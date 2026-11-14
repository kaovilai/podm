import Foundation
import Testing

@testable import podmd

/// An unparseable `LANG` (a shell that printed a multi-line notice into it, for
/// example) makes CoreFoundation load a garbage locale and SIGSEGV inside
/// ICU collation — the daemon died with exit 139 and no output at all.
@Suite("LocaleGuard — unparseable locale values")
struct LocaleGuardTests {

    @Test(
        "real locale identifiers are left alone",
        arguments: ["C", "C.UTF-8", "en_US.UTF-8", "de_DE.ISO-8859-1", "sr_RS.UTF-8@latin", "POSIX"]
    )
    func validLocalesUntouched(_ value: String) {
        #expect(LocaleGuard.isValidLocaleValue(value))
    }

    @Test(
        "values that cannot be a locale are rejected",
        arguments: [
            "dotfiles repo has uncommitted changes, run \u{1B}[0;31medit-dotfiles\u{1B}[0m to review\nC.UTF-8",
            "has space",
            "tab\there",
            "nul\u{0}byte",
            String(repeating: "a", count: 65),
        ]
    )
    func invalidLocalesRejected(_ value: String) {
        #expect(!LocaleGuard.isValidLocaleValue(value))
    }

    @Test("only the offending variables are reported")
    func reportsOnlyOffendingVariables() {
        let environment = [
            "LANG": "dotfiles repo has uncommitted changes\nC.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/bin",
        ]
        let invalid = LocaleGuard.invalidVariables(in: environment)
        #expect(invalid.map(\.name) == ["LANG"])
    }

    @Test("a clean environment reports nothing")
    func cleanEnvironmentUntouched() {
        #expect(LocaleGuard.invalidVariables(in: ["LANG": "C.UTF-8", "LC_ALL": "en_US.UTF-8"]).isEmpty)
        // An unset or empty variable is the platform default, not an error.
        #expect(LocaleGuard.invalidVariables(in: ["LANG": ""]).isEmpty)
        #expect(LocaleGuard.invalidVariables(in: [:]).isEmpty)
    }

    @Test("every locale variable is checked, not just LANG")
    func checksAllLocaleVariables() {
        let environment = ["LANG": "C", "LC_ALL": "bad\nvalue", "LC_CTYPE": "also bad\nvalue", "LC_COLLATE": "C"]
        #expect(LocaleGuard.invalidVariables(in: environment).map(\.name) == ["LC_ALL", "LC_CTYPE"])
    }
}
