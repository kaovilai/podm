import Foundation
import Testing
import Vapor

@testable import podmd

@Suite("DockerEventFilterUtility — GET /events filters")
struct DockerEventFilterUtilityTests {

    private let logger = Logger(label: "test.events-filters")

    private func makeEvent(
        type: String = "container",
        action: String = "start",
        id: String = "abc123def456",
        name: String = "my-ctr",
        image: String = "busybox:latest",
        attributes: [String: String] = [:]
    ) -> DockerEvent {
        var attrs = attributes
        if !name.isEmpty { attrs["name"] = name }
        if !image.isEmpty { attrs["image"] = image }
        return DockerEvent(
            status: action, id: id, from: image, Type: type, Action: action,
            Actor: DockerActor(ID: id, Attributes: attrs),
            scope: "local", time: 0, timeNano: 0
        )
    }

    private func matcher(
        _ json: String, nameOverrides: [String: String] = [:]
    ) throws -> (DockerEvent) -> Bool {
        let filters = try DockerEventFilterUtility.parse(filtersParam: json, logger: logger)
        guard let m = DockerEventFilterUtility.makeMatcher(filters, nameOverrides: nameOverrides) else {
            struct NoFilter: Error {}
            throw NoFilter()
        }
        return m
    }

    // MARK: - Parse validation

    @Test("unknown filter key is a 400")
    func unknownKeyRejected() {
        #expect(throws: Abort.self) {
            _ = try DockerEventFilterUtility.parse(
                filtersParam: #"{"bogus":{"x":true}}"#, logger: logger)
        }
    }

    @Test("all docker CLI event filter keys are accepted")
    func allCliKeysAccepted() throws {
        let everyKey = """
            {"config":{},"container":{},"daemon":{},"event":{},"image":{},
             "label":{},"network":{},"node":{},"plugin":{},"scope":{},
             "secret":{},"service":{},"type":{},"volume":{}}
            """
        let filters = try DockerEventFilterUtility.parse(filtersParam: everyKey, logger: logger)
        #expect(filters.isEmpty, "empty value maps contribute no constraints")
    }

    @Test("array and bare-string filter values are accepted")
    func arrayAndStringValues() throws {
        let filters = try DockerEventFilterUtility.parse(
            filtersParam: #"{"type":["container","image"],"scope":"local"}"#, logger: logger)
        #expect(filters["type"] == ["container", "image"])
        #expect(filters["scope"] == ["local"])
    }

    @Test("empty filters produce no matcher (unfiltered fast path)")
    func emptyFiltersNoMatcher() throws {
        let filters = try DockerEventFilterUtility.parse(filtersParam: nil, logger: logger)
        #expect(DockerEventFilterUtility.makeMatcher(filters) == nil)
    }

    // MARK: - type / event / scope

    @Test("type, event and scope match exactly")
    func exactKeys() throws {
        let m = try matcher(#"{"type":"network","event":"create","scope":"local"}"#)
        #expect(m(makeEvent(type: "network", action: "create", name: "my-net", image: "")))
        #expect(!m(makeEvent(type: "container", action: "create")))
        #expect(!m(makeEvent(type: "network", action: "destroy", name: "my-net", image: "")))
    }

    // MARK: - container

    @Test("container filter matches by actor id, id prefix and name attribute")
    func containerMatching() throws {
        let m = try matcher(#"{"container":"abc123"}"#)
        #expect(m(makeEvent()), "id prefix")
        let byName = try matcher(#"{"container":"my-ctr"}"#)
        #expect(byName(makeEvent()))
        let byFullId = try matcher(#"{"container":"abc123def456"}"#)
        #expect(byFullId(makeEvent()))
        let miss = try matcher(#"{"container":"zzz"}"#)
        #expect(!miss(makeEvent()))
    }

    @Test("container filter resolves rename overrides: events recorded under the old id still match the new name")
    func containerRenameOverride() throws {
        // event recorded before any rename carries id + old name
        let event = makeEvent(id: "hex-1", name: "original")
        let m = try matcher(#"{"container":"renamed"}"#, nameOverrides: ["hex-1": "renamed"])
        #expect(m(event), "the override maps the filtered name back to the event's actor id")
        let withoutOverride = try matcher(#"{"container":"renamed"}"#)
        #expect(!withoutOverride(event))
    }

    // MARK: - image

    @Test("image filter matches actor id, image attribute and tag-stripped forms")
    func imageMatching() throws {
        // image events carry the reference in the name attribute
        let pull = makeEvent(
            type: "image", action: "pull", id: "sha256:abcd", name: "", image: "",
            attributes: ["name": "docker.io/library/busybox:latest"])

        let byId = try matcher(#"{"image":"sha256:abcd"}"#)
        #expect(byId(pull))

        let byFull = try matcher(#"{"image":"docker.io/library/busybox:latest"}"#)
        #expect(byFull(pull), "the raw filter matches the name attribute verbatim")

        // moby compares the filter value raw — only the event side is
        // tag-stripped/familiarized — so a tagged filter does not match a
        // fully-qualified event reference.
        let byTagged = try matcher(#"{"image":"busybox:latest"}"#)
        #expect(!byTagged(pull))

        let byStripped = try matcher(#"{"image":"busybox"}"#)
        #expect(byStripped(pull), "tag-stripped filter matches the familiarized reference")

        // container events: image attribute of the container's image
        let start = makeEvent(image: "alpine:3.19")
        let containerImage = try matcher(#"{"image":"alpine"}"#)
        #expect(containerImage(start), "container events match via their image attribute")
    }

    // MARK: - label

    @Test("label filter: bare key requires presence, key=value requires equality")
    func labelMatching() throws {
        let labeled = makeEvent(attributes: ["com.example.foo": "bar"])
        let present = try matcher(#"{"label":{"com.example.foo":true}}"#)
        #expect(present(labeled))
        let equal = try matcher(#"{"label":"com.example.foo=bar"}"#)
        #expect(equal(labeled))
        let unequal = try matcher(#"{"label":"com.example.foo=baz"}"#)
        #expect(!unequal(labeled))
        let missing = try matcher(#"{"label":"com.example.other"}"#)
        #expect(!missing(labeled))
    }

    // MARK: - network / volume

    @Test("network and volume filters match by actor id or name (podm emits these families)")
    func networkVolumeMatching() throws {
        let net = makeEvent(type: "network", action: "create", id: "net-abc123", name: "my-net", image: "")
        let byId = try matcher(#"{"network":"net-abc"}"#)
        #expect(byId(net))
        let byName = try matcher(#"{"network":"my-net"}"#)
        #expect(byName(net))
        let miss = try matcher(#"{"network":"other"}"#)
        #expect(!miss(net))

        let vol = makeEvent(type: "volume", action: "mount", id: "my-vol", name: "my-vol", image: "")
        let volMatch = try matcher(#"{"volume":"my-vol"}"#)
        #expect(volMatch(vol))
        let volMiss = try matcher(#"{"volume":"nope"}"#)
        #expect(!volMiss(vol))
    }

    // MARK: - Never-match families

    @Test("swarm and plugin filter families podm never emits match nothing")
    func neverMatchFamilies() throws {
        let event = makeEvent()
        for key in ["node", "service", "secret", "config", "plugin", "daemon"] {
            let m = try matcher(#"{"\#(key)":"anything"}"#)
            #expect(!m(event), "\(key) filter must never match a podm event")
        }
    }

    // MARK: - Combinatorics

    @Test("values within a key OR, keys AND")
    func andOrSemantics() throws {
        let start = makeEvent(action: "start")
        let die = makeEvent(action: "die")
        let orM = try matcher(#"{"event":["start","die"]}"#)
        #expect(orM(start) && orM(die))

        let andM = try matcher(#"{"type":"container","event":"start"}"#)
        #expect(andM(start))
        #expect(!andM(die))
    }
}
