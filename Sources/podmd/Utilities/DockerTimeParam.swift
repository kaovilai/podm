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
            let nano = Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
            self.seconds = nano / 1_000_000_000
            self.nanoseconds = nano % 1_000_000_000
            if nanoseconds < 0 {
                self.seconds -= 1
                self.nanoseconds += 1_000_000_000
            }
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
        let digits = fraction.prefix(9)
        var nanoseconds = Int64(digits) ?? 0
        if digits.count < 9 {
            for _ in digits.count..<9 { nanoseconds *= 10 }
        }
        return Timestamp(seconds: seconds, nanoseconds: nanoseconds)
    }

    // MARK: - Date-time formats

    /// RFC3339 (with or without fractional seconds) and bare dates.
    private static func parseDateTime(_ value: String) -> Timestamp? {
        // The "-" of a date is the discriminator: unix formats never contain one.
        guard value.contains("-") else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return Timestamp(date: date) }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return Timestamp(date: date) }

        // Zone-less timestamps are interpreted in the host's local zone,
        // matching moby's `ParseInLocation(..., reference.Zone())`.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSS"
        if let date = local.date(from: value) { return Timestamp(date: date) }
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = local.date(from: value) { return Timestamp(date: date) }
        local.dateFormat = "yyyy-MM-dd"
        if let date = local.date(from: value) { return Timestamp(date: date) }
        return nil
    }
}
