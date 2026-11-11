import Foundation

@testable import podmd

/// Installs the process-wide test-owned directory for the SHARED journal
/// (`ContainerLogJournal.shared`) — the one the production routes use.
///
/// Any test suite that drives a lifecycle route (`/start`, `/restart`, the
/// attach bootstraps, delete/prune teardown) must install this in its
/// common setup (an async suite `init`): the shared journal's unconfigured
/// default is the DEVELOPER'S real journal directory, and those routes
/// reset and delete journal files. A `.serialized` trait on ONE suite does
/// not order the OTHER suites — each affected suite installs for itself,
/// before any of its route tests runs, so no suite running alone can touch
/// the real directory either.
///
/// The install is idempotent per directory: repeated installs never wipe
/// live state (an unconditional reconfigure would clear the writer epochs
/// of followers other suites armed and silently drop their appends).
actor SharedJournalTestIsolation {
    static let shared = SharedJournalTestIsolation()
    private var directory: URL?

    @discardableResult
    func install() async -> URL {
        if let directory { return directory }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podm-journal-route-tests-\(UUID().uuidString)", isDirectory: true)
        await ContainerLogJournal.shared.configure(storageDirectory: dir)
        directory = dir
        return dir
    }
}
