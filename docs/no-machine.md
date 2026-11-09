# No machine, no remote — the philosophy

Why podm exists, with numbers. Measurements are from
[RESEARCH.md](../RESEARCH.md) (macOS 26.7.1, arm64, apple/container 1.6.1,
2026-11-09).

## The problem with every other macOS option

Linux containers are Linux kernel features: namespaces, cgroups, overlayfs,
binfmt. `podman` on Linux is daemonless *because* it fork/execs straight into
host kernel features. macOS has none of them, so every macOS container runtime
is secretly one of two shapes:

| Model | Who uses it | Why it fails us |
|---|---|---|
| Shared Linux VM + daemon inside | podman machine, colima/Lima, Docker Desktop, OrbStack, Rancher Desktop, Finch | That *is* a machine: RAM pinned while idle, guest disk to manage, machine lifecycle exposed in the UX (`podman machine start`, `colima start`, "Docker Desktop is starting…") |
| VM-per-container, launchd-managed | apple `container` | No machine concept, no resident heavy daemon, memory overcommits, VMs die with their container |

There is no third option — qemu-user on the macOS host without a VM cannot
work (it needs a Linux kernel).

podm takes the second model and fixes its one real problem — the CLI/API
surface — instead of taking the first model and hiding the machine.

## What "no machine / no remote" means concretely

Not marketing. Checkable properties:

- **No `machine` lifecycle in your workflow.** No `podman machine start`,
  no `colima start`, no menu-bar app to babysit. First-run bootstrap is
  `podm install`, once.
- **No connection setup.** No `podman system connection add`, no
  `DOCKER_HOST` exports, no context juggling. The shim sets the environment;
  the socket is always where the CLIs expect it.
- **No errors that mention machines or remote hosts.** The CLIs talk to what
  they believe is a local socket; there is no "cannot connect to remote host"
  failure class.
- **Idle RAM is zero for podm, ~25 MB for the platform.** Measured with no
  containers running: `container-apiserver` 9.8 MB + `container-core-images`
  10.0 MB + `container-network-vmnet` 4.7 MB ≈ **25 MB total, 0% CPU**.
  `podmd` itself is a launchd-managed on-demand process that exits when it
  has zero connections and zero running containers. `container system stop`
  releases even the 25 MB, and podm auto-starts the helpers again on demand.

Contrast: a podman machine VM or Docker Desktop pins **gigabytes** whether you
use them or not. The 25 MB helper set is the floor Apple's platform gives you;
nothing above it stays resident.

## Why microVM-per-container is the right trade

Apple's Virtualization framework gives the VM-per-container model its teeth:

- lightweight VMs boot in **~1s** (vs ~320ms for a container in Docker
  Desktop's shared VM — the one latency you pay);
- **memory overcommit**: macOS schedules and swaps VM pages against physical
  RAM like any process, so idle containers page out instead of pinning their
  configured memory — the opposite of a shared machine VM's pinned allocation;
- virtiofs host mounts, vmnet networking, vsock I/O;
- XPC + launchd integration, Keychain for registry credentials;
- Rosetta 2 for x86_64 userland (and a QEMU builder for everything else —
  see [multi-arch.md](multi-arch.md)).

VMs die with their containers: `podman rm` returns the memory to the OS
immediately, with no guest disk image left to garbage collect.

## What we deliberately do NOT support

Honesty beats checkbox parity. These are accepted limits of the model, not
bugs to wait on:

- **Pause/unpause.** A microVM cannot be frozen the way a cgroup can. The
  `pause`/`unpause` endpoints exist and return an explicit "not supported"
  error rather than pretending.
- **Pods / `podman kube play`.** There is no pod primitive in apple
  container. If ever needed, pods could be modeled as multi-VM + shared vmnet
  + shared volumes at the API layer; today that is intentionally out of scope.
- **Checkpoint/restore.** Same class of problem — no VM snapshot-to-disk
  container semantics exposed through the API.
- **True host-privileged.** `--privileged` maps to all capabilities *inside
  the guest VM*. That is a real security boundary, not a gap to be closed:
  there is, by design, no way for a container to reach host-level privilege.
- **Intel Macs.** containerization does not support them and Rosetta-for-Linux
  does not exist there. Hard boundary inherited from Apple.
- **Exotic-arch *run*.** ppc64le/s390x/… images can be *built* (QEMU builder)
  but not executed as containers.

Also accepted, as engineering trade-offs rather than model limits: VM resources
(memory/cpus) are fixed at create time — `update` only handles restart
policies — and memory ballooning is partial (guest-freed pages are not always
returned to the host).
