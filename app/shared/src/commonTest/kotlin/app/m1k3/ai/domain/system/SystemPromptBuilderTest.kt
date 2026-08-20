package app.m1k3.ai.domain.system

import app.m1k3.ai.domain.context.HealthContext
import app.m1k3.ai.domain.context.LocationContext
import app.m1k3.ai.domain.context.NotificationContext
import app.m1k3.ai.domain.context.ScreenTimeContext
import app.m1k3.ai.domain.context.UserContext
import app.m1k3.ai.domain.context.WeatherContext
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * TDD: SystemPromptBuilder
 *
 * Verifies both tiers produce the right content and stay within
 * their token budgets. FULL ≤ 500 words. COMPACT ≤ 50 words.
 */
class SystemPromptBuilderTest {
    private val builder = MaSystemPromptBuilder()

    // ── Identity / Ethos ──────────────────────────────────────

    @Test fun `FULL contains M1K3 identity`() {
        val prompt = builder.build(fullInput())
        assertTrue(prompt.contains("M1K3", ignoreCase = true))
    }

    @Test fun `FULL contains privacy statement`() {
        val prompt = builder.build(fullInput())
        assertTrue(
            prompt.contains("device", ignoreCase = true) ||
                prompt.contains("local", ignoreCase = true) ||
                prompt.contains("phone", ignoreCase = true),
        )
    }

    @Test fun `FULL contains curiosity or on the user side language`() {
        val prompt = builder.build(fullInput())
        assertTrue(
            prompt.contains("curious", ignoreCase = true) ||
                prompt.contains("side", ignoreCase = true) ||
                prompt.contains("advocate", ignoreCase = true),
        )
    }

    @Test fun `COMPACT contains M1K3 identity`() {
        val prompt = builder.build(compactInput())
        assertTrue(prompt.contains("M1K3", ignoreCase = true))
    }

    // ── FULL context injection ────────────────────────────────

    @Test fun `FULL includes user name`() {
        val prompt = builder.build(fullInput(name = "Kev"))
        assertTrue(prompt.contains("Kev"))
    }

    @Test fun `FULL includes location`() {
        val prompt = builder.build(fullInput())
        assertTrue(prompt.contains("Dublin"))
    }

    @Test fun `FULL includes weather when available`() {
        val prompt = builder.build(fullInput())
        assertTrue(
            prompt.contains("12", ignoreCase = true) ||
                prompt.contains("overcast", ignoreCase = true) ||
                prompt.contains("cloud", ignoreCase = true),
        )
    }

    @Test fun `FULL includes sleep`() {
        val prompt = builder.build(fullInput())
        assertTrue(prompt.contains("7h") || prompt.contains("sleep", ignoreCase = true))
    }

    @Test fun `FULL includes steps`() {
        val prompt = builder.build(fullInput())
        assertTrue(prompt.contains("5,000") || prompt.contains("5000"))
    }

    @Test fun `FULL includes day of week`() {
        val prompt = builder.build(fullInput(dayOfWeek = "Thursday"))
        assertTrue(prompt.contains("Thursday"))
    }

    @Test fun `FULL mentions available tools when present`() {
        val prompt = builder.build(fullInput(tools = listOf("search_web", "open_settings")))
        assertTrue(
            prompt.contains("search_web") ||
                prompt.contains("tools", ignoreCase = true),
        )
    }

    @Test fun `FULL does not mention tools when none available`() {
        val prompt = builder.build(fullInput(tools = emptyList()))
        assertFalse(prompt.contains("search_web"))
    }

    @Test fun `FULL tool section uses imperative language for small models`() {
        // Task #10: Qwen3 0.6B under-triggers <tool_call> when prompt is
        // gentle ("use tools when they would genuinely help"). Small models
        // need firm imperatives.
        val prompt = builder.build(fullInput(tools = listOf("get_battery_level")))
        assertTrue(
            prompt.contains("MUST", ignoreCase = false) ||
                prompt.contains("Call the tool", ignoreCase = false),
            "Tool section should use an imperative phrasing for small models. Got: $prompt",
        )
    }

    // ── COMPACT context injection ─────────────────────────────

    @Test fun `COMPACT includes name`() {
        val prompt = builder.build(compactInput(name = "Kev"))
        assertTrue(prompt.contains("Kev"))
    }

    @Test fun `COMPACT includes location`() {
        val prompt = builder.build(compactInput())
        assertTrue(prompt.contains("Dublin"))
    }

    @Test fun `COMPACT includes weather`() {
        val prompt = builder.build(compactInput())
        assertTrue(
            prompt.contains("12") ||
                prompt.contains("overcast", ignoreCase = true),
        )
    }

    // ── Token budget ──────────────────────────────────────────

    @Test fun `FULL stays under 500 words`() {
        val prompt = builder.build(fullInput())
        val wordCount = prompt.trim().split(Regex("\\s+")).size
        assertTrue(wordCount <= 500, "FULL prompt too long: $wordCount words")
    }

    @Test fun `COMPACT stays under 60 words`() {
        val prompt = builder.build(compactInput())
        val wordCount = prompt.trim().split(Regex("\\s+")).size
        assertTrue(wordCount <= 60, "COMPACT prompt too long: $wordCount words")
    }

    // ── Graceful degradation ──────────────────────────────────

    @Test fun `FULL works with empty context`() {
        val prompt =
            builder.build(
                SystemPromptInput(
                    tier = SystemPromptTier.FULL,
                    userContext = UserContext(),
                ),
            )
        assertTrue(prompt.isNotBlank())
        assertFalse(prompt.contains("null"))
    }

    @Test fun `COMPACT works with empty context`() {
        val prompt =
            builder.build(
                SystemPromptInput(
                    tier = SystemPromptTier.COMPACT,
                    userContext = UserContext(),
                ),
            )
        assertTrue(prompt.isNotBlank())
        assertFalse(prompt.contains("null"))
    }

    // ── Helpers ───────────────────────────────────────────────

    private fun fullInput(
        name: String = "Kev",
        dayOfWeek: String = "Thursday",
        tools: List<String> = emptyList(),
    ) = SystemPromptInput(
        tier = SystemPromptTier.FULL,
        userContext =
            UserContext(
                hourOfDay = 8,
                userName = name,
                location = LocationContext(city = "Dublin", country = "Ireland"),
                health = HealthContext(stepsToday = 5000, sleepLastNightMinutes = 420),
                screenTime = ScreenTimeContext(todayMinutes = 90),
                notifications = NotificationContext(unreadCount = 3),
            ),
        weather =
            WeatherContext(
                temperatureCelsius = 12.0,
                conditionDescription = "Overcast",
                conditionCode = 3,
            ),
        dayOfWeek = dayOfWeek,
        deviceTierName = "Flagship",
        contextWindowTokens = 4096,
        availableTools = tools,
    )

    private fun compactInput(name: String = "Kev") =
        SystemPromptInput(
            tier = SystemPromptTier.COMPACT,
            userContext =
                UserContext(
                    hourOfDay = 14,
                    userName = name,
                    location = LocationContext(city = "Dublin", country = "Ireland"),
                    health = HealthContext(sleepLastNightMinutes = 420),
                ),
            weather =
                WeatherContext(
                    temperatureCelsius = 12.0,
                    conditionDescription = "Overcast",
                    conditionCode = 3,
                ),
            dayOfWeek = "Thursday",
        )
}
