package app.m1k3.ai.assistant.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.navigation.NavController
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.compose.currentBackStackEntryAsState
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.design.tokens.MaColors

/**
 * 間 AI - Bottom Navigation Bar
 *
 * Primary navigation interface with 6 tabs.
 *
 * **Navigation Tabs:**
 * - Chat: Main AI conversation interface
 * - History: Browse past conversations
 * - Settings: App configuration
 * - Demo: Welcome and feature showcase
 *
 * **Features:**
 * - Material3 NavigationBar
 * - Haptic feedback on tap
 * - State preservation across tabs
 * - Active tab highlighting
 *
 * **Philosophy:**
 * Simple, clear navigation. Every feature one tap away.
 */
@Composable
fun BottomNavigationBar(
    navController: NavController,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalHapticFeedback.current
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = navBackStackEntry?.destination

    NavigationBar(
        modifier = modifier,
        containerColor = MaColors.BgPrimary,
        contentColor = MaColors.TextSecondary,
    ) {
        bottomNavItems.forEach { item ->
            val isSelected =
                currentDestination?.hierarchy?.any {
                    it.route == item.screen.route
                } == true

            NavigationBarItem(
                icon = {
                    Icon(
                        imageVector = item.icon,
                        contentDescription = item.label,
                    )
                },
                label = {
                    Text(text = item.label)
                },
                selected = isSelected,
                onClick = {
                    if (!isSelected) {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        navController.navigateToBottomNav(item.screen)
                    }
                },
                alwaysShowLabel = true,
                colors =
                    NavigationBarItemDefaults.colors(
                        selectedIconColor = MaColors.Orange,
                        selectedTextColor = MaColors.Orange,
                        unselectedIconColor = MaColors.TextMuted,
                        unselectedTextColor = MaColors.TextMuted,
                        indicatorColor = MaColors.OrangeFaint,
                    ),
            )
        }
    }
}

/**
 * Bottom navigation item data class
 */
data class BottomNavItem(
    val screen: Screen,
    val label: String,
    val icon: ImageVector,
)

/**
 * Bottom navigation items configuration
 */
val bottomNavItems =
    listOf(
        BottomNavItem(
            screen = Screen.Chat,
            label = "Chat",
            icon = Icons.Default.Chat,
        ),
        BottomNavItem(
            screen = Screen.History,
            label = "History",
            icon = Icons.Default.History,
        ),
        BottomNavItem(
            screen = Screen.Settings,
            label = "Settings",
            icon = Icons.Default.Settings,
        ),
    )
