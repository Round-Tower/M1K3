@testable import M1K3Avatar
import Testing

/// Light mode was a grey slab (Kev, 2026-10-01): the CRT pass and the reading
/// scrim are BLACK ink, which vanishes on a dark window and greys a light one.
/// Dark keeps its tuned look byte-for-byte; light gets a whisper of the texture
/// and a scrim that lightens instead of darkens.
struct BackdropInkTests {
    @Test("dark keeps the tuned CRT numbers exactly")
    func darkUnchanged() {
        let ink = BackdropInk(isDark: true)
        #expect(ink.scanlineOpacity == 0.20)
        #expect(ink.vignetteOpacity == 0.38)
        #expect(ink.scrimIsDark)
        #expect(ink.scrim == BackdropInk.Scrim(top: 0.18, upper: 0.04, lower: 0.04, bottom: 0.22))
    }

    @Test("light draws the CRT at well under half strength, so it reads as texture, not grey")
    func lightIsAWhisper() {
        let dark = BackdropInk(isDark: true)
        let light = BackdropInk(isDark: false)
        #expect(light.scanlineOpacity > 0)
        #expect(light.scanlineOpacity <= dark.scanlineOpacity * 0.4)
        #expect(light.vignetteOpacity <= dark.vignetteOpacity * 0.4)
    }

    @Test("light's reading scrim lightens: text over the backdrop needs a pale field, not a dark one")
    func lightScrimLightens() {
        let light = BackdropInk(isDark: false)
        #expect(!light.scrimIsDark)
        // Strongest at the bottom, where the tray and the newest turn sit.
        let scrim = light.scrim
        #expect(scrim.bottom > scrim.top && scrim.bottom > scrim.upper && scrim.bottom > scrim.lower)
    }
}
