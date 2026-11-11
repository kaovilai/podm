import Foundation
import Testing

@testable import podmd

/// The shared-journal isolation must configure exactly one directory even
/// when suite initializers enter `install()` concurrently — actor
/// reentrancy across the configure `await` would otherwise run the
/// configuration twice with different directories (the second clearing
/// writer epochs of followers another suite already armed).
@Suite("SharedJournalTestIsolation")
struct SharedJournalTestIsolationTests {

    /// Records every configure call; yields first so the racing callers
    /// all reach the suspension point before any append happens.
    private actor ConfigureRecorder {
        var directories: [URL] = []

        func record(_ directory: URL) async {
            await Task.yield()
            await Task.yield()
            directories.append(directory)
        }

        func snapshot() -> [URL] { directories }
    }

    @Test("concurrent installs await one cached task and configure exactly once")
    func concurrentInstallsConfigureOnce() async {
        let recorder = ConfigureRecorder()
        let isolation = SharedJournalTestIsolation { directory in
            await recorder.record(directory)
        }

        // Three concurrent installs — the same shape as three suites'
        // async initializers racing at process start.
        async let first = isolation.install()
        async let second = isolation.install()
        async let third = isolation.install()
        let urls = await [first, second, third]

        #expect(Set(urls).count == 1, "every caller must receive the same directory")
        let recorded = await recorder.snapshot()
        #expect(recorded.count == 1, "configure must run exactly once, ran \(recorded.count)")
        #expect(recorded.first == urls.first, "the configured directory must be the returned one")
    }

    @Test("a later install after completion returns the same directory")
    func laterInstallReusesDirectory() async {
        let recorder = ConfigureRecorder()
        let isolation = SharedJournalTestIsolation { directory in
            await recorder.record(directory)
        }

        let first = await isolation.install()
        let second = await isolation.install()

        #expect(first == second)
        let recorded = await recorder.snapshot()
        #expect(recorded.count == 1)
    }
}
