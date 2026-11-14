import Foundation

/// Guards the process against an unparseable locale environment.
///
/// CoreFoundation builds a collator from `LANG`/`LC_ALL` the first time any
/// localized string comparison runs. A locale value that is not a locale at
/// all — a shell that accidentally printed a multi-line notice into `LANG`, for
/// example — makes ICU load a garbage locale and **SIGSEGV** inside
/// `icu::CollationRoot::load`, before the daemon logs a single line:
///
///     podmd(pid) EXC_BAD_ACCESS (SIGSEGV)
///     icu::CollationRoot::load → icu::Collator::makeInstance → __CFStringCreateCollator
///
/// The crash is in no way attributable to the user's actual problem, and a
/// daemon that dies silently is the worst possible diagnostic. Sanitizing the
/// variables at startup turns the silent crash into a normal run with one
/// stated warning.
enum LocaleGuard {
    /// Variables whose values CoreFoundation treats as locale identifiers.
    static let localeVariables = ["LANG", "LC_ALL", "LC_CTYPE", "LC_COLLATE"]

    /// Locale identifiers are built from letters, digits, `_`, `.`, `@` and
    /// `-` (`en_US.UTF-8`, `C`, `sr_RS.UTF-8@latin`). Anything else — spaces,
    /// newlines, ANSI escapes — cannot be a locale and crashes ICU's collation
    /// root. A real identifier is far shorter than this cap.
    static func isValidLocaleValue(_ value: String) -> Bool {
        guard value.count <= 64 else { return false }
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "_.@-".contains(character))
        }
    }

    /// The variables that need replacing, as (variable, offending value) pairs.
    /// Empty is a normal, clean environment.
    static func invalidVariables(in environment: [String: String]) -> [(name: String, value: String)] {
        localeVariables.compactMap { name in
            guard let value = environment[name], !value.isEmpty, !isValidLocaleValue(value) else { return nil }
            return (name, value)
        }
    }

    /// Replaces unparseable locale variables with `C.UTF-8` in the live process
    /// environment. Returns the variables it replaced so the caller can state
    /// what happened; the offending values are deliberately not echoed (they
    /// are arbitrary bytes from someone's shell, and may contain terminal
    /// escape sequences).
    /// - Parameters:
    ///   - environment: the environment to inspect (injectable for tests).
    ///   - apply: performs the replacement; the default writes to the live
    ///     process environment.
    @discardableResult
    static func sanitizeProcessLocale(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        apply: (String, String) -> Void = { setenv($0, $1, 1) },
        log: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) -> [String] {
        let invalid = invalidVariables(in: environment)
        guard !invalid.isEmpty else { return [] }
        for entry in invalid {
            apply(entry.name, "C.UTF-8")
        }
        let names = invalid.map(\.name).joined(separator: ", ")
        log(
            "warning: \(names) does not hold a locale identifier — falling back to C.UTF-8 "
                + "(an invalid locale crashes CoreFoundation's collation with a silent SIGSEGV).\n"
        )
        return invalid.map(\.name)
    }
}
