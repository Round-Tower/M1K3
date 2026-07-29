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
}
