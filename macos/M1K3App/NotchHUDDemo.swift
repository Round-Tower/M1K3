//
//  NotchHUDDemo.swift
//  M1K3App
//
//  Debug-only HUD demo: `-hudDemo light|dark` pins NSApp.appearance and shows the notch HUD at launch
//  with a sample utterance, bypassing the main-window demand, until the process is killed. Paired with
//  `-hudDemoScreen N` (NSScreen.screens[N] instead of main) and `-hudDemoText "..."`. Driven by
//  tools/screengrab/direct/hud-capture.sh so Light/Dark, docked/notched can be checked without eyes.
//  The whole file is #if DEBUG; HUDDemoScanTests pins that every reference in M1K3App stays inside one.
//  Read like the other argv overrides: launch arguments land in UserDefaults' argument domain.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-05, Confidence 0.7 (compiles; behaviour is verify-by-launch,
//  not launched by me: Kev's live build was running). Prior: none (new file).
//

#if DEBUG
    import AppKit

    struct HUDDemoConfig {
        /// Long enough that the HUD's caption has to scroll.
        static let defaultText = "This is the notch HUD demo. M1K3 is reading a sentence that is long enough to scroll, "
            + "so the caption marquee, the avatar tile and the panel all show up in the capture."

        let appearanceName: NSAppearance.Name
        let screenIndex: Int?
        let text: String

        /// nil unless `-hudDemo light|dark` was passed.
        static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> HUDDemoConfig? {
            guard let mode = defaults.string(forKey: "hudDemo") else { return nil }
            let name: NSAppearance.Name = mode.lowercased() == "dark" ? .darkAqua : .aqua
            let index = defaults.object(forKey: "hudDemoScreen") == nil ? nil : defaults.integer(forKey: "hudDemoScreen")
            let text = defaults.string(forKey: "hudDemoText").flatMap { $0.isEmpty ? nil : $0 } ?? defaultText
            return HUDDemoConfig(appearanceName: name, screenIndex: index, text: text)
        }

        /// `NSScreen.screens[N]`, or nil (the caller falls back to main) when N is absent or out of range.
        var screen: NSScreen? {
            guard let screenIndex, NSScreen.screens.indices.contains(screenIndex) else { return nil }
            return NSScreen.screens[screenIndex]
        }
    }
#endif
