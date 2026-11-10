import Foundation

/// Parses the `since`/`until` query parameters of `GET /events` (and, later,
/// container logs) into an absolute timestamp.
///
/// Supported formats (the union of what moby's `api/types/time` and podman's
/// `pkg/timestamp` accept — the API receives *resolved* timestamps; relative
/// Go durations like `10m` are resolved by the CLI client, not the daemon):
///
/// - unix seconds: `1136073600`
/// - unix seconds with nanoseconds, `.` or `T` separator:
///   `1136073600.000000001`, `1136073600T000000001`
///   (a nanosecond portion longer than 9 digits is truncated, shorter is
///   scaled — moby's `parseTimestamp` does the same)
/// - RFC3339 with zone, with or without fractional seconds:
///   `2006-01-02T15:04:05Z`, `2006-01-02T15:04:05.999999999+01:00`
/// - date-only: `2006-01-02` (interpreted in the host's local time zone,
///   like moby's `dateLocal` format)
///
/// Deliberately Foundation-only so a future logs feature can share it.
enum DockerTimeParam {

    /// A parsed instant, in unix seconds + nanoseconds since the epoch.
    struct Timestamp: Equatable, Sendable {
        var seconds: Int64
        var nanoseconds: Int64

        init(seconds: Int64, nanoseconds: Int64 = 0) {
            self.seconds = seconds
            self.nanoseconds = nanoseconds
        }

        init(date: Date) {
            // Split whole seconds from the fraction BEFORE any integer
            // conversion: a single `interval × 1e9` TRAPS for dates beyond
            // ~year 2262 (Int64 nanosecond overflow — `until=9999-12-31`
            // parses fine and would crash the daemon) and loses precision
            // (a Double has ~256 ns resolution at current epoch values).
            // Whole seconds fit Int64 for any representable Date; the
            // fraction is 0..<1 s.
            let interval = date.timeIntervalSince1970
            let wholeSeconds = floor(interval)
            var fractionNanos = ((interval - wholeSeconds) * 1_000_000_000).rounded()
            if fractionNanos >= 1_000_000_000 {
                // A fraction rounding up to a full second carries.
                fractionNanos -= 1_000_000_000
                self.seconds = Int64(clamping: Int(exactly: wholeSeconds + 1) ?? .max)
            } else {
                self.seconds = Int64(clamping: Int(exactly: wholeSeconds) ?? (wholeSeconds > 0 ? .max : .min))
            }
            self.nanoseconds = Int64(clamping: Int(exactly: fractionNanos) ?? 0)
        }

        /// Total nanoseconds since the epoch, saturating instead of trapping
        /// on absurd inputs (the caller compares against event `timeNano`).
        var nanoSinceEpoch: Int64 {
            // |seconds| beyond ±9_223_372_036 seconds would overflow Int64
            // nanoseconds; clamp to the representable range.
            let clampedSeconds = min(max(seconds, -9_223_372_036), 9_223_372_036)
            let (result, overflow) = clampedSeconds.multipliedReportingOverflow(by: 1_000_000_000)
            if overflow { return clampedSeconds > 0 ? .max : .min }
            let (sum, sumOverflow) = result.addingReportingOverflow(nanoseconds)
            if sumOverflow { return clampedSeconds > 0 ? .max : .min }
            return sum
        }

        /// Event `timeNano` comparisons happen in UInt64; timestamps before
        /// 1970 clamp to 0.
        var unsignedNanoSinceEpoch: UInt64 {
            UInt64(max(nanoSinceEpoch, 0))
        }

        var unixNanoseconds: UInt64 {
            UInt64(max(nanoSinceEpoch, 0))
        }

        static func < (lhs: Timestamp, rhs: Timestamp) -> Bool {
            lhs.nanoSinceEpoch < rhs.nanoSinceEpoch
        }
    }

    enum ParseError: Error, CustomStringConvertible {
        case invalid(String)

        var description: String {
            switch self {
            case .invalid(let value):
                return "failed to parse value as time: \"\(value)\""
            }
        }
    }

    /// Parses an optional query value. `nil`/empty → `nil` (no bound);
    /// anything unparseable → `ParseError.invalid` (the route maps it to 400).
    /// Parses `value` to unix NANOSECONDS — the convenience entry point the
    /// logs window uses (`since`/`until` compare against journal nanos).
    /// Falls back to moby's `GetTimestamp` duration branch: a Go duration
    /// string ("10m") resolves relative to now; `"0"` is excluded there and
    /// parses as 0 (callers treat it per moby — until=0 ignored,
    /// since=0 filters nothing).
    static func unixNanoseconds(_ value: String?) throws -> UInt64? {
        guard let value, !value.isEmpty else { return nil }
        // The timestamp parser THROWS on unparseable values (routes map that
        // to 400) — here a throw just means "not a timestamp", and the Go
        // duration branch below gets its chance before we rethrow.
        if let stamp = (try? Self.parse(value as String?)) ?? nil {
            return stamp.unixNanoseconds
        }
        if value != "0", let interval = goDuration(value) {
            let now = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000_000))
            let delta = UInt64(min(interval, TimeInterval(now) / 1e9) * 1_000_000_000)
            return now - delta
        }
        throw ParseError.invalid(value)
    }

    /// Parses a Go duration (`"1h30m"`, `"500ms"`, `"1.5s"`) to seconds, or
    /// nil when the value is not a duration at all.
    private static func goDuration(_ value: String) -> TimeInterval? {
        let units: [(suffix: String, seconds: TimeInterval)] = [
            ("ns", 1e-9), ("us", 1e-6), ("µs", 1e-6), ("μs", 1e-6), ("ms", 1e-3),
            ("s", 1), ("m", 60), ("h", 3600),
        ]
        var remaining = Substring(value)
        var total = 0.0
        var matchedAny = false
        while !remaining.isEmpty {
            guard let unit = units.first(where: { remaining.hasSuffix($0.suffix) }) else { return nil }
            remaining = remaining.dropLast(unit.suffix.count)
            let numberPart = remaining.reversed().prefix { $0.isNumber || $0 == "." }
            guard !numberPart.isEmpty else { return nil }
            let number = String(numberPart.reversed())
            remaining = remaining.dropLast(number.count)
            guard let magnitude = Double(number), magnitude >= 0 else { return nil }
            total += magnitude * unit.seconds
            matchedAny = true
        }
        return matchedAny ? total : nil
    }

    static func parse(_ value: String?) throws -> Timestamp? {
        guard let value, !value.isEmpty else { return nil }
        return try parse(value)
    }

    /// Parses a non-empty timestamp string.
    static func parse(_ value: String) throws -> Timestamp {
        if let timestamp = parseUnix(value) { return timestamp }
        if let timestamp = parseDateTime(value) { return timestamp }
        throw ParseError.invalid(value)
    }

    // MARK: - Unix formats

    /// `1136073600`, `1136073600.000000001`, `1136073600T000000001`.
    /// Only consulted when the value is not a date-time (no `-` separator),
    /// so the `T` of RFC3339 never reaches here.
    private static func parseUnix(_ value: String) -> Timestamp? {
        let hasSeparator = value.contains(".") || value.contains("T")
        let parts: [Substring]
        if value.contains(".") {
            parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        } else if value.contains("T") {
            parts = value.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        } else {
            parts = [Substring(value)]
        }

        guard let seconds = Int64(parts[0]) else { return nil }
        guard hasSeparator else { return Timestamp(seconds: seconds) }

        guard parts.count == 2 else { return nil }
        let fraction = parts[1]
        guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber) else { return nil }

        // Moby: a nanosecond portion longer than 9 digits is truncated,
        // shorter is left-padded (i.e. interpreted at its own scale).
        return Timestamp(seconds: seconds, nanoseconds: scaledNanoseconds(fraction))
    }

    // MARK: - Date-time formats

    /// RFC3339 (with or without fractional seconds) and bare dates.
    ///
    /// A fractional-seconds suffix is split off BEFORE any formatter runs
    /// and parsed directly as integer nanoseconds: Foundation's `Date` is a
    /// Double and cannot represent sub-microsecond fractions, so routing
    /// the fraction through it would round `...05.000000001` to the whole
    /// second while the unix-string form preserves it — equivalent inputs
    /// must select the same boundary events.
    private static func parseDateTime(_ value: String) -> Timestamp? {
        // The "-" of a date is the discriminator: unix formats never contain one.
        guard value.contains("-") else { return nil }

        var body = Substring(value)
        var fractionDigits: Substring?
        if let dot = value.firstIndex(of: ".") {
            // The fraction runs to the zone marker (Z / ±hh:mm) or the end.
            let afterDot = value.index(after: dot)
            let zoneStart = value[afterDot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
            let digits = value[afterDot..<(zoneStart ?? value.endIndex)]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            fractionDigits = digits
            body = value[..<dot] + (zoneStart.map { value[$0...] } ?? "")
        }

        func withFraction(_ date: Date) -> Timestamp {
            var timestamp = Timestamp(date: date)
            if let fractionDigits {
                timestamp.nanoseconds = scaledNanoseconds(fractionDigits)
            }
            return timestamp
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: String(body)) { return withFraction(date) }

        // Zone-less timestamps are interpreted in the host's local zone,
        // matching moby's `ParseInLocation(..., reference.Zone())`.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = local.date(from: String(body)) { return withFraction(date) }
        // Date-only cannot carry a fraction ("2006-01-02.5" is not a form
        // moby accepts either).
        guard fractionDigits == nil else { return nil }
        local.dateFormat = "yyyy-MM-dd"
        if let date = local.date(from: String(body)) { return Timestamp(date: date) }
        return nil
    }

    /// Moby's `parseTimestamp` fraction rule: a portion longer than 9 digits
    /// is truncated, shorter is scaled (left-padded to its own precision).
    private static func scaledNanoseconds(_ digits: Substring) -> Int64 {
        let prefix = digits.prefix(9)
        var nanoseconds = Int64(prefix) ?? 0
        if prefix.count < 9 {
            for _ in prefix.count..<9 { nanoseconds *= 10 }
        }
        return nanoseconds
    }
}
