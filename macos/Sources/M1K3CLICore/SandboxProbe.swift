//
//  SandboxProbe.swift
//  M1K3CLICore
//
//  Is this copy of `m1k3` sandboxed? It matters because a sandboxed helper
//  cannot write another app's config file — and, worse, will happily write one
//  INSIDE its own container and report success. `~/.cursor/mcp.json` resolved
//  through a redirected home becomes
//  `~/Library/Containers/app.m1k3.cli/Data/.cursor/mcp.json`, which Cursor will
//  never read.
//
//  The obvious check — APP_SANDBOX_CONTAINER_ID — is injected by launchd, so a
//  sandboxed helper launched from a Terminal (the documented route: run the
//  binary inside M1K3.app) does NOT have it. The reliable signal is the home
//  directory: the sandbox redirects it, the password database still knows the
//  real one.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.85 (the comparison is
//  pinned; the live getpwuid read that feeds it is verify-by-run — see
//  CommandRunner). Prior: Unknown.
//

import Foundation

public enum SandboxProbe {
    public static let containerEnvironmentKey = "APP_SANDBOX_CONTAINER_ID"

    /// - Parameters:
    ///   - home: what this process thinks its home is (`FileManager`'s).
    ///   - realHome: the account's actual home from the password database, or
    ///     nil when it can't be read — which is not evidence of anything, so
    ///     it is never treated as a sandbox on its own.
    public static func isSandboxed(
        home: String,
        realHome: String?,
        environment: [String: String]
    ) -> Bool {
        if environment[containerEnvironmentKey] != nil { return true }
        guard let realHome else { return false }
        return standardised(home) != standardised(realHome)
    }

    private static func standardised(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}
