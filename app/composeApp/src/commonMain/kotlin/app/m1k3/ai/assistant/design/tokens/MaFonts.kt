package app.m1k3.ai.assistant.design.tokens

import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight

/**
 * M1K3 Font System
 *
 * Custom font configuration for branded, accessible typography.
 * Uses system fonts optimized for readability on mobile.
 */

/**
 * Primary font family - for headings and emphasis
 *
 * Uses Inter/SF Pro on iOS, Roboto on Android
 * Both are highly legible, modern, and optimized for screens
 */
expect val MaFontFamilyBrand: FontFamily

/**
 * Body font family - for body text and UI
 *
 * Uses system default for maximum readability and performance
 */
expect val MaFontFamilyBody: FontFamily

/**
 * Monospace font family - for code, stats, technical content
 *
 * Uses JetBrains Mono / SF Mono / Roboto Mono
 */
expect val MaFontFamilyMono: FontFamily

/**
 * Caption font family - for captions and secondary text
 *
 * Uses Doto font family for distinctive, readable captions
 */
expect val MaFontFamilyCaption: FontFamily

/**
 * Font weights used throughout the app
 */
object MaFontWeights {
    val Light = FontWeight.Light // 300
    val Normal = FontWeight.Normal // 400
    val Medium = FontWeight.Medium // 500
    val SemiBold = FontWeight.SemiBold // 600
    val Bold = FontWeight.Bold // 700
    val ExtraBold = FontWeight.ExtraBold // 800
}

/**
 * Usage:
 * ```kotlin
 * Text(
 *     "M1K3 AI",
 *     fontFamily = MaFontFamilyBrand,
 *     fontWeight = MaFontWeights.Bold
 * )
 *
 * Text(
 *     "Chat message...",
 *     fontFamily = MaFontFamilyBody,
 *     fontWeight = MaFontWeights.Normal
 * )
 *
 * Text(
 *     "42 tok/s • 256 tokens",
 *     fontFamily = MaFontFamilyMono,
 *     fontWeight = MaFontWeights.Medium
 * )
 *
 * Text(
 *     "Caption text",
 *     fontFamily = MaFontFamilyCaption,
 *     fontWeight = MaFontWeights.Normal
 * )
 * ```
 */
