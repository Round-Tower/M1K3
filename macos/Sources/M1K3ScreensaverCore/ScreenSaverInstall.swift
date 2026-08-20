//
//  ScreenSaverInstall.swift
//  M1K3ScreensaverCore
//
//  The pure side of installing the M1K3 screensaver from inside the app. M1K3
//  is app-sandboxed, so it CANNOT write to ~/Library/Screen Savers/ directly —
//  the app ships the .saver as an embedded resource and hands it to macOS via
//  NSWorkspace.open, which shows the system's native "Install screen saver?"
//  prompt (that write lives outside the sandbox, in the system UI). This helper
//  is the testable part: where the installed copy would live and whether it's
//  there yet, plus the status copy. The NSWorkspace open + deep-link are glue.
//
//  Signed: Kev + claude-opus-4-8, 2026-08-20, Confidence 0.85 (pure path/status
//  logic, TDD'd; the actual install is the OS prompt, verify-by-launch). Prior:
//  the screensaver core (this session).
//

import Foundation

public enum ScreenSaverInstall {
    /// The default installed file name (matches what the app embeds + the DMG
    /// install path). CFBundleName is "M1K3", so the picker shows "M1K3".
    public static let fileName = "M1K3.saver"

    /// The per-user Screen Savers directory: ~/Library/Screen Savers. Passing
    /// `home` explicitly keeps this pure/testable (no reliance on the process's
    /// real home). Note the space — it's "Screen Savers", the macOS convention.
    public static func userScreenSaversDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Screen Savers", isDirectory: true)
    }

    /// Where the user's installed copy lives once macOS accepts the prompt.
    public static func installedURL(home: URL, name: String = fileName) -> URL {
        userScreenSaversDirectory(home: home).appendingPathComponent(name, isDirectory: true)
    }

    /// Whether an installed copy is already present.
    public static func isInstalled(
        home: URL, name: String = fileName, fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: installedURL(home: home, name: name).path)
    }

    /// One-line status for the Settings row.
    public static func statusText(installed: Bool) -> String {
        installed
            ? "Installed — choose “M1K3” in System Settings ▸ Screen Saver."
            : "Not set up yet. One tap adds it to your Mac."
    }

    /// The button's call to action, which changes once it's installed.
    public static func actionTitle(installed: Bool) -> String {
        installed ? "Re-install Screen Saver" : "Set Up Screen Saver…"
    }
}
