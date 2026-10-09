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

/// The thinking rain (voice mode's phosphor text) was tuned on the old near-black
/// gradient: pale-green tints at half strength vanish on light glass. Dark keeps
/// today's 0.5 cap and un-darkened tints; light gets a stronger, darker ink.
struct BackdropInkRainTests {
    @Test("dark rain is byte-identical to the tuned look: 0.5 cap, tints untouched")
    func darkRainUnchanged() {
        let rain = BackdropInk(isDark: true).rain
        #expect(rain.opacityScale == 0.5)
        #expect(rain.tintDarkening == 0)
    }

    @Test("light rain lays down more ink than dark, and darkens the pale tints")
    func lightRainIsStrongerAndDarker() {
        let dark = BackdropInk(isDark: true).rain
        let light = BackdropInk(isDark: false).rain
        #expect(light.opacityScale > dark.opacityScale)
        #expect(light.opacityScale <= 1)
        #expect(light.tintDarkening > 0 && light.tintDarkening < 1)
    }
}
