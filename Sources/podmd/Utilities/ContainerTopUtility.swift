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
    /// line a `Processes` row.
    ///
    /// The two dialects disagree on rows wider than the header (a COMMAND
    /// column with arguments splits into several whitespace fields):
    /// - moby leaves the row split, so rows can be longer than `Titles`;
    /// - podman's handler assumes the last column is the command and merges
    ///   the extras back into it, keeping every row exactly `Titles.count`
    ///   wide. `rejoinCommandExtras` selects podman's behavior.
    ///
    /// Empty or unparseable output (e.g. an image whose ps failed) yields an
    /// empty report rather than an error, matching how minimal images behave.
    static func parse(_ output: String, rejoinCommandExtras: Bool) -> TopReport {
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
            if rejoinCommandExtras, fields.count > titles.count {
                // podman (pkg/api/handlers/compat/containers_top.go): "Docker
                // assumes the last entry is *always* command which can include
                // spaces. So combine any extras."
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

    /// libpod dialect: podman's remote CLI sends ps(1) AIX format descriptors
    /// — one per repeated `ps_args` query value (`ps_args=user&ps_args=pid`)
    /// or comma-joined in one (`ps_args=user,pid`); the newer `descriptors`
    /// parameter carries the same values. Since we exec real ps instead of
    /// reading /proc via psgo, descriptors map to `ps -o d1,d2,...` (procps
    /// and busybox ps both accept that). Values that already look like flags
    /// (leading "-") pass through unchanged. `[]` means "no args given".
    static func libpodArgv(psArgs: [String]) -> [String] {
        let tokens =
            psArgs
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { descriptorAliases[$0] ?? $0 }
        guard !tokens.isEmpty else { return [] }
        if tokens.contains(where: { $0.hasPrefix("-") }) {
            return tokens
        }
        return ["-o", tokens.joined(separator: ",")]
    }

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
        typealias PsOutput = (exitCode: Int32, stdout: Data, stderr: Data)
        let outcome: PsOutput? = await withTaskGroup(of: PsOutput?.self) { group in
            group.addTask {
                try? await pipes.collectOutput {
                    await ContainerExitCodeStore.resolveExitCode(wait: { try await process.wait() })
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: execTimeoutNs)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let outcome else {
            // Timed out: kill ps so Apple closes the write ends (letting the
            // background drain tasks finish and close the read fds), then
            // report an empty table rather than hanging the request.
            try? await process.kill(SIGTERM)
            return ""
        }
        let text = String(data: outcome.stdout, encoding: .utf8) ?? ""
        return filterPsSelfRow(text, command: (["ps"] + arguments).joined(separator: " "))
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
    static func top(
        client: ClientContainerProtocol,
        containerId: String,
        psArgs: [String],
        rejoinCommandExtras: Bool,
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
        return parse(output, rejoinCommandExtras: rejoinCommandExtras)
    }
}
