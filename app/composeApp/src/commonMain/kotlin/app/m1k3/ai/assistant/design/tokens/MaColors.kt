package app.m1k3.ai.assistant.design.tokens

import androidx.compose.ui.graphics.Color

/**
 * M1K3 AI Color Palette
 *
 * AMOLED black optimized design system with M1K3 branding.
 * Pure black (#000000) saves 15-20% battery on AMOLED displays.
 *
 * Design Philosophy:
 * - Pure AMOLED black for maximum battery efficiency
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
    // Background Layers - Dark Mode
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
    // Background Layers - Light Mode
    // (Transparent Black on Light)
    // ============================================

    /** Light mode primary background - Off-white (#F9F9FA) */
    val BgPrimaryLight = Color(0xFFF9F9FA)

    /** Light mode secondary background - Very subtle dark (1% black) */
    val BgSecondaryLight = Color(0x03000000) // rgba(0,0,0,0.01)

    /** Light mode tertiary background - 2% black transparency */
    val BgTertiaryLight = Color(0x05000000) // rgba(0,0,0,0.02)

    /** Light mode elevated surface - 4% black transparency */
    val BgElevatedLight = Color(0x0A000000) // rgba(0,0,0,0.04)

    /** Light mode glassmorphic surface - 2% black transparency */
    val BgGlassLight = Color(0x05000000) // rgba(0,0,0,0.02)

    /** Light mode highly elevated surface - 8% black transparency */
    val BgHighElevatedLight = Color(0x14000000) // rgba(0,0,0,0.08)

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
    // Text Hierarchy - Light Mode
    // ============================================

    /** Light mode primary text - 95% black (near-black for readability) */
    val TextPrimaryLight = Color(0xF2000000) // rgba(0,0,0,0.95)

    /** Light mode secondary text - 60% black (for less important content) */
    val TextSecondaryLight = Color(0x99000000) // rgba(0,0,0,0.60)

    /** Light mode muted text - 40% black (for hints, placeholders) */
    val TextMutedLight = Color(0x66000000) // rgba(0,0,0,0.40)

    /** Light mode disabled text - 25% black (for inactive elements) */
    val TextDisabledLight = Color(0x40000000) // rgba(0,0,0,0.25)

    // ============================================
    // Border Colors - Dark Mode
    // ============================================

    /** Subtle border - 6% white (barely visible separation) */
    val BorderSubtle = Color(0x0FFFFFFF) // rgba(255,255,255,0.06)

    /** Light border - 10% white (standard dividers) */
    val BorderLight = Color(0x1AFFFFFF) // rgba(255,255,255,0.10)

    /** Medium border - 15% white (emphasized dividers) */
    val BorderMedium = Color(0x26FFFFFF) // rgba(255,255,255,0.15)

    /** Strong border - 25% white (strong visual separation) */
    val BorderStrong = Color(0x40FFFFFF) // rgba(255,255,255,0.25)

    // ============================================
    // Border Colors - Light Mode
    // ============================================

    /** Light mode subtle border - 5% black (barely visible separation) */
    val BorderSubtleLight = Color(0x0D000000) // rgba(0,0,0,0.05)

    /** Light mode light border - 8% black (standard dividers) */
    val BorderLightLight = Color(0x14000000) // rgba(0,0,0,0.08)

    /** Light mode medium border - 12% black (emphasized dividers) */
    val BorderMediumLight = Color(0x1F000000) // rgba(0,0,0,0.12)

    /** Light mode strong border - 20% black (strong visual separation) */
    val BorderStrongLight = Color(0x33000000) // rgba(0,0,0,0.20)

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
    // Interactive States - Light Mode
    // ============================================

    /** Light mode hover overlay - 5% black */
    val HoverOverlayLight = Color(0x0D000000)

    /** Light mode pressed overlay - 10% black */
    val PressedOverlayLight = Color(0x1A000000)

    /** Light mode focus ring - M1K3 orange */
    val FocusRingLight = Orange

    /** Light mode selection background - 12% orange */
    val SelectionBgLight = Color(0x1FE25303)

    // ============================================
    // Scrim & Overlays - Dark Mode
    // ============================================

    /** Light scrim - 40% black (for overlays) */
    val ScrimLight = Color(0x66000000)

    /** Medium scrim - 60% black (for modals) */
    val ScrimMedium = Color(0x99000000)

    /** Dark scrim - 80% black (for full overlays) */
    val ScrimDark = Color(0xCC000000)

    // ============================================
    // Scrim & Overlays - Light Mode
    // ============================================

    /** Light mode light scrim - 30% black (for overlays) */
    val ScrimLightLight = Color(0x4D000000)

    /** Light mode medium scrim - 50% black (for modals) */
    val ScrimMediumLight = Color(0x80000000)

    /** Light mode dark scrim - 70% black (for full overlays) */
    val ScrimDarkLight = Color(0xB3000000)

    /**
     * Theme-aware color getters
     * Automatically select appropriate color based on system dark mode
     */

    // Text colors
    @androidx.compose.runtime.Composable
    fun textPrimary(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) TextPrimary else TextPrimaryLight

    @androidx.compose.runtime.Composable
    fun textSecondary(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) TextSecondary else TextSecondaryLight

    @androidx.compose.runtime.Composable
    fun textMuted(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) TextMuted else TextMutedLight

    @androidx.compose.runtime.Composable
    fun textDisabled(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) TextDisabled else TextDisabledLight

    // Background colors
    @androidx.compose.runtime.Composable
    fun bgPrimary(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) BgPrimary else BgPrimaryLight

    @androidx.compose.runtime.Composable
    fun bgSecondary(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) BgSecondary else BgSecondaryLight

    @androidx.compose.runtime.Composable
    fun bgTertiary(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) BgTertiary else BgTertiaryLight

    @androidx.compose.runtime.Composable
    fun bgElevated(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) BgElevated else BgElevatedLight

    @androidx.compose.runtime.Composable
    fun bgGlass(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) BgGlass else BgGlassLight

    @androidx.compose.runtime.Composable
    fun bgHighElevated(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) BgHighElevated else BgHighElevatedLight

    // Border colors
    @androidx.compose.runtime.Composable
    fun borderSubtle(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) BorderSubtle else BorderSubtleLight

    @androidx.compose.runtime.Composable
    fun borderLight(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) BorderLight else BorderLightLight

    @androidx.compose.runtime.Composable
    fun borderMedium(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) BorderMedium else BorderMediumLight

    @androidx.compose.runtime.Composable
    fun borderStrong(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) BorderStrong else BorderStrongLight

    // Interactive states
    @androidx.compose.runtime.Composable
    fun hoverOverlay(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) HoverOverlay else HoverOverlayLight

    @androidx.compose.runtime.Composable
    fun pressedOverlay(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) PressedOverlay else PressedOverlayLight

    @androidx.compose.runtime.Composable
    fun selectionBg(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) SelectionBg else SelectionBgLight

    // Scrim colors
    @androidx.compose.runtime.Composable
    fun scrimLight(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) ScrimLight else ScrimLightLight

    @androidx.compose.runtime.Composable
    fun scrimMedium(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) ScrimMedium else ScrimMediumLight

    @androidx.compose.runtime.Composable
    fun scrimDark(): Color = if (androidx.compose.foundation.isSystemInDarkTheme()) ScrimDark else ScrimDarkLight
}
