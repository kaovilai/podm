// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

enum Stderr {
    static func write(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

// Wait-status decoding. The WIFEXITED / WIFSIGNALED / WTERMSIG macros are
// function-like C macros and therefore unavailable in Swift; these implement
// the same bit tests Darwin's <sys/wait.h> defines (_WSTATUS = status & 0x7f,
// _WSTOPPED = 0x7f).

enum WaitStatus {
    static func exited(_ status: Int32) -> Bool {
        (status & 0x7f) == 0
    }

    static func exitCode(_ status: Int32) -> Int32 {
        (status >> 8) & 0xff
    }

    static func signaled(_ status: Int32) -> Bool {
        let termination = status & 0x7f
        return termination != 0x7f && termination != 0
    }

    static func signalNumber(_ status: Int32) -> Int32 {
        status & 0x7f
    }
}

enum ProcessSpawn {
    /// Spawn `executable` with inherited stdio, wait for it, and terminate this
    /// process with the child's status — re-raising fatal signals so $?, job
    /// control and shells observe the real outcome. Never returns.
    ///
    /// While waiting, terminal-generated signals (SIGINT, ...) are ignored in
    /// this shim and reset to their default disposition in the child via
    /// POSIX_SPAWN_SETSIGDEF. The child shares the shim's process group, so it
    /// still receives Ctrl-C / terminal signals directly and decides itself how
    /// to respond (interactive `docker run -it`, `podman attach`, ...); the shim
    /// survives only to propagate the exit status.
    static func execAndWait(executable: String, arguments: [String], environment: [String: String]) -> Never {
        let terminalSignals: [Int32] = [SIGINT, SIGQUIT, SIGTERM, SIGHUP]
        for signalNumber in terminalSignals {
            signal(signalNumber, SIG_IGN)
        }

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signalNumber in terminalSignals {
            sigaddset(&defaultSignals, signalNumber)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))

        var argv: [UnsafeMutablePointer<CChar>?] = []
        for argument in arguments {
            guard let copy = strdup(argument) else {
                Stderr.write("pacman: out of memory building argv\n")
                exit(71)
            }
            argv.append(copy)
        }
        argv.append(nil)
        var environmentPointers: [UnsafeMutablePointer<CChar>?] = []
        for pair in environment.map({ "\($0.key)=\($0.value)" }).sorted() {
            guard let copy = strdup(pair) else {
                Stderr.write("pacman: out of memory building environment\n")
                exit(71)
            }
            environmentPointers.append(copy)
        }
        environmentPointers.append(nil)
        defer {
            for pointer in argv where pointer != nil {
                free(pointer)
            }
            for pointer in environmentPointers where pointer != nil {
                free(pointer)
            }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, nil, &attributes, &argv, &environmentPointers)
        if attributes != nil {
            posix_spawnattr_destroy(&attributes)
        }
        if spawnResult != 0 {
            Stderr.write("pacman: failed to spawn \(executable): \(String(cString: strerror(spawnResult)))\n")
            exit(127)
        }

        var status: Int32 = 0
        while true {
            let waitResult = waitpid(pid, &status, 0)
            if waitResult == pid {
                break
            }
            if waitResult == -1 && errno == EINTR {
                continue
            }
            Stderr.write("pacman: waitpid failed: \(String(cString: strerror(errno)))\n")
            exit(1)
        }

        if WaitStatus.exited(status) {
            exit(WaitStatus.exitCode(status))
        }
        if WaitStatus.signaled(status) {
            let signalNumber = WaitStatus.signalNumber(status)
            signal(signalNumber, SIG_DFL)
            kill(getpid(), signalNumber)
            exit(128 &+ signalNumber)  // fallback in case the signal cannot be re-raised
        }
        exit(1)
    }

    /// Run a short-lived helper command. Output handling:
    ///   - captureOutput: both stdout and stderr are captured and returned.
    ///   - discardOutput: both streams are sent to /dev/null (quiet mode).
    ///   - neither: stdio is inherited (visible to the user).
    ///
    /// Captured output is read before waiting, which is fine for the small
    /// outputs used here (version strings, one-line summaries).
    static func run(
        _ executable: String,
        _ arguments: [String],
        captureOutput: Bool = false,
        discardOutput: Bool = false
    ) -> (exitStatus: Int32, output: String?) {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var outputPipe: Pipe? = nil
        if captureOutput {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            outputPipe = pipe
        } else if discardOutput {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
        } catch {
            return (127, nil)
        }
        var output: String? = nil
        if let pipe = outputPipe {
            output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        }
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
