// screens.swift: one line per NSScreen, "<index> <notch 0|1> <width>x<height> <name>".
// A notch is a safe-area inset at the top (NSScreen.safeAreaInsets.top > 0). Used by hud-capture.sh.
// Signed: Kev + claude-opus-5.5, 2026-11-05, Confidence 0.8, Prior: none (new file).
import AppKit

for (i, s) in NSScreen.screens.enumerated() {
    let notch = s.safeAreaInsets.top > 0 ? 1 : 0
    print(i, notch, "\(Int(s.frame.width))x\(Int(s.frame.height))", s.localizedName)
}
