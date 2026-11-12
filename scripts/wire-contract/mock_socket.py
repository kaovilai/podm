#!/usr/bin/env python3
"""Recording stand-in for podm's socket (wire-contract harness).

Logs every HTTP request the real podman CLI sends — method, path, query
parameter NAMES, content type — and answers with podm-shaped minimal
responses (the /_ping headers mirror HealthCheckPingRoute exactly) so the
client keeps making calls. The recordings are normalized into signatures
and diffed against scripts/wire-contract/baseline.json in CI: upstream
call-signature drift (issue #49's absolute-path -f, #52's repeated t key)
shows up as a diff the day a new podman CLI makes requests differently.

Usage: mock_socket.py <socket-path> <out.jsonl>
"""
import json
import re
import socketserver
import sys
from http.server import BaseHTTPRequestHandler

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
        query_keys = sorted(
            part.split("=", 1)[0] for part in raw_query.split("&") if part
        )
        entry = {
            "method": self.command,
            "path": signature_path(raw_path),
            "query_keys": query_keys,
            "content_type": (self.headers.get("Content-Type") or "").split(";")[0],
        }
        with open(OUT, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def _respond(self):
        path = signature_path(self.path.partition("?")[0])
        if path == "/_ping":
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
        if path.endswith("/containers/create") or path.endswith("/images/create"):
            # {"Id": ...} shape so id-carrying follow-up calls happen.
            body = json.dumps({"Id": FIXED_ID, "Warnings": []}).encode()
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
