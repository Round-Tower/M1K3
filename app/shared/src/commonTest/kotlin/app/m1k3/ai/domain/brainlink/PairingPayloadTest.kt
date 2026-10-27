package app.m1k3.ai.domain.brainlink

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The QR payload the Mac composes and the phone parses. The Mac's side is
 * `macos/Sources/M1K3BrainLink/PairingPayload.swift`; the Kotlin tests can't
 * link it, so the composed strings below were printed by that file's
 * composed() on macOS 27 (2026-10-27) with the fixture of its own
 * PairingPayloadTests: key = bytes 0..31, the UUID identity, pairing port
 * 52113, serve port 4243, "Kev’s Mac Studio". Every accept and reject below
 * was checked against the Mac's parse the same way, except the four shapes
 * in the last group, where the Kotlin is deliberately stricter.
 *
 * Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.9 (literals read off
 * the Mac's own compose and parse, not retyped from the spec).
 * Prior: none (new file).
 */
class PairingPayloadTest {
    private val key = ByteArray(32) { it.toByte() }

    @Test
    fun `parses the payload the Mac composes`() {
        val parsed = assertNotNull(PairingPayload.parse(COMPOSED))
        assertContentEquals(key, parsed.psk)
        assertEquals(IDENTITY, parsed.identity)
        assertEquals(52113, parsed.pairingPort)
        assertEquals(4243, parsed.mainPort)
        assertEquals(MAC_NAME, parsed.macName)
        assertEquals(listOf("192.168.1.24"), parsed.hosts)
        assertEquals(PairingPayload(key, IDENTITY, 52113, 4243, MAC_NAME, listOf("192.168.1.24")), parsed)
    }

    @Test
    fun `an IPv6 host keeps its zone`() {
        val parsed = assertNotNull(PairingPayload.parse(COMPOSED_IPV6))
        // %25 decodes before the comma split, exactly as the Mac reads it.
        assertEquals(listOf("fe80::1c2a:ff:fe4e:1%en0", "192.168.1.24"), parsed.hosts)
    }

    @Test
    fun `a payload without hosts parses with none`() {
        assertEquals(emptyList(), assertNotNull(PairingPayload.parse(COMPOSED_NO_HOSTS)).hosts)
        // The 2026-08-19 server composed exactly this shape.
        val legacy = assertNotNull(PairingPayload.parse("m1k3-pair://v1?psk=$KEY&id=ABC-123&port=50000&mainPort=4243&name=M1K3"))
        assertEquals("ABC-123", legacy.identity)
        assertContentEquals(key, legacy.psk)
        assertEquals(50000, legacy.pairingPort)
        assertEquals(4243, legacy.mainPort)
        assertEquals("M1K3", legacy.macName)
        assertEquals(emptyList(), legacy.hosts)
    }

    @Test
    fun `structural characters in the name survive`() {
        assertEquals("a&b=c+d,e", assertNotNull(PairingPayload.parse(COMPOSED_TRICKY_NAME)).macName)
    }

    @Test
    fun `a plus in a value stays a plus`() {
        // URLComponents never reads + as a space; neither does the twin.
        assertEquals("a+b+c", parse("&name=a%2Bb+c").macName)
    }

    @Test
    fun `presentation fields default instead of failing`() {
        assertEquals(4243, parse("").mainPort)
        for (bad in listOf("abc", "0", "65536", "-1")) {
            assertEquals(4243, parse("&mainPort=$bad").mainPort, "mainPort=$bad")
        }
        assertEquals("M1K3", parse("").macName)
        assertEquals("M1K3", parse("&name=").macName)
        // Bytes that aren't UTF-8 read as an empty value on the Mac, so they default.
        assertEquals("M1K3", parse("&name=%FF").macName)
        assertEquals("M1K3", parse("&name=%E2%80").macName)
        assertEquals(emptyList(), parse("&hosts=%FF").hosts)
    }

    @Test
    fun `empty hosts are dropped`() {
        assertEquals(listOf("10.0.0.5", "fd00::5"), parse("&hosts=,10.0.0.5,,fd00::5").hosts)
    }

    @Test
    fun `the secret is exactly 32 bytes of base64 or nothing`() {
        val shortKey = "AQID"
        val key31 = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBw"
        val key33 = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcH"
        for (psk in listOf(shortKey, key31, key33, "!!!!", "", "%20$KEY")) {
            assertNull(PairingPayload.parse("m1k3-pair://v1?psk=$psk&id=ABC&port=50000"), "psk=$psk")
        }
        assertNull(PairingPayload.parse("m1k3-pair://v1?id=ABC&port=50000"))
    }

    @Test
    fun `the secret reads either base64 alphabet padded or not`() {
        assertContentEquals(key, assertNotNull(PairingPayload.parse("m1k3-pair://v1?psk=$KEY=&id=ABC&port=50000")).psk)
        // %41 is A: the value decodes before the base64 does.
        assertContentEquals(key, assertNotNull(PairingPayload.parse("m1k3-pair://v1?psk=%41${KEY.drop(1)}&id=ABC&port=50000")).psk)
        val high = ByteArray(32) { (255 - it).toByte() }
        for (psk in listOf(HIGH_KEY_STANDARD, HIGH_KEY_URL_SAFE)) {
            assertContentEquals(high, assertNotNull(PairingPayload.parse("m1k3-pair://v1?psk=$psk&id=ABC&port=50000"), psk).psk)
        }
    }

    @Test
    fun `identity and pairing port are required`() {
        for (query in listOf("psk=$KEY&port=50000", "psk=$KEY&id=&port=50000", "psk=$KEY&id&port=50000", "psk=$KEY&id=%FF&port=50000")) {
            assertNull(PairingPayload.parse("m1k3-pair://v1?$query"), query)
        }
        for (port in listOf("0", "65536", "99999999", "-1", "abc", "%D9%A3", "")) {
            assertNull(PairingPayload.parse("m1k3-pair://v1?psk=$KEY&id=ABC&port=$port"), "port=$port")
        }
        assertNull(PairingPayload.parse("m1k3-pair://v1?psk=$KEY&id=ABC"))
    }

    @Test
    fun `ports read the way the Mac reads them`() {
        for (port in listOf("+80", "%2B80", "0080")) {
            assertEquals(80, assertNotNull(PairingPayload.parse("m1k3-pair://v1?psk=$KEY&id=ABC&port=$port"), port).pairingPort)
        }
        assertEquals(65535, assertNotNull(PairingPayload.parse("m1k3-pair://v1?psk=$KEY&id=ABC&port=65535")).pairingPort)
    }

    @Test
    fun `the scheme and version are exact`() {
        for (payload in listOf(
            COMPOSED.replace("m1k3-pair://", "https://"),
            COMPOSED.replace("://v1?", "://v2?"),
            COMPOSED.replace("m1k3-pair://", "M1K3-PAIR://"),
            COMPOSED.replace("://v1?", "://V1?"),
            "m1k3-pair://v1",
            "m1k3-pair://v1?",
            "",
        )) {
            assertNull(PairingPayload.parse(payload), payload)
        }
    }

    @Test
    fun `the last of a repeated parameter wins`() {
        assertEquals(50001, parse("&port=50001").pairingPort)
    }

    @Test
    fun `parameter names decode too`() {
        assertEquals(50000, assertNotNull(PairingPayload.parse("m1k3-pair://v1?psk=$KEY&id=ABC&p%6Frt=50000")).pairingPort)
    }

    @Test
    fun `a fragment is not part of the query`() {
        assertEquals("x", parse("&name=x#frag").macName)
    }

    @Test
    fun `stricter than the Mac on shapes it never composes`() {
        // macOS 27 accepts all four. For a query that isn't valid RFC 3986 it then
        // leaves EVERY value undecoded (a raw space in the name left hosts=%25en0
        // encoded), and Foundation before macOS 14 refused such a string outright;
        // the Mac's own composer writes none of these. A path after v1 and a base64
        // tail with stray low bits are refused for the same reason.
        assertNull(PairingPayload.parse(COMPOSED.replace("://v1?", "://v1/?")))
        assertNull(PairingPayload.parse("$BASE&name=a%ZZb"))
        assertNull(PairingPayload.parse("$BASE&name=a b"))
        assertNull(PairingPayload.parse("$BASE&name=é"))
        assertNull(PairingPayload.parse("m1k3-pair://v1?psk=${KEY.dropLast(1)}9&id=ABC&port=50000"))
    }

    @Test
    fun `the secret never reaches toString`() {
        val text = assertNotNull(PairingPayload.parse(COMPOSED)).toString()
        assertFalse(KEY in text, text)
        assertFalse("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=" in text, text)
        assertFalse(key.contentToString() in text, text)
        assertFalse("000102030405" in text, text)
        assertTrue(IDENTITY in text, text)
    }

    @Test
    fun `equality compares the secret by content`() {
        val first = assertNotNull(PairingPayload.parse(COMPOSED))
        val second = assertNotNull(PairingPayload.parse(COMPOSED))
        assertEquals(first, second)
        assertEquals(first.hashCode(), second.hashCode())
        val otherKey = key.copyOf().also { it[31] = 99 }
        assertNotEquals(first, PairingPayload(otherKey, IDENTITY, 52113, 4243, MAC_NAME, listOf("192.168.1.24")))
    }

    @Test
    fun `the secret cannot be changed from outside`() {
        val source = key.copyOf()
        val payload = PairingPayload(source, IDENTITY, 52113)
        source[0] = 99
        payload.psk[1] = 99
        assertContentEquals(key, payload.psk)
    }

    private fun parse(extra: String): PairingPayload = assertNotNull(PairingPayload.parse(BASE + extra), BASE + extra)

    private companion object {
        const val KEY = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        const val IDENTITY = "9D9A44E6-27E4-4E86-B7C0-4E2E0AB2E9AD"
        const val MAC_NAME = "Kev’s Mac Studio"
        const val BASE = "m1k3-pair://v1?psk=$KEY&id=ABC&port=50000"

        // Bytes 255 down to 224, as Foundation's base64EncodedString and the Mac's base64URL print them.
        const val HIGH_KEY_STANDARD = "//79/Pv6+fj39vX08/Lx8O/u7ezr6uno5+bl5OPi4eA="
        const val HIGH_KEY_URL_SAFE = "__79_Pv6-fj39vX08_Lx8O_u7ezr6uno5-bl5OPi4eA"

        // PairingPayload.composed() on the Mac, hosts ["192.168.1.24"].
        const val COMPOSED =
            "m1k3-pair://v1?psk=$KEY&id=$IDENTITY&port=52113&mainPort=4243" +
                "&name=Kev%E2%80%99s%20Mac%20Studio&hosts=192.168.1.24"

        // …hosts ["fe80::1c2a:ff:fe4e:1%en0", "192.168.1.24"].
        const val COMPOSED_IPV6 =
            "m1k3-pair://v1?psk=$KEY&id=$IDENTITY&port=52113&mainPort=4243" +
                "&name=Kev%E2%80%99s%20Mac%20Studio&hosts=fe80::1c2a:ff:fe4e:1%25en0,192.168.1.24"

        // …hosts [] (no hosts parameter at all).
        const val COMPOSED_NO_HOSTS =
            "m1k3-pair://v1?psk=$KEY&id=$IDENTITY&port=52113&mainPort=4243&name=Kev%E2%80%99s%20Mac%20Studio"

        // …macName "a&b=c+d,e", hosts [].
        const val COMPOSED_TRICKY_NAME =
            "m1k3-pair://v1?psk=$KEY&id=$IDENTITY&port=52113&mainPort=4243&name=a%26b%3Dc%2Bd%2Ce"
    }
}
