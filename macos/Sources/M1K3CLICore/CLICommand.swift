//
//  CLICommand.swift
//  M1K3CLICore
//
//  The `m1k3` argument table — the whole of the command-line surface, parsed
//  into a value the executable can switch on. Hand-rolled rather than
//  swift-argument-parser: this binary ships INSIDE M1K3.app and is on the
//  Show HN line (`m1k3 connect claude`), so it carries no dependency the app
//  doesn't already have, and starts in milliseconds.
//
//  Two conventions worth knowing. `--port` is global (flag beats
//  `M1K3_MCP_PORT` beats the app's own 4242) because every subcommand talks
//  to the same loopback server. And the text-carrying subcommands — ask,
//  speak, remember, search — join everything that is not a recognised flag,
//  so an unquoted question works the way people actually type it.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.9 (a pure table,
//  test-pinned shape by shape; the only judgement calls are which shapes are
//  errors and which are help). Prior: Unknown.
//

import Foundation

/// One MCP client M1K3 knows how to wire itself into.
public enum MCPClient: String, CaseIterable, Equatable, Sendable {
    case claude
    case codex
    case cursor
    case vscode
    case zed

    /// How the client calls itself in its own UI (Settings shows this).
    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .zed: "Zed"
        }
    }
}

/// The one address M1K3 serves MCP on. Loopback is not a default — it is the
/// privacy guarantee (`LocalMCPHTTPServer` binds 127.0.0.1 explicitly), so
/// there is deliberately no host parameter here.
public enum MCPEndpoint {
    public static let defaultPort: UInt16 = 4242

    public static func url(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/mcp"
    }
}

/// A refusal the user can act on: one line about what went wrong, plus the
/// usage text, because a CLI that says only "invalid arguments" is a dead end.
public struct CLIUsageError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var usage: String {
        CLICommand.usage
    }
}

/// A parsed command line: what to do, and which port to do it against.
public struct CLICommand: Equatable, Sendable {
    /// Where `agent-notes` sends the resident block.
    public enum NotesTarget: Equatable, Sendable {
        case stdout
        case file(String)
    }

    public enum Action: Equatable, Sendable {
        case status
        case ask(String)
        case speak(text: String, emotion: String?)
        case remember(text: String, title: String?)
        case search(String)
        /// Raw escape hatch: any tool, arguments verbatim. `argumentsJSON` is
        /// validated to be a JSON *object* at parse time so a typo fails at
        /// exit 1 rather than as a puzzling server error.
        case call(tool: String, argumentsJSON: String?)
        case connect(client: MCPClient, printOnly: Bool, configDir: String?)
        case agentNotes(NotesTarget)
        case help
        case version
    }

    public let action: Action
    public let port: UInt16

    public init(action: Action, port: UInt16 = MCPEndpoint.defaultPort) {
        self.action = action
        self.port = port
    }

    public static let portEnvironmentKey = "M1K3_MCP_PORT"

    public static let usage = """
    m1k3 — talk to the M1K3 app running on this Mac.

    USAGE
      m1k3 status                        what M1K3 is doing right now
      m1k3 ask <question…>               ask the local brain
      m1k3 speak <text…> [--emotion E]   say it aloud
      m1k3 remember <text…> [--title T]  keep it, for every future conversation
      m1k3 search <query…>               search M1K3's own documents and notes
      m1k3 call <tool> [json]            call any MCP tool directly
      m1k3 connect <client>              wire an agent into M1K3
                                         (\(MCPClient.allCases.map(\.rawValue).joined(separator: " | ")))
                                         [--print] [--config-dir DIR]
      m1k3 agent-notes [--write [PATH]]  the "M1K3 is the resident" block for AGENTS.md
      m1k3 version | help

    OPTIONS
      --port N        the app's MCP port (default \(MCPEndpoint.defaultPort), or $\(portEnvironmentKey))

    M1K3 must be running — m1k3 opens it for you if it isn't.
    """

    // MARK: - Parsing

    /// Parse a command line (already stripped of argv[0]).
    ///
    /// `environment` is injected rather than read from `ProcessInfo` so the
    /// table is testable without touching the machine's real environment.
    public static func parse(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) -> Result<CLICommand, CLIUsageError> {
        let port: UInt16
        var rest: [String]
        switch extractPort(from: arguments, environment: environment) {
        case let .failure(error): return .failure(error)
        case let .success(extracted): (port, rest) = extracted
        }

        guard let head = rest.first else { return .success(CLICommand(action: .help, port: port)) }
        rest.removeFirst()
        return action(for: head, arguments: rest).map { CLICommand(action: $0, port: port) }
    }

    private static func action(for subcommand: String, arguments: [String]) -> Result<Action, CLIUsageError> {
        switch subcommand {
        case "status": noArguments(arguments, subcommand: "status", action: .status)
        case "ask": text(arguments, subcommand: "ask").map { .ask($0) }
        case "speak": speak(arguments)
        case "remember": remember(arguments)
        case "search": text(arguments, subcommand: "search").map { .search($0) }
        case "call": call(arguments)
        case "connect": connect(arguments)
        case "agent-notes": agentNotes(arguments)
        case "help", "--help", "-h": .success(.help)
        case "version", "--version", "-v": .success(.version)
        default: .failure(CLIUsageError("unknown command \"\(subcommand)\""))
        }
    }

    // MARK: - The global port

    private static func extractPort(
        from arguments: [String],
        environment: [String: String]
    ) -> Result<(UInt16, [String]), CLIUsageError> {
        // An out-of-range env var is IGNORED rather than fatal: it is ambient
        // state, and MCPHostController.port does exactly the same with an
        // out-of-range stored default. An explicit --port is a typo the user
        // can see and fix, so that one is refused.
        var port = environment[portEnvironmentKey].flatMap(validPort) ?? MCPEndpoint.defaultPort
        var rest: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--port" {
                let next = arguments.index(after: index)
                guard next < arguments.endIndex else {
                    return .failure(CLIUsageError("--port needs a port number"))
                }
                guard let parsed = validPort(arguments[next]) else {
                    return .failure(CLIUsageError(
                        "--port takes a number from 1024 to 65535, not \"\(arguments[next])\""
                    ))
                }
                port = parsed
                index = arguments.index(after: next)
                continue
            }
            if argument.hasPrefix("--port=") {
                let value = String(argument.dropFirst("--port=".count))
                guard let parsed = validPort(value) else {
                    return .failure(CLIUsageError("--port takes a number from 1024 to 65535, not \"\(value)\""))
                }
                port = parsed
                index = arguments.index(after: index)
                continue
            }
            rest.append(argument)
            index = arguments.index(after: index)
        }
        return .success((port, rest))
    }

    /// Mirrors MCPHostController.port's own bounds — below 1024 needs root to
    /// bind, so the app would never be listening there.
    private static func validPort(_ text: String) -> UInt16? {
        guard let value = Int(text), value > 1023, value <= 65535 else { return nil }
        return UInt16(value)
    }

    // MARK: - Subcommand shapes

    private static func noArguments(
        _ arguments: [String],
        subcommand: String,
        action: Action
    ) -> Result<Action, CLIUsageError> {
        guard arguments.isEmpty else {
            return .failure(CLIUsageError("\(subcommand) takes no arguments — didn't expect \"\(arguments[0])\""))
        }
        return .success(action)
    }

    private static func text(_ arguments: [String], subcommand: String) -> Result<String, CLIUsageError> {
        let joined = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            return .failure(CLIUsageError("\(subcommand) needs something to work with — try: m1k3 \(subcommand) …"))
        }
        return .success(joined)
    }

    private static func speak(_ arguments: [String]) -> Result<Action, CLIUsageError> {
        pullValue(named: "--emotion", from: arguments).flatMap { emotion, rest in
            text(rest, subcommand: "speak").map { .speak(text: $0, emotion: emotion) }
        }
    }

    private static func remember(_ arguments: [String]) -> Result<Action, CLIUsageError> {
        pullValue(named: "--title", from: arguments).flatMap { title, rest in
            text(rest, subcommand: "remember").map { .remember(text: $0, title: title) }
        }
    }

    private static func call(_ arguments: [String]) -> Result<Action, CLIUsageError> {
        guard let tool = arguments.first, !tool.isEmpty else {
            return .failure(CLIUsageError("call needs a tool name — try: m1k3 call get_status"))
        }
        // The shell splits unquoted JSON on spaces; rejoining is friendlier
        // than telling the user to quote it.
        let raw = arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .success(.call(tool: tool, argumentsJSON: nil)) }
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              parsed is [String: Any]
        else {
            return .failure(CLIUsageError("call's arguments must be a JSON object, e.g. {\"text\":\"hello\"}"))
        }
        return .success(.call(tool: tool, argumentsJSON: raw))
    }

    private static func connect(_ arguments: [String]) -> Result<Action, CLIUsageError> {
        var rest = arguments
        var printOnly = false
        rest.removeAll { argument in
            guard argument == "--print" else { return false }
            printOnly = true
            return true
        }
        return pullValue(named: "--config-dir", from: rest).flatMap { configDir, rest in
            let known = MCPClient.allCases.map(\.rawValue).joined(separator: ", ")
            guard let name = rest.first else {
                return .failure(CLIUsageError("connect needs a client — one of: \(known)"))
            }
            guard let client = MCPClient(rawValue: name.lowercased()) else {
                return .failure(CLIUsageError("\"\(name)\" isn't a client m1k3 knows — try one of: \(known)"))
            }
            guard rest.count == 1 else {
                return .failure(CLIUsageError("connect takes one client — didn't expect \"\(rest[1])\""))
            }
            return .success(.connect(client: client, printOnly: printOnly, configDir: configDir))
        }
    }

    private static func agentNotes(_ arguments: [String]) -> Result<Action, CLIUsageError> {
        guard let head = arguments.first else { return .success(.agentNotes(.stdout)) }
        guard head == "--write" else {
            return .failure(CLIUsageError("agent-notes takes only --write [PATH] — didn't expect \"\(head)\""))
        }
        guard arguments.count <= 2 else {
            return .failure(CLIUsageError("agent-notes takes one path — didn't expect \"\(arguments[2])\""))
        }
        return .success(.agentNotes(.file(arguments.dropFirst().first ?? AgentNotes.defaultFileName)))
    }

    /// Pull `--name VALUE` out of a line, leaving everything else in order.
    /// Positional text keeps its own leading dashes ("-40 degrees" is text,
    /// not a flag) — only the names we know are treated as flags.
    ///
    /// ⚠️ Deliberately `--name VALUE` ONLY — no `--name=VALUE`. These three
    /// flags (`--title`, `--emotion`, `--config-dir`) sit inside free text, and
    /// `m1k3 remember --title=x` would otherwise be ambiguous with a note that
    /// genuinely begins "--title=x". `--port` accepts `=` because it is global:
    /// it is lifted out before any subcommand sees the line, so there is no
    /// free text for it to collide with. The usage text lists `--port N` and
    /// `[--config-dir DIR]` in exactly this shape.
    private static func pullValue(
        named name: String,
        from arguments: [String]
    ) -> Result<(String?, [String]), CLIUsageError> {
        var value: String?
        var rest: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            guard arguments[index] == name else {
                rest.append(arguments[index])
                index = arguments.index(after: index)
                continue
            }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else {
                return .failure(CLIUsageError("\(name) needs a value"))
            }
            value = arguments[next]
            index = arguments.index(after: next)
        }
        return .success((value, rest))
    }
}
