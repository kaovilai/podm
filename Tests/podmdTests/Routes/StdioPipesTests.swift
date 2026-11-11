import Foundation
import Testing

@testable import podmd

// All fd-ownership tests share a single parent suite that is .serialized.
// Each child suite's tests run sequentially within the parent. That alone
// does NOT make the closure assertions below safe: Swift Testing still runs
// OTHER suites concurrently, and POSIX allocates the lowest free fd NUMBER —
// between a close() under test and the fcntl that verifies it, another
// suite's open()/pipe()/socket() can claim the just-freed number, making
// `fcntl(fd, F_GETFD) == -1` false-fail. Every closure assertion therefore
// uses markFd() + assertClosed() (see below), which tags the fd with
// FD_CLOEXEC so a recycled number is distinguishable from a real leak.
@Suite("Pipe fd ownership", .serialized)
struct PipeFdOwnershipTests {

    // MARK: - StdioPipes

    /// Tests for `StdioPipes` — the high-level stdio pipe manager.
    ///
    /// `StdioPipes` centralises allocation, EMFILE validation, and cleanup for all
    /// three stdio channels passed to `createProcess(stdio:)` / `bootstrap(id:stdio:)`.
    @Suite("StdioPipes — allocation and cleanup")
    struct StdioPipesTests {

        @Test("make() returns valid fds for all requested streams")
        func makeReturnsValidFds() {
            guard let pipes = StdioPipes.make(.all) else {
                Issue.record("StdioPipes.make() returned nil")
                return
            }
            for fd in [
                pipes.stdin?.read.fileDescriptor, pipes.stdin?.write.fileDescriptor,
                pipes.stdout?.read.fileDescriptor, pipes.stdout?.write.fileDescriptor,
                pipes.stderr?.read.fileDescriptor, pipes.stderr?.write.fileDescriptor,
            ].compactMap({ $0 }) {
                #expect(Darwin.fcntl(fd, F_GETFD) >= 0, "fd \(fd) not valid")
            }
            pipes.closeAll()
        }

        @Test("make() returns nil for streams not requested")
        func makeReturnsNilForUnrequestedStreams() {
            guard let pipes = StdioPipes.make([.stdout]) else {
                Issue.record("StdioPipes.make() returned nil")
                return
            }
            #expect(pipes.stdin == nil)
            #expect(pipes.stdout != nil)
            #expect(pipes.stderr == nil)
            pipes.closeAll()
        }

        @Test("stdioArray ordering: stdin.read, stdout.write, stderr.write")
        func stdioArrayHasCorrectOrdering() {
            guard let pipes = StdioPipes.make(.all) else {
                Issue.record("StdioPipes.make() returned nil")
                return
            }
            let array = pipes.stdioArray
            #expect(array.count == 3)
            #expect(array[0] === pipes.stdin?.read)
            #expect(array[1] === pipes.stdout?.write)
            #expect(array[2] === pipes.stderr?.write)
            pipes.closeAll()
        }

        @Test("closeAll() closes all six fds")
        func closeAllClosesSixFds() {
            var fds: [Int32] = []
            do {
                guard let pipes = StdioPipes.make(.all) else {
                    Issue.record("StdioPipes.make() returned nil")
                    return
                }
                fds = [
                    pipes.stdin!.read.fileDescriptor, pipes.stdin!.write.fileDescriptor,
                    pipes.stdout!.read.fileDescriptor, pipes.stdout!.write.fileDescriptor,
                    pipes.stderr!.read.fileDescriptor, pipes.stderr!.write.fileDescriptor,
                ].map(markFd)
                pipes.closeAll()
                // pipes released here — closeOnDealloc:false means deinit won't re-close
            }
            for fd in fds {
                assertClosed(fd, "fd \(fd) should be closed after closeAll()")
            }
        }

        /// Verifies the post-handoff ownership split:
        /// - closeAfterHandoff() closes: stdin.write, stdout.read, stderr.read (caller-owned)
        /// - closeAfterHandoff() leaves open: stdin.read, stdout.write, stderr.write (Apple-owned)
        @Test("closeAfterHandoff() closes only caller-owned fds, leaves Apple-owned fds open")
        func closeAfterHandoffClosesOnlyCallerOwnedFds() {
            var stdinRead: Int32 = -1
            var stdinWrite: Int32 = -1
            var stdoutRead: Int32 = -1
            var stdoutWrite: Int32 = -1
            var stderrRead: Int32 = -1
            var stderrWrite: Int32 = -1

            do {
                guard let pipes = StdioPipes.make(.all) else {
                    Issue.record("StdioPipes.make() returned nil")
                    return
                }
                stdinRead = pipes.stdin!.read.fileDescriptor
                stdinWrite = markFd(pipes.stdin!.write.fileDescriptor)
                stdoutRead = markFd(pipes.stdout!.read.fileDescriptor)
                stdoutWrite = pipes.stdout!.write.fileDescriptor
                stderrRead = markFd(pipes.stderr!.read.fileDescriptor)
                stderrWrite = pipes.stderr!.write.fileDescriptor
                pipes.closeAfterHandoff()
            }

            // Caller-owned ends are closed
            assertClosed(stdinWrite, "stdin.write (caller-owned) must be closed")
            assertClosed(stdoutRead, "stdout.read (caller-owned) must be closed")
            assertClosed(stderrRead, "stderr.read (caller-owned) must be closed")

            // Apple-owned ends remain open (closeAfterHandoff must not touch them)
            #expect(Darwin.fcntl(stdinRead, F_GETFD) >= 0, "stdin.read (Apple-owned) must stay open")
            #expect(Darwin.fcntl(stdoutWrite, F_GETFD) >= 0, "stdout.write (Apple-owned) must stay open")
            #expect(Darwin.fcntl(stderrWrite, F_GETFD) >= 0, "stderr.write (Apple-owned) must stay open")

            Darwin.close(stdinRead)
            Darwin.close(stdoutWrite)
            Darwin.close(stderrWrite)
        }
    }

    @Test("make() closes partially-allocated fds when a later pipe allocation fails")
    func makeCleansUpPartialAllocationOnFailure() {
        // Capture fds from the first successful allocation so we can verify
        // the guard-else block closes them when the second allocation fails.
        var capturedRead: Int32 = -1
        var capturedWrite: Int32 = -1
        var callCount = 0

        let result = StdioPipes.make([.stdin, .stdout]) { () -> ProcessPipe? in
            callCount += 1
            guard let pipe = ProcessPipe.make() else { return nil }
            if callCount == 1 {
                capturedRead = markFd(pipe.read.fileDescriptor)
                capturedWrite = markFd(pipe.write.fileDescriptor)
                return pipe  // first allocation succeeds
            }
            // Simulate EMFILE on the second allocation; close the real pipe we made.
            try? pipe.read.close()
            try? pipe.write.close()
            return nil
        }

        #expect(result == nil, "make() must return nil when any required pipe fails")
        #expect(callCount == 2, "factory called twice: once for stdin (ok), once for stdout (fail)")
        // The guard-else block must have closed the first pipe's fds.
        // assertClosed (not a bare fcntl == -1): under parallel-suite load a
        // concurrent test can recycle the freed fd NUMBER before this runs.
        assertClosed(capturedRead, "first pipe read fd must be closed by guard-else")
        assertClosed(capturedWrite, "first pipe write fd must be closed by guard-else")
    }

    // MARK: - collectOutput

    @Suite("StdioPipes.collectOutput — concurrent drain while waiting")
    struct CollectOutputTests {

        @Test("success path: collects stdout and stderr, returns exit code")
        func collectsOutputOnSuccess() async throws {
            guard let pipes = StdioPipes.make([.stdout, .stderr]) else {
                Issue.record("StdioPipes.make() returned nil")
                return
            }

            // Write test data to write ends (simulating container output), then close
            // so readers see EOF immediately when collectOutput starts draining.
            let stdoutPayload = "hello stdout".data(using: .utf8)!
            let stderrPayload = "hello stderr".data(using: .utf8)!
            try pipes.stdout!.write.write(contentsOf: stdoutPayload)
            try pipes.stderr!.write.write(contentsOf: stderrPayload)
            try? pipes.stdout!.write.close()
            try? pipes.stderr!.write.close()

            let (exitCode, stdout, stderr) = try await pipes.collectOutput { 0 }

            #expect(exitCode == 0)
            #expect(stdout == stdoutPayload)
            #expect(stderr == stderrPayload)
        }

        @Test("error path: wait error is rethrown; drain tasks exit when write ends close")
        func rethrowsWaitError() async throws {
            guard let pipes = StdioPipes.make([.stdout, .stderr]) else {
                Issue.record("StdioPipes.make() returned nil")
                return
            }

            struct FakeWaitError: Error {}
            do {
                _ = try await pipes.collectOutput { throw FakeWaitError() }
                Issue.record("Expected collectOutput to rethrow FakeWaitError")
            } catch is FakeWaitError {
                // Expected: collectOutput rethrows immediately without awaiting drain tasks.
                // Drain tasks will exit once write ends are closed (EOF).
            }
            // Close write ends to unblock background drain tasks (no concurrent fd close hazard
            // because we're not inside collectOutput anymore).
            try? pipes.stdout!.write.close()
            try? pipes.stderr!.write.close()
        }
    }

    // MARK: - ProcessPipe

    /// Tests for `ProcessPipe`, the internal low-level primitive backing `StdioPipes`.
    ///
    /// Root cause of issue #107: `createProcess(stdio:)/bootstrap(id:stdio:)` dups
    /// the passed fds into the container then closes the parent copies. When code
    /// used Foundation's `Pipe()`, the freed fd could be reused (e.g. as a NIO
    /// socket) before `Pipe.deinit` ran its own close, double-closing the reused
    /// fd and corrupting NIO's fd table (writev/kevent EBADF crash).
    ///
    /// Fix: `ProcessPipe` uses `pipe(2)` + `FileHandle(closeOnDealloc:false)` so
    /// Apple is the sole closer of the end passed to createProcess/bootstrap.
    @Suite("ProcessPipe — fd ownership contract")
    struct ProcessPipeTests {

        // MARK: - ProcessPipe API

        @Test("ProcessPipe.make() returns two distinct, valid fds")
        func makePipeReturnsValidFds() {
            guard let pipe = ProcessPipe.make() else {
                Issue.record("ProcessPipe.make() returned nil")
                return
            }
            let r = pipe.read.fileDescriptor
            let w = pipe.write.fileDescriptor
            #expect(r >= 0)
            #expect(w >= 0)
            #expect(r != w)
            #expect(Darwin.fcntl(r, F_GETFD) >= 0, "read fd not valid")
            #expect(Darwin.fcntl(w, F_GETFD) >= 0, "write fd not valid")
            Darwin.close(r)
            Darwin.close(w)
        }

        /// Core invariant: `ProcessPipe` deinit does not call `close()` on either fd.
        /// Without this guarantee, an fd freed by Apple and recycled by NIO as a socket
        /// could be closed by the deinit, corrupting NIO's fd table (writev EBADF crash).
        @Test("ProcessPipe deinit does not close fds (closeOnDealloc:false)")
        func deinitDoesNotCloseFds() {
            var readFd: Int32 = -1
            var writeFd: Int32 = -1

            // Inner scope forces deinit before the #expect calls below.
            do {
                guard let pipe = ProcessPipe.make() else {
                    Issue.record("ProcessPipe.make() returned nil")
                    return
                }
                readFd = pipe.read.fileDescriptor
                writeFd = pipe.write.fileDescriptor
                // pipe released here — deinit fires immediately (ARC is synchronous)
            }

            // Both fds must still be open — deinit must not have touched them.
            #expect(Darwin.fcntl(readFd, F_GETFD) >= 0, "read fd closed by ProcessPipe deinit")
            #expect(Darwin.fcntl(writeFd, F_GETFD) >= 0, "write fd closed by ProcessPipe deinit")

            Darwin.close(readFd)
            Darwin.close(writeFd)
        }

        // MARK: - Low-level primitives (regression tests for the building blocks)

        @Test("closeOnDealloc:false — fd stays valid after FileHandle is released")
        func fdStaysOpenAfterFileHandleReleased() throws {
            var fds: [Int32] = [0, 0]
            try #require(Darwin.pipe(&fds) == 0)
            let readFd = fds[0]
            let writeFd = fds[1]

            do {
                _ = FileHandle(fileDescriptor: readFd, closeOnDealloc: false)
                _ = FileHandle(fileDescriptor: writeFd, closeOnDealloc: false)
            }
            #expect(Darwin.fcntl(readFd, F_GETFD) >= 0, "read fd closed prematurely")
            #expect(Darwin.fcntl(writeFd, F_GETFD) >= 0, "write fd closed prematurely")

            Darwin.close(readFd)
            Darwin.close(writeFd)
        }

        @Test("write-end external close leaves read end usable")
        func writeEndExternalCloseDoesNotInvalidateReadEnd() throws {
            var fds: [Int32] = [0, 0]
            try #require(Darwin.pipe(&fds) == 0)
            let readFd = fds[0]
            let writeFd = fds[1]

            let byte: [UInt8] = [0x42]
            _ = Darwin.write(writeFd, byte, 1)
            Darwin.close(markFd(writeFd))
            assertClosed(writeFd, "write fd should be closed")

            let readHandle = FileHandle(fileDescriptor: readFd, closeOnDealloc: false)
            let data = try readHandle.readToEnd()
            #expect(data?.count == 1)
            #expect(data?.first == 0x42)

            try readHandle.close()
        }
    }

}  // end PipeFdOwnershipTests

// MARK: - Recycle-tolerant fd-closure assertions

/// Tags `fd` with FD_CLOEXEC so `assertClosed` can tell "our fd, never
/// closed" apart from "number recycled by a concurrent test". FD_CLOEXEC is
/// the marker of choice because the fds under test come from plain
/// `pipe(2)` (fd flags 0): a fresh fd opened elsewhere in the process does
/// not carry it.
@discardableResult
private func markFd(_ fd: Int32) -> Int32 {
    _ = Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC)
    return fd
}

/// fd-closure assertion that tolerates fd-NUMBER recycling under parallel
/// test load.
///
/// Mechanism: POSIX hands out the LOWEST free fd number, and Swift Testing
/// runs other suites concurrently with this one — between the close() under
/// test and this fcntl, another suite's open()/pipe()/socket() can claim the
/// just-freed NUMBER, so a bare `fcntl(fd, F_GETFD) == -1` false-fails even
/// though the close happened (the CI flake; the parent suite's .serialized
/// cannot prevent it, since the recycler lives in a DIFFERENT suite). The
/// FD_CLOEXEC marker set by `markFd` before the close disambiguates:
///
///   - closed, not recycled → fcntl == -1 → pass
///   - closed, recycled → fresh fd without the marker → pass
///   - NOT closed (real bug) → marker still set → fail
///
/// Only a recycler that itself sets FD_CLOEXEC on its fresh fd could still
/// false-fail; nothing else in this test target does.
private func assertClosed(_ fd: Int32, _ message: @autoclosure () -> String = "") {
    let flags = Darwin.fcntl(fd, F_GETFD)
    #expect(
        flags == -1 || (flags & FD_CLOEXEC) == 0,
        "\(message()) fd \(fd) must be closed — fcntl flags \(flags): nonnegative WITH FD_CLOEXEC means the fd was never closed; nonnegative WITHOUT it means the number was recycled by a concurrent test"
    )
}
