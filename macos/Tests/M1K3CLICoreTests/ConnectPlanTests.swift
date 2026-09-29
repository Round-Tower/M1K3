//
//  ConnectPlanTests.swift
//  M1K3CLICoreTests
//
//  What `m1k3 connect <client>` actually does, per client, and the JSON writer
//  behind the two clients whose config we edit. The writer's tests all run in
//  a temp directory: `swift test` here is UNSANDBOXED, and a test that wrote
//  to the real ~/.cursor/mcp.json would be a bug shipped as a test.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.85 (the shapes are
//  each client's documented one; Zed's is the least stable, which is why its
//  plan prints rather than writes). Prior: Unknown.
//

import Foundation
@testable import M1K3CLICore
import Testing

struct ConnectPlanTests {
    @Test("`claude mcp add` refusing a duplicate NAME reads as already connected — anchored on the name")
    func claudeDuplicateIsAlreadyConnected() {
        #expect(ConnectPlan.shellSaysAlreadyConnected("MCP server m1k3 already exists in user config"))
        #expect(ConnectPlan.shellSaysAlreadyConnected("Error: m1k3 is already configured\n"))
        // Some other resource that "already exists" is a real failure, not our duplicate.
        #expect(!ConnectPlan.shellSaysAlreadyConnected("project config already exists at ~/.claude.json"))
        #expect(!ConnectPlan.shellSaysAlreadyConnected(""))
    }

    private let url = MCPEndpoint.url(port: 4242)
    private let token = "m1k3_" + String(repeating: "T", count: 43)
    private var bearer: String {
        "Bearer \(token)"
    }

    /// Resolved (/var → /private/var) so path equality survives the writer's
    /// own symlink resolution, and registered for teardown — `swift test` here
    /// is UNSANDBOXED, so tests clean up after themselves.
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("m1k3-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        temporaries.add(dir)
        return dir
    }

    /// Swift Testing builds a fresh suite instance per test, so this bag —
    /// and everything it holds — dies with the test that filled it.
    private let temporaries = TemporaryDirectories()

    private func jsonPlan(_ client: MCPClient, in dir: URL) throws -> (URL, ([String: Any]) -> [String: Any]) {
        guard case let .jsonMerge(path, merge) = ConnectPlan.plan(client: client, url: url, token: token, configDir: dir) else {
            throw CLIUsageError("expected a jsonMerge plan for \(client.rawValue)")
        }
        return (path, merge)
    }

    private func printedPlan(_ client: MCPClient, in dir: URL) throws -> (String, String) {
        guard case let .printOnly(snippet, note) = ConnectPlan.plan(client: client, url: url, token: token, configDir: dir) else {
            throw CLIUsageError("expected a printOnly plan for \(client.rawValue)")
        }
        return (snippet, note)
    }

    // MARK: - Plans

    @Test("Claude Code is a command we can run for the user")
    func claudePlan() throws {
        let dir = try temporaryDirectory()
        guard case let .shell(command) = ConnectPlan.plan(client: .claude, url: url, token: token, configDir: dir) else {
            Issue.record("expected a shell plan")
            return
        }
        #expect(command == [
            "claude", "mcp", "add", "--transport", "http", "-s", "user", "m1k3", url,
            "--header", "Authorization: \(bearer)",
        ])
        #expect(ConnectPlan.replaceCommand(client: .claude) == ["claude", "mcp", "remove", "-s", "user", "m1k3"])
        for client in MCPClient.allCases where client != .claude {
            #expect(ConnectPlan.replaceCommand(client: client) == nil, "\(client.rawValue) merges in place")
        }
    }

    @Test("Cursor gets an mcpServers entry in ~/.cursor/mcp.json")
    func cursorPlan() throws {
        let dir = try temporaryDirectory()
        let (path, merge) = try jsonPlan(.cursor, in: dir)
        #expect(path == dir.appendingPathComponent(".cursor/mcp.json"))
        let servers = try #require(merge([:])["mcpServers"] as? [String: Any])
        let entry = try #require(servers["m1k3"] as? [String: Any])
        #expect(entry["url"] as? String == url)
        #expect(entry["headers"] as? [String: String] == ["Authorization": bearer])
    }

    @Test("VS Code gets a typed servers entry under Application Support")
    func vscodePlan() throws {
        let dir = try temporaryDirectory()
        let (path, merge) = try jsonPlan(.vscode, in: dir)
        #expect(path == dir.appendingPathComponent("Library/Application Support/Code/User/mcp.json"))
        let servers = try #require(merge([:])["servers"] as? [String: Any])
        let entry = try #require(servers["m1k3"] as? [String: Any])
        #expect(entry["type"] as? String == "http")
        #expect(entry["url"] as? String == url)
        #expect(entry["headers"] as? [String: String] == ["Authorization": bearer])
    }

    @Test("a merge keeps the other servers already in the file")
    func mergeKeepsSiblings() throws {
        let dir = try temporaryDirectory()
        let (_, merge) = try jsonPlan(.cursor, in: dir)
        let existing: [String: Any] = [
            "mcpServers": ["other": ["command": "npx"]],
            "somethingElse": true,
        ]
        let merged = merge(existing)
        #expect(merged["somethingElse"] as? Bool == true)
        let servers = try #require(merged["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil)
        #expect(servers["m1k3"] != nil)
    }

    @Test("Codex prints TOML for its own config file")
    func codexPlan() throws {
        let dir = try temporaryDirectory()
        let (snippet, note) = try printedPlan(.codex, in: dir)
        #expect(snippet == "[mcp_servers.m1k3]\nurl = \"\(url)\"\nhttp_headers = { \"Authorization\" = \"\(bearer)\" }")
        #expect(note.contains(".codex/config.toml"))
    }

    @Test("Zed prints JSON and says out loud that the shape moves")
    func zedPlan() throws {
        let dir = try temporaryDirectory()
        let (snippet, note) = try printedPlan(.zed, in: dir)
        #expect(snippet.contains("context_servers"))
        #expect(snippet.contains(url))
        #expect(note.contains(".config/zed/settings.json"))
        #expect(note.lowercased().contains("check the shape against your zed version"))
    }

    @Test("every client has a paste-ready snippet that names the endpoint")
    func snippetForEveryClient() {
        for client in MCPClient.allCases {
            let snippet = ConnectPlan.snippet(client: client, url: url, token: token)
            #expect(snippet.contains(url), "\(client.rawValue) snippet lost the endpoint")
            #expect(snippet.contains(bearer), "\(client.rawValue) snippet lost the token")
            // What Settings shows: the masked token, never the real one.
            let shown = ConnectPlan.snippet(client: client, url: url, token: MCPAccessToken.masked(token))
            #expect(!shown.contains(token), "\(client.rawValue) showed the token")
            #expect(!snippet.isEmpty)
            #expect(!ConnectPlan.destination(client: client).isEmpty)
        }
        #expect(ConnectPlan.snippet(client: .claude, url: url, token: token)
            == "claude mcp add --transport http -s user m1k3 \(url) --header \"Authorization: \(bearer)\"")
    }

    // MARK: - The writer

    @Test("a config that doesn't exist yet is created, directories and all")
    func writesFresh() throws {
        let dir = try temporaryDirectory()
        let (path, _) = try jsonPlan(.vscode, in: dir)
        let outcome = try JSONConfigWriter.apply(ConnectPlan.plan(client: .vscode, url: url, token: token, configDir: dir))
        #expect(outcome == .written(path: path, backup: nil))
        let written = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        )
        let servers = try #require(written["servers"] as? [String: Any])
        let entry = try #require(servers["m1k3"] as? [String: Any])
        #expect(entry["type"] as? String == "http")
        #expect(entry["url"] as? String == url)
        #expect(entry["headers"] as? [String: String] == ["Authorization": bearer], "the token is on disk too")
    }

    @Test("an existing config keeps its contents and gains a backup")
    func writesIntoExisting() throws {
        let dir = try temporaryDirectory()
        let (path, _) = try jsonPlan(.cursor, in: dir)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"mcpServers":{"other":{"command":"npx"}}}"#.utf8).write(to: path)

        let outcome = try JSONConfigWriter.apply(ConnectPlan.plan(client: .cursor, url: url, token: token, configDir: dir))
        guard case let .written(writtenPath, backup) = outcome else {
            Issue.record("expected a write, got \(outcome)")
            return
        }
        #expect(writtenPath == path)
        let backupURL = try #require(backup)
        #expect(backupURL.lastPathComponent == "mcp.json.bak")
        #expect(try String(contentsOf: backupURL, encoding: .utf8).contains("npx"))

        let written = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        )
        let servers = try #require(written["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil)
        #expect(servers["m1k3"] != nil)
    }

    @Test("a stale endpoint is replaced, not duplicated")
    func replacesExistingEntry() throws {
        let dir = try temporaryDirectory()
        let (path, _) = try jsonPlan(.cursor, in: dir)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"mcpServers":{"m1k3":{"url":"http://127.0.0.1:9999/mcp"}}}"#.utf8).write(to: path)

        _ = try JSONConfigWriter.apply(ConnectPlan.plan(client: .cursor, url: url, token: token, configDir: dir))
        let written = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        )
        let servers = try #require(written["mcpServers"] as? [String: Any])
        let entry = try #require(servers["m1k3"] as? [String: Any])
        #expect(entry["url"] as? String == url)
        #expect(servers.count == 1)
    }

    @Test("#270: a pre-token entry gains the header — it is not 'already connected'")
    func preTokenEntryGainsHeader() throws {
        let dir = try temporaryDirectory()
        let (path, _) = try jsonPlan(.cursor, in: dir)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"mcpServers":{"m1k3":{"url":"\#(url)"}}}"#.utf8).write(to: path)

        let outcome = try JSONConfigWriter.apply(ConnectPlan.plan(client: .cursor, url: url, token: token, configDir: dir))
        guard case .written = outcome else {
            Issue.record("expected a write, got \(outcome)")
            return
        }
        let written = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        )
        let entry = try #require((written["mcpServers"] as? [String: Any])?["m1k3"] as? [String: Any])
        #expect(entry["headers"] as? [String: String] == ["Authorization": bearer])
        // A new token replaces the old header rather than failing as a duplicate.
        let rotated = "m1k3_" + String(repeating: "R", count: 43)
        _ = try JSONConfigWriter.apply(ConnectPlan.plan(client: .cursor, url: url, token: rotated, configDir: dir))
        let again = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        )
        let rotatedEntry = try #require((again["mcpServers"] as? [String: Any])?["m1k3"] as? [String: Any])
        #expect(rotatedEntry["headers"] as? [String: String] == ["Authorization": "Bearer \(rotated)"])
    }

    @Test("running connect twice is unchanged the second time")
    func idempotent() throws {
        let dir = try temporaryDirectory()
        let plan = { ConnectPlan.plan(client: .cursor, url: self.url, token: self.token, configDir: dir) }
        _ = try JSONConfigWriter.apply(plan())
        #expect(try JSONConfigWriter.apply(plan()) == .unchanged)
    }

    @Test("a config that isn't a JSON object is refused, and nothing is written")
    func refusesNonObject() throws {
        let dir = try temporaryDirectory()
        let (path, _) = try jsonPlan(.cursor, in: dir)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original = "# not json at all\n"
        try Data(original.utf8).write(to: path)

        #expect(throws: JSONConfigWriter.WriteError.self) {
            _ = try JSONConfigWriter.apply(ConnectPlan.plan(client: .cursor, url: url, token: token, configDir: dir))
        }
        #expect(try String(contentsOf: path, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: path.path + ".bak"))
    }

    @Test("the writer refuses a plan that isn't a file merge")
    func refusesWrongPlan() throws {
        let dir = try temporaryDirectory()
        #expect(throws: JSONConfigWriter.WriteError.self) {
            _ = try JSONConfigWriter.apply(ConnectPlan.plan(client: .claude, url: url, token: token, configDir: dir))
        }
    }

    @Test("what lands on disk is pretty, sorted, and readable — someone has to edit it later")
    func writesReadableJSON() throws {
        let dir = try temporaryDirectory()
        let (path, _) = try jsonPlan(.vscode, in: dir)
        _ = try JSONConfigWriter.apply(ConnectPlan.plan(client: .vscode, url: url, token: token, configDir: dir))
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.contains("\n"))
        #expect(text.contains("http://127.0.0.1:4242/mcp"))
        #expect(!text.contains("\\/"))
        #expect(text.hasSuffix("\n"))
    }

    // MARK: - Files the user actually owns

    @Test("★ a symlinked config keeps its link — dotfiles survive being connected")
    func followsSymlinks() throws {
        let dir = try temporaryDirectory()
        let real = dir.appendingPathComponent("dotfiles-cursor.json")
        try Data(#"{"mcpServers":{"other":{"command":"npx"}}}"#.utf8).write(to: real)
        let link = dir.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let outcome = try JSONConfigWriter.apply(ConnectPlan.plan(client: .cursor, url: url, token: token, configDir: dir))
        #expect(outcome == .written(path: real, backup: dir.appendingPathComponent("dotfiles-cursor.json.bak")))
        // The link is still a link, and the real file behind it gained the entry.
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        let written = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any]
        )
        let servers = try #require(written["mcpServers"] as? [String: Any])
        #expect(servers["m1k3"] != nil)
        #expect(servers["other"] != nil)
    }

    @Test("★ the backup is the PRISTINE original — a later write never overwrites it")
    func backupIsPristine() throws {
        let dir = try temporaryDirectory()
        let (path, _) = try jsonPlan(.cursor, in: dir)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"mcpServers":{"other":{"command":"npx"}}}"#.utf8).write(to: path)

        _ = try JSONConfigWriter.apply(ConnectPlan.plan(client: .cursor, url: url, token: token, configDir: dir))
        // A second, DIFFERENT write (the port moved) must not clobber the backup.
        _ = try JSONConfigWriter.apply(
            ConnectPlan.plan(client: .cursor, url: MCPEndpoint.url(port: 5111), token: token, configDir: dir)
        )
        let backup = try String(contentsOf: URL(fileURLWithPath: path.path + ".bak"), encoding: .utf8)
        #expect(backup.contains("npx"))
        #expect(!backup.contains("4242"))
    }

    @Test("a zero-byte config is a fresh start, not a parse failure")
    func emptyFile() throws {
        let dir = try temporaryDirectory()
        let (path, _) = try jsonPlan(.cursor, in: dir)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: path)

        let outcome = try JSONConfigWriter.apply(ConnectPlan.plan(client: .cursor, url: url, token: token, configDir: dir))
        guard case .written = outcome else {
            Issue.record("expected a write, got \(outcome)")
            return
        }
        let written = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        )
        #expect(written["mcpServers"] != nil)
    }
}

/// Thread-safe bag of directories to delete when a suite finishes.
private final class TemporaryDirectories: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func add(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    deinit {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// #380: VS Code's mcp.json routinely carries comments and trailing commas.
extension ConnectPlanTests {
    @Test("#445 review: a URL's // is not a comment — a broken file with a URL is just invalid JSON")
    func urlIsNotAComment() {
        #expect(!JSONConfigWriter.looksLikeJSONC(Data(#"{"servers": {"a": {"url": "https://x.example/mcp"}"#.utf8)))
        #expect(JSONConfigWriter.looksLikeJSONC(Data("{ // mine\n}".utf8)))
        #expect(JSONConfigWriter.looksLikeJSONC(Data("{\"a\": 1,\n}".utf8)))
        #expect(JSONConfigWriter.looksLikeJSONC(Data("/* x */ {}".utf8)))
    }

    @Test("#380: a JSONC config is named as such, left untouched, and the user told to paste")
    func jsoncNamed() throws {
        let dir = try temporaryDirectory()
        let (path, _) = try jsonPlan(.vscode, in: dir)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\n  // my servers\n  \"servers\": {},\n}\n"
        try Data(original.utf8).write(to: path)
        do {
            _ = try JSONConfigWriter.apply(ConnectPlan.plan(client: .vscode, url: url, token: token, configDir: dir))
            Issue.record("expected a refusal")
        } catch let error as JSONConfigWriter.WriteError {
            #expect(error.message.contains("comments"))
            #expect(!error.message.contains("isn't valid JSON"))
        }
        #expect(try String(contentsOf: path, encoding: .utf8) == original)
    }
}
