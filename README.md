<div align="center">

# pacman

**`podman` and `docker` on macOS, the way they work on Linux — no `machine`, no `remote`.**

</div>

---

`pacman` lets the stock `podman` and `docker` CLIs manage local containers on a Mac
with zero setup and zero VM-machine concepts. It exposes **both** the Docker Engine
API and the podman libpod API on a single unix socket, backed by Apple's
[containerization](https://github.com/apple/containerization) framework — the same
technology as Apple's [`container`](https://github.com/apple/container) CLI — so every
container runs in its own lightweight microVM.

```bash
podman ps                     # just works — no podman machine, no CONTAINER_HOST
docker ps                     # just works — no Docker Desktop, no context juggling
podman run --rm alpine echo hello
docker build -t myapp .
podman build --platform linux/amd64,linux/ppc64le --manifest myapp .
```

## Why

On macOS, `podman` normally requires `podman machine` (a resident Linux VM holding
pinned RAM and a guest disk) and `docker` requires Docker Desktop (a resident daemon
plus VM). `pacman` replaces both with:

- **microVM per container** (Apple container model) — no shared VM to keep alive,
  no guest disk to resize, VMs die with their containers, memory is not pinned;
- **an on-demand API daemon** — launchd socket activation: zero resident RAM when
  idle, spawned on first connection;
- **stock CLIs, maximal compatibility** — pacman's policy is to support *all* flags
  and commands of both `podman` and `docker`, by putting the real CLIs in front of
  a socket that speaks both API dialects. `pacman` itself is a thin client shim
  that dispatches to the real CLIs with the right environment.

## Architecture

```
podman ─┐                                  ┌─ Docker Engine API (/v1.*/)
docker ─┼─ pacman (client shim, argv0) ────┤                    one socket,
        │        exec real CLI w/ env      ├─ podman libpod API (/libpod/*)  both dialects
        ▼                                   ▼
   unix socket (launchd socket activation → 0 RAM idle)
        │
     pacmand (Swift/Vapor daemon)
        │
   apple/containerization — one lightweight Linux VM per container
   (container-apiserver, BuildKit builder VMs, Rosetta + QEMU for multi-arch)
```

| Piece | What it is |
|---|---|
| `pacman` | Client shim: dispatches by argv[0] (`pacman`/`podman`/`docker` symlinks), ensures the socket exists, execs the real `podman`/`docker` CLI with `CONTAINER_HOST`/`DOCKER_HOST` pointing at pacman's socket |
| `pacmand` | Swift daemon (Vapor) serving Docker Engine API v1.51 + libpod API on one unix socket (`~/.pacman/container.sock`) |
| launchd | `LaunchAgent` with socket activation — the daemon only exists while something is talking to it (or containers are running) |

## Requirements

- macOS 26 (Tahoe) or newer, Apple Silicon (arm64)
- Apple `container` 1.6.1+ (`brew install container`)
- The real CLIs you want to use: `podman` (brew) and/or `docker` (brew, client only)

## Status

Imported from [socktainer](https://github.com/socktainer/socktainer)
(Apache-2.0) with its podman libpod API layer and multi-arch build support,
rebranded and extended. See [RESEARCH.md](RESEARCH.md) for the landscape study
that motivated this project and [docs](docs/) for details.

## License

Apache-2.0 — same as socktainer. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
