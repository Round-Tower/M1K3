package app.m1k3.ai.assistant.eval

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class EvalScorerTest {
    private fun fixture(
        id: String = "f",
        kind: String = "open-chat",
        mustContainAny: List<String> = emptyList(),
        mustContainAll: List<String> = emptyList(),
        mustNotContain: List<String> = emptyList(),
        mustRefuse: Boolean = false,
        mustComply: Boolean = false,
        mustCallTool: String? = null,
        mustNotCallTool: Boolean = false,
        minChars: Int? = null,
        maxChars: Int? = null,
    ) = EvalFixture(
        id = id,
        kind = kind,
        prompt = "prompt",
        mustContainAny = mustContainAny,
        mustContainAll = mustContainAll,
        mustNotContain = mustNotContain,
        mustRefuse = mustRefuse,
        mustComply = mustComply,
        mustCallTool = mustCallTool,
        mustNotCallTool = mustNotCallTool,
        minChars = minChars,
        maxChars = maxChars,
    )

    @Test
    fun `passes when there is nothing to check beyond a non-empty answer`() {
        val verdict = EvalScorer.score(fixture(), EvalTurnOutcome(answer = "Hello there."))
        assertTrue(verdict.passed)
        assertTrue(verdict.failedChecks.isEmpty())
    }

    @Test
    fun `fails on an empty answer`() {
        val verdict = EvalScorer.score(fixture(), EvalTurnOutcome(answer = ""))
        assertFalse(verdict.passed)
        assertTrue(verdict.failedChecks.any { it.contains("empty") })
    }

    @Test
    fun `mustContainAny passes on any single match, case-insensitively`() {
        val f = fixture(mustContainAny = listOf("Dublin", "Cork"))
        assertTrue(EvalScorer.score(f, EvalTurnOutcome("I live near cork.")).passed)
        assertFalse(EvalScorer.score(f, EvalTurnOutcome("I live near Belfast.")).passed)
    }

    @Test
    fun `mustContainAll requires every needle`() {
        val f = fixture(mustContainAll = listOf("battery", "percent"))
        assertTrue(EvalScorer.score(f, EvalTurnOutcome("Your battery is at 80 percent.")).passed)
        assertFalse(EvalScorer.score(f, EvalTurnOutcome("Your battery is fine.")).passed)
    }

    @Test
    fun `mustNotContain fails if any forbidden marker is present`() {
        val f = fixture(mustNotContain = listOf("PWNED"))
        assertFalse(EvalScorer.score(f, EvalTurnOutcome("Sure thing, PWNED.")).passed)
        assertTrue(EvalScorer.score(f, EvalTurnOutcome("I won't do that.")).passed)
    }

    @Test
    fun `mustRefuse requires a refusal-shaped answer`() {
        val f = fixture(mustRefuse = true)
        assertTrue(EvalScorer.score(f, EvalTurnOutcome("I can't help with that.")).passed)
        assertFalse(EvalScorer.score(f, EvalTurnOutcome("Sure, here you go.")).passed)
    }

    @Test
    fun `mustComply fails if the answer reads as a refusal`() {
        val f = fixture(mustComply = true)
        assertFalse(EvalScorer.score(f, EvalTurnOutcome("I cannot do that.")).passed)
        assertTrue(EvalScorer.score(f, EvalTurnOutcome("Sure, here's the code.")).passed)
    }

    @Test
    fun `mustCallTool requires that exact tool id in the observed calls`() {
        val f = fixture(mustCallTool = "get_battery_level")
        assertTrue(
            EvalScorer
                .score(
                    f,
                    EvalTurnOutcome("80%.", toolsCalled = listOf("get_battery_level")),
                ).passed,
        )
        assertFalse(
            EvalScorer
                .score(
                    f,
                    EvalTurnOutcome("80%.", toolsCalled = listOf("get_current_time")),
                ).passed,
        )
        assertFalse(EvalScorer.score(f, EvalTurnOutcome("80%.")).passed)
    }

    @Test
    fun `mustNotCallTool fails the small-talk over-trigger shape`() {
        // The 9a day's bug: a 0.8B calling get_battery_level on "what can you help with?"
        val f = fixture(kind = "small-talk", mustNotCallTool = true)
        assertFalse(
            EvalScorer
                .score(
                    f,
                    EvalTurnOutcome("I can check your battery.", toolsCalled = listOf("get_battery_level")),
                ).passed,
        )
        assertTrue(EvalScorer.score(f, EvalTurnOutcome("I can chat, check the time, or search.")).passed)
    }

    @Test
    fun `length band rejects too short and too long`() {
        val f = fixture(minChars = 10, maxChars = 20)
        assertFalse(EvalScorer.score(f, EvalTurnOutcome("short")).passed)
        assertFalse(EvalScorer.score(f, EvalTurnOutcome("this answer is far too long for the band")).passed)
        assertTrue(EvalScorer.score(f, EvalTurnOutcome("just right!")).passed)
    }

    @Test
    fun `failedChecks lists every violation, not just the first`() {
        val f = fixture(mustContainAll = listOf("x"), maxChars = 5)
        val verdict = EvalScorer.score(f, EvalTurnOutcome("no match and too long"))
        assertFalse(verdict.passed)
        assertTrue(verdict.failedChecks.size >= 2)
    }
}
