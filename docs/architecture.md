# Architecture

This document maps podm's design onto the actual repository layout. For the
*why* behind the design, see [no-machine.md](no-machine.md); for the build
machinery, [multi-arch.md](multi-arch.md).

## The big picture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Client layer                                                                │
│   podman ─┐                                                                │
│   docker ─┼─ podm (Sources/podm, multi-call shim, argv[0] dispatch)     │
│           │    · finds real CLIs (~/.podm/client-paths.json)              │
│           │    · wakes daemon (launchctl kickstart) if needed               │
│           │    · execs real CLI with CONTAINER_HOST/DOCKER_HOST set         │
├─────────────────────────────────────────────────────────────────────────────┤
│ Transport                                                                   │
│   unix socket ~/.podm/container.sock (0700 dir, 0666 socket)              │
│   ONE server, BOTH dialects:                                                │
│     /v1.32–v1.51/*  Docker Engine API      (docker CLI, compose, docker-py) │
│     /libpod/*       podman REST v4/v5      (podman CLI)                     │
├─────────────────────────────────────────────────────────────────────────────┤
│ Daemon layer — podmd (Sources/podmd, Swift/Vapor)                       │
│   launchd LaunchAgent io.github.podm.daemon: on-demand start,             │
│   idle-exit (PODM_IDLE_EXIT_SECS, 0 connections + 0 running containers)   │
├─────────────────────────────────────────────────────────────────────────────┤
│ Runtime — apple/containerization (same backend as apple/container CLI)      │
│   container-apiserver + container-core-images + container-network-vmnet     │
│   one lightweight Linux microVM per container (virtiofs, vmnet, vsock)      │
│   BuildKit builder container VMs (Rosetta builder + QEMU binfmt builder)    │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Repository layout

| Path | Component | Purpose |
|---|---|---|
| `Sources/podm/` | Client shim | Multi-call binary: `podm` own subcommands (`install`, `uninstall`, `status`, `doctor`, `version`, `serve`) + `podman`/`docker` persona dispatch on `argv[0]` |
| `Sources/podmd/main.swift` | Daemon entry point | Argument parsing, compatibility check, single-instance lock, socket bind, docker-context registration |
| `Sources/podmd/configure.swift` | Route registration | Wires every route collection into the Vapor app (Docker Engine, libpod, and support routes) |
| `Sources/podmd/Routes/Containers/` | Docker container routes | Docker Engine container lifecycle endpoints (`/containers/...`) |
| `Sources/podmd/Routes/Images/` | Docker image routes | Build, pull, push, inspect, prune, load/save (`/images/...`, `/build`) |
| `Sources/podmd/Routes/Libpod/` | Podman libpod routes | ~65 route files mirroring the libpod API (`/libpod/...`) — the layer that makes the stock `podman` CLI work |
| `Sources/podmd/Routes/Networks/`, `Routes/Volumes/` | Network / volume routes | Docker network and volume endpoints |
| `Sources/podmd/Routes/Server/` | Server routes | `/_ping`, `/info`, `/version`, `/events`, system df |
| `Sources/podmd/Routes/Swarm/`, `Routes/Plugins/` | Compatibility stubs | Swarm and plugin endpoints return the Docker-expected "not supported" shapes so clients don't break |
| `Sources/podmd/Routes/Registry/` | Registry routes | Auth and distribution endpoints |
| `Sources/podmd/Clients/` | Service layer | Business logic wrapping Apple Container/Containerization frameworks: container, image, builder, manifest, network, volume, registry-credentials (Keychain), archive (cp/export), health check, plus a reconnecting client wrapper |
| `Sources/podmd/Models/` | REST models | Request/response DTOs matching the Docker Engine API and libpod schemas |
| `Sources/podmd/DNS/` | DNS service | Embedded DNS: a tiny static Rust forwarder (`podm-dns`, ~388 KB) run as a sidecar per user-defined network, resolving container/service names and forwarding the rest upstream |
| `Sources/podmd/Events/` | Event system | Event broadcaster for `podman events` / `docker events` and client liveness monitoring; volume-mount events |
| `Sources/podmd/Utilities/` | Utilities | Socket setup, StdioPipes (fd ownership — see CONTRIBUTING.md), docker-context setup, docker.sock relay, platform classification, buildctl helpers, restart-policy store, volume image cleaner |
| `Sources/BuildInfo/` | Build metadata | C target exposing build version, git commit, and supported Docker Engine API versions (min v1.32, max v1.51) to Swift |
| `Tests/podmdTests/` | Test suite | Unit tests organized by feature area (`Routes/`, `Clients/`, `Utilities/`, `DNS/`, `Events/`, `Network/`) |
| `pkginstaller/` | macOS .pkg | `make installer` produces a signed/notarizable installer for `podmd` |
| `scripts/lint-pipes.sh` | CI guard | Rejects `= Pipe()` in non-registry source (fd-ownership rule) |

## One socket, two dialects

`podmd` binds a single unix domain socket at `~/.podm/container.sock` and
serves both API families from one Vapor app:

- **Docker Engine API** (`/v1.32`–`/v1.51`): consumed by the `docker` CLI,
  `docker compose`, docker-py, and tools that speak the Docker protocol.
- **podman libpod API** (`/libpod/*`, REST v4/v5 conventions): consumed by the
  `podman` CLI in remote-client mode.

Both dialects see the same containers, images, volumes, and networks — there is
one state store underneath. Route coverage is audited in
[PODMAN_API_AUDIT.md](../PODMAN_API_AUDIT.md).

The socket directory is `0700` (other host users kept out) while the socket
itself is `0666` — that mode is mirrored onto the root-owned guest-side socket
by Apple's runtime, which is what lets non-root processes *inside* containers
reach a Docker API (see DockerSocketRelay below).

## The client shim (Sources/podm)

The shim is a multi-call binary: behavior is selected by `argv[0]`, never by
aliases (a shell alias collapses all invocations to one `argv[0]`). `podm
install` creates symlinks in `~/.podm/bin`:

```
~/.podm/bin/podm   → the shim itself
~/.podm/bin/podman   → podm   (persona: exec real podman)
~/.podm/bin/docker   → podm   (persona: exec real docker)
```

With `~/.podm/bin` first on `PATH`, the personas win over the brew-installed
originals. The shim records the resolved real-CLI paths in
`~/.podm/client-paths.json` at install time, wakes the daemon if needed, and
execs the real CLI with `CONTAINER_HOST`/`DOCKER_HOST` pointing at
`unix://$HOME/.podm/container.sock`. Flag and command coverage is therefore
inherited from the real CLIs, forever current.

## Daemon lifecycle (launchd, on-demand)

`podmd` is managed by a per-user LaunchAgent (`io.github.podm.daemon`):

1. **Start on demand.** Nothing resident when idle. The client shim (or any
   podm subcommand) wakes the daemon via `launchctl kickstart` when it needs
   the socket; `podmd` can also be run in the foreground with `podm serve`.
2. **Idle exit.** When the daemon has had **zero API connections and zero
   running containers** for `PODM_IDLE_EXIT_SECS`, it exits. A running
   container always keeps the daemon alive.
3. **Single instance.** A lock file (`~/.podm/podm.lock`) is held for the
   process lifetime; a second `podmd` against the same socket refuses to
   start instead of stealing it.
4. **State survives the daemon.** All container/image/volume state lives in
   Apple container's store and on-disk files under `~/.podm`; a daemon
   restart reattaches to running containers.

Apple's own helpers (`container-apiserver`, `container-core-images`,
`container-network-vmnet`) are launchd XPC services started on demand when
containers or builds run; `container system stop` releases their ~25 MB when you
want an entirely flat machine.

## State on disk

| Path | Contents |
|---|---|
| `~/.podm/container.sock` | The API socket (both dialects) |
| `~/.podm/podm.lock` | Single-instance lock |
| `~/.podm/bin/` | Shim + `podman`/`docker` symlinks |
| `~/.podm/client-paths.json` | Real `podman`/`docker` CLI paths discovered at install |
| `~/.podm/podm-restart-policy-overrides.json` | Restart policies applied on daemon restart (VM resources are fixed at create; restart policies are tracked host-side) |
| `~/.docker/contexts/meta/...` | The `podm` docker context auto-registered by the daemon (`docker context use podm`) |
| Apple container's store | Images and content (managed by `container-core-images`), not by podm |

## Image & content store

Images are pulled, stored, and exported through Apple container's image store
(`container-core-images`), not a podm-specific store. `podmd` delegates via
the Containerization framework's image APIs, which means `container images ls`
and `podman images` see the same content. Builds go through BuildKit builder
*container VMs* — see [multi-arch.md](multi-arch.md) for the Rosetta/QEMU split.

## Supporting subsystems

- **Embedded DNS** (`Sources/podmd/DNS/`): a static Rust forwarder sidecar is
  launched per user-defined network. It resolves single-label container/service
  names locally (so compose-style service discovery works despite Apple
  containers having a single global hostname namespace) and forwards everything
  else upstream. Host-side port is `PODM_DNS_PORT` (default 2054).
- **docker.sock relay** (`Utilities/DockerSocketRelay.swift`): a bind mount of
  `/var/run/docker.sock` *into* a container can't be virtiofs-shared (it's a
  socket), so podm redirects the mount source to its own control socket;
  Apple's runtime vsock-relays it, giving the guest a working Docker API. This
  is what makes docker-context-aware tools inside containers (e.g. Supabase's
  `vector`) work.
- **Events** (`Sources/podmd/Events/`): `EventBroadcaster` fans container
  lifecycle events out to `/events` subscribers (podman/docker CLIs use this for
  liveness monitoring of long-running commands).
- **Registry credentials** (`Clients/ClientRegistryService.swift`): stored in
  the macOS Keychain, matching `container` CLI behavior.
- **Volume cleaner** (`Utilities/VolumeImageCleaner.swift`): named volumes are
  EXT4 images and Apple always creates `/lost+found` at the root, which breaks
  Postgres `initdb`; podm reformats the image to remove it (opt out:
  `PODM_CLEAN_VOLUMES=false` or label `podm.clean-volumes=false`).
