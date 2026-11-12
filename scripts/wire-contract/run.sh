#!/usr/bin/env bash
# Wire-contract recording: run the real podman CLI against the mock socket
# and capture every request it sends. Usage:
#   bash scripts/wire-contract/run.sh RECORDING.jsonl [podman-binary]
# Env:
#   WC_CMD_PREFIX  prefix for each battery command (CI's pinned mode wraps
#                  them in `docker run quay.io/podman/stable:vX`); when set,
#                  CONTAINER_HOST is exported for the inner container by the
#                  prefix itself, not here.
#   WC_TIMEOUT     per-command timeout in seconds (default 20, host mode).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=${1:?usage: run.sh RECORDING.jsonl [podman-binary]}
PODMAN=${2:-podman}
PREFIX=${WC_CMD_PREFIX:-}
TIMEOUT=${WC_TIMEOUT:-20}

# Temp DIR + fixed name: GNU mktemp (CI) requires the X's to be trailing,
# which a .sock suffix would break — the dir form is portable.
SOCK_DIR=$(mktemp -d)
SOCK="$SOCK_DIR/wire.sock"
python3 "$HERE/mock_socket.py" "$SOCK" "$OUT" &
MOCK=$!
trap 'kill $MOCK 2>/dev/null; rm -rf "$SOCK_DIR"' EXIT
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { echo "mock socket never appeared" >&2; exit 1; }

if [ -z "$PREFIX" ]; then
    export CONTAINER_HOST="unix://$SOCK"
fi

# A tiny deterministic build context.
CTX=$(mktemp -d)
printf 'FROM alpine:latest\nRUN echo wire\n' > "$CTX/Dockerfile"
trap 'kill $MOCK 2>/dev/null; rm -rf "$SOCK_DIR"; rm -rf "$CTX"' EXIT

# The CI prefix carries %CTX% / %SOCK% placeholders (docker -v needs host
# paths, which only run.sh knows). The inner container gets CONTAINER_HOST
# through the prefix itself.
PREFIX="${PREFIX//\%CTX%/$CTX}"
PREFIX="${PREFIX//\%SOCK%/$SOCK}"

# The battery: fixed arguments only — relative times, random names, and
# server-derived ids all make recordings non-comparable across runs. The
# mock returns a FIXED create id, so follow-up paths stay constant.
# Each line runs in a subshell; failures are expected (the mock's
# responses are minimal) — only the REQUESTS matter.
battery=(
    "podman --version"
    "podman version"
    "podman info"
    "podman ps"
    "podman ps -a"
    "podman images"
    "podman images -a"
    "podman image ls"
    "podman image inspect alpine:latest"
    "podman pull docker.io/library/alpine:latest"
    "podman create --name wct alpine:latest echo hi"
    "podman start wct"
    "podman stop wct"
    "podman restart wct"
    "podman kill wct"
    "podman pause wct"
    "podman unpause wct"
    "podman init wct"
    "podman inspect wct"
    "podman container inspect wct"
    "podman top wct"
    "podman stats --no-stream"
    "podman logs wct"
    "podman logs --since 2020-01-01T00:00:00Z wct"
    "podman logs -f --since 2020-01-01T00:00:00Z --until 2020-01-01T00:05:00Z wct"
    "podman exec wct ls /"
    "podman exec -e FOO=bar wct env"
    "podman rename wct wct2"
    "podman wait wct"
    "podman port wct"
    "podman diff wct"
    "podman rm wct"
    "podman rm -f wct2"
    "podman container prune -f"
    "podman run --rm alpine:latest echo hi"
    "podman run --name wcr alpine:latest echo hi"
    "podman run -d alpine:latest"
    "podman tag alpine:latest wctag:1"
    "podman rmi wctag:1"
    "podman image prune -f"
    "podman history alpine:latest"
    "podman push alpine:latest docker.io/example/wc:1"
    "podman search alpine"
    "podman commit wcr wcimg:1"
    "podman export wcr"
    "podman save -o /tmp/wc.tar alpine:latest"
    "podman load -i /tmp/wc.tar"
    "podman build -f Dockerfile ."
    "podman build -t wc-a -t wc-b ."
    "podman build -q -f Dockerfile ."
    "podman manifest create wcm alpine:latest"
    "podman manifest inspect wcm"
    "podman volume create wcv"
    "podman volume ls"
    "podman volume inspect wcv"
    "podman volume rm wcv"
    "podman volume prune -f"
    "podman network create wcn"
    "podman network ls"
    "podman network inspect wcn"
    "podman network rm wcn"
    "podman network prune -f"
    "podman events --since 2020-01-01T00:00:00Z --until 2020-01-01T01:00:00Z"
    "podman system df"
    "podman system info"
    "podman secret ls"
    "podman secret create wcs -"
    "podman secret inspect wcs"
    "podman secret rm wcs"
    "podman container exists wct"
    "podman container list --all"
    "podman inspect --type image alpine:latest"
    "podman container checkpoint -l"
    "podman generate systemd wct"
)

for cmd in "${battery[@]}"; do
    echo "{\"marker\": \"$(echo "$cmd" | sed 's/"/\\"/g')\"}" >> "$OUT"
    if [ -n "$PREFIX" ]; then
        # Container-wrapped battery line (CI pinned mode): the prefix
        # carries CONTAINER_HOST into the container.
        (cd "$CTX" && $PREFIX $cmd >/dev/null 2>&1)
    else
        (cd "$CTX" && timeout "$TIMEOUT" $cmd >/dev/null 2>&1)
    fi
done

echo "recorded $(grep -vc '"marker"' "$OUT") requests across ${#battery[@]} commands -> $OUT"
