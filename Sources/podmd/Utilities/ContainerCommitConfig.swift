import ContainerResource
import ContainerizationOCI
import Foundation

/// The subset of Docker's container `Config` that `docker commit`'s request
/// body may carry, as neutral (non-Vapor) values the pure merge below and its
/// unit tests can use. moby decodes a full `container.CreateRequest` superset
/// and discards the `HostConfig`/`NetworkingConfig` halves plus every
/// runtime-only field (Hostname, AttachStdin, …); those are accepted-and-
/// ignored by omission here rather than rejected.
struct CommitConfigOverrides {
    var user: String?
    var exposedPorts: Set<String>?
    var env: [String]?
    var entrypoint: [String]?
    var cmd: [String]?
    var volumes: Set<String>?
    var workingDir: String?
    var labels: [String: String]?

    init(
        user: String? = nil,
        exposedPorts: Set<String>? = nil,
        env: [String]? = nil,
        entrypoint: [String]? = nil,
        cmd: [String]? = nil,
        volumes: Set<String>? = nil,
        workingDir: String? = nil,
        labels: [String: String]? = nil
    ) {
        self.user = user
        self.exposedPorts = exposedPorts
        self.env = env
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.volumes = volumes
        self.workingDir = workingDir
        self.labels = labels
    }
}

/// Pure capture/merge of the run-config a `docker commit` bakes into the new
/// image — no I/O, fully unit-testable. Mirrors moby's
/// `daemon/commit.go CreateImageFromContainer`:
///
/// 1. start from the request body's `Config` (sparse; absent when the client
///    sent no body — moby then starts from the container's own config, which
///    the fill step below reconstructs);
/// 2. apply the `--change` Dockerfile instructions on top (`BuildFromConfig`);
/// 3. `merge()`: fill every still-unset field from the container, with the
///    parent image's config as the fallback for fields the snapshot cannot
///    represent or lacks.
///
/// Field sourcing follows what podm can actually know:
/// - `env`/`user`/`workingDir`/`labels` come from the snapshot's live process
///   configuration (the same values inspect reports — for a container created
///   without overrides these already contain the image's values);
/// - `Entrypoint`/`Cmd` cannot be recovered split from the snapshot alone
///   (create flattens `entrypoint + cmd` into `executable + arguments`), so
///   the parent image's config disambiguates: a parent with an ENTRYPOINT
///   means `[executable]` / `arguments`; a parent without one means the
///   executable is the head of the original CMD. Without a parent config the
///   inspect approximation (`Entrypoint: [executable]`, `Cmd: arguments`) is
///   used;
/// - `ExposedPorts`/`Volumes` exist only in the parent's raw config (Apple's
///   typed OCI `ImageConfig` does not model them) and the snapshot's
///   `publishedPorts` are host mappings, not image EXPOSE — so these come
///   only from the body and `--change` instructions, never seeded.
enum ContainerCommitConfig {
    static func make(
        container: ContainerSnapshot,
        parent: ContainerizationOCI.ImageConfig?,
        overrides: CommitConfigOverrides?,
        changes: [String]
    ) throws -> SynthesizedImageConfig {
        var config = SynthesizedImageConfig()

        // 1. Request-body Config — sparse, unset fields fall through.
        if let overrides {
            config.user = overrides.user
            config.exposedPorts = overrides.exposedPorts ?? []
            config.env = overrides.env ?? []
            config.entrypoint = overrides.entrypoint
            config.cmd = overrides.cmd
            config.volumes = overrides.volumes ?? []
            config.workingDir = overrides.workingDir
            config.labels = overrides.labels ?? [:]
        }

        // 2. --change Dockerfile instructions on top (moby BuildFromConfig
        // mutates the same request config before merge runs).
        try DockerfileChangeApplier.apply(changes, to: &config)

        // 3. moby's merge(): fill still-unset fields from the container.
        if (config.user ?? "").isEmpty {
            config.user = snapshotUser(container) ?? parent?.user
        }

        // Env: union by key — the snapshot's env first (it already holds the
        // create-time image+container union), then any parent entries the
        // snapshot itself doesn't carry. Entries already set by the body or a
        // change win; moby's merge appends missing container env the same way.
        var seenEnvKeys = Set(config.env.map(envKey))
        for entry in container.configuration.initProcess.environment
        where !seenEnvKeys.contains(envKey(entry)) {
            config.env.append(entry)
            seenEnvKeys.insert(envKey(entry))
        }
        for entry in parent?.env ?? []
        where !seenEnvKeys.contains(envKey(entry)) {
            config.env.append(entry)
            seenEnvKeys.insert(envKey(entry))
        }

        // Entrypoint/Cmd with moby's nil-vs-empty distinction: only when the
        // entrypoint is EMPTY may Cmd be inherited, and only a nil — never an
        // explicitly-emptied — entrypoint is inherited itself (so
        // `--change 'ENTRYPOINT []'` keeps the image entrypoint-less and a
        // body that sets Entrypoint suppresses Cmd inheritance, exactly like
        // moby's merge).
        if (config.entrypoint ?? []).isEmpty {
            if (config.cmd ?? []).isEmpty {
                config.cmd = snapshotCommand(container, parent: parent)
            }
            if config.entrypoint == nil {
                config.entrypoint = snapshotEntrypoint(container, parent: parent)
            }
        }

        if (config.workingDir ?? "").isEmpty {
            let snapshotDir = container.configuration.initProcess.workingDirectory
            config.workingDir = snapshotDir.isEmpty ? parent?.workingDir : snapshotDir
        }

        // Labels: fill missing keys — the container's labels (restored to
        // their original keys) first, then the parent image's.
        for (key, value) in LabelNormalization.restore(container.configuration.labels)
        where config.labels[key] == nil {
            config.labels[key] = value
        }
        for (key, value) in parent?.labels ?? [:]
        where config.labels[key] == nil {
            config.labels[key] = value
        }

        return config
    }

    /// moby's `container.Config.User` for the committed container: the live
    /// process user. `.id` has no username, so it renders as `uid:gid` — the
    /// same representation inspect reports.
    private static func snapshotUser(_ container: ContainerSnapshot) -> String? {
        switch container.configuration.initProcess.user {
        case .raw(let userString):
            return userString.isEmpty ? nil : userString
        case .id(let uid, let gid):
            return "\(uid):\(gid)"
        }
    }

    /// moby's `container.Config.Entrypoint`: `[executable]` when the parent
    /// image declares an ENTRYPOINT (the executable is its head), nil when
    /// the parent declares none (the executable is then really the head of
    /// the CMD — see `snapshotCommand`). Without a parent config, the same
    /// approximation `ContainerInspectRoute` reports is used.
    private static func snapshotEntrypoint(
        _ container: ContainerSnapshot,
        parent: ContainerizationOCI.ImageConfig?
    ) -> [String]? {
        let executable = container.configuration.initProcess.executable
        guard !executable.isEmpty else { return nil }
        if let parentEntrypoint = parent?.entrypoint, !parentEntrypoint.isEmpty {
            return [executable]
        }
        if parent == nil {
            return [executable]
        }
        return nil
    }

    /// moby's `container.Config.Cmd`: the arguments when the parent image
    /// declares an ENTRYPOINT; `[executable] + arguments` when it declares
    /// none (create-time flattening put the CMD head in `executable`);
    /// the bare arguments when the parent config is unknown (inspect
    /// approximation). nil rather than [] when empty, so an unset CMD is
    /// omitted from the synthesized config instead of pinned to `[]`.
    private static func snapshotCommand(
        _ container: ContainerSnapshot,
        parent: ContainerizationOCI.ImageConfig?
    ) -> [String]? {
        let executable = container.configuration.initProcess.executable
        let arguments = container.configuration.initProcess.arguments
        if let parentEntrypoint = parent?.entrypoint, !parentEntrypoint.isEmpty {
            return arguments.isEmpty ? nil : arguments
        }
        if parent == nil {
            return arguments.isEmpty ? nil : arguments
        }
        guard !executable.isEmpty || !arguments.isEmpty else { return nil }
        return [executable] + arguments
    }

    private static func envKey(_ entry: String) -> String {
        guard let equalsIndex = entry.firstIndex(of: "=") else { return entry }
        return String(entry[..<equalsIndex])
    }
}
