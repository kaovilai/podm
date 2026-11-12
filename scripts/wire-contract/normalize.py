#!/usr/bin/env python3
"""Turn a raw recording (JSONL from mock_socket.py / run.sh) into the
canonical baseline shape: one entry per battery command with its ordered
request signatures. Volatile path segments (64-hex ids, 12+ hex tokens)
are replaced so server-derived ids can't churn the baseline.

Usage: normalize.py RECORDING.jsonl PODMAN_VERSION > baseline.json
"""
import json
import re
import sys

HEX64 = re.compile(r"\b[0-9a-f]{64}\b")
HEX12 = re.compile(r"\b[0-9a-f]{12,63}\b")


def normalize_path(path):
    path = HEX64.sub("{id}", path)
    path = HEX12.sub("{id}", path)
    return path


def main():
    recording, podman_version = sys.argv[1], sys.argv[2]
    commands = []
    current = None
    with open(recording) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            entry = json.loads(line)
            if "marker" in entry:
                current = {"command": entry["marker"], "requests": []}
                commands.append(current)
                continue
            if current is None:
                continue
            current["requests"].append(
                {
                    "method": entry["method"],
                    "path": normalize_path(entry["path"]),
                    "query_keys": entry["query_keys"],
                    "content_type": entry["content_type"],
                }
            )
    print(
        json.dumps(
            {"podman_version": podman_version, "commands": commands},
            indent=2,
            sort_keys=False,
        )
    )


if __name__ == "__main__":
    main()
