package app.m1k3.ai.assistant.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.sharp.Menu
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.m1k3.ai.assistant.avatar.AvatarEmotion
import app.m1k3.ai.assistant.avatar.AvatarState
import app.m1k3.ai.assistant.avatar.DotMatrixAvatar
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.design.tokens.*
import org.jetbrains.compose.ui.tooling.preview.Preview

/**
 * Unified persistent toolbar for all screens.
 *
 * Features:
 * - Hamburger menu icon for drawer toggle
 * - Liquid glass blur effect with gradient overlay
 * - Engine initialization status indicator
 * - The face, with emotion/activity feedback (100dp)
 * - Screen name display
 * - Consistent styling across all screens
 *
 * @param screenName Name of the current screen to display
 * @param engineInitialized Whether the AI engine is ready
 * @param avatarState Current avatar emotional/activity state
 * @param onMenuClick Callback when hamburger menu is clicked
 * @param modifier Optional modifier for customization
 */
@Composable
fun Toolbar(
    screenName: String,
    engineInitialized: Boolean,
    avatarState: AvatarState,
    onMenuClick: () -> Unit = {},
    onClearClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    var showOverflowMenu by remember { mutableStateOf(false) }
    val toolbarActions by LocalToolbarActions.current
    Box(
        modifier =
            modifier
                .fillMaxWidth(),
    ) {
        // Toolbar content
        Surface(
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = MaSpacing.md, vertical = 16.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Left side: Menu button + Title and status
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    // Hamburger menu button
                    IconButton(
                        onClick = onMenuClick,
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Sharp.Menu,
                            contentDescription = "Menu",
                            tint = MaColors.textPrimary(),
                        )
                    }

                    // Title and status
                    Column {
                        Text(
                            screenName,
                            style = MaTypography.titleLarge,
                            fontWeight = FontWeight.Bold,
                            color = MaColors.textPrimary(),
                        )
                        Text(
                            if (engineInitialized) avatarState.activity.displayName else "Loading...",
                            style =
                                TextStyle(
                                    fontFamily = MaFontFamilyBrand,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 24.sp,
                                    lineHeight = 16.sp,
                                    letterSpacing = 0.25.sp,
                                ),
                            color = if (engineInitialized) MaColors.Orange else MaColors.textSecondary(),
                        )
                    }
                }

                // Middle: New Chat (primary) + overflow menu
                Row(verticalAlignment = Alignment.CenterVertically) {
                    toolbarActions.onNewChat?.let { onNewChat ->
                        IconButton(
                            onClick = onNewChat,
                            modifier =
                                Modifier
                                    .testTag("toolbar_new_chat")
                                    .size(40.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Default.Add,
                                contentDescription = "New chat",
                                tint = MaColors.Orange,
                            )
                        }
                    }

                    if (onClearClick != null) {
                        Box {
                            IconButton(
                                onClick = { showOverflowMenu = true },
                                modifier = Modifier.size(40.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Default.MoreVert,
                                    contentDescription = "More options",
                                    tint = MaColors.textPrimary(),
                                )
                            }

                            DropdownMenu(
                                expanded = showOverflowMenu,
                                onDismissRequest = { showOverflowMenu = false },
                            ) {
                                DropdownMenuItem(
                                    text = { Text("New Chat") },
                                    onClick = {
                                        showOverflowMenu = false
                                        onClearClick()
                                    },
                                )
                            }
                        }
                    }
                }

                // Right side: the face — M1K3's one avatar.
                DotMatrixAvatar(
                    state = avatarState,
                    modifier =
                        Modifier
                            .testTag("avatar_unified")
                            .size(140.dp)
                            .statusBarsPadding(),
                )
            }
        }
    }
}

// ============================================================
// Previews
// ============================================================

@Preview
@Composable
private fun UnifiedToolbarChatReadyPreview() {
    MaTheme {
        Toolbar(
            screenName = "Chat",
            engineInitialized = true,
            avatarState = AvatarState(emotion = AvatarEmotion.HAPPY),
            onMenuClick = {},
        )
    }
}

@Preview
@Composable
private fun ToolbarHistoryLoadingPreview() {
    MaTheme {
        Toolbar(
            screenName = "History",
            engineInitialized = false,
            avatarState = AvatarState(emotion = AvatarEmotion.THINKING),
        )
    }
}

@Preview
@Composable
private fun ToolbarSettingsPreview() {
    MaTheme {
        Toolbar(
            screenName = "Settings",
            engineInitialized = true,
            avatarState = AvatarState(emotion = AvatarEmotion.NEUTRAL),
        )
    }
}
