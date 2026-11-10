import Foundation
import Testing

@testable import podmd

@Suite("DockerfileChangeApplier — docker import --change")
struct DockerfileChangeApplierTests {

    @Test("CMD in JSON exec form is applied as-is")
    func cmdExecForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["CMD [\"/app\", \"serve\"]"], to: &config)
        #expect(config.cmd == ["/app", "serve"])
    }

    @Test("CMD in shell form is wrapped as /bin/sh -c")
    func cmdShellForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["CMD /app serve"], to: &config)
        #expect(config.cmd == ["/bin/sh", "-c", "/app serve"])
    }

    @Test("ENTRYPOINT in JSON exec form is applied as-is")
    func entrypointExecForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENTRYPOINT [\"/app\"]"], to: &config)
        #expect(config.entrypoint == ["/app"])
    }

    @Test("an ENTRYPOINT clears a Cmd the config already carried, like moby's dispatchEntrypoint")
    func entrypointClearsPreSeededCmd() throws {
        // moby's dispatchEntrypoint: `if !d.state.cmdSet { runConfig.Cmd = nil }`.
        // BuildFromConfig's state starts fresh, so a pre-seeded Cmd (from the
        // container in a body-less commit, or from the request body) is never
        // cmdSet and gets cleared.
        var config = SynthesizedImageConfig()
        config.cmd = ["serve", "--verbose"]
        try DockerfileChangeApplier.apply(["ENTRYPOINT [\"/new\"]"], to: &config)
        #expect(config.entrypoint == ["/new"])
        #expect(config.cmd == nil)
    }

    @Test("a shell-form ENTRYPOINT clears a pre-seeded Cmd too")
    func shellEntrypointClearsPreSeededCmd() throws {
        var config = SynthesizedImageConfig()
        config.cmd = ["serve"]
        try DockerfileChangeApplier.apply(["ENTRYPOINT /new"], to: &config)
        #expect(config.entrypoint == ["/bin/sh", "-c", "/new"])
        #expect(config.cmd == nil)
    }

    @Test("a Cmd set by a prior CMD change survives a later ENTRYPOINT, like moby's cmdSet")
    func cmdChangeProtectsCmdFromEntrypoint() throws {
        // moby's dispatchCmd sets d.state.cmdSet for a non-empty command, which
        // dispatchEntrypoint then honors by keeping runConfig.Cmd.
        var config = SynthesizedImageConfig()
        config.cmd = ["serve", "--verbose"]
        try DockerfileChangeApplier.apply(["CMD [\"override\"]", "ENTRYPOINT [\"/new\"]"], to: &config)
        #expect(config.entrypoint == ["/new"])
        #expect(config.cmd == ["override"])
    }

    @Test("an emptied CMD [] does not mark Cmd as set, so a later ENTRYPOINT clears it")
    func emptiedCmdDoesNotProtectCmdFromEntrypoint() throws {
        // moby's dispatchCmd: `if len(c.ShellDependantCmdLine.CmdLine) != 0 {
        // d.state.cmdSet = true }` — an empty exec form leaves cmdSet false.
        var config = SynthesizedImageConfig()
        config.cmd = ["serve", "--verbose"]
        try DockerfileChangeApplier.apply(["CMD []", "ENTRYPOINT [\"/new\"]"], to: &config)
        #expect(config.entrypoint == ["/new"])
        #expect(config.cmd == nil)
    }

    @Test("multiple ENV pairs on one line are all applied")
    func envMultiplePairs() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV FOO=bar BAZ=qux"], to: &config)
        #expect(config.env == ["FOO=bar", "BAZ=qux"])
    }

    @Test("the legacy ENV KEY VALUE form is applied")
    func envLegacyForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV FOO bar"], to: &config)
        #expect(config.env == ["FOO=bar"])
    }

    @Test("a repeated ENV key overwrites in place rather than duplicating")
    func envOverwritesInPlace() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV FOO=bar", "ENV FOO=baz"], to: &config)
        #expect(config.env == ["FOO=baz"])
    }

    @Test("the legacy ENV KEY VALUE form takes the whole remainder verbatim, even if it contains '='")
    func envLegacyFormTakesWholeRemainder() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV FOO bar=1 baz=2"], to: &config)
        #expect(config.env == ["FOO=bar=1 baz=2"])
    }

    @Test("the legacy ENV form preserves internal whitespace in the value")
    func envLegacyFormPreservesInternalWhitespace() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV NAME   spaced   out"], to: &config)
        #expect(config.env == ["NAME=spaced   out"])
    }

    @Test("a backslash-escaped space in a modern ENV pair is kept literal, not a token separator")
    func envBackslashEscapedSpace() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV DESC=hello\\ world"], to: &config)
        #expect(config.env == ["DESC=hello world"])
    }

    @Test("a backslash-escaped quote inside a quoted ENV value is kept literal")
    func envBackslashEscapedQuote() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV ESCAPED=\"a\\\"b\""], to: &config)
        #expect(config.env == ["ESCAPED=a\"b"])
    }

    @Test("ENV with only a key and no value is rejected")
    func envSingleTokenIsRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["ENV JUSTONE"], to: &config)
        }
    }

    @Test("an empty quoted ENV value clears to an empty string, not a parse error")
    func envEmptyQuotedValue() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV FOO=\"\""], to: &config)
        #expect(config.env == ["FOO="])
    }

    @Test("ENV with a blank name in KEY=VALUE form is rejected, matching moby's 'ENV names can not be blank'")
    func envBlankNameIsRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["ENV =value"], to: &config)
        }
    }

    @Test("ENV with a blank quoted name in the legacy KEY VALUE form is accepted, unlike KEY=VALUE form")
    func envBlankNameInLegacyFormIsAccepted() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV \"\" value"], to: &config)
        #expect(config.env == ["=value"])
    }

    @Test("an unterminated quote is rejected, matching moby's 'unexpected end of statement'")
    func envUnterminatedQuoteIsRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["ENV FOO=\"bar"], to: &config)
        }
    }

    @Test("a trailing unconsumed backslash is silently dropped, not rejected")
    func envTrailingBackslashIsDropped() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV FOO=bar\\"], to: &config)
        #expect(config.env == ["FOO=bar"])
    }

    @Test("the legacy LABEL KEY VALUE form takes the whole remainder verbatim")
    func labelLegacyFormTakesWholeRemainder() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["LABEL JUSTONE value with spaces"], to: &config)
        #expect(config.labels == ["JUSTONE": "value with spaces"])
    }

    @Test("LABEL with a quoted value containing spaces is parsed as one pair")
    func labelQuotedValue() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["LABEL description=\"two words\""], to: &config)
        #expect(config.labels == ["description": "two words"])
    }

    @Test("multiple LABEL pairs on one line are all applied")
    func labelMultiplePairs() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["LABEL a=1 b=2"], to: &config)
        #expect(config.labels == ["a": "1", "b": "2"])
    }

    @Test("EXPOSE without a protocol defaults to tcp")
    func exposeDefaultsToTcp() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["EXPOSE 8080"], to: &config)
        #expect(config.exposedPorts == ["8080/tcp"])
    }

    @Test("EXPOSE with an explicit protocol is kept as given")
    func exposeExplicitProtocol() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["EXPOSE 53/udp"], to: &config)
        #expect(config.exposedPorts == ["53/udp"])
    }

    @Test("EXPOSE accepts multiple ports on one line")
    func exposeMultiplePorts() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["EXPOSE 8080 53/udp"], to: &config)
        #expect(config.exposedPorts == ["8080/tcp", "53/udp"])
    }

    @Test("VOLUME in JSON array form is applied as-is")
    func volumeJSONForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["VOLUME [\"/data\"]"], to: &config)
        #expect(config.volumes == ["/data"])
    }

    @Test("VOLUME in shell form accepts multiple paths")
    func volumeShellForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["VOLUME /data /var/log"], to: &config)
        #expect(config.volumes == ["/data", "/var/log"])
    }

    @Test("USER sets the config's user")
    func userInstruction() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["USER app"], to: &config)
        #expect(config.user == "app")
    }

    @Test("WORKDIR sets the config's working directory")
    func workdirInstruction() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["WORKDIR /srv/app"], to: &config)
        #expect(config.workingDir == "/srv/app")
    }

    @Test("a relative WORKDIR joins the threaded-in base, like moby's commit starting from the container's config")
    func workdirRelativeJoinsBase() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["WORKDIR logs"], to: &config, baseWorkingDir: "/srv")
        #expect(config.workingDir == "/srv/logs")
    }

    @Test("a relative WORKDIR without a base anchors at / — moby's import runs BuildFromConfig on an empty config")
    func workdirRelativeWithoutBaseAnchorsAtRoot() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["WORKDIR logs"], to: &config)
        #expect(config.workingDir == "/logs")
    }

    @Test("a relative WORKDIR chains onto the current directory set by an earlier instruction")
    func workdirRelativeChains() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["WORKDIR /srv", "WORKDIR logs", "WORKDIR more"], to: &config)
        #expect(config.workingDir == "/srv/logs/more")
    }

    @Test("an absolute WORKDIR passes through cleaned, like moby's normalizeWorkdir/filepath.Clean")
    func workdirAbsoluteIsCleaned() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["WORKDIR //srv/./app/"], to: &config, baseWorkingDir: "/elsewhere")
        #expect(config.workingDir == "/srv/app")
    }

    @Test("a relative WORKDIR cleans the joined result, resolving . and .. segments")
    func workdirRelativeIsCleaned() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["WORKDIR ../logs"], to: &config, baseWorkingDir: "/srv/app")
        #expect(config.workingDir == "/srv/logs")
    }

    @Test("an instruction this endpoint does not model (e.g. ONBUILD) is rejected, not silently dropped")
    func unsupportedInstructionIsRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["ONBUILD /bin/true"], to: &config)
        }
    }

    @Test("STOPSIGNAL sets the config's stop signal")
    func stopSignalInstruction() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["STOPSIGNAL SIGTERM"], to: &config)
        #expect(config.stopSignal == "SIGTERM")
    }

    @Test("STOPSIGNAL accepts a numeric signal")
    func stopSignalNumeric() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["STOPSIGNAL 15"], to: &config)
        #expect(config.stopSignal == "15")
    }

    @Test("an invalid STOPSIGNAL is rejected, like moby's signal.ParseSignal")
    func stopSignalInvalidIsRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["STOPSIGNAL NOTASIGNAL"], to: &config)
        }
    }

    @Test("STOPSIGNAL takes exactly one argument")
    func stopSignalExtraArgumentsRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["STOPSIGNAL SIGTERM extra"], to: &config)
        }
    }

    @Test("HEALTHCHECK with flags and a CMD exec form applies, durations in nanoseconds")
    func healthcheckFlagsAndExecForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(
            [
                "HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --start-interval=2s --retries=3 CMD [\"curl\", \"-f\", \"http://localhost\"]"
            ],
            to: &config)
        #expect(
            config.healthcheck
                == HealthcheckConfig(
                    Test: ["CMD", "curl", "-f", "http://localhost"],
                    Interval: 30_000_000_000,
                    Timeout: 3_000_000_000,
                    Retries: 3,
                    StartPeriod: 5_000_000_000,
                    StartInterval: 2_000_000_000))
    }

    @Test("HEALTHCHECK in shell form wraps the command as CMD-SHELL")
    func healthcheckShellForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(
            ["HEALTHCHECK --interval=1m30s CMD curl -f http://localhost || exit 1"], to: &config)
        #expect(
            config.healthcheck
                == HealthcheckConfig(
                    Test: ["CMD-SHELL", "curl -f http://localhost || exit 1"],
                    Interval: 90_000_000_000,
                    Timeout: nil,
                    Retries: nil,
                    StartPeriod: nil))
    }

    @Test("HEALTHCHECK NONE sets moby's disable marker")
    func healthcheckNone() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["HEALTHCHECK NONE"], to: &config)
        #expect(
            config.healthcheck
                == HealthcheckConfig(
                    Test: ["NONE"], Interval: nil, Timeout: nil, Retries: nil, StartPeriod: nil))
    }

    @Test("HEALTHCHECK NONE takes no arguments")
    func healthcheckNoneTakesNoArguments() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["HEALTHCHECK NONE extra"], to: &config)
        }
    }

    @Test("a HEALTHCHECK type other than CMD or NONE is rejected")
    func healthcheckUnknownTypeRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["HEALTHCHECK CMDX true"], to: &config)
        }
    }

    @Test("a HEALTHCHECK with no command after CMD is rejected")
    func healthcheckMissingCommandRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["HEALTHCHECK CMD"], to: &config)
        }
    }

    @Test("an unknown HEALTHCHECK flag is rejected")
    func healthcheckUnknownFlagRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["HEALTHCHECK --bogus=1 CMD true"], to: &config)
        }
    }

    @Test("a HEALTHCHECK flag without a value is rejected, like buildkit's bflag")
    func healthcheckFlagMissingValueRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["HEALTHCHECK --interval 30s CMD true"], to: &config)
        }
    }

    @Test("a bare -- delimiter ends HEALTHCHECK flag processing, like buildkit's bflag")
    func healthcheckDoubleDashDelimiter() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["HEALTHCHECK -- CMD true"], to: &config)
        #expect(
            config.healthcheck
                == HealthcheckConfig(
                    Test: ["CMD-SHELL", "true"], Interval: nil, Timeout: nil, Retries: nil, StartPeriod: nil))
    }

    @Test("a HEALTHCHECK duration below 1ms is rejected, like moby's minimumDuration")
    func healthcheckSubMillisecondRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["HEALTHCHECK --interval=500us CMD true"], to: &config)
        }
    }

    @Test("a HEALTHCHECK duration of exactly Int64.max nanoseconds is rejected, not trapped")
    func healthcheckDurationAtInt64MaxRejected() throws {
        // 9223372036854775807ns parses to the Double 2^63 (Double(Int64.max)
        // rounds up), which a `<= Double(Int64.max)` bound admits and then
        // traps on in Int64(total). The strict `<` must reject it with a 400.
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["HEALTHCHECK --interval=9223372036854775807ns CMD true"], to: &config)
        }
    }

    @Test("a HEALTHCHECK duration one nanosecond above Int64.max is rejected")
    func healthcheckDurationAboveInt64MaxRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["HEALTHCHECK --interval=9223372036854775808ns CMD true"], to: &config)
        }
    }

    @Test("a huge second-based HEALTHCHECK duration is rejected")
    func healthcheckHugeSecondDurationRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["HEALTHCHECK --timeout=9223372036854775807s CMD true"], to: &config)
        }
    }

    @Test("the largest HEALTHCHECK duration below the Double rounding cliff is accepted")
    func healthcheckDurationJustBelowCliffAccepted() throws {
        // 2^63 - 2^10 ns is the largest Double below 2^63 and a valid Int64 —
        // it must still parse, proving the strict bound does not over-reject.
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["HEALTHCHECK --interval=9223372036854774784ns CMD true"], to: &config)
        #expect(config.healthcheck?.Interval == 9_223_372_036_854_774_784)
    }

    @Test("a negative HEALTHCHECK retries count is rejected")
    func healthcheckNegativeRetriesRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["HEALTHCHECK --retries=-1 CMD true"], to: &config)
        }
    }

    @Test("a HEALTHCHECK overriding a previous one replaces it wholesale at the applier level")
    func healthcheckReplacesPrevious() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(
            ["HEALTHCHECK --interval=30s CMD true", "HEALTHCHECK CMD false"], to: &config)
        #expect(
            config.healthcheck
                == HealthcheckConfig(
                    Test: ["CMD-SHELL", "false"], Interval: nil, Timeout: nil, Retries: nil, StartPeriod: nil))
    }

    @Test("a genuinely invalid instruction (no value) is rejected")
    func missingValueIsRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["WORKDIR"], to: &config)
        }
    }

    @Test("an empty change entry is ignored")
    func emptyEntryIsIgnored() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["  "], to: &config)
        #expect(config.cmd == nil)
        #expect(config.env.isEmpty)
    }

    @Test("a bare 0 duration parses as unset (Go ParseDuration parity)")
    func bareZeroDuration() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(
            ["HEALTHCHECK --interval=0 CMD [\"true\"]"], to: &config)
        #expect(config.healthcheck?.Interval == nil)
        #expect(config.healthcheck?.Test == ["CMD", "true"])
    }

    @Test("a trailing unitless zero after a component is garbage, not a fresh zero")
    func trailingZeroIsRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(
                ["HEALTHCHECK --interval=5s0 CMD [\"true\"]"], to: &config)
        }
    }
}
