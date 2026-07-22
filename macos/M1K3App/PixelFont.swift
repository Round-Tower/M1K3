//
//  PixelFont.swift
//  M1K3App
//
//  M1K3's bundled type faces, registered at launch via CoreText so `Font.custom`
//  resolves them regardless of where the bundler drops the files in Resources:
//    • Silkscreen (OFL) — the pixel accent face for wordmark / accent moments.
//    • OpenDyslexic (OFL) — the optional "Dyslexia-friendly" reading mode.
//  Call sites are `Font.pixel(_:)` and `Font.dyslexic(_:)`.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-08, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-sonnet-4-6, 2026-06-08 — generalised the single-font
//  registrar into BundledFonts (Silkscreen + OpenDyslexic) for the reading modes.
//  Review: Kev + claude-fable-5, 2026-07-02, Confidence 0.85 — added Font.pixelTitle
//  (the shared 15pt title accent) and codified the house rules (12pt floor, no
//  dynamic user content, wordmark kerning) from the brand-typography sweep.

import CoreText
import SwiftUI

enum BundledFonts {
    /// Family names (for `Font.custom`).
    static let pixelFamily = "Silkscreen"
    static let dyslexicFamily = "OpenDyslexic"

    /// Every bundled face file (without extension) and its extension.
    private static let faces: [(name: String, ext: String)] = [
        ("Silkscreen-Regular", "ttf"),
        ("Silkscreen-Bold", "ttf"),
        ("OpenDyslexic-Regular", "otf"),
        ("OpenDyslexic-Bold", "otf"),
    ]

    /// Register all bundled faces. Idempotent — re-registering a URL is a no-op.
    static func register() {
        for face in faces {
            guard let url = Bundle.main.url(forResource: face.name, withExtension: face.ext) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Font {
    /// M1K3's pixel accent face. `fixedSize` keeps the pixels crisp (Dynamic Type
    /// scaling renders bitmap-style fonts fuzzy) — reserve it for short accents.
    ///
    /// House rules (a bitmap-style face degrades fast when misused):
    ///   • Floor at 12pt — below caption size Silkscreen turns to mush, so badges
    ///     (e.g. the "Recommended" capsule) stay system.
    ///   • Never on dynamic user content (conversation titles, file names) or
    ///     body/reading text — short app-controlled strings only.
    ///   • The wordmark pairs with `.kerning(2)` — 40pt as onboarding's hero,
    ///     28pt at caption volume (the chat empty state). 15pt titles stay
    ///     un-kerned (2pt of tracking at 15pt would be ~2.7× the hero's
    ///     letterspacing).
    ///   • Accepted trade-off: `fixedSize` opts these accents OUT of Dynamic
    ///     Type (scaling a bitmap-style face goes fuzzy). That's tolerable
    ///     precisely because usage is confined to short, decorative accents —
    ///     body/reading text (which must scale) never wears this face.
    static func pixel(_ size: CGFloat) -> Font {
        .custom(BundledFonts.pixelFamily, fixedSize: size)
    }

    /// Silkscreen section/card title — short accents only (card names, one-word
    /// sheet headers, the popover brain name). One size so every title moment
    /// wears the same face at the same volume.
    static var pixelTitle: Font {
        .pixel(15)
    }

    /// OpenDyslexic — the dyslexia-friendly reading face. Uses `size:` (not fixed)
    /// so it still scales with Dynamic Type for body reading.
    static func dyslexic(_ size: CGFloat) -> Font {
        .custom(BundledFonts.dyslexicFamily, size: size)
    }

    /// The bundled OpenDyslexic-Bold face, for markdown headings in dyslexia
    /// mode — `.dyslexic(_:).bold()` can't synthesize weight on a custom font,
    /// so headings need the dedicated bold face registered alongside it.
    static func dyslexicBold(_ size: CGFloat) -> Font {
        .custom("OpenDyslexic-Bold", size: size)
    }
}
