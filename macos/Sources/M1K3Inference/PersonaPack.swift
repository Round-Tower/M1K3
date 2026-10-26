//
//  PersonaPack.swift
//  M1K3Inference
//
//  The seam a persona pack would slot into (#698 Phase 1): the VOICE bullets and
//  the four exemplar MOVES, as data, over a core that stays the same for every
//  pack. One pack ships, `.default`, which is today's voice byte for byte. There is
//  no selection state, no UI and no second pack. Whether more than one voice beats
//  one is a preference question no eval here can answer yet (see #698), so it is
//  Kev's call.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.8 (the bytes are hash-pinned;
//  whether a second pack is ever worth shipping is unmeasured), Prior: none (new file)
//

/// The part of the persona a pack may change, and nothing else.
///
/// A pack brings two things. `voice` is the `# VOICE` section's bullets (the composer
/// writes the header). `exemplars` is the MOVE bullets under the shared exemplar header,
/// each `- <lead-in>: <reply>`, the shape `M1K3Persona.exemplarReplies(of:)` reads.
///
/// Everything else stays outside the pack, the same for every pack, for these reasons:
/// - ABSOLUTE RULES and HONESTY are the security and anti-fabrication spans. Every render
///   carries them byte for byte (`rulesKeepTheDeclineScoped`).
/// - BEING YOURSELF is behaviour, not voice. It keeps the wiring decline for the
///   instructions' text (Lil's canned decline 9/38 → 3/38, interview 4/10 → 9/10,
///   2026-09-23), so a pack that softened it would bring the over-firing decline back.
/// - The opening carries the measured privacy claims (where things are kept, and that a
///   search is part of the job; #482, 2026-10-19), worded so a word-for-word recital of
///   them doesn't trip the leak guard. Mini's core also rewrites `curiosityBeat` inside it
///   (#428). A later phase may carve a register slot out of it if a second pack needs one.
/// - `capabilityMove` says what M1K3 can do, not how it sounds. It rides LAST in the
///   standard set, where recency does the work (#303), and the leak guard never
///   fingerprints it.
/// - `leakDeclineBeat` is pocket's measured security beat (51/105 → 76/105), also LAST.
///   Pocket ignores the pack: its frozen core and five beats were measured as one text.
/// - The exemplar header frames the bullets as moves, never lines to reuse (the parrot
///   fix, 12/12 → 0/12, 2026-09-11), and the leak guard fingerprints it.
///
/// Byte-identical rules do not mean unchanged behaviour. Pocket lost security 43/63 →
/// 23/63 to edits outside the rules, and a VOICE-only edit moved Lil's interview score
/// 15/20 → 12/20 (2026-09-29). A second pack is a new prompt, so it owes the full
/// chateval gate, wired like the app, on every brain it reaches. The villain also lives
/// in the invariant spans ("A villain, not a liar.", "stay in character"), so a pack can
/// change the register only inside that one character.
///
/// The catalogue is compile-time data shipped in the binary (ADR 0004's catalogue rule).
/// A pack changes in a reviewed PR and is never fetched. The type is not Codable because
/// nothing persists yet. When a choice does persist, store the `id` as an Optional field.
struct PersonaPack: Hashable, Identifiable {
    /// The stable key.
    let id: String
    /// What a picker would show.
    let name: String
    /// The `# VOICE` section's bullets, one per line, without the header.
    let voice: String
    /// The MOVE bullets under the exemplar header, without the header.
    let exemplars: String

    /// Today's voice and moves, byte for byte: `M1K3Persona.corePrompt` is this pack's render.
    static let `default` = PersonaPack(
        id: "default",
        name: "M1K3",
        voice: M1K3Persona.defaultVoice,
        exemplars: M1K3Persona.defaultExemplarMoves
    )

    /// The catalogue: one entry until a second voice wins a measured preference.
    static let all: [PersonaPack] = [.default]
}
