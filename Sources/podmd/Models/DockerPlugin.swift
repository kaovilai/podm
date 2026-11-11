// SPDX-License-Identifier: Apache-2.0
import Foundation
import Vapor

/// moby v28.5.2 plugin wire shapes (`api/types/plugin.go` and its sibling
/// files, all generated from the v1.51 swagger): the `Plugin` report served
/// by `GET /plugins` and `GET /plugins/{name}/json`, the `PluginConfig`
/// carried inside a plugin tarball's `config.json`, and the
/// `PluginPrivilege` list served by `GET /plugins/privileges`.
///
/// Decoding is LENIENT on purpose: moby decodes a plugin's `config.json`
/// with Go's `json.Unmarshal`, where a missing key becomes the zero value
/// and is never an error (and moby's own `validateConfig` is a no-op TODO —
/// `plugin/backend_linux.go`). Swift's synthesized `Codable` would reject
/// the same file, so every `init(from:)` below uses `decodeIfPresent` with
/// Go zero-value defaults.
///
/// Encoding normalizes those zero values to the REPORT shape moby serves:
/// missing strings become `""`, missing arrays become `[]` (DEVIATION: Go
/// marshals a nil slice as `null`; podm serves `[]` — the decoded-and-stored
/// config is normalized once at create, so the value is stable), and
/// `omitempty` fields (`DockerVersion`, `PluginReference`, `rootfs`) are
/// omitted when empty, matching Go's marshaling.
///
/// Key-shape notes verified against moby v28.5.2:
/// - `Plugin.Id` is the JSON key `Id` (mixed case — NOT `ID`).
/// - `PluginConfig.rootfs` is LOWERCASE on the wire (swagger quirk), with
///   `diff_ids` (snake case) and omitempty `type`.
/// - `PluginConfigUser` has omitempty on GID/UID, so Go serves an empty
///   `User` object as `{}`; podm decodes it leniently and re-encodes the
///   integers it found.
/// - `PluginInterfaceType` marshals as the STRING `"prefix.capability/version"`
///   (`api/types/plugin_responses.go` custom Marshaler/Unmarshaler), not as
///   an object — `DockerPluginInterfaceType` implements that below.

// MARK: - Plugin (the report)

/// moby `types.Plugin` — the list element and inspect body.
struct DockerPlugin: Content, Sendable, Equatable {
    /// `json:"Id,omitempty"` — moby mints this via `stringid.GenerateRandomID`
    /// (64 lowercase hex chars); never empty for a stored plugin.
    let Id: String
    /// `json:"Name"` — the familiar repo name, e.g. `vieux/sshfs:latest`.
    let Name: String
    /// `json:"Enabled"` — always false right after create (moby's
    /// `createPlugin` never enables; `enable` is the runtime half podm stubs).
    let Enabled: Bool
    /// `json:"PluginReference,omitempty"` — the remote reference the plugin
    /// was created from; moby's `CreateFromContext` sets it to the local name.
    let PluginReference: String?
    let Config: DockerPluginConfig
    let Settings: DockerPluginSettings
}

/// moby `types.PluginSettings` — "settings that can be modified by users".
/// moby fills them from the config via `v2.Plugin.InitEmptySettings`: mounts
/// and devices are struct copies, env becomes `name=value` strings, args copy
/// `Config.Args.Value`.
struct DockerPluginSettings: Codable, Sendable, Equatable {
    var Args: [String]
    var Devices: [DockerPluginDevice]
    var Env: [String]
    var Mounts: [DockerPluginMount]

    init(Args: [String] = [], Devices: [DockerPluginDevice] = [], Env: [String] = [], Mounts: [DockerPluginMount] = []) {
        self.Args = Args
        self.Devices = Devices
        self.Env = Env
        self.Mounts = Mounts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Args = try c.decodeIfPresent([String].self, forKey: .Args) ?? []
        Devices = try c.decodeIfPresent([DockerPluginDevice].self, forKey: .Devices) ?? []
        Env = try c.decodeIfPresent([String].self, forKey: .Env) ?? []
        Mounts = try c.decodeIfPresent([DockerPluginMount].self, forKey: .Mounts) ?? []
    }

    /// moby `Plugin.InitEmptySettings` — the settings a freshly created
    /// (never configured) plugin carries.
    static func emptySettings(from config: DockerPluginConfig) -> DockerPluginSettings {
        DockerPluginSettings(
            Args: config.Args?.Value ?? [],
            Devices: config.Linux?.Devices ?? [],
            Env: (config.Env ?? []).compactMap { env in env.Value.map { "\(env.Name)=\($0)" } },
            Mounts: config.Mounts ?? []
        )
    }
}

// MARK: - PluginConfig (the tarball's config.json, and the Config report)

/// moby `types.PluginConfig` — "the config of a plugin". Doubles as the
/// decoded `config.json` inside a plugin tarball (moby's
/// `CreateFromContext` json.Unmarshals exactly this type) and the `Config`
/// half of the report.
struct DockerPluginConfig: Codable, Sendable, Equatable {
    /// `json:"Args"` — the plugin's argument spec.
    var Args: DockerPluginConfigArgs?
    /// `json:"Description"`.
    var Description: String
    /// `json:"DockerVersion,omitempty"` — deprecated in the API but SET by
    /// moby on create (`config.DockerVersion = dockerversion.Version`); podm
    /// sets its own build version the same way.
    var DockerVersion: String?
    /// `json:"Documentation"`.
    var Documentation: String
    /// `json:"Entrypoint"`.
    var Entrypoint: [String]
    /// `json:"Env"`.
    var Env: [DockerPluginEnv]?
    /// `json:"Interface"` — the docker↔plugin contract.
    var Interface: DockerPluginConfigInterface?
    /// `json:"IpcHost"`.
    var IpcHost: Bool
    /// `json:"Linux"`.
    var Linux: DockerPluginConfigLinux?
    /// `json:"Mounts"`.
    var Mounts: [DockerPluginMount]?
    /// `json:"Network"`.
    var Network: DockerPluginConfigNetwork?
    /// `json:"PidHost"`.
    var PidHost: Bool
    /// `json:"PropagatedMount"`.
    var PropagatedMount: String
    /// `json:"User,omitempty"` — a struct, so Go's omitempty is a no-op and
    /// moby always emits the key; podm omits it when the config.json carried
    /// none (documented deviation, see the file header).
    var User: DockerPluginConfigUser?
    /// `json:"WorkDir"`.
    var WorkDir: String
    /// `json:"rootfs,omitempty"` — LOWERCASE key. moby's create sets it to
    /// `{Type: "layers", DiffIds: [rootfs blob digest]}`.
    var rootfs: DockerPluginConfigRootfs?

    init(
        Args: DockerPluginConfigArgs? = nil,
        Description: String = "",
        DockerVersion: String? = nil,
        Documentation: String = "",
        Entrypoint: [String] = [],
        Env: [DockerPluginEnv]? = nil,
        Interface: DockerPluginConfigInterface? = nil,
        IpcHost: Bool = false,
        Linux: DockerPluginConfigLinux? = nil,
        Mounts: [DockerPluginMount]? = nil,
        Network: DockerPluginConfigNetwork? = nil,
        PidHost: Bool = false,
        PropagatedMount: String = "",
        User: DockerPluginConfigUser? = nil,
        WorkDir: String = "",
        rootfs: DockerPluginConfigRootfs? = nil
    ) {
        self.Args = Args
        self.Description = Description
        self.DockerVersion = DockerVersion
        self.Documentation = Documentation
        self.Entrypoint = Entrypoint
        self.Env = Env
        self.Interface = Interface
        self.IpcHost = IpcHost
        self.Linux = Linux
        self.Mounts = Mounts
        self.Network = Network
        self.PidHost = PidHost
        self.PropagatedMount = PropagatedMount
        self.User = User
        self.WorkDir = WorkDir
        self.rootfs = rootfs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Args = try c.decodeIfPresent(DockerPluginConfigArgs.self, forKey: .Args)
        Description = try c.decodeIfPresent(String.self, forKey: .Description) ?? ""
        DockerVersion = try c.decodeIfPresentIfNotEmpty(String.self, forKey: .DockerVersion)
        Documentation = try c.decodeIfPresent(String.self, forKey: .Documentation) ?? ""
        Entrypoint = try c.decodeIfPresent([String].self, forKey: .Entrypoint) ?? []
        Env = try c.decodeIfPresent([DockerPluginEnv].self, forKey: .Env)
        Interface = try c.decodeIfPresent(DockerPluginConfigInterface.self, forKey: .Interface)
        IpcHost = try c.decodeIfPresent(Bool.self, forKey: .IpcHost) ?? false
        Linux = try c.decodeIfPresent(DockerPluginConfigLinux.self, forKey: .Linux)
        Mounts = try c.decodeIfPresent([DockerPluginMount].self, forKey: .Mounts)
        Network = try c.decodeIfPresent(DockerPluginConfigNetwork.self, forKey: .Network)
        PidHost = try c.decodeIfPresent(Bool.self, forKey: .PidHost) ?? false
        PropagatedMount = try c.decodeIfPresent(String.self, forKey: .PropagatedMount) ?? ""
        User = try c.decodeIfPresent(DockerPluginConfigUser.self, forKey: .User)
        WorkDir = try c.decodeIfPresent(String.self, forKey: .WorkDir) ?? ""
        rootfs = try c.decodeIfPresent(DockerPluginConfigRootfs.self, forKey: .rootfs)
    }
}

extension KeyedDecodingContainer {
    /// Decodes an optional string, treating `null`, absence, and the empty
    /// string all as nil — Go's `omitempty` marshaling cannot distinguish
    /// them, so podm keeps such fields absent instead of re-encoding "".
    func decodeIfPresentIfNotEmpty(_ type: String.Type, forKey key: Key) throws -> String? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        return value.isEmpty ? nil : value
    }
}

/// moby `types.PluginConfigArgs` — `json:"Description"/"Name"/"Settable"/"Value"`.
struct DockerPluginConfigArgs: Codable, Sendable, Equatable {
    var Description: String
    var Name: String
    var Settable: [String]
    var Value: [String]

    init(Description: String = "", Name: String = "", Settable: [String] = [], Value: [String] = []) {
        self.Description = Description
        self.Name = Name
        self.Settable = Settable
        self.Value = Value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Description = try c.decodeIfPresent(String.self, forKey: .Description) ?? ""
        Name = try c.decodeIfPresent(String.self, forKey: .Name) ?? ""
        Settable = try c.decodeIfPresent([String].self, forKey: .Settable) ?? []
        Value = try c.decodeIfPresent([String].self, forKey: .Value) ?? []
    }
}

/// moby `types.PluginConfigInterface` — `ProtocolScheme` is omitempty.
struct DockerPluginConfigInterface: Codable, Sendable, Equatable {
    var ProtocolScheme: String?
    var Socket: String
    var Types: [DockerPluginInterfaceType]

    init(ProtocolScheme: String? = nil, Socket: String = "", Types: [DockerPluginInterfaceType] = []) {
        self.ProtocolScheme = ProtocolScheme
        self.Socket = Socket
        self.Types = Types
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ProtocolScheme = try c.decodeIfPresentIfNotEmpty(String.self, forKey: .ProtocolScheme)
        Socket = try c.decodeIfPresent(String.self, forKey: .Socket) ?? ""
        Types = try c.decodeIfPresent([DockerPluginInterfaceType].self, forKey: .Types) ?? []
    }
}

/// moby `types.PluginConfigLinux` — devices and capabilities.
struct DockerPluginConfigLinux: Codable, Sendable, Equatable {
    var AllowAllDevices: Bool
    var Capabilities: [String]
    var Devices: [DockerPluginDevice]

    init(AllowAllDevices: Bool = false, Capabilities: [String] = [], Devices: [DockerPluginDevice] = []) {
        self.AllowAllDevices = AllowAllDevices
        self.Capabilities = Capabilities
        self.Devices = Devices
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        AllowAllDevices = try c.decodeIfPresent(Bool.self, forKey: .AllowAllDevices) ?? false
        Capabilities = try c.decodeIfPresent([String].self, forKey: .Capabilities) ?? []
        Devices = try c.decodeIfPresent([DockerPluginDevice].self, forKey: .Devices) ?? []
    }
}

/// moby `types.PluginConfigNetwork` — just the driver `Type` (the JSON key
/// stays `Type`; the Swift property is renamed because `Type` is reserved).
struct DockerPluginConfigNetwork: Codable, Sendable, Equatable {
    var networkType: String

    enum CodingKeys: String, CodingKey {
        case networkType = "Type"
    }

    init(networkType: String = "") {
        self.networkType = networkType
    }

    init(from decoder: Decoder) throws {
        networkType = (try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .networkType)) ?? ""
    }
}

/// moby `types.PluginConfigUser` — GID/UID are omitempty uint32.
struct DockerPluginConfigUser: Codable, Sendable, Equatable {
    var GID: UInt32
    var UID: UInt32

    enum CodingKeys: String, CodingKey {
        case GID, UID
    }

    init(GID: UInt32 = 0, UID: UInt32 = 0) {
        self.GID = GID
        self.UID = UID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        GID = try c.decodeIfPresent(UInt32.self, forKey: .GID) ?? 0
        UID = try c.decodeIfPresent(UInt32.self, forKey: .UID) ?? 0
    }

    /// Go omits zero-valued GID/UID (omitempty) — an all-zero user encodes
    /// as `{}`, and an omitted key decodes back as zeros.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if GID != 0 { try c.encode(GID, forKey: .GID) }
        if UID != 0 { try c.encode(UID, forKey: .UID) }
    }
}

/// moby `types.PluginConfigRootfs` — keys are `diff_ids` (snake) and
/// omitempty `type`; the whole struct is omitempty under the LOWERCASE
/// `rootfs` key of `PluginConfig`.
struct DockerPluginConfigRootfs: Codable, Sendable, Equatable {
    var diff_ids: [String]
    var type: String?

    init(diff_ids: [String] = [], type: String? = nil) {
        self.diff_ids = diff_ids
        self.type = type
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        diff_ids = try c.decodeIfPresent([String].self, forKey: .diff_ids) ?? []
        type = try c.decodeIfPresentIfNotEmpty(String.self, forKey: .type)
    }
}

// MARK: - Config element types

/// moby `types.PluginInterfaceType` — marshals as the STRING
/// `"prefix.capability/version"` via the custom coder in
/// `api/types/plugin_responses.go`. The unmarshaler scans for the LAST `.`
/// before the FIRST `/` (prefix), the span between them (capability), and
/// everything after the `/` (version) — no dot means an empty prefix, no
/// slash means an empty version.
struct DockerPluginInterfaceType: Codable, Sendable, Equatable, Hashable {
    var Prefix: String
    var Capability: String
    var Version: String

    init(Prefix: String, Capability: String, Version: String) {
        self.Prefix = Prefix
        self.Capability = Capability
        self.Version = Version
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let bytes = Array(raw.utf8)
        var prefixIndex = 0
        var versionIndex = bytes.count
        loop: for (i, b) in bytes.enumerated() {
            switch b {
            case UInt8(ascii: "."): prefixIndex = i
            case UInt8(ascii: "/"):
                versionIndex = i
                break loop
            default: break
            }
        }
        Prefix = String(decoding: bytes[0..<prefixIndex], as: UTF8.self)
        // moby's span arithmetic, verbatim — including its quirk for a
        // dotless string ("logdriver" → Capability "ogdriver"): prefixIndex
        // stays 0, so the capability span starts at byte 1.
        let lower = prefixIndex + 1
        let upper = max(lower, min(versionIndex, bytes.count))
        Capability = String(decoding: bytes[lower..<upper], as: UTF8.self)
        Version = versionIndex < bytes.count ? String(decoding: bytes[(versionIndex + 1)...], as: UTF8.self) : ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode("\(Prefix).\(Capability)/\(Version)")
    }
}

/// moby `types.PluginEnv` — `Value` is `*string` with NO omitempty, so Go
/// emits `null` for a nil value; podm mirrors that with an optional.
struct DockerPluginEnv: Codable, Sendable, Equatable {
    var Description: String
    var Name: String
    var Settable: [String]
    var Value: String?

    init(Description: String = "", Name: String = "", Settable: [String] = [], Value: String? = nil) {
        self.Description = Description
        self.Name = Name
        self.Settable = Settable
        self.Value = Value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Description = try c.decodeIfPresent(String.self, forKey: .Description) ?? ""
        Name = try c.decodeIfPresent(String.self, forKey: .Name) ?? ""
        Settable = try c.decodeIfPresent([String].self, forKey: .Settable) ?? []
        Value = try c.decodeIfPresent(String.self, forKey: .Value)
    }
}

/// moby `types.PluginDevice` — `Path` is `*string` without omitempty.
struct DockerPluginDevice: Codable, Sendable, Equatable {
    var Description: String
    var Name: String
    var Path: String?
    var Settable: [String]

    init(Description: String = "", Name: String = "", Path: String? = nil, Settable: [String] = []) {
        self.Description = Description
        self.Name = Name
        self.Path = Path
        self.Settable = Settable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Description = try c.decodeIfPresent(String.self, forKey: .Description) ?? ""
        Name = try c.decodeIfPresent(String.self, forKey: .Name) ?? ""
        Path = try c.decodeIfPresent(String.self, forKey: .Path)
        Settable = try c.decodeIfPresent([String].self, forKey: .Settable) ?? []
    }
}

/// moby `types.PluginMount` — `Source` is `*string` without omitempty; the
/// JSON key `Type` maps to a renamed Swift property (`Type` is reserved).
struct DockerPluginMount: Codable, Sendable, Equatable {
    var Description: String
    var Destination: String
    var Name: String
    var Options: [String]
    var Settable: [String]
    var Source: String?
    var mountType: String

    enum CodingKeys: String, CodingKey {
        case Description, Destination, Name, Options, Settable, Source
        case mountType = "Type"
    }

    init(
        Description: String = "", Destination: String = "", Name: String = "", Options: [String] = [],
        Settable: [String] = [], Source: String? = nil, mountType: String = ""
    ) {
        self.Description = Description
        self.Destination = Destination
        self.Name = Name
        self.Options = Options
        self.Settable = Settable
        self.Source = Source
        self.mountType = mountType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Description = try c.decodeIfPresent(String.self, forKey: .Description) ?? ""
        Destination = try c.decodeIfPresent(String.self, forKey: .Destination) ?? ""
        Name = try c.decodeIfPresent(String.self, forKey: .Name) ?? ""
        Options = try c.decodeIfPresent([String].self, forKey: .Options) ?? []
        Settable = try c.decodeIfPresent([String].self, forKey: .Settable) ?? []
        Source = try c.decodeIfPresent(String.self, forKey: .Source)
        mountType = try c.decodeIfPresent(String.self, forKey: .mountType) ?? ""
    }
}

// MARK: - Privileges

/// moby `types.PluginPrivilege` — no JSON tags, so Go marshals the field
/// names verbatim: `Name`, `Description`, `Value`.
struct DockerPluginPrivilege: Content, Sendable, Equatable {
    let Name: String
    let Description: String
    let Value: [String]
}
