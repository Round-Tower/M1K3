package app.m1k3.ai.assistant.eval

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * EvalFixture — the Android model-eval harness's fixture vocabulary.
 *
 * Mirrors `macos/Sources/M1K3Eval/ChatEvalFixture.swift`'s `EvalExpectation`
 * field-for-field (mustContainAny/All, mustNotContain, mustRefuse,
 * mustComply, mustCallTool, minChars/maxChars) so a person who already knows
 * the Mac scorecard can read an Android one without relearning a vocabulary.
 * Deliberately does NOT copy `mustCite`/`mustNotCite` — those score the
 * Mac's citation-footer machinery, which Android doesn't have.
 *
 * `mustNotCallTool` is an Android-only addition: the 9a day found a 0.8B
 * calling `get_battery_level` on "what can you help me with?" — small-talk
 * over-triggering a tool has no Mac equivalent fixture kind to borrow from.
 *
 * Fixtures live as plain JSON files under `tools/eval/android/fixtures/`
 * (pushed to the device by the Python driver, not baked into the APK) so
 * the fixture set can grow from real on-device misses without an app
 * rebuild — same rationale as the Mac's own hand-curated set.
 */
@Serializable
data class EvalFixture(
    val id: String,
    val kind: String,
    val prompt: String,
    @SerialName("mustContainAny") val mustContainAny: List<String> = emptyList(),
    @SerialName("mustContainAll") val mustContainAll: List<String> = emptyList(),
    @SerialName("mustNotContain") val mustNotContain: List<String> = emptyList(),
    @SerialName("mustRefuse") val mustRefuse: Boolean = false,
    @SerialName("mustComply") val mustComply: Boolean = false,
    @SerialName("mustCallTool") val mustCallTool: String? = null,
    @SerialName("mustNotCallTool") val mustNotCallTool: Boolean = false,
    @SerialName("minChars") val minChars: Int? = null,
    @SerialName("maxChars") val maxChars: Int? = null,
) {
    init {
        require(!(mustRefuse && mustComply)) {
            "$id: mustRefuse and mustComply are mutually exclusive"
        }
        require(!(mustCallTool != null && mustNotCallTool)) {
            "$id: mustCallTool and mustNotCallTool are mutually exclusive"
        }
    }
}

/** Kinds this harness's fixture files are expected to use — informational
 * only (the parser accepts any string; the scorecard groups by whatever it
 * sees), listed here so a new fixture file has something to copy from. */
object EvalKind {
    const val OPEN_CHAT = "open-chat"
    const val SMALL_TALK = "small-talk"
    const val TOOL_USE = "tool-use"
    const val INSTRUCTION_FOLLOWING = "instruction-following"
    const val SECURITY = "security"
    const val WORLD_KNOWLEDGE = "world-knowledge"
}

private val fixtureJson = Json { ignoreUnknownKeys = true }

/**
 * Parse a fixtures JSON array (the shape the files under
 * `tools/eval/android/fixtures/` use) into [EvalFixture]s.
 *
 * @throws kotlinx.serialization.SerializationException on malformed JSON —
 *   deliberately not swallowed; a fixture file that doesn't parse should
 *   fail the run loudly, not silently score zero fixtures (same stance as
 *   the Mac's `scorecard.py`: "a benchmark whose parser silently drops rows
 *   is worse than no benchmark").
 */
fun parseFixtures(json: String): List<EvalFixture> = fixtureJson.decodeFromString(json)
