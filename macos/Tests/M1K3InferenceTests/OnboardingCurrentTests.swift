//
//  OnboardingCurrentTests.swift
//  M1K3InferenceTests
//
//  The re-run hello card's "Currently: Full / Private / Custom" line (#540 slice-1 carry-over):
//  read from the seven experience keys, so a re-run shows where the doors stand before it
//  rewrites them.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.9. Prior: none (new file).

import Foundation
@testable import M1K3Inference
import Testing

struct OnboardingCurrentTests {
    private func scratchDefaults() throws -> (UserDefaults, String) {
        let suite = "test-onboarding-current-\(UUID().uuidString)"
        return try (#require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("all seven keys on reads Full; all seven off reads Private")
    func fullAndPrivate() throws {
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        for entry in OnboardingExperience.fullExperienceDefaults {
            defaults.set(true, forKey: entry.key)
        }
        #expect(OnboardingExperience.current(in: defaults) == .fullExperience)
        OnboardingExperience.privateByDefault.apply(to: defaults)
        #expect(OnboardingExperience.current(in: defaults) == .privateByDefault)
    }

    @Test("one key off the door reads Custom (nil), and each case has its label")
    func custom() throws {
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        for entry in OnboardingExperience.fullExperienceDefaults {
            defaults.set(true, forKey: entry.key)
        }
        defaults.set(false, forKey: "notchHUD.enabled")
        #expect(OnboardingExperience.current(in: defaults) == nil)
        #expect(OnboardingExperience.currentLabel(for: nil) == "Custom")
        #expect(OnboardingExperience.currentLabel(for: .fullExperience) == "Full")
        #expect(OnboardingExperience.currentLabel(for: .privateByDefault) == "Private")
    }
}
