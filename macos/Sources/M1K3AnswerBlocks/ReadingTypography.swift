//
//  ReadingTypography.swift
//  M1K3AnswerBlocks
//
//  The numbers behind a chat answer's type: size, line spacing, letter spacing,
//  the gap between paragraphs and the inset inside the bubble. One table, so the
//  chat, the Settings preview and the answer cards cannot drift apart, and so the
//  numbers can be pinned by tests (the views that read them cannot be).
//
//  The Mac: the system's body style is 13 pt and does not follow a text-size
//  setting, which is small for long answers. Every face reads at 15 pt or more
//  there, with looser lines and letters. Touch keeps the system's body style, so
//  Dynamic Type still governs the size on iPhone, iPad and Vision Pro.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.7, Prior: none (new
//  file; the touch values are ReadingText's own from before this change).
//  Context: Kev, 2026-11-12, on a Mac chat screenshot in the serif face: "the font
//  size particularly on Mac - I think it needs to be bigger, with better kerning,
//  and more padding on the border".
//  Open: the Mac numbers are a first pick, judged by eye on one screen; a
//  text-size control in Settings is the next step if one size does not fit.

import CoreGraphics

public struct ReadingTypography: Equatable, Sendable {
    /// The typeface family, mirroring the app's `ReadingMode`.
    public enum Face: Sendable {
        case standard, serif, dyslexia, bionic
    }

    /// Where the text is read: a Mac window, or a touch shell (iOS, visionOS).
    public enum Idiom: Sendable {
        case mac, touch

        public static var current: Idiom {
            #if os(macOS)
                .mac
            #else
                .touch
            #endif
        }
    }

    /// The body size in points; `nil` means the system's body text style.
    public let bodySize: CGFloat?
    public let lineSpacing: CGFloat
    public let tracking: CGFloat
    /// The gap between two blocks (paragraphs, lists, headings).
    public let paragraphSpacing: CGFloat
    /// The inset between a bubble's edge and its text.
    public let insetHorizontal: CGFloat
    public let insetVertical: CGFloat
    private let headingSizes: [CGFloat]

    /// A heading's size for markdown levels 1 to 6; an unknown level reads as body-sized.
    public func headingSize(level: Int) -> CGFloat {
        guard (1 ... headingSizes.count).contains(level) else { return headingSizes.last ?? 15 }
        return headingSizes[level - 1]
    }

    public static func resolve(_ face: Face, on idiom: Idiom = .current) -> ReadingTypography {
        switch (idiom, face) {
        case (.mac, .dyslexia):
            ReadingTypography(
                bodySize: 16, lineSpacing: 8, tracking: 0.6, paragraphSpacing: 14,
                insetHorizontal: 18, insetVertical: 14, headingSizes: [24, 21, 19, 17, 16, 16]
            )
        case (.mac, _):
            ReadingTypography(
                bodySize: 15, lineSpacing: 5, tracking: 0.2, paragraphSpacing: 12,
                insetHorizontal: 18, insetVertical: 14, headingSizes: [23, 20, 18, 16, 15, 15]
            )
        case (.touch, .dyslexia):
            ReadingTypography(
                bodySize: 15, lineSpacing: 6, tracking: 0.5, paragraphSpacing: 8,
                insetHorizontal: 12, insetVertical: 8, headingSizes: [22, 19, 17, 15, 14, 13]
            )
        case (.touch, _):
            ReadingTypography(
                bodySize: nil, lineSpacing: 2, tracking: 0, paragraphSpacing: 8,
                insetHorizontal: 12, insetVertical: 8, headingSizes: [22, 19, 17, 15, 14, 13]
            )
        }
    }
}
