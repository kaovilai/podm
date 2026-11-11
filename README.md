<div align="center">

# podm

**podman's promise, true on Mac — no `machine`, no `remote`, no resident daemon.**

> *No manager daemon, for improved security and lower resource utilization at idle.*
> — podman's own pledge, which its macOS story breaks with a resident VM.
> `podm` keeps it: microVM per container, zero daemon RAM at idle.

</div>

<!-- Badges: enable once CI badge URLs are public. Do not fake them.
[![CI](https://github.com/kaovilai/podm/actions/workflows/pr-check.yaml/badge.svg)](https://github.com/kaovilai/podm/actions/workflows/pr-check.yaml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-26%2B%20arm64-black.svg)](#requirements)
-->

---

`podm` lets the stock `podman` and `docker` CLIs manage local containers on a Mac
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

## Why podm?

On macOS, `podman` normally requires `podman machine` — a resident Linux VM holding
pinned RAM and a guest disk you have to resize — and `docker` requires Docker
Desktop, a resident daemon plus VM that idles in the gigabytes. `podm` replaces
both with:

- **microVM per container** (the Apple `container` model) — no shared VM to keep
  alive, no guest disk to manage; each VM dies with its container and memory is
  overcommitted by macOS like any other process, so idle containers page out
  instead of pinning RAM.
- **an on-demand daemon** — `podmd` runs under a launchd LaunchAgent and exits
  when it has zero connections and zero running containers. Idle RAM for the whole
  stack is **0 MB for podm itself and ≈25 MB for Apple's helper services**
  (measured: `container-apiserver` 9.8 MB + `container-core-images` 10.0 MB +
  `container-network-vmnet` 4.7 MB, 0% CPU — versus a multi-GB pinned VM).
- **stock CLIs, maximal compatibility** — podm's policy is to support *all*
  flags and commands of both `podman` and `docker` by putting the **real CLIs** in
  front of a socket that speaks both API dialects. `podm` itself is a thin client
  shim that dispatches to the real CLIs with the right environment. You never
  outgrow it: every new podman/docker flag works on day one, because it is the
  actual CLI.

See [docs/no-machine.md](docs/no-machine.md) for the full philosophy, the RAM math,
and the hard limits we accept.

## Install

### Homebrew

The formula is ready ([`Formula/podm.rb`](Formula/podm.rb)) and the release
pipeline publishes to the [`kaovilai/homebrew-tap`](https://github.com/kaovilai/homebrew-tap)
tap — it becomes installable with the first tagged release:

```bash
brew install kaovilai/tap/podm
```

Until then, use the source flow below (or a build artifact from
[Actions](https://github.com/kaovilai/podm/actions)).

### Requirements

- macOS 26 (Tahoe) or newer, Apple Silicon (arm64)
- Apple `container` 1.6.1+ — `brew install container`
- The real CLIs you want to use: `podman` (brew) and/or `docker` (brew, client only)

### From source

```bash
git clone https://github.com/kaovilai/podm.git
cd podm
make                # builds podmd (daemon) + podm (client), debug
```

A macOS `.pkg` is also available via `make installer` (system install to
`/opt/podm`, needs admin; see `make installer-help` for signed/notarized
variants).

The source + `podm install` flow below is entirely user-space — no sudo
needed.

### Set up the client (`podm install`)

One-time bootstrap — installs the `podm` client, symlinks the `podman` and
`docker` personas, and records the real CLI paths:

```bash
.build/debug/podm install
```

Add `--launchd-template assets/launchd/io.github.podm.daemon.plist.in` to
also install the daemon's LaunchAgent (on-demand lifecycle: idle-exit +
kickstart wake). Without it, start the daemon yourself when needed:
`.build/debug/podmd &` (or `podm serve`).

Then put podm's bin directory first on your `PATH` (in `~/.zshrc`):

```bash
export PATH="$HOME/.podm/bin:$PATH"
```

`podm install` places `podman → podm` and `docker → podm` symlinks in
`~/.podm/bin`. The shim dispatches on `argv[0]`, locates the *real* CLIs
(recorded in `~/.podm/client-paths.json`), and execs them with
`CONTAINER_HOST` / `DOCKER_HOST` pointing at podm's socket
(`unix://$HOME/.podm/container.sock`). Because it's the actual `podman` and
`docker` binaries doing the talking, every flag and subcommand they support works.

### Optional: `/var/run/docker.sock` compatibility

Tools that hardcode `/var/run/docker.sock` work with one symlink (one-time sudo):

```bash
sudo ln -s "$HOME/.podm/container.sock" /var/run/docker.sock
```

### Optional: docker context

`podmd` registers a `podm` docker context automatically. Instead of exporting
`DOCKER_HOST`, you can make it your default once:

```bash
docker context use podm
```

## Usage

### Personas

`podm` is a multi-call binary: what it does depends on the name it was invoked as.

| Invoked as | Behavior |
|---|---|
| `podm` | podm's own subcommands (below) |
| `podman` | execs the real `podman` CLI against podm's socket |
| `docker` | execs the real `docker` CLI against podm's socket |

### podm subcommands

| Command | Purpose |
|---|---|
| `podm install` | One-time setup: symlinks, LaunchAgent, client-path discovery |
| `podm uninstall` | Remove symlinks, LaunchAgent, and podm-managed state |
| `podm status` | Daemon state, socket, LaunchAgent, running containers |
| `podm doctor` | Diagnose the install (socket reachable, CLIs found, versions) |
| `podm version` | Version and build info |
| `podm serve` | Run the API daemon in the foreground (what launchd uses) |

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `PODM_IDLE_EXIT_SECS` | launchd default | Seconds of zero connections **and** zero running containers before `podmd` exits (the launchd LaunchAgent restarts it on demand) |
| `PODM_DNS_PORT` | `2054` | Host-side port of podm's embedded DNS resolver |
| `PODM_DNS_UPSTREAM` | `1.1.1.1:53` | Upstream resolver for names the embedded DNS server cannot answer locally: IPv4 literal with optional `:port` (default `1.1.1.1:53`); `--dns-upstream` flag wins, invalid env warns and keeps the default |
| `PODM_CLEAN_VOLUMES` | enabled | Set `false` to opt out of removing `/lost+found` from named-volume EXT4 images (it breaks Postgres `initdb`; per-volume opt-out label: `podm.clean-volumes=false`) |
| `CONTAINER_HOST` / `DOCKER_HOST` | set by shim | Point the real CLIs at `unix://$HOME/.podm/container.sock` — normally you never set these yourself |

### Volume sync modes

Named volumes are EXT4 images mounted over virtiofs. Write-durability vs speed is
tunable per volume (or daemon-wide):

```bash
docker volume create -o sync=fsync mydata   # honor guest fsyncs (durable)
```

| Mode | Meaning |
|---|---|
| `nosync` | default; fastest for write-heavy workloads (~1.5×) |
| `fsync` | honors guest `fsync` for durability |
| `full` | fully synchronous writes |

Daemon-wide default: `podmd --volume-sync <mode>`.

## Multi-arch builds

Build for the whole matrix — including architectures your Mac cannot natively or
via-Rosetta run — with one command:

```bash
podman build --platform linux/amd64,linux/arm64,linux/ppc64le,linux/s390x \
  --manifest myapp .
podman manifest push myapp registry.example.com/myapp:latest
```

How it works:

- **`linux/arm64`** — native on Apple Silicon.
- **`linux/amd64`** — Rosetta 2 translates the x86_64 userland inside the arm64
  kernel; build and run both work (`uname -m` reports `x86_64`).
- **`linux/ppc64le`, `s390x`, `riscv64`, …** — no Rosetta exists for these. Upstream
  `apple/container` cannot execute their `RUN` steps
  ([apple/container#1496](https://github.com/apple/container/issues/1496)); podm
  solves it by provisioning a **second BuildKit builder VM with QEMU binfmt
  registered**, classifying each requested platform as Rosetta-eligible vs
  QEMU-only, splitting mixed `--platform` builds across both builders
  concurrently, and merging the halves into a single image index.

Details and examples: [docs/multi-arch.md](docs/multi-arch.md).

## How it works

```
podman ─┐                                                ┌─ Docker Engine API (/v1.32–v1.51)
docker ─┼─ podm (client shim, argv0) ──────────────────┤                     one socket,
        │   exec real CLI with CONTAINER_HOST/DOCKER_HOST ├─ podman libpod API (/libpod/*)  both dialects
        ▼                                                 ▼
   unix socket  ~/.podm/container.sock
        │
   launchd (LaunchAgent io.github.podm.daemon) — on-demand, idle-exit → 0 MB daemon RAM
        │
   podmd (Swift/Vapor daemon)
        │
   apple/containerization — one lightweight Linux VM per container
   (container-apiserver, BuildKit builder VMs, Rosetta + QEMU for multi-arch)
```

| Piece | What it is |
|---|---|
| `podm` | Client shim: dispatches by `argv[0]` (`podm`/`podman`/`docker` symlinks), ensures the daemon is awake, execs the real `podman`/`docker` CLI with the right environment |
| `podmd` | Swift daemon (Vapor) serving Docker Engine API v1.51 + libpod API on one unix socket (`~/.podm/container.sock`) |
| launchd | `LaunchAgent` managing `podmd` — started on demand, woken via `launchctl kickstart`, exits after `PODM_IDLE_EXIT_SECS` idle (0 connections + 0 running containers) |

The one-socket-two-dialects point: `docker`, `compose`, `docker-py`, test tooling
and friends speak Docker Engine API on `/v1.x/*`; the `podman` CLI speaks podman
REST on `/libpod/*`. Both hit `~/.podm/container.sock` and see the same
containers, images, volumes and networks. Deep dive:
[docs/architecture.md](docs/architecture.md).

## Limitations

Honest, inherited-from-the-model limits (details in
[docs/no-machine.md](docs/no-machine.md)):

| Limitation | Status |
|---|---|
| `podman pause` / `docker pause` | Not supported — a microVM cannot be frozen; the API returns an explicit error |
| `--privileged` | Mapped to all capabilities **inside the guest VM** — there is no true host-privileged |
| Container resources (`--memory`, `--cpus`) | Fixed at create time; `update` only handles restart policies |
| Memory ballooning | Partial — guest-freed pages are not always returned to the host |
| Platform | macOS 26+ (Tahoe), Apple Silicon only — hard boundary from Apple's frameworks |
| Pods / `podman kube play` | Not available — no pod primitive in apple container |
| Exotic-arch `RUN` (ppc64le, s390x, …) | Build-time only, via the QEMU builder VM; running such containers is not supported |
| `podman commit`, `podman diff` | API routes exist but return "not implemented" |
| Container startup latency | ~1s per container (VM boot) vs ~320ms on Docker Desktop |

## Comparison

| | podm | podman machine | Docker Desktop | colima | socktainer | apple `container` | us/mocker |
|---|---|---|---|---|---|---|---|
| Model | microVM per container, on-demand daemon | shared Linux VM | shared VM + dockerd | shared Linux VM (Lima) | microVM per container, resident daemon | microVM per container | microVM per container |
| Idle RAM | ~0 (25 MB Apple helpers) | multi-GB pinned VM | GB-scale | multi-GB pinned VM | ~25 MB helpers + daemon | ~25 MB helpers | ~25 MB helpers |
| `podman` CLI | ✅ stock | ✅ stock (machine UX) | ❌ | ✅ (machine UX) | ❌ | ❌ | ❌ |
| `docker` CLI / Engine API | ✅ stock | via docker socket in VM | ✅ | ✅ | ✅ (partial: 52/69 endpoints) | ❌ | ❌ (own CLI only) |
| libpod API | ✅ | ✅ | ❌ | ❌ | ❌ (upstream) | ❌ | ❌ |
| Multi-arch (ppc64le/s390x) | ✅ QEMU builder | manual | manual | manual | ❌ arm64/amd64 (Rosetta) only | ❌ arm64/amd64 (Rosetta) only | ❌ |
| No machine concept / lifecycle | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| License | Apache-2.0 | Apache-2.0 | proprietary | MIT | Apache-2.0 | Apache-2.0 | AGPL-3.0 |

No other project does the union: **stock docker+podman CLIs + dual-API socket +
microVM-per-container + no resident daemon.** See
[RESEARCH.md](RESEARCH.md) for the full landscape study.

## FAQ

**Why the name `podm`?**
Type `podm` and hit TAB: the shell completes to `podman` — which is exactly the
point. `podm` is the short, nimble form; `podm` + TAB is the full podman
experience (the persona symlink). And the name states the mission: **podman's
promise, true on Mac.**

**Is this a fork?**
The server (`podmd`) was imported from
[socktainer](https://github.com/socktainer/socktainer) (Apache-2.0) with its podman
libpod API layer and multi-arch build support, then rebranded and extended. See
[NOTICE](NOTICE) for attribution of socktainer and Apple code; the license stays
Apache-2.0.

**Does kind / testcontainers / docker-py work?**
Unverified, and in places genuinely hard: anything needing true host-privileged
behavior (kind, k3s-in-container) only gets all-caps *inside the guest VM*, which is
not the same thing. Plain API clients (docker-py, compose, Supabase-style tools that
read `/var/run/docker.sock` inside a container — podm vsock-relays that socket)
have the best odds. Test before relying on it; report what you find.

**Where does my data live?**
Everything podm-managed is under `~/.podm` (socket, lock, client config) and
Apple container's own image/content store. No data in `/var` except the optional
`/var/run/docker.sock` symlink.

**Why not just use `container system stop` when idle?**
You can — podm only needs Apple's helpers while containers/builds run and
auto-starts them on demand. The ~25 MB helper footprint is the floor the platform
gives you; the point is nothing above it stays resident.

## Route coverage

<!-- podm:route-coverage:start -->
<!-- Generated by `podmd --docgen` in CI — edits between the markers are
     overwritten on the next run. Regenerate locally with:
     swift build && .build/debug/podmd --docgen /tmp/podm-docs -->

185 routes registered (149 supported, 36 deliberately not
implemented — every gap carries its reason and its tracking context in
[RouteSupportManifest.swift](Sources/podmd/Utilities/RouteSupportManifest.swift)).
Full, searchable version: **[podm route coverage site](https://github.tig.pw/podm/)**.

| Status | Method | Route | Dialect | Reason |
|---|---|---|---|---|
| ✅ | `GET` | `/_ping` | docker |  |
| ✅ | `HEAD` | `/_ping` | docker |  |
| ✅ | `POST` | `/auth` | docker |  |
| ✅ | `POST` | `/build` | docker |  |
| ✅ | `POST` | `/build/prune` | docker |  |
| ✅ | `POST` | `/commit` | docker |  |
| ✅ | `GET` | `/configs` | docker |  |
| ✅ | `POST` | `/configs/create` | docker |  |
| ✅ | `DELETE` | `/configs/{id}` | docker |  |
| ✅ | `GET` | `/configs/{id}` | docker |  |
| ✅ | `POST` | `/containers/create` | docker |  |
| ✅ | `GET` | `/containers/json` | docker |  |
| ✅ | `POST` | `/containers/prune` | docker |  |
| ✅ | `GET` | `/containers/{id:.*}/archive` | docker |  |
| ✅ | `HEAD` | `/containers/{id:.*}/archive` | docker |  |
| ✅ | `PUT` | `/containers/{id:.*}/archive` | docker |  |
| ✅ | `DELETE` | `/containers/{id}` | docker |  |
| ✅ | `POST` | `/containers/{id}/attach` | docker |  |
| ✅ | `GET` | `/containers/{id}/attach/ws` | docker |  |
| ✅ | `GET` | `/containers/{id}/changes` | docker |  |
| ✅ | `POST` | `/containers/{id}/exec` | docker |  |
| ✅ | `GET` | `/containers/{id}/export` | docker |  |
| ✅ | `GET` | `/containers/{id}/json` | docker |  |
| ✅ | `POST` | `/containers/{id}/kill` | docker |  |
| ✅ | `GET` | `/containers/{id}/logs` | docker |  |
| 🚫 | `POST` | `/containers/{id}/pause` | docker | Blocked upstream: apple/container exposes no pause XPC route; apple/containerization#366 removed the LinuxContainer/LinuxPod pause/resume API (suspected vended-vsock EBADF asserts), while the underlying VZ pause/resume VM primitives remain (apple/containerization#998). |
| ✅ | `POST` | `/containers/{id}/rename` | docker |  |
| ✅ | `POST` | `/containers/{id}/resize` | docker |  |
| ✅ | `POST` | `/containers/{id}/restart` | docker |  |
| ✅ | `POST` | `/containers/{id}/start` | docker |  |
| ✅ | `GET` | `/containers/{id}/stats` | docker |  |
| ✅ | `POST` | `/containers/{id}/stop` | docker |  |
| ✅ | `GET` | `/containers/{id}/top` | docker |  |
| 🚫 | `POST` | `/containers/{id}/unpause` | docker | Blocked upstream: apple/container exposes no pause XPC route; apple/containerization#366 removed the LinuxContainer/LinuxPod pause/resume API (suspected vended-vsock EBADF asserts), while the underlying VZ pause/resume VM primitives remain (apple/containerization#998). |
| ✅ | `POST` | `/containers/{id}/update` | docker |  |
| ✅ | `POST` | `/containers/{id}/wait` | docker |  |
| ✅ | `GET` | `/distribution/{name:.*}/json` | docker |  |
| ✅ | `GET` | `/events` | docker |  |
| ✅ | `GET` | `/exec/{id}/json` | docker |  |
| ✅ | `POST` | `/exec/{id}/resize` | docker |  |
| ✅ | `POST` | `/exec/{id}/start` | docker |  |
| ✅ | `POST` | `/images/create` | docker |  |
| ✅ | `GET` | `/images/get` | docker |  |
| ✅ | `GET` | `/images/json` | docker |  |
| ✅ | `POST` | `/images/load` | docker |  |
| ✅ | `POST` | `/images/prune` | docker |  |
| ✅ | `GET` | `/images/search` | docker |  |
| ✅ | `DELETE` | `/images/{name:.*}` | docker |  |
| ✅ | `GET` | `/images/{name:.*}/get` | docker |  |
| ✅ | `GET` | `/images/{name:.*}/history` | docker |  |
| ✅ | `GET` | `/images/{name:.*}/json` | docker |  |
| ✅ | `POST` | `/images/{name:.*}/push` | docker |  |
| ✅ | `POST` | `/images/{name:.*}/tag` | docker |  |
| ✅ | `GET` | `/info` | docker |  |
| ✅ | `GET` | `/networks` | docker |  |
| ✅ | `POST` | `/networks/create` | docker |  |
| ✅ | `POST` | `/networks/prune` | docker |  |
| ✅ | `DELETE` | `/networks/{id}` | docker |  |
| ✅ | `GET` | `/networks/{id}` | docker |  |
| ✅ | `POST` | `/networks/{id}/connect` | docker |  |
| ✅ | `POST` | `/networks/{id}/disconnect` | docker |  |
| 🚫 | `GET` | `/nodes` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `GET` | `/nodes/{id}` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `POST` | `/nodes/{id}/update` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `GET` | `/plugins` | docker | The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility. |
| 🚫 | `POST` | `/plugins/create` | docker | The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility. |
| 🚫 | `GET` | `/plugins/privileges` | docker | The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility. |
| 🚫 | `POST` | `/plugins/pull` | docker | The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility. |
| 🚫 | `GET` | `/plugins/{name}` | docker | The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility. |
| 🚫 | `POST` | `/plugins/{name}/disable` | docker | The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility. |
| 🚫 | `POST` | `/plugins/{name}/enable` | docker | The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility. |
| 🚫 | `GET` | `/plugins/{name}/json` | docker | The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility. |
| 🚫 | `POST` | `/plugins/{name}/push` | docker | The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility. |
| 🚫 | `POST` | `/plugins/{name}/set` | docker | The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility. |
| 🚫 | `POST` | `/plugins/{name}/upgrade` | docker | The docker plugin system is out of scope; the route answers not-implemented for CLI compatibility. |
| ✅ | `GET` | `/secrets` | docker |  |
| ✅ | `POST` | `/secrets/create` | docker |  |
| ✅ | `DELETE` | `/secrets/{id}` | docker |  |
| ✅ | `GET` | `/secrets/{id}` | docker |  |
| 🚫 | `GET` | `/services` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `POST` | `/services/create` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `GET` | `/services/{id}` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `GET` | `/services/{id}/logs` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `POST` | `/services/{id}/update` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `GET` | `/session` | docker | dockerd's buildx session channel is not supported; the route answers not-supported for CLI compatibility. |
| 🚫 | `GET` | `/swarm` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `POST` | `/swarm/init` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `POST` | `/swarm/join` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `POST` | `/swarm/leave` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `POST` | `/swarm/unlock` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `GET` | `/swarm/unlockkey` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| 🚫 | `POST` | `/swarm/update` | docker | Swarm object — single-node Apple container has no swarm mode; the route exists for CLI compatibility. |
| ✅ | `GET` | `/system/df` | docker |  |
| 🚫 | `GET` | `/tasks` | docker | Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility. |
| 🚫 | `GET` | `/tasks/{id}` | docker | Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility. |
| 🚫 | `GET` | `/tasks/{id}/logs` | docker | Swarm object — Apple container has no swarm mode; the route answers moby's documented 503 for CLI compatibility. |
| ✅ | `GET` | `/version` | docker |  |
| ✅ | `GET` | `/volumes` | docker |  |
| ✅ | `POST` | `/volumes/create` | docker |  |
| ✅ | `POST` | `/volumes/prune` | docker |  |
| ✅ | `DELETE` | `/volumes/{name}` | docker |  |
| ✅ | `GET` | `/volumes/{name}` | docker |  |
| ✅ | `GET` | `/libpod/_ping` | libpod |  |
| ✅ | `HEAD` | `/libpod/_ping` | libpod |  |
| ✅ | `POST` | `/libpod/auth` | libpod |  |
| ✅ | `POST` | `/libpod/build` | libpod |  |
| ✅ | `POST` | `/libpod/commit` | libpod |  |
| ✅ | `POST` | `/libpod/containers/create` | libpod |  |
| ✅ | `GET` | `/libpod/containers/json` | libpod |  |
| ✅ | `POST` | `/libpod/containers/prune` | libpod |  |
| ✅ | `GET` | `/libpod/containers/stats` | libpod |  |
| ✅ | `GET` | `/libpod/containers/{id:.*}/archive` | libpod |  |
| ✅ | `HEAD` | `/libpod/containers/{id:.*}/archive` | libpod |  |
| ✅ | `PUT` | `/libpod/containers/{id:.*}/archive` | libpod |  |
| ✅ | `DELETE` | `/libpod/containers/{id}` | libpod |  |
| ✅ | `POST` | `/libpod/containers/{id}/attach` | libpod |  |
| ✅ | `GET` | `/libpod/containers/{id}/changes` | libpod |  |
| ✅ | `POST` | `/libpod/containers/{id}/exec` | libpod |  |
| ✅ | `GET` | `/libpod/containers/{id}/exists` | libpod |  |
| ✅ | `GET` | `/libpod/containers/{id}/export` | libpod |  |
| ✅ | `GET` | `/libpod/containers/{id}/json` | libpod |  |
| ✅ | `POST` | `/libpod/containers/{id}/kill` | libpod |  |
| ✅ | `GET` | `/libpod/containers/{id}/logs` | libpod |  |
| 🚫 | `POST` | `/libpod/containers/{id}/pause` | libpod | Blocked upstream: apple/container exposes no pause XPC route; apple/containerization#366 removed the LinuxContainer/LinuxPod pause/resume API (suspected vended-vsock EBADF asserts), while the underlying VZ pause/resume VM primitives remain (apple/containerization#998). |
| ✅ | `POST` | `/libpod/containers/{id}/rename` | libpod |  |
| ✅ | `POST` | `/libpod/containers/{id}/restart` | libpod |  |
| ✅ | `POST` | `/libpod/containers/{id}/start` | libpod |  |
| ✅ | `GET` | `/libpod/containers/{id}/stats` | libpod |  |
| ✅ | `POST` | `/libpod/containers/{id}/stop` | libpod |  |
| ✅ | `GET` | `/libpod/containers/{id}/top` | libpod |  |
| 🚫 | `POST` | `/libpod/containers/{id}/unpause` | libpod | Blocked upstream: apple/container exposes no pause XPC route; apple/containerization#366 removed the LinuxContainer/LinuxPod pause/resume API (suspected vended-vsock EBADF asserts), while the underlying VZ pause/resume VM primitives remain (apple/containerization#998). |
| ✅ | `POST` | `/libpod/containers/{id}/update` | libpod |  |
| ✅ | `POST` | `/libpod/containers/{id}/wait` | libpod |  |
| ✅ | `GET` | `/libpod/containers/{name}/healthcheck` | libpod |  |
| ✅ | `GET` | `/libpod/events` | libpod |  |
| ✅ | `GET` | `/libpod/exec/{id}/json` | libpod |  |
| ✅ | `POST` | `/libpod/exec/{id}/start` | libpod |  |
| ✅ | `GET` | `/libpod/images/export` | libpod |  |
| ✅ | `POST` | `/libpod/images/import` | libpod |  |
| ✅ | `GET` | `/libpod/images/json` | libpod |  |
| ✅ | `POST` | `/libpod/images/load` | libpod |  |
| ✅ | `POST` | `/libpod/images/prune` | libpod |  |
| ✅ | `POST` | `/libpod/images/pull` | libpod |  |
| ✅ | `DELETE` | `/libpod/images/remove` | libpod |  |
| ✅ | `GET` | `/libpod/images/search` | libpod |  |
| ✅ | `DELETE` | `/libpod/images/{name:.*}` | libpod |  |
| ✅ | `GET` | `/libpod/images/{name:.*}/exists` | libpod |  |
| ✅ | `GET` | `/libpod/images/{name:.*}/get` | libpod |  |
| ✅ | `GET` | `/libpod/images/{name:.*}/history` | libpod |  |
| ✅ | `GET` | `/libpod/images/{name:.*}/json` | libpod |  |
| ✅ | `POST` | `/libpod/images/{name:.*}/push` | libpod |  |
| ✅ | `POST` | `/libpod/images/{name:.*}/tag` | libpod |  |
| ✅ | `POST` | `/libpod/images/{name:.*}/untag` | libpod |  |
| ✅ | `GET` | `/libpod/info` | libpod |  |
| ✅ | `POST` | `/libpod/local/images/load` | libpod |  |
| ✅ | `DELETE` | `/libpod/manifests/{name:.*}` | libpod |  |
| ✅ | `POST` | `/libpod/manifests/{name:.*}` | libpod |  |
| ✅ | `PUT` | `/libpod/manifests/{name:.*}` | libpod |  |
| ✅ | `GET` | `/libpod/manifests/{name:.*}/exists` | libpod |  |
| ✅ | `GET` | `/libpod/manifests/{name:.*}/json` | libpod |  |
| ✅ | `POST` | `/libpod/manifests/{name:.*}/push` | libpod |  |
| ✅ | `POST` | `/libpod/manifests/{name:.*}/registry/{destination:.*}` | libpod |  |
| ✅ | `POST` | `/libpod/networks/create` | libpod |  |
| ✅ | `GET` | `/libpod/networks/json` | libpod |  |
| ✅ | `POST` | `/libpod/networks/prune` | libpod |  |
| ✅ | `DELETE` | `/libpod/networks/{id}` | libpod |  |
| ✅ | `GET` | `/libpod/networks/{id}/json` | libpod |  |
| ✅ | `POST` | `/libpod/networks/{name}/connect` | libpod |  |
| ✅ | `POST` | `/libpod/networks/{name}/disconnect` | libpod |  |
| ✅ | `GET` | `/libpod/networks/{name}/exists` | libpod |  |
| ✅ | `POST` | `/libpod/secrets/create` | libpod |  |
| ✅ | `GET` | `/libpod/secrets/json` | libpod |  |
| ✅ | `DELETE` | `/libpod/secrets/{name}` | libpod |  |
| ✅ | `GET` | `/libpod/secrets/{name}/exists` | libpod |  |
| ✅ | `GET` | `/libpod/secrets/{name}/json` | libpod |  |
| ✅ | `GET` | `/libpod/system/df` | libpod |  |
| ✅ | `GET` | `/libpod/version` | libpod |  |
| ✅ | `POST` | `/libpod/volumes/create` | libpod |  |
| ✅ | `GET` | `/libpod/volumes/json` | libpod |  |
| ✅ | `POST` | `/libpod/volumes/prune` | libpod |  |
| ✅ | `DELETE` | `/libpod/volumes/{name}` | libpod |  |
| ✅ | `GET` | `/libpod/volumes/{name}/exists` | libpod |  |
| ✅ | `GET` | `/libpod/volumes/{name}/json` | libpod |  |

<!-- podm:route-coverage:end -->

## Project status

Early stage. The daemon's API surface (Docker Engine + libpod, multi-arch builds)
is imported and working; the client shim and launchd on-demand lifecycle are the
new work landing now. Known gaps: `podman healthcheck run`, `manifest annotate`,
all-container `podman stats`, and 17 of 69 Docker Engine endpoints still partial
(upstream socktainer [#14](https://github.com/socktainer/socktainer/issues/14)).

### Roadmap (ideas, unordered)

- `podman healthcheck run` (exec-based on-demand probe)
- `manifest annotate`, all-container `/libpod/containers/stats`
- Docker Engine API parity completion (socktainer #14, #90)
- Exotic-arch *run* (qemu-user registered inside container VMs)
- Optional pods modeled as multi-VM + shared vmnet + shared volumes

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). DCO sign-off required on every commit.

## License

Apache-2.0 — same as socktainer. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
