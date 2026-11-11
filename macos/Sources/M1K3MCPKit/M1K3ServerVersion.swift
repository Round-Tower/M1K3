//
//  M1K3ServerVersion.swift
//  M1K3MCPKit
//
//  What the MCP server says its version is in the `initialize` reply. The app
//  passes its own bundle's version and build, so a client can ask the RUNNING
//  process which build it is: `tools/asc/verify_build.py` reads it before a
//  build is stamped for submission (#491). The old check compared the process
//  start time with the binary's mtime, which installers preserve, so a stale
//  process could pass.
//
//  The shape is semver with build metadata, `1.4.0+546`. Anything that is not a
//  plain version and a plain build number reports the fallback, so a reader
//  either gets a build it can trust or none.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.8, Prior: none (new
//  file; the static "0.1.0" it replaces was `makeM1K3Server`'s default).
//  Open: the build number is public to any client holding the MCP token, which
//  already reads memory. Brain at Home's scoped server keeps the fallback.
//

import Foundation

public enum M1K3ServerVersion {
    /// What a process with no app bundle reports (the stdio binary, `swift test`).
    public static let fallback = "0.1.0"

    public static func string(marketing: String?, build: String?) -> String {
        guard let marketing, let build, !build.isEmpty, build.allSatisfy(\.isASCIIDigit),
              !marketing.isEmpty, marketing.allSatisfy({ $0.isASCIIDigit || $0 == "." })
        else { return fallback }
        return "\(marketing)+\(build)"
    }

    public static func string(info: [String: Any]) -> String {
        string(marketing: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String)
    }

    /// The running app's own version and build.
    public static var current: String {
        string(info: Bundle.main.infoDictionary ?? [:])
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
