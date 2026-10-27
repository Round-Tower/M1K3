package app.m1k3.ai.domain.brainlink

import kotlin.io.encoding.Base64

/**
 * The Brain at Home pairing QR, as the Mac composes it (`macos/docs/BRAIN_AT_HOME_SPEC.md` §4):
 *
 *     m1k3-pair://v1?psk=<b64url 32B>&id=<opaque>&port=<pairing port>
 *         &mainPort=<serve port>&name=<mac name>&hosts=<addr,addr,…>
 *
 * The Kotlin twin of the parse in `macos/Sources/M1K3BrainLink/PairingPayload.swift`
 * (the phone only reads the QR; the Mac composes it). Strict about the secret
 * (base64 decoding to exactly 32 bytes) and the pairing port; the presentation
 * fields default instead of failing; hosts is optional, so a QR from before the
 * Mac added it still parses.
 *
 * Not a data class: the secret is a ByteArray, so equality compares it by
 * content, [psk] hands out a copy, and toString never prints it.
 *
 * Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.9 (every accept and
 * reject in PairingPayloadTest was checked against the Mac's own parse on
 * macOS 27; the shapes where this is stricter are named there).
 * Prior: none (new file). Lineage: PairingPayload.swift (Kev + claude-fable-5, 2026-08-24).
 */
class PairingPayload(
    psk: ByteArray,
    /** The opaque PSK identity (spec S1: random, never a device name). */
    val identity: String,
    /** The pairing listener's port; it serves only the pair route, for 60 s at most. */
    val pairingPort: Int,
    /** The serve port the phone talks to once the Mac approves it. */
    val mainPort: Int = DEFAULT_MAIN_PORT,
    /** The Mac's display name, for the pairing UI. */
    val macName: String = DEFAULT_MAC_NAME,
    /** The Mac's private LAN addresses (an IPv6 one may carry a zone); empty when the QR predates them. */
    val hosts: List<String> = emptyList(),
) {
    private val secret: ByteArray = psk.copyOf()

    /** The pre-shared key, a fresh copy on every read. */
    val psk: ByteArray get() = secret.copyOf()

    override fun equals(other: Any?): Boolean =
        other is PairingPayload &&
            secret.contentEquals(other.secret) &&
            identity == other.identity &&
            pairingPort == other.pairingPort &&
            mainPort == other.mainPort &&
            macName == other.macName &&
            hosts == other.hosts

    override fun hashCode(): Int {
        var result = secret.contentHashCode()
        result = 31 * result + identity.hashCode()
        result = 31 * result + pairingPort
        result = 31 * result + mainPort
        result = 31 * result + macName.hashCode()
        return 31 * result + hosts.hashCode()
    }

    override fun toString(): String =
        "PairingPayload(psk=<${secret.size} bytes, redacted>, identity=$identity, pairingPort=$pairingPort, " +
            "mainPort=$mainPort, macName=$macName, hosts=$hosts)"

    companion object {
        const val SCHEME = "m1k3-pair"
        const val VERSION = "v1"

        /** The well-known serve port (the Mac's BrainServeController.defaultPort). */
        const val DEFAULT_MAIN_PORT = 4243
        const val DEFAULT_MAC_NAME = "M1K3"
        const val KEY_LENGTH = 32

        private const val PREFIX = "$SCHEME://$VERSION?"

        /** RFC 3986's query characters, less the percent sign (escapes are checked apart). */
        private const val QUERY_CHARS =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!\$&'()*+,;=:@/?"

        private val BASE64 = Base64.Default.withPadding(Base64.PaddingOption.PRESENT_OPTIONAL)

        /**
         * Null for anything that isn't a well-formed v1 payload carrying a 32-byte
         * secret, an identity and a pairing port. Never guesses at a secret;
         * happily defaults the presentation fields.
         *
         * Stricter than the Mac on shapes its composer never writes: the query
         * must be valid RFC 3986 and follow v1 directly, and a base64 tail whose
         * unused low bits aren't zero is refused (Kotlin's decoder insists).
         */
        fun parse(string: String): PairingPayload? {
            val url = string.substringBefore('#')
            if (!url.startsWith(PREFIX)) return null
            val params = readQuery(url.substring(PREFIX.length)) ?: return null
            val key = params["psk"]?.let(::decodeBase64)?.takeIf { it.size == KEY_LENGTH } ?: return null
            val identity = params["id"]?.takeIf { it.isNotEmpty() } ?: return null
            val pairingPort = params["port"]?.let(::readPort) ?: return null
            return PairingPayload(
                psk = key,
                identity = identity,
                pairingPort = pairingPort,
                mainPort = params["mainPort"]?.let(::readPort) ?: DEFAULT_MAIN_PORT,
                macName = params["name"]?.takeIf { it.isNotEmpty() } ?: DEFAULT_MAC_NAME,
                // The value is decoded before the split, as on the Mac: a comma is never legal in an address.
                hosts = params["hosts"].orEmpty().split(',').filter { it.isNotEmpty() },
            )
        }

        /**
         * The query's items, names and values percent-decoded; a value without
         * '=' reads as empty and the last repeat of a name wins, as the Mac's
         * dictionary does. A value whose bytes aren't UTF-8 reads as empty (the
         * Mac's queryItems hand back nil there). Null for a query that isn't
         * valid RFC 3986.
         */
        private fun readQuery(query: String): Map<String, String>? {
            if (!isRfc3986Query(query)) return null
            val params = mutableMapOf<String, String>()
            for (item in query.split('&')) {
                val name = percentDecoded(item.substringBefore('=')) ?: continue
                params[name] = percentDecoded(item.substringAfter('=', missingDelimiterValue = "")) ?: ""
            }
            return params
        }

        private fun isRfc3986Query(query: String): Boolean {
            var index = 0
            while (index < query.length) {
                if (query[index] == '%') {
                    val wellFormed = index + 2 < query.length && hexValue(query[index + 1]) >= 0 && hexValue(query[index + 2]) >= 0
                    if (!wellFormed) return false
                    index += 3
                } else {
                    if (query[index] !in QUERY_CHARS) return false
                    index += 1
                }
            }
            return true
        }

        /** Decodes text [isRfc3986Query] accepted (ASCII, every escape well formed); null when the bytes aren't UTF-8. */
        private fun percentDecoded(text: String): String? {
            if ('%' !in text) return text
            val bytes = ByteArray(text.length)
            var size = 0
            var index = 0
            while (index < text.length) {
                if (text[index] == '%') {
                    bytes[size++] = (hexValue(text[index + 1]) * 16 + hexValue(text[index + 2])).toByte()
                    index += 3
                } else {
                    bytes[size++] = text[index].code.toByte()
                    index += 1
                }
            }
            return runCatching { bytes.decodeToString(0, size, throwOnInvalidSequence = true) }.getOrNull()
        }

        /** ASCII hex only; Kotlin's digitToIntOrNull would also take other scripts' digits. */
        private fun hexValue(char: Char): Int =
            when (char) {
                in '0'..'9' -> char - '0'
                in 'a'..'f' -> char - 'a' + 10
                in 'A'..'F' -> char - 'A' + 10
                else -> -1
            }

        /**
         * The Mac maps the URL-safe alphabet onto the standard one and re-pads
         * before decoding, so either alphabet reads, padded or not.
         */
        private fun decodeBase64(text: String): ByteArray? =
            runCatching { BASE64.decode(text.replace('-', '+').replace('_', '/')) }.getOrNull()

        /** Swift's `UInt16(String)` with zero refused: the Mac's port read. */
        private fun readPort(text: String): Int? = text.toSwiftIntOrNull()?.takeIf { it in 1..65535 }
    }
}
