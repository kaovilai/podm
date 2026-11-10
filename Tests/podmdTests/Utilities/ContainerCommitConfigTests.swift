import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import podmd

/// `ContainerCommitConfig.make` — the pure capture/merge behind
/// `docker commit`. Precedence under test everywhere: `--change` >
/// body Config > container snapshot > parent image config.
@Suite("ContainerCommitConfig — commit config capture/merge")
struct ContainerCommitConfigTests {

    // MARK: - Fixtures

    /// A snapshot whose live process configuration says what the container
    /// actually runs — the fields `docker inspect` would report.
    private func makeSnapshot(
        executable: String = "/app",
        arguments: [String] = ["serve", "--verbose"],
        environment: [String] = ["PATH=/usr/bin", "MODE=container"],
        workingDirectory: String = "/srv",
        user: ProcessConfiguration.User = .raw(userString: "1000"),
        labels: [String: String] = ["com.example.owner": "ctr"],
        stopSignal: String? = nil,
        healthcheck: HealthcheckConfig? = nil
    ) throws -> ContainerSnapshot {
        let process = ProcessConfiguration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            terminal: false,
            user: user
        )
        let image = ImageDescription(
            reference: "example/app:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: "sha256:abc", size: 0)
        )
        var configuration = ContainerConfiguration(id: "web", image: image, process: process)
        var allLabels = labels
        if let stopSignal {
            configuration.stopSignal = stopSignal
        }
        if let healthcheck {
            let json = try JSONEncoder().encode(healthcheck)
            allLabels[HealthCheckManager.healthcheckLabel] = String(data: json, encoding: .utf8)
        }
        configuration.labels = allLabels
        return ContainerSnapshot(configuration: configuration, status: .stopped, networks: [])
    }

    private func makeParent(
        user: String? = "0",
        env: [String]? = ["PATH=/usr/bin", "MODE=image", "EXTRA=from-parent"],
        entrypoint: [String]? = ["/app"],
        cmd: [String]? = ["serve"],
        workingDir: String? = "/srv",
        labels: [String: String]? = ["com.example.owner": "image", "com.example.other": "image"]
    ) -> ContainerizationOCI.ImageConfig {
        ContainerizationOCI.ImageConfig(
            user: user,
            env: env,
            entrypoint: entrypoint,
            cmd: cmd,
            workingDir: workingDir,
            labels: labels
        )
    }

    // MARK: - Capture from the snapshot

    @Test("with no body, changes, or parent, the config captures the snapshot's live process")
    func capturesSnapshot() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: nil, overrides: nil, changes: [])

        // No parent → the inspect approximation: Entrypoint [executable],
        // Cmd arguments.
        #expect(config.entrypoint == ["/app"])
        #expect(config.cmd == ["serve", "--verbose"])
        #expect(config.env == ["PATH=/usr/bin", "MODE=container"])
        #expect(config.user == "1000")
        #expect(config.workingDir == "/srv")
        #expect(config.labels == ["com.example.owner": "ctr"])
    }

    @Test("a parent with an ENTRYPOINT splits executable/arguments into Entrypoint/Cmd")
    func parentWithEntrypointSplits() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: makeParent(), overrides: nil, changes: [])

        #expect(config.entrypoint == ["/app"])
        #expect(config.cmd == ["serve", "--verbose"])
    }

    @Test("a parent without an ENTRYPOINT means the executable is the head of the original CMD")
    func parentWithoutEntrypointFoldsExecutableIntoCmd() throws {
        let parent = makeParent(entrypoint: nil, cmd: ["/app", "serve"])
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: parent, overrides: nil, changes: [])

        #expect(config.entrypoint == nil)
        #expect(config.cmd == ["/app", "serve", "--verbose"])
    }

    @Test("env unions by key: container entries first, parent entries only for keys neither carries")
    func envUnionsByKey() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: makeParent(), overrides: nil, changes: [])

        // MODE=container (snapshot) wins over MODE=image (parent); EXTRA
        // (parent-only) is appended.
        #expect(config.env == ["PATH=/usr/bin", "MODE=container", "EXTRA=from-parent"])
    }

    @Test("labels fill missing keys: snapshot labels win, parent labels fill the gaps")
    func labelsFillMissingKeys() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: makeParent(), overrides: nil, changes: [])

        #expect(
            config.labels == [
                "com.example.owner": "ctr",
                "com.example.other": "image",
            ])
    }

    @Test("user and workingDir fall back to the parent when the snapshot has none")
    func userAndWorkdirFallBackToParent() throws {
        let snapshot = try makeSnapshot(workingDirectory: "", user: .raw(userString: ""))
        let config = try ContainerCommitConfig.make(
            container: snapshot, parent: makeParent(user: "42", workingDir: "/opt"), overrides: nil, changes: [])

        #expect(config.user == "42")
        #expect(config.workingDir == "/opt")
    }

    @Test("a numeric process user renders as uid:gid, the same as inspect")
    func numericUser() throws {
        let snapshot = try makeSnapshot(user: .id(uid: 1000, gid: 1000))
        let config = try ContainerCommitConfig.make(
            container: snapshot, parent: nil, overrides: nil, changes: [])

        #expect(config.user == "1000:1000")
    }

    // MARK: - Body overrides

    @Test("body Config fields replace the captured values")
    func bodyOverridesReplace() throws {
        let overrides = CommitConfigOverrides(
            user: "nobody",
            env: ["MODE=body"],
            entrypoint: ["/init"],
            cmd: ["--foreground"],
            workingDir: "/override",
            labels: ["com.example.owner": "body"])

        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: makeParent(), overrides: overrides, changes: [])

        #expect(config.user == "nobody")
        #expect(config.entrypoint == ["/init"])
        #expect(config.cmd == ["--foreground"])
        #expect(config.workingDir == "/override")
        // Labels fill: the body's key wins, the snapshot/parent keys the body
        // didn't set survive.
        #expect(
            config.labels == [
                "com.example.owner": "body",
                "com.example.other": "image",
            ])
    }

    @Test("body Env replaces keys and the container env only fills missing keys, like moby's merge")
    func bodyEnvUnionsWithSnapshot() throws {
        let overrides = CommitConfigOverrides(env: ["MODE=body", "NEW=1"])
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: makeParent(), overrides: overrides, changes: [])

        #expect(config.env == ["MODE=body", "NEW=1", "PATH=/usr/bin", "EXTRA=from-parent"])
    }

    @Test("an explicitly empty body Entrypoint stays empty — the captured one is not inherited")
    func explicitEmptyEntrypointStaysEmpty() throws {
        // Non-nil empty ≠ unset for moby's merge: an explicitly emptied
        // Entrypoint is not refilled from the container.
        let overrides = CommitConfigOverrides(entrypoint: [])
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: makeParent(), overrides: overrides, changes: [])

        #expect(config.entrypoint == [])
        // Cmd may still be inherited when Entrypoint is empty.
        #expect(config.cmd == ["serve", "--verbose"])
    }

    @Test("a body Entrypoint suppresses Cmd inheritance, matching moby's merge quirk")
    func bodyEntrypointSuppressesCmdInheritance() throws {
        // moby's merge() only fills Cmd when the entrypoint is empty — a body
        // that sets Entrypoint (without Cmd) produces a Cmd-less image.
        let overrides = CommitConfigOverrides(entrypoint: ["/only-entrypoint"])
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: makeParent(), overrides: overrides, changes: [])

        #expect(config.entrypoint == ["/only-entrypoint"])
        #expect(config.cmd == nil)
    }

    @Test("body ExposedPorts and Volumes pass straight through")
    func bodyPortsAndVolumes() throws {
        let overrides = CommitConfigOverrides(
            exposedPorts: ["80/tcp", "53/udp"], volumes: ["/data", "/config"])
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: nil, overrides: overrides, changes: [])

        #expect(config.exposedPorts == ["80/tcp", "53/udp"])
        #expect(config.volumes == ["/data", "/config"])
    }

    // MARK: - --change instructions

    @Test("--change instructions apply on top of the body and the fill completes around them")
    func changesApplyOnTop() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(),
            parent: makeParent(),
            overrides: nil,
            changes: [
                "CMD [\"override\"]",
                "ENV MODE=changed",
                "LABEL com.example.new=yes",
                "USER daemon",
                "WORKDIR /changed",
                "EXPOSE 8080",
                "VOLUME [\"/vol\"]",
            ])

        #expect(config.cmd == ["override"])
        #expect(config.entrypoint == ["/app"])
        #expect(config.env.contains("MODE=changed"))
        #expect(config.env.contains("PATH=/usr/bin"))
        #expect(config.labels["com.example.new"] == "yes")
        #expect(config.labels["com.example.owner"] == "ctr")
        #expect(config.user == "daemon")
        #expect(config.workingDir == "/changed")
        #expect(config.exposedPorts == ["8080/tcp"])
        #expect(config.volumes == ["/vol"])
    }

    @Test("an ENV change hides the same-key container entry, not just the body's")
    func envChangeHidesContainerEntry() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: nil, overrides: nil, changes: ["ENV MODE=changed"])

        #expect(config.env == ["MODE=changed", "PATH=/usr/bin"])
    }

    @Test("an invalid --change instruction is rejected")
    func invalidChangeRejected() throws {
        #expect(throws: DockerfileChangeError.self) {
            _ = try ContainerCommitConfig.make(
                container: try makeSnapshot(), parent: nil, overrides: nil, changes: ["ONBUILD x"])
        }
    }

    // MARK: - Relative WORKDIR resolution

    @Test("a relative --change WORKDIR joins the container's working directory")
    func relativeWorkdirJoinsContainerDir() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(workingDirectory: "/srv"),
            parent: nil,
            overrides: nil,
            changes: ["WORKDIR logs"])

        #expect(config.workingDir == "/srv/logs")
    }

    @Test("a relative --change WORKDIR falls back to the parent's working directory when the snapshot has none")
    func relativeWorkdirFallsBackToParent() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(workingDirectory: ""),
            parent: makeParent(workingDir: "/opt"),
            overrides: nil,
            changes: ["WORKDIR logs"])

        #expect(config.workingDir == "/opt/logs")
    }

    @Test("an absolute --change WORKDIR passes through untouched")
    func absoluteWorkdirPassesThrough() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(workingDirectory: "/srv"),
            parent: nil,
            overrides: nil,
            changes: ["WORKDIR /opt"])

        #expect(config.workingDir == "/opt")
    }

    @Test("a body WorkingDir is the join base for a relative --change WORKDIR, like moby's runConfig")
    func bodyWorkdirIsJoinBase() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(workingDirectory: "/srv"),
            parent: nil,
            overrides: CommitConfigOverrides(workingDir: "/base"),
            changes: ["WORKDIR logs"])

        #expect(config.workingDir == "/base/logs")
    }

    @Test("a SPARSE body makes a relative --change WORKDIR anchor at /, like moby's BuildFromConfig")
    func sparseBodyWorkdirAnchorsAtRoot() throws {
        // moby's commit: `if c.Config == nil { c.Config = container.Config }`
        // — only a body-less commit starts BuildFromConfig from the
        // container's config. A sparse body (labels only, no WorkingDir)
        // starts from the BODY's config, whose working dir is unset, so
        // `WORKDIR logs` resolves against `/` — NOT the container's /srv.
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(workingDirectory: "/srv"),
            parent: nil,
            overrides: CommitConfigOverrides(labels: ["x": "y"]),
            changes: ["WORKDIR logs"])

        #expect(config.workingDir == "/logs")
    }

    // MARK: - CMD [] under a nonempty entrypoint

    @Test("an explicitly-emptied --change CMD stays empty when the container has a nonempty entrypoint")
    func emptiedCmdStaysEmptyUnderEntrypoint() throws {
        // moby's merge only fills Cmd while the entrypoint is empty; with no
        // body, BuildFromConfig starts from the container's own config, so
        // `CMD []` under the container's ENTRYPOINT must survive as [].
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(),
            parent: makeParent(),
            overrides: nil,
            changes: ["CMD []"])

        #expect(config.entrypoint == ["/app"])
        #expect(config.cmd == [])
    }

    @Test("an emptied --change CMD on an entrypoint-LESS container is refilled, matching moby's merge")
    func emptiedCmdRefilledWithoutEntrypoint() throws {
        // No parent entrypoint → the container's config pair is (nil, cmd);
        // moby's merge sees an empty entrypoint and refills the emptied Cmd.
        let parent = makeParent(entrypoint: nil, cmd: ["/app", "serve"])
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(executable: "/app", arguments: ["serve"]),
            parent: parent,
            overrides: nil,
            changes: ["CMD []"])

        #expect(config.entrypoint == nil)
        #expect(config.cmd == ["/app", "serve"])
    }

    // MARK: - ENTRYPOINT change vs the pre-seeded Cmd

    @Test("an ENTRYPOINT --change clears the pre-seeded Cmd, like moby's dispatchEntrypoint")
    func entrypointChangeClearsPreSeededCmd() throws {
        // moby's dispatchEntrypoint: `if !d.state.cmdSet { runConfig.Cmd = nil }`.
        // BuildFromConfig's state starts fresh, so the Cmd pre-seeded from the
        // container (no request body) is NOT cmdSet and is cleared — then
        // merge cannot refill it either, because the entrypoint is nonempty.
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(),
            parent: makeParent(),
            overrides: nil,
            changes: ["ENTRYPOINT [\"/new\"]"])

        #expect(config.entrypoint == ["/new"])
        #expect(config.cmd == nil)
    }

    @Test("a CMD --change before an ENTRYPOINT --change keeps the Cmd, like moby's cmdSet")
    func cmdChangeBeforeEntrypointKeepsCmd() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(),
            parent: makeParent(),
            overrides: nil,
            changes: ["CMD [\"override\"]", "ENTRYPOINT [\"/new\"]"])

        #expect(config.entrypoint == ["/new"])
        #expect(config.cmd == ["override"])
    }

    @Test("an ENTRYPOINT --change clears a body Cmd too — moby's cmdSet only tracks CMD instructions")
    func entrypointChangeClearsBodyCmd() throws {
        // The request body's Cmd is part of the runConfig BuildFromConfig
        // starts from, not a CMD instruction, so dispatchEntrypoint clears it.
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(),
            parent: makeParent(),
            overrides: CommitConfigOverrides(cmd: ["from-body"]),
            changes: ["ENTRYPOINT [\"/new\"]"])

        #expect(config.entrypoint == ["/new"])
        #expect(config.cmd == nil)
    }

    @Test("an emptied ENTRYPOINT [] clears the Cmd, which moby's merge then refills from the container")
    func emptiedEntrypointClearsThenMergeRefillsCmd() throws {
        // dispatchEntrypoint clears the pre-seeded Cmd; merge sees an empty
        // (explicitly-emptied, non-nil) entrypoint, refills the Cmd from the
        // container's config, and leaves the entrypoint emptied — the
        // nil-vs-empty distinction moby's merge makes.
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(),
            parent: makeParent(),
            overrides: nil,
            changes: ["ENTRYPOINT []"])

        #expect(config.entrypoint == [])
        #expect(config.cmd == ["serve", "--verbose"])
    }

    // MARK: - Multi-element ENTRYPOINT split

    @Test("a multi-element parent ENTRYPOINT splits intact: [\"/bin/sh\",\"-c\"] + CMD [\"echo\"] stays two parts")
    func multiElementEntrypointSplitsIntact() throws {
        // Parent: ENTRYPOINT ["/bin/sh", "-c"], CMD ["echo"]. Create flattens
        // to executable "/bin/sh", arguments ["-c", "echo"] — the snapshot's
        // live shape. The split must recover ["/bin/sh","-c"] / ["echo"], not
        // the naive ["/bin/sh"] / ["-c","echo"] (which would exec
        // `/bin/sh -c -c echo`).
        let snapshot = try makeSnapshot(executable: "/bin/sh", arguments: ["-c", "echo"])
        let parent = makeParent(entrypoint: ["/bin/sh", "-c"], cmd: ["echo"])

        let config = try ContainerCommitConfig.make(
            container: snapshot, parent: parent, overrides: nil, changes: [])

        #expect(config.entrypoint == ["/bin/sh", "-c"])
        #expect(config.cmd == ["echo"])
    }

    @Test("a create-time CMD override survives the multi-element ENTRYPOINT split")
    func cmdOverrideSurvivesSplit() throws {
        // Same parent ENTRYPOINT, but the container was created with
        // --cmd ["sleep","5"]: the flattened process is
        // ["/bin/sh","-c","sleep","5"], which still begins with the parent's
        // entrypoint, so the split yields the parent entrypoint + the override.
        let snapshot = try makeSnapshot(executable: "/bin/sh", arguments: ["-c", "sleep", "5"])
        let parent = makeParent(entrypoint: ["/bin/sh", "-c"], cmd: ["echo"])

        let config = try ContainerCommitConfig.make(
            container: snapshot, parent: parent, overrides: nil, changes: [])

        #expect(config.entrypoint == ["/bin/sh", "-c"])
        #expect(config.cmd == ["sleep", "5"])
    }

    @Test("a --change CMD on a multi-element-ENTRYPOINT parent replaces only the cmd part of the split")
    func changeCmdReplacesSplitRemainder() throws {
        let snapshot = try makeSnapshot(executable: "/bin/sh", arguments: ["-c", "echo"])
        let parent = makeParent(entrypoint: ["/bin/sh", "-c"], cmd: ["echo"])

        let config = try ContainerCommitConfig.make(
            container: snapshot, parent: parent, overrides: nil, changes: ["CMD [\"date\"]"])

        #expect(config.entrypoint == ["/bin/sh", "-c"])
        #expect(config.cmd == ["date"])
    }

    @Test("when the live process no longer begins with the parent's ENTRYPOINT, the split falls back to the approximation")
    func overriddenEntrypointFallsBack() throws {
        // The container was created with --entrypoint ["/init"]: the flattened
        // process ["/init","--foreground"] does not begin with the parent's
        // ["/bin/sh","-c"], so the original split is unrecoverable and the
        // inspect approximation is used.
        let snapshot = try makeSnapshot(executable: "/init", arguments: ["--foreground"])
        let parent = makeParent(entrypoint: ["/bin/sh", "-c"], cmd: ["echo"])

        let config = try ContainerCommitConfig.make(
            container: snapshot, parent: parent, overrides: nil, changes: [])

        #expect(config.entrypoint == ["/init"])
        #expect(config.cmd == ["--foreground"])
    }

    // MARK: - EXPOSE/VOLUME inheritance

    @Test("parent ExposedPorts and Volumes are unioned in, so a no-change commit keeps them")
    func parentPortsAndVolumesUnion() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(),
            parent: makeParent(),
            parentExposedPorts: ["80/tcp", "443/tcp"],
            parentVolumes: ["/data"],
            overrides: nil,
            changes: [])

        #expect(config.exposedPorts == ["80/tcp", "443/tcp"])
        #expect(config.volumes == ["/data"])
    }

    @Test("body and --change EXPOSE/VOLUME union with the parent's, not replace them")
    func bodyPortsAndVolumesUnionWithParent() throws {
        let overrides = CommitConfigOverrides(exposedPorts: ["8080/tcp"], volumes: ["/config"])
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(),
            parent: makeParent(),
            parentExposedPorts: ["80/tcp"],
            parentVolumes: ["/data"],
            overrides: overrides,
            changes: ["EXPOSE 53/udp"])

        #expect(config.exposedPorts == ["80/tcp", "8080/tcp", "53/udp"])
        #expect(config.volumes == ["/data", "/config"])
    }

    // MARK: - StopSignal / Healthcheck carry

    @Test("the container's persisted stop signal is carried into the commit")
    func containerStopSignalCarried() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(stopSignal: "SIGQUIT"),
            parent: makeParent(),
            overrides: nil,
            changes: [])

        #expect(config.stopSignal == "SIGQUIT")
    }

    @Test("stop signal falls back to the parent when the container set none")
    func stopSignalFallsBackToParent() throws {
        let parent = makeParent()
        // ContainerConfiguration.stopSignal stays nil (create only persists an
        // explicit request), so the image's signal must come through.
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: parent, overrides: nil, changes: [])

        #expect(config.stopSignal == nil)

        let parentWithSignal = ContainerizationOCI.ImageConfig(
            env: nil, entrypoint: nil, cmd: nil, workingDir: nil, labels: nil, stopSignal: "SIGUSR1")
        let configWithParentSignal = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: parentWithSignal, overrides: nil, changes: [])
        #expect(configWithParentSignal.stopSignal == "SIGUSR1")
    }

    @Test("a body StopSignal override wins over the container's and the parent's")
    func bodyStopSignalOverrides() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(stopSignal: "SIGQUIT"),
            parent: nil,
            overrides: CommitConfigOverrides(stopSignal: "SIGTERM"),
            changes: [])

        #expect(config.stopSignal == "SIGTERM")
    }

    @Test("the container's effective healthcheck (the create-route label) is carried into the commit")
    func containerHealthcheckCarried() throws {
        let healthcheck = HealthcheckConfig(
            Test: ["CMD-SHELL", "curl -f http://localhost/ || exit 1"],
            Interval: 30, Timeout: 5, Retries: 3, StartPeriod: 10)
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(healthcheck: healthcheck),
            parent: nil,
            overrides: nil,
            changes: [])

        #expect(config.healthcheck == healthcheck)
    }

    @Test("a body Healthcheck override wins over the container's effective healthcheck")
    func bodyHealthcheckOverrides() throws {
        let carried = HealthcheckConfig(
            Test: ["CMD", "true"], Interval: 30, Timeout: 5, Retries: 3, StartPeriod: nil)
        let override = HealthcheckConfig(
            Test: ["NONE"], Interval: nil, Timeout: nil, Retries: nil, StartPeriod: nil)
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(healthcheck: carried),
            parent: nil,
            overrides: CommitConfigOverrides(healthcheck: override),
            changes: [])

        #expect(config.healthcheck == override)
    }

    @Test("a PARTIAL body Healthcheck merges field-wise: nil fields inherit, set fields replace")
    func partialBodyHealthcheckMergesFieldWise() throws {
        // moby's merge fills each zero-valued healthcheck field from the
        // container's config, so a body carrying only Interval keeps the
        // container's probe (Test) instead of discarding it.
        let carried = HealthcheckConfig(
            Test: ["CMD-SHELL", "curl -f http://localhost/ || exit 1"],
            Interval: 30_000_000_000,
            Timeout: 3_000_000_000,
            Retries: 3,
            StartPeriod: 10_000_000_000)
        let partial = HealthcheckConfig(
            Test: nil, Interval: 60_000_000_000, Timeout: nil, Retries: nil, StartPeriod: nil)
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(healthcheck: carried),
            parent: nil,
            overrides: CommitConfigOverrides(healthcheck: partial),
            changes: [])

        #expect(
            config.healthcheck
                == HealthcheckConfig(
                    Test: ["CMD-SHELL", "curl -f http://localhost/ || exit 1"],
                    Interval: 60_000_000_000,
                    Timeout: 3_000_000_000,
                    Retries: 3,
                    StartPeriod: 10_000_000_000))
    }

    @Test("a body Healthcheck with Test NONE disables wholesale — nothing is inherited")
    func bodyHealthcheckNoneDisablesWholesale() throws {
        let carried = HealthcheckConfig(
            Test: ["CMD", "true"], Interval: 30, Timeout: 5, Retries: 3, StartPeriod: 10)
        let disable = HealthcheckConfig(
            Test: ["NONE"], Interval: nil, Timeout: nil, Retries: nil, StartPeriod: nil)
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(healthcheck: carried),
            parent: nil,
            overrides: CommitConfigOverrides(healthcheck: disable),
            changes: [])

        #expect(config.healthcheck == disable)
    }

    @Test("a partial --change HEALTHCHECK merges field-wise over the container's, like moby's merge after BuildFromConfig")
    func partialChangeHealthcheckMergesFieldWise() throws {
        let carried = HealthcheckConfig(
            Test: ["CMD-SHELL", "old probe"],
            Interval: 30_000_000_000,
            Timeout: 3_000_000_000,
            Retries: 3,
            StartPeriod: nil)
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(healthcheck: carried),
            parent: nil,
            overrides: nil,
            changes: ["HEALTHCHECK --retries=5 CMD [\"new-probe\"]"])

        #expect(
            config.healthcheck
                == HealthcheckConfig(
                    Test: ["CMD", "new-probe"],
                    Interval: 30_000_000_000,
                    Timeout: 3_000_000_000,
                    Retries: 5,
                    StartPeriod: nil))
    }

    @Test("a --change STOPSIGNAL wins over the container's and the parent's")
    func changeStopSignalOverrides() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(stopSignal: "SIGQUIT"),
            parent: nil,
            overrides: nil,
            changes: ["STOPSIGNAL SIGUSR2"])

        #expect(config.stopSignal == "SIGUSR2")
    }

    @Test("a container with no healthcheck label commits without one")
    func noHealthcheckStaysAbsent() throws {
        let config = try ContainerCommitConfig.make(
            container: try makeSnapshot(), parent: nil, overrides: nil, changes: [])

        #expect(config.healthcheck == nil)
    }

    @Test("stop signal and healthcheck serialize into the config dict with Docker's keys")
    func stopSignalAndHealthcheckSerialize() throws {
        let healthcheck = HealthcheckConfig(
            Test: ["CMD", "true"], Interval: 30, Timeout: 5, Retries: 3, StartPeriod: 10)
        var config = SynthesizedImageConfig()
        config.stopSignal = "SIGQUIT"
        config.healthcheck = healthcheck

        let dict = config.toDict()
        #expect(dict["StopSignal"] as? String == "SIGQUIT")
        let healthcheckDict = try #require(dict["Healthcheck"] as? [String: Any])
        #expect(healthcheckDict["Test"] as? [String] == ["CMD", "true"])
        #expect(healthcheckDict["Interval"] as? Int == 30)
        #expect(healthcheckDict["Timeout"] as? Int == 5)
        #expect(healthcheckDict["Retries"] as? Int == 3)
        #expect(healthcheckDict["StartPeriod"] as? Int == 10)
    }

    @Test("podm-internal labels never leak into the committed image")
    func podmInternalLabelsExcluded() throws {
        let container = try makeSnapshot(labels: [
            "podm.healthcheck": "{\"Test\":[\"CMD\",\"true\"]}",
            "podm.restart-policy": "{\"Name\":\"always\"}",
            "com.example.owner": "keep-me",
        ])
        let config = try ContainerCommitConfig.make(
            container: container, parent: nil, overrides: nil, changes: [])
        #expect(config.labels["com.example.owner"] == "keep-me")
        #expect(config.labels["podm.healthcheck"] == nil)
        #expect(config.labels["podm.restart-policy"] == nil)
    }
}
