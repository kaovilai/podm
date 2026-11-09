import ContainerizationError
import Foundation
import Vapor

/// `PUT /libpod/manifests/{name}` — real podman's unified add/remove/annotate endpoint
/// (`ManifestModifyOptions{Operation: "update"|"remove"|"annotate", Images: [...]}`).
/// "annotate" sets index-level annotations only (real podman's `podman manifest annotate
/// --index`); per-instance annotate (`podman manifest annotate <list> <instance>`) is not
/// implemented and answers 501 rather than faking success.
///
/// Real podman (`pkg/bindings/manifests`'s `Modify`) sends `operation`/`images`/etc. as
/// query parameters (`images` repeated once per image, like `platform` on `/build` — see
/// `allQueryValues`), NOT as a decodable request body: it does send a JSON body too, but
/// without a `Content-Type` header, so `req.content.decode` fails with "Can't decode data
/// without a content type" before ever reaching the body's actual content. The query
/// string carries the same data and is what's actually decoded here.
struct RESTManifestModifyQuery: Content {
    let operation: String?
}

struct LibpodManifestModifyRoute: RouteCollection {
    let client: ClientManifestServiceProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.PUT, pattern: "/libpod/manifests/{name:.*}", use: LibpodManifestModifyRoute.handler(client: client))
    }

    static func handler(client: ClientManifestServiceProtocol) -> @Sendable (Request) async throws -> RESTManifestIDResponse {
        { req in
            guard let name = req.parameters.get("name"), !name.isEmpty else {
                throw Abort(.badRequest, reason: "Missing manifest list name")
            }
            let query: RESTManifestModifyQuery
            do {
                query = try req.query.decode(RESTManifestModifyQuery.self)
            } catch {
                throw Abort(.badRequest, reason: "Invalid query parameters: \(error)")
            }
            let images = allQueryValues(named: "images", from: req.url.query)

            do {
                switch query.operation {
                case "remove":
                    guard !images.isEmpty else {
                        throw Abort(.badRequest, reason: "remove requires at least one image digest")
                    }
                    // Validate every requested digest is a current member BEFORE removing
                    // any of them — `removeDigest` re-tags after each single removal, so
                    // looping it directly would leave the manifest list partially modified
                    // (the first N-1 digests already removed) if a LATER digest in the same
                    // request turns out to be invalid, with no way for the caller to tell.
                    let currentDigests = Set(try await client.inspect(name: name).manifests.map(\.digest))
                    var normalizedDigests: [String] = []
                    var seenDigests = Set<String>()
                    for digest in images {
                        let normalized: String
                        if digest.hasPrefix("sha256:") {
                            normalized = digest
                        } else if digest.contains(":") {
                            throw Abort(.badRequest, reason: "\(digest) is not a supported digest (only sha256 is)")
                        } else {
                            normalized = "sha256:\(digest)"
                        }
                        guard currentDigests.contains(normalized) else {
                            throw Abort(.badRequest, reason: "\(normalized) is not a member of \(name)")
                        }
                        // A duplicate in the SAME request would otherwise pass this
                        // membership check (it IS currently a member) but then fail on its
                        // second removal attempt below (no longer a member after the
                        // first) — partially modifying the list for the exact reason this
                        // pre-check exists in the first place.
                        guard seenDigests.insert(normalized).inserted else {
                            throw Abort(.badRequest, reason: "\(normalized) is requested more than once")
                        }
                        normalizedDigests.append(normalized)
                    }
                    let result = try await client.removeDigests(name: name, digests: normalizedDigests)
                    return RESTManifestIDResponse(ID: result)
                case "annotate":
                    return try await handleAnnotate(req: req, name: name, queryImages: images, client: client)
                case "update", nil, "":
                    guard !images.isEmpty else {
                        throw Abort(.badRequest, reason: "update requires at least one image")
                    }
                    let result = try await client.add(name: name, images: images, logger: req.logger)
                    return RESTManifestIDResponse(ID: result)
                case .some(let unknown):
                    throw Abort(.badRequest, reason: "Unknown manifest modify operation: \(unknown)")
                }
            } catch ClientImageError.notFound(let id) {
                throw Abort(.badRequest, reason: "No such image: \(id)")
            } catch is ClientManifestError {
                throw Abort(.notFound, reason: "No such manifest list: \(name)")
            } catch let error as ContainerizationError where error.code == .invalidArgument {
                throw Abort(.badRequest, reason: error.message)
            }
        }
    }
}

extension LibpodManifestModifyRoute {
    /// The "annotate" operation — real podman's `podman manifest annotate --index <list>`
    /// (`--annotation k=v`): sets INDEX-LEVEL annotations on the manifest list itself.
    ///
    /// Real podman (pkg/api/handlers/libpod/manifests.go `ManifestModify`, v5 and v6) decodes
    /// the request body into `entities.ManifestModifyOptions`; the annotate operation reads the
    /// embedded `ManifestAnnotateOptions`. Podman's own bindings client marshals that struct
    /// with Go's encoding rules: tagged fields use their json tags (`index_annotations`,
    /// `subject`, `os_version`, …) but UNTAGGED fields marshal under their Go field names
    /// (`Operation`, `Images`, `Annotations`) — the Go server's decode matches keys
    /// case-insensitively, Swift's JSONDecoder does not. The body is therefore parsed with
    /// JSONSerialization and case-insensitive key matching, accepting every spelling real
    /// podman clients send. And like the rest of this endpoint family (see the route doc
    /// comment above), the bindings send that JSON body WITHOUT a `Content-Type` header, so
    /// `req.content.decode` is useless here — the raw bytes are decoded directly instead.
    ///
    /// Only index-level annotations are implemented. Requests real podman would serve but
    /// this daemon cannot answer honestly are rejected before any mutation happens:
    /// per-instance annotate (`images` naming a member plus member fields) and an index
    /// `subject` both answer 501 — never a silent no-op that fakes success.
    private static func handleAnnotate(
        req: Request, name: String, queryImages: [String], client: ClientManifestServiceProtocol
    ) async throws -> RESTManifestIDResponse {
        let body = try parseAnnotateBody(req)

        // Real podman's argument validation (abi `ManifestAnnotate`): index-wide fields
        // require NO instance digest, per-instance fields require one. An absent/empty
        // `images` entry (what the bindings send for `--index`) means the index itself.
        let hasInstance = (queryImages + body.images).contains(where: { !$0.isEmpty })

        if hasInstance {
            if body.hasIndexLevelFields {
                throw Abort(.badRequest, reason: "setting index-wide annotation in a manifest list requires no instance digest")
            }
            if body.hasMemberLevelFields {
                throw Abort(
                    .notImplemented,
                    reason: "per-instance manifest annotate is not implemented; only index-level annotations are supported (podman manifest annotate --index)"
                )
            }
        } else {
            if let memberField = body.memberLevelFieldLabel {
                throw Abort(.badRequest, reason: "setting \(memberField) on an item in a manifest list requires an instance digest")
            }
            if let subject = body.subject, !subject.isEmpty {
                throw Abort(.notImplemented, reason: "manifest index subject annotation is not implemented")
            }
        }

        // Real podman converts the k=v slice form into the map server-side before applying
        // (pkg/domain/utils `ParseAnnotations`): split on the FIRST "=", no "=" at all is an
        // error, an empty key or value is allowed.
        var annotations = body.indexAnnotations
        for spec in body.indexAnnotationSpecs {
            guard let separator = spec.firstIndex(of: "=") else {
                throw Abort(.badRequest, reason: "no value given for annotation \"\(spec)\"")
            }
            annotations[String(spec[..<separator])] = String(spec[spec.index(after: separator)...])
        }

        // Called inside the handler's do/catch, so a missing manifest list still maps to the
        // endpoint's usual 404 rather than a raw error.
        let result = try await client.annotate(name: name, annotations: annotations)
        return RESTManifestIDResponse(ID: result)
    }

    /// The annotate-relevant subset of real podman's `ManifestModifyOptions` body. Field
    /// presence matters as much as value: podman validates "index fields need no instance,
    /// member fields need one" per field, so emptiness is tracked rather than optionality.
    private struct ManifestAnnotateBody {
        var indexAnnotations: [String: String] = [:]
        var indexAnnotationSpecs: [String] = []
        var memberAnnotations: [String: String] = [:]
        var memberAnnotationSpecs: [String] = []
        var images: [String] = []
        var subject: String?
        var arch: String?
        var os: String?
        var osVersion: String?
        var variant: String?
        var features: [String] = []
        var osFeatures: [String] = []

        var hasIndexLevelFields: Bool {
            !indexAnnotations.isEmpty || !indexAnnotationSpecs.isEmpty || !(subject?.isEmpty ?? true)
        }

        /// Podman's own error label for whichever member-level field is set (its abi
        /// `ManifestAnnotate` rejects each with "setting X on an item in a manifest list
        /// requires an instance digest"), nil when no member-level field is present.
        var memberLevelFieldLabel: String? {
            if !memberAnnotations.isEmpty || !memberAnnotationSpecs.isEmpty { return "annotation" }
            if let arch, !arch.isEmpty { return "architecture" }
            if !features.isEmpty { return "features" }
            if let os, !os.isEmpty { return "OS" }
            if !osFeatures.isEmpty { return "OS features" }
            if let osVersion, !osVersion.isEmpty { return "OS version" }
            if let variant, !variant.isEmpty { return "variant" }
            return nil
        }

        var hasMemberLevelFields: Bool { memberLevelFieldLabel != nil }
    }

    /// Parses the annotate request body. An absent or empty body is an empty (no-op)
    /// annotate — real podman's own annotate with no fields set succeeds without changing
    /// anything. A malformed body, or one whose annotate fields have the wrong JSON type,
    /// is a 400 rather than a silent skip.
    private static func parseAnnotateBody(_ req: Request) throws -> ManifestAnnotateBody {
        var body = ManifestAnnotateBody()
        guard let bytes = req.body.data, bytes.readableBytes > 0 else {
            return body
        }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: Data(buffer: bytes)) as? [String: Any] else {
                throw Abort(.badRequest, reason: "annotate request body must be a JSON object")
            }
            object = decoded
        } catch let abort as Abort {
            throw abort
        } catch {
            throw Abort(.badRequest, reason: "invalid annotate request body: \(error)")
        }

        if let raw = value(in: object, for: "index_annotations") {
            body.indexAnnotations = try stringMap(raw, key: "index_annotations")
        }
        body.indexAnnotationSpecs = try stringArray(in: object, for: "index_annotation") ?? []
        if let raw = value(in: object, for: "annotations") {
            body.memberAnnotations = try stringMap(raw, key: "annotations")
        }
        body.memberAnnotationSpecs = try stringArray(in: object, for: "annotation") ?? []
        body.images = try stringArray(in: object, for: "images") ?? []
        body.subject = try string(in: object, for: "subject")
        body.arch = try string(in: object, for: "arch")
        body.os = try string(in: object, for: "os")
        body.osVersion = try string(in: object, for: "os_version")
        body.variant = try string(in: object, for: "variant")
        body.features = try stringArray(in: object, for: "features") ?? []
        body.osFeatures = try stringArray(in: object, for: "os_features") ?? []

        // Real podman's handler 400s when the map form and the k=v slice form of the same
        // field are both present (the slice is converted into the map server-side, so
        // allowing both would leave the intended value ambiguous).
        if !body.indexAnnotations.isEmpty && !body.indexAnnotationSpecs.isEmpty {
            throw Abort(.badRequest, reason: "can not set both IndexAnnotation and IndexAnnotations")
        }
        if !body.memberAnnotations.isEmpty && !body.memberAnnotationSpecs.isEmpty {
            throw Abort(.badRequest, reason: "can not set both Annotation and Annotations")
        }
        return body
    }

    /// Case-insensitive key lookup, mirroring how Go's encoding/json matches keys on decode:
    /// podman's bindings marshal untagged struct fields under their Go names ("Operation",
    /// "Images", "Annotations") while the tagged spellings are lowercase — both must work.
    /// A JSON null is treated as absent, matching how podman's bindings marshal unset
    /// pointer/slice fields.
    private static func value(in object: [String: Any], for key: String) -> Any? {
        guard let raw = object.first(where: { $0.key.lowercased() == key })?.value, !(raw is NSNull) else {
            return nil
        }
        return raw
    }

    private static func stringMap(_ raw: Any, key: String) throws -> [String: String] {
        guard let dict = raw as? [String: Any] else {
            throw Abort(.badRequest, reason: "\(key) must be a JSON object of annotation key/value strings")
        }
        var result: [String: String] = [:]
        for (annotationKey, annotationValue) in dict where !(annotationValue is NSNull) {
            guard let stringValue = annotationValue as? String else {
                throw Abort(.badRequest, reason: "\(key)[\(annotationKey)] must be a string")
            }
            result[annotationKey] = stringValue
        }
        return result
    }

    private static func stringArray(in object: [String: Any], for key: String) throws -> [String]? {
        guard let raw = value(in: object, for: key) else { return nil }
        guard let array = raw as? [Any] else {
            throw Abort(.badRequest, reason: "\(key) must be an array of strings")
        }
        return try array.map { element in
            guard let stringValue = element as? String else {
                throw Abort(.badRequest, reason: "\(key) must be an array of strings")
            }
            return stringValue
        }
    }

    private static func string(in object: [String: Any], for key: String) throws -> String? {
        guard let raw = value(in: object, for: key) else { return nil }
        guard let stringValue = raw as? String else {
            throw Abort(.badRequest, reason: "\(key) must be a string")
        }
        return stringValue
    }
}
