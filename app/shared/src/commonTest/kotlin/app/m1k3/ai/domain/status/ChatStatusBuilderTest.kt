package app.m1k3.ai.domain.status

import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals

/**
 * Tests for ChatStatusBuilder.
 */
class ChatStatusBuilderTest {
    private val builder = ChatStatusBuilder()

    @Test
    fun `getTimeBasedGreeting returns good morning for early hours`() {
        assertEquals("Good morning!", builder.getTimeBasedGreeting(5))
        assertEquals("Good morning!", builder.getTimeBasedGreeting(6))
        assertEquals("Good morning!", builder.getTimeBasedGreeting(11))
    }

    @Test
    fun `getTimeBasedGreeting returns good afternoon for midday hours`() {
        assertEquals("Good afternoon!", builder.getTimeBasedGreeting(12))
        assertEquals("Good afternoon!", builder.getTimeBasedGreeting(14))
        assertEquals("Good afternoon!", builder.getTimeBasedGreeting(17))
    }

    @Test
    fun `getTimeBasedGreeting returns good evening for evening hours`() {
        assertEquals("Good evening!", builder.getTimeBasedGreeting(18))
        assertEquals("Good evening!", builder.getTimeBasedGreeting(21))
        assertEquals("Good evening!", builder.getTimeBasedGreeting(23))
    }

    @Test
    fun `getTimeBasedGreeting returns good evening for late night hours`() {
        assertEquals("Good evening!", builder.getTimeBasedGreeting(0))
        assertEquals("Good evening!", builder.getTimeBasedGreeting(2))
        assertEquals("Good evening!", builder.getTimeBasedGreeting(4))
    }

    @Test
    fun `build creates status with all fields`() {
        val status =
            builder.build(
                hour = 14,
                engineReady = true,
                memoryCount = 127,
                maxContextTokens = 4096,
                deviceTierName = "Flagship",
            )

        assertEquals("Good afternoon!", status.greeting)
        assertEquals(true, status.engineReady)
        assertEquals(127, status.memoryCount)
        assertEquals(4096, status.maxContextTokens)
        assertEquals("Flagship", status.deviceTierName)
    }

    @Test
    fun `build with engine not ready`() {
        val status =
            builder.build(
                hour = 14,
                engineReady = false,
                memoryCount = 0,
                maxContextTokens = 0,
                deviceTierName = "Unknown",
            )

        assertEquals(false, status.engineReady)
    }

    @Test
    fun `formatStatusText includes greeting`() {
        val status =
            builder.build(
                hour = 14,
                engineReady = true,
                memoryCount = 127,
                maxContextTokens = 4096,
                deviceTierName = "Flagship",
            )

        val text = builder.formatStatusText(status)
        assertContains(text, "Good afternoon!")
    }

    @Test
    fun `formatStatusText includes engine status`() {
        val status =
            builder.build(
                hour = 10,
                engineReady = true,
                memoryCount = 0,
                maxContextTokens = 2048,
                deviceTierName = "Budget",
            )

        val text = builder.formatStatusText(status)
        assertContains(text, "Engine: Ready")
    }

    @Test
    fun `formatStatusText includes memory count`() {
        val status =
            builder.build(
                hour = 10,
                engineReady = true,
                memoryCount = 42,
                maxContextTokens = 4096,
                deviceTierName = "High-End",
            )

        val text = builder.formatStatusText(status)
        assertContains(text, "Memories: 42")
    }

    @Test
    fun `formatStatusText omits the knowledge chip`() {
        val status =
            builder.build(
                hour = 10,
                engineReady = true,
                memoryCount = 42,
                maxContextTokens = 4096,
                deviceTierName = "High-End",
            )

        val text = builder.formatStatusText(status)
        assert(!text.contains("Knowledge")) { "Status should no longer render a knowledge chip" }
    }
}
