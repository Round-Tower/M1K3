//
//  UserScriptRunnerTests.swift
//  M1K3AgentToolsTests
//
//  The live NSUserUnixTask adapter, exercised against a temp directory —
//  `swift test` runs unsandboxed, so NSUserUnixTask happily runs a chmod+x
//  fixture from /tmp here; in the app the directory is
//  ~/Library/Application Scripts/app.m1k3 (the sandbox-sanctioned folder).
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.85, Prior: Unknown

import CryptoKit
import Foundation
@testable import M1K3AgentTools
import Testing

struct UserScriptRunnerTests {
    private func makeScriptsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func write(_ name: String, _ content: String, in dir: URL, executable: Bool = true) throws {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    @Test("lists regular visible files with their content hashes")
    func listsInstalled() async throws {
        let dir = try makeScriptsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("hello.sh", "#!/bin/sh\necho hi\n", in: dir)
        try write(".hidden", "nope", in: dir)
        let runner = UserScriptRunner(directory: { dir })
        let scripts = await runner.installedScripts()
        #expect(scripts.map(\.name) == ["hello.sh"])
        // SHA-256 of the exact bytes — stable, so approval pinning works.
        #expect(scripts.first?.sha256.count == 64)
    }

    @Test("runs a script, capturing stdout and stderr")
    func runsAndCaptures() async throws {
        let dir = try makeScriptsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("hello.sh", "#!/bin/sh\necho out-line\necho err-line 1>&2\n", in: dir)
        let runner = UserScriptRunner(directory: { dir })
        let outcome = try await runner.run(named: "hello.sh", arguments: [], timeout: 10, expectedSHA256: sha("#!/bin/sh\necho out-line\necho err-line 1>&2\n"))
        #expect(outcome.succeeded)
        #expect(outcome.timedOut == false)
        #expect(outcome.output.contains("out-line"))
        #expect(outcome.output.contains("err-line"))
    }

    @Test("arguments reach the script")
    func passesArguments() async throws {
        let dir = try makeScriptsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("args.sh", "#!/bin/sh\necho \"got:$1:$2\"\n", in: dir)
        let runner = UserScriptRunner(directory: { dir })
        let outcome = try await runner.run(named: "args.sh", arguments: ["alpha", "beta"], timeout: 10, expectedSHA256: sha("#!/bin/sh\necho \"got:$1:$2\"\n"))
        #expect(outcome.output.contains("got:alpha:beta"))
    }

    @Test("a nonzero exit reports failure with a reason, not a throw")
    func nonzeroExit() async throws {
        let dir = try makeScriptsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("fail.sh", "#!/bin/sh\necho before-death\nexit 3\n", in: dir)
        let runner = UserScriptRunner(directory: { dir })
        let outcome = try await runner.run(named: "fail.sh", arguments: [], timeout: 10, expectedSHA256: sha("#!/bin/sh\necho before-death\nexit 3\n"))
        #expect(outcome.succeeded == false)
        #expect(outcome.failureReason?.isEmpty == false)
        #expect(outcome.output.contains("before-death"))
    }

    @Test("a script that outlives its timeout reports timedOut with partial output")
    func timesOut() async throws {
        let dir = try makeScriptsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("slow.sh", "#!/bin/sh\necho started\nsleep 30\necho finished\n", in: dir)
        let runner = UserScriptRunner(directory: { dir })
        let outcome = try await runner.run(named: "slow.sh", arguments: [], timeout: 1, expectedSHA256: sha("#!/bin/sh\necho started\nsleep 30\necho finished\n"))
        #expect(outcome.timedOut)
        #expect(outcome.succeeded == false)
        #expect(outcome.output.contains("started"))
        #expect(!outcome.output.contains("finished"))
    }

    @Test("a genuinely non-terminating script's wait is abandoned near the timeout", .timeLimit(.minutes(1)))
    func abandonsNonTerminatingScript() async throws {
        let dir = try makeScriptsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A script that will not exit within any test timescale (an hour) —
        // unlike `sleep 30`, which the abandon-elapsed assertion below couldn't
        // distinguish from "returned once the process ended" if the timeout
        // were near 30s (the review's F2 coverage gap). Deliberately a long
        // `sleep`, NOT a `while true` busy-loop: NSUserUnixTask children can't
        // be killed, so a spinner would peg a core for an hour and starve the
        // parallel suite (it flaked exactly this way once). A sleeping child
        // costs nothing and self-reaps. The .timeLimit trait is the outer
        // watchdog: a race regression that hangs fails fast instead of hanging CI.
        let body = "#!/bin/sh\nsleep 3600\n"
        try write("spin.sh", body, in: dir)
        let runner = UserScriptRunner(directory: { dir })
        let start = Date()
        let outcome = try await runner.run(
            named: "spin.sh", arguments: [], timeout: 1, expectedSHA256: sha(body)
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(outcome.timedOut)
        #expect(outcome.succeeded == false)
        // Returned near the 1s timeout, NOT after the child's 3600s exit.
        #expect(elapsed < 10)
    }

    @Test("a missing script throws launchFailed")
    func missingScript() async throws {
        let dir = try makeScriptsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = UserScriptRunner(directory: { dir })
        await #expect(throws: ScriptRunFailure.self) {
            _ = try await runner.run(named: "ghost.sh", arguments: [], timeout: 5, expectedSHA256: "deadbeef")
        }
    }

    @Test("bytes that drift from the approved hash are refused at the exec boundary")
    func refusesDriftAtExec() async throws {
        let dir = try makeScriptsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("drift.sh", "#!/bin/sh\necho now\n", in: dir)
        let runner = UserScriptRunner(directory: { dir })
        await #expect(throws: ScriptRunFailure.self) {
            _ = try await runner.run(named: "drift.sh", arguments: [], timeout: 5, expectedSHA256: "notthehash")
        }
    }

    @Test("a symlinked script is excluded from the listing and refused at run")
    func refusesSymlink() async throws {
        let dir = try makeScriptsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.sh")
        try "#!/bin/sh\necho hi\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let link = dir.appendingPathComponent("link.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let runner = UserScriptRunner(directory: { dir })
        let listed = await runner.installedScripts().map(\.name)
        #expect(listed.contains("real.sh"))
        #expect(!listed.contains("link.sh"))
        await #expect(throws: ScriptRunFailure.self) {
            _ = try await runner.run(named: "link.sh", arguments: [], timeout: 5, expectedSHA256: "x")
        }
    }

    @Test("traversal names never resolve outside the directory")
    func refusesTraversal() async throws {
        let dir = try makeScriptsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = UserScriptRunner(directory: { dir })
        for name in ["../sh", "/bin/sh", "a/../../b"] {
            await #expect(throws: ScriptRunFailure.self) {
                _ = try await runner.run(named: name, arguments: [], timeout: 5, expectedSHA256: "deadbeef")
            }
        }
    }
}
