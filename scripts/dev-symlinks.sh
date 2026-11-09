#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Developer helper: create .build/podm-dev/bin/{podm,podman,docker} symlinks
# pointing at the locally built podm shim, for PATH testing without a full
# `podm install`:
#
#   scripts/dev-symlinks.sh
#   export PATH="$PWD/.build/podm-dev/bin:$PATH"
#   podman ps   # goes through the shim -> real podman with CONTAINER_HOST set
#
# The shim's PATH-scan skip logic handles this layout: the symlinks resolve
# (realpath) to the built podm binary, which the shim recognizes as itself.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$REPO_ROOT/.build/podm-dev/bin"

# Locate the built shim (debug first, then release).
SHIM=""
for candidate in "$REPO_ROOT/.build/debug/podm" "$REPO_ROOT/.build/release/podm"; do
    if [[ -x "$candidate" ]]; then
        SHIM="$candidate"
        break
    fi
done
if [[ -z "$SHIM" ]]; then
    echo "error: built podm binary not found — run 'make build' (or 'make release') first" >&2
    exit 1
fi

mkdir -p "$BIN_DIR"
for name in podm podman docker; do
    ln -sfn "$SHIM" "$BIN_DIR/$name"
done

echo "Created dev shims in $BIN_DIR"
echo "  export PATH=\"$BIN_DIR:\$PATH\""
