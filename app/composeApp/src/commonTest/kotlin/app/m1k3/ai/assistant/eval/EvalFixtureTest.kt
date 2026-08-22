package app.m1k3.ai.assistant.eval

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class EvalFixtureTest {
    @Test
    fun `parses a minimal fixture with defaults`() {
        val fixtures =
            parseFixtures(
                """
                [{"id": "chat-hello", "kind": "open-chat", "prompt": "Hey, how's it going?"}]
                """.trimIndent(),
            )

        assertEquals(1, fixtures.size)
        val fixture = fixtures.single()
        assertEquals("chat-hello", fixture.id)
        assertEquals("open-chat", fixture.kind)
        assertEquals("Hey, how's it going?", fixture.prompt)
        assertTrue(fixture.mustContainAny.isEmpty())
        assertFalse(fixture.mustRefuse)
        assertFalse(fixture.mustComply)
        assertNull(fixture.mustCallTool)
        assertFalse(fixture.mustNotCallTool)
        assertNull(fixture.minChars)
        assertNull(fixture.maxChars)
    }

    @Test
    fun `parses every expectation field`() {
        val fixtures =
            parseFixtures(
                """
                [{
                    "id": "tool-battery",
                    "kind": "tool-use",
                    "prompt": "What's my battery level?",
                    "mustContainAny": ["%", "percent"],
                    "mustContainAll": ["battery"],
                    "mustNotContain": ["error"],
                    "mustCallTool": "get_battery_level",
                    "minChars": 3,
                    "maxChars": 200
                }]
                """.trimIndent(),
            )

        val fixture = fixtures.single()
        assertEquals(listOf("%", "percent"), fixture.mustContainAny)
        assertEquals(listOf("battery"), fixture.mustContainAll)
        assertEquals(listOf("error"), fixture.mustNotContain)
        assertEquals("get_battery_level", fixture.mustCallTool)
        assertEquals(3, fixture.minChars)
        assertEquals(200, fixture.maxChars)
    }

    @Test
    fun `parses several fixtures in one file`() {
        val fixtures =
            parseFixtures(
                """
                [
                    {"id": "a", "kind": "open-chat", "prompt": "one"},
                    {"id": "b", "kind": "security", "prompt": "two", "mustRefuse": true}
                ]
                """.trimIndent(),
            )

        assertEquals(2, fixtures.size)
        assertEquals(listOf("a", "b"), fixtures.map { it.id })
        assertTrue(fixtures[1].mustRefuse)
    }

    @Test
    fun `small-talk fixture can require no tool call`() {
        val fixtures =
            parseFixtures(
                """
                [{
                    "id": "small-talk-capabilities",
                    "kind": "small-talk",
                    "prompt": "What can you help me with?",
                    "mustNotCallTool": true
                }]
                """.trimIndent(),
            )

        assertTrue(fixtures.single().mustNotCallTool)
    }

    @Test
    fun `mustRefuse and mustComply together is rejected`() {
        assertFailsWith<IllegalArgumentException> {
            parseFixtures(
                """
                [{"id": "bad", "kind": "security", "prompt": "x", "mustRefuse": true, "mustComply": true}]
                """.trimIndent(),
            )
        }
    }

    @Test
    fun `mustCallTool and mustNotCallTool together is rejected`() {
        assertFailsWith<IllegalArgumentException> {
            parseFixtures(
                """
                [{"id": "bad", "kind": "tool-use", "prompt": "x", "mustCallTool": "x", "mustNotCallTool": true}]
                """.trimIndent(),
            )
        }
    }

    @Test
    fun `malformed JSON fails loudly rather than returning nothing`() {
        assertFailsWith<Exception> {
            parseFixtures("not json")
        }
    }
}
