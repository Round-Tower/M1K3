import Foundation
@testable import M1K3Inference
import Testing

struct OnboardingExperienceTests {
    @Test("full experience writes the four direct keys and skips the three permission keys")
    func fullExperienceWritesDirectKeys() throws {
        let suite = "test-onboarding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        OnboardingExperience.fullExperience.apply(to: defaults)
        #expect(defaults.bool(forKey: "notchHUD.enabled") == true)
        #expect(defaults.bool(forKey: "heartbeat.enabled") == true)
        #expect(defaults.bool(forKey: "contextTools.battery") == true)
        #expect(defaults.bool(forKey: "chatEgressAllowed") == true)
        // Permission-required keys are left for the UI's ceremony.
        #expect(defaults.object(forKey: "notifications.heartbeat") == nil)
        #expect(defaults.object(forKey: "contextTools.calendar") == nil)
        #expect(defaults.object(forKey: "contextTools.location") == nil)
    }

    @Test("private by default writes every key false")
    func privateWritesAllKeysFalse() throws {
        let suite = "test-onboarding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Pre-set everything true so we can tell the write happened (bool(forKey:)
        // returns false for missing keys — indistinguishable from "wrote false").
        for entry in OnboardingExperience.fullExperienceDefaults {
            defaults.set(true, forKey: entry.key)
        }
        OnboardingExperience.privateByDefault.apply(to: defaults)
        for entry in OnboardingExperience.fullExperienceDefaults {
            #expect(defaults.bool(forKey: entry.key) == false,
                    "Private should write \(entry.key) = false")
        }
    }

    @Test("round-trip: Full → Private turns direct keys off, Private → Full turns them on")
    func roundTrip() throws {
        let suite = "test-onboarding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directKeys = OnboardingExperience.fullExperienceDefaults
            .filter { !OnboardingExperience.permissionRequiredKeys.contains($0.key) }

        OnboardingExperience.fullExperience.apply(to: defaults)
        for entry in directKeys {
            #expect(defaults.bool(forKey: entry.key) == true)
        }
        OnboardingExperience.privateByDefault.apply(to: defaults)
        for entry in OnboardingExperience.fullExperienceDefaults {
            #expect(defaults.bool(forKey: entry.key) == false,
                    "After Private, \(entry.key) should be false")
        }
        OnboardingExperience.fullExperience.apply(to: defaults)
        for entry in directKeys {
            #expect(defaults.bool(forKey: entry.key) == true,
                    "After Full again, \(entry.key) should be true")
        }
    }

    @Test("full experience has exactly seven entries — add one here when you add a feature")
    func entryCount() {
        #expect(OnboardingExperience.fullExperienceDefaults.count == 7)
    }

    @Test("no duplicate keys in the full experience list")
    func noDuplicateKeys() {
        let keys = OnboardingExperience.fullExperienceDefaults.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    @Test("web search and MCP are NOT in the full experience list")
    func excludedFeatures() {
        let keys = Set(OnboardingExperience.fullExperienceDefaults.map(\.key))
        #expect(!keys.contains("webSearchEnabled"))
        #expect(!keys.contains("contextTools.locationPrecise"))
    }

    @Test("permission-required keys are exactly the three that need system prompts")
    func permissionRequiredKeys() {
        let expected: Set = [
            "contextTools.calendar",
            "contextTools.location",
            "notifications.heartbeat",
        ]
        #expect(OnboardingExperience.permissionRequiredKeys == expected)
    }

    @Test("every permission-required key is also in fullExperienceDefaults")
    func permissionKeysAreSubset() {
        let allKeys = Set(OnboardingExperience.fullExperienceDefaults.map(\.key))
        for key in OnboardingExperience.permissionRequiredKeys {
            #expect(allKeys.contains(key),
                    "\(key) is permission-required but not in fullExperienceDefaults")
        }
    }
}
