//
//  MemoryKindGlyph.swift
//  M1K3Memory
//
//  The SF Symbol a memory row wears for its kind, so the Memories list reads
//  what each fact IS at a glance instead of a brain on every row (launch snag
//  list, 2026-09-12). Kept beside the kind vocabulary (not in the app) so the
//  mapping is test-pinned and the iOS shell can share it.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.9, Prior: Unknown
//

public extension MemoryKind {
    /// The symbol for this kind; an uncatalogued kind falls back to the brain.
    var symbolName: String {
        switch self {
        case .profile: "person.crop.circle"
        case .preference: "heart"
        case .decision: "checkmark.seal"
        case .episode: "clock"
        case .note: "note.text"
        default: "brain"
        }
    }
}
