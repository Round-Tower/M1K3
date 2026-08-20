package app.m1k3.ai.assistant.design.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import org.jetbrains.compose.ui.tooling.preview.Preview
import app.m1k3.ai.assistant.design.preview.PreviewFixtures
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaDurations
import app.m1k3.ai.assistant.design.tokens.MaRadius
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography

/**
 * M1K3 Text Field Component
 *
 * Glassmorphic input field with:
 * - M1K3 orange focus glow
 * - AMOLED-optimized colors
 * - Smooth focus animations
 * - Multi-line support
 * - Placeholder text
 */

/**
 * Standard text input field with focus glow
 *
 * Features animated border color and width when focused.
 * Uses M1K3 orange accent for focus state.
 *
 * @param value Current text value
 * @param onValueChange Callback when text changes
 * @param modifier Optional modifier
 * @param placeholder Placeholder text (shown when empty)
 * @param enabled Whether field is enabled
 * @param singleLine Whether to restrict to single line
 * @param maxLines Maximum lines (if singleLine = false)
 * @param keyboardOptions Keyboard configuration
 * @param keyboardActions Keyboard actions (e.g., onDone, onSearch)
 */
@Composable
fun MaTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    enabled: Boolean = true,
    singleLine: Boolean = false,
    maxLines: Int = if (singleLine) 1 else Int.MAX_VALUE,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default
) {
    val interactionSource = remember { MutableInteractionSource() }
    val isFocused by interactionSource.collectIsFocusedAsState()

    // Animated focus glow
    val defaultBorderColor = MaColors.borderLight()
    val borderColor by animateColorAsState(
        targetValue = if (isFocused) MaColors.Orange else defaultBorderColor,
        animationSpec = tween(durationMillis = MaDurations.fast),
        label = "borderColor"
    )

    val borderWidth by animateDpAsState(
        targetValue = if (isFocused) 2.dp else 1.dp,
        animationSpec = tween(durationMillis = MaDurations.fast),
        label = "borderWidth"
    )

    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp),
        enabled = enabled,
        textStyle = MaTypography.bodyLarge.copy(
            color = if (enabled) MaColors.textPrimary() else MaColors.textDisabled()
        ),
        cursorBrush = SolidColor(MaColors.Orange),
        singleLine = singleLine,
        maxLines = maxLines,
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        interactionSource = interactionSource,
        decorationBox = { innerTextField ->
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(MaRadius.sm))
                    .background(
                        color = if (enabled) MaColors.bgSecondary() else MaColors.bgPrimary(),
                        shape = RoundedCornerShape(MaRadius.sm)
                    )
                    .border(
                        width = borderWidth,
                        color = borderColor,
                        shape = RoundedCornerShape(MaRadius.sm)
                    )
                    .padding(horizontal = MaSpacing.base, vertical = MaSpacing.md),
                contentAlignment = Alignment.CenterStart
            ) {
                if (value.isEmpty() && placeholder.isNotEmpty()) {
                    Text(
                        text = placeholder,
                        style = MaTypography.bodyLarge,
                        color = MaColors.textDisabled()
                    )
                }
                innerTextField()
            }
        }
    )
}

/**
 * Multi-line text input field (chat message composition)
 *
 * Pre-configured for chat input with:
 * - Multi-line support (max 6 lines)
 * - "Send" IME action
 * - Glassmorphic styling
 *
 * @param value Current text value
 * @param onValueChange Callback when text changes
 * @param onSend Callback when send action triggered
 * @param modifier Optional modifier
 * @param placeholder Placeholder text
 * @param enabled Whether field is enabled
 */
@Composable
fun MaTextFieldChat(
    value: String,
    onValueChange: (String) -> Unit,
    onSend: () -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "Type your message...",
    enabled: Boolean = true
) {
    MaTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        placeholder = placeholder,
        enabled = enabled,
        singleLine = false,
        maxLines = 6,
        keyboardOptions = KeyboardOptions.Default.copy(
            imeAction = ImeAction.Send
        ),
        keyboardActions = KeyboardActions(
            onSend = { onSend() }
        )
    )
}

/**
 * Single-line text input field (search, quick entry)
 *
 * Pre-configured for single-line input with:
 * - Search IME action
 * - Compact height
 *
 * @param value Current text value
 * @param onValueChange Callback when text changes
 * @param onSearch Callback when search action triggered
 * @param modifier Optional modifier
 * @param placeholder Placeholder text
 * @param enabled Whether field is enabled
 */
@Composable
fun MaTextFieldSearch(
    value: String,
    onValueChange: (String) -> Unit,
    onSearch: () -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "Search...",
    enabled: Boolean = true
) {
    MaTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        placeholder = placeholder,
        enabled = enabled,
        singleLine = true,
        keyboardOptions = KeyboardOptions.Default.copy(
            imeAction = ImeAction.Search
        ),
        keyboardActions = KeyboardActions(
            onSearch = { onSearch() }
        )
    )
}

/**
 * Usage Examples:
 * ```kotlin
 * // Basic text field
 * var text by remember { mutableStateOf("") }
 * MaTextField(
 *     value = text,
 *     onValueChange = { text = it },
 *     placeholder = "Enter text..."
 * )
 *
 * // Chat message input
 * var message by remember { mutableStateOf("") }
 * MaTextFieldChat(
 *     value = message,
 *     onValueChange = { message = it },
 *     onSend = {
 *         sendMessage(message)
 *         message = ""
 *     },
 *     placeholder = "Ask M1K3 anything..."
 * )
 *
 * // Search field
 * var query by remember { mutableStateOf("") }
 * MaTextFieldSearch(
 *     value = query,
 *     onValueChange = { query = it },
 *     onSearch = { performSearch(query) },
 *     placeholder = "Search knowledge base..."
 * )
 * ```
 */

// ============================================================
// Previews
// ============================================================

@Preview
@Composable
private fun MaTextFieldEmptyPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base),
            verticalArrangement = Arrangement.spacedBy(MaSpacing.base)
        ) {
            MaTextField(
                value = "",
                onValueChange = PreviewFixtures.noOpOnTextChange,
                placeholder = PreviewFixtures.sampleInputPlaceholder,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Preview
@Composable
private fun MaTextFieldWithTextPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base),
            verticalArrangement = Arrangement.spacedBy(MaSpacing.base)
        ) {
            MaTextField(
                value = PreviewFixtures.sampleInputText,
                onValueChange = PreviewFixtures.noOpOnTextChange,
                placeholder = PreviewFixtures.sampleInputPlaceholder,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Preview
@Composable
private fun MaTextFieldDisabledPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base),
            verticalArrangement = Arrangement.spacedBy(MaSpacing.base)
        ) {
            MaTextField(
                value = PreviewFixtures.sampleInputText,
                onValueChange = PreviewFixtures.noOpOnTextChange,
                placeholder = PreviewFixtures.sampleInputPlaceholder,
                enabled = false,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Preview
@Composable
private fun MaTextFieldMultilinePreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base),
            verticalArrangement = Arrangement.spacedBy(MaSpacing.base)
        ) {
            MaTextField(
                value = "Line 1\nLine 2\nLine 3",
                onValueChange = PreviewFixtures.noOpOnTextChange,
                placeholder = "Multi-line text...",
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Preview
@Composable
private fun MaTextFieldChatEmptyPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base),
            verticalArrangement = Arrangement.spacedBy(MaSpacing.base)
        ) {
            Text(
                "Chat Input (Empty):",
                style = MaTypography.labelSmall,
                color = MaColors.textSecondary(),
                modifier = Modifier.padding(bottom = MaSpacing.sm)
            )

            MaTextFieldChat(
                value = "",
                onValueChange = PreviewFixtures.noOpOnTextChange,
                onSend = PreviewFixtures.noOpOnClick,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Preview
@Composable
private fun MaTextFieldChatWithMessagePreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base),
            verticalArrangement = Arrangement.spacedBy(MaSpacing.base)
        ) {
            Text(
                "Chat Input (With Message):",
                style = MaTypography.labelSmall,
                color = MaColors.textSecondary(),
                modifier = Modifier.padding(bottom = MaSpacing.sm)
            )

            MaTextFieldChat(
                value = "What is machine learning?",
                onValueChange = PreviewFixtures.noOpOnTextChange,
                onSend = PreviewFixtures.noOpOnClick,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Preview
@Composable
private fun MaTextFieldSearchEmptyPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base),
            verticalArrangement = Arrangement.spacedBy(MaSpacing.base)
        ) {
            Text(
                "Search Field (Empty):",
                style = MaTypography.labelSmall,
                color = MaColors.textSecondary(),
                modifier = Modifier.padding(bottom = MaSpacing.sm)
            )

            MaTextFieldSearch(
                value = "",
                onValueChange = PreviewFixtures.noOpOnTextChange,
                onSearch = PreviewFixtures.noOpOnClick,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Preview
@Composable
private fun MaTextFieldSearchWithQueryPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base),
            verticalArrangement = Arrangement.spacedBy(MaSpacing.base)
        ) {
            Text(
                "Search Field (With Query):",
                style = MaTypography.labelSmall,
                color = MaColors.textSecondary(),
                modifier = Modifier.padding(bottom = MaSpacing.sm)
            )

            MaTextFieldSearch(
                value = "machine learning",
                onValueChange = PreviewFixtures.noOpOnTextChange,
                onSearch = PreviewFixtures.noOpOnClick,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Preview
@Composable
private fun MaTextFieldAllVariantsPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base),
            verticalArrangement = Arrangement.spacedBy(MaSpacing.base)
        ) {
            Text(
                "Basic TextField:",
                style = MaTypography.labelSmall,
                color = MaColors.textSecondary()
            )
            MaTextField(
                value = "",
                onValueChange = PreviewFixtures.noOpOnTextChange,
                placeholder = "Enter text...",
                modifier = Modifier.fillMaxWidth()
            )

            Text(
                "Chat TextField:",
                style = MaTypography.labelSmall,
                color = MaColors.textSecondary(),
                modifier = Modifier.padding(top = MaSpacing.base)
            )
            MaTextFieldChat(
                value = "",
                onValueChange = PreviewFixtures.noOpOnTextChange,
                onSend = PreviewFixtures.noOpOnClick,
                modifier = Modifier.fillMaxWidth()
            )

            Text(
                "Search TextField:",
                style = MaTypography.labelSmall,
                color = MaColors.textSecondary(),
                modifier = Modifier.padding(top = MaSpacing.base)
            )
            MaTextFieldSearch(
                value = "",
                onValueChange = PreviewFixtures.noOpOnTextChange,
                onSearch = PreviewFixtures.noOpOnClick,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}
