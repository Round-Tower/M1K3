package app.m1k3.ai.assistant.ui.drawer

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography
import app.m1k3.ai.assistant.navigation.SidebarMenuItem
import app.m1k3.ai.assistant.navigation.primaryNavItems
import app.m1k3.ai.assistant.navigation.sidebarItems

/**
 * DrawerContent - Navigation drawer with primary + secondary items.
 *
 * Layout:
 * - 間 M1K3 branded header
 * - Primary nav (Chat, History, Settings)
 * - Divider
 * - Secondary nav (About, Help, Feedback, Privacy, Export)
 *
 * This is the sole navigation paradigm — no bottom nav bar.
 */
@Composable
fun DrawerContent(
    currentRoute: String?,
    isDarkMode: Boolean,
    onItemClick: (String) -> Unit,
    onMenuClose: () -> Unit,
    modifier: Modifier = Modifier
) {
    ModalDrawerSheet(
        modifier = modifier
            .fillMaxHeight()
            .width(280.dp),
        drawerContainerColor = if (isDarkMode) MaColors.BgPrimary else MaColors.BgPrimaryLight
    ) {
        DrawerHeader(isDarkMode = isDarkMode)

        HorizontalDivider(
            color = if (isDarkMode) MaColors.BorderSubtle else MaColors.BorderSubtleLight,
            thickness = 1.dp
        )

        Spacer(modifier = Modifier.height(MaSpacing.md))

        // Primary navigation items
        PrimaryNavSection(
            currentRoute = currentRoute,
            onItemClick = onItemClick,
            onMenuClose = onMenuClose
        )

        Spacer(modifier = Modifier.height(MaSpacing.sm))

        HorizontalDivider(
            modifier = Modifier.padding(horizontal = MaSpacing.lg),
            color = if (isDarkMode) MaColors.BorderSubtle else MaColors.BorderSubtleLight,
            thickness = 1.dp
        )

        Spacer(modifier = Modifier.height(MaSpacing.sm))

        // Secondary / meta navigation items
        SecondaryNavSection(
            currentRoute = currentRoute,
            onItemClick = onItemClick,
            onMenuClose = onMenuClose
        )

        Spacer(modifier = Modifier.weight(1f))
        Spacer(modifier = Modifier.height(MaSpacing.lg))
    }
}

@Composable
private fun DrawerHeader(isDarkMode: Boolean) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = MaSpacing.base,
                vertical = MaSpacing.lg
            ),
        horizontalAlignment = Alignment.Start
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(MaSpacing.md)
        ) {
            Text(
                "間",
                style = MaTypography.displaySmall,
                color = MaColors.Orange
            )
            Column {
                Text(
                    "M1K3",
                    style = MaTypography.headlineLarge,
                    fontWeight = FontWeight.Bold,
                    color = MaColors.textPrimary()
                )
                Text(
                    "Call me Mike",
                    style = MaTypography.bodySmall,
                    color = MaColors.textMuted()
                )
            }
        }
    }
}

@Composable
private fun PrimaryNavSection(
    currentRoute: String?,
    onItemClick: (String) -> Unit,
    onMenuClose: () -> Unit
) {
    val haptics = LocalHapticFeedback.current

    primaryNavItems.forEach { item ->
        val isSelected = currentRoute == item.screen.route

        SidebarMenuItem(
            icon = item.icon,
            label = item.label,
            isSelected = isSelected,
            onClick = {
                if (!isSelected) {
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    onItemClick(item.screen.route)
                }
                onMenuClose()
            },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = MaSpacing.base)
        )

        Spacer(modifier = Modifier.height(MaSpacing.xs))
    }
}

@Composable
private fun SecondaryNavSection(
    currentRoute: String?,
    onItemClick: (String) -> Unit,
    onMenuClose: () -> Unit
) {
    val haptics = LocalHapticFeedback.current

    sidebarItems.forEach { item ->
        val isSelected = currentRoute == item.screen.route

        SidebarMenuItem(
            icon = item.icon,
            label = item.label,
            isSelected = isSelected,
            onClick = {
                if (!isSelected) {
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    onItemClick(item.screen.route)
                }
                onMenuClose()
            },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = MaSpacing.base)
        )

        Spacer(modifier = Modifier.height(MaSpacing.xs))
    }
}
