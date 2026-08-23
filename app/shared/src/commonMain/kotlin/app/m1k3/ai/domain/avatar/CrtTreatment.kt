package app.m1k3.ai.domain.avatar

/**
 * The CRT/phosphor post-process dialled by what M1K3 is doing.
 *
 * The Phosphor Fox is drawn on a Filament surface; this treatment is the
 * amber-monochrome CRT skin laid over it (scanlines, vignette, bloom, a
 * faint mains flicker). Its parameters breathe with the avatar's activity —
 * calm and dim at rest, hotter and busier while listening/thinking/speaking —
 * so the tube feels alive without ever changing the fox geometry.
 *
 * Pure and unit-tested; the Compose overlay just reads these numbers.
 * All fields are normalised 0..1 except [flickerHz] (cycles/second).
 */
data class CrtTreatment(
    val phosphorGlow: Float,
    val scanlineStrength: Float,
    val flickerHz: Float,
    val aberration: Float,
) {
    companion object {
        // Activity buckets → how "hot" the tube runs. Resting is deliberately
        // low so an idle hero doesn't strobe; active states lift the glow and
        // add a touch of chroma fringing and a faster mains hum.
        fun forActivity(
            isActive: Boolean,
            intensity: Float,
        ): CrtTreatment {
            val i = intensity.coerceIn(0f, 1f)
            return if (isActive) {
                CrtTreatment(
                    phosphorGlow = lerp(0.55f, 0.95f, i),
                    scanlineStrength = 0.35f,
                    flickerHz = 12f,
                    aberration = lerp(0.15f, 0.4f, i),
                )
            } else {
                CrtTreatment(
                    phosphorGlow = 0.4f,
                    scanlineStrength = 0.28f,
                    flickerHz = 5f,
                    aberration = 0.08f,
                )
            }
        }

        private fun lerp(
            a: Float,
            b: Float,
            t: Float,
        ): Float = a + (b - a) * t
    }
}
