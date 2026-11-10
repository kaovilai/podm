import Foundation
import Testing

@testable import podmd

@Suite("DockerTimeParam — since/until timestamp parsing")
struct DockerTimeParamTests {

    // MARK: - Absent / empty

    @Test("nil and empty values mean no bound")
    func absentValues() throws {
        #expect(try DockerTimeParam.parse(nil as String?) == nil)
        #expect(try DockerTimeParam.parse("" as String?) == nil)
    }

    // MARK: - Unix formats

    @Test("unix seconds")
    func unixSeconds() throws {
        let ts = try DockerTimeParam.parse("1136073600")
        #expect(ts == DockerTimeParam.Timestamp(seconds: 1_136_073_600))
        #expect(ts.nanoSinceEpoch == 1_136_073_600_000_000_000)
    }

    @Test("unix seconds with dot-separated nanoseconds")
    func unixDotNano() throws {
        let ts = try DockerTimeParam.parse("1136073600.000000001")
        #expect(ts.seconds == 1_136_073_600)
        #expect(ts.nanoseconds == 1)
    }

    @Test("unix seconds with T-separated nanoseconds (podman format)")
    func unixTNano() throws {
        let ts = try DockerTimeParam.parse("1136073600T000000001")
        #expect(ts.seconds == 1_136_073_600)
        #expect(ts.nanoseconds == 1)
        // T and dot forms of the same instant agree
        let dot = try DockerTimeParam.parse("1136073600.000000001")
        #expect(ts == dot)
    }

    @Test("nanosecond portion shorter than 9 digits is scaled, longer is truncated")
    func nanoScaling() throws {
        // ".5" is half a second, like moby's parseTimestamp
        #expect(try DockerTimeParam.parse("1136073600.5").nanoseconds == 500_000_000)
        #expect(try DockerTimeParam.parse("1136073600T5").nanoseconds == 500_000_000)
        #expect(try DockerTimeParam.parse("1136073600.000000001234").nanoseconds == 1)
    }

    @Test("negative unix seconds (pre-epoch) parse")
    func negativeUnix() throws {
        let ts = try DockerTimeParam.parse("-100")
        #expect(ts.seconds == -100)
        #expect(ts.unsignedNanoSinceEpoch == 0, "pre-epoch timestamps clamp to 0 for timeNano comparison")
    }

    // MARK: - Date-time formats

    @Test("RFC3339 with zone")
    func rfc3339() throws {
        // Go's reference time: 2006-01-02T15:04:05Z
        let ts = try DockerTimeParam.parse("2006-01-02T15:04:05Z")
        #expect(ts.seconds == 1_136_214_245)
        #expect(ts.nanoseconds == 0)
    }

    @Test("RFC3339 with fractional seconds and numeric offset")
    func rfc3339NanoOffset() throws {
        let ts = try DockerTimeParam.parse("2006-01-02T15:04:05.5+01:00")
        // 15:04:05.5 UTC+1 == 14:04:05.5Z == 1136210645.5e9
        #expect(ts.seconds == 1_136_210_645)
        #expect(ts.nanoseconds == 500_000_000)
    }

    @Test("date-only string parses as midnight local time")
    func dateOnly() throws {
        let ts = try DockerTimeParam.parse("2006-01-02")
        // local midnight of 2006-01-02 expressed as unix seconds
        let expected = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_136_214_245))
        #expect(ts.seconds == Int64(expected.timeIntervalSince1970))
    }

    // MARK: - Errors

    @Test("unparseable values throw")
    func invalidValues() {
        #expect(throws: DockerTimeParam.ParseError.self) {
            _ = try DockerTimeParam.parse("not-a-time")
        }
        #expect(throws: DockerTimeParam.ParseError.self) {
            _ = try DockerTimeParam.parse("1234567890.abc")
        }
        #expect(throws: DockerTimeParam.ParseError.self) {
            _ = try DockerTimeParam.parse("2006-13-45T99:99:99Z")
        }
    }

    // MARK: - Ordering

    @Test("timestamps order by instant, not string")
    func ordering() throws {
        let a = try DockerTimeParam.parse("1136073600.9")
        let b = try DockerTimeParam.parse("1136073601")
        #expect(a < b)
        #expect(!(b < a))
    }
}
