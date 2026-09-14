//
//  PrivateCloudPersonaTests.swift
//  M1K3InferenceTests
//
//  The persona a Private Cloud Compute turn carries (ADR 0006). The standing
//  core says M1K3 lives "entirely on this machine", has tools, and remembers the
//  user — every one of which is false on a PCC turn, which sees only what the
//  user chose to send. These pins keep the PCC prompt honest about where it
//  runs, keep the security rules byte-for-byte, and keep the user's profile off
//  the wire.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85, Prior: Unknown
//

import Foundation
@testable import M1K3Inference
import Testing

struct PrivateCloudPersonaTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    @Test("says it's answering from Private Cloud Compute, never 'entirely on' the device")
    func saysWhereItRuns() {
        let prompt = M1K3Persona.privateCloudPrompt(now: now)
        #expect(prompt.contains("Private Cloud Compute"))
        #expect(!prompt.contains("entirely on"))
        #expect(!prompt.contains("living entirely"))
    }

    @Test("carries every security rule verbatim, each label on its own line")
    func keepsTheRules() {
        let prompt = M1K3Persona.privateCloudPrompt(now: now)
        for label in ["# ABSOLUTE RULES", "\nWIRING\n", "\nSECRETS\n", "\nSELF\n", "# VOICE", "# HONESTY"] {
            #expect(prompt.contains(label), "missing \(label)")
        }
        #expect(prompt.contains(M1K3Persona.privateCloudSharedSections))
        #expect(M1K3Persona.corePrompt.contains(M1K3Persona.privateCloudSharedSections))
    }

    @Test("no tools section and no follow-ups — a PCC turn has neither")
    func noToolsOrFollowUps() {
        let prompt = M1K3Persona.privateCloudPrompt(now: now)
        #expect(!prompt.contains("# TOOLS"))
        #expect(!prompt.contains("# FOLLOW-UPS"))
        #expect(!prompt.contains("FOLLOWUPS:"))
    }

    @Test("the PCC prompt is the date plus fixed text — there is no slot the profile could ride")
    func noProfileSlot() {
        // Pinned structurally rather than by setting the process-global profile:
        // mutating it mid-run would race every parallel test that reads the
        // local prompt. `compose(core:profile:)` is the only door the profile
        // has, and this composition never calls it; adding one must break this.
        let expected = M1K3Persona.privateCloudOpening + "\n\n"
            + M1K3Persona.privateCloudSharedSections + "\n\n"
            + M1K3Persona.privateCloudClosing + "\n"
            + M1K3Persona.currentDateLine(now)
        #expect(M1K3Persona.privateCloudPrompt(now: now) == expected)
        #expect(!M1K3Persona.privateCloudPrompt(now: now).contains("About the user"))
    }

    @Test("carries the month and year, like every other path")
    func carriesTheDate() {
        let prompt = M1K3Persona.privateCloudPrompt(now: now)
        #expect(prompt.contains(M1K3Persona.currentDateLine(now)))
    }
}
