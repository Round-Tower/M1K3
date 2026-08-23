//
//  UserScriptRunner.swift
//  M1K3AgentTools
//
//  The live ScriptRunning adapter: NSUserUnixTask over the app's Application
//  Scripts folder (~/Library/Application Scripts/app.m1k3) — the sandbox's
//  sanctioned door for running user-installed scripts. Foundation-only, so it
//  lives beside the tool and stays package-testable (swift test is
//  unsandboxed, so tests point `directory` at a temp folder).
//
//  Honest limits, by API contract:
//  - NSUserUnixTask reports completed-or-error, never an exit code — failure
//    carries the error's description, and `succeeded` is that boolean.
//  - A launched task CANNOT be terminated. Timeout here abandons the wait and
//    reports `timedOut: true` with whatever output arrived; the script may
//    still be running, and callers must say so.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.8, Prior: Unknown

import CryptoKit
import Foundation

public final class UserScriptRunner: ScriptRunning, @unchecked Sendable {
    /// Bytes of combined stdout+stderr kept (tail). A chatty script can emit
    /// unbounded output; the collector keeps the end, where verdicts live.
    static let outputByteLimit = 64 * 1024

    private let directory: @Sendable () throws -> URL

    /// `directory` defaults to the app's Application Scripts folder; tests
    /// inject a temp dir. The folder is created if absent so a fresh install
    /// has somewhere to reveal in Finder.
    public init(
        directory: @escaping @Sendable () throws -> URL = {
            try FileManager.default.url(
                for: .applicationScriptsDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
        }
    ) {
        self.directory = directory
    }

    public func installedScripts() async -> [InstalledScript] {
        guard let dir = try? directory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }
        return entries
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                // Reject symlinks outright: an approved-by-name symlink could
                // point anywhere the co-resident attacker can write, dodging
                // the folder's scrutiny. No legitimate use here.
                return values?.isRegularFile == true && values?.isSymbolicLink != true
            }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return InstalledScript(name: url.lastPathComponent, sha256: Self.hexDigest(data))
            }
            .sorted { $0.name < $1.name }
    }

    public func run(
        named name: String, arguments: [String], timeout: TimeInterval, expectedSHA256: String
    ) async throws -> ScriptRunOutcome {
        // Defense in depth: the tool validates too, but the runner must not
        // trust its caller — a name is a file INSIDE the folder, full stop.
        guard ExecuteScriptTool.isValidScriptName(name) else {
            throw ScriptRunFailure.launchFailed("\"\(name)\" is not a plain script file name")
        }
        let dir = try mapLaunchFailure { try directory() }
        let url = dir.appendingPathComponent(name)
        guard url.standardizedFileURL.deletingLastPathComponent().path == dir.standardizedFileURL.path else {
            throw ScriptRunFailure.launchFailed("\"\(name)\" resolves outside the scripts folder")
        }
        // TOCTOU close (Finding 2): re-read the bytes NOW and re-verify the
        // approved hash immediately before launch, refusing an inode swap or a
        // symlinked target that slipped in after the tool's snapshot. There is
        // still an irreducible micro-window — NSUserUnixTask(url:) re-opens the
        // path itself — but the check moves from a stale snapshot to the exec
        // boundary. A symlink at the path is refused before it can resolve out.
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else {
            throw ScriptRunFailure.launchFailed("\"\(name)\" is a symbolic link — refused")
        }
        guard let currentBytes = try? Data(contentsOf: url) else {
            throw ScriptRunFailure.launchFailed("\"\(name)\" could not be read")
        }
        guard Self.hexDigest(currentBytes) == expectedSHA256 else {
            throw ScriptRunFailure.launchFailed(
                "\"\(name)\" changed on disk since it was approved — refused"
            )
        }
        let task = try mapLaunchFailure { try NSUserUnixTask(url: url) }

        let pipe = Pipe()
        task.standardOutput = pipe.fileHandleForWriting
        task.standardError = pipe.fileHandleForWriting
        let collector = TailCollector(limit: Self.outputByteLimit)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.append(data)
            }
        }

        let start = DispatchTime.now()
        // Bridge the completion handler to a stream so the timeout race below
        // never risks a double-resume: the stream absorbs the callback
        // whenever it lands, raced or not.
        let completion = AsyncStream<Error?> { continuation in
            task.execute(withArguments: arguments) { error in
                continuation.yield(error)
                continuation.finish()
            }
            // Drop the parent's write end AFTER execute has duplicated the
            // handles into the child, so EOF can reach the reader when the
            // child exits.
            try? pipe.fileHandleForWriting.close()
        }

        enum RaceWinner {
            case finished(Error?)
            case timedOut
        }
        let winner: RaceWinner = await withTaskGroup(of: RaceWinner.self) { group in
            group.addTask {
                for await error in completion {
                    return .finished(error)
                }
                return .finished(nil)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        let duration = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        switch winner {
        case .timedOut:
            // Cannot kill an NSUserUnixTask — abandon the wait, keep the
            // reader handler detached, and report honestly.
            pipe.fileHandleForReading.readabilityHandler = nil
            return ScriptRunOutcome(
                succeeded: false, failureReason: "timed out after \(Int(timeout))s",
                output: collector.text, duration: duration, timedOut: true
            )
        case let .finished(error):
            // Final drain: the readability handler may not have seen the last
            // chunk before EOF; read whatever remains, then release the handle.
            pipe.fileHandleForReading.readabilityHandler = nil
            if let remaining = try? pipe.fileHandleForReading.readToEnd(), !remaining.isEmpty {
                collector.append(remaining)
            }
            try? pipe.fileHandleForReading.close()
            return ScriptRunOutcome(
                succeeded: error == nil,
                failureReason: error?.localizedDescription,
                output: collector.text, duration: duration, timedOut: false
            )
        }
    }

    static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func mapLaunchFailure<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let failure as ScriptRunFailure {
            throw failure
        } catch {
            throw ScriptRunFailure.launchFailed(error.localizedDescription)
        }
    }
}

/// Thread-safe bounded output buffer keeping the TAIL of what it's fed.
private final class TailCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit {
            data = data.suffix(limit)
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        // Prefer a clean UTF-8 decode; fall back to a lossy one because the
        // tail cap can slice a multibyte character mid-sequence.
        // swiftlint:disable:next optional_data_string_conversion
        return String(bytes: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
