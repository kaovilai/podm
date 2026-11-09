// SPDX-License-Identifier: Apache-2.0
// Copyright © 2026 the pacman authors.
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not
// use this file except in compliance with the License. You may obtain a copy
// of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
// License for the specific language governing permissions and limitations
// under the License.

// Investigation note: adopting a launchd-provided listening socket for TRUE
// socket activation (daemon started on first connection, no kickstart needed).
//
// Status: NOT implemented. Vapor 4.121 cannot cleanly serve on a pre-bound
// file descriptor, and correctness was chosen over cleverness. What was found:
//
// 1. Getting the fd from launchd works. `launch_activate_socket(name:fds:count:)`
//    is a public liblaunch API; it can be reached without a framework import:
//
//        let handle = dlopen("/usr/lib/system/liblaunch.dylib", RTLD_NOW)
//        let sym = dlsym(handle, "launch_activate_socket")
//        // C function pointer: (name: UnsafePointer<CChar>,
//        //                      fds: UnsafeMutablePointer<UnsafeMutablePointer<CInt>?,
//        //                      cnt: UnsafeMutablePointer<Int>) -> kern_return_t
//
//    It returns dup'd fds for every socket declared under the job's
//    `Sockets` dict — the commented-out `pacman-listener` entry in
//    assets/launchd/io.github.pacman.daemon.plist.in is shaped for this.
//
// 2. Serving on it with Vapor does not. Vapor's `HTTPServer` binds via NIO's
//    `ServerBootstrap` from a `BindAddress`, and the only unix-socket flavor
//    is `.unixDomainSocket(path:)`, which bind(2)s a NEW socket at that path.
//    `BindAddress` has no "adopt an existing fd / already-bound listener"
//    case, and `HTTPServer.start(address:)`'s bootstrap path is not
//    interceptable (Sources/Vapor/HTTP/Server/HTTPServer.swift, verified
//    against the 4.121.3 checkout). `EventLoopGroup.next().make...`-style
//    adoption would mean forking/patching Vapor's server stack — not clean.
//
// 3. There is also an unlink hazard: `prepareUnixSocket`
//    (Sources/pacmand/Utilities/SocketUtility.swift) removes a stale socket
//    file before binding. With launchd owning the bound socket at that path,
//    the unlink would disconnect launchd's listener from the filesystem, so
//    adoption mode would need to skip that step as well.
//
// Future path (kept ready in the plist as the commented Sockets section):
//   a. Uncomment the `Sockets` dict (listener name "pacman-listener") in the
//      plist and re-run scripts/install-launchd.sh.
//   b. dlopen liblaunch + `launch_activate_socket("pacman-listener", ...)` at
//      startup, before `prepareUnixSocket`.
//   c. Teach Vapor to serve on the adopted fd — either upstream
//      (`BindAddress.unixDomainSocket(fd:)` or equivalent) or by swapping in
//      a thin NIO HTTP/1.1 server over `ServerBootstrap`'s
//      `bind(existingChannel:)`-style adoption.
//   d. Skip the socket-file unlink when adopting.
//
// Until then, the supported on-demand path is: RunAtLoad + idle-exit
// (Sources/pacmand/Utilities/IdleExit.swift) + `launchctl kickstart` wake-up
// from the pacman client shim. That already achieves the zero-RAM-when-idle
// goal; socket activation would only remove the kickstart latency (~one
// process spawn) from the first request after an idle period.
