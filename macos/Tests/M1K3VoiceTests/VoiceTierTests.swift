import M1K3Voice
import Testing

struct VoiceTierTests {
    @Test("two tiers, built-in first")
    func cases() {
        #expect(VoiceTier.allCases == [.builtin, .m1k3Voice])
    }

    @Test("display names")
    func displayNames() {
        #expect(VoiceTier.builtin.displayName == "Built-in")
        #expect(VoiceTier.m1k3Voice.displayName == "M1K3 Voice")
    }

    @Test("only M1K3 Voice requires a download")
    func downloadRequirement() {
        #expect(VoiceTier.builtin.approxDownloadMB == nil)
        #expect(VoiceTier.builtin.requiresDownload == false)
        #expect(VoiceTier.m1k3Voice.approxDownloadMB == 354)
        #expect(VoiceTier.m1k3Voice.requiresDownload == true)
    }

    @Test("macOS keeps M1K3 Voice's exact card copy — the platform-honesty byte freeze")
    func m1k3VoiceDetailMacOSBytesFrozen() {
        #if os(macOS)
            #expect(VoiceTier.m1k3Voice.detail.contains("runs entirely on your Mac"))
        #else
            #expect(!VoiceTier.m1k3Voice.detail.contains("Mac"))
        #endif
    }

    @Test("Built-in's card copy is platform-honest — macOS bytes frozen, no macOS leak elsewhere")
    func builtinDetailPlatformHonest() {
        #if os(macOS)
            #expect(VoiceTier.builtin.detail.contains("macOS's built-in speech"))
        #else
            #expect(!VoiceTier.builtin.detail.contains("macOS"))
            #expect(VoiceTier.builtin.detail.contains("built-in speech"))
        #endif
    }

    @Test("every tier has a non-empty tagline, detail, and glyph")
    func metadataPopulated() {
        for tier in VoiceTier.allCases {
            #expect(!tier.tagline.isEmpty)
            #expect(!tier.detail.isEmpty)
            #expect(!tier.glyph.isEmpty)
        }
    }

    @Test("identifiable by raw value")
    func identifiable() {
        #expect(VoiceTier.builtin.id == "builtin")
        #expect(VoiceTier.m1k3Voice.id == "m1k3Voice")
    }
}
