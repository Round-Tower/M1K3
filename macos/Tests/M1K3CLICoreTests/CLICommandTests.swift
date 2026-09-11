//
//  CLICommandTests.swift
//  M1K3CLICoreTests
//
//  The `m1k3` argument table. Every subcommand, the two text-carrying flags,
//  the global port (flag beats env beats default), and the refusals — an
//  unknown client name is the one a user hits by typing "vs-code", so its
//  message has to list what IS accepted.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.9 (a pure table;
//  the only judgement is which shapes are errors versus help). Prior: Unknown.
//

import Foundation
@testable import M1K3CLICore
import Testing

struct CLICommandTests {
    private func parsed(_ args: [String], env: [String: String] = [:]) throws -> CLICommand {
        try CLICommand.parse(args, environment: env).get()
    }

    private func failure(_ args: [String], env: [String: String] = [:]) throws -> CLIUsageError {
        switch CLICommand.parse(args, environment: env) {
        case let .success(command):
            Issue.record("expected a usage error, got \(command)")
            throw CLIUsageError("unreachable")
        case let .failure(error):
            return error
        }
    }

    // MARK: - Subcommands

    @Test("status takes no arguments")
    func status() throws {
        #expect(try parsed(["status"]).action == .status)
    }

    @Test("ask joins the rest of the line into one question")
    func ask() throws {
        #expect(try parsed(["ask", "what", "did", "I", "say?"]).action == .ask("what did I say?"))
    }

    @Test("speak takes an optional emotion, anywhere on the line")
    func speak() throws {
        #expect(try parsed(["speak", "all", "done"]).action == .speak(text: "all done", emotion: nil))
        #expect(try parsed(["speak", "--emotion", "happy", "all", "done"]).action
            == .speak(text: "all done", emotion: "happy"))
        #expect(try parsed(["speak", "all", "done", "--emotion", "excited"]).action
            == .speak(text: "all done", emotion: "excited"))
    }

    @Test("remember takes an optional title")
    func remember() throws {
        #expect(try parsed(["remember", "Kev", "flies", "Tuesday"]).action
            == .remember(text: "Kev flies Tuesday", title: nil))
        #expect(try parsed(["remember", "--title", "Travel", "Kev", "flies"]).action
            == .remember(text: "Kev flies", title: "Travel"))
    }

    @Test("search joins the rest of the line into one query")
    func search() throws {
        #expect(try parsed(["search", "brain", "at", "home"]).action == .search("brain at home"))
    }

    @Test("call takes a tool name and optional JSON arguments")
    func call() throws {
        #expect(try parsed(["call", "get_status"]).action == .call(tool: "get_status", argumentsJSON: nil))
        #expect(try parsed(["call", "speak", "{\"text\":\"hi\"}"]).action
            == .call(tool: "speak", argumentsJSON: "{\"text\":\"hi\"}"))
    }

    @Test("call rejoins JSON the shell split on spaces")
    func callRejoinsSplitJSON() throws {
        #expect(try parsed(["call", "speak", "{\"text\":", "\"hi\"}"]).action
            == .call(tool: "speak", argumentsJSON: "{\"text\": \"hi\"}"))
    }

    @Test("call refuses arguments that are not a JSON object")
    func callRefusesNonObject() throws {
        #expect(try failure(["call", "speak", "hi"]).message.contains("JSON object"))
        #expect(try failure(["call", "speak", "[1,2]"]).message.contains("JSON object"))
    }

    @Test("connect names a client and defaults to executing")
    func connect() throws {
        #expect(try parsed(["connect", "claude"]).action
            == .connect(client: .claude, printOnly: false, configDir: nil))
        #expect(try parsed(["connect", "cursor", "--print"]).action
            == .connect(client: .cursor, printOnly: true, configDir: nil))
        #expect(try parsed(["connect", "vscode", "--config-dir", "/tmp/x"]).action
            == .connect(client: .vscode, printOnly: false, configDir: "/tmp/x"))
        #expect(try parsed(["connect", "codex"]).action
            == .connect(client: .codex, printOnly: false, configDir: nil))
        #expect(try parsed(["connect", "zed", "--print", "--config-dir", "/tmp/z"]).action
            == .connect(client: .zed, printOnly: true, configDir: "/tmp/z"))
    }

    @Test("agent-notes prints by default; --write takes an optional path")
    func agentNotes() throws {
        #expect(try parsed(["agent-notes"]).action == .agentNotes(.stdout))
        #expect(try parsed(["agent-notes", "--write"]).action == .agentNotes(.file(AgentNotes.defaultFileName)))
        #expect(try parsed(["agent-notes", "--write", "docs/CLAUDE.md"]).action == .agentNotes(.file("docs/CLAUDE.md")))
    }

    @Test("help and version, long and short")
    func helpAndVersion() throws {
        #expect(try parsed(["help"]).action == .help)
        #expect(try parsed(["--help"]).action == .help)
        #expect(try parsed(["-h"]).action == .help)
        #expect(try parsed([]).action == .help)
        #expect(try parsed(["version"]).action == .version)
        #expect(try parsed(["--version"]).action == .version)
    }

    // MARK: - Refusals

    @Test("a subcommand with nothing to say is a usage error naming the subcommand")
    func missingArguments() throws {
        #expect(try failure(["ask"]).message.contains("ask"))
        #expect(try failure(["speak"]).message.contains("speak"))
        #expect(try failure(["remember"]).message.contains("remember"))
        #expect(try failure(["search"]).message.contains("search"))
        #expect(try failure(["call"]).message.contains("call"))
        #expect(try failure(["connect"]).message.contains("connect"))
    }

    @Test("a flag with no value is a usage error")
    func flagWithoutValue() throws {
        #expect(try failure(["speak", "hi", "--emotion"]).message.contains("--emotion"))
        #expect(try failure(["remember", "hi", "--title"]).message.contains("--title"))
        #expect(try failure(["connect", "cursor", "--config-dir"]).message.contains("--config-dir"))
        #expect(try failure(["status", "--port"]).message.contains("--port"))
    }

    @Test("an unknown client is refused with the list of known ones")
    func unknownClient() throws {
        let error = try failure(["connect", "vs-code"])
        #expect(error.message.contains("vs-code"))
        for client in MCPClient.allCases {
            #expect(error.message.contains(client.rawValue))
        }
    }

    @Test("an unknown command is refused by name")
    func unknownCommand() throws {
        #expect(try failure(["yodel"]).message.contains("yodel"))
    }

    @Test("every usage error carries the usage text")
    func errorsCarryUsage() throws {
        #expect(try failure(["yodel"]).usage == CLICommand.usage)
        #expect(CLICommand.usage.contains("m1k3 connect"))
    }

    // MARK: - The global port

    @Test("the port defaults to the app's own 4242")
    func defaultPort() throws {
        #expect(try parsed(["status"]).port == 4242)
    }

    @Test("M1K3_MCP_PORT overrides the default")
    func envPort() throws {
        #expect(try parsed(["status"], env: ["M1K3_MCP_PORT": "5111"]).port == 5111)
    }

    @Test("--port beats the environment, and works before or after the subcommand")
    func flagPortWins() throws {
        #expect(try parsed(["status", "--port", "9000"], env: ["M1K3_MCP_PORT": "5111"]).port == 9000)
        #expect(try parsed(["--port", "9000", "ask", "hi"], env: ["M1K3_MCP_PORT": "5111"]).port == 9000)
        #expect(try parsed(["--port", "9000", "ask", "hi"]).action == .ask("hi"))
    }

    @Test("an out-of-range --port is a usage error; an out-of-range env var falls back to the default")
    func portRange() throws {
        #expect(try failure(["status", "--port", "80"]).message.contains("--port"))
        #expect(try failure(["status", "--port", "not-a-number"]).message.contains("--port"))
        // The env var is ambient — the app itself ignores an out-of-range
        // stored port rather than refusing to start, and so do we.
        #expect(try parsed(["status"], env: ["M1K3_MCP_PORT": "80"]).port == 4242)
        #expect(try parsed(["status"], env: ["M1K3_MCP_PORT": "banana"]).port == 4242)
    }

    @Test("--port=N is accepted too")
    func portEqualsForm() throws {
        #expect(try parsed(["status", "--port=9000"]).port == 9000)
    }

    @Test("a subcommand that takes nothing refuses a stray argument")
    func straysRefused() throws {
        #expect(try failure(["status", "extra"]).message.contains("extra"))
        #expect(try failure(["connect", "cursor", "extra"]).message.contains("extra"))
    }

    @Test("text subcommands take a leading dash as text, not as an unknown flag")
    func dashText() throws {
        #expect(try parsed(["speak", "-40", "degrees"]).action == .speak(text: "-40 degrees", emotion: nil))
    }

    @Test("--port is global: it comes out of a text subcommand's words, as the usage text says")
    func portLeavesTextAlone() throws {
        let command = try parsed(["speak", "hello", "--port", "9000"])
        #expect(command.action == .speak(text: "hello", emotion: nil))
        #expect(command.port == 9000)
        // Quoted text that merely mentions the flag is still text.
        #expect(try parsed(["speak", "mind the --port flag"]).action
            == .speak(text: "mind the --port flag", emotion: nil))
    }

    @Test("★ call's tail is never scanned for --port — a port inside the JSON is data, not the flag")
    func callTailIsVerbatim() throws {
        // Unquoted JSON is rejoined from the shell's words; a `--port 8080` in a
        // note's text must land in the note, not redirect the CLI's own port.
        let command = try parsed([
            "call", "remember", "{\"title\":\"Router\",\"text\":\"forward", "--port", "8080", "to", "the", "NAS\"}",
        ])
        #expect(command.port == MCPEndpoint.defaultPort)
        #expect(command.action == .call(
            tool: "remember",
            argumentsJSON: "{\"title\":\"Router\",\"text\":\"forward --port 8080 to the NAS\"}"
        ))
        // The global flag still works where it belongs: in front of the subcommand.
        #expect(try parsed(["--port", "5000", "call", "get_status"])
            == CLICommand(action: .call(tool: "get_status", argumentsJSON: nil), port: 5000))
        #expect(try parsed(["--port=5000", "call", "get_status"]).port == 5000)
    }

    @Test("★ --port is the flag only when its value is a number — the rest is words")
    func portOnlyWhenNumeric() throws {
        // The line that started this rule: a real question that says --port.
        let asking = try parsed(["ask", "what's", "my", "--port", "forwarding", "setup"])
        #expect(asking.action == .ask("what's my --port forwarding setup"))
        #expect(asking.port == MCPEndpoint.defaultPort)
        // A numeric value IS the port, on either side of the subcommand.
        #expect(try parsed(["ask", "hi", "--port", "5000"]) == CLICommand(action: .ask("hi"), port: 5000))
        #expect(try parsed(["--port", "5000", "ask", "hi"]) == CLICommand(action: .ask("hi"), port: 5000))
        // Numeric but unusable stays the typo the user can see and fix.
        #expect(try failure(["ask", "--port", "70"]).message.contains("--port"))
        // `--port=…` is never prose, so a bad value there is always an error.
        #expect(try failure(["ask", "--port=banana"]).message.contains("--port"))
        // A subcommand that carries no text has nothing for it to be text OF.
        #expect(try failure(["status", "--port"]).message.contains("--port"))
        #expect(try failure(["status", "--port", "forwarding"]).message.contains("--port"))
    }

    @Test("the endpoint is loopback, always")
    func endpoint() {
        #expect(MCPEndpoint.url(port: 4242) == "http://127.0.0.1:4242/mcp")
        #expect(MCPEndpoint.url(port: 5111) == "http://127.0.0.1:5111/mcp")
    }
}
