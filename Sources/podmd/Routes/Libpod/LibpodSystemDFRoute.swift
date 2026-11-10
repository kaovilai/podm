import Vapor

/// `GET /libpod/system/df` — `podman system df` / `podman system df -v`.
///
/// podman's remote client decodes this endpoint into `entities.SystemDfReport`
/// (pkg/domain/entities/types/system.go), whose field names and types differ
/// from the docker `/system/df` shape: per-item rows instead of summary types,
/// `ContainerID`/`RWSize` instead of `Id`/`SizeRw`, `Command` as []string, and
/// `Created` as time.Time (RFC3339 string — a unix int is a hard decode error,
/// which is how `podman system df` failed against the docker shape before this
/// mapping existed). The report is built from the same SystemDFRoute data, so
/// both dialects agree on every number.
struct LibpodSystemDFRoute: RouteCollection {
    let dockerRoute: SystemDFRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/system/df") { req in
            LibpodSystemDfReport(from: try await dockerRoute.report(req))
        }
    }
}

/// podman's `entities.SystemDfReport`: no json tags, so encoding/json uses the
/// Go field names verbatim. `ImagesSize` is the total size of all image layers
/// (podman's summary "SIZE" for images).
struct LibpodSystemDfReport: Content {
    let ImagesSize: Int64
    let Images: [LibpodSystemDfImageReport]
    let Containers: [LibpodSystemDfContainerReport]
    let Volumes: [LibpodSystemDfVolumeReport]

    init(from df: SystemDFResponse) {
        ImagesSize = df.LayersSize ?? 0
        Images = (df.Images ?? []).map(LibpodSystemDfImageReport.from)
        Containers = (df.Containers ?? []).map(LibpodSystemDfContainerReport.from)
        Volumes = (df.Volumes ?? []).map(LibpodSystemDfVolumeReport.from)
    }
}

/// podman's `entities.SystemDfImageReport`. SharedSize stays 0 — Apple
/// Container exposes no layer-sharing accounting, so every layer byte is
/// attributed uniquely (UniqueSize = Size) rather than guessed.
struct LibpodSystemDfImageReport: Content {
    let Repository: String
    let Tag: String
    let ImageID: String
    /// time.Time on podman's side: RFC3339.
    let Created: String
    let Size: Int64
    let SharedSize: Int64
    let UniqueSize: Int64
    let Containers: Int

    static func from(_ s: RESTImageSummary) -> LibpodSystemDfImageReport {
        // podman's libimage DiskUsage reports "<none>"/"<none>" for untagged
        // images; split the first repo tag at the last colon so registry
        // ports (localhost:5000/foo:tag) survive.
        var repository = "<none>"
        var tag = "<none>"
        if let first = s.RepoTags.first {
            if let separator = first.lastIndex(of: ":") {
                repository = String(first[first.startIndex..<separator])
                tag = String(first[first.index(after: separator)...])
            } else {
                repository = first
            }
        }
        return LibpodSystemDfImageReport(
            Repository: repository,
            Tag: tag,
            ImageID: s.Id,
            Created: AppleContainerTimestampResolver.iso8601Timestamp(
                Date(timeIntervalSince1970: TimeInterval(s.Created))),
            Size: s.Size,
            SharedSize: s.SharedSize,
            UniqueSize: s.Size - s.SharedSize,
            Containers: s.Containers
        )
    }
}

/// podman's `entities.SystemDfContainerReport`. Size/RWSize both come from
/// Apple's single aggregate disk-usage figure (the same figure the docker
/// dialect reports as SizeRw/SizeRootFs on /system/df); podman's CLI reads
/// RWSize for the size column and reclaimable math.
struct LibpodSystemDfContainerReport: Content {
    let ContainerID: String
    let Image: String
    let Command: [String]
    let LocalVolumes: Int
    let Size: Int64
    let RWSize: Int64
    /// time.Time on podman's side: RFC3339.
    let Created: String
    let Status: String
    let Names: String

    static func from(_ s: RESTContainerSummary) -> LibpodSystemDfContainerReport {
        LibpodSystemDfContainerReport(
            ContainerID: s.Id,
            // podman's own df report carries the image ID here, not the
            // reference (its CLI truncates the value for display).
            Image: s.ImageID,
            Command: s.Command.split(separator: " ").map(String.init),
            LocalVolumes: s.Mounts.filter { $0.type == "volume" }.count,
            Size: s.SizeRootFs ?? 0,
            RWSize: s.SizeRw ?? 0,
            Created: AppleContainerTimestampResolver.iso8601Timestamp(
                Date(timeIntervalSince1970: TimeInterval(s.Created))),
            Status: s.State,
            Names: s.Names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? ""
        )
    }
}

/// podman's `entities.SystemDfVolumeReport`: Links is the in-use (mounted)
/// count and ReclaimableSize is the full size for volumes nothing mounts —
/// the same semantics podman's own engine reports.
struct LibpodSystemDfVolumeReport: Content {
    let VolumeName: String
    let Links: Int
    let Size: Int64
    let ReclaimableSize: Int64

    static func from(_ v: Volume) -> LibpodSystemDfVolumeReport {
        let size = v.UsageData?.Size ?? 0
        let refCount = v.UsageData?.RefCount ?? 0
        return LibpodSystemDfVolumeReport(
            VolumeName: v.Name,
            Links: Int(refCount),
            Size: size,
            ReclaimableSize: refCount == 0 ? size : 0
        )
    }
}
