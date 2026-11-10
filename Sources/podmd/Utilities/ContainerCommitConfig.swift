import ContainerResource
import ContainerizationOCI
import Foundation
import Vapor

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
    var stopSignal: String?
    var healthcheck: HealthcheckConfig?

    init(
        user: String? = nil,
        exposedPorts: Set<String>? = nil,
        env: [String]? = nil,
        entrypoint: [String]? = nil,
        cmd: [String]? = nil,
        volumes: Set<String>? = nil,
        workingDir: String? = nil,
        labels: [String: String]? = nil,
        stopSignal: String? = nil,
        healthcheck: HealthcheckConfig? = nil
    ) {
        self.user = user
        self.exposedPorts = exposedPorts
        self.env = env
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.volumes = volumes
        self.workingDir = workingDir
        self.labels = labels
        self.stopSignal = stopSignal
        self.healthcheck = healthcheck
    }
}

/// Pure capture/merge of the run-config a `docker commit` bakes into the new
/// image — no I/O, fully unit-testable. Mirrors moby's
/// `daemon/commit.go CreateImageFromContainer`:
///
/// 1. start from the request body's `Config` (sparse; absent when the client
///    sent no body — moby then starts from the container's own config, which
///    is pre-seeded for the Entrypoint/Cmd pair and reconstructed by the
///    fill step below for the rest);
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
///   the parent image's config disambiguates: when the live flattened process
///   begins with the parent's full ENTRYPOINT array, the split happens there
///   (entrypoint = the parent's array verbatim, cmd = the remainder — a
///   create-time CMD override survives the split). When it does not, the
///   entrypoint was overridden at create time and the split is unrecoverable —
///   the inspect approximation (`Entrypoint: [executable]`, `Cmd: arguments`)
///   is used, as it also is without a parent config. A parent with an EMPTY
///   entrypoint means the executable is the head of the original CMD;
/// - `ExposedPorts`/`Volumes` exist only in the parent's raw config JSON
///   (Apple's typed OCI `ImageConfig` does not model them) and the snapshot's
///   `publishedPorts` are host mappings, not image EXPOSE — so the body's and
///   `--change`'s values are UNIONED with the parent's (extracted by
///   `commitParentConfig` from the same raw blob), never replaced by them;
/// - `StopSignal` comes from the body override, else the container's persisted
///   create-time signal, else the parent's;
/// - `Healthcheck` comes from the body override, else the container's
///   effective healthcheck (the JSON label the create route persisted, parsed
///   the same way inspect parses it — it already holds the image's
///   HEALTHCHECK merged with any create-time request).
enum ContainerCommitConfig {
    static func make(
        container: ContainerSnapshot,
        parent: ContainerizationOCI.ImageConfig?,
        parentExposedPorts: Set<String> = [],
        parentVolumes: Set<String> = [],
        overrides: CommitConfigOverrides?,
        changes: [String]
    ) throws -> SynthesizedImageConfig {
        var config = SynthesizedImageConfig()

        // moby's `if c.Config == nil { c.Config = container.Config }`: with
        // no request body, BuildFromConfig starts from the CONTAINER's own
        // config, so the --change instructions apply on top of the
        // container's Entrypoint/Cmd pair. Pre-seeding the pair here is what
        // makes an explicitly-emptied Cmd survive: `--change 'CMD []'` on a
        // container with a nonempty entrypoint keeps Cmd empty, because the
        // merge below gates the Cmd refill on the FINAL entrypoint state
        // (moby's merge only fills Cmd while the entrypoint is empty).
        if overrides == nil {
            let split = snapshotProcessSplit(container, parent: parent)
            config.entrypoint = split.entrypoint
            config.cmd = split.cmd
        }

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
            config.stopSignal = overrides.stopSignal
            config.healthcheck = overrides.healthcheck
        }

        // 2. --change Dockerfile instructions on top (moby BuildFromConfig
        // mutates the same request config before merge runs). A RELATIVE
        // WORKDIR resolves against the container's effective working
        // directory — the snapshot's live one, falling back to the parent
        // image's — because moby's BuildFromConfig starts from the
        // container's config, whose WorkingDir is the join base
        // (normalizeWorkdir). Absolute paths pass through untouched.
        let snapshotWorkingDir = container.configuration.initProcess.workingDirectory
        let effectiveWorkingDir = snapshotWorkingDir.isEmpty ? parent?.workingDir : snapshotWorkingDir
        try DockerfileChangeApplier.apply(changes, to: &config, baseWorkingDir: effectiveWorkingDir)

        // EXPOSE/VOLUME inheritance: union the parent's raw-config keys with
        // whatever the body and --change set, so a no-change commit of an
        // image declaring them keeps them (moby's container config carried
        // them from create; the union is the closest podm can express since
        // the snapshot has no image-side EXPOSE/VOLUME to read).
        config.exposedPorts.formUnion(parentExposedPorts)
        config.volumes.formUnion(parentVolumes)

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
            let split = snapshotProcessSplit(container, parent: parent)
            if (config.cmd ?? []).isEmpty {
                config.cmd = split.cmd
            }
            if config.entrypoint == nil {
                config.entrypoint = split.entrypoint
            }
        }

        if (config.workingDir ?? "").isEmpty {
            let snapshotDir = container.configuration.initProcess.workingDirectory
            config.workingDir = snapshotDir.isEmpty ? parent?.workingDir : snapshotDir
        }

        // StopSignal: the container's persisted create-time signal, else the
        // parent's (create only persists an explicit request — a container
        // from a STOPSIGNAL image that didn't override still needs the image's
        // signal carried into the commit).
        if (config.stopSignal ?? "").isEmpty {
            config.stopSignal = container.configuration.stopSignal ?? parent?.stopSignal
        }

        // Healthcheck: the container's effective healthcheck — the JSON label
        // the create route persisted (image HEALTHCHECK merged with the
        // create-time request), parsed exactly like ContainerInspectRoute
        // parses it. No label → no healthcheck to carry. A PARTIAL body or
        // --change healthcheck merges FIELD-WISE over it (moby's merge fills
        // every zero-valued field from the container's config): nil fields
        // inherit, set fields replace. `Test: ["NONE"]` is moby's disable
        // marker and replaces wholesale — a disabled healthcheck inherits
        // nothing.
        if config.healthcheck == nil {
            config.healthcheck = snapshotHealthcheck(container)
        } else if let carried = snapshotHealthcheck(container), config.healthcheck?.Test != ["NONE"] {
            config.healthcheck = mergeHealthcheckFields(config.healthcheck!, over: carried)
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

    /// Splits the snapshot's flattened live process (`executable +
    /// arguments`, what create produced from `entrypoint + cmd`) back into
    /// moby's `container.Config.Entrypoint`/`Cmd` pair:
    ///
    /// - Parent with a non-empty ENTRYPOINT: when the flattened process
    ///   BEGINS with the parent's full entrypoint array, split there —
    ///   entrypoint is the parent's array verbatim, cmd is the remainder (a
    ///   create-time CMD override survives). Multi-element entrypoints
    ///   (`ENTRYPOINT ["/bin/sh", "-c"]`) stay intact instead of leaking
    ///   their tail into Cmd. When the flattened process does NOT begin with
    ///   the parent's entrypoint, the entrypoint was overridden at create
    ///   time and the true split is unrecoverable — fall back to the inspect
    ///   approximation (`Entrypoint: [executable]`, `Cmd: arguments`).
    /// - Parent with an empty entrypoint: the create-time flattening put the
    ///   CMD head in `executable`, so cmd is `[executable] + arguments` and
    ///   there is no entrypoint.
    /// - No parent config: the inspect approximation, like
    ///   `ContainerInspectRoute` reports.
    ///
    /// cmd is nil rather than [] when empty, so an unset CMD is omitted from
    /// the synthesized config instead of pinned to `[]`.
    private static func snapshotProcessSplit(
        _ container: ContainerSnapshot,
        parent: ContainerizationOCI.ImageConfig?
    ) -> (entrypoint: [String]?, cmd: [String]?) {
        let executable = container.configuration.initProcess.executable
        let arguments = container.configuration.initProcess.arguments
        guard !executable.isEmpty else { return (nil, arguments.isEmpty ? nil : arguments) }

        if let parentEntrypoint = parent?.entrypoint, !parentEntrypoint.isEmpty {
            let flattened = [executable] + arguments
            if flattened.starts(with: parentEntrypoint) {
                let remainder = Array(flattened[parentEntrypoint.count...])
                return (parentEntrypoint, remainder.isEmpty ? nil : remainder)
            }
            // Overridden at create — the split is unrecoverable; approximate.
            return ([executable], arguments.isEmpty ? nil : arguments)
        }
        if parent == nil {
            return ([executable], arguments.isEmpty ? nil : arguments)
        }
        return (nil, [executable] + arguments)
    }

    /// The container's effective healthcheck: the JSON label the create route
    /// persisted (image HEALTHCHECK merged with the create-time request),
    /// decoded exactly the way `ContainerInspectRoute` decodes it.
    private static func snapshotHealthcheck(_ container: ContainerSnapshot) -> HealthcheckConfig? {
        container.configuration.labels[HealthCheckManager.healthcheckLabel]
            .flatMap { Data($0.utf8) }
            .flatMap { try? JSONDecoder().decode(HealthcheckConfig.self, from: $0) }
    }

    /// moby's merge() healthcheck fill: each field the request left unset
    /// (nil here, zero there) inherits the container's value; set fields
    /// replace it.
    private static func mergeHealthcheckFields(
        _ requested: HealthcheckConfig, over carried: HealthcheckConfig
    ) -> HealthcheckConfig {
        HealthcheckConfig(
            Test: requested.Test ?? carried.Test,
            Interval: requested.Interval ?? carried.Interval,
            Timeout: requested.Timeout ?? carried.Timeout,
            Retries: requested.Retries ?? carried.Retries,
            StartPeriod: requested.StartPeriod ?? carried.StartPeriod,
            StartInterval: requested.StartInterval ?? carried.StartInterval)
    }

    private static func envKey(_ entry: String) -> String {
        guard let equalsIndex = entry.firstIndex(of: "=") else { return entry }
        return String(entry[..<equalsIndex])
    }
}
