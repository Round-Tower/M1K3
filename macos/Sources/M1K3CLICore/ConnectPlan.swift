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

    public static func plan(client: MCPClient, url: String, configDir: URL) -> ConnectPlan {
        switch client {
        case .claude:
            // -s user: available in every project, which is the point of a
            // resident. `claude mcp add` is idempotent for the same name.
            .shell(command: ["claude", "mcp", "add", "--transport", "http", "-s", "user", serverName, url])
        case .cursor:
            .jsonMerge(path: configDir.appendingPathComponent(".cursor/mcp.json")) { existing in
                setting(existing, section: "mcpServers", entry: ["url": url])
            }
        case .vscode:
            .jsonMerge(
                path: configDir.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
            ) { existing in
                setting(existing, section: "servers", entry: ["type": "http", "url": url])
            }
        case .codex:
            .printOnly(
                snippet: snippet(client: .codex, url: url),
                note: "Add that to \(configDir.appendingPathComponent(".codex/config.toml").path)"
            )
        case .zed:
            .printOnly(
                snippet: snippet(client: .zed, url: url),
                note: "Add that to \(configDir.appendingPathComponent(".config/zed/settings.json").path) — "
                    + "check the shape against your Zed version."
            )
        }
    }

    /// The paste-ready form for EVERY client — what Settings shows, and what
    /// `--print` prints. Kept beside `plan` so the two can't disagree.
    public static func snippet(client: MCPClient, url: String) -> String {
        switch client {
        case .claude:
            "claude mcp add --transport http -s user \(serverName) \(url)"
        case .codex:
            "[mcp_servers.\(serverName)]\nurl = \"\(url)\""
        case .cursor:
            """
            {
              "mcpServers": {
                "\(serverName)": { "url": "\(url)" }
              }
            }
            """
        case .vscode:
            """
            {
              "servers": {
                "\(serverName)": { "type": "http", "url": "\(url)" }
              }
            }
            """
        case .zed:
            """
            "context_servers": {
              "\(serverName)": { "url": "\(url)" }
            }
            """
        }
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
        entry: [String: String]
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
