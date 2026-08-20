package app.m1k3.ai.assistant.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.design.haptics.rememberHapticFeedback
import app.m1k3.ai.assistant.design.preview.PreviewFixtures
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaRadius
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography
import org.jetbrains.compose.ui.tooling.preview.Preview

/**
 * ChatInputBar - Glassmorphic floating input with integrated send and mic.
 *
 * The bar is intentionally minimal: text field, voice mic, send.
 * Model, context, and eco signals live above in [ChatContextBar];
 * "New chat" lives in ChatScreen's own top bar; the "speak replies aloud"
 * preference lives in Settings → Voice.
 */
@Composable
fun ChatInputBar(
    text: String,
    onTextChange: (String) -> Unit,
    onSend: () -> Unit,
    enabled: Boolean,
    isListening: Boolean = false,
    onMicClick: (() -> Unit)? = null,
    listeningPartialText: String = "",
    onFocusChanged: (Boolean) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val isFocused by interactionSource.collectIsFocusedAsState()
    val hasText = text.isNotBlank()
    val haptics = rememberHapticFeedback()
    val focusRequester = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current

    var previousText by remember { mutableStateOf(text) }

    LaunchedEffect(text) {
        if (previousText.isEmpty() && text.isNotEmpty()) {
            haptics.light()
        }
        previousText = text
    }

    LaunchedEffect(isFocused) { onFocusChanged(isFocused) }

    val borderSubtle = MaColors.borderSubtle()
    val borderLight = MaColors.borderLight()
    val borderColor by animateColorAsState(
        targetValue =
            when {
                !enabled -> borderSubtle
                isFocused -> MaColors.Orange.copy(alpha = 0.6f)
                else -> borderLight
            },
        animationSpec = tween(durationMillis = 250),
        label = "borderColor",
    )

    val sendButtonScale by animateFloatAsState(
        targetValue = if (hasText && enabled) 1f else 0f,
        animationSpec =
            spring(
                dampingRatio = Spring.DampingRatioMediumBouncy,
                stiffness = Spring.StiffnessMedium,
            ),
        label = "sendButtonScale",
    )

    val pillShape = RoundedCornerShape(MaRadius.xl)

    Column(
        modifier =
            modifier
                .fillMaxWidth()
                .padding(start = MaSpacing.md, end = MaSpacing.md, bottom = MaSpacing.sm),
    ) {
        Box(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .clip(pillShape)
                    .background(color = MaColors.bgElevated(), shape = pillShape)
                    .border(
                        width = if (isFocused) 1.5.dp else 1.dp,
                        color = borderColor,
                        shape = pillShape,
                    ),
        ) {
            Row(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 52.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                BasicTextField(
                    value = text,
                    onValueChange = onTextChange,
                    modifier =
                        Modifier
                            .testTag("input_field")
                            .weight(1f)
                            .heightIn(min = 52.dp, max = 200.dp)
                            .padding(
                                start = MaSpacing.base,
                                top = MaSpacing.md,
                                bottom = MaSpacing.md,
                                end = MaSpacing.xs,
                            ).focusRequester(focusRequester)
                            .verticalScroll(rememberScrollState()),
                    enabled = enabled,
                    textStyle =
                        MaTypography.bodyLarge.copy(
                            color = if (enabled) MaColors.textPrimary() else MaColors.textDisabled(),
                        ),
                    cursorBrush = SolidColor(MaColors.Orange),
                    maxLines = 8,
                    keyboardOptions = KeyboardOptions.Default.copy(imeAction = ImeAction.Send),
                    keyboardActions =
                        KeyboardActions(
                            onSend = {
                                if (hasText && enabled) {
                                    haptics.strong()
                                    onSend()
                                    keyboardController?.hide()
                                    focusManager.clearFocus()
                                }
                            },
                        ),
                    interactionSource = interactionSource,
                    decorationBox = { innerTextField ->
                        Box(contentAlignment = Alignment.CenterStart) {
                            if (text.isEmpty()) {
                                Text(
                                    text =
                                        if (isListening) {
                                            listeningPartialText.ifBlank { "Listening..." }
                                        } else {
                                            "Ask M1K3…"
                                        },
                                    style = MaTypography.bodyLarge,
                                    color =
                                        if (isListening) {
                                            MaColors.Orange.copy(alpha = 0.7f)
                                        } else {
                                            MaColors.textMuted()
                                        },
                                )
                            }
                            innerTextField()
                        }
                    },
                )

                if (!hasText && onMicClick != null && sendButtonScale < 0.01f) {
                    val micPulse by animateFloatAsState(
                        targetValue = if (isListening) 1.15f else 1f,
                        animationSpec =
                            if (isListening) {
                                infiniteRepeatable(
                                    animation = tween(600, easing = FastOutSlowInEasing),
                                    repeatMode = RepeatMode.Reverse,
                                )
                            } else {
                                tween(200)
                            },
                        label = "micPulse",
                    )

                    Box(
                        modifier =
                            Modifier
                                .testTag("mic_button")
                                .padding(end = MaSpacing.xs, bottom = MaSpacing.xs)
                                .size(40.dp)
                                .scale(micPulse)
                                .clip(CircleShape)
                                .background(
                                    if (isListening) MaColors.Orange else MaColors.Orange.copy(alpha = 0.15f),
                                    CircleShape,
                                ).clickable(
                                    enabled = enabled,
                                    onClick = {
                                        haptics.medium()
                                        onMicClick()
                                    },
                                    indication = null,
                                    interactionSource = remember { MutableInteractionSource() },
                                ),
                        contentAlignment = Alignment.Center,
                    ) {
                        MicIcon(color = if (isListening) MaColors.White else MaColors.Orange)
                    }
                }

                if (sendButtonScale > 0.01f) {
                    Box(
                        modifier =
                            Modifier
                                .testTag("send_button")
                                .padding(end = MaSpacing.xs, bottom = MaSpacing.xs)
                                .size(40.dp)
                                .scale(sendButtonScale)
                                .clip(CircleShape)
                                .background(MaColors.Orange, CircleShape)
                                .clickable(
                                    enabled = hasText && enabled,
                                    onClick = {
                                        haptics.strong()
                                        onSend()
                                        keyboardController?.hide()
                                        focusManager.clearFocus()
                                    },
                                    indication = null,
                                    interactionSource = remember { MutableInteractionSource() },
                                ),
                        contentAlignment = Alignment.Center,
                    ) {
                        SendArrowIcon(color = MaColors.White)
                    }
                }
            }
        }
    }
}

@Composable
private fun SendArrowIcon(
    color: androidx.compose.ui.graphics.Color,
    modifier: Modifier = Modifier.size(20.dp),
) {
    Canvas(modifier = modifier) {
        val strokeWidth = 2.5f
        val centerX = size.width / 2
        val centerY = size.height / 2
        val arrowLength = size.height * 0.5f

        drawLine(
            color = color,
            start = Offset(centerX, centerY + arrowLength / 2),
            end = Offset(centerX, centerY - arrowLength / 2),
            strokeWidth = strokeWidth,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = color,
            start = Offset(centerX, centerY - arrowLength / 2),
            end = Offset(centerX - arrowLength / 3, centerY - arrowLength / 2 + arrowLength / 3),
            strokeWidth = strokeWidth,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = color,
            start = Offset(centerX, centerY - arrowLength / 2),
            end = Offset(centerX + arrowLength / 3, centerY - arrowLength / 2 + arrowLength / 3),
            strokeWidth = strokeWidth,
            cap = StrokeCap.Round,
        )
    }
}

@Composable
private fun MicIcon(
    color: androidx.compose.ui.graphics.Color,
    modifier: Modifier = Modifier.size(20.dp),
) {
    Canvas(modifier = modifier) {
        val sw = 2.5f
        val cx = size.width / 2
        val cy = size.height / 2

        val micWidth = size.width * 0.25f
        val micHeight = size.height * 0.4f
        val micTop = cy - micHeight / 2 - size.height * 0.05f

        drawLine(
            color,
            Offset(cx - micWidth / 2, micTop + micHeight),
            Offset(cx - micWidth / 2, micTop + micWidth / 2),
            sw,
            StrokeCap.Round,
        )
        drawLine(
            color,
            Offset(cx + micWidth / 2, micTop + micHeight),
            Offset(cx + micWidth / 2, micTop + micWidth / 2),
            sw,
            StrokeCap.Round,
        )
        drawLine(color, Offset(cx - micWidth / 2, micTop + micWidth / 2), Offset(cx, micTop), sw, StrokeCap.Round)
        drawLine(color, Offset(cx + micWidth / 2, micTop + micWidth / 2), Offset(cx, micTop), sw, StrokeCap.Round)

        val cupY = micTop + micHeight + size.height * 0.03f
        drawLine(color, Offset(cx - micWidth, cupY), Offset(cx - micWidth, cupY - size.height * 0.08f), sw, StrokeCap.Round)
        drawLine(color, Offset(cx + micWidth, cupY), Offset(cx + micWidth, cupY - size.height * 0.08f), sw, StrokeCap.Round)
        drawLine(color, Offset(cx - micWidth, cupY), Offset(cx + micWidth, cupY), sw, StrokeCap.Round)

        val standBottom = size.height * 0.85f
        drawLine(color, Offset(cx, cupY), Offset(cx, standBottom), sw, StrokeCap.Round)
        drawLine(color, Offset(cx - micWidth * 0.8f, standBottom), Offset(cx + micWidth * 0.8f, standBottom), sw, StrokeCap.Round)
    }
}

/**
 * Container for ChatInputBar with gradient fade above.
 */
@Composable
fun ChatInputBarContainer(
    inputBar: @Composable () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth()) {
        Box(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .height(32.dp)
                    .background(
                        brush =
                            Brush.verticalGradient(
                                colors =
                                    listOf(
                                        MaColors.bgPrimary().copy(alpha = 0f),
                                        MaColors.bgPrimary(),
                                    ),
                            ),
                    ),
        )

        Box(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .background(MaColors.bgPrimary()),
        ) {
            inputBar()
        }
    }
}

@Preview
@Composable
private fun ChatInputBarEmptyPreview() {
    MaTheme {
        Column(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .background(MaColors.BgPrimary)
                    .padding(MaSpacing.base),
        ) {
            ChatInputBar(
                text = "",
                onTextChange = PreviewFixtures.noOpOnTextChange,
                onSend = PreviewFixtures.noOpOnClick,
                enabled = true,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Preview
@Composable
private fun ChatInputBarWithTextPreview() {
    MaTheme {
        Column(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .background(MaColors.BgPrimary)
                    .padding(MaSpacing.base),
        ) {
            ChatInputBar(
                text = "What is machine learning?",
                onTextChange = PreviewFixtures.noOpOnTextChange,
                onSend = PreviewFixtures.noOpOnClick,
                enabled = true,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Preview
@Composable
private fun ChatInputBarDisabledPreview() {
    MaTheme {
        Column(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .background(MaColors.BgPrimary)
                    .padding(MaSpacing.base),
        ) {
            ChatInputBar(
                text = "Processing...",
                onTextChange = PreviewFixtures.noOpOnTextChange,
                onSend = PreviewFixtures.noOpOnClick,
                enabled = false,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
