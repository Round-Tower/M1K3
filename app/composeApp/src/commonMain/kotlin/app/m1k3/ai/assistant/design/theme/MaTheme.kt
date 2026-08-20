package app.m1k3.ai.assistant.design.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.foundation.isSystemInDarkTheme
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaTypography

/**
 * M1K3 AI Theme
 *
 * Dual-mode design system with M1K3 orange branding.
 * - Dark mode: Pure AMOLED black (#000000) for battery efficiency
 * - Light mode: Off-white (#F9F9FA) for readability
 *
 * System-aware: Automatically switches based on system dark mode preference.
 * Both modes optimized for a clean, glassmorphic aesthetic.
 *
 * Key Features:
 * - Respects system dark mode setting
 * - M1K3 orange (#E25303) signature branding (consistent across modes)
 * - Transparent layers for glassmorphic depth
 * - Terminal-inspired minimalism
 */

/**
 * M1K3 AI Dark Color Scheme
 *
 * Maps our design tokens to Material3's color roles.
 * This allows us to use Material3 components while maintaining our brand identity.
 */
private val MaDarkColorScheme = darkColorScheme(
    // ============================================
    // Primary Colors (M1K3 Orange)
    // ============================================
    primary = MaColors.White.copy(alpha = 0.7f),
    onPrimary = MaColors.White,
    primaryContainer = MaColors.White.copy(alpha = 0.7f),
    onPrimaryContainer = MaColors.White,

    // ============================================
    // Secondary Colors (Subtle grays)
    // ============================================
    secondary = MaColors.Black,
    onSecondary = MaColors.Black,
    secondaryContainer = MaColors.Black,
    onSecondaryContainer = MaColors.TextPrimary,

    // ============================================
    // Tertiary Colors (Info blue)
    // ============================================
    tertiary = MaColors.Info,
    onTertiary = MaColors.White,
    tertiaryContainer = MaColors.InfoBg,
    onTertiaryContainer = MaColors.Info,

    // ============================================
    // Background & Surface (AMOLED black base)
    // ============================================
    background = MaColors.BgPrimary,
    onBackground = MaColors.TextPrimary,

    surface = MaColors.BgPrimary,
    onSurface = MaColors.TextPrimary,

    surfaceVariant = MaColors.BgPrimary,
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
    scrim = MaColors.ScrimMedium
)

/**
 * M1K3 AI Light Color Scheme
 *
 * Off-white background with near-black text for excellent readability in bright environments.
 * Maintains the glassmorphic aesthetic using transparent black layers.
 */
private val MaLightColorScheme = lightColorScheme(
    // ============================================
    // Primary Colors (M1K3 Orange)
    // ============================================
    primary = MaColors.Orange,
    onPrimary = MaColors.White,
    primaryContainer = MaColors.Orange.copy(alpha = 0.1f),
    onPrimaryContainer = MaColors.Orange,

    // ============================================
    // Secondary Colors (Subtle grays)
    // ============================================
    secondary = MaColors.Black,
    onSecondary = MaColors.White,
    secondaryContainer = MaColors.Black.copy(alpha = 0.1f),
    onSecondaryContainer = MaColors.TextPrimaryLight,

    // ============================================
    // Tertiary Colors (Info blue)
    // ============================================
    tertiary = MaColors.Info,
    onTertiary = MaColors.White,
    tertiaryContainer = MaColors.InfoBg,
    onTertiaryContainer = MaColors.Info,

    // ============================================
    // Background & Surface (Light mode)
    // ============================================
    background = MaColors.BgPrimaryLight,
    onBackground = MaColors.TextPrimaryLight,

    surface = MaColors.BgPrimaryLight,
    onSurface = MaColors.TextPrimaryLight,

    surfaceVariant = MaColors.BgSecondaryLight,
    onSurfaceVariant = MaColors.TextSecondaryLight,

    surfaceTint = MaColors.Orange,

    // ============================================
    // Inverse Colors (For special cases)
    // ============================================
    inverseSurface = MaColors.Black,
    inverseOnSurface = MaColors.White,
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
    outline = MaColors.BorderMediumLight,
    outlineVariant = MaColors.BorderLightLight,

    // ============================================
    // Scrim (Overlay backgrounds)
    // ============================================
    scrim = MaColors.ScrimMediumLight
)

/**
 * M1K3 Theme Composable
 *
 * Apply this at the root of your app to enable the complete design system.
 * Automatically detects system dark mode preference and applies the appropriate color scheme.
 * Provides Material3 theming with our custom color schemes and typography.
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
 * The theme will automatically switch between:
 * - Dark mode: Pure black (#000000) background + white text
 * - Light mode: Off-white (#F9F9FA) background + near-black text
 *
 * @param content The composable content to theme
 */
@Composable
fun MaTheme(
    content: @Composable () -> Unit
) {
    val isDarkMode = isSystemInDarkTheme()
    val colorScheme = if (isDarkMode) MaDarkColorScheme else MaLightColorScheme

    MaterialTheme(
        colorScheme = colorScheme,
        typography = MaTypography,
        content = content
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
 * val bg = MaterialTheme.colorScheme.background    // Pure black
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
