package app.m1k3.ai.assistant.design.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaTypography

/**
 * M1K3 AI Theme
 *
 * One scheme, always dark. AMOLED-calm charcoal + M1K3 orange, matching the
 * Mac/iOS shell's dark gradient — there is no light-mode branch to fall
 * into (macos/docs/DESIGN_DOCTRINE.md principle 4: "a setting is a
 * decision you failed to make"; the app never asked two users who'd
 * genuinely want different answers here, so it isn't a setting).
 *
 * Key Features:
 * - M1K3 orange (#D97706) signature branding on every "primary" role, so
 *   Material3 defaults (selected Card containers, checkmarks, section
 *   labels) render on-brand instead of falling back to washed-out white.
 * - Transparent white layers for glassmorphic depth
 * - Terminal-inspired minimalism
 */

/**
 * M1K3 AI Dark Color Scheme
 *
 * Maps our design tokens to Material3's color roles.
 */
private val MaDarkColorScheme =
    darkColorScheme(
        // ============================================
        // Primary Colors (M1K3 Orange) — was White, which read as a
        // near-invisible wash on Settings' selected Brain card and made
        // the "Recommended" tag / selected checkmark disappear.
        // ============================================
        primary = MaColors.Orange,
        onPrimary = MaColors.White,
        primaryContainer = MaColors.OrangeFaint,
        onPrimaryContainer = MaColors.Orange,
        // ============================================
        // Secondary Colors (Subtle grays)
        // ============================================
        secondary = MaColors.BgElevated,
        onSecondary = MaColors.TextPrimary,
        secondaryContainer = MaColors.BgElevated,
        onSecondaryContainer = MaColors.TextPrimary,
        // ============================================
        // Tertiary Colors (Info blue)
        // ============================================
        tertiary = MaColors.Info,
        onTertiary = MaColors.White,
        tertiaryContainer = MaColors.InfoBg,
        onTertiaryContainer = MaColors.Info,
        // ============================================
        // Background & Surface (AMOLED-calm charcoal base)
        // ============================================
        background = MaColors.BgPrimary,
        onBackground = MaColors.TextPrimary,
        surface = MaColors.BgPrimary,
        onSurface = MaColors.TextPrimary,
        surfaceVariant = MaColors.BgSecondary,
        onSurfaceVariant = MaColors.TextSecondary,
        surfaceTint = MaColors.Orange,
        // ============================================
        // Inverse Colors (For special cases)
        // ============================================
        inverseSurface = MaColors.White,
        inverseOnSurface = MaColors.Black,
        inversePrimary = MaColors.Orange,
        // ============================================
        // Error Colors
        // ============================================
        error = MaColors.Error,
        onError = MaColors.White,
        errorContainer = MaColors.ErrorBg,
        onErrorContainer = MaColors.Error,
        // ============================================
        // Outline & Borders
        // ============================================
        outline = MaColors.BorderLight,
        outlineVariant = MaColors.BorderSubtle,
        // ============================================
        // Scrim (Overlay backgrounds)
        // ============================================
        scrim = MaColors.ScrimMedium,
    )

/**
 * M1K3 Theme Composable
 *
 * Apply this at the root of your app to enable the complete design system.
 * Always dark — see the file header for why there's no light-mode branch.
 *
 * Example Usage:
 * ```kotlin
 * @Composable
 * fun MyApp() {
 *     MaTheme {
 *         // Your app content here
 *         Scaffold { ... }
 *     }
 * }
 * ```
 *
 * @param content The composable content to theme
 */
@Composable
fun MaTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = MaDarkColorScheme,
        typography = MaTypography,
        content = content,
    )
}

/**
 * Color Role Mappings for Reference
 *
 * When using Material3 components, they automatically use these roles:
 *
 * Buttons:
 * - FilledButton: primary/onPrimary
 * - OutlinedButton: outline border, transparent background
 * - TextButton: primary text, transparent background
 *
 * Cards:
 * - Card: surface/onSurface
 * - ElevatedCard: surfaceVariant/onSurfaceVariant
 * - OutlinedCard: outline border
 *
 * Text Fields:
 * - Filled: surface/onSurface
 * - Outlined: outline border
 *
 * Top App Bar:
 * - surface/onSurface
 *
 * Background:
 * - Scaffold background: background/onBackground
 *
 * Access colors directly:
 * ```kotlin
 * val primary = MaterialTheme.colorScheme.primary  // M1K3 Orange
 * val bg = MaterialTheme.colorScheme.background    // Soft charcoal
 * ```
 *
 * Access typography:
 * ```kotlin
 * Text(
 *     text = "Hello",
 *     style = MaterialTheme.typography.headlineLarge
 * )
 * ```
 */
