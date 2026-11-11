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
        // Expected as explicit local components — NOT startOfDay of a UTC
        // instant: in zones at or beyond UTC+9 that instant already falls on
        // January 3 locally, and the parser correctly returns midnight of
        // the REQUESTED day.
        var components = DateComponents()
        components.year = 2006
        components.month = 1
        components.day = 2
        let expected = Calendar.current.date(from: components)!
        #expect(ts.seconds == Int64(expected.timeIntervalSince1970))
    }

    @Test("far-future date-times must not trap the Int64 nanosecond conversion")
    func farFutureDoesNotTrap() throws {
        // Year 9999 ≈ 2.5e11 s — nanoseconds overflow Int64 (year ~2262
        // limit); the parse must saturate at nanoSinceEpoch's clamp, not
        // crash the daemon.
        let saturatedRoute = 9_223_372_036_000_000_000
        let rfc3339 = try DockerTimeParam.parse("9999-12-31T23:59:59Z")
        #expect(rfc3339.seconds == 253_402_300_799)
        #expect(rfc3339.nanoSinceEpoch == saturatedRoute)
        let dateOnly = try DockerTimeParam.parse("9999-12-31")
        #expect(dateOnly.nanoSinceEpoch == saturatedRoute)
    }

    @Test("fractional RFC3339 nanoseconds survive parsing (Date is only a Double)")
    func fractionalRfc3339NanosPreserved() throws {
        // Foundation's Date cannot represent sub-microsecond fractions; the
        // fraction is parsed directly so equivalent forms select the same
        // boundary event. (1136214245 = 2006-01-02T15:04:05Z.)
        let rfc3339 = try DockerTimeParam.parse("2006-01-02T15:04:05.000000001Z")
        #expect(rfc3339.nanoseconds == 1)
        let unixForm = try DockerTimeParam.parse("1136214245.000000001")
        #expect(rfc3339 == unixForm)
        // Zone-less fractional, local interpretation, fraction preserved.
        let localFraction = try DockerTimeParam.parse("2006-01-02T15:04:05.123456789")
        #expect(localFraction.nanoseconds == 123_456_789)
        // A short fraction scales: .5 → 500 ms.
        let short = try DockerTimeParam.parse("2006-01-02T15:04:05.5Z")
        #expect(short.nanoseconds == 500_000_000)
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

    // Ported from the logs window's parser (now served by the same enum):
    // Go durations resolve relative to now, per moby's GetTimestamp.
    @Test("Go durations resolve relative to now")
    func durations() throws {
        let before = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let since = try DockerTimeParam.unixNanoseconds("42m")
        let after = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let fortyTwoMinutes: UInt64 = 42 * 60 * 1_000_000_000
        #expect(since != nil)
        if let since {
            // The exact bounds are [before - 42m, after - 42m]; the slack
            // covers only Double→UInt64 rounding, NOT wall-clock jitter
            // between the three now() reads (a loaded CI runner can exceed
            // the old 50 ms window and flake — one CI flake was reported).
            #expect(since + 10_000 >= before - fortyTwoMinutes)
            #expect(since <= after - fortyTwoMinutes + 10_000)
        }
        #expect(try DockerTimeParam.unixNanoseconds("1h30m") != nil)
        #expect(try DockerTimeParam.unixNanoseconds("500ms") != nil)
        // "0" is never a duration (moby excludes it explicitly).
        #expect(try DockerTimeParam.unixNanoseconds("0") == 0)

        // A duration longer than the time since the epoch clamps at ~0
        // (moby's since semantics) instead of trapping on UInt64 underflow —
        // the two separate ns conversions could round apart.
        let saturated = try DockerTimeParam.unixNanoseconds("999999h")
        #expect(saturated != nil)
        if let saturated {
            #expect(saturated < 1_000_000, "a past-the-epoch duration clamps at ~0, not a trap")
        }
    }

    @Test("unparseable and negative durations throw, like moby's GetTimestamp")
    func invalidDurations() {
        #expect(throws: DockerTimeParam.ParseError.self) {
            _ = try DockerTimeParam.unixNanoseconds("not-a-time")
        }
        #expect(throws: DockerTimeParam.ParseError.self) {
            _ = try DockerTimeParam.unixNanoseconds("-42m")
        }
    }

}
