# Contributing to podm

Thanks for contributing! This document covers the essentials: building,
testing, commit conventions, and the one hard rule about file-descriptor
ownership that everyone touching container I/O must know.

## Getting started

Requirements:

- macOS 26 (Tahoe) or newer, Apple Silicon (arm64)
- Xcode command line tools (Swift 6 toolchain)
- Apple `container` 1.6.1+ (`brew install container`) — needed at runtime, not
  build time

```bash
git clone https://github.com/kaovilai/podm.git
cd podm
make            # debug build of podmd
make test       # unit tests (runs the pipe-ownership lint first)
make release    # release build
make installer  # unsigned macOS .pkg (see make installer-help for signed/notarized)
```

Plain `swift build` / `swift test` also work — the Makefile wraps them and adds
the extra checks.

## Code style

The project uses `swift-format` with configuration in `.swift-format`.

```bash
make fmt    # format before committing
```

CI checks for formatting drift: `make fmt` followed by `git diff --exit-code`.

## Testing

- **Bug fixes must include a unit test** that reproduces the bug and verifies
  the fix — it should fail without the fix and pass with it.
- **New features must include unit tests** covering the main behavior and
  relevant edge cases.
- Place tests in `Tests/podmdTests/` following the existing structure
  (`Routes/`, `Clients/`, `Utilities/`, `DNS/`, `Events/`, `Network/`).
- When modifying behavior, update the corresponding tests.
- Run `make test` before committing.

`make test` runs `make lint-pipes` first (see the fd-ownership rule below) —
a lint failure fails the test target.

## Commits

- **Conventional Commits** format: `<type>(<scope>): <description>` (scope
  optional). Common types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`,
  `ci`, `perf`, `deps`, `build`. Common scopes: `routes`, `containers`,
  `images`, `healthcheck`, `dns`, `build`, `volumes`, `labels`, `stats`,
  `context`, `attach`, `app`, `archive`, `builder`.
- **DCO sign-off is required** on every commit: use `git commit -s` (or
  `--signoff`). The [DCO Probot app](https://probot.github.io/apps/dco/)
  enforces this on pull requests.
- Scope changes to the issue at hand — don't make unrelated changes in the
  same branch.

## License headers

New source files must carry the Apache-2.0 SPDX identifier and copyright
notice, matching the existing files (see `Sources/podmd/main.swift` or the
`Makefile` for the header text):

```swift
// Copyright © 2026 Podm contributors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
```

## Apple Container stdio fd ownership

**Never use Foundation's `Pipe()` when passing fds to
`ContainerClient.createProcess(stdio:)` or
`ContainerClient.bootstrap(id:stdio:)`.**

These APIs dup the passed fds into the container and then **immediately close
the parent copies**. `Pipe()` does not know about this external close — its
`deinit` later calls `close()` again on the same fd, which may now be a
recycled NIO socket. The double-close corrupts NIO's fd table, causing
`writev`/`kevent` EBADF crashes under concurrent load (issue #107).

**Use `StdioPipes`** (centralized allocation and cleanup,
`Sources/podmd/Utilities/DockerConnectionUtility.swift`):

```swift
guard let pipes = StdioPipes.make([.stdin, .stdout, .stderr]) else {  // or make(.all)
    throw Abort(.internalServerError, reason: "Failed to create I/O pipes")
}
let process: ClientProcess
do {
    process = try await ContainerClient().createProcess(..., stdio: pipes.stdioArray)
} catch {
    pipes.closeAll()           // Apple never took ownership — close all 6 fds
    throw error
}
do {
    try await process.start()
} catch {
    pipes.closeAfterHandoff()  // Apple owns stdin.read, stdout.write, stderr.write
    throw error
}
// Success — use pipes.stdout?.read, pipes.stderr?.read, pipes.stdin?.write in tasks
```

`StdioPipes.make()` handles EMFILE internally (closes any partially-allocated
pipes and returns `nil`). `closeAll()` is for createProcess-failure;
`closeAfterHandoff()` is for start-failure. `ProcessPipe` (the single-pipe
primitive) exists for unusual cases requiring finer control.

Ownership contract:

- **stdout/stderr**: pass `.write` via `StdioPipes.stdioArray` — Apple closes
  it. Caller closes `.read`.
- **stdin**: pass `.read` via `StdioPipes.stdioArray` — Apple closes it.
  Caller closes `.write`.
- Always use `StdioPipes.make()` with `guard let` — pipe exhaustion returns
  nil and yields a clean HTTP error.
- `make test` runs `make lint-pipes` which rejects `= Pipe()` in non-registry
  source files.

## Pull requests

- PR titles follow the same conventional commit format.
- Include a summary of the change and how you tested it (see
  `.github/PULL_REQUEST_TEMPLATE.md`).
- PR CI (`pr-check.yaml`) runs: format check, unit tests, release build,
  installer build, and integration tests. Make sure `make fmt && make test`
  passes locally first.
- Reference the issue a PR resolves with `Fixes #<issueNo>` so GitHub
  auto-links and closes it on merge.

## Reporting bugs

Bug reports should include: description (actual vs expected behavior),
reproduction steps, environment info (macOS version, `podm version`, apple
container version), and relevant logs. See the issue templates in
`.github/ISSUE_TEMPLATE/`.

Security vulnerabilities should be reported responsibly (to the maintainers),
not as public GitHub issues.
