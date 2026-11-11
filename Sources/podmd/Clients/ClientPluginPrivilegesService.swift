// SPDX-License-Identifier: Apache-2.0
import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI
import Foundation
import Logging
import Vapor

/// moby's plugin-name grammar, shared by create (which stores names),
/// list/inspect (which resolve them) and privileges (which fetches remotes).
///
/// moby's `POST /plugins/create` flow (`plugin/backend_linux.go`
/// `CreateFromContext`): `reference.ParseNormalizedNamed(options.RepoName)`
/// → reject digest refs ("canonical references are not permitted") →
/// `reference.TagNameOnly` → `reference.FamiliarString`. The familiar form
/// is what moby STORES as `Plugin.Name` (e.g. `vieux/sshfs:latest`,
/// `myplugin:latest`) and what `Store.resolvePluginID` compares against.
///
/// The underlying `ContainerizationOCI.Reference` parse mirrors
/// distribution/reference's grammar (domain detection, path, tag, digest);
/// the docker.io special cases Go applies inside ParseNormalizedNamed and
/// FamiliarString — implicit docker.io domain and the `library/` path — are
/// applied here so a domainless single-component name round-trips as
/// `name:latest`, exactly like moby.
enum PluginReferenceUtility {
    enum NameError: Error, Equatable {
        /// distribution/reference's parse failure; moby wraps it as
        /// "failed to parse reference %v".
        case unparseable(String)
        /// moby CreateFromContext: "canonical references are not permitted".
        case canonical
    }

    /// moby's `Plugin.Id` shape (`pkg/stringid/stringid.go`
    /// `GenerateRandomID`): 64 lowercase hex characters.
    static let fullIDPattern = "^[a-f0-9]{64}$"

    /// The familiar repo name moby stores: ParseNormalizedNamed → no digest
    /// → TagNameOnly → FamiliarString. Domainless names default to docker.io
    /// semantics (a single path component gets `library/`, which Familiar
    /// strips back off); an explicit non-docker domain is kept.
    static func repoName(from raw: String) throws -> String {
        let reference: Reference
        do {
            reference = try Reference.parse(raw)
        } catch {
            throw NameError.unparseable(raw)
        }
        if reference.digest != nil {
            throw NameError.canonical
        }
        let domain = reference.domain
        // Go's ParseNormalizedNamed defaults an absent domain to docker.io;
        // registry-1.docker.io is its resolved form.
        let isDefaultRegistry =
            domain == nil || domain == "docker.io" || domain == "registry-1.docker.io"
        var path = reference.path
        if isDefaultRegistry, !path.contains("/") {
            path = "library/\(path)"
        }
        // TagNameOnly: an untagged, undigested ref gets :latest (digests
        // were rejected above).
        let tag = reference.tag ?? "latest"
        // FamiliarString: drop the docker.io domain and the exact
        // `library/<name>` two-component prefix; keep every other domain.
        if isDefaultRegistry, path.hasPrefix("library/") {
            let rest = String(path.dropFirst("library/".count))
            if !rest.contains("/") {
                path = rest
            }
        }
        let domainPrefix = isDefaultRegistry ? "" : "\(domain!)/"
        return "\(domainPrefix)\(path):\(tag)"
    }

    /// moby `Store.resolvePluginID`'s name lookup step: a ref that fails to
    /// parse resolves to NOTHING (the caller surfaces moby's 404
    /// `plugin "<input>" not found`), never a client error.
    static func lookupName(from raw: String) -> String? {
        try? repoName(from: raw)
    }

    /// Whether `input` is shaped like one of moby's full plugin IDs — the
    /// `validFullID` regex (`^([a-f0-9]{64})$`, `plugin/manager.go`).
    static func isFullID(_ input: String) -> Bool {
        input.range(of: fullIDPattern, options: .regularExpression) != nil
    }
}

// MARK: - Privileges

/// Seam for the privileges route: fetch a remote plugin reference's config
/// and compute the privileges installing it requires.
protocol PluginPrivilegesProviding: Sendable {
    func privileges(remote: String, authentication: Authentication?) async throws -> [DockerPluginPrivilege]
}

/// moby's `GET /plugins/privileges` backend (`plugin/backend_linux.go`
/// `Manager.Privileges`): resolve the reference at its registry, read the
/// image manifest, find the config blob (media type
/// `application/vnd.docker.plugin.config.v1+json`), decode it as a
/// `PluginConfig`, and run `computePrivileges` over it — no plugin runtime
/// involved, only registry reads.
///
/// The registry plumbing (scheme detection, auth, error mapping) mirrors
/// podm's distribution-inspect route (`RegistryDistributionProvider`), which
/// talks to the same `RegistryClient`.
struct RegistryPluginPrivilegesProvider: PluginPrivilegesProviding {
    /// `schema2.MediaTypePluginConfig` — moby's plugin config blob media type.
    static let pluginConfigMediaType = "application/vnd.docker.plugin.config.v1+json"

    let containerSystemConfig: ContainerSystemConfig

    func privileges(remote: String, authentication: Authentication?) async throws -> [DockerPluginPrivilege] {
        // moby's parseRemoteRef: ParseNormalizedNamed (digest refs allowed
        // here — the manifest is fetched by digest) + TagNameOnly.
        let reference: Reference
        do {
            reference = try Reference.parse(remote)
            if reference.tag == nil, reference.digest == nil {
                reference.normalize()
            }
        } catch {
            // distribution/reference's own message for a bad ref.
            throw Abort(.badRequest, reason: "invalid reference format")
        }
        // An absent domain means docker.io (ParseNormalizedNamed); Reference
        // resolves the legacy alias for us otherwise.
        let server = reference.resolvedDomain ?? "registry-1.docker.io"
        let client = try registryClient(server: server, authentication: authentication)

        let name = reference.path
        let descriptor: Descriptor
        do {
            descriptor = try await client.resolve(name: name, tag: reference.digest ?? reference.tag ?? "latest")
        } catch let error as RegistryClient.Error {
            throw DistributionJsonRoute.abort(for: error, reference: remote)
        }
        // moby's fetch handler only follows schema2/OCI image manifests;
        // an index or manifest list never yields a config descriptor.
        guard descriptor.mediaType == MediaTypes.dockerManifest || descriptor.mediaType == MediaTypes.imageManifest
        else {
            throw Abort(
                .badRequest,
                reason: "did not find plugin config for specified reference \(remote)")
        }
        let manifest: Manifest
        let configData: Data
        do {
            manifest = try await client.fetch(name: name, descriptor: descriptor)
            guard manifest.config.mediaType == Self.pluginConfigMediaType else {
                throw Abort(
                    .badRequest,
                    reason: "did not find plugin config for specified reference \(remote)")
            }
            configData = try await client.fetchData(name: name, descriptor: manifest.config)
        } catch let error as RegistryClient.Error {
            throw DistributionJsonRoute.abort(for: error, reference: remote)
        }
        guard let config = try? JSONDecoder().decode(DockerPluginConfig.self, from: configData) else {
            // moby: "error unmarshaling plugin config for %s" (a 500 there;
            // podm's standing deviation makes client-data errors 400s).
            throw Abort(.badRequest, reason: "failed to parse config")
        }
        return Self.computePrivileges(from: config)
    }

    private func registryClient(server: String, authentication: Authentication?) throws -> RegistryClient {
        let scheme = try RequestScheme.auto.schemeFor(host: server, internalDnsDomain: containerSystemConfig.dns.domain)
        guard let url = URL(string: "\(scheme.rawValue)://\(server)"), let host = url.host else {
            throw Abort(.badRequest, reason: "invalid registry host: \(server)")
        }
        return RegistryClient(host: host, scheme: scheme.rawValue, port: url.port, authentication: authentication)
    }

    /// moby `computePrivileges` (`plugin/backend_linux.go`), order preserved:
    /// network, host ipc, host pid, mounts, devices, allow-all-devices,
    /// capabilities. The descriptions and the `["true"]` values are moby's
    /// verbatim.
    static func computePrivileges(from config: DockerPluginConfig) -> [DockerPluginPrivilege] {
        var privileges: [DockerPluginPrivilege] = []
        let networkType = config.Network?.networkType ?? ""
        if networkType != "null", networkType != "bridge", networkType != "" {
            privileges.append(
                DockerPluginPrivilege(
                    Name: "network",
                    Description: "permissions to access a network",
                    Value: [networkType]))
        }
        if config.IpcHost {
            privileges.append(
                DockerPluginPrivilege(
                    Name: "host ipc namespace",
                    Description: "allow access to host ipc namespace",
                    Value: ["true"]))
        }
        if config.PidHost {
            privileges.append(
                DockerPluginPrivilege(
                    Name: "host pid namespace",
                    Description: "allow access to host pid namespace",
                    Value: ["true"]))
        }
        for mount in config.Mounts ?? [] where mount.Source != nil {
            privileges.append(
                DockerPluginPrivilege(
                    Name: "mount",
                    Description: "host path to mount",
                    Value: [mount.Source!]))
        }
        for device in config.Linux?.Devices ?? [] where device.Path != nil {
            privileges.append(
                DockerPluginPrivilege(
                    Name: "device",
                    Description: "host device to access",
                    Value: [device.Path!]))
        }
        if config.Linux?.AllowAllDevices == true {
            privileges.append(
                DockerPluginPrivilege(
                    Name: "allow-all-devices",
                    Description: "allow 'rwm' access to all devices",
                    Value: ["true"]))
        }
        let capabilities = config.Linux?.Capabilities ?? []
        if !capabilities.isEmpty {
            privileges.append(
                DockerPluginPrivilege(
                    Name: "capabilities",
                    Description: "list of additional capabilities required",
                    Value: capabilities))
        }
        return privileges
    }
}
