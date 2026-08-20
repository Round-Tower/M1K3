package app.m1k3.ai.assistant.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Navigation item data class for sidebar menu
 */
data class NavItem(
    val screen: Screen,
    val label: String,
    val icon: ImageVector,
)

/**
 * Primary navigation items — main app workflows.
 *
 * These are the core screens the user moves between frequently.
 * Displayed prominently at the top of the drawer.
 */
val primaryNavItems =
    listOf(
        NavItem(
            screen = Screen.Chat,
            label = "Chat",
            icon = Icons.Default.Chat,
        ),
        NavItem(
            screen = Screen.History,
            label = "History",
            icon = Icons.Default.History,
        ),
        NavItem(
            screen = Screen.AvatarGallery,
            label = "Avatar",
            icon = Icons.Default.Face,
        ),
        NavItem(
            screen = Screen.Settings,
            label = "Settings",
            icon = Icons.Default.Settings,
        ),
    )

/**
 * Secondary navigation items — meta/app-level actions.
 *
 * Less frequently accessed screens shown below a divider.
 */
val sidebarItems =
    listOf(
        NavItem(
            screen = Screen.About,
            label = "About M1K3",
            icon = Icons.Default.Info,
        ),
        NavItem(
            screen = Screen.Licenses,
            label = "Licenses",
            icon = Icons.Default.Code,
        ),
        NavItem(
            screen = Screen.Help,
            label = "Help & Docs",
            icon = Icons.Default.Help,
        ),
        NavItem(
            screen = Screen.Feedback,
            label = "Send Feedback",
            icon = Icons.Default.Feedback,
        ),
        NavItem(
            screen = Screen.Privacy,
            label = "Privacy Policy",
            icon = Icons.Default.Shield,
        ),
        NavItem(
            screen = Screen.Export,
            label = "Export Data",
            icon = Icons.Default.Download,
        ),
    )
