package app.m1k3.ai.domain.brainlink

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.math.floor

/**
 * The Foundation reads the Mac's M1K3BrainLink makes without spelling them out,
 * written down so the Kotlin twins read the same wire the same way: Swift's
 * `Int(String)`, `CharacterSet.whitespaces`, and JSONSerialization's
 * `as? String` / `as? Int`. Pinned value by value in FoundationParityTest
 * against what macOS 27's Foundation printed.
 *
 * Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (every read pinned
 * against Foundation's own output; two gaps are deliberate and named in the
 * tests: past-Int numbers and JSON bools are refused, where NSNumber takes them).
 * Prior: none (new file).
 */

private val SWIFT_INT = Regex("[+-]?[0-9]+")

/**
 * Swift's `Int(String)`: an optional sign, then ASCII digits only. Kotlin's
 * toIntOrNull alone would also take other scripts' digits. Past Int range
 * reads as absent (Swift's 64-bit Int would take it).
 */
internal fun String.toSwiftIntOrNull(): Int? = if (SWIFT_INT.matches(this)) toIntOrNull() else null

/** `trimmingCharacters(in: .whitespaces)`: tab and the Zs space separators, never line breaks. */
internal fun String.trimSwiftWhitespaces(): String = trim { it == '\t' || it.category == CharCategory.SPACE_SEPARATOR }

/**
 * JSONSerialization's `as? [String: Any]`: the text is one strict JSON value
 * and that value is an object, or there is no object at all. kotlinx keeps an
 * unquoted token such as `abc` as a primitive rather than failing, so every
 * non-string primitive is checked against JSON's own grammar.
 */
internal fun parseJsonObject(text: String?): JsonObject? {
    if (text.isNullOrEmpty()) return null
    val element = runCatching { Json.parseToJsonElement(text) }.getOrNull() ?: return null
    return (element as? JsonObject)?.takeIf { it.isStrictJson() }
}

/** `json[key] as? String`: present and a JSON string. */
internal fun JsonObject.stringOrNull(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

/**
 * `json[key] as? Int` for a number: a JSON number with a whole value (30,
 * 30.0 and 1e2 all count) inside Int range. Strings, fractions, null and
 * bools do not.
 */
internal fun JsonObject.wholeIntOrNull(key: String): Int? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    if (primitive.isString || primitive is JsonNull || !JSON_NUMBER.matches(primitive.content)) return null
    val value = primitive.content.toDoubleOrNull() ?: return null
    val inRange = value >= Int.MIN_VALUE.toDouble() && value <= Int.MAX_VALUE.toDouble()
    return if (inRange && value == floor(value)) value.toInt() else null
}

private val JSON_NUMBER = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")

private fun JsonElement.isStrictJson(): Boolean =
    when (this) {
        is JsonObject -> values.all { it.isStrictJson() }
        is JsonArray -> all { it.isStrictJson() }
        is JsonNull -> true
        is JsonPrimitive -> isString || content == "true" || content == "false" || JSON_NUMBER.matches(content)
    }
