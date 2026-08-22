package app.m1k3.ai.assistant.design.tokens

import androidx.compose.ui.graphics.Color

/**
 * M1K3 AI Color Palette
 *
 * AMOLED black optimized design system with M1K3 branding.
 * Pure black (#000000) saves 15-20% battery on AMOLED displays.
 *
 * Design Philosophy:
 * - Pure AMOLED black, always. One scheme, no system light-mode branch
 *   (doctrine: "a setting is a decision you failed to make" — the dark
 *   calm gradient IS the product, matching the Mac/iOS shell).
 * - M1K3 orange (#E25303) as signature brand accent
 * - Transparent white layers for glassmorphic depth
 * - Minimal, intentional color use
 */
object MaColors {
    // ============================================
    // Foundation Colors
    // ============================================

    /** Pure AMOLED black - Maximum battery savings on OLED displays */
    val Black = Color(0xFF000000)

    /** Pure white - Used sparingly for maximum contrast */
    val White = Color(0xFFFFFFFF)

    // ============================================
    // M1K3 Brand Colors
    // ============================================

    /** M1K3 signature orange - Primary brand color (muted amber) */
    val Orange = Color(0xFFD97706)

    /** Dimmed orange (50% alpha) - For subtle accents */
    val OrangeDim = Color(0x80D97706)

    /** Faint orange (20% alpha) - For very subtle tints */
    val OrangeFaint = Color(0x33D97706)

    // ============================================
    // Background Layers
    // (Transparent White on Black)
    // Creates depth through subtle transparency
    // ============================================

    /**
     * Primary background - soft charcoal.
     *
     * Was pure AMOLED Black, but #000000 feels clinical at hero scale.
     * #0E0E10 reads as "dark" but gives a tiny warmth so the avatar,
     * cards, and glass surfaces have something to lift off.
     */
    val BgPrimary = Color(0xFF0E0E10)

    /** Secondary background - 2% white transparency */
    val BgSecondary = Color(0x15FFFFFF) // rgba(255,255,255,0.02)

    /** Tertiary background - 4% white transparency */
    val BgTertiary = Color(0x0AFFFFFF) // rgba(255,255,255,0.04)

    /** Elevated surface - 8% white transparency */
    val BgElevated = Color(0x14FFFFFF) // rgba(255,255,255,0.08)

    /** Glassmorphic surface - 3% white transparency (for blur effects) */
    val BgGlass = Color(0x08FFFFFF) // rgba(255,255,255,0.03)

    /** Highly elevated surface - 12% white transparency */
    val BgHighElevated = Color(0x1FFFFFFF) // rgba(255,255,255,0.12)

    // ============================================
    // Text Hierarchy
    // ============================================

    /** Primary text - 98% white (nearly pure but softer) */
    val TextPrimary = Color(0xFAFFFFFF) // rgba(255,255,255,0.98)

    /** Secondary text - 75% white (for less important content) */
    val TextSecondary = Color(0xBFFFFFFF) // rgba(255,255,255,0.75)

    /** Muted text - 45% white (for hints, placeholders) */
    val TextMuted = Color(0x73FFFFFF) // rgba(255,255,255,0.45)

    /** Disabled text - 30% white (for inactive elements) */
    val TextDisabled = Color(0x4DFFFFFF) // rgba(255,255,255,0.30)

    // ============================================
    // Border Colors
    // ============================================

    /** Subtle border - 6% white (barely visible separation) */
    val BorderSubtle = Color(0x0FFFFFFF) // rgba(255,255,255,0.06)

    /** Light-weight border - 10% white (standard dividers) */
    val BorderLight = Color(0x1AFFFFFF) // rgba(255,255,255,0.10)

    /** Medium-weight border - 15% white (emphasized dividers) */
    val BorderMedium = Color(0x26FFFFFF) // rgba(255,255,255,0.15)

    /** Strong border - 25% white (strong visual separation) */
    val BorderStrong = Color(0x40FFFFFF) // rgba(255,255,255,0.25)

    // ============================================
    // Status Colors
    // ============================================

    /** Success state - Material Green 500 */
    val Success = Color(0xFF4CAF50)

    /** Success background - 15% alpha */
    val SuccessBg = Color(0x264CAF50)

    /** Error state - Material Red 500 */
    val Error = Color(0xFFF44336)

    /** Error background - 15% alpha */
    val ErrorBg = Color(0x26F44336)

    /** Warning state - Material Orange 400 */
    val Warning = Color(0xFFFFA726)

    /** Warning background - 15% alpha */
    val WarningBg = Color(0x26FFA726)

    /** Info state - Material Light Blue 400 */
    val Info = Color(0xFF29B6F6)

    /** Info background - 15% alpha */
    val InfoBg = Color(0x2629B6F6)

    // ============================================
    // Interactive States
    // ============================================

    /** Hover overlay - 8% white */
    val HoverOverlay = Color(0x14FFFFFF)

    /** Pressed overlay - 16% white */
    val PressedOverlay = Color(0x29FFFFFF)

    /** Focus ring - M1K3 orange */
    val FocusRing = Orange

    /** Selection background - 12% orange */
    val SelectionBg = Color(0x1FE25303)

    // ============================================
    // Scrim & Overlays
    // ============================================

    /** Light scrim - 40% black (for overlays) */
    val ScrimLight = Color(0x66000000)

    /** Medium scrim - 60% black (for modals) */
    val ScrimMedium = Color(0x99000000)

    /** Dark scrim - 80% black (for full overlays) */
    val ScrimDark = Color(0xCC000000)

    /**
     * Role getters.
     *
     * These used to branch on `isSystemInDarkTheme()`; the app is dark-only
     * now (finding #1 — no theme decision), so they're plain accessors over
     * the single token set above. Kept as functions (not vals) so every
     * existing `MaColors.textPrimary()` call site keeps compiling unchanged.
     */

    @androidx.compose.runtime.Composable
    fun textPrimary(): Color = TextPrimary

    @androidx.compose.runtime.Composable
    fun textSecondary(): Color = TextSecondary

    @androidx.compose.runtime.Composable
    fun textMuted(): Color = TextMuted

    @androidx.compose.runtime.Composable
    fun textDisabled(): Color = TextDisabled

    @androidx.compose.runtime.Composable
    fun bgPrimary(): Color = BgPrimary

    @androidx.compose.runtime.Composable
    fun bgSecondary(): Color = BgSecondary

    @androidx.compose.runtime.Composable
    fun bgTertiary(): Color = BgTertiary

    @androidx.compose.runtime.Composable
    fun bgElevated(): Color = BgElevated

    @androidx.compose.runtime.Composable
    fun bgGlass(): Color = BgGlass

    @androidx.compose.runtime.Composable
    fun bgHighElevated(): Color = BgHighElevated

    @androidx.compose.runtime.Composable
    fun borderSubtle(): Color = BorderSubtle

    @androidx.compose.runtime.Composable
    fun borderLight(): Color = BorderLight

    @androidx.compose.runtime.Composable
    fun borderMedium(): Color = BorderMedium

    @androidx.compose.runtime.Composable
    fun borderStrong(): Color = BorderStrong

    @androidx.compose.runtime.Composable
    fun hoverOverlay(): Color = HoverOverlay

    @androidx.compose.runtime.Composable
    fun pressedOverlay(): Color = PressedOverlay

    @androidx.compose.runtime.Composable
    fun selectionBg(): Color = SelectionBg

    @androidx.compose.runtime.Composable
    fun scrimLight(): Color = ScrimLight

    @androidx.compose.runtime.Composable
    fun scrimMedium(): Color = ScrimMedium

    @androidx.compose.runtime.Composable
    fun scrimDark(): Color = ScrimDark
}
