//
//  ConnectPlan.swift
//  M1K3CLICore
//
//  How M1K3 wires itself into each coding agent. One shape per client, because
//  the five of them genuinely differ: Claude Code owns its own registry behind
//  a CLI, Cursor and VS Code keep a JSON file we can edit safely, and Codex
//  (TOML) and Zed (a settings schema that has moved more than once) get printed
//  for the user to paste. Printing is not a lesser outcome — an editor's whole
//  settings file is the wrong thing for a tool to rewrite on a hunch.
//
//  Settings renders `snippet(client:url:)` for every client, so the paste-ready
//  form and the executed form come from the same place and cannot drift.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.85 (each shape is
//  the client's documented one and test-pinned; Zed's is the least stable,
//  which is exactly why its plan prints and its note says so). Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-09-11 — `shellSaysAlreadyConnected`
//  moved here from the executable so it can be pinned, and anchored on the
//  server NAME: a duplicate `m1k3` reads as already connected, any other thing
//  that "already exists" stays a real failure (PR #279 review). Confidence now 0.85.
//  Review: Kev + claude-opus-5-5, 2026-09-28 — #380: a JSONC config (comments, trailing commas) is named as such in the refusal
//  (`looksLikeJSONC`, message only; a URL's `//` isn't a comment). Confidence 0.85.
//  Review: Kev + claude-opus-5-5, 2026-09-28 — #270 slice 3: every plan and snippet carries
//  the access token as an `Authorization: Bearer` header, in each client's own shape. A
//  Claude Code entry that already exists is REPLACED (`replaceCommand`), because a pre-token
//  entry is not "already connected" any more. Settings passes a masked token to show and the
//  real one to Copy. Confidence 0.85 (Codex's `http_headers` and Zed's `headers` are their
//  documented shapes, not driven here).
//

import Foundation

/// What connecting a given client means.
public enum ConnectPlan {
    /// Run this — the client owns its own registry (Claude Code).
    case shell(command: [String])
    /// Edit this JSON config in place, keeping everything else in it.
    case jsonMerge(path: URL, merge: ([String: Any]) -> [String: Any])
    /// Show this and get out of the way.
    case printOnly(snippet: String, note: String)

    /// The server name M1K3 registers under, in every client.
    public static let serverName = "m1k3"

    public static func plan(client: MCPClient, url: String, token: String, configDir: URL) -> ConnectPlan {
        let headers = [MCPAccessToken.headerName: MCPAccessToken.headerValue(token)]
        switch client {
        case .claude:
            // -s user: available in every project, which is the point of a
            // resident. The token rides in argv for the moment `claude` runs;
            // it lands in Claude Code's own config either way (#270).
            return .shell(command: [
                "claude", "mcp", "add", "--transport", "http", "-s", "user", serverName, url,
                "--header", "\(MCPAccessToken.headerName): \(MCPAccessToken.headerValue(token))",
            ])
        case .cursor:
            return .jsonMerge(path: configDir.appendingPathComponent(".cursor/mcp.json")) { existing in
                setting(existing, section: "mcpServers", entry: ["url": url, "headers": headers])
            }
        case .vscode:
            return .jsonMerge(
                path: configDir.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
            ) { existing in
                setting(existing, section: "servers", entry: ["type": "http", "url": url, "headers": headers])
            }
        case .codex:
            return .printOnly(
                snippet: snippet(client: .codex, url: url, token: token),
                note: "Add that to \(configDir.appendingPathComponent(".codex/config.toml").path)"
            )
        case .zed:
            return .printOnly(
                snippet: snippet(client: .zed, url: url, token: token),
                note: "Add that to \(configDir.appendingPathComponent(".config/zed/settings.json").path) — "
                    + "check the shape against your Zed version."
            )
        }
    }

    /// The paste-ready form for EVERY client — what Settings shows, and what
    /// `--print` prints. Kept beside `plan` so the two can't disagree.
    /// Settings renders it with `MCPAccessToken.masked(token)` and copies it
    /// with the real one, so the screen never shows a usable token.
    public static func snippet(client: MCPClient, url: String, token: String) -> String {
        let bearer = MCPAccessToken.headerValue(token)
        switch client {
        case .claude:
            return "claude mcp add --transport http -s user \(serverName) \(url) --header \"Authorization: \(bearer)\""
        case .codex:
            return "[mcp_servers.\(serverName)]\nurl = \"\(url)\"\nhttp_headers = { \"Authorization\" = \"\(bearer)\" }"
        case .cursor:
            return """
            {
              "mcpServers": {
                "\(serverName)": {
                  "url": "\(url)",
                  "headers": { "Authorization": "\(bearer)" }
                }
              }
            }
            """
        case .vscode:
            return """
            {
              "servers": {
                "\(serverName)": {
                  "type": "http",
                  "url": "\(url)",
                  "headers": { "Authorization": "\(bearer)" }
                }
              }
            }
            """
        case .zed:
            return """
            "context_servers": {
              "\(serverName)": {
                "url": "\(url)",
                "headers": { "Authorization": "\(bearer)" }
              }
            }
            """
        }
    }

    /// What clears a client's existing `m1k3` entry so `plan` can write the
    /// current one. Only Claude Code needs it: its `mcp add` refuses a name
    /// that exists, where the JSON clients' merge simply replaces the entry.
    public static func replaceCommand(client: MCPClient) -> [String]? {
        client == .claude ? ["claude", "mcp", "remove", "-s", "user", serverName] : nil
    }

    /// Did a client's own registration command refuse because a server called
    /// `serverName` is ALREADY registered? Current `claude mcp add` exits
    /// non-zero on a duplicate name. Since the token (#270) that entry may be
    /// a stale one without it, so the runner replaces it (`replaceCommand`)
    /// and adds again. Anchored on the name: some other thing that "already
    /// exists" is a real failure, not ours.
    public static func shellSaysAlreadyConnected(_ stderr: String, serverName: String = Self.serverName) -> Bool {
        let lowered = stderr.lowercased()
        guard lowered.contains(serverName.lowercased()) else { return false }
        return lowered.contains("already exists") || lowered.contains("already configured")
    }

    /// Where that snippet belongs, in the form a person recognises. Shown as
    /// the caption under the snippet in Settings.
    public static func destination(client: MCPClient) -> String {
        switch client {
        case .claude: "Run it in Terminal"
        case .codex: "~/.codex/config.toml"
        case .cursor: "~/.cursor/mcp.json"
        case .vscode: "~/Library/Application Support/Code/User/mcp.json"
        case .zed: "~/.config/zed/settings.json"
        }
    }

    /// Put `entry` at `section.m1k3`, leaving every other key — and every
    /// other server in that section — exactly as it was.
    private static func setting(
        _ existing: [String: Any],
        section: String,
        entry: [String: Any]
    ) -> [String: Any] {
        var root = existing
        var servers = root[section] as? [String: Any] ?? [:]
        servers[serverName] = entry
        root[section] = servers
        return root
    }
}

/// Applies a `.jsonMerge` plan to disk — the only part of `connect` that
/// touches a file the user owns, so it is deliberately conservative: never
/// writes over something it could not parse, keeps one backup of the original,
/// and says "already connected" rather than reformatting a file for nothing.
public enum JSONConfigWriter {
    public enum Outcome: Equatable, Sendable {
        case written(path: URL, backup: URL?)
        case unchanged
    }

    /// A `//` or `/*` comment, or a comma right before a closing bracket: the JSON-with-
    /// comments dialect editors write. A heuristic for the message only; the file is
    /// refused either way.
    static func looksLikeJSONC(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        // A `//` straight after a colon is a URL's scheme (`https://`), not a comment (#445 review).
        return text.range(of: #"(^|[^:])//"#, options: .regularExpression) != nil || text.contains("/*")
            || text.range(of: #",\s*[}\]]"#, options: .regularExpression) != nil
    }

    public struct WriteError: Error, Equatable, Sendable {
        public let message: String
        public init(_ message: String) {
            self.message = message
        }
    }

    public static func apply(_ plan: ConnectPlan) throws -> Outcome {
        guard case let .jsonMerge(declaredPath, merge) = plan else {
            throw WriteError("that client isn't configured by editing a JSON file")
        }

        // ★ Follow symlinks to the real file. A dotfiles-managed config is a
        // link into ~/dotfiles; `copyItem` would copy the LINK as a link and
        // the atomic write would REPLACE it with a plain file — the config
        // silently stops being managed, and the next `stow` diverges. Resolving
        // first means we back up and write the file the user actually keeps.
        let path = declaredPath.resolvingSymlinksInPath()
        let manager = FileManager.default
        let existing: [String: Any]
        let alreadyThere = manager.fileExists(atPath: path.path)
        if alreadyThere {
            let data = try Data(contentsOf: path)
            // An empty file is a fresh start, not a parse failure.
            if data.isEmpty {
                existing = [:]
            } else {
                let parsed: Any
                do {
                    parsed = try JSONSerialization.jsonObject(with: data)
                } catch {
                    // VS Code's mcp.json routinely carries comments and trailing commas (#380):
                    // a valid file there, so name it rather than calling it broken.
                    if JSONConfigWriter.looksLikeJSONC(data) {
                        throw WriteError(
                            "\(path.path) has comments or trailing commas — m1k3 won't rewrite it; paste the snippet below"
                        )
                    }
                    throw WriteError("\(path.path) isn't valid JSON (\(error.localizedDescription)) — left untouched")
                }
                guard let object = parsed as? [String: Any] else {
                    throw WriteError("\(path.path) isn't a JSON object — left untouched")
                }
                existing = object
            }
        } else {
            existing = [:]
        }

        let merged = merge(existing)
        // Compare the VALUES, not the bytes: a file the user hand-formatted is
        // already connected, and rewriting it just to sort its keys would be
        // rude and would make `connect` look non-idempotent.
        if alreadyThere, NSDictionary(dictionary: merged).isEqual(to: existing) { return .unchanged }

        var backup: URL?
        if alreadyThere {
            let candidate = URL(fileURLWithPath: path.path + ".bak")
            // Keep the PRISTINE original: a second run must not overwrite the
            // backup with an already-modified copy.
            if !manager.fileExists(atPath: candidate.path) {
                try manager.copyItem(at: path, to: candidate)
                backup = candidate
            }
        }

        try manager.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var data = try JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A) // trailing newline — someone edits this file by hand
        try data.write(to: path, options: .atomic)
        return .written(path: path, backup: backup)
    }
}
