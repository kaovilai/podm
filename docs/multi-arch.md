# Multi-arch builds

How podm builds images for architectures your Mac cannot natively run —
including ppc64le and s390x — with the stock CLIs.

## The three tiers

When you pass `--platform` (or `podman build --manifest` with a platform list),
every requested platform is classified exactly one way
(`Utilities/PlatformUtility.swift`):

| Tier | Architectures | Mechanism |
|---|---|---|
| Native | `linux/arm64` | Runs directly on the Apple Silicon host kernel |
| Rosetta | `linux/amd64` (`x86_64`) | Rosetta 2 translates x86_64 userland inside the arm64 kernel; build and run both work, `uname -m` reports `x86_64` |
| QEMU | `linux/ppc64le`, `s390x`, `riscv64`, … | A second BuildKit **builder VM with QEMU binfmt registered** executes `RUN` steps under emulation |

Rosetta edge cases: anything needing a true x86_64 *kernel* or ptrace-heavy
tooling may misbehave. For the exotic architectures there is no Rosetta at all —
upstream `apple/container` cannot execute their `RUN` steps (Exec format error;
tracked as [apple/container#1496](https://github.com/apple/container/issues/1496)).

## The two-builder split

The QEMU tier is podm's addition over upstream. Instead of one BuildKit
builder, `podmd` provisions **two builder container VMs**:

1. the **Rosetta builder** — default BuildKit VM, handles arm64 + amd64;
2. the **QEMU builder** — an additional BuildKit VM with qemu-user-static
   registered via binfmt, handles everything else.

For a mixed `--platform` request, each platform is classified
(`platformRequiresQEMU`: anything that is neither arm64 nor amd64/x86_64 goes
to QEMU), the build is **split across both builders concurrently**, and the
per-architecture results are merged into **one image index / manifest list**
(`Clients/ClientManifestService.swift`, `Routes/Images/BuildRoute.swift`).

This is the same trick as qemu-user-static on a Linux host, wrapped so the
plain CLIs drive it:

```bash
# build the whole OADP-style matrix locally on one Mac:
podman build \
  --platform linux/amd64,linux/arm64,linux/ppc64le,linux/s390x \
  --manifest myapp .

podman manifest inspect myapp | grep architecture
#   "architecture": "amd64"
#   "architecture": "arm64"
#   "architecture": "ppc64le"
#   "architecture": "s390x"

podman manifest push myapp quay.io/me/myapp:latest
```

Single-platform exotic builds work too:

```bash
podman build --platform linux/s390x -t myapp-s390x .
```

## Builder management

- Builders are container VMs created on demand and reused across builds
  (`Clients/ClientBuilderService.swift`); `buildctl` is driven over the
  builder's internal socket.
- `docker builder prune` / `docker system df` report and prune **both**
  builders' caches (the QEMU builder is only touched if it exists — reporting
  never provisions a VM just to say "empty").
- Builder reachability is polled with a timeout/retry loop before use.

## Run vs build

| Operation | arm64 | amd64 | ppc64le/s390x/… |
|---|---|---|---|
| `RUN` during build | native | Rosetta | QEMU builder VM |
| `podman run` | ✅ | ✅ (Rosetta) | ❌ not supported |

Running exotic-arch containers would require qemu-user registered *inside each
container VM* — possible future work, tracked on the roadmap, but not needed
for the build use-case. If you need to smoke-test a ppc64le image, run it
somewhere that architecture exists.

## Builder sizing (big projects, emulated arches)

The builder VMs default to 2 vCPUs / 2048 MB each — conservative for a
laptop, slow for a big multi-stage Go/Rust/Node build, and *very* slow under
QEMU emulation. Two ways to size up:

**Once, for every build** (env knobs, read at daemon start):

```sh
launchctl setenv PODM_BUILDER_CPUS 6
launchctl setenv PODM_BUILDER_MEMORY 6g
# The QEMU (emulated-arch) builder is sized independently — usually wants more CPU:
launchctl setenv PODM_QEMU_BUILDER_CPUS 8
launchctl setenv PODM_QEMU_BUILDER_MEMORY 8g
```

(or `podm serve` in the foreground with them exported). Knobs take effect
when the builder is next created; both knobs and per-build asks below
clamp to the host's core count and physical RAM.

**Per build, only when you ask** — the standard resource flags both CLIs
already send on `/build`:

```sh
podman build --memory 6g --cpu-quota 600000 --cpu-period 100000 .
docker build --memory 6g --cpu-quota 600000 --cpu-period 100000 .
```

(`--cpu-quota/--cpu-period` is CFS-speak for vCPUs: `quota/period` of
`600000/100000` = 6; a quota sent without a period uses the CFS default
period of `100000`.) The flags are absent from the wire when you don't
pass them, so an un-flagged build never triggers *per-build* escalation —
though a builder smaller than a **raised env floor** is still recreated
once, on the next build of any kind. A flagged build sizes a builder it
has to *create* at the larger of the env floor and the ask; a smaller
builder that is already running is recreated at the larger size, keeping
any field where it was already larger (replacement never shrinks). The
BuildKit cache inside a replaced builder resets — a one-time cost logged
at the time, and a build concurrently in flight on that builder may
fail; re-run it.
