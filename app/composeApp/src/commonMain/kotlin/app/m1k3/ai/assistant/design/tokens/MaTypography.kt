package app.m1k3.ai.assistant.design.tokens

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * M1K3 AI Typography System
 *
 * Custom branded typography with local fonts:
 * - Silkscreen: M1K3 brand font (regular weight for optimal legibility)
 * - Roboto: Android default for body text (optimal readability)
 * - JetBrains Mono: Technical monospace for stats/code
 * - Doto: Caption font for secondary text and descriptions
 *
 * Material3 type scale optimized for mobile readability and terminal aesthetic.
 * Scale: 7 levels from 12sp (label) to 57sp (display)
 * Line heights: 1.25-1.5x for optimal readability
 */
val MaTypography =
    Typography(
        // ============================================
        // Display Styles - Large marketing/hero text
        // Uses Silkscreen (brand font) for strong visual identity
        // ============================================
        displayLarge =
            TextStyle(
                fontFamily = MaFontFamilyBrand,
                fontWeight = FontWeight.Normal,
                fontSize = 57.sp,
                lineHeight = 64.sp,
                letterSpacing = (-0.25).sp,
            ),
        displayMedium =
            TextStyle(
                fontFamily = MaFontFamilyBrand,
                fontWeight = FontWeight.Normal,
                fontSize = 45.sp,
                lineHeight = 52.sp,
                letterSpacing = 0.sp,
            ),
        displaySmall =
            TextStyle(
                fontFamily = MaFontFamilyBrand,
                fontWeight = FontWeight.Normal,
                fontSize = 36.sp,
                lineHeight = 44.sp,
                letterSpacing = 0.sp,
            ),
        // ============================================
        // Headline Styles - Section headers
        // Uses Silkscreen for branded section headers
        // ============================================
        headlineLarge =
            TextStyle(
                fontFamily = MaFontFamilyBrand,
                fontWeight = FontWeight.Normal,
                fontSize = 32.sp,
                lineHeight = 40.sp,
                letterSpacing = 0.sp,
            ),
        headlineMedium =
            TextStyle(
                fontFamily = MaFontFamilyBrand,
                fontWeight = FontWeight.Normal,
                fontSize = 28.sp,
                lineHeight = 36.sp,
                letterSpacing = 0.sp,
            ),
        // headlineSmall carries multi-line copy (onboarding taglines, error
        // text) — never the blocky brand font at that length; Silkscreen
        // stays for headlineMedium/Large's short, single-line moments.
        headlineSmall =
            TextStyle(
                fontFamily = MaFontFamilyBody,
                fontWeight = FontWeight.Normal,
                fontSize = 24.sp,
                lineHeight = 32.sp,
                letterSpacing = 0.sp,
            ),
        // ============================================
        // Title Styles - Component headers, app bars
        //
        // Normal type, not the brand pixel font. The pixel font is a
        // costume M1K3 wears (his face, the wordmark, waking-up moments) —
        // never Apple/Android's own chrome (screen titles, dialog titles,
        // rendered markdown headings). See macos/docs/DESIGN_DOCTRINE.md
        // principles 1–2. Screen titles ("Settings", "Memories",
        // "Conversations") default to this role via TopAppBar.
        // ============================================
        titleLarge =
            TextStyle(
                fontFamily = MaFontFamilyBody,
                fontWeight = FontWeight.SemiBold,
                fontSize = 22.sp,
                lineHeight = 28.sp,
                letterSpacing = 0.sp,
            ),
        titleMedium =
            TextStyle(
                fontFamily = MaFontFamilyBody,
                fontWeight = FontWeight.SemiBold,
                fontSize = 16.sp,
                lineHeight = 24.sp,
                letterSpacing = 0.15.sp,
            ),
        titleSmall =
            TextStyle(
                fontFamily = MaFontFamilyBody,
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp,
                lineHeight = 20.sp,
                letterSpacing = 0.1.sp,
            ),
        // ============================================
        // Body Styles - Main content text
        // Uses system Roboto for optimal readability
        // ============================================
        bodyLarge =
            TextStyle(
                fontFamily = MaFontFamilyBody,
                fontWeight = FontWeight.Normal,
                fontSize = 16.sp,
                lineHeight = 24.sp,
                letterSpacing = 0.5.sp,
            ),
        bodyMedium =
            TextStyle(
                fontFamily = MaFontFamilyBody,
                fontWeight = FontWeight.Normal,
                fontSize = 14.sp,
                lineHeight = 20.sp,
                letterSpacing = 0.25.sp,
            ),
        bodySmall =
            TextStyle(
                fontFamily = MaFontFamilyBody,
                fontWeight = FontWeight.Normal,
                fontSize = 12.sp,
                lineHeight = 16.sp,
                letterSpacing = 0.4.sp,
            ),
        // ============================================
        // Label Styles - Buttons, chips, badges
        // Uses system Roboto for UI consistency
        // ============================================
        labelLarge =
            TextStyle(
                fontFamily = MaFontFamilyBody,
                fontWeight = FontWeight.Medium,
                fontSize = 14.sp,
                lineHeight = 20.sp,
                letterSpacing = 0.1.sp,
            ),
        labelMedium =
            TextStyle(
                fontFamily = MaFontFamilyBody,
                fontWeight = FontWeight.Medium,
                fontSize = 12.sp,
                lineHeight = 16.sp,
                letterSpacing = 0.5.sp,
            ),
        labelSmall =
            TextStyle(
                fontFamily = MaFontFamilyBody,
                fontWeight = FontWeight.Medium,
                fontSize = 11.sp,
                lineHeight = 16.sp,
                letterSpacing = 0.5.sp,
            ),
    )

// ============================================
// Caption Styles - Secondary text, descriptions
// Uses Doto font for distinctive, readable captions
// ============================================

val MaTypographyCaptionLarge =
    TextStyle(
        fontFamily = MaFontFamilyCaption,
        fontWeight = FontWeight.Medium,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.1.sp,
    )

val MaTypographyCaptionMedium =
    TextStyle(
        fontFamily = MaFontFamilyCaption,
        fontWeight = FontWeight.Normal,
        fontSize = 12.sp,
        lineHeight = 16.sp,
        letterSpacing = 0.25.sp,
    )

val MaTypographyCaptionSmall =
    TextStyle(
        fontFamily = MaFontFamilyCaption,
        fontWeight = FontWeight.Normal,
        fontSize = 11.sp,
        lineHeight = 16.sp,
        letterSpacing = 0.4.sp,
    )

/**
 * Typography Usage Guidelines
 *
 * Display: Hero sections, splash screens (displayLarge/Medium/Small)
 * Headline: Section headers, page titles (headlineLarge/Medium/Small)
 * Title: Component headers, dialog titles, app bar (titleLarge/Medium/Small)
 * Body: Paragraph text, list items, chat messages (bodyLarge/Medium/Small)
 * Label: Buttons, chips, metadata, badges (labelLarge/Medium/Small)
 * Caption: Secondary text, descriptions, metadata (captionLarge/Medium/Small)
 *
 * Example Usage:
 * ```kotlin
 * Text(
 *     text = "M1K3 AI",
 *     style = MaterialTheme.typography.displayLarge
 * )
 *
 * Text(
 *     text = "Secondary description",
 *     style = MaterialTheme.typography.captionMedium
 * )
 * ```
 */
