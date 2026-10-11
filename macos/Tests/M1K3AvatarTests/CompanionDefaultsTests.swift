import Foundation
import M1K3Avatar
import Testing

/// `CompanionDefaults` holds the UserDefaults spellings for the avatar choice,
/// shared by the macOS `AppEnvironment` and the iOS/visionOS `AppCore`. The key
/// STRINGS are load-bearing: they must equal the values the Mac has always
/// persisted, or a user's chosen companion silently orphans on upgrade. Pin them
/// so a rename can't quietly break that contract.
struct CompanionDefaultsTests {
    @Test("keys match the shipped Mac spellings (no silent migration)")
    func keysMatchShippedSpellings() {
        #expect(CompanionDefaults.companionKey == "voiceMode.companion")
        #expect(CompanionDefaults.shadingStyleKey == "companion.shadingStyle")
        #expect(CompanionDefaults.constellationID == "memory-constellation")
    }

    @Test("the constellation sentinel is distinct from the pixel-face default")
    func constellationIsNotThePixelDefault() {
        // "" (empty) is the pixel-face default; the constellation sentinel and every
        // real companion id must differ from it, or the resolver can't tell them apart.
        #expect(CompanionDefaults.constellationID != "")
        #expect(CompanionSpec.all.allSatisfy { $0.id != CompanionDefaults.constellationID })
    }

    @Test("the none sentinel is pinned and distinct from every other choice")
    func noneSentinelIsPinnedAndDistinct() {
        #expect(CompanionDefaults.noneID == "avatar-none")
        #expect(CompanionDefaults.noneID != "")
        #expect(CompanionDefaults.noneID != CompanionDefaults.constellationID)
        #expect(CompanionSpec.all.allSatisfy { $0.id != CompanionDefaults.noneID })
    }

    @Test("hidesAvatar is true ONLY for the none sentinel")
    func hidesAvatarOnlyForNone() {
        #expect(CompanionDefaults.hidesAvatar(CompanionDefaults.noneID))
        #expect(!CompanionDefaults.hidesAvatar("")) // pixel face
        #expect(!CompanionDefaults.hidesAvatar(CompanionDefaults.constellationID))
        // Every real companion id — and an unknown/stale id (falls back to the
        // pixel face, never to a blank screen) — keeps the avatar visible.
        #expect(CompanionSpec.all.allSatisfy { !CompanionDefaults.hidesAvatar($0.id) })
        #expect(!CompanionDefaults.hidesAvatar("some-retired-companion"))
    }

    // MARK: - The house default (Kev, TestFlight 499: "Phosphor Fox should be the default avatar")

    @Test("the house companion is the white-lattice Phosphor Fox, and it ships")
    func houseCompanionIsPhosphorFox() {
        #expect(CompanionDefaults.houseCompanion == .phosphorFox)
        #expect(CompanionDefaults.houseCompanion.id == "PhosphorFox")
        #expect(CompanionAssets.isInstalled(CompanionDefaults.houseCompanion))
        #expect(CompanionDefaults.houseShading == .off)
        #expect(CompanionSpec.all.first == .phosphorFox)
    }

    @Test("registeredDefaults is exactly the companion and the shading pair")
    func registeredDefaultsExact() {
        #expect(CompanionDefaults.registeredDefaults == [
            CompanionDefaults.companionKey: "PhosphorFox",
            CompanionDefaults.shadingStyleKey: "off",
        ])
    }

    @Test("registration gives untouched keys the house look and never overrides a saved pick")
    func registrationKeepsSavedPicks() throws {
        func scratch() throws -> (UserDefaults, String) {
            let name = "CompanionDefaultsTests-\(UUID().uuidString)"
            return try (#require(UserDefaults(suiteName: name)), name)
        }
        // Never touched: the house values.
        let (fresh, freshName) = try scratch()
        defer { fresh.removePersistentDomain(forName: freshName) }
        fresh.register(defaults: CompanionDefaults.registeredDefaults)
        #expect(fresh.string(forKey: CompanionDefaults.companionKey) == "PhosphorFox")
        #expect(fresh.string(forKey: CompanionDefaults.shadingStyleKey) == "off")

        // Saved picks survive, including the pixel face's empty string.
        for saved in ["Colobus", ""] {
            let (defaults, name) = try scratch()
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(saved, forKey: CompanionDefaults.companionKey)
            defaults.set("phosphor", forKey: CompanionDefaults.shadingStyleKey)
            defaults.register(defaults: CompanionDefaults.registeredDefaults)
            #expect(defaults.string(forKey: CompanionDefaults.companionKey) == saved)
            #expect(defaults.string(forKey: CompanionDefaults.shadingStyleKey) == "phosphor")
        }
    }

    @Test("both entry points register the shared defaults and neither hard-codes Fox")
    func entryPointsRegisterTheHouseDefaults() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["M1K3App/M1K3App.swift", "M1K3iOSApp/M1K3iOSHarnessApp.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(src.contains("register(defaults: CompanionDefaults.registeredDefaults)"), "\(file) skips the house defaults")
            #expect(!src.contains("companionKey: \"Fox\""), "\(file) still registers the old Fox default")
        }
    }

    // MARK: - The 1.1 skin preservation (the Mac used to register "phosphor")

    @Test("a persisted face with no persisted skin keeps the phosphor glow it always had")
    func preservesTheOldMacSkin() {
        let persisted: [String: Any] = [CompanionDefaults.companionKey: "Colobus"]
        #expect(CompanionDefaults.skinToPreserve(persisted: persisted, markerSpent: false) == "phosphor")
        // The pixel face's "" is a persisted pick too.
        #expect(CompanionDefaults.skinToPreserve(persisted: [CompanionDefaults.companionKey: ""], markerSpent: false) == "phosphor")
    }

    @Test("nothing to preserve: a fresh install, a saved skin, or a spent marker")
    func preservesNothingElse() {
        // Brand new: no face persisted.
        #expect(CompanionDefaults.skinToPreserve(persisted: [:], markerSpent: false) == nil)
        #expect(CompanionDefaults.skinToPreserve(persisted: nil, markerSpent: false) == nil)
        // The user already chose a skin (even "off"): theirs wins.
        let chose: [String: Any] = [CompanionDefaults.companionKey: "Fox", CompanionDefaults.shadingStyleKey: "off"]
        #expect(CompanionDefaults.skinToPreserve(persisted: chose, markerSpent: false) == nil)
        // Already ran once: a 1.1 user who later picks a face keeps the house skin.
        let later: [String: Any] = [CompanionDefaults.companionKey: "Fox"]
        #expect(CompanionDefaults.skinToPreserve(persisted: later, markerSpent: true) == nil)
    }

    @Test("the marker key is pinned and the Mac entry point runs the migration before registering")
    func macWiresTheMigration() throws {
        #expect(CompanionDefaults.skinPreservedKey == "companion.skinPreserved1_1")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("M1K3App/M1K3App.swift"), encoding: .utf8)
        let migrate = try #require(src.range(of: "skinToPreserve("))
        let register = try #require(src.range(of: "register(defaults: CompanionDefaults.registeredDefaults)"))
        #expect(migrate.lowerBound < register.lowerBound, "the migration must read the persistent domain BEFORE registering")
        #expect(src.contains("persistentDomain(forName:"), "read the persistent domain, never registered defaults")
        let ios = try String(contentsOf: root.appendingPathComponent("M1K3iOSApp/M1K3iOSHarnessApp.swift"), encoding: .utf8)
        #expect(!ios.contains("skinToPreserve"), "iOS registered no skin before: nothing to preserve")
    }
}
