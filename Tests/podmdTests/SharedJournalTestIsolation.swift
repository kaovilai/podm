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
/// The install runs exactly once per process: the first caller's task is
/// cached BEFORE any suspension, and every concurrent caller awaits that
/// same task. Actor reentrancy would otherwise let two suite initializers
/// both observe `installTask == nil` across the `await`, each configuring a
/// different directory — and the second configuration clears the shared
/// journal's states and writer epochs, dropping entries from followers
/// another suite already armed.
actor SharedJournalTestIsolation {
    static let shared = SharedJournalTestIsolation(configure: { directory in
        await ContainerLogJournal.shared.configure(storageDirectory: directory)
    })

    private let configure: @Sendable (URL) async -> Void
    private var installTask: Task<URL, Never>?

    init(configure: @escaping @Sendable (URL) async -> Void) {
        self.configure = configure
    }

    @discardableResult
    func install() async -> URL {
        if let installTask { return await installTask.value }
        let task = Task { [configure] () -> URL in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("podm-journal-route-tests-\(UUID().uuidString)", isDirectory: true)
            await configure(dir)
            return dir
        }
        installTask = task
        return await task.value
    }
}
