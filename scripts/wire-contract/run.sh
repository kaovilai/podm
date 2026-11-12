#!/usr/bin/env bash
# Wire-contract recording: run the real podman or docker CLI against the
# mock socket and capture every request it sends. Usage:
#   bash scripts/wire-contract/run.sh RECORDING.jsonl <podman|docker> [binary]
# Env:
#   WC_TIMEOUT  per-command timeout in seconds (default 20).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=${1:?usage: run.sh RECORDING.jsonl <podman|docker> [binary]}
CLI=${2:?usage: run.sh RECORDING.jsonl <podman|docker> [binary]}
BIN=${3:-$CLI}
TIMEOUT=${WC_TIMEOUT:-20}
case "$CLI" in
    podman) HOST_VAR=CONTAINER_HOST ;;
    docker) HOST_VAR=DOCKER_HOST ;;
    *) echo "unknown CLI: $CLI (podman|docker)" >&2; exit 2 ;;
esac

# Temp DIR + fixed name: GNU mktemp (CI) requires the X's to be trailing,
# which a .sock suffix would break — the dir form is portable.
SOCK_DIR=$(mktemp -d)
SOCK="$SOCK_DIR/wire.sock"
python3 "$HERE/mock_socket.py" "$SOCK" "$OUT" &
MOCK=$!
trap 'kill $MOCK 2>/dev/null; rm -rf "$SOCK_DIR"' EXIT
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { echo "mock socket never appeared" >&2; exit 1; }

export "$HOST_VAR=unix://$SOCK"
if [ "$CLI" = docker ]; then
    # Isolate from the user's docker config: a named context there would
    # override DOCKER_HOST and point the CLI somewhere else entirely.
    export DOCKER_CONFIG="$SOCK_DIR/docker-config"
    mkdir -p "$DOCKER_CONFIG"
fi

# A tiny deterministic build context.
CTX=$(mktemp -d)
printf 'FROM alpine:latest\nRUN echo wire\n' > "$CTX/Dockerfile"
trap 'kill $MOCK 2>/dev/null; rm -rf "$SOCK_DIR"; rm -rf "$CTX"' EXIT

# The battery: fixed arguments only — relative times, random names, and
# server-derived ids all make recordings non-comparable across runs. The
# mock returns a FIXED create id, so follow-up paths stay constant.
# Each line runs in a subshell; failures are expected (the mock's
# responses are minimal) — only the REQUESTS matter.
# Each line runs in a subshell; failures are expected (the mock's
# responses are minimal) — only the REQUESTS matter. The leading CLI word
# is replaced with the concrete binary at run time; the recorded command
# strings stay binary-agnostic.
if [ "$CLI" = podman ]; then
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
    "podman save -o wc.tar alpine:latest"
    "podman load -i wc.tar"
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
else
battery=(
    "docker --version"
    "docker version"
    "docker info"
    "docker ps"
    "docker ps -a"
    "docker images"
    "docker images -a"
    "docker image ls"
    "docker image inspect alpine:latest"
    "docker pull docker.io/library/alpine:latest"
    "docker create --name wct alpine:latest echo hi"
    "docker start wct"
    "docker stop wct"
    "docker restart wct"
    "docker kill wct"
    "docker pause wct"
    "docker unpause wct"
    "docker inspect wct"
    "docker container inspect wct"
    "docker top wct"
    "docker stats --no-stream"
    "docker logs wct"
    "docker logs --since 2020-01-01T00:00:00Z wct"
    "docker exec wct ls /"
    "docker exec -e FOO=bar wct env"
    "docker rename wct wct2"
    "docker wait wct"
    "docker port wct"
    "docker diff wct"
    "docker rm wct"
    "docker rm -f wct2"
    "docker container prune -f"
    "docker run --rm alpine:latest echo hi"
    "docker run --name wcr alpine:latest echo hi"
    "docker run -d alpine:latest"
    "docker tag alpine:latest wctag:1"
    "docker rmi wctag:1"
    "docker image prune -f"
    "docker history alpine:latest"
    "docker push alpine:latest"
    "docker search alpine"
    "docker commit wcr wcimg:1"
    "docker export wcr"
    "docker save -o wc.tar alpine:latest"
    "docker load -i wc.tar"
    "docker build -f Dockerfile ."
    "docker build -t wc-a -t wc-b ."
    "docker build -q -f Dockerfile ."
    "docker manifest create wcm alpine:latest"
    "docker manifest inspect wcm"
    "docker volume create wcv"
    "docker volume ls"
    "docker volume inspect wcv"
    "docker volume rm wcv"
    "docker volume prune -f"
    "docker network create wcn"
    "docker network ls"
    "docker network inspect wcn"
    "docker network rm wcn"
    "docker network prune -f"
    "docker events --since 2020-01-01T00:00:00Z --until 2020-01-01T01:00:00Z"
    "docker system df"
    "docker system info"
    "docker secret ls"
    "docker secret create wcs -"
    "docker secret inspect wcs"
    "docker secret rm wcs"
    "docker container ls --all"
    "docker inspect --type image alpine:latest"
)
fi

for cmd in "${battery[@]}"; do
    echo "{\"marker\": \"$(echo "$cmd" | sed 's/"/\"/g')\"}" >> "$OUT"
    # Replace the leading CLI word with the concrete binary path.
    resolved="${cmd/#$CLI/$BIN}"
    (cd "$CTX" && eval "timeout $TIMEOUT $resolved" >/dev/null 2>&1 || true)
done

echo "recorded $(grep -vc '"marker"' "$OUT") requests across ${#battery[@]} commands -> $OUT"
