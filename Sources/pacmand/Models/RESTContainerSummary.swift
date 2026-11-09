import Vapor

struct ContainerState: Content {
    let Status: String
    let Running: Bool
    let Paused: Bool
    let Restarting: Bool
    let OOMKilled: Bool
    let Dead: Bool
    let Pid: Int
    let ExitCode: Int
    let Error: String
    let StartedAt: String
    let FinishedAt: String
    let Health: ContainerHealth?
}

struct RESTContainerSummary: Content {
    let Id: String
    let Names: [String]
    let Image: String
    let ImageID: String
    let ImageManifestDescriptor: ImageOCIDescriptor?
    let Command: String
    let Created: Int64
    /// Unix seconds the init process last started, nil when never started.
    /// Extra field beyond Docker's shape (clients ignore unknown fields);
    /// consumed by the libpod list route for podman's ListContainer.StartedAt.
    let StartedAtUnix: Int64?
    /// Recorded init-process exit code, nil while running/never started.
    /// Consumed by the libpod list route for podman's ListContainer.ExitCode.
    let ExitCode: Int32?
    /// Unix seconds the init process exited, nil while running/never started.
    /// Consumed by the libpod list route for podman's ListContainer.ExitedAt.
    let ExitedAtUnix: Int64?
    let Ports: [ContainerPort]
    let SizeRw: Int64?
    let SizeRootFs: Int64?
    let Labels: [String: String]
    let State: String
    let Status: String
    let HostConfig: ContainerHostConfig
    let NetworkSettings: ContainerNetworkSummary
    let Mounts: [ContainerMountPoint]
    let Platform: String
}

struct RESTContainerInspect: Content {
    let Id: String
    let Created: String?
    let Path: String
    let Args: [String]
    let State: ContainerState
    let Image: String
    let ResolvConfPath: String
    let HostnamePath: String
    let HostsPath: String
    let LogPath: String?
    let Name: String
    let RestartCount: Int
    let Driver: String
    let Platform: String
    let ImageManifestDescriptor: ImageOCIDescriptor?
    let MountLabel: String
    let ProcessLabel: String
    let AppArmorProfile: String
    let ExecIDs: [String]?
    let HostConfig: HostConfig
    let GraphDriver: ContainerDriverData
    let SizeRw: Int64?
    let SizeRootFs: Int64?
    let Mounts: [ContainerMountPoint]
    let Config: ContainerConfig
    let NetworkSettings: ContainerNetworkSettings
}

struct RESTContainerListQuery: Content {
    let all: Bool?
}
