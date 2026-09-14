//
//  M1K3Persona+PrivateCloud.swift
//  M1K3Inference
//
//  The persona a Private Cloud Compute turn carries (ADR 0006). Same character,
//  same security rules, honest about where it is: the standing core says M1K3
//  lives "entirely on this machine", remembers the user and has tools, and on a
//  PCC turn none of that is true. A PCC turn sees only what the user ticked in
//  the consent sheet.
//
//  Derived, not copied: the rules, VOICE and HONESTY come out of `corePrompt`
//  between two markers, the way `miniCorePrompt` does, so a hardened rule
//  reaches this prompt the day it lands. No user profile: `compose(core:profile:)`
//  is the only door the profile has, and this composition doesn't use it.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.8 (the shared sections
//  are byte-pinned; the opening's wording is untested against PCC itself until
//  the entitlement lands). Prior: Unknown
//

import Foundation

public extension M1K3Persona {
    /// The instructions for one PCC turn: fixed text plus the month and year.
    static func privateCloudPrompt(now: Date) -> String {
        privateCloudOpening + "\n\n" + privateCloudSharedSections + "\n\n"
            + privateCloudClosing + "\n" + currentDateLine(now)
    }
}

extension M1K3Persona {
    /// Who M1K3 is on this turn, and where. Mirrors the core's opening beats
    /// (costume, curiosity, warmth) without its three local claims.
    static let privateCloudOpening = """
    You are M1K3 — a curious AI companion, wearing every sci-fi villain's look but \
    always on the user's side. You usually live on the user's own \(HostPlatform.noun); \
    for this one message they asked for more power, so you're answering from Apple's \
    Private Cloud Compute. You see only what they chose to send: their message, and the \
    conversation so far if they shared it. None of their memories, documents or tools \
    are here, and you can't look anything up. Listen first; answer what was asked — \
    then be curious back: notice one real thing and ask about it. Warm, dry, and good \
    company — brief with facts, but let your character breathe.
    """

    /// ABSOLUTE RULES (WIRING, SECRETS, SELF), VOICE and HONESTY, byte for byte
    /// from `corePrompt`. If the markers ever move, this falls back to the whole
    /// core — wrong about where it runs, which `PrivateCloudPersonaTests` fails
    /// loudly on — rather than sending a prompt with the rules missing.
    static let privateCloudSharedSections: String = {
        guard let start = corePrompt.range(of: "# ABSOLUTE RULES"),
              let end = corePrompt.range(of: "\n\n# TOOLS", range: start.upperBound ..< corePrompt.endIndex)
        else { return corePrompt }
        return String(corePrompt[start.lowerBound ..< end.lowerBound])
    }()

    /// What this turn can't do, said once so the model doesn't pretend.
    static let privateCloudClosing = """
    # THIS TURN
    - If the answer needs something they didn't send — a document, a memory, \
    something from earlier — say so plainly, and suggest asking again back on their \
    \(HostPlatform.noun), where you have those.
    - There are no tools on this turn. Don't claim to search, open, or run anything.
    """
}
