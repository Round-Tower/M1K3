//
//  CommandRunner.swift
//  m1k3
//
//  Each subcommand, turned into either an MCP tool call or a file on disk.
//  Thin by design: every decision worth pinning (what the frames look like,
//  what a plan means per client, how the notes block merges) lives in
//  M1K3CLICore and is unit-tested; this file is the effects.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.8 (verify-by-run
//  against the live app — the ask job poll and the `claude` lookup are the
//  parts a unit test can't see). Prior: Unknown.
//  Review: Kev + claude-opus-5, 2026-09-11 — code-quality fold: the sandbox is
//  detected by a REDIRECTED HOME, not only by launchd's env var (the App Store
//  helper run from a Terminal has no env var and would have written a config
//  inside its own container while printing "wrote …"); a duplicate
//  `claude mcp add` now reads as already-connected; every write failure prints
//  the snippet so the user is never left with nothing. Confidence now 0.85.
//

import Darwin // getpwuid — the account's REAL home, which the sandbox hides
import Foundation
import M1K3CLICore

enum ExitCode {
    static let ok: Int32 = 0
    static let usage: Int32 = 1
    static let unreachable: Int32 = 2
    static let toolError: Int32 = 3
}

enum Output {
    static func line(_ text: String) {
        print(text)
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

struct CommandRunner {
    let command: CLICommand
    let environment: [String: String]
    let appVersion: String

    /// The App Store build's helper runs sandboxed, so it can see neither
    /// ~/.cursor nor the `claude` binary. Rather than fail at the user with a
    /// permissions error, `connect` degrades to printing — which is what a
    /// sandboxed helper can honestly do.
    ///
    /// ★ The env var is not enough on its own: launchd injects it, so the
    /// helper run from a Terminal (the route the README documents) is
    /// sandboxed WITHOUT it. Unspotted, `~/.cursor/mcp.json` resolves into
    /// ~/Library/Containers/app.m1k3.cli/Data and we'd report "wrote …" for a
    /// file Cursor will never read. The redirected home is the real tell.
    var isSandboxed: Bool {
        SandboxProbe.isSandboxed(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            realHome: Self.passwordDatabaseHome(),
            environment: environment
        )
    }

    /// The account's home as the password database knows it — untouched by
    /// the sandbox's redirection. nil when it can't be read, which the probe
    /// treats as "no evidence" rather than as a sandbox.
    static func passwordDatabaseHome() -> String? {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        return String(cString: home)
    }

    func run() async -> Int32 {
        switch command.action {
        case .help:
            Output.line(CLICommand.usage)
            return ExitCode.ok
        case .version:
            Output.line(appVersion)
            return ExitCode.ok
        case let .agentNotes(target):
            return agentNotes(target)
        case let .connect(client, printOnly, configDir):
            return connect(client: client, printOnly: printOnly, configDir: configDir)
        default:
            return await callTool()
        }
    }

    // MARK: - Tool calls

    private func callTool() async -> Int32 {
        let transport = MCPTransport.sequence(port: command.port, clientVersion: appVersion)
        let request: (tool: String, arguments: [String: JSONValue])
        switch command.action {
        case .status:
            request = ("get_status", [:])
        case let .ask(question):
            request = ("ask_m1k3", ["question": .string(question)])
        case let .speak(text, emotion):
            var arguments: [String: JSONValue] = ["text": .string(text)]
            if let emotion { arguments["emotion"] = .string(emotion) }
            request = ("speak", arguments)
        case let .remember(text, title):
            request = ("remember", ["title": .string(title ?? Self.title(for: text)), "text": .string(text)])
        case let .search(query):
            request = ("search_knowledge", ["query": .string(query)])
        case let .call(tool, argumentsJSON):
            do {
                let arguments = try argumentsJSON.map { try JSONValue.arguments(fromJSON: $0) } ?? [:]
                request = (tool, arguments)
            } catch {
                Output.error("m1k3: \(error)")
                return ExitCode.usage
            }
        case .connect, .agentNotes, .help, .version:
            Output.error("m1k3: nothing to call")
            return ExitCode.usage
        }

        switch await transport.call(tool: request.tool, arguments: request.arguments) {
        case let .success(text):
            return await finish(text, transport: transport)
        case let .failure(.unreachable(message)):
            Output.error(message)
            return ExitCode.unreachable
        case let .failure(.tool(message)):
            Output.error("m1k3: \(message)")
            return ExitCode.toolError
        }
    }

    /// `ask_m1k3` hands back a job id when a turn outruns its ~8s inline grace
    /// (see IntelligenceMCPTools). A person at a terminal wants the answer, not
    /// the receipt — so poll it out.
    private func finish(_ text: String, transport: MCPCallSequence) async -> Int32 {
        guard case .ask = command.action, let job = Self.jobID(in: text) else {
            Output.line(text)
            return ExitCode.ok
        }
        Output.error("m1k3: M1K3 is thinking (job \(job)) — waiting…")
        // The app's own runaway backstop is AskJobStore.jobRetention (600s);
        // waiting longer than the answer can survive would be pointless.
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(2))
            switch await transport.call(tool: "get_answer", arguments: ["job_id": .string(job)]) {
            case let .success(answer):
                if answer.contains("still working on job") { continue }
                Output.line(answer)
                return ExitCode.ok
            case let .failure(.unreachable(message)):
                Output.error(message)
                return ExitCode.unreachable
            case let .failure(.tool(message)):
                Output.error("m1k3: \(message)")
                return ExitCode.toolError
            }
        }
        Output.error("m1k3: gave up waiting — redeem it later with: m1k3 call get_answer '{\"job_id\":\"\(job)\"}'")
        return ExitCode.toolError
    }

    /// The busy line quotes the id: `… with job_id "1A2B" in a few seconds …`
    static func jobID(in text: String) -> String? {
        guard let marker = text.range(of: "job_id \"") else { return nil }
        let rest = text[marker.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let id = String(rest[..<close])
        return id.isEmpty ? nil : id
    }

    /// A remembered note needs a title; the first line of what you said is a
    /// better one than "Untitled".
    static func title(for text: String) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(60)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - agent-notes

    private func agentNotes(_ target: CLICommand.NotesTarget) -> Int32 {
        switch target {
        case .stdout:
            Output.line(AgentNotes.block)
            return ExitCode.ok
        case let .file(path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let existing = try? String(contentsOf: url, encoding: .utf8)
            let merged = AgentNotes.merge(into: existing)
            if merged == existing {
                Output.line("already there — \(url.path) is unchanged")
                return ExitCode.ok
            }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data(merged.utf8).write(to: url, options: .atomic)
                Output.line("wrote \(url.path)")
                return ExitCode.ok
            } catch {
                Output.error("m1k3: couldn't write \(url.path) — \(error.localizedDescription)")
                return ExitCode.toolError
            }
        }
    }

    // MARK: - connect

    private func connect(client: MCPClient, printOnly: Bool, configDir: String?) -> Int32 {
        let url = MCPEndpoint.url(port: command.port)
        if isSandboxed {
            Output.line("This copy of m1k3 is sandboxed (App Store build) — here's the config to paste yourself:")
            return show(client: client, url: url)
        }
        if printOnly { return show(client: client, url: url) }

        let home = configDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        switch ConnectPlan.plan(client: client, url: url, configDir: home) {
        case let .shell(command):
            return runShell(command, client: client, url: url)
        case .jsonMerge:
            return writeConfig(client: client, url: url, configDir: home)
        case let .printOnly(snippet, note):
            Output.line(snippet)
            Output.line("")
            Output.line(note)
            return ExitCode.ok
        }
    }

    private func show(client: MCPClient, url: String) -> Int32 {
        Output.line(ConnectPlan.snippet(client: client, url: url))
        Output.line("")
        Output.line("→ \(ConnectPlan.destination(client: client))")
        return ExitCode.ok
    }

    private func writeConfig(client: MCPClient, url: String, configDir: URL) -> Int32 {
        do {
            let outcome = try JSONConfigWriter.apply(
                ConnectPlan.plan(client: client, url: url, configDir: configDir)
            )
            switch outcome {
            case let .written(path, backup):
                let suffix = backup.map { " (backup \($0.lastPathComponent))" } ?? ""
                Output.line("wrote \(path.path)\(suffix)")
                Output.line("Restart \(client.displayName) to pick it up.")
            case .unchanged:
                Output.line("already connected — nothing to change.")
            }
            return ExitCode.ok
        } catch let error as JSONConfigWriter.WriteError {
            Output.error("m1k3: \(error.message)")
            Output.line("")
            Output.line(ConnectPlan.snippet(client: client, url: url))
            return ExitCode.toolError
        } catch {
            // Whatever went wrong, the user should leave with something they
            // can paste rather than just an error.
            Output.error("m1k3: \(error.localizedDescription)")
            Output.line("")
            Output.line(ConnectPlan.snippet(client: client, url: url))
            Output.line("→ \(ConnectPlan.destination(client: client))")
            return ExitCode.toolError
        }
    }

    /// Run the client's own registration command — but only if we can find it.
    /// Printing the line for the user to run is a perfectly good outcome; a
    /// stack trace about a missing binary is not.
    private func runShell(_ command: [String], client: MCPClient, url: String) -> Int32 {
        guard let tool = command.first else { return ExitCode.usage }
        guard let executable = Self.locate(tool) else {
            Output.line("\(tool) isn't on your PATH. Run this once \(tool) is installed:")
            Output.line("")
            Output.line(command.joined(separator: " "))
            return ExitCode.ok
        }
        Output.line("$ \(command.joined(separator: " "))")
        let process = Process()
        process.executableURL = executable
        process.arguments = Array(command.dropFirst())
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                Output.line("Restart \(client.displayName) to pick it up.")
                return ExitCode.ok
            }
            let message = String(data: stderr, encoding: .utf8) ?? ""
            // Current `claude mcp add` refuses a duplicate NAME. That is the
            // same state the JSON clients call "already connected", so it must
            // read the same way here — re-running connect is not an error.
            if Self.saysAlreadyConnected(message) {
                Output.line("already connected — nothing to change.")
                return ExitCode.ok
            }
            if !message.isEmpty { Output.error(message.trimmingCharacters(in: .whitespacesAndNewlines)) }
            Output.error("m1k3: \(tool) exited \(process.terminationStatus). Do it by hand:")
            Output.line("")
            Output.line(ConnectPlan.snippet(client: client, url: url))
            return ExitCode.toolError
        } catch {
            Output.error("m1k3: couldn't run \(tool) — \(error.localizedDescription)")
            Output.line("")
            Output.line(ConnectPlan.snippet(client: client, url: url))
            return ExitCode.toolError
        }
    }

    /// The client already knows about a server called m1k3.
    static func saysAlreadyConnected(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("already exists") || lowered.contains("already configured")
    }

    /// PATH, plus the two places a coding-agent CLI lands that a GUI-launched
    /// process's PATH usually misses.
    static func locate(_ tool: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        // Absolute entries only: a relative PATH entry (or an empty one, which
        // POSIX reads as ".") would resolve against whatever directory the user
        // happens to be in — running a `claude` a repo dropped there.
        for directory in searchPath where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
