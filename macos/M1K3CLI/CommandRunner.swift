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
//  Review: Kev + claude-opus-5, 2026-09-11 — the `claude` lookup moved to
//  M1K3CLICore.ExecutableLookup and is handed THIS runner's injected
//  environment. It used to default to ProcessInfo, so the one call site read
//  the real machine while `isSandboxed` beside it read the injection — a DI
//  seam with a hole in it, and untestable where it lived. Confidence now 0.85.
//  Review: Kev + claude-fable-5.1, 2026-09-11 — the already-connected read of
//  `claude`'s stderr now lives in ConnectPlan, anchored on the server name.
//  Confidence now 0.85.
//  Review: Kev + claude-fable-5.1, 2026-09-18 — `agent-notes --write` is sandbox-aware, as `connect`
//  already was. Found the first time the sandboxed helper ever RAN (it had trapped at launch since it
//  was added — no Info.plist section, see project.yml): it wrote AGENTS.md into its own container and
//  printed "wrote …". Now it prints the block (stdout) and says why (stderr). Verified by run on an
//  ad-hoc-signed sandboxed build; `connect` was driven the same way and already printed. Confidence 0.85.
//  Review: Kev + claude-opus-5-5, 2026-09-28 — #380: agent-notes resolves its path through `AgentNotes.target`. Confidence 0.9.
//  Review: Kev + claude-opus-5-5, 2026-09-28 — #270 slice 3: `login` reads the token from the terminal
//  (echo off) or a pipe and saves it (CLITokenStore); every call carries it; a 401 prints how to log in
//  (exit 4). `connect` needs the token and writes it into the client's config; a Claude Code entry that
//  already exists is removed and added again, and the echoed command masks the token. Confidence 0.85.
//  Review: Kev + claude-opus-5-5, 2026-09-29 — #448 review folds: `login` checks the token BEFORE saving
//  (a stale paste can't replace a working token); the tty read switches echo off on stdin and VERIFIES it
//  (readpassphrase echoed the token in the sandboxed helper), refusing a terminal that still echoes; `claude`'s stderr and the
//  PATH-missing hint go through `MCPAccessToken.redacting` / the masked snippet; a failed re-add after a
//  successful remove says the old entry is gone; every failure fallback masks the token (`--print` shows it
//  whole); Ctrl-C/TERM/HUP at the hidden prompt restore the terminal before dying. Confidence 0.85.
//

import Darwin // getpwuid — the account's REAL home, which the sandbox hides; termios for login
import Foundation
import M1K3CLICore

/// The terminal settings `readSecretLine` must put back, reachable from a
/// signal handler (a C function pointer captures nothing). Set only for the
/// read window.
/// `nonisolated(unsafe)` is sound here: it is written only BEFORE the handlers
/// are installed and cleared after they are removed, so the handler only ever
/// reads a settled value; `tcsetattr`, `signal` and `raise` are async-signal-safe.
private nonisolated(unsafe) var termiosToRestore: termios?

/// Ctrl-C (or a TERM/HUP) at the hidden prompt would otherwise kill the
/// process with echo still off, and the user's shell stops echoing (#448
/// review). Restore, then die of the same signal.
private func restoreTerminalAndReraise(_ signal: Int32) {
    if var saved = termiosToRestore {
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
    }
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

enum ExitCode {
    static let ok: Int32 = 0
    static let usage: Int32 = 1
    static let unreachable: Int32 = 2
    static let toolError: Int32 = 3
    static let unauthorized: Int32 = 4
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
        case .login:
            return await login()
        default:
            return await callTool()
        }
    }

    // MARK: - Tool calls

    private func callTool() async -> Int32 {
        let transport = MCPTransport.sequence(
            port: command.port, clientVersion: appVersion, token: CLITokenStore.read()
        )
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
        case .connect, .agentNotes, .login, .help, .version:
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
        case .failure(.unauthorized):
            return Self.unauthorized()
        }
    }

    /// The door's 401 (#270): say where the token is and how to hand it over.
    static func unauthorized() -> Int32 {
        Output.error("m1k3: M1K3 turned that away — it needs the access token.")
        Output.error("m1k3: copy it from M1K3 ▸ Settings ▸ Privacy ▸ MCP server, then run: m1k3 login")
        return ExitCode.unauthorized
    }

    /// `ask_m1k3` hands back a job id when a turn outruns its ~8s inline grace
    /// (see IntelligenceMCPTools). A person at a terminal wants the answer, not
    /// the receipt — so poll it out.
    private func finish(_ text: String, transport: MCPCallSequence) async -> Int32 {
        guard case .ask = command.action, let job = AskJobWire.jobID(in: text) else {
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
                if AskJobWire.isStillWorking(answer) { continue }
                Output.line(answer)
                return ExitCode.ok
            case let .failure(.unreachable(message)):
                Output.error(message)
                return ExitCode.unreachable
            case let .failure(.tool(message)):
                Output.error("m1k3: \(message)")
                return ExitCode.toolError
            case .failure(.unauthorized):
                return Self.unauthorized()
            }
        }
        Output.error("m1k3: gave up waiting — redeem it later with: m1k3 call get_answer '{\"job_id\":\"\(job)\"}'")
        return ExitCode.toolError
    }

    /// A remembered note needs a title; the first line of what you said is a
    /// better one than "Untitled".
    static func title(for text: String) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(60)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - login

    /// The token comes in on the terminal with echo off, or down a pipe
    /// (`pbpaste | m1k3 login`) — never argv, which lands in shell history.
    /// Tried BEFORE it is saved: a stale paste M1K3 turns away must not
    /// replace a token that works. Saved unchecked only when M1K3 can't be
    /// reached — right or wrong, the token doesn't depend on the app being up.
    private func login() async -> Int32 {
        let pasted: String
        switch Self.readSecretLine(
            prompt: "Paste M1K3's access token (Settings ▸ Privacy ▸ MCP server ▸ Copy): "
        ) {
        case let .read(line): pasted = line
        case .noInput:
            Output.error("m1k3: no token read")
            return ExitCode.usage
        case .terminalUnavailable:
            Output.error("m1k3: this terminal won't hide what you type — pipe the token in instead: pbpaste | m1k3 login")
            return ExitCode.usage
        }
        guard let token = MCPAccessToken.parse(pasted: pasted) else {
            Output.error("m1k3: that isn't an M1K3 access token — it starts \(MCPAccessToken.prefix) (Settings ▸ Privacy ▸ Copy)")
            return ExitCode.usage
        }
        let transport = MCPTransport.sequence(port: command.port, clientVersion: appVersion, token: token)
        let checked: String
        switch await transport.call(tool: "get_status", arguments: [:]) {
        case .success:
            checked = "M1K3 accepted it."
        case .failure(.unauthorized):
            Output.error("m1k3: M1K3 turned that token away — not saved (any token saved before is unchanged).")
            Output.error("m1k3: copy the current one from M1K3 ▸ Settings ▸ Privacy ▸ MCP server.")
            return ExitCode.unauthorized
        case let .failure(.unreachable(message)), let .failure(.tool(message)):
            checked = "Couldn't check it just now — \(message)"
        }
        do {
            try CLITokenStore.save(token)
        } catch {
            Output.error("m1k3: \(error)")
            return ExitCode.toolError
        }
        Output.line("Saved \(MCPAccessToken.masked(token)). \(checked)")
        return ExitCode.ok
    }

    enum SecretRead {
        case read(String)
        case noInput
        /// The terminal wouldn't hide what's typed — reading would put the token on screen.
        case terminalUnavailable
    }

    /// One line from the terminal with echo off, or from stdin when it's a pipe.
    ///
    /// ★ Not `readpassphrase`: in the sandboxed App Store helper it opens
    /// /dev/tty and the typed token ECHOES (the echo-off doesn't take; found
    /// driving #448 under a pty — the same call unsandboxed hides it). So echo
    /// is switched off on the inherited stdin and READ BACK: a terminal that
    /// still echoes is refused, never read. The Swift String copies aren't
    /// wiped (no secure string type) — fine for a short-lived CLI (#270).
    static func readSecretLine(prompt: String) -> SecretRead {
        guard isatty(STDIN_FILENO) != 0 else {
            return readLine(strippingNewline: true).map(SecretRead.read) ?? .noInput
        }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return .terminalUnavailable }
        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO)
        hidden.c_lflag |= tcflag_t(ICANON)
        var applied = termios()
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0,
              tcgetattr(STDIN_FILENO, &applied) == 0, applied.c_lflag & tcflag_t(ECHO) == 0
        else {
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            return .terminalUnavailable
        }
        termiosToRestore = original
        let cancelSignals = [SIGINT, SIGTERM, SIGHUP]
        for cancel in cancelSignals {
            signal(cancel, restoreTerminalAndReraise)
        }
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            for cancel in cancelSignals {
                signal(cancel, SIG_DFL)
            }
            termiosToRestore = nil
            FileHandle.standardError.write(Data("\n".utf8)) // the Return the user typed wasn't echoed
        }
        FileHandle.standardError.write(Data(prompt.utf8))
        return readLine(strippingNewline: true).map(SecretRead.read) ?? .noInput
    }

    // MARK: - agent-notes

    private func agentNotes(_ target: CLICommand.NotesTarget) -> Int32 {
        switch target {
        case .stdout:
            Output.line(AgentNotes.block)
            return ExitCode.ok
        case let .file(path):
            // Same stance as `connect`: a sandboxed helper's `~` and its working
            // directory both resolve inside ~/Library/Containers/app.m1k3.cli, so
            // a write "succeeds" into a file no agent will ever read. The notice
            // goes to stderr so the block on stdout stays pipeable (`>> AGENTS.md`
            // is the shell's write, outside the sandbox, and lands where asked).
            if isSandboxed {
                Output.error("m1k3: this copy is sandboxed (App Store build) and can't write \(path) for you.")
                Output.error("m1k3: here's the block — or run: m1k3 agent-notes >> \(path)")
                Output.line(AgentNotes.block)
                return ExitCode.ok
            }
            let url = AgentNotes.target(for: path) { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
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
        // Every client's config carries the token now (#270), so there is nothing
        // honest to write or print without it.
        guard let token = CLITokenStore.read() else {
            Output.error("m1k3: connect needs M1K3's access token first — run m1k3 login")
            Output.error("m1k3: (copy it from M1K3 ▸ Settings ▸ Privacy ▸ MCP server)")
            return ExitCode.unauthorized
        }
        if isSandboxed {
            Output.line("This copy of m1k3 is sandboxed (App Store build) — here's the config to paste yourself:")
            return show(client: client, url: url, token: token)
        }
        if printOnly { return show(client: client, url: url, token: token) }

        let home = configDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        switch ConnectPlan.plan(client: client, url: url, token: token, configDir: home) {
        case let .shell(command):
            return runShell(command, client: client, url: url, token: token)
        case .jsonMerge:
            return writeConfig(client: client, url: url, token: token, configDir: home)
        case let .printOnly(snippet, note):
            Output.line(snippet)
            Output.line("")
            Output.line(note)
            return ExitCode.ok
        }
    }

    /// What a failed connect leaves on screen: the shape, token masked, and
    /// the flag that prints it whole. A failure isn't a request to print a
    /// secret; `--print` is (#448 review).
    private static func fallback(client: MCPClient, url: String, token: String) {
        Output.line(ConnectPlan.snippet(client: client, url: url, token: MCPAccessToken.masked(token)))
        Output.line("")
        Output.line("m1k3 connect \(client.rawValue) --print shows it with the full token.")
    }

    private func show(client: MCPClient, url: String, token: String) -> Int32 {
        Output.line(ConnectPlan.snippet(client: client, url: url, token: token))
        Output.line("")
        Output.line("→ \(ConnectPlan.destination(client: client))")
        return ExitCode.ok
    }

    private func writeConfig(client: MCPClient, url: String, token: String, configDir: URL) -> Int32 {
        do {
            let outcome = try JSONConfigWriter.apply(
                ConnectPlan.plan(client: client, url: url, token: token, configDir: configDir)
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
            Self.fallback(client: client, url: url, token: token)
            return ExitCode.toolError
        } catch {
            // Whatever went wrong, the user should leave with something they
            // can paste rather than just an error.
            Output.error("m1k3: \(error.localizedDescription)")
            Output.line("")
            Self.fallback(client: client, url: url, token: token)
            Output.line("→ \(ConnectPlan.destination(client: client))")
            return ExitCode.toolError
        }
    }

    /// Run the client's own registration command — but only if we can find it.
    /// Printing the line for the user to run is a perfectly good outcome; a
    /// stack trace about a missing binary is not.
    private func runShell(_ command: [String], client: MCPClient, url: String, token: String) -> Int32 {
        guard let tool = command.first else { return ExitCode.usage }
        // What goes on screen: the command with the token masked. The real one
        // only ever reaches the client's own registry.
        let shown = command.map { MCPAccessToken.redacting($0, token: token) }
        guard let executable = ExecutableLookup.locate(
            tool, environment: environment, home: FileManager.default.homeDirectoryForCurrentUser.path
        ) else {
            // Nothing failed here, so nothing secret goes to the screen by default.
            Output.line("\(tool) isn't on your PATH. Once \(tool) is installed, run m1k3 connect \(client.rawValue) again,")
            Output.line("or m1k3 connect \(client.rawValue) --print for the full line. It looks like:")
            Output.line("")
            Output.line(ConnectPlan.snippet(client: client, url: url, token: MCPAccessToken.masked(token)))
            return ExitCode.ok
        }
        Output.line("$ \(shown.joined(separator: " "))")
        do {
            var run = try Self.execute(executable, Array(command.dropFirst()))
            var removedOld = false
            // `claude mcp add` refuses a name that exists — and since the token
            // (#270) that entry may be one without it. Replace it: remove, add again.
            if run.status != 0, ConnectPlan.shellSaysAlreadyConnected(run.stderr),
               let replace = ConnectPlan.replaceCommand(client: client)
            {
                Output.line("$ \(replace.joined(separator: " "))")
                let removal = try Self.execute(executable, Array(replace.dropFirst()))
                removedOld = removal.status == 0
                let removalError = MCPAccessToken.redacting(removal.stderr, token: token)
                if !removedOld, !removalError.isEmpty {
                    Output.error(removalError.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                Output.line("$ \(shown.joined(separator: " "))")
                run = try Self.execute(executable, Array(command.dropFirst()))
            }
            if run.status == 0 {
                Output.line("Restart \(client.displayName) to pick it up.")
                return ExitCode.ok
            }
            // The client's own words, token masked — it may echo its arguments.
            let stderr = MCPAccessToken.redacting(run.stderr, token: token)
            if !stderr.isEmpty { Output.error(stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if removedOld { Output.error("m1k3: the old m1k3 entry was removed and the new one didn't go in.") }
            Output.error("m1k3: \(tool) exited \(run.status). Do it by hand:")
            Output.line("")
            Self.fallback(client: client, url: url, token: token)
            return ExitCode.toolError
        } catch {
            Output.error("m1k3: couldn't run \(tool) — \(error.localizedDescription)")
            Output.line("")
            Self.fallback(client: client, url: url, token: token)
            return ExitCode.toolError
        }
    }

    /// Run to completion; stdout passes through, stderr is captured for the
    /// already-exists read.
    private static func execute(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: stderr, encoding: .utf8) ?? "")
    }
}
