import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import podmd

@Suite("LibpodManifestModifyRoute")
struct LibpodManifestModifyRouteTests {
    @Test("default operation (no 'operation' param) adds images, matching podman's 'update' default")
    func defaultOperationAdds() async throws {
        let receivedImages = Box<[String]?>(nil)
        let client = MockManifestClient(addHandler: { _, images in
            await receivedImages.set(images)
            return "sha256:added"
        })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?images=alpine:latest") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(RESTManifestIDResponse.self, from: Data(buffer: res.body))
                #expect(body.ID == "sha256:added")
            }
        }
        #expect(await receivedImages.get() == ["alpine:latest"])
    }

    @Test("explicit operation=update adds images the same as the default")
    func explicitUpdateAdds() async throws {
        let addCalled = Box(false)
        let client = MockManifestClient(addHandler: { _, _ in
            await addCalled.set(true)
            return "sha256:added"
        })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=update&images=alpine:latest") { res async throws in
                #expect(res.status == .ok)
            }
        }
        #expect(await addCalled.get())
    }

    @Test("update with no images is a 400, not an empty no-op update")
    func updateWithNoImagesIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("operation=remove removes every listed digest in a single batch call")
    func removeDigestsInOneBatch() async throws {
        let removedDigests = Box<[String]>([])
        let client = MockManifestClient(
            inspectHandler: { _ in
                Index(manifests: [
                    Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:aaa", size: 100),
                    Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:bbb", size: 100),
                ])
            },
            removeDigestsHandler: { _, digests in
                await removedDigests.set(digests)
                return "sha256:afterremoval"
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove&images=sha256:aaa&images=sha256:bbb") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(RESTManifestIDResponse.self, from: Data(buffer: res.body))
                #expect(body.ID == "sha256:afterremoval")
            }
        }
        #expect(await removedDigests.get() == ["sha256:aaa", "sha256:bbb"])
    }

    @Test("remove with no images is a 400")
    func removeWithNoImagesIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("a non-sha256 digest is rejected as unsupported, not silently mangled into a malformed sha256 value")
    func removeWithNonSha256DigestIs400() async throws {
        let client = MockManifestClient(
            inspectHandler: { _ in
                Index(manifests: [Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:aaa", size: 100)])
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove&images=sha512:abc") { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("not a supported digest"))
            }
        }
    }

    @Test("a later invalid digest in a multi-digest remove is rejected before any digest is actually removed")
    func removeRejectsBeforeMutatingWhenADigestIsInvalid() async throws {
        let removedDigests = Box<[String]>([])
        let client = MockManifestClient(
            inspectHandler: { _ in
                // Only "sha256:aaa" is an actual member — "sha256:bbb" is not.
                Index(manifests: [Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:aaa", size: 100)])
            },
            removeDigestsHandler: { _, digests in
                await removedDigests.set(await removedDigests.get() + digests)
                return "sha256:afterremoval"
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove&images=sha256:aaa&images=sha256:bbb") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
        // Neither digest was actually removed — validation ran before any mutation, even
        // though "sha256:aaa" alone would have succeeded if processed first.
        #expect(await removedDigests.get() == [])
    }

    @Test("a digest requested twice in the same remove is rejected before any digest is actually removed")
    func removeRejectsDuplicateDigestBeforeMutating() async throws {
        let removedDigests = Box<[String]>([])
        let client = MockManifestClient(
            inspectHandler: { _ in
                Index(manifests: [Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:aaa", size: 100)])
            },
            removeDigestsHandler: { _, digests in
                await removedDigests.set(await removedDigests.get() + digests)
                return "sha256:afterremoval"
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove&images=sha256:aaa&images=sha256:aaa") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
        // Without the duplicate check, the first occurrence would succeed and the second
        // would fail (no longer a member after the first removal) — a partial mutation
        // masquerading as a whole-request failure, the exact bug this pre-check prevents.
        #expect(await removedDigests.get() == [])
    }

    @Test("operation=annotate with an index_annotations map body annotates the manifest list index")
    func annotateIndexMap() async throws {
        let receivedAnnotations = Box<[String: String]?>(nil)
        let client = MockManifestClient(annotateHandler: { _, annotations in
            await receivedAnnotations.set(annotations)
            return "sha256:annotated"
        })

        try await withModifyApp(client: client) { app in
            // Podman's bindings send the JSON body WITHOUT a Content-Type header, like the
            // rest of this endpoint family.
            let body = ByteBuffer(string: #"{"operation":"annotate","index_annotations":{"org.opencontainers.image.title":"mylist"}}"#)
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=annotate", body: body) { res async throws in
                #expect(res.status == .ok)
                let responseBody = try JSONDecoder().decode(RESTManifestIDResponse.self, from: Data(buffer: res.body))
                #expect(responseBody.ID == "sha256:annotated")
            }
        }
        #expect(await receivedAnnotations.get() == ["org.opencontainers.image.title": "mylist"])
    }

    @Test("annotate accepts podman's Go field-name body spellings (Operation, Images)")
    func annotateGoFieldCasing() async throws {
        // Podman's bindings marshal UNtagged Go struct fields under their Go names
        // ("Operation", "Images") while tagged fields keep their json tags
        // ("index_annotations") — Go's server-side decode matches keys
        // case-insensitively, so both spellings must be accepted here.
        let receivedAnnotations = Box<[String: String]?>(nil)
        let client = MockManifestClient(annotateHandler: { _, annotations in
            await receivedAnnotations.set(annotations)
            return "sha256:annotated"
        })

        try await withModifyApp(client: client) { app in
            let body = ByteBuffer(string: #"{"Operation":"annotate","Images":[""],"index_annotations":{"a":"b"}}"#)
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=annotate", body: body) { res async throws in
                #expect(res.status == .ok)
            }
        }
        // "Images": [""] is an empty instance entry — podman's bindings send it for
        // `manifest annotate --index`; it must NOT count as a member instance.
        #expect(await receivedAnnotations.get() == ["a": "b"])
    }

    @Test("annotate with the index_annotation k=v slice form merges it into the map")
    func annotateIndexSliceForm() async throws {
        let receivedAnnotations = Box<[String: String]?>(nil)
        let client = MockManifestClient(annotateHandler: { _, annotations in
            await receivedAnnotations.set(annotations)
            return "sha256:annotated"
        })

        try await withModifyApp(client: client) { app in
            let body = ByteBuffer(string: #"{"index_annotation":["left=right","empty="]}"#)
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=annotate", body: body) { res async throws in
                #expect(res.status == .ok)
            }
        }
        #expect(await receivedAnnotations.get() == ["left": "right", "empty": ""])
    }

    @Test("annotate with both the map and the k=v slice form is a 400, not an ambiguous merge")
    func annotateBothFormsIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            let body = ByteBuffer(string: #"{"index_annotations":{"a":"b"},"index_annotation":["c=d"]}"#)
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=annotate", body: body) { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("can not set both IndexAnnotation and IndexAnnotations"))
            }
        }
    }

    @Test("annotate with a k=v spec missing '=' is a 400")
    func annotateBadSpecIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            let body = ByteBuffer(string: #"{"index_annotation":["novalue"]}"#)
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=annotate", body: body) { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("no value given for annotation"))
            }
        }
    }

    @Test("annotate with a malformed JSON body is a 400")
    func annotateMalformedBodyIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            let body = ByteBuffer(string: #"{"index_annotations":"#)
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=annotate", body: body) { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("annotate with a member instance plus member fields is an honest 501, not a faked success")
    func annotateMemberLevelIs501() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            let body = ByteBuffer(string: #"{"annotations":{"a":"b"},"images":["sha256:aaa"]}"#)
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=annotate", body: body) { res async throws in
                #expect(res.status == .notImplemented)
                #expect(res.body.string.contains("per-instance manifest annotate is not implemented"))
            }
        }
    }

    @Test("annotate with member fields but no instance is a 400, matching podman's own validation")
    func annotateMemberFieldsWithoutInstanceIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            let body = ByteBuffer(string: #"{"annotations":{"a":"b"}}"#)
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=annotate", body: body) { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("requires an instance digest"))
            }
        }
    }

    @Test("annotate with index fields plus a member instance is a 400, matching podman's own validation")
    func annotateIndexFieldsWithInstanceIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            let body = ByteBuffer(string: #"{"index_annotations":{"a":"b"},"images":["sha256:aaa"]}"#)
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=annotate", body: body) { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("requires no instance digest"))
            }
        }
    }

    @Test("annotate with an index subject is an honest 501, not a silently-dropped field")
    func annotateSubjectIs501() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            let body = ByteBuffer(string: #"{"subject":"registry.example.com/repo:latest"}"#)
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=annotate", body: body) { res async throws in
                #expect(res.status == .notImplemented)
                #expect(res.body.string.contains("subject"))
            }
        }
    }

    @Test("annotating a nonexistent manifest list is a 404")
    func annotateNonexistentManifestIs404() async throws {
        let client = MockManifestClient(annotateHandler: { name, _ in
            throw ClientManifestError.notFound(name: name)
        })

        try await withModifyApp(client: client) { app in
            let body = ByteBuffer(string: #"{"index_annotations":{"a":"b"}}"#)
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/ghost?operation=annotate", body: body) { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("an unknown operation is a 400")
    func unknownOperationIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=bogus") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("an image add can't resolve surfaces as 400, not a raw error")
    func addNotFoundImageIs400() async throws {
        let client = MockManifestClient(addHandler: { _, _ in
            throw ClientImageError.notFound(id: "does-not-exist:latest")
        })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?images=does-not-exist:latest") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("removing from a nonexistent manifest list is a 404")
    func removeFromNonexistentManifestIs404() async throws {
        let client = MockManifestClient(
            inspectHandler: { name in throw ClientManifestError.notFound(name: name) },
            removeDigestsHandler: { name, _ in
                throw ClientManifestError.notFound(name: name)
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/ghost?operation=remove&images=sha256:aaa") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    // MARK: - Helper

    private func withModifyApp(client: MockManifestClient, test: @escaping (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodManifestModifyRoute(client: client))
            try await test(app)
        }
    }
}
