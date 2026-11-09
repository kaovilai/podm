# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Import of the [socktainer](https://github.com/socktainer/socktainer) fork as
  the pacman server (`pacmand`), carrying over:
  - the podman libpod API layer (~65 route files covering containers, images,
    volumes, networks, manifests, exec, events, auth, system df, build), so the
    stock `podman` CLI works in remote-client mode against pacman's socket;
  - multi-arch build support: a second BuildKit builder VM with QEMU binfmt,
    Rosetta-vs-QEMU platform classification, concurrent split builds across
    both builders, and single-image-index merges for mixed `--platform` lists
    (`--platform linux/amd64,linux/ppc64le --manifest …`);
  - embedded DNS (Rust forwarder sidecar per user network) for compose-style
    service discovery;
  - docker.sock vsock relay for tools that bind-mount `/var/run/docker.sock`
    into containers;
  - `StdioPipes` centralized fd ownership for Apple Container stdio handoff
    (fixes double-close / NIO EBADF crashes, issue #107) with a CI lint.
- Rebrand to pacman/pacmand: socket at `~/.pacman/container.sock`, labels and
  state under `~/.pacman`, `pacman` docker context auto-registration.
- Client shim `pacman` (`Sources/pacman`): multi-call binary with argv[0]
  dispatch for `podman`/`docker` personas, one-time `pacman install`
  (symlinks in `~/.pacman/bin`, real-CLI paths recorded in
  `~/.pacman/client-paths.json`), plus `uninstall`, `status`, `doctor`,
  `version`, and `serve` subcommands.
- launchd on-demand lifecycle for `pacmand` (LaunchAgent
  `io.github.pacman.daemon`): started on demand, woken via
  `launchctl kickstart`, exits after `PACMAN_IDLE_EXIT_SECS` with zero API
  connections and zero running containers.
- CI workflows (PR checks: format, unit tests, release build, installer,
  integration; release; next-build) and macOS `.pkg` installer targets
  (`make installer[-signed|-notarized]`).
- Documentation set: README rewrite, `docs/architecture.md`,
  `docs/no-machine.md`, `docs/multi-arch.md`, `CONTRIBUTING.md`.

[Unreleased]: https://github.com/kaovilai/pacman/compare/6264b64...HEAD
