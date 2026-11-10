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
        labels: [String: String] = ["com.example.owner": "ctr"]
    ) -> ContainerSnapshot {
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
        configuration.labels = labels
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
            container: makeSnapshot(), parent: nil, overrides: nil, changes: [])

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
            container: makeSnapshot(), parent: makeParent(), overrides: nil, changes: [])

        #expect(config.entrypoint == ["/app"])
        #expect(config.cmd == ["serve", "--verbose"])
    }

    @Test("a parent without an ENTRYPOINT means the executable is the head of the original CMD")
    func parentWithoutEntrypointFoldsExecutableIntoCmd() throws {
        let parent = makeParent(entrypoint: nil, cmd: ["/app", "serve"])
        let config = try ContainerCommitConfig.make(
            container: makeSnapshot(), parent: parent, overrides: nil, changes: [])

        #expect(config.entrypoint == nil)
        #expect(config.cmd == ["/app", "serve", "--verbose"])
    }

    @Test("env unions by key: container entries first, parent entries only for keys neither carries")
    func envUnionsByKey() throws {
        let config = try ContainerCommitConfig.make(
            container: makeSnapshot(), parent: makeParent(), overrides: nil, changes: [])

        // MODE=container (snapshot) wins over MODE=image (parent); EXTRA
        // (parent-only) is appended.
        #expect(config.env == ["PATH=/usr/bin", "MODE=container", "EXTRA=from-parent"])
    }

    @Test("labels fill missing keys: snapshot labels win, parent labels fill the gaps")
    func labelsFillMissingKeys() throws {
        let config = try ContainerCommitConfig.make(
            container: makeSnapshot(), parent: makeParent(), overrides: nil, changes: [])

        #expect(
            config.labels == [
                "com.example.owner": "ctr",
                "com.example.other": "image",
            ])
    }

    @Test("user and workingDir fall back to the parent when the snapshot has none")
    func userAndWorkdirFallBackToParent() throws {
        let snapshot = makeSnapshot(workingDirectory: "", user: .raw(userString: ""))
        let config = try ContainerCommitConfig.make(
            container: snapshot, parent: makeParent(user: "42", workingDir: "/opt"), overrides: nil, changes: [])

        #expect(config.user == "42")
        #expect(config.workingDir == "/opt")
    }

    @Test("a numeric process user renders as uid:gid, the same as inspect")
    func numericUser() throws {
        let snapshot = makeSnapshot(user: .id(uid: 1000, gid: 1000))
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
            container: makeSnapshot(), parent: makeParent(), overrides: overrides, changes: [])

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
            container: makeSnapshot(), parent: makeParent(), overrides: overrides, changes: [])

        #expect(config.env == ["MODE=body", "NEW=1", "PATH=/usr/bin", "EXTRA=from-parent"])
    }

    @Test("an explicitly empty body Entrypoint stays empty — the captured one is not inherited")
    func explicitEmptyEntrypointStaysEmpty() throws {
        // Non-nil empty ≠ unset for moby's merge: an explicitly emptied
        // Entrypoint is not refilled from the container.
        let overrides = CommitConfigOverrides(entrypoint: [])
        let config = try ContainerCommitConfig.make(
            container: makeSnapshot(), parent: makeParent(), overrides: overrides, changes: [])

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
            container: makeSnapshot(), parent: makeParent(), overrides: overrides, changes: [])

        #expect(config.entrypoint == ["/only-entrypoint"])
        #expect(config.cmd == nil)
    }

    @Test("body ExposedPorts and Volumes pass straight through")
    func bodyPortsAndVolumes() throws {
        let overrides = CommitConfigOverrides(
            exposedPorts: ["80/tcp", "53/udp"], volumes: ["/data", "/config"])
        let config = try ContainerCommitConfig.make(
            container: makeSnapshot(), parent: nil, overrides: overrides, changes: [])

        #expect(config.exposedPorts == ["80/tcp", "53/udp"])
        #expect(config.volumes == ["/data", "/config"])
    }

    // MARK: - --change instructions

    @Test("--change instructions apply on top of the body and the fill completes around them")
    func changesApplyOnTop() throws {
        let config = try ContainerCommitConfig.make(
            container: makeSnapshot(),
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
            container: makeSnapshot(), parent: nil, overrides: nil, changes: ["ENV MODE=changed"])

        #expect(config.env == ["MODE=changed", "PATH=/usr/bin"])
    }

    @Test("an invalid --change instruction is rejected")
    func invalidChangeRejected() throws {
        #expect(throws: DockerfileChangeError.self) {
            _ = try ContainerCommitConfig.make(
                container: makeSnapshot(), parent: nil, overrides: nil, changes: ["ONBUILD x"])
        }
    }
}
