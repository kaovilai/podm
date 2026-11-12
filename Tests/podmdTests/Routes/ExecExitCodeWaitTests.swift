import Foundation
import Testing

@testable import podmd

@Suite("ExecManager.waitForExitCode")
struct ExecExitCodeWaitTests {

    private func makeStartedExec() async -> String {
        let execId = await ExecManager.shared.create(
            config: ExecManager.ExecConfig(
                containerId: "devcontainer-lifecycle",
                cmd: ["sh", "-c", "exit 42"],
                attachStdin: false,
                attachStdout: true,
                attachStderr: true,
                tty: false,
                detach: false,
                env: [],
                user: nil,
                workingDir: nil
            )
        )
        _ = await ExecManager.shared.markStarted(id: execId)
        return execId
    }

    @Test("returns immediately when the exit code is already recorded")
    func alreadyRecorded() async {
        let execId = await makeStartedExec()
        await ExecManager.shared.setExitCode(id: execId, code: 42)

        let code = await ExecManager.shared.waitForExitCode(id: execId)

        #expect(code == 42)
        await ExecManager.shared.remove(id: execId)
    }

    @Test("blocks until a late exit code lands instead of returning nil at pipe EOF")
    func waitsForLateExitCode() async throws {
        let execId = await makeStartedExec()

        // async let, NOT a fire-and-forget Task: waitForExitCode polls in
        // a tight 25 ms loop, and on a saturated runner the parent keeps
        // waking while an UNSTRUCTURED setter task can be starved past
        // the 12 s deadline entirely (the same class the events-route
        // test documents). A structured child is scheduled as part of
        // this scope — the parent suspends into its first poll sleep and
        // the child gets the thread.
        async let setter: Void = {
            try? await Task.sleep(nanoseconds: 100_000_000)
            await ExecManager.shared.setExitCode(id: execId, code: 42)
        }()

        // A generous deadline: CI runners occasionally stall 10-20 s (the
        // documented runner-stall class — even structured children cannot
        // run while the machine is frozen), and this test's contract is
        // "waits until the code lands, never returns nil early" — not
        // "lands within 12 s". The production default stays 12 s.
        let code = await ExecManager.shared.waitForExitCode(id: execId, timeoutNanoseconds: 120_000_000_000)
        _ = await setter

        #expect(code == 42)
        await ExecManager.shared.remove(id: execId)
    }

    @Test("gives up after the timeout when no exit code is ever recorded")
    func timesOutWhenNeverRecorded() async {
        let execId = await makeStartedExec()

        let code = await ExecManager.shared.waitForExitCode(id: execId, timeoutNanoseconds: 100_000_000)

        #expect(code == nil)
        await ExecManager.shared.remove(id: execId)
    }
}
