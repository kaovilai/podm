#!/usr/bin/env python3
"""Recording stand-in for podm's socket (wire-contract harness).

Logs every HTTP request the real podman/docker CLI sends — method, path,
query parameters (names AND value shapes), content type — and answers
with podm-shaped minimal responses (the /_ping headers mirror
HealthCheckPingRoute exactly) so the client keeps making calls. The
recordings are normalized into signatures and diffed against
scripts/wire-contract/baseline-<cli>.json in CI: upstream call-signature
drift (issue #49's absolute-path -f, #52's repeated t key) shows up as a
diff the day a new CLI makes requests differently.

Usage: mock_socket.py <socket-path> <out.jsonl>
"""
import json
import re
import socketserver
import sys
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qsl

SOCK, OUT = sys.argv[1], sys.argv[2]

# A FIXED 64-hex id returned by create-style endpoints: downstream request
# paths then carry a constant (no per-run volatility to normalize away).
FIXED_ID = "wirefixedid0123456789abcdef0123456789abcdef0123456789abcdef"

# Endpoints whose plausibly-empty response is a LIST, so client parsing
# proceeds past them.
LIST_ENDINGS = (
    "/containers/json",
    "/images/json",
    "/networks",
    "/volumes",
    "/pods/json",
    "/secrets/json",
    "/manifests",
    "/events",
)

VERSION_PREFIX = re.compile(r"^/v\d+(?:\.\d+){1,2}")


def signature_path(path):
    """Strip the /vX.Y.Z API-version prefix; keep the dialect base
    (/containers/json vs /libpod/containers/json are different routes)."""
    return VERSION_PREFIX.sub("", path, count=1)


def value_shape(value):
    """Stable token for a query VALUE: absolute paths collapse to
    {abspath} (tempdirs vary per run), JSON-encoded arrays keep their
    element shapes, everything else passes through verbatim — battery
    arguments are fixed, so plain values are deterministic and drift in
    them (relative→absolute -f, #49) is exactly what must be visible."""
    if value.startswith("/"):
        return "{abspath}"
    try:
        decoded = json.loads(value)
    except ValueError:
        return value
    if isinstance(decoded, list):
        return [value_shape(v) for v in decoded if isinstance(v, str)]
    return value


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _read_body(self):
        if (self.headers.get("Transfer-Encoding") or "").lower() == "chunked":
            while True:
                size_line = self.rfile.readline().strip()
                try:
                    size = int(size_line.split(b";")[0], 16)
                except ValueError:
                    return
                if size == 0:
                    self.rfile.readline()
                    return
                self.rfile.read(size)
                self.rfile.readline()
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)

    def _record(self):
        self._read_body()
        raw_path, _, raw_query = self.path.partition("?")
        # Values as shapes (see value_shape): names, tags, timestamps from
        # the fixed battery stay verbatim; volatile absolute paths collapse.
        query = {}
        for key, value in parse_qsl(raw_query, keep_blank_values=True):
            query.setdefault(key, []).append(value_shape(value))
        entry = {
            "method": self.command,
            "path": signature_path(raw_path),
            "query": query,
            "content_type": (self.headers.get("Content-Type") or "").split(";")[0],
        }
        with open(OUT, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def _respond(self):
        path = signature_path(self.path.partition("?")[0])
        if path == "/_ping" or path.endswith("/_ping"):
            # Both dialects: docker pings /_ping, podman /libpod/_ping —
            # each must see the negotiation headers HealthCheckPingRoute
            # sends, or the client bails before the battery's real calls.
            body = b"OK" if self.command != "HEAD" else b""
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Api-Version", "1.51")
            self.send_header("Builder-Version", "")
            self.send_header("Docker-Experimental", "false")
            # Mirrors podm's HealthCheckPingRoute: the podman client checks
            # this on GET /_ping during connection setup.
            self.send_header("Libpod-API-Version", "5.0.0")
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)
            return
        if path.endswith("/exec"):
            # Exec creation (POST /libpod/containers/<name>/exec): a real
            # Id makes the follow-up /exec/<id>/json + /exec/<id>/start
            # calls carry a fixed id instead of an empty one.
            body = json.dumps({"Id": FIXED_ID}).encode()
        elif path.endswith("/containers/create") or path.endswith("/images/create"):
            # {"Id": ...} shape so id-carrying follow-up calls happen.
            body = json.dumps({"Id": FIXED_ID, "Warnings": []}).encode()
        elif path.endswith("/images/pull"):
            # podman's pull response is a stream of JSON events ending in
            # the image id — a plain-text id fails client-side decoding.
            body = (
                json.dumps({"Id": "sha256:" + FIXED_ID, "Stream": "done"})
                + "\n"
            ).encode()
        elif re.fullmatch(r"(/libpod)?/images/[^/]+/json", path):
            # Minimal image inspect so create/run proceed past the
            # "does the image exist locally" lookup.
            body = json.dumps(
                {
                    "Id": "sha256:" + FIXED_ID,
                    "RepoTags": ["alpine:latest"],
                    "Created": "2020-01-01T00:00:00Z",
                    "Os": "linux",
                    "Architecture": "arm64",
                    "Config": {},
                    "RootFS": {"Type": "layers", "Layers": []},
                }
            ).encode()
        elif re.fullmatch(r"(/libpod)?/containers/json", path):
            # One running container so name→id resolution succeeds and
            # start/stop/restart reach their lifecycle POSTs.
            body = json.dumps(
                [
                    {
                        "Id": FIXED_ID,
                        "Names": ["wct"],
                        "Image": "sha256:" + FIXED_ID,
                        "ImageID": "sha256:" + FIXED_ID,
                        "Command": ["echo", "hi"],
                        "Created": "2020-01-01T00:00:00Z",
                        "State": "exited",
                        "Status": "Exited (0)",
                        "Labels": {},
                    }
                ]
            ).encode()
        elif re.fullmatch(r"(/libpod)?/containers/[^/]+/json", path):
            # Minimal container inspect (looks running) so start/stop/
            # restart/kill/pause reach their lifecycle POSTs.
            body = json.dumps(
                {
                    "Id": FIXED_ID,
                    "Name": "wct",
                    "Created": "2020-01-01T00:00:00Z",
                    "State": {
                        "Status": "exited",
                        "Running": False,
                        "Paused": False,
                        "OciVersion": "1.0.0",
                    },
                    "Image": "sha256:" + FIXED_ID,
                    "Config": {"Image": "alpine:latest"},
                    "HostConfig": {},
                    "NetworkSettings": {},
                }
            ).encode()
        elif path.endswith(LIST_ENDINGS):
            body = b"[]"
        elif path.endswith("/build"):
            body = b'{"stream":"wire-contract: no real build\\n"}'
        else:
            body = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self):
        try:
            self._record()
            self._respond()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_PATCH = do_OPTIONS = _handle

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    open(OUT, "w").close()
    server = Server(SOCK, Handler)
    server.serve_forever()
