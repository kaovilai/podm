import Foundation
import Vapor

/// Errors raised while applying `docker import --change` (Dockerfile-instruction-like)
/// directives to a synthesized image config.
enum DockerfileChangeError: Error, LocalizedError {
    case invalidInstruction(String)
    case invalidValue(instruction: String, value: String)

    var errorDescription: String? {
        switch self {
        case .invalidInstruction(let instruction):
            return "\(instruction) is not a supported --change instruction"
        case .invalidValue(let instruction, let value):
            return "invalid value for \(instruction): \(value)"
        }
    }
}

/// Accumulates the subset of `container_config`/OCI image config fields that
/// `docker import --change` can set. Serialized by `ContainerImageUtility` as the
/// image config's `config` object, matching Docker's PascalCase field names —
/// including `ExposedPorts`/`Volumes`, which `ContainerizationOCI.ImageConfig`
/// does not model but which `ImageStore.load` decodes past without error (extra
/// JSON keys are simply ignored), so they still round-trip through the store.
struct SynthesizedImageConfig {
    var user: String?
    var exposedPorts: Set<String> = []
    var env: [String] = []
    var entrypoint: [String]?
    var cmd: [String]?
    var volumes: Set<String> = []
    var workingDir: String?
    var labels: [String: String] = [:]
    /// moby's `container.Config.StopSignal` — settable by `docker commit`'s
    /// body `Config.StopSignal` and by a `STOPSIGNAL` --change on both import
    /// and commit (moby's `validCommitCommands` includes it for both).
    /// Serialized with Docker's PascalCase key (`StopSignal`), the extension
    /// key the OCI image-config JSON carries it under.
    var stopSignal: String?
    /// moby's `container.Config.Healthcheck` — settable by `docker commit`'s
    /// body `Config.Healthcheck`, the container's effective healthcheck, and
    /// a `HEALTHCHECK` --change on both import and commit (moby's
    /// `validCommitCommands` includes it for both). Serialized as the config
    /// object's `Healthcheck` (Test/Interval/Timeout/Retries/StartPeriod/
    /// StartInterval), matching the docker-shape `HealthcheckConfig` model.
    var healthcheck: HealthcheckConfig?

    mutating func setEnv(key: String, value: String) {
        let prefix = "\(key)="
        if let index = env.firstIndex(where: { $0.hasPrefix(prefix) }) {
            env[index] = "\(key)=\(value)"
        } else {
            env.append("\(key)=\(value)")
        }
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let user, !user.isEmpty { dict["User"] = user }
        if !exposedPorts.isEmpty { dict["ExposedPorts"] = emptyObjectMap(for: exposedPorts) }
        if !env.isEmpty { dict["Env"] = env }
        if let entrypoint { dict["Entrypoint"] = entrypoint }
        if let cmd { dict["Cmd"] = cmd }
        if !volumes.isEmpty { dict["Volumes"] = emptyObjectMap(for: volumes) }
        if let workingDir, !workingDir.isEmpty { dict["WorkingDir"] = workingDir }
        if !labels.isEmpty { dict["Labels"] = labels }
        if let stopSignal, !stopSignal.isEmpty { dict["StopSignal"] = stopSignal }
        if let healthcheck {
            // `HealthcheckConfig` is Codable with Docker's exact key shape, so
            // round-trip it through JSON to get the nested dictionary
            // `JSONSerialization`-based config writer needs.
            if let data = try? JSONEncoder().encode(healthcheck),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            {
                dict["Healthcheck"] = object
            }
        }
        return dict
    }

    private func emptyObjectMap(for keys: Set<String>) -> [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, [:]) })
    }
}

/// Applies `--change` directives (one Dockerfile instruction per entry) to a
/// `SynthesizedImageConfig`, for both `docker import --change` and
/// `docker commit --change` (moby runs both through `BuildFromConfig`, whose
/// `validCommitCommands` set defines the grammar). Supports: CMD, ENTRYPOINT,
/// ENV, EXPOSE, HEALTHCHECK, LABEL, STOPSIGNAL, USER, VOLUME, WORKDIR.
/// ONBUILD is valid for moby's commit but is not modeled by the synthesized
/// config, so it — and any genuinely unknown instruction — is rejected rather
/// than silently dropped.
enum DockerfileChangeApplier {
    /// - Parameters:
    ///   - baseWorkingDir: the directory a RELATIVE `WORKDIR` resolves
    ///     against when the config does not already carry one — moby's
    ///     `BuildFromConfig` starts from whatever config the caller seeded:
    ///     the container's config for a BODY-LESS commit (so its working
    ///     directory is the base) or the request body's config for a commit
    ///     with a body and an empty config for import (so the base is `/`).
    ///     `nil` behaves like the import/sparse-body case: relative paths
    ///     anchor at `/`.
    static func apply(
        _ changes: [String],
        to config: inout SynthesizedImageConfig,
        baseWorkingDir: String? = nil
    ) throws {
        // moby's `d.state.cmdSet` — set by `dispatchCmd` for a non-empty
        // command, consulted by `dispatchEntrypoint`'s Cmd-clearing below.
        // `BuildFromConfig` starts a FRESH state, so a Cmd the config carried
        // before the changes (pre-seeded from the container by a body-less
        // commit, or set by the request body) never counts as cmdSet.
        var cmdSetByChange = false
        for change in changes {
            try applyOne(change, to: &config, baseWorkingDir: baseWorkingDir, cmdSetByChange: &cmdSetByChange)
        }
    }

    private static func applyOne(
        _ change: String,
        to config: inout SynthesizedImageConfig,
        baseWorkingDir: String?,
        cmdSetByChange: inout Bool
    ) throws {
        let trimmed = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let separatorIndex = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            throw DockerfileChangeError.invalidInstruction(trimmed)
        }
        let instruction = trimmed[..<separatorIndex].uppercased()
        let rest = trimmed[trimmed.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else {
            throw DockerfileChangeError.invalidValue(instruction: instruction, value: "")
        }

        switch instruction {
        case "CMD":
            let cmd = try parseExecOrShellForm(instruction: instruction, rest)
            config.cmd = cmd
            // moby's dispatchCmd: `if len(c.ShellDependantCmdLine.CmdLine) != 0
            // { d.state.cmdSet = true }` — only a NON-EMPTY command marks Cmd
            // as set; `CMD []` does not.
            if !cmd.isEmpty { cmdSetByChange = true }
        case "ENTRYPOINT":
            config.entrypoint = try parseExecOrShellForm(instruction: instruction, rest)
            // moby's dispatchEntrypoint: `if !d.state.cmdSet {
            // runConfig.Cmd = nil }` — an ENTRYPOINT clears whatever Cmd the
            // config carried (pre-seeded from the container by a body-less
            // commit, or set by the request body) unless a prior CMD change
            // set it.
            if !cmdSetByChange { config.cmd = nil }
        case "ENV": try applyEnv(rest, to: &config)
        case "LABEL": try applyLabels(rest, to: &config)
        case "USER": config.user = rest
        case "WORKDIR":
            config.workingDir = resolveWorkdir(
                rest, current: (config.workingDir ?? "").isEmpty ? nil : config.workingDir, base: baseWorkingDir)
        case "EXPOSE": config.exposedPorts.formUnion(parsePorts(rest))
        case "VOLUME": config.volumes.formUnion(try parseVolumes(instruction: instruction, rest))
        case "STOPSIGNAL": try applyStopSignal(rest, to: &config)
        case "HEALTHCHECK": try applyHealthcheck(rest, to: &config)
        default:
            throw DockerfileChangeError.invalidInstruction(instruction)
        }
    }

    /// moby's `normalizeWorkdir`: an absolute path passes through cleaned; a
    /// relative one joins onto the CURRENT working directory (the config's
    /// own, else the threaded-in base), anchored at `/` — moby's
    /// `filepath.Join(string(os.PathSeparator), current, requested)` always
    /// produces an absolute, cleaned path.
    private static func resolveWorkdir(_ requested: String, current: String?, base: String?) -> String {
        if requested.hasPrefix("/") {
            return cleanPath(requested)
        }
        let currentDir = current ?? base ?? ""
        return cleanPath("/" + currentDir + "/" + requested)
    }

    /// Lexical POSIX path cleaning, Go's `path.Clean`: collapses duplicate
    /// slashes, drops `.` segments, resolves `..` against the previous
    /// segment (a leading `..` survives only on relative paths), and strips
    /// trailing separators.
    private static func cleanPath(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var segments: [String] = []
        for segment in path.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..":
                if segments.last != nil, segments.last != ".." {
                    segments.removeLast()
                } else if !absolute {
                    segments.append("..")
                }
            default:
                segments.append(String(segment))
            }
        }
        let joined = segments.joined(separator: "/")
        if absolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    /// `STOPSIGNAL <signal>` — moby's dispatcher validates through
    /// `signal.ParseSignal` before setting; exactly one argument.
    private static func applyStopSignal(_ rest: String, to config: inout SynthesizedImageConfig) throws {
        let tokens = try tokenize(rest, instruction: "STOPSIGNAL")
        guard tokens.count == 1 else {
            throw DockerfileChangeError.invalidValue(instruction: "STOPSIGNAL", value: rest)
        }
        guard DockerSignal.isValid(tokens[0]) else {
            throw DockerfileChangeError.invalidValue(instruction: "STOPSIGNAL", value: tokens[0])
        }
        config.stopSignal = tokens[0]
    }

    /// `HEALTHCHECK [--interval=<dur>|--timeout=<dur>|--start-period=<dur>|
    /// --start-interval=<dur>|--retries=<n>] CMD <command>` or
    /// `HEALTHCHECK NONE`, with moby's dispatcher semantics: the exec form
    /// (`CMD ["a","b"]`) produces `Test = ["CMD", "a", "b"]`, the shell form
    /// `Test = ["CMD-SHELL", <command>]`, and `NONE` the disable marker
    /// `Test = ["NONE"]`. Flags are the LEADING `--name=value` tokens (the
    /// Dockerfile line parser hands them to the dispatcher separately, and
    /// buildkit's bflag requires the `=`); durations use Go's
    /// `time.ParseDuration` grammar and land in the config as nanoseconds,
    /// with zero meaning unset.
    private static func applyHealthcheck(_ rest: String, to config: inout SynthesizedImageConfig) throws {
        let knownFlags: Set<String> = ["interval", "timeout", "start-period", "start-interval", "retries"]
        var flags: [String: String] = [:]
        var remainder: Substring? = Substring(rest)
        while let current = remainder {
            let (token, after) = splitFirstToken(current)
            guard token.hasPrefix("--") else { break }
            // The POSIX `--` delimiter ends flag processing (buildkit's
            // bflag does the same), so `HEALTHCHECK -- CMD true` parses.
            if token == "--" {
                remainder = after
                break
            }
            guard let equals = token.firstIndex(of: "="), equals > token.index(token.startIndex, offsetBy: 2) else {
                throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: String(token))
            }
            let name = String(token[token.index(token.startIndex, offsetBy: 2)..<equals])
            let value = String(token[token.index(after: equals)...])
            guard knownFlags.contains(name) else {
                throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: String(token))
            }
            guard flags[name] == nil else {
                throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: String(token))
            }
            flags[name] = value
            remainder = after
        }

        guard let typeRemainder = remainder else {
            throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: rest)
        }
        let (typToken, afterTyp) = splitFirstToken(typeRemainder)
        switch typToken.uppercased() {
        case "NONE":
            // moby: "HEALTHCHECK NONE takes no arguments" — the flags it may
            // carry are dropped without being validated.
            guard afterTyp == nil || afterTyp?.isEmpty == true else {
                throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: "NONE \(afterTyp ?? "")")
            }
            config.healthcheck = HealthcheckConfig(
                Test: ["NONE"], Interval: nil, Timeout: nil, Retries: nil, StartPeriod: nil)
        case "CMD":
            let command = afterTyp.map(String.init) ?? ""
            guard !command.isEmpty else {
                throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: rest)
            }
            let test: [String]
            if command.hasPrefix("[") {
                guard let data = command.data(using: .utf8),
                    let array = try? JSONDecoder().decode([String].self, from: data)
                else {
                    throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: command)
                }
                test = ["CMD"] + array
            } else {
                test = ["CMD-SHELL", String(command)]
            }
            config.healthcheck = HealthcheckConfig(
                Test: test,
                Interval: try parseHealthcheckDuration(flags["interval"], flag: "interval"),
                Timeout: try parseHealthcheckDuration(flags["timeout"], flag: "timeout"),
                Retries: try parseHealthcheckRetries(flags["retries"]),
                StartPeriod: try parseHealthcheckDuration(flags["start-period"], flag: "start-period"),
                StartInterval: try parseHealthcheckDuration(flags["start-interval"], flag: "start-interval"))
        default:
            throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: String(typToken))
        }
    }

    /// Go's `time.ParseDuration` (subset: no sign, the units Dockerfiles
    /// use) → nanoseconds. Empty and zero durations parse as nil — moby's
    /// `parseOptInterval` maps 0 to "unset", which the commit merge then
    /// fills from the container's healthcheck. Non-zero durations below 1ms
    /// are rejected, matching moby's `minimumDuration`.
    private static func parseHealthcheckDuration(_ raw: String?, flag: String) throws -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        let units: [Substring: Int64] = [
            "ns": 1, "us": 1_000, "µs": 1_000, "ms": 1_000_000,
            "s": 1_000_000_000, "m": 60_000_000_000, "h": 3_600_000_000_000,
        ]
        var rest = Substring(raw)
        var total: Double = 0
        var parsedComponent = false
        while !rest.isEmpty {
            // Number: digits with an optional single '.' and fraction digits.
            var numberEnd = rest.startIndex
            var seenDot = false
            while numberEnd < rest.endIndex {
                let char = rest[numberEnd]
                if char.isNumber {
                    numberEnd = rest.index(after: numberEnd)
                } else if char == "." && !seenDot {
                    seenDot = true
                    numberEnd = rest.index(after: numberEnd)
                } else {
                    break
                }
            }
            // Go's time.ParseDuration accepts a bare "0" with no unit
            // (only nonzero values require one); mirror that so
            // `--interval=0` means unset rather than invalid. FIRST
            // component only — after e.g. "5s" a trailing "0" is garbage
            // Go rejects, not a fresh zero that may silently discard the
            // accumulated duration.
            if !parsedComponent, numberEnd == rest.endIndex, rest == "0" {
                return nil
            }
            let numberText = rest[..<numberEnd]
            guard !numberText.isEmpty, numberText != ".", let value = Double(numberText) else {
                throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: "\(flag)=\(raw)")
            }
            // Unit: everything up to the next number or dot.
            var unitEnd = numberEnd
            while unitEnd < rest.endIndex, !rest[unitEnd].isNumber, rest[unitEnd] != "." {
                unitEnd = rest.index(after: unitEnd)
            }
            guard let unitNanos = units[rest[numberEnd..<unitEnd]] else {
                throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: "\(flag)=\(raw)")
            }
            total += value * Double(unitNanos)
            rest = rest[unitEnd...]
            parsedComponent = true
        }
        // `Double(Int64.max)` rounds UP to exactly 2^63, so a `<=` bound would
        // ADMIT totals that round to 2^63 (e.g. 9223372036854775807ns) and
        // the `Int64(total)` below would trap. The strict `<` rejects 2^63
        // and every Double above it; the largest Double below 2^63 is
        // 2^63 - 2^10, itself a valid Int64, so the conversion can never
        // trap. Infinite totals (absurdly long digit strings multiply out to
        // +inf) fail this guard too.
        guard parsedComponent, total >= 0, total < Double(Int64.max) else {
            throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: "\(flag)=\(raw)")
        }
        let nanoseconds = Int64(total)
        if nanoseconds == 0 { return nil }
        guard nanoseconds >= 1_000_000 else {
            throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: "\(flag)=\(raw)")
        }
        return Int(nanoseconds)
    }

    /// `--retries=<n>`: a non-negative integer (moby: ParseInt base 10,
    /// "cannot be negative").
    private static func parseHealthcheckRetries(_ raw: String?) throws -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let retries = Int(raw), retries >= 0 else {
            throw DockerfileChangeError.invalidValue(instruction: "HEALTHCHECK", value: "retries=\(raw)")
        }
        return retries
    }

    /// CMD/ENTRYPOINT accept either JSON exec form (`["a", "b"]`) or shell form,
    /// which Docker wraps as `["/bin/sh", "-c", <rest>]`.
    private static func parseExecOrShellForm(instruction: String, _ rest: String) throws -> [String] {
        if rest.hasPrefix("[") {
            guard let data = rest.data(using: .utf8),
                let array = try? JSONDecoder().decode([String].self, from: data)
            else {
                throw DockerfileChangeError.invalidValue(instruction: instruction, value: rest)
            }
            return array
        }
        return ["/bin/sh", "-c", rest]
    }

    /// `ENV KEY=VALUE ...` (one or more pairs) or the legacy `ENV KEY VALUE` form.
    private static func applyEnv(_ rest: String, to config: inout SynthesizedImageConfig) throws {
        try applyKeyValuePairs(rest, instruction: "ENV") { key, value in
            config.setEnv(key: key, value: value)
        }
    }

    /// `LABEL KEY=VALUE ...`, quoting allowed for values containing spaces.
    private static func applyLabels(_ rest: String, to config: inout SynthesizedImageConfig) throws {
        try applyKeyValuePairs(rest, instruction: "LABEL") { key, value in
            config.labels[key] = value
        }
    }

    /// Shared `ENV`/`LABEL` grammar: one or more `KEY=VALUE` pairs (quoting and
    /// backslash-escaping honored per pair), or the legacy `KEY VALUE` form —
    /// used only when the first word has no `=`, in which case the ENTIRE
    /// remainder of the line (internal whitespace preserved, not re-split into
    /// further words) becomes the single value. Verified against real
    /// `docker build` (BuildKit) output: `ENV FOO bar=1 baz=2` sets one
    /// variable `FOO="bar=1 baz=2"`, and `ENV NAME   spaced   out` preserves
    /// the internal run of spaces — both are legacy form, decided solely by
    /// whether the first word contains `=`.
    private static func applyKeyValuePairs(_ rest: String, instruction: String, set: (String, String) -> Void) throws {
        let (firstRaw, remainder) = splitFirstToken(Substring(rest))
        let firstKey = try dequote(firstRaw, instruction: instruction)
        if !firstKey.contains("="), let remainder {
            set(firstKey, try dequote(remainder, instruction: instruction))
            return
        }
        guard firstKey.contains("=") else {
            throw DockerfileChangeError.invalidValue(instruction: instruction, value: rest)
        }
        for token in try tokenize(rest, instruction: instruction) {
            // A blank name is only rejected in this `KEY=VALUE` form — real
            // docker build accepts a blank name from the legacy branch above
            // (`ENV "" value` sets "" to "value"); the two forms are not
            // symmetric, verified against real `docker build` output.
            guard let equalsIndex = token.firstIndex(of: "="), equalsIndex > token.startIndex else {
                throw DockerfileChangeError.invalidValue(instruction: instruction, value: token)
            }
            let key = String(token[..<equalsIndex])
            let value = String(token[token.index(after: equalsIndex)...])
            set(key, value)
        }
    }

    /// `EXPOSE <port>[/<proto>] ...`, defaulting to `/tcp`.
    private static func parsePorts(_ rest: String) -> [String] {
        rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { token in
            token.contains("/") ? String(token) : "\(token)/tcp"
        }
    }

    /// `VOLUME ["/data", ...]` (JSON form) or `VOLUME /data /data2` (shell form).
    private static func parseVolumes(instruction: String, _ rest: String) throws -> [String] {
        if rest.hasPrefix("[") {
            guard let data = rest.data(using: .utf8),
                let array = try? JSONDecoder().decode([String].self, from: data)
            else {
                throw DockerfileChangeError.invalidValue(instruction: instruction, value: rest)
            }
            return array
        }
        return try tokenize(rest, instruction: instruction)
    }

    /// Splits `value` on unquoted, unescaped whitespace into dequoted tokens.
    private static func tokenize(_ value: String, instruction: String) throws -> [String] {
        var tokens: [String] = []
        var remainder: Substring? = Substring(value)
        while let current = remainder, !current.isEmpty {
            let (rawToken, rest) = splitFirstToken(current)
            if !rawToken.isEmpty { tokens.append(try dequote(rawToken, instruction: instruction)) }
            remainder = rest
        }
        return tokens
    }

    /// Splits off the first whitespace-delimited raw token, honoring
    /// `"..."`/`'...'` quoting and backslash-escaping so an escaped or quoted
    /// space doesn't end the token early. Returns the raw (not yet dequoted)
    /// token and everything after the whitespace that follows it — `nil` if
    /// nothing follows.
    private static func splitFirstToken(_ value: Substring) -> (first: Substring, remainder: Substring?) {
        var start = value.startIndex
        while start < value.endIndex, value[start] == " " || value[start] == "\t" {
            start = value.index(after: start)
        }
        var index = start
        var escaped = false
        var quote: Character?
        while index < value.endIndex {
            let char = value[index]
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if let openQuote = quote {
                if char == openQuote { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == " " || char == "\t" {
                break
            }
            index = value.index(after: index)
        }
        let first = value[start..<index]
        guard index < value.endIndex else { return (first, nil) }
        var remainderStart = index
        while remainderStart < value.endIndex, value[remainderStart] == " " || value[remainderStart] == "\t" {
            remainderStart = value.index(after: remainderStart)
        }
        return (first, remainderStart < value.endIndex ? value[remainderStart...] : "")
    }

    /// Removes backslash-escapes (`\X` -> literal `X`) and strips a matching
    /// pair of enclosing `"`/`'` quote characters, honoring escapes even
    /// inside a quoted span (`"a\"b"` -> `a"b"`). Whitespace outside of an
    /// escape or quote is preserved literally — this is applied to the WHOLE
    /// remainder for the legacy `KEY VALUE` form, not per-word, which is why
    /// internal spacing in the value survives untouched.
    ///
    /// A quote left open at the end (`FOO="bar`) is rejected — real `docker
    /// build` does the same ("unexpected end of statement ... looking for
    /// matching double-quote"). A trailing, unconsumed backslash is NOT
    /// rejected: real `docker build` silently drops it (`FOO=bar\` -> `bar`),
    /// since a Dockerfile's line-continuation backslash has nothing left to
    /// continue onto at the end of a single `--change` entry.
    private static func dequote<S: StringProtocol>(_ value: S, instruction: String) throws -> String {
        var result = ""
        var escaped = false
        var quote: Character?
        for char in value {
            if escaped {
                result.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if let openQuote = quote {
                if char == openQuote {
                    quote = nil
                } else {
                    result.append(char)
                }
            } else if char == "\"" || char == "'" {
                quote = char
            } else {
                result.append(char)
            }
        }
        guard quote == nil else {
            throw DockerfileChangeError.invalidValue(instruction: instruction, value: String(value))
        }
        return result
    }
}
