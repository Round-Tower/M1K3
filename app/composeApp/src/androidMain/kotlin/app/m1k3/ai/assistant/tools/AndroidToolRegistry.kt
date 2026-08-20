package app.m1k3.ai.assistant.tools

import android.content.Context
import app.m1k3.ai.assistant.tools.executors.BatteryLevelExecutor
import app.m1k3.ai.assistant.tools.executors.GetHealthExecutor
import app.m1k3.ai.assistant.tools.executors.GetNotificationsExecutor
import app.m1k3.ai.assistant.tools.executors.GetScreenTimeExecutor
import app.m1k3.ai.assistant.tools.executors.GetTimeExecutor
import app.m1k3.ai.assistant.tools.executors.GetVolumeExecutor
import app.m1k3.ai.assistant.tools.executors.OpenBrowserExecutor
import app.m1k3.ai.assistant.tools.executors.OpenCameraExecutor
import app.m1k3.ai.assistant.tools.executors.OpenMapsExecutor
import app.m1k3.ai.assistant.tools.executors.OpenSettingsExecutor
import app.m1k3.ai.assistant.tools.executors.SetAlarmExecutor
import app.m1k3.ai.assistant.tools.executors.SetTimerExecutor
import app.m1k3.ai.assistant.tools.executors.SetVolumeExecutor
import app.m1k3.ai.assistant.tools.executors.ToggleFlashlightExecutor
import app.m1k3.ai.assistant.tools.executors.WebSearchExecutor
import app.m1k3.ai.domain.tools.ParameterType
import app.m1k3.ai.domain.tools.Tool
import app.m1k3.ai.domain.tools.ToolCategory
import app.m1k3.ai.domain.tools.ToolParameter

/**
 * Android Tool Registry - Registers Android-specific tool implementations
 *
 * Registers all platform-specific tool executors that use Android APIs
 * like Intents, system services, and ContentProviders.
 *
 * **Available Tools (11 total):**
 * - Device Info: battery level, current time, volume
 * - System Controls: flashlight, set volume, set alarm, set timer
 * - App Launchers: camera, browser, settings, maps
 * - Context Intelligence: notifications, health, screen time
 * - Web: search (DuckDuckGo, no API key)
 *
 * @param context Android application context
 */
class AndroidToolRegistry(
    private val context: Context,
) : ToolRegistryImpl() {
    init {
        registerDeviceInfoTools()
        registerSystemTools()
        registerAppLaunchers()
        registerTimerAndAlarmTools()
        registerContextTools()
        registerWebTools()
    }

    private fun registerDeviceInfoTools() {
        // Battery Level
        registerTool(
            Tool(
                id = "get_battery_level",
                name = "Get Battery Level",
                description = "Returns the current battery level as a percentage",
                parameters = emptyList(),
                category = ToolCategory.DEVICE_INFO,
            ),
            BatteryLevelExecutor(context),
        )

        // Get Time
        registerTool(
            Tool(
                id = "get_current_time",
                name = "Get Current Time",
                description = "Returns the current time in the specified format",
                parameters =
                    listOf(
                        ToolParameter(
                            name = "format",
                            type = ParameterType.STRING,
                            description = "Time format: 12h, 24h, or full (default: 12h)",
                            required = false,
                            defaultValue = "12h",
                        ),
                    ),
                category = ToolCategory.DEVICE_INFO,
            ),
            GetTimeExecutor(),
        )

        // Get Volume
        registerTool(
            Tool(
                id = "get_volume",
                name = "Get Volume",
                description = "Returns the current volume level for a stream (media, ring, alarm, notification)",
                parameters =
                    listOf(
                        ToolParameter(
                            name = "stream",
                            type = ParameterType.ENUM,
                            description = "Volume stream type",
                            required = false,
                            defaultValue = "media",
                            enumValues = listOf("media", "ring", "alarm", "notification"),
                        ),
                    ),
                category = ToolCategory.DEVICE_INFO,
            ),
            GetVolumeExecutor(context),
        )
    }

    private fun registerSystemTools() {
        // Flashlight
        registerTool(
            Tool(
                id = "toggle_flashlight",
                name = "Toggle Flashlight",
                description = "Turns the device flashlight on or off",
                parameters =
                    listOf(
                        ToolParameter(
                            name = "enable",
                            type = ParameterType.BOOLEAN,
                            description = "true to turn on, false to turn off",
                            required = true,
                        ),
                    ),
                category = ToolCategory.SYSTEM,
            ),
            ToggleFlashlightExecutor(context),
        )

        // Set Volume
        registerTool(
            Tool(
                id = "set_volume",
                name = "Set Volume",
                description = "Sets the volume level (0-100) for a stream (media, ring, alarm, notification)",
                parameters =
                    listOf(
                        ToolParameter(
                            name = "level",
                            type = ParameterType.NUMBER,
                            description = "Volume level 0-100",
                            required = true,
                        ),
                        ToolParameter(
                            name = "stream",
                            type = ParameterType.ENUM,
                            description = "Volume stream type",
                            required = false,
                            defaultValue = "media",
                            enumValues = listOf("media", "ring", "alarm", "notification"),
                        ),
                    ),
                category = ToolCategory.SYSTEM,
            ),
            SetVolumeExecutor(context),
        )
    }

    private fun registerAppLaunchers() {
        // Camera
        registerTool(
            Tool(
                id = "open_camera",
                name = "Open Camera",
                description = "Opens the device camera app",
                parameters = emptyList(),
                category = ToolCategory.APPS,
            ),
            OpenCameraExecutor(context),
        )

        // Browser
        registerTool(
            Tool(
                id = "open_browser",
                name = "Open Browser",
                description = "Opens a URL in the default web browser",
                parameters =
                    listOf(
                        ToolParameter(
                            name = "url",
                            type = ParameterType.STRING,
                            description = "The URL to open (defaults to google.com)",
                            required = false,
                            defaultValue = "https://google.com",
                        ),
                    ),
                category = ToolCategory.APPS,
            ),
            OpenBrowserExecutor(context),
        )

        // Settings
        registerTool(
            Tool(
                id = "open_settings",
                name = "Open Settings",
                description = "Opens device settings (main, wifi, bluetooth, display, sound, battery, or apps)",
                parameters =
                    listOf(
                        ToolParameter(
                            name = "section",
                            type = ParameterType.ENUM,
                            description = "Settings section to open",
                            required = false,
                            defaultValue = "main",
                            enumValues = listOf("main", "wifi", "bluetooth", "display", "sound", "battery", "apps"),
                        ),
                    ),
                category = ToolCategory.APPS,
            ),
            OpenSettingsExecutor(context),
        )

        // Maps
        registerTool(
            Tool(
                id = "open_maps",
                name = "Open Maps",
                description = "Opens maps for search or turn-by-turn navigation",
                parameters =
                    listOf(
                        ToolParameter(
                            name = "query",
                            type = ParameterType.STRING,
                            description = "Search query (e.g., 'coffee shop', '123 Main St')",
                            required = false,
                        ),
                        ToolParameter(
                            name = "destination",
                            type = ParameterType.STRING,
                            description = "Destination for turn-by-turn directions",
                            required = false,
                        ),
                        ToolParameter(
                            name = "mode",
                            type = ParameterType.ENUM,
                            description = "Navigation mode",
                            required = false,
                            defaultValue = "driving",
                            enumValues = listOf("driving", "walking", "bicycling", "transit"),
                        ),
                    ),
                category = ToolCategory.APPS,
            ),
            OpenMapsExecutor(context),
        )
    }

    private fun registerTimerAndAlarmTools() {
        // Set Alarm
        registerTool(
            Tool(
                id = "set_alarm",
                name = "Set Alarm",
                description = "Creates an alarm at the specified time",
                parameters =
                    listOf(
                        ToolParameter(
                            name = "hour",
                            type = ParameterType.NUMBER,
                            description = "Hour (0-23)",
                            required = true,
                        ),
                        ToolParameter(
                            name = "minute",
                            type = ParameterType.NUMBER,
                            description = "Minute (0-59)",
                            required = false,
                            defaultValue = "0",
                        ),
                        ToolParameter(
                            name = "message",
                            type = ParameterType.STRING,
                            description = "Label for the alarm",
                            required = false,
                        ),
                    ),
                category = ToolCategory.SYSTEM,
            ),
            SetAlarmExecutor(context),
        )

        // Set Timer
        registerTool(
            Tool(
                id = "set_timer",
                name = "Set Timer",
                description = "Creates a countdown timer",
                parameters =
                    listOf(
                        ToolParameter(
                            name = "hours",
                            type = ParameterType.NUMBER,
                            description = "Hours (0-24)",
                            required = false,
                            defaultValue = "0",
                        ),
                        ToolParameter(
                            name = "minutes",
                            type = ParameterType.NUMBER,
                            description = "Minutes (0-59)",
                            required = false,
                            defaultValue = "0",
                        ),
                        ToolParameter(
                            name = "seconds",
                            type = ParameterType.NUMBER,
                            description = "Seconds (0-59)",
                            required = false,
                            defaultValue = "0",
                        ),
                        ToolParameter(
                            name = "message",
                            type = ParameterType.STRING,
                            description = "Label for the timer",
                            required = false,
                        ),
                    ),
                category = ToolCategory.SYSTEM,
            ),
            SetTimerExecutor(context),
        )
    }

    private fun registerContextTools() {
        // Get Notifications (content, not just count)
        registerTool(
            Tool(
                id = "get_notifications",
                name = "Get Notifications",
                description = "Returns recent notification content — app name, title, and message text",
                parameters = emptyList(),
                category = ToolCategory.DEVICE_INFO,
            ),
            GetNotificationsExecutor(context),
        )

        // Get Health
        registerTool(
            Tool(
                id = "get_health",
                name = "Get Health Data",
                description = "Returns health data — steps today, sleep last night, heart rate, active calories",
                parameters = emptyList(),
                category = ToolCategory.DEVICE_INFO,
            ),
            GetHealthExecutor(context),
        )

        // Get Screen Time
        registerTool(
            Tool(
                id = "get_screen_time",
                name = "Get Screen Time",
                description = "Returns today's screen time total and top apps with usage",
                parameters = emptyList(),
                category = ToolCategory.DEVICE_INFO,
            ),
            GetScreenTimeExecutor(context),
        )
    }

    private fun registerWebTools() {
        // Web Search (DuckDuckGo — no API key, no tracking)
        registerTool(
            Tool(
                id = "web_search",
                name = "Web Search",
                description = "Search the web for weather, news, facts, answers, information, directions, and more using DuckDuckGo. No API key, no tracking.",
                parameters =
                    listOf(
                        ToolParameter(
                            name = "query",
                            type = ParameterType.STRING,
                            description = "Search query",
                            required = true,
                        ),
                    ),
                category = ToolCategory.KNOWLEDGE,
            ),
            WebSearchExecutor(),
        )
    }
}
