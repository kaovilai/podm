import Foundation
import Testing

@testable import podmd

/// The two build clients read the completion stream differently, in both
/// directions: docker's classic builder takes `--iidfile` only from the `aux`
/// record, while podman's client fails the whole build on any record with
/// neither `stream` nor `error`. Sending the aux record to podman broke every
/// successful `podman build` (exit 125 after "Unpacking image layers").
@Suite("BuildRoute — completion records per dialect")
struct BuildCompletionRecordsTests {

    private let id = "2533e1d34f34fa226443b5f2cde142f4c614c7ddb5a8be35a0490da758237343"

    private func records(
        quiet: Bool = false,
        sendsAuxRecord: Bool,
        tags: [String] = ["ok:test"]
    ) -> [[String: Any]] {
        BuildRoute.completionRecords(
            recordedImageID: "sha256:" + id,
            imageName: "ok:test",
            tags: tags,
            quiet: quiet,
            sendsAuxRecord: sendsAuxRecord
        ).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    @Test("the docker dialect carries the aux record and the bare-ID stream line")
    func dockerRecords() {
        let parsed = records(sendsAuxRecord: true)
        #expect(parsed.contains { $0["aux"] != nil })
        #expect(parsed.contains { ($0["stream"] as? String)?.hasPrefix(id) == true })
    }

    @Test("the libpod dialect NEVER sends an aux record — podman fails the build on it")
    func libpodOmitsAux() {
        let parsed = records(sendsAuxRecord: false)
        #expect(!parsed.contains { $0["aux"] != nil })
        // ...but the bare-ID stream line must still be there, or podman reports
        // "decoding stream: EOF" for a successful build.
        #expect(parsed.contains { ($0["stream"] as? String)?.hasPrefix(id) == true })
        // Every record must have `stream` or `error` for podman's decoder.
        #expect(parsed.allSatisfy { $0["stream"] != nil || $0["error"] != nil })
    }

    @Test("quiet mode keeps the bare-ID line for both dialects and the aux record for docker")
    func quietRecords() {
        let docker = records(quiet: true, sendsAuxRecord: true)
        #expect(docker.contains { $0["aux"] != nil })
        #expect(docker.contains { ($0["stream"] as? String)?.hasPrefix(id) == true })
        // No progress chatter in quiet mode.
        #expect(!docker.contains { ($0["stream"] as? String)?.contains("Successfully built") == true })

        let podman = records(quiet: true, sendsAuxRecord: false)
        #expect(!podman.contains { $0["aux"] != nil })
        #expect(podman.count == 1, "quiet libpod output is exactly the image ID")
        #expect((podman.first?["stream"] as? String)?.hasPrefix(id) == true)
    }

    @Test("a normal build reports one success line per requested tag")
    func successLinesPerTag() {
        let parsed = records(sendsAuxRecord: false, tags: ["ok:test", "ok:alias"])
        let streams = parsed.compactMap { $0["stream"] as? String }
        #expect(streams.contains("Successfully built ok:test\n"))
        #expect(streams.contains("Successfully tagged ok:test\n"))
        #expect(streams.contains("Successfully tagged ok:alias\n"))
    }
}
