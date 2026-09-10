//
//  main.swift
//  m1k3 — the M1K3 command-line client
//
//  Parse, run, exit. `m1k3` is a THIN CLIENT of the running Mac app: it starts
//  no model, opens no store, and holds no state. The app is the daemon — there
//  is one MLX slot on this machine and it belongs to M1K3.app.
//
//  The binary ships inside the bundle at M1K3.app/Contents/MacOS/m1k3, which
//  is where the Homebrew cask symlinks from, and where the app's own Settings
//  points people. That's also why `version` reads the bundle's Info.plist two
//  levels up: the CLI and the app it talks to are the same release, by
//  construction, and saying so out loud is cheaper than a second version pin.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.85 (parse/exit
//  wiring is trivial and driven live; the version lookup is verify-by-run from
//  inside a built bundle). Prior: Unknown.
//

import Foundation
import M1K3CLICore

/// MARKETING_VERSION off the enclosing app bundle — Contents/MacOS/m1k3 →
/// Contents/Info.plist. "dev" when the binary is run from a build directory
/// rather than an installed bundle.
func appVersion() -> String {
    let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        .resolvingSymlinksInPath()
    let plist = executable
        .deletingLastPathComponent() // …/Contents/MacOS
        .deletingLastPathComponent() // …/Contents
        .appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let version = info["CFBundleShortVersionString"] as? String
    else { return "dev" }
    return version
}

let environment = ProcessInfo.processInfo.environment

switch CLICommand.parse(Array(CommandLine.arguments.dropFirst()), environment: environment) {
case let .success(command):
    let runner = CommandRunner(command: command, environment: environment, appVersion: appVersion())
    exit(await runner.run())
case let .failure(error):
    Output.error("m1k3: \(error.message)")
    Output.error("")
    Output.error(error.usage)
    exit(ExitCode.usage)
}
