# CI Workflows & Dev-Box Bootstrap

pacman has four GitHub Actions workflows plus a bootstrap script for standing
up a real (non-CI) Apple silicon box. All macOS jobs run on the
`macos-26` runner label — an arm64 macOS 26 (Tahoe) image, matching the
minimum OS that Apple's `container`/`containerization` frameworks target.

## Workflows

### `pr-check.yaml` — per-PR gate

Runs on every pull request:

| Job | What it does |
|---|---|
| `build` | `make release` (builds the `pacmand` product) + `make installer`; uploads the `pacmand` binary and `pacman-installer.pkg` as artifacts |
| `tests-lint-format` | `make fmt` + no-drift check, `make test` (unit tests + `scripts/lint-pipes.sh`) |
| `integration-test` | Downloads the `pacmand` artifact, installs Apple `container` (version pinned via `Package.resolved`), starts the container runtime, runs `pacmand` as root, and drives it with the **real** docker and podman CLIs: image pull/tag/inspect/load/save fixtures, networks, volumes, version endpoints, podman images/containers/manifest/push-to-ttl.sh |
| `multi-arch-build` | Multi-arch build API test (arm64+amd64 via Rosetta builder, s390x via QEMU builder, combined manifest list). Currently `if: false` — see [VM-gated steps](#vm-gated-steps) |

### `cli-integration.yaml` — flagship proof workflow

Manual dispatch (`workflow_dispatch`) and on PRs. Builds `pacmand` from
source, installs Apple `container`, starts the daemon, waits for its socket
(`~/.pacman/container.sock`, i.e. `/var/root/.pacman/container.sock` under
`sudo -i`), then proves the stock-CLI experience end to end:

- **docker CLI** (Homebrew): `docker ps`, `version`, `images`, `pull`,
  `run --rm alpine echo hello`, `build` of a tiny Dockerfile
  (classic builder, `DOCKER_BUILDKIT=0`).
- **podman CLI** (Homebrew, `CONTAINER_HOST=unix:///var/root/.pacman/container.sock`):
  `podman ps`, `version`, `pull`, `run --rm alpine echo hello`, `build`,
  the manifest workflow (`manifest create/add/inspect/exists`), and
  `podman push` / `manifest push` to ttl.sh.
- **client shim**: built only if `Sources/pacman/` exists (guarded by a
  file-exists check), so the workflow stays green before the shim target
  lands.
- **`multi-arch-build` job**: mirrors `pr-check.yaml`'s multi-arch job
  (Rosetta + QEMU builder split, manifest-list verification), gated behind
  the `enable-multiarch` dispatch input.

### `next-build.yaml` — nightly-style prerelease

On push to `main` and manual dispatch. Tags `v<next-minor>-next.<timestamp>-<sha>`,
builds, signs, notarizes, zips (`pacman.zip`) and packages
(`pacman-installer.pkg`), and attaches them to a prerelease. Every job is
**conditional on the required secrets existing** (`PACMAN_BOT_TOKEN`,
Apple signing/notarization secrets), so on a freshly-imported repository the
workflow completes as all-skipped instead of failing. The fork pushed tags to
a separate `socktainer/prereleases` repository; pacman tags and releases in
its own repository. The `brew-tap-update` job additionally requires a
`kaovilai/homebrew-tap` repository with an `update-formula-next.yml` workflow.

### `release.yaml` — stable release

Manual dispatch with `version` (and optional `branch`). Tags, builds, signs,
notarizes and publishes a release in this repository. As with
`next-build.yaml`, the signing/build/publish chain is gated on the Apple
certificate secrets existing.

## VM-gated steps

pacman runs each container in its own microVM (Apple `containerization`), and
image builds go through BuildKit builder VMs. **GitHub-hosted macOS runners
run inside VMs without nested virtualization**, so anything that boots a VM
fails there with `VZErrorDomain Code=2 "Virtualization is not available on
this hardware"` (see
[actions/runner-images#12933](https://github.com/actions/runner-images/issues/12933)).
Consequently:

- `pr-check.yaml` has `podman build` commented out and the multi-arch job
  disabled (`if: false`), matching the fork's green-tolerant state.
- `cli-integration.yaml` gates `docker/podman run`, `docker build`,
  `podman build` behind the `enable-vm-steps` dispatch input and the
  multi-arch job behind `enable-multiarch` (both default `false`, and unset
  on `pull_request` events). Enable them only on a self-hosted runner —
  e.g. a box set up with `scripts/bootstrap-box.sh`.

## Running cli-integration locally

The same steps `cli-integration.yaml` performs, on a real Apple silicon Mac
(macOS 26, Xcode installed):

```sh
# 1. bootstrap the box (no sudo: user-local installs of Apple container +
#    podman + docker CLI from their .pkg payloads; idempotent)
zsh scripts/bootstrap-box.sh

# 2. start the daemon (socket: ~/.pacman/container.sock)
~/bin/pacmand &

# 3. docker CLI — no setup needed (the daemon installs a 'pacman' docker
#    context); or point at the socket explicitly:
docker ps
DOCKER_HOST=unix://$HOME/.pacman/container.sock docker run --rm alpine echo hello

# 4. podman CLI
CONTAINER_HOST=unix://$HOME/.pacman/container.sock podman ps
CONTAINER_HOST=unix://$HOME/.pacman/container.sock podman run --rm alpine echo hello

# 5. build something
DOCKER_BUILDKIT=0 docker build -t cli-int-test .   # classic builder
CONTAINER_HOST=unix://$HOME/.pacman/container.sock podman build -t cli-int-test .
```

`scripts/bootstrap-box.sh` flags:

| Flag | Effect |
|---|---|
| (default) | `--user-install`: no-sudo user-local installs into `~/.local`, CLIs symlinked into the bin dir |
| `--sudo-stdin` | fallback: password piped to `sudo -S -k` per call (never on argv); without it, sudo steps use `sudo -n` and are reported as `PENDING` rather than prompting |
| `--test` | also run `scripts/lint-pipes.sh` and `swift test` in the checkout |
| `REPO` (positional) | build an existing checkout instead of cloning `PACMAN_REPO_URL` (branch `PACMAN_BRANCH`) into `~/pacman` |

Versions are pinned and env-overridable: `CONTAINER_VERSION` (defaults to the
`Package.resolved` pin — the same version CI installs), `PODMAN_VERSION`,
`DOCKER_VERSION`, plus `PACMAN_REPO_URL` / `PACMAN_BRANCH`. The script is
safe over ssh without a tty: it never prompts, and reports sudo-requiring
steps as `PENDING` for a later re-run.

## Runner requirements

| Requirement | Why |
|---|---|
| `macos-26` label (arm64) | Apple `container` / `containerization` need Apple Silicon + macOS 26; the fork used the same label |
| Xcode (via `setup-xcode` `latest-stable`) | Swift toolchain for `swift build` |
| Virtualization framework (self-hosted only) | microVMs per container, BuildKit builder VMs, Rosetta/QEMU multi-arch builders — unavailable on GitHub-hosted runners |
| Homebrew | docker / podman / docker-buildx CLIs in CI |
