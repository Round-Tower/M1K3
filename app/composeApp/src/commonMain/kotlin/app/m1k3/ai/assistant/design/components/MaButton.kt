package app.m1k3.ai.assistant.design.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.jetbrains.compose.ui.tooling.preview.Preview
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaRadius
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.design.preview.PreviewFixtures

/**
 * M1K3 Button Components
 *
 * M1K3 orange branded buttons with variants:
 * - MaButtonPrimary: Filled orange button (primary actions)
 * - MaButtonSecondary: Outlined button (secondary actions)
 * - MaButtonText: Text-only button (tertiary actions)
 */

/**
 * Primary filled button with M1K3 orange
 *
 * Use for primary/call-to-action buttons (e.g., "Chat", "Send", "Confirm")
 */
@Composable
fun MaButtonPrimary(
    onClick: () -> Unit,
    text: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true
) {
    Button(
        onClick = onClick,
        modifier = modifier.height(56.dp),
        enabled = enabled,
        shape = RoundedCornerShape(MaRadius.sm),
        colors = ButtonDefaults.buttonColors(
            containerColor = MaColors.Orange,
            contentColor = MaColors.White,
            disabledContainerColor = MaColors.OrangeDim,
            disabledContentColor = MaColors.textDisabled()
        ),
        contentPadding = PaddingValues(
            horizontal = MaSpacing.lg,
            vertical = MaSpacing.md
        )
    ) {
        Text(
            text = text,
            fontWeight = FontWeight.Bold
        )
    }
}

/**
 * Secondary outlined button
 *
 * Use for secondary actions (e.g., "Cancel", "Back", "Settings")
 */
@Composable
fun MaButtonSecondary(
    onClick: () -> Unit,
    text: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true
) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier.height(56.dp),
        enabled = enabled,
        shape = RoundedCornerShape(MaRadius.sm),
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = MaColors.textPrimary(),
            disabledContentColor = MaColors.textDisabled()
        ),
        border = ButtonDefaults.outlinedButtonBorder.copy(
            brush = androidx.compose.ui.graphics.SolidColor(
                if (enabled) MaColors.borderLight() else MaColors.borderSubtle()
            )
        ),
        contentPadding = PaddingValues(
            horizontal = MaSpacing.lg,
            vertical = MaSpacing.md
        )
    ) {
        Text(
            text = text,
            fontWeight = FontWeight.Medium
        )
    }
}

/**
 * Text-only button
 *
 * Use for tertiary actions (e.g., "Learn More", "Skip", navigation)
 */
@Composable
fun MaButtonText(
    onClick: () -> Unit,
    text: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true
) {
    TextButton(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        colors = ButtonDefaults.textButtonColors(
            contentColor = MaColors.Orange,
            disabledContentColor = MaColors.textDisabled()
        ),
        contentPadding = PaddingValues(
            horizontal = MaSpacing.base,
            vertical = MaSpacing.sm
        )
    ) {
        Text(
            text = text,
            fontWeight = FontWeight.Medium
        )
    }
}

/**
 * Usage Examples:
 * ```kotlin
 * // Primary action
 * MaButtonPrimary(
 *     onClick = { /* navigate to chat */ },
 *     text = "Start Chat",
 *     modifier = Modifier.fillMaxWidth()
 * )
 *
 * // Secondary action
 * MaButtonSecondary(
 *     onClick = { /* go back */ },
 *     text = "Back"
 * )
 *
 * // Text action
 * MaButtonText(
 *     onClick = { /* show settings */ },
 *     text = "Settings"
 * )
 * ```
 */

// ============================================================
// Previews
// ============================================================

@Preview
@Composable
private fun MaButtonPrimaryPreview() {
    MaTheme {
        MaButtonPrimary(
            onClick = PreviewFixtures.noOpOnClick,
            text = PreviewFixtures.buttonTextPrimary
        )
    }
}

@Preview
@Composable
private fun MaButtonSecondaryPreview() {
    MaTheme {
        MaButtonSecondary(
            onClick = PreviewFixtures.noOpOnClick,
            text = PreviewFixtures.buttonTextSecondary
        )
    }
}

@Preview
@Composable
private fun MaButtonTextPreview() {
    MaTheme {
        MaButtonText(
            onClick = PreviewFixtures.noOpOnClick,
            text = PreviewFixtures.buttonTextCancel
        )
    }
}

@Preview
@Composable
private fun MaButtonPrimaryDisabledPreview() {
    MaTheme {
        MaButtonPrimary(
            onClick = PreviewFixtures.noOpOnClick,
            text = PreviewFixtures.buttonTextPrimary,
            enabled = false
        )
    }
}

@Preview
@Composable
private fun MaButtonSecondaryDisabledPreview() {
    MaTheme {
        MaButtonSecondary(
            onClick = PreviewFixtures.noOpOnClick,
            text = PreviewFixtures.buttonTextSecondary,
            enabled = false
        )
    }
}

@Preview
@Composable
private fun MaButtonAllVariantsPreview() {
    MaTheme {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text("Enabled Variants:")
            MaButtonPrimary(
                onClick = PreviewFixtures.noOpOnClick,
                text = "Primary Button"
            )
            MaButtonSecondary(
                onClick = PreviewFixtures.noOpOnClick,
                text = "Secondary Button"
            )
            MaButtonText(
                onClick = PreviewFixtures.noOpOnClick,
                text = "Text Button"
            )

            Spacer(modifier = Modifier.height(16.dp))
            Text("Disabled Variants:")
            MaButtonPrimary(
                onClick = PreviewFixtures.noOpOnClick,
                text = "Disabled Primary",
                enabled = false
            )
            MaButtonSecondary(
                onClick = PreviewFixtures.noOpOnClick,
                text = "Disabled Secondary",
                enabled = false
            )
            MaButtonText(
                onClick = PreviewFixtures.noOpOnClick,
                text = "Disabled Text",
                enabled = false
            )
        }
    }
}
