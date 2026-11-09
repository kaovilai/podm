import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

/// `docker top` / `podman top` — both dialects run `ps` inside the container
/// (processes are not visible from the macOS host, each container is its own
/// microVM) and parse the table into `{"Titles": [...], "Processes": [[...]]}`.
///
/// These tests cover the parse matrix, ps_args handling per dialect, and the
/// route-level error/shape semantics (404 unknown, 409 not running). The
/// ps execution itself is injected as a fake so no real container is needed.
@Suite("ContainerTop")
struct ContainerTopRouteTests {

    // MARK: - Helpers

    /// Records every (container, argv) the route asked to run and replies with
    /// canned ps output.
    private actor FakePs {
        var calls: [(containerId: String, argv: [String])] = []
        let output: String

        init(output: String) {
            self.output = output
        }

        func record(containerId: String, argv: [String]) {
            calls.append((containerId, argv))
        }
    }

    private struct TopClientMock: ClientContainerProtocol {
        let containers: [ContainerSnapshot]
        /// When set, `getContainer` throws this instead of looking up — used
        /// to cover error branches (e.g. the ambiguous-ID 400 path).
        let getContainerError: Error?

        init(containers: [ContainerSnapshot], getContainerError: Error? = nil) {
            self.containers = containers
            self.getContainerError = getContainerError
        }

        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { containers }
        func getContainer(id: String) async throws -> ContainerSnapshot? {
            if let getContainerError { throw getContainerError }
            return containers.first { $0.id == id }
        }
        func enforceContainerRunning(container: ContainerSnapshot) throws {
            guard container.status == .running else {
                throw ClientContainerError.notRunning(id: container.id)
            }
        }
        func start(id: String, detachKeys: String?) async throws {}
        func stop(id: String, signal: String?, timeout: Int?) async throws {}
        func restart(id: String, signal: String?, timeout: Int?) async throws {}
        func kill(id: String, signal: String?) async throws {}
        func delete(id: String) async throws {}
        func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
            RESTContainerWait(statusCode: 0)
        }
        func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
            ([], 0)
        }
    }

    private func runningSnapshot(id: String) throws -> ContainerSnapshot {
        try makeContainerSnapshot(nativeId: id, networks: [], labels: [:], status: .running)
    }

    private func makeRunner(_ fake: FakePs) -> ContainerTopUtility.PsRunner {
        { container, argv in
            await fake.record(containerId: container.id, argv: argv)
            // Mirror execPs's post-processing so route tests see what the real
            // daemon returns: the ps self-row is filtered on the exec'd argv.
            return ContainerTopUtility.filterPsSelfRow(
                await fake.output,
                command: (["ps"] + argv).joined(separator: " "))
        }
    }

    private func withTopApp<T: RouteCollection>(
        _ collection: T,
        _ test: (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: collection)
            try await test(app)
        }
    }

    // MARK: - Parse matrix

    @Test("procps ps -ef output parses header and rows, command extras merge into the last column")
    func parseProcpsEf() {
        let output = """
            UID  PID  PPID  C STIME TTY  TIME CMD
            root     1     0  0 12:34 ?    00:00:00 /sbin/init
            root    42     1  0 12:34 ?    00:00:00 sh -c sleep 1000
            """
        let report = ContainerTopUtility.parse(output)
        #expect(report.Titles == ["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"])
        #expect(report.Processes.count == 2)
        #expect(report.Processes[0] == ["root", "1", "0", "0", "12:34", "?", "00:00:00", "/sbin/init"])
        // moby appendProcess2ProcList merges "overhanging" fields — a command
        // with args spans several whitespace fields and is rejoined into the
        // last column, keeping every row exactly Titles.count wide.
        #expect(report.Processes[1] == ["root", "42", "1", "0", "12:34", "?", "00:00:00", "sh -c sleep 1000"])
    }

    @Test("ps aux output parses (%CPU-style headers and decimal columns)")
    func parseAux() {
        let output = """
            USER PID %CPU %MEM    VSZ   RSS TTY STAT START TIME COMMAND
            root   1  0.0  0.1  12345  678 ?  Ss  12:34  0:00 /sbin/init
            """
        let report = ContainerTopUtility.parse(output)
        #expect(report.Titles == ["USER", "PID", "%CPU", "%MEM", "VSZ", "RSS", "TTY", "STAT", "START", "TIME", "COMMAND"])
        #expect(report.Processes == [["root", "1", "0.0", "0.1", "12345", "678", "?", "Ss", "12:34", "0:00", "/sbin/init"]])
    }

    @Test("busybox ps output parses (right-aligned columns, COMMAND with args)")
    func parseBusybox() {
        let output = """
            PID   USER     TIME  COMMAND
                1 root      0:00 sleep 1000
            """
        let report = ContainerTopUtility.parse(output)
        #expect(report.Titles == ["PID", "USER", "TIME", "COMMAND"])
        #expect(report.Processes == [["1", "root", "0:00", "sleep 1000"]])
    }

    @Test("rows wider than the header merge command extras into the last column")
    func parseRejoinsCommandExtras() {
        let output = """
            UID PID PPID C STIME TTY TIME CMD
            root 42 1 0 12:34 ? 00:00:00 sh -c sleep 1000
            """
        let report = ContainerTopUtility.parse(output)
        #expect(report.Titles == ["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"])
        // Every row stays exactly Titles.count wide (moby + podman compat).
        #expect(report.Processes == [["root", "42", "1", "0", "12:34", "?", "00:00:00", "sh -c sleep 1000"]])
    }

    @Test("rows that fit the header are untouched")
    func parseRejoinShortRow() {
        let output = """
            PID COMMAND
            2 ps
            1 /bin/sh
            """
        let report = ContainerTopUtility.parse(output)
        #expect(report.Processes == [["2", "ps"], ["1", "/bin/sh"]])
    }

    @Test("empty output yields an empty report, not an error")
    func parseEmpty() {
        let report = ContainerTopUtility.parse("")
        #expect(report.Titles.isEmpty)
        #expect(report.Processes.isEmpty)
    }

    @Test("header-only output yields titles with no processes")
    func parseHeaderOnly() {
        let report = ContainerTopUtility.parse("PID USER COMMAND\n")
        #expect(report.Titles == ["PID", "USER", "COMMAND"])
        #expect(report.Processes.isEmpty)
    }

    @Test("CRLF and blank lines are tolerated")
    func parseCRLF() {
        let output = "PID COMMAND\r\n1 sleep 1000\r\n\r\n2 ps\r\n"
        let report = ContainerTopUtility.parse(output)
        #expect(report.Titles == ["PID", "COMMAND"])
        #expect(report.Processes == [["1", "sleep 1000"], ["2", "ps"]])
    }

    @Test("non-ASCII whitespace inside a command does not split the field")
    func parseNonAsciiSpace() {
        let output = "PID COMMAND\n1 café\u{00A0}latte"
        let report = ContainerTopUtility.parse(output)
        #expect(report.Processes == [["1", "café\u{00A0}latte"]])
    }

    // MARK: - ps_args handling

    @Test("dockerArgv defaults to empty (route applies -ef)")
    func dockerArgvDefaults() {
        #expect(ContainerTopUtility.dockerArgv(psArgs: nil) == [])
        #expect(ContainerTopUtility.dockerArgv(psArgs: "") == [])
    }

    @Test("dockerArgv splits flags on whitespace, dropping empties")
    func dockerArgvSplits() {
        #expect(ContainerTopUtility.dockerArgv(psArgs: "aux") == ["aux"])
        #expect(ContainerTopUtility.dockerArgv(psArgs: "-ef") == ["-ef"])
        #expect(ContainerTopUtility.dockerArgv(psArgs: "  aux   -f  ") == ["aux", "-f"])
    }

    @Test("libpodArgv defaults to empty (route applies -ef)")
    func libpodArgvDefaults() {
        #expect(ContainerTopUtility.libpodArgv(psArgs: []) == ContainerTopUtility.LibpodTopArgs(argv: [], appendedCommandColumn: false))
        #expect(ContainerTopUtility.libpodArgv(psArgs: [""]) == ContainerTopUtility.LibpodTopArgs(argv: [], appendedCommandColumn: false))
    }

    @Test("libpodArgv maps descriptors — repeated, comma-joined, or via descriptors — to ps -eo")
    func libpodArgvDescriptors() {
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["user", "pid"]) == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "user,pid,args"], appendedCommandColumn: true))
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["user,pid,command"]) == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "user,pid,args"], appendedCommandColumn: false))
        #expect(
            ContainerTopUtility.libpodArgv(psArgs: ["user", "pid,command"]) == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "user,pid,args"], appendedCommandColumn: false))
        #expect(ContainerTopUtility.libpodArgv(psArgs: [" user , pid "]) == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "user,pid,args"], appendedCommandColumn: true))
    }

    @Test("libpodArgv aliases procps-only descriptor spellings to busybox-compatible ones")
    func libpodArgvAliases() {
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["command"]) == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "args"], appendedCommandColumn: false))
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["cmd"]) == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "args"], appendedCommandColumn: false))
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["pid,elapsed"]) == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "pid,etime,args"], appendedCommandColumn: true))
    }

    @Test("libpodArgv recognizes psgo/podman-documented descriptors beyond the core set")
    func libpodArgvExtendedDescriptors() {
        // podman top(1) documents these AIX descriptors; treating them as raw
        // ps arguments made valid requests fail (`ps pid vsz`).
        #expect(
            ContainerTopUtility.libpodArgv(psArgs: ["pid", "vsz"])
                == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "pid,vsz,args"], appendedCommandColumn: true))
        #expect(
            ContainerTopUtility.libpodArgv(psArgs: ["nice", "pcpu", "pgid", "rgroup", "ruser", "rss", "stat"])
                == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "nice,pcpu,pgid,rgroup,ruser,rss,stat,args"], appendedCommandColumn: true))
    }

    @Test("libpodArgv passes flag-style values through unchanged, raw mode decided before normalization")
    func libpodArgvFlags() {
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["-ef"]) == ContainerTopUtility.LibpodTopArgs(argv: ["-ef"], appendedCommandColumn: false))
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["aux", "-f"]) == ContainerTopUtility.LibpodTopArgs(argv: ["aux", "-f"], appendedCommandColumn: false))
        // A single flag-carrying value is shlex-split with commas preserved —
        // comma-splitting first would destroy the "-o pid,args" option value
        // (podman's ErrUnknownDescriptor fallback, google/shlex, #12452).
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["-o pid,args"]) == ContainerTopUtility.LibpodTopArgs(argv: ["-o", "pid,args"], appendedCommandColumn: false))
        // Unknown descriptors are raw ps arguments, not "-o" columns:
        // "aux" would otherwise become "ps -eo aux", which ps rejects.
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["aux"]) == ContainerTopUtility.LibpodTopArgs(argv: ["aux"], appendedCommandColumn: false))
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["-eo", "pid,args"]) == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "pid,args"], appendedCommandColumn: false))
    }

    @Test("libpodArgv shlex-splits quoted and escaped single values like shell words")
    func libpodArgvShellWords() {
        // Quotes are stripped and escapes honored (podman uses google/shlex);
        // a whitespace-only split would pass 'pid,args' with literal quotes
        // and ps would reject the format.
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["-eo 'pid,args'"]) == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "pid,args"], appendedCommandColumn: false))
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["-eo \"pid args\""]) == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "pid args"], appendedCommandColumn: false))
        #expect(ContainerTopUtility.libpodArgv(psArgs: ["-eo p\\;id"]) == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "p;id"], appendedCommandColumn: false))
    }

    @Test("filterPsSelfRow drops the ps process's own row, keeps everything else")
    func filterSelfRow() {
        let output = """
            PID USER TIME COMMAND
            1 root 0:00 sleep 1000
            2 root 0:00 ps -ef
            """
        let filtered = ContainerTopUtility.filterPsSelfRow(output, command: "ps -ef")
        #expect(filtered == "PID USER TIME COMMAND\n1 root 0:00 sleep 1000")
        #expect(ContainerTopUtility.filterPsSelfRow(output, command: "") == output)
        #expect(ContainerTopUtility.filterPsSelfRow("", command: "ps -ef") == "")
    }

    // MARK: - Docker dialect route

    @Test("docker top returns 404 for an unknown container")
    func dockerTopUnknownContainer() async throws {
        let fake = FakePs(output: "")
        let mock = TopClientMock(containers: [])
        try await withTopApp(ContainerTopRoute(client: mock, runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/containers/nope/top") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("docker top returns 409 when the container is not running")
    func dockerTopNotRunning() async throws {
        let stopped = try makeContainerSnapshot(nativeId: "c-stopped", networks: [], labels: [:], status: .stopped)
        let fake = FakePs(output: "")
        try await withTopApp(ContainerTopRoute(client: TopClientMock(containers: [stopped]), runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/containers/c-stopped/top") { res async throws in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("docker top defaults to ps -ef and returns the parsed table")
    func dockerTopDefaultArgs() async throws {
        let fake = FakePs(
            output: """
                UID PID PPID C STIME TTY TIME CMD
                root 1 0 0 12:34 ? 00:00:00 sleep 1000
                """)
        let snapshot = try runningSnapshot(id: "c1")
        try await withTopApp(ContainerTopRoute(client: TopClientMock(containers: [snapshot]), runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/containers/c1/top") { res async throws in
                #expect(res.status == .ok)
                let report = try res.content.decode(TopReport.self)
                #expect(report.Titles == ["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"])
                #expect(report.Processes.count == 1)
            }
        }
        let calls = await fake.calls
        #expect(calls.map(\.argv) == [["-ef"]])
        #expect(calls.map(\.containerId) == ["c1"])
    }

    @Test("docker top passes ps_args through to ps")
    func dockerTopPsArgs() async throws {
        let fake = FakePs(output: "USER PID COMMAND\n")
        let snapshot = try runningSnapshot(id: "c1")
        try await withTopApp(ContainerTopRoute(client: TopClientMock(containers: [snapshot]), runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/containers/c1/top?ps_args=aux") { res async throws in
                #expect(res.status == .ok)
            }
        }
        let calls = await fake.calls
        #expect(calls.map(\.argv) == [["aux"]])
    }

    @Test("docker top with empty ps output returns an empty Processes array, not 500")
    func dockerTopEmptyOutput() async throws {
        let fake = FakePs(output: "")
        let snapshot = try runningSnapshot(id: "c1")
        try await withTopApp(ContainerTopRoute(client: TopClientMock(containers: [snapshot]), runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/containers/c1/top") { res async throws in
                #expect(res.status == .ok)
                let report = try res.content.decode(TopReport.self)
                #expect(report.Titles.isEmpty)
                #expect(report.Processes.isEmpty)
            }
        }
    }

    // MARK: - libpod dialect route

    @Test("podman top defaults to ps -ef and merges command extras into the last column")
    func libpodTopDefault() async throws {
        let fake = FakePs(
            output: """
                UID PID PPID C STIME TTY TIME CMD
                root 1 0 0 12:34 ? 00:00:00 sh -c sleep 1000
                """)
        let snapshot = try runningSnapshot(id: "c1")
        try await withTopApp(LibpodContainerTopRoute(client: TopClientMock(containers: [snapshot]), runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/c1/top") { res async throws in
                #expect(res.status == .ok)
                let report = try res.content.decode(TopReport.self)
                #expect(report.Titles == ["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"])
                #expect(report.Processes == [["root", "1", "0", "0", "12:34", "?", "00:00:00", "sh -c sleep 1000"]])
            }
        }
        let calls = await fake.calls
        #expect(calls.map(\.argv) == [["-ef"]])
    }

    @Test("podman top maps repeated ps_args descriptors to ps -eo")
    func libpodTopDescriptors() async throws {
        let fake = FakePs(output: "USER PID COMMAND\n")
        let snapshot = try runningSnapshot(id: "c1")
        try await withTopApp(LibpodContainerTopRoute(client: TopClientMock(containers: [snapshot]), runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/c1/top?ps_args=user&ps_args=pid") { res async throws in
                #expect(res.status == .ok)
            }
        }
        let calls = await fake.calls
        #expect(calls.map(\.argv) == [["-eo", "user,pid,args"]])
    }

    @Test("podman top maps comma-joined descriptors and the descriptors parameter to ps -eo")
    func libpodTopCommaAndDescriptorsParam() async throws {
        let fake = FakePs(output: "USER PID COMMAND\n")
        let snapshot = try runningSnapshot(id: "c1")
        try await withTopApp(LibpodContainerTopRoute(client: TopClientMock(containers: [snapshot]), runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/c1/top?ps_args=user,pid,command") { res async throws in
                #expect(res.status == .ok)
            }
            try await app.testing().test(.GET, "/v1.51/libpod/containers/c1/top?descriptors=user&descriptors=pid") { res async throws in
                #expect(res.status == .ok)
            }
        }
        let calls = await fake.calls
        #expect(calls.map(\.argv) == [["-eo", "user,pid,args"], ["-eo", "user,pid,args"]])
    }

    @Test("libpodArgv renders a nonfinal command column last and reports the reorder permutation")
    func libpodArgvNonFinalCommandColumn() {
        // parse() merges overhanging command words into the LAST column, so
        // the command must be rendered last internally; the requested order
        // is restored after parsing via the permutation.
        #expect(
            ContainerTopUtility.libpodArgv(psArgs: ["command", "pid"])
                == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "pid,args"], reorder: [1, 0]))
        #expect(
            ContainerTopUtility.libpodArgv(psArgs: ["user", "command", "pid"])
                == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "user,pid,args"], reorder: [0, 2, 1]))
    }

    @Test("libpodArgv treats comm as insufficient for self-row filtering and appends args anyway")
    func libpodArgvCommOnlyAppends() {
        // comm is only the executable name — the self-row filter needs the
        // full command line, so args is appended (and stripped after parse).
        #expect(
            ContainerTopUtility.libpodArgv(psArgs: ["pid", "comm"])
                == ContainerTopUtility.LibpodTopArgs(argv: ["-eo", "pid,comm,args"], appendedCommandColumn: true))
    }

    @Test("podman top with a nonfinal command descriptor restores the requested column order")
    func libpodTopNonFinalCommandColumn() async throws {
        // ps output as "ps -eo pid,args" renders it: PID first, COMMAND last.
        let fake = FakePs(
            output: """
                PID COMMAND
                1 sleep 1000
                """)
        let snapshot = try runningSnapshot(id: "c1")
        try await withTopApp(LibpodContainerTopRoute(client: TopClientMock(containers: [snapshot]), runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/c1/top?ps_args=command&ps_args=pid") { res async throws in
                #expect(res.status == .ok)
                let report = try res.content.decode(TopReport.self)
                // The requested COMMAND-then-PID order, with the command's
                // arguments kept together in the COMMAND column.
                #expect(report.Titles == ["COMMAND", "PID"])
                #expect(report.Processes == [["sleep 1000", "1"]])
            }
        }
        let calls = await fake.calls
        #expect(calls.map(\.argv) == [["-eo", "pid,args"]])
    }

    @Test("podman top with a comm-only request filters the ps self-row via the appended args column")
    func libpodTopCommOnlyFiltersSelfRow() async throws {
        // "ps -eo pid,comm,args" output: the self row's args column carries
        // the full command line so the filter drops it; the comm column keeps
        // just the executable name; the appended args column is stripped.
        let fake = FakePs(
            output: """
                PID COMMAND COMMAND
                1 sleep sleep 1000
                2 ps ps -eo pid,comm,args
                """)
        let snapshot = try runningSnapshot(id: "c1")
        try await withTopApp(LibpodContainerTopRoute(client: TopClientMock(containers: [snapshot]), runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/c1/top?ps_args=pid&ps_args=comm") { res async throws in
                #expect(res.status == .ok)
                let report = try res.content.decode(TopReport.self)
                #expect(report.Titles == ["PID", "COMMAND"])
                #expect(report.Processes == [["1", "sleep"]])
            }
        }
    }

    @Test("podman top without a command column appends args for self-row filtering, then strips it")
    func libpodTopNoCommandColumn() async throws {
        // ps output as it would look for "ps -eo user,pid,args": the ps
        // process's own row carries the command line, so the self-row filter
        // can drop it; the appended args column is then stripped from the
        // report the client sees.
        let fake = FakePs(
            output: """
                USER PID COMMAND
                root 1 sleep 1000
                root 2 ps -eo user,pid,args
                """)
        let snapshot = try runningSnapshot(id: "c1")
        try await withTopApp(LibpodContainerTopRoute(client: TopClientMock(containers: [snapshot]), runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/c1/top?ps_args=user&ps_args=pid") { res async throws in
                #expect(res.status == .ok)
                let report = try res.content.decode(TopReport.self)
                // Only the requested columns — the appended args column is
                // gone, and the ps self-row was filtered despite the client
                // never asking for a command column.
                #expect(report.Titles == ["USER", "PID"])
                #expect(report.Processes == [["root", "1"]])
            }
        }
        let calls = await fake.calls
        #expect(calls.map(\.argv) == [["-eo", "user,pid,args"]])
    }

    @Test("podman top returns 404 for an unknown container and 409 when stopped")
    func libpodTopErrors() async throws {
        let stopped = try makeContainerSnapshot(nativeId: "c-stopped", networks: [], labels: [:], status: .stopped)
        let fake = FakePs(output: "")
        try await withTopApp(
            LibpodContainerTopRoute(client: TopClientMock(containers: [stopped]), runPs: makeRunner(fake))
        ) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/missing/top") { res async throws in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.GET, "/v1.51/libpod/containers/c-stopped/top") { res async throws in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("an ambiguous container reference is a 400 in both dialects")
    func ambiguousReferenceIsBadRequest() async throws {
        let fake = FakePs(output: "")
        let mock = TopClientMock(
            containers: [],
            getContainerError: ClientContainerError.ambiguousId(reference: "c1", matches: ["c1a", "c1b"])
        )
        try await withTopApp(ContainerTopRoute(client: mock, runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/containers/c1/top") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
        try await withTopApp(LibpodContainerTopRoute(client: mock, runPs: makeRunner(fake))) { app in
            try await app.testing().test(.GET, "/v1.51/libpod/containers/c1/top") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }
}
