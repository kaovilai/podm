# pacman research: podman/docker-identical UX on macOS, no machine, no remote

Goal: `pacman` CLI on macOS that behaves exactly like podman on Linux — no
`machine`, no `remote` — with maximal flag/command coverage of **both** podman
and docker dialects, plus socket compat usable by both. Non-negotiable: no
dedicated RAM-resident daemon (podman/Docker Desktop model); microVM-per-
container (Apple `container` model) is acceptable.

Date: 2026-11-09. Machine context: macOS 26.7.1, arm64, apple/container 1.6.1
installed, pacman built from `kaovilai/pacman` fork.

---

## 1. Verdict (TL;DR)

**Apple containers is the right runtime shape, and the server half of pacman
already exists in the `kaovilai/pacman` fork.** The fork serves Docker
Engine API v1.51 *and* the podman libpod API on one unix socket on top of
apple/containerization, with multi-arch builds (Rosetta + QEMU builder VMs).
What's missing for pacman is: (a) the CLI personality — a `pacman` binary
presenting the union of docker+podman command trees with zero-config socket
discovery, (b) launchd socket activation so the API daemon consumes zero RAM
when idle, and (c) sockets placed at the conventional paths
(`$XDG_RUNTIME_DIR/podman/podman.sock`, `/var/run/docker.sock`) so unmodified
ecosystem tools find it.

Measured idle footprint of apple's services on this machine (no containers
running): `container-apiserver` 9.8 MB + `container-core-images` 10.0 MB +
`container-network-vmnet` 4.7 MB ≈ **25 MB total, 0% CPU** — versus podman
machine's pinned multi-GB VM or Docker Desktop's VM+dockerd. `container system
stop` releases even that.

---

## 2. Why daemonless-on-host is impossible and microVM-per-container is the only fit

Linux containers are Linux kernel features (namespaces, cgroups, overlayfs,
binfmt). podman on Linux is daemonless *because* it fork/execs into those host
kernel features. macOS has none of them, so every macOS design is one of:

| Model | Who | Fails our requirements? |
|---|---|---|
| Shared Linux VM + daemon inside | podman machine, colima/Lima, Docker Desktop, OrbStack, Rancher Desktop, Finch | Yes — that *is* a machine: RAM pinned while idle, guest disk to manage, machine lifecycle exposed to UX |
| VM-per-container, launchd-managed | apple `container` | No — no machine concept, no resident heavy daemon, memory overcommits and pages out, VMs die with their container |
| (nothing else exists) | — | qemu-user on macOS host without a VM cannot work (needs Linux kernel) |

Apple's Virtualization framework gives the second model its teeth: lightweight
VMs booting in ~1s, memory overcommit (macOS schedules/swaps VM pages against
physical RAM like any process), virtiofs host mounts, vmnet networking, vsock
I/O, XPC + launchd integration, Keychain for registry creds, Rosetta for x86_64
userland.

Per-container VM trade-offs to accept: ~1s container startup vs ~320ms Docker
Desktop (mocker's hyperfine numbers); no pause/unpause primitive (VMs can't be
frozen — pacman returns "not supported"); VM resources (memory/cpus) fixed
at create time, `update` only handles restart policies; partial memory
ballooning (guest-freed pages not returned to host); single global hostname
namespace (pacman's embedded DNS works around it for compose).

Platform ceiling: **macOS 26+ and Apple Silicon only.** containerization does
not support Intel Macs, and Rosetta-for-Linux doesn't exist there. This is a
hard boundary inherited from Apple.

## 3. Multi-arch (build & run)

- `linux/arm64`: native.
- `linux/amd64`: Rosetta 2 — userland translation inside an arm64 kernel.
  `container run --arch amd64` and builds both work; `uname -m` reports x86_64.
  Edge cases: anything needing a true x86_64 kernel or ptrace-heavy tooling.
- `linux/ppc64le`, `s390x`, `riscv64`, …: **no Rosetta.** Upstream
  apple/container cannot execute `RUN` for these (Exec format error,
  apple/container#1496 still open). The kaovilai/pacman fork already
  solves this: commit `6c770e2` provisions a second BuildKit builder VM with
  QEMU binfmt registered, classifies each requested platform as
  Rosetta-eligible vs QEMU-only, splits mixed `--platform` requests across
  both builders concurrently, and merges the halves into one image index.
  That is the same trick as qemu-user-static on a Linux host and covers the
  OADP-style multi-arch (amd64+arm64+ppc64le+s390x) build matrix locally.
- Run (not build) of exotic arch: would need qemu-user registered inside each
  container VM — possible future work, not needed for the build use-case.

## 4. Landscape survey — promising projects and where they fail

| Project | Model | Where it fails our requirements |
|---|---|---|
| **apple/container** (github.com/apple/container, Apache-2.0, macOS 26+) | VM-per-container on containerization (Swift), launchd XPC services, BuildKit-in-VM builder, OCI images, `cluster` (k8s) | Right runtime, wrong CLI: own dialect (`container ls`, `container image pull`…), no Docker/podman API, no socket compat — nothing in the docker/podman ecosystem can talk to it |
| **pacman** upstream (github.com/socktainer/socktainer, Apache-2.0, brew) | Daemon (Vapor/NIO) exposing Docker Engine API v1.51 on a unix socket over containerization; auto-starts `container system`; docker context autoregistration; embedded DNS + compose service discovery; volume sync modes | Partial Docker API (52/69 endpoints, #14; 36/43 events, #90); libpod API tracked open in #201 (upstream hasn't shipped it); resident daemon (manual/brew services start); native-arch builds only upstream |
| **kaovilai/pacman** fork (13 commits ahead) | Upstream + ~complete libpod API (65 route files: containers/images/volumes/networks/manifests/exec/events/auth/system-df/build) + multi-arch builds with Rosetta/QEMU split + manifest-list workflows (`--platform a,b --manifest name`) + CI podman-CLI verification | This *is* pacman's server half. Remaining gaps: `podman healthcheck run` (needs exec-based on-demand probe, not cached status), `manifest annotate`, all-container `/libpod/containers/stats`; docker-side 17 partial endpoints per #14; daemon still resident, not launchd-activated |
| **us/mocker** (373★, AGPL-3.0, Swift) | Docker-dialect CLI on containerization; shells out to `container` CLI for lifecycle, ImageStore directly for images; own compose v2 impl; per-port userspace proxy subprocesses for `-p` | No socket / no Engine API — only the `mocker` binary itself can drive it (no docker CLI, compose binary, docker-py, testcontainers, kind); no podman support at all; AGPL; proxy-per-port is a hack we'd not want |
| **container-compose/cli** (18★) | compose wrapper over apple container | Peripheral: compose-only, no API, no podman |
| **andrew-waters/orchard** (1.7k★) | Native UI over Apple containers ("docker desktop replacement") | UI only, not a CLI/API play |
| **Podman Desktop extension-apple-container** | Visualizes Apple containers/images in Podman Desktop | Uses pacman underneath — confirms pacman as the de-facto API layer |
| **colima / Lima** (31.6k★ / 22.3k★) | Single shared Linux VM (qemu/vz) hosting dockerd/containerd | Machine by another name: pinned RAM while idle, guest disk lifecycle, "colima start" UX — exactly what we're eliminating |
| **krunkit / libkrun / krunvm** | podman machine provider using libkrun microVMs | Still a *shared* machine VM per podman install, machine UX retained |
| **OrbStack / Rancher Desktop / Finch / Docker Desktop** | Shared VM + daemon, varying polish/proprietary status | All fail the no-machine/no-resident-daemon non-negotiable |

No project was found that does what pacman wants: **union CLI (docker+podman
dialects) + dual-API socket + microVM-per-container + no resident daemon.**
pacman(fork) covers the socket; mocker covers (docker-only) CLI dialect;
apple/container covers the runtime. The composition is the novel work.

## 5. Recommended pacman architecture

```
┌─ pacman CLI (union dialect: podman command tree + docker-only commands) ─┐
│  zero-config: default connection baked (like podman machine registers    │
│  itself in containers.conf — minus the machine)                          │
├─ unix socket(s) — ONE server, BOTH dialects ─────────────────────────────┤
│  /v1.x/*   Docker Engine API (docker CLI, compose, docker-py, …)         │
│  /libpod/* podman REST v4/v5   (podman CLI)                              │
│  launchd socket activation: launchd holds the socket, spawns the API     │
│  server on first connection, idle-exit → 0 bytes RAM when unused         │
│  (today: kaovilai/pacman daemon; NIO can bind a launchd-passed fd)   │
├─ socket placement for ecosystem compat ──────────────────────────────────┤
│  $XDG_RUNTIME_DIR/podman/podman.sock  ← podman client's default: stock   │
│                                          podman works with NO env vars   │
│  /var/run/docker.sock (symlink, one-time sudo) ← docker default context  │
│                                          + tools hardcoding the path     │
├─ runtime: apple/containerization (apple/container's own backend) ────────┤
│  container-apiserver (launchd, ~10MB) + per-container VMs + BuildKit     │
│  builder VMs (Rosetta + QEMU binfmt for multi-arch)                      │
└───────────────────────────────────────────────────────────────────────────┘
```

### CLI layer — two viable paths (recommend A first, evolve to B)

**A. Exec-shim (weeks, zero maintenance treadmill):** `pacman` sets
`CONTAINER_HOST`/`DOCKER_HOST` to its socket and execs the *real* podman /
docker CLI. "Maximal support of all flags and commands from both" is inherited
for free — it's the actual CLIs, forever current. Persona dispatch must come
from argv[0], not aliases: install `podman → pacman` and `docker → pacman`
symlinks ahead of the real binaries (a zsh *alias* erases the distinction —
`alias podman=pacman` and `alias docker=pacman` collapse to one argv[0]).
Podman's darwin build is the full CLI in remote-client mode; registered as the
default connection in containers.conf it needs no `machine`, no env, and never
prints "machine"/"remote" concepts in the happy path. `podman machine`
subcommand still exists in the real CLI — hide/neutralize in the symlinked
path if we care (it would just operate on real machines if any exist).

**B. Vendored CLI (months, one binary/one dialect-union):** fork podman's Go
cobra tree (darwin remote-client build), add the docker-only commands
(`compose` → delegate to compose provider talking to our socket, `context` →
map to `system connection`, `builder`, …), hide `machine`. One `pacman`
binary, no dependency on installed docker/podman. Permanent cost: tracking
two CLIs' flag surfaces — the exact treadmill "maximally supporting all
flags" implies. mocker (373★, AGPL) proves a from-scratch Swift union CLI is
possible but also shows the cost: no API surface, proxy hacks, AGPL blocks
code reuse anyway.

### Daemon layer — satisfying the non-negotiable

- Today: pacman runs as a resident daemon (Vapor server, ~tens of MB) +
  apple's ~25MB of XPC helpers.
- pacman: **launchd socket activation** (LaunchAgent with `Sockets` key;
  launchd owns the listening socket, spawns the server on first connection).
  Combined with an idle-exit (no connections + no running containers → exit),
  idle RAM is exactly 0. Apple's own helpers can additionally be left
  `container system stop`-ed when nothing runs (pacman already
  auto-starts it on demand).
- This is categorically different from Docker Desktop/podman machine: nothing
  pins GBs; the only persistent state is on disk (image/content store).

### What "no machine / no remote" means concretely

- No `machine` subcommand in the union CLI; no connection-setup steps;
  errors never mention machines or remote hosts.
- First-run bootstrap = `pacman install` (one-time): place symlinks/sockets,
  load the LaunchAgent, optionally `sudo ln -s` for /var/run/docker.sock.

## 6. Known gaps / open items (priority order)

1. **CLI layer does not exist** — the actual pacman work (path A or B above).
2. **launchd socket activation** for the API server (NIO: bind to
   launchd-inherited fd instead of creating the socket).
3. libpod API remainder (fork): `podman healthcheck run` (exec-based on-demand
   probe), `manifest annotate`, all-container `/libpod/containers/stats`
   (needs host-CPU-time accounting — deliberately not faked today).
4. Docker Engine API: 17 of 69 applicable endpoints still partial (#14);
   events 7 of 43 (#90).
5. **pods / `podman kube play`**: no pod primitive in apple container.
   Modelable as compose-style multi-VM + shared vmnet + shared volumes at the
   API layer if ever needed; currently intentionally N/A in the fork.
6. **privileged-heavy tooling (kind, k3s-in-container)**: VM model grants
   capabilities inside the guest (fork maps `--privileged` to all-caps, pacman#364)
   but there is no true host-privileged; kind compatibility unproven — test
   before promising.
7. **Intel Macs**: unsupported, hard boundary (containerization + Rosetta).
8. **Name collision**: `pacman` is Arch Linux's package manager — brew
   formula namespace, docs/SEO confusion, and muscle-memory hazard when
   pairing with Arch-based container images (host-side only; inside VMs the
   guest pacman is unaffected). Worth a conscious accept/rename decision.

## 7. Sources

- apple/container — https://github.com/apple/container (README; docs/technical-overview.md; docs/command-reference.md; docs/multiplatform-images.md; docs/resource-usage.md)
- apple/containerization — https://github.com/apple/containerization
- apple/container#1496 — QEMU for exotic arch in build VM (open): https://github.com/apple/container/issues/1496
- pacman upstream — https://github.com/socktainer/socktainer (README; #14 Docker API parity; #90 events parity; #201 libpod API tracking)
- kaovilai/pacman fork — https://github.com/kaovilai/pacman (local checkout; PODMAN_API_AUDIT.md; commit 6c770e2 multi-platform Rosetta/QEMU build split)
- us/mocker — https://github.com/us/mocker (README: architecture, exotic-arch limits, benchmarks)
- colima — https://github.com/abiosoft/colima ; Lima — https://github.com/lima-vm/lima ; krunkit — https://github.com/libkrun/krunkit ; Rancher Desktop — https://github.com/rancher-sandbox/rancher-desktop ; Finch — https://github.com/runfinch/finch
- Podman Desktop apple-container extension (uses pacman) — https://github.com/podman-desktop/extension-apple-container
- container-compose — https://github.com/container-compose/cli ; orchard — https://github.com/andrew-waters/orchard
- Local measurements: `ps` RSS of container-apiserver/core-images/network-vmnet on this Mac (2026-11-09); mocker's published hyperfine startup numbers.
