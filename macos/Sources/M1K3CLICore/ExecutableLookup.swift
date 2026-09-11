//
//  ExecutableLookup.swift
//  M1K3CLICore
//
//  Where `m1k3 connect claude` finds the `claude` binary before running it.
//
//  This lives in the package, not beside the caller, for one reason: the
//  executable target has no tests, and a PATH search that silently reads
//  `ProcessInfo` is exactly the kind of ambient dependency that looks right
//  and isn't. Both inputs — the environment and the home directory — are
//  parameters with no defaults, so a caller has to say whose machine it means.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.9 (lifted from
//  CommandRunner.locate unchanged except for the injected home; pinned by
//  tests against real files on a temp PATH). Prior: Unknown.
//

import Foundation

/// Finding a client's own CLI on this machine.
public enum ExecutableLookup {
    /// The two places a coding-agent CLI lands that a GUI-launched process's
    /// PATH usually misses — a `.app` inherits launchd's PATH, not the shell's.
    public static let extraDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The first executable named `tool` on `environment["PATH"]`, then in
    /// `<home>/.local/bin` and the Homebrew prefixes. nil when there is none.
    ///
    /// Relative and empty PATH entries are skipped on purpose: an empty entry
    /// is POSIX shorthand for ".", so honouring it would run whatever `claude`
    /// the current directory happens to contain.
    public static func locate(_ tool: String, environment: [String: String], home: String) -> URL? {
        let searchPath = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            + ["\(home)/.local/bin"] + extraDirectories
        for directory in searchPath where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
