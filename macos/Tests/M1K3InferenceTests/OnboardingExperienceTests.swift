import Foundation
@testable import M1K3Inference
import Testing

struct OnboardingExperienceTests {
    @Test("full experience writes all seven feature keys")
    func fullExperienceWritesAllKeys() throws {
        let suite = "test-onboarding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        OnboardingExperience.fullExperience.apply(to: defaults)
        #expect(defaults.bool(forKey: "notchHUD.enabled") == true)
        #expect(defaults.bool(forKey: "heartbeat.enabled") == true)
        #expect(defaults.bool(forKey: "notifications.heartbeat") == true)
        #expect(defaults.bool(forKey: "contextTools.battery") == true)
        #expect(defaults.bool(forKey: "contextTools.calendar") == true)
        #expect(defaults.bool(forKey: "contextTools.location") == true)
        #expect(defaults.bool(forKey: "chatEgressAllowed") == true)
    }

    @Test("private by default writes nothing")
    func privateWritesNothing() throws {
        let suite = "test-onboarding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        OnboardingExperience.privateByDefault.apply(to: defaults)
        #expect(defaults.bool(forKey: "notchHUD.enabled") == false)
        #expect(defaults.bool(forKey: "heartbeat.enabled") == false)
        #expect(defaults.bool(forKey: "chatEgressAllowed") == false)
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
}
