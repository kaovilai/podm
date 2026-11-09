import ContainerAPIClient
import ContainerResource
import Foundation
import Vapor

/// Response body shared by both top dialects — moby's `ContainerTopOKBody`
/// and podman's libpod `TopReport` use the same shape:
/// `{"Titles": ["UID", "PID", ...], "Processes": [["root", "1", ...], ...]}`.
struct TopReport: Content {
    let Titles: [String]
    let Processes: [[String]]
}

/// Shared implementation for `docker top` / `podman top`.
///
/// Container processes are NOT visible from the macOS host — each container
/// is its own microVM — so this runs `ps` INSIDE the container via
/// `ContainerClient.createProcess` (same machinery as exec) and parses the
/// table it prints. Neither Docker nor podman parses ps output for us here:
/// moby runs `ps` host-side (filtered by container pids) and podman reads
/// `/proc` via psgo; both then split the first line into `Titles` and the
/// rest into `Processes` rows.
enum ContainerTopUtility {

    /// moby's `daemon/top_unix.go` defaults to `-ef` when no ps_args are
    /// given; podman's compat handler does the same for non-libpod requests.
    static let defaultPsArgs = ["-ef"]

    /// Runs `ps <arguments>` inside the container and returns its stdout.
    /// A seam so route tests can inject canned ps output — the real daemon
    /// uses `execPs(container:arguments:)`.
    typealias PsRunner = @Sendable (ContainerSnapshot, [String]) async throws -> String

    /// Upper bound for one `ps` run. Apple Container's XPC `wait()` can stall
    /// (see ExecRoutes); a hung ps must not hang the HTTP request forever.
    /// ps finishes in well under a second — 10s is pure stall headroom.
    private static let execTimeoutNs: UInt64 = 10_000_000_000

    // MARK: - ps output parsing

    /// moby's `fieldsASCII`: split on ASCII whitespace only (a command
    /// containing non-ASCII spaces, e.g. U+00A0, must NOT split), dropping
    /// empty fields. This also swallows `\r` from CRLF output — note that in
    /// Swift "\r\n" is a single Character (grapheme cluster), so it needs its
    /// own comparison to match at all.
    private static func fieldsASCII(_ line: Substring) -> [String] {
        line.split(whereSeparator: { ch in
            guard ch.isASCII || ch == "\r\n" else { return false }
            return ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "\r\n" || ch == "\u{0B}" || ch == "\u{0C}"
        }).map(String.init)
    }

    /// Parses `ps` output: the first line becomes `Titles`, every following
    /// line a `Processes` row. Rows wider than the header (a COMMAND column
    /// with arguments splits into several whitespace fields) are merged back
    /// into the last column, keeping every row exactly `Titles.count` wide —
    /// moby v28.5.2 `appendProcess2ProcList` ("merging overhanging fields")
    /// and podman's compat handler ("combine any extras") both do this.
    ///
    /// Empty output from a successful ps yields an empty report rather than
    /// an error, matching how minimal images behave.
    static func parse(_ output: String) -> TopReport {
        // Split on "\n" AND the combined "\r\n" Character — in Swift they are
        // distinct Characters, so a plain `split(separator: "\n")` would leave
        // CRLF output as one giant line.
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        guard let header = lines.first else {
            return TopReport(Titles: [], Processes: [])
        }
        let titles = fieldsASCII(header)
        guard !titles.isEmpty else {
            return TopReport(Titles: [], Processes: [])
        }
        var processes: [[String]] = []
        for line in lines.dropFirst() {
            let fields = fieldsASCII(line)
            guard !fields.isEmpty else { continue }
            if fields.count > titles.count {
                // moby appendProcess2ProcList: "Make sure number of fields
                // equals number of header titles merging 'overhanging'
                // fields" — same words in podman's compat handler ("combine
                // any extras").
                let lastColumn = titles.count - 1
                let command = fields[lastColumn...].joined(separator: " ")
                var row = Array(fields[0..<lastColumn])
                row.append(command)
                processes.append(row)
            } else {
                processes.append(fields)
            }
        }
        return TopReport(Titles: titles, Processes: processes)
    }

    // MARK: - ps args

    /// Docker dialect: one `ps_args` string of raw ps flags ("aux", "-ef").
    /// moby splits it on spaces and passes the tokens to ps; empty tokens are
    /// dropped here because an empty argv element would reach the container's
    /// ps as a literal empty argument. `[]` means "no args given" — the caller
    /// then applies `defaultPsArgs`.
    static func dockerArgv(psArgs: String?) -> [String] {
        guard let psArgs, !psArgs.isEmpty else { return [] }
        return psArgs.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// libpod dialect ps arguments plus the post-parse fixups `top()` must
    /// apply. `appendedCommandColumn`: an `args` column was appended purely
    /// so the self-row filter has a command line — strip it from the report.
    /// `reorder`: the command column was rendered LAST internally (parse
    /// merges overhanging words into the last column, which is only correct
    /// when that column is the command) — reorder parsed columns back to the
    /// requested order through this permutation (requested position →
    /// internal index).
    struct LibpodTopArgs: Equatable, Sendable {
        let argv: [String]
        let appendedCommandColumn: Bool
        let reorder: [Int]?

        init(argv: [String], appendedCommandColumn: Bool = false, reorder: [Int]? = nil) {
            self.argv = argv
            self.appendedCommandColumn = appendedCommandColumn
            self.reorder = reorder
        }
    }

    /// libpod dialect: podman's remote CLI sends ps(1) AIX format descriptors
    /// — one per repeated `ps_args` query value (`ps_args=user&ps_args=pid`)
    /// or comma-joined in one (`ps_args=user,pid`); the newer `descriptors`
    /// parameter carries the same values.
    ///
    /// podman's own decision (`libpod/container_top_linux.go` `Top`): the
    /// comma-split tokens must ALL be known psgo descriptors — on
    /// `ErrUnknownDescriptor` it falls back to treating the ORIGINAL values
    /// as a ps(1) command line (a single value shlex-split on spaces, commas
    /// preserved, so `ps -o pid,args` survives). We mirror that: known
    /// descriptors map to `ps -eo d1,d2,...` (we exec real ps instead of
    /// reading /proc via psgo), anything else passes through as raw ps
    /// arguments. The `-e` matters: procps with only `-o` selects the current
    /// user's tty-attached processes (in a container, usually nothing) —
    /// busybox ps ignores it harmlessly (it never filters).
    ///
    /// Column fixups (see LibpodTopArgs): only `args` carries the full
    /// command line the self-row filter matches on — `comm` is just the
    /// executable name, so a `comm`-only request still gets `args` appended.
    /// A command column that is not LAST is rendered last internally and
    /// restored to the requested position after parsing, because parse()
    /// merges overhanging command words into the last column.
    /// `[]` means "no args given" — the caller then applies `defaultPsArgs`.
    static func libpodArgv(psArgs: [String]) -> LibpodTopArgs {
        let trimmed = psArgs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return LibpodTopArgs(argv: []) }
        // Raw ps-argument mode is decided on the ORIGINAL values, before any
        // comma-splitting or aliasing: a leading dash is always a flag, and
        // comma-splitting "-o pid,args" would destroy the option value.
        if trimmed.contains(where: { $0.hasPrefix("-") }) {
            return LibpodTopArgs(argv: shlexSplitSingle(trimmed))
        }
        let tokens =
            trimmed
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if tokens.allSatisfy({ isKnownDescriptor($0) }) {
            let mapped = tokens.map { descriptorAliases[$0] ?? $0 }
            let commandCount = mapped.filter { $0 == "args" }.count
            guard commandCount > 0 else {
                // No command column at all: append args so the self-row filter
                // has a command line to match on; top() strips it after.
                return LibpodTopArgs(
                    argv: ["-eo", (mapped + ["args"]).joined(separator: ",")],
                    appendedCommandColumn: true)
            }
            if commandCount == 1, mapped.last == "args" {
                // Single command column, already last — ps output merges
                // cleanly as-is, no fixups needed.
                return LibpodTopArgs(argv: ["-eo", mapped.joined(separator: ",")])
            }
            // Otherwise render exactly ONE args column last (repeated command
            // descriptors collapse onto it — `command,pid,command` must not
            // produce a duplicated internal args column, which would corrupt
            // parsing), then restore the requested order after parsing: every
            // requested command position maps to that single internal column.
            let nonCommand = mapped.filter { $0 != "args" }
            let internalColumns = nonCommand + ["args"]
            var permutation: [Int] = []
            var nonCommandPosition = 0
            for column in mapped {
                if column == "args" {
                    permutation.append(internalColumns.count - 1)
                } else {
                    permutation.append(nonCommandPosition)
                    nonCommandPosition += 1
                }
            }
            return LibpodTopArgs(
                argv: ["-eo", internalColumns.joined(separator: ",")],
                reorder: permutation)
        }
        // Unknown descriptor → ps(1) arguments (podman's ErrUnknownDescriptor
        // fallback): "aux" and friends reach the container's ps verbatim.
        return LibpodTopArgs(argv: shlexSplitSingle(trimmed))
    }

    /// podman (google/shlex, containers/podman#12452) splits a single
    /// descriptor string into a ps(1) argv; several separate values are
    /// already an argv. This is a quote/escape-aware shell-word splitter
    /// (single quotes, double quotes, backslash escapes) so a value like
    /// `-eo 'pid,args'` reaches ps as two clean words, quotes stripped.
    private static func shlexSplitSingle(_ values: [String]) -> [String] {
        guard values.count == 1 else { return values }
        return shellWords(values[0])
    }

    /// Minimal shlex: splits on unquoted whitespace, honors '…', "…", and
    /// backslash escapes; empty words are dropped.
    private static func shellWords(_ input: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasWord = false
        var iterator = input.makeIterator()
        while let ch = iterator.next() {
            switch ch {
            case " ", "\t":
                if hasWord {
                    words.append(current)
                    current = ""
                    hasWord = false
                }
            case "'":
                // Single-quoted: everything until the closing quote is literal.
                while let inner = iterator.next(), inner != "'" {
                    current.append(inner)
                }
                hasWord = true
            case "\"":
                // Double-quoted: backslash escapes are honored.
                while let inner = iterator.next(), inner != "\"" {
                    if inner == "\\", let escaped = iterator.next() {
                        current.append(escaped)
                    } else {
                        current.append(inner)
                    }
                }
                hasWord = true
            case "\\":
                if let escaped = iterator.next() {
                    current.append(escaped)
                }
                hasWord = true
            default:
                current.append(ch)
                hasWord = true
            }
        }
        if hasWord {
            words.append(current)
        }
        return words
    }

    /// The descriptors psgo accepts without falling back to ps(1) (its AIX
    /// format set, per podman's top(1) documentation), plus the ps(1)
    /// spellings we alias — anything else is a raw ps argument as far as the
    /// decision is concerned.
    private static func isKnownDescriptor(_ token: String) -> Bool {
        psgoDescriptors.contains(token) || descriptorAliases[token] != nil
    }

    private static let psgoDescriptors: Set<String> = [
        "args", "comm", "%cpu", "pcpu", "cgroup", "etime", "gid", "group", "%mem", "pmem",
        "pid", "ppid", "time", "tty", "uid", "user", "%vmem", "pvmem",
        "nice", "pgid", "rgroup", "ruser", "vsz", "rss", "stat",
    ]

    /// procps accepts both spellings, busybox ps only the short ones — the
    /// aliases normalize to a name both implementations understand.
    private static let descriptorAliases = ["command": "args", "cmd": "args", "elapsed": "etime"]

    // MARK: - execution

    /// Runs `ps` inside `container`'s VM and captures its stdout.
    ///
    /// Apple Container stdio fd ownership: `StdioPipes` allocates the pipe
    /// pairs, `closeAll()` on createProcess failure, `closeAfterHandoff()` on
    /// start failure — never Foundation `Pipe()` (issue #107).
    static func execPs(container: ContainerSnapshot, arguments: [String]) async throws -> String {
        guard let pipes = StdioPipes.make([.stdout, .stderr]) else {
            throw Abort(.internalServerError, reason: "Failed to create I/O pipes")
        }

        var processConfig = container.configuration.initProcess
        processConfig.executable = "ps"
        processConfig.arguments = arguments
        processConfig.terminal = false
        // ps runs as root, mirroring moby (host-side ps) and podman's
        // healthcheck-style exec — a non-root container user could lack
        // permission to see other processes' rows.
        processConfig.user = .id(uid: 0, gid: 0)

        let process: ClientProcess
        do {
            process = try await ContainerClient().createProcess(
                containerId: container.id,
                processId: "top-\(UUID().uuidString.lowercased())",
                configuration: processConfig,
                stdio: pipes.stdioArray
            )
        } catch {
            pipes.closeAll()
            throw Abort(.internalServerError, reason: "Failed to create ps process in container: \(error)")
        }
        do {
            try await process.start()
        } catch {
            pipes.closeAfterHandoff()
            throw Abort(.internalServerError, reason: "Failed to run ps in container: \(error)")
        }

        // Race the output collection against a timeout. Draining happens
        // before waiting (via collectOutput) so a ps writing more than the
        // pipe buffer can't deadlock, and the wait goes through the bounded
        // retry helper so a transient XPC error doesn't fail the request.
        //
        // The collector is an UNSTRUCTURED task, not a task-group child: a
        // group's scope waits for every child at exit, and cancellation
        // doesn't unblock a stalled XPC wait() or the detached pipe readers —
        // the timeout branch would never actually return. Racing this way,
        // the request path never awaits the collector after the deadline.
        // The collector reports Result so a COLLECTION error (pipe read
        // failure) stays distinguishable from a timeout.
        typealias PsOutput = (exitCode: Int32, stdout: Data, stderr: Data)
        let collector = Task<Result<PsOutput, Error>?, Never> {
            do {
                return .success(
                    try await pipes.collectOutput {
                        await ContainerExitCodeStore.resolveExitCode(wait: { try await process.wait() })
                    })
            } catch {
                return .failure(error)
            }
        }
        let outcome = await raceFirstOrTimeout(collector, timeoutNs: execTimeoutNs)

        guard let outcome else {
            // Timed out: kill ps so Apple closes the write ends (letting the
            // collector's drain tasks finish and close the read fds), then
            // fail the request — a stalled ps must not masquerade as "no
            // processes" in a 200 empty table. If even the kill doesn't
            // unblock a dead XPC wait, the collector leaks — the request is
            // already home.
            try? await process.kill(SIGTERM)
            throw Abort(
                .internalServerError,
                reason: "ps in container \(container.id) did not finish within \(execTimeoutNs / 1_000_000_000)s"
            )
        }
        // A collection failure (e.g. a pipe read error) is not "no processes"
        // either — surface it instead of silently returning an empty table.
        let output: PsOutput
        switch outcome {
        case .success(let collected): output = collected
        case .failure(let error):
            throw Abort(.internalServerError, reason: "Failed to collect ps output from container: \(error)")
        }
        // A failed ps must not masquerade as "no processes": report it with
        // the captured diagnostic (moby surfaces host-ps failures too).
        guard output.exitCode == 0 else {
            let diagnostic =
                String(data: output.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Abort(
                .internalServerError,
                reason: "ps failed in container (exit \(output.exitCode))\(diagnostic.isEmpty ? "" : ": \(diagnostic)")"
            )
        }
        let text = String(data: output.stdout, encoding: .utf8) ?? ""
        return filterPsSelfRow(text, command: (["ps"] + arguments).joined(separator: " "))
    }

    /// Resumes with the task's result, or `nil` if the timeout elapses first.
    /// The loser is never awaited on the winning path: whichever finishes
    /// second finds the continuation already consumed and is ignored.
    private static func raceFirstOrTimeout<T: Sendable>(_ task: Task<T?, Never>, timeoutNs: UInt64) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(cont)
            Task {
                once.resume(returning: await task.value)
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                once.resume(returning: nil)
            }
        }
    }

    /// One-shot continuation wrapper — the second resume is a no-op instead
    /// of a fatal error (the losing racer is guaranteed to fire late).
    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        init(_ continuation: CheckedContinuation<T, Never>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: value)
        }
    }

    /// moby runs ps on the HOST filtered to the container's pids, so the ps
    /// process itself never shows; podman execs ps in the container and drops
    /// its own row afterwards ("filter the ps command from the output instead
    /// of checking/requiring PIDs"). We exec inside like podman, so we apply
    /// the same line filter for both dialects. Trade-off (shared with podman):
    /// a container process whose command line literally contains our ps
    /// invocation is dropped too.
    static func filterPsSelfRow(_ output: String, command: String) -> String {
        guard !command.isEmpty else { return output }
        let kept =
            output
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .filter { !$0.contains(command) }
        return kept.joined(separator: "\n")
    }

    /// Resolves the container, checks it is running, runs ps inside it and
    /// parses the output. Shared by the Docker and libpod top routes.
    /// `appendedCommandColumn` strips the trailing `args` column that
    /// `libpodArgv` adds when the requested descriptors have no command
    /// column — it existed only so the self-row filter could match.
    /// `reorder` restores the requested column order when the command column
    /// had to be rendered last internally.
    static func top(
        client: ClientContainerProtocol,
        containerId: String,
        psArgs: [String],
        appendedCommandColumn: Bool = false,
        reorder: [Int]? = nil,
        runPs: PsRunner = execPs
    ) async throws -> TopReport {
        let container: ContainerSnapshot
        do {
            guard let found = try await client.getContainer(id: containerId) else {
                // Docker phrasing ("No such container: <id>") is load-bearing —
                // see the matching comment in ContainerInspectRoute.
                throw Abort(.notFound, reason: "No such container: \(containerId)")
            }
            try client.enforceContainerRunning(container: found)
            container = found
        } catch ClientContainerError.notRunning {
            // Docker returns 409 for `top` on a container that is not running.
            throw Abort(.conflict, reason: "Container is not running")
        } catch ClientContainerError.ambiguousId(let reference, let matches) {
            throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matches.joined(separator: ", "))")
        }

        let arguments = psArgs.isEmpty ? defaultPsArgs : psArgs
        let output = try await runPs(container, arguments)
        var report = parse(output)
        if appendedCommandColumn {
            report = TopReport(
                Titles: Array(report.Titles.dropLast()),
                Processes: report.Processes.map { Array($0.dropLast()) }
            )
        }
        if let reorder, !report.Titles.isEmpty {
            // Requested position → internal index; rows can be shorter than
            // the header (ps omits trailing empty columns), hence the bounds
            // check instead of a force-unwrap.
            func column(_ row: [String], at index: Int) -> String {
                row.indices.contains(index) ? row[index] : ""
            }
            report = TopReport(
                Titles: reorder.map { column(report.Titles, at: $0) },
                Processes: report.Processes.map { row in reorder.map { column(row, at: $0) } }
            )
        }
        return report
    }
}
