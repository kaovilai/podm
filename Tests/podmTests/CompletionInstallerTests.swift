// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import podm

/// The zsh completion must ship in-repo and land where the user's zsh can
/// load it (issue #46).
@Suite("CompletionInstaller")
struct CompletionInstallerTests {

    private func tempDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podm-completion-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("installs into the user completions dir when it exists")
    func installsIntoUserDir() throws {
        let userDir = tempDir("user")
        let fallbackDir = tempDir("fallback")

        let outcome = try CompletionInstaller.installZsh(
            userCompletionsDir: userDir, fallbackDir: fallbackDir)

        #expect(outcome.destination == .userCompletions(userDir))
        #expect(outcome.updated)
        let installed = try String(contentsOf: userDir.appendingPathComponent("_podm"), encoding: .utf8)
        #expect(installed == CompletionScript.zsh)
        #expect(!FileManager.default.fileExists(atPath: fallbackDir.appendingPathComponent("_podm").path))
    }

    @Test("falls back to podm's own dir when the user dir does not exist")
    func fallsBackWhenNoUserDir() throws {
        let userDir = tempDir("user-absent")
        try FileManager.default.removeItem(at: userDir)
        let fallbackDir = tempDir("fallback")

        let outcome = try CompletionInstaller.installZsh(
            userCompletionsDir: userDir, fallbackDir: fallbackDir)

        #expect(outcome.destination == .podmFallback(fallbackDir))
        #expect(
            FileManager.default.fileExists(atPath: fallbackDir.appendingPathComponent("_podm").path))
    }

    @Test("a second install with identical content reports up-to-date")
    func idempotentInstall() throws {
        let userDir = tempDir("user")
        let fallbackDir = tempDir("fallback")

        _ = try CompletionInstaller.installZsh(userCompletionsDir: userDir, fallbackDir: fallbackDir)
        let second = try CompletionInstaller.installZsh(
            userCompletionsDir: userDir, fallbackDir: fallbackDir)

        #expect(!second.updated, "rewriting identical content must be reported as up to date")
    }

    @Test("an updated completion replaces the previous content")
    func replacesOutdatedContent() throws {
        let userDir = tempDir("user")
        let fallbackDir = tempDir("fallback")
        let target = userDir.appendingPathComponent("_podm")
        try "old completion".write(to: target, atomically: true, encoding: .utf8)

        let outcome = try CompletionInstaller.installZsh(
            userCompletionsDir: userDir, fallbackDir: fallbackDir)

        #expect(outcome.updated)
        #expect(try String(contentsOf: target, encoding: .utf8) == CompletionScript.zsh)
    }

    @Test("a symlink in the way is refused, not clobbered")
    func refusesSymlink() throws {
        let userDir = tempDir("user")
        let elsewhere = tempDir("elsewhere")
        let realFile = elsewhere.appendingPathComponent("precious")
        try "precious".write(to: realFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: userDir.appendingPathComponent("_podm").path,
            withDestinationPath: realFile.path)

        #expect(throws: (any Error).self) {
            try CompletionInstaller.installZsh(userCompletionsDir: userDir, fallbackDir: elsewhere)
        }
        #expect(
            FileSystem.isSymlink(userDir.appendingPathComponent("_podm").path),
            "the symlink must be untouched")
    }

    /// Review round 1: `fileExists` follows symlinks, so a DANGLING `_podm`
    /// link slipped past the old guard and the write replaced the link.
    @Test("a dangling symlink is refused too — fileExists would miss it")
    func refusesDanglingSymlink() throws {
        let userDir = tempDir("user")
        let fallbackDir = tempDir("fallback")
        // Points at a path that does not exist.
        try FileManager.default.createSymbolicLink(
            atPath: userDir.appendingPathComponent("_podm").path,
            withDestinationPath: userDir.appendingPathComponent("no-such-target").path)

        #expect(throws: (any Error).self) {
            try CompletionInstaller.installZsh(userCompletionsDir: userDir, fallbackDir: fallbackDir)
        }
        #expect(
            FileSystem.isSymlink(userDir.appendingPathComponent("_podm").path),
            "the dangling symlink must be untouched")
    }

    @Test("uninstall removes from both locations")
    func uninstallRemovesBoth() throws {
        let userDir = tempDir("user-absent")
        try FileManager.default.removeItem(at: userDir)
        let fallbackDir = tempDir("fallback")

        // No user dir yet: the install lands in the fallback.
        _ = try CompletionInstaller.installZsh(userCompletionsDir: userDir, fallbackDir: fallbackDir)
        // Later the user creates their own completions dir and re-runs
        // install: a copy lands there too.
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try CompletionScript.zsh.write(
            to: userDir.appendingPathComponent("_podm"), atomically: true, encoding: .utf8)

        let removed = CompletionInstaller.uninstallZsh(
            userCompletionsDir: userDir, fallbackDir: fallbackDir)

        #expect(removed.count == 2)
        for path in removed {
            #expect(!FileManager.default.fileExists(atPath: path.path))
        }
    }

    /// Review round 1: install refuses a symlinked `_podm`, so uninstall must
    /// not delete one either — that would remove the user's own completion
    /// setup, which podm never installed.
    @Test("uninstall skips a symlinked _podm it would have refused to install")
    func uninstallSkipsSymlink() throws {
        let userDir = tempDir("user")
        let fallbackDir = tempDir("fallback")
        let elsewhere = tempDir("elsewhere")
        let realFile = elsewhere.appendingPathComponent("users-own")
        try "user's own completion".write(to: realFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: userDir.appendingPathComponent("_podm").path,
            withDestinationPath: realFile.path)

        let removed = CompletionInstaller.uninstallZsh(
            userCompletionsDir: userDir, fallbackDir: fallbackDir)

        #expect(removed.isEmpty, "a symlink must not be removed")
        #expect(
            FileSystem.isSymlink(userDir.appendingPathComponent("_podm").path),
            "the user's symlink must survive")
        #expect(FileManager.default.fileExists(atPath: realFile.path), "the target must survive")
    }

    @Test("the completion delegates the mirrored surface to _podman and names podm's own commands")
    func scriptContent() {
        let script = CompletionScript.zsh
        // Own subcommands, with descriptions.
        for command in ["doctor", "install", "serve", "status", "uninstall"] {
            #expect(script.contains("'\(command):"), "missing own subcommand \(command)")
        }
        // Reuse of the upstream podman completion: the delegation guard.
        #expect(script.contains("$+functions[_podman]"))
        #expect(script.contains("words[1]=podman"))
        // Header so zsh autoloads it as a completion for the podm command.
        #expect(script.hasPrefix("#compdef podm"))
    }
}
