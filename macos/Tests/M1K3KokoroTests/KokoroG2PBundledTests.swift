import Foundation
@testable import M1K3Kokoro
import Testing

struct KokoroG2PBundledTests {
    @Test("parse builds a lookup table, skipping malformed lines")
    func parseSkipsMalformed() {
        let dict = KokoroG2P.parse("hello\t50,83,54\nnotab\nempty\t\nworld\t65,156\n")
        #expect(dict["hello"] == [50, 83, 54])
        #expect(dict["world"] == [65, 156])
        #expect(dict["notab"] == nil)
        #expect(dict["empty"] == nil)
    }

    @Test("the byte parser keeps the Int.init contract — junk id segments drop whole")
    func parseDropsJunkSegments() {
        // "5x0" must not become 50 (digit accumulation across junk) — the old
        // `Int(Substring)` returned nil for the whole segment, and the byte
        // parser must agree. A final line without a trailing newline parses too.
        let dict = KokoroG2P.parse("mixed\t12,5x0,7\nlast\t9")
        #expect(dict["mixed"] == [12, 7])
        #expect(dict["last"] == [9])
    }

    @Test("the bundled dictionary loads and reproduces the oracle tokens end-to-end")
    func bundledEndToEnd() throws {
        let g2p = try KokoroG2P.bundled()
        // misaki-gb dict: canonical single-token diphthongs (Q=33 for /əʊ/).
        #expect(g2p.phonemeTokens("Hello world.") ==
            [50, 83, 54, 156, 33, 16, 65, 156, 87, 158, 54, 46, 4])
        #expect(g2p.phonemeTokens("don't").isEmpty == false)
    }

    @Test("numbers, units, and acronyms are spoken against the real dictionary")
    func bundledFallbackChain() throws {
        let g2p = try KokoroG2P.bundled()
        // Every expansion word (fifteen/celsius/twenty/six…) must resolve in
        // the shipped dict — this is the line that used to be silently mute.
        let weather = g2p.annotatedTokens("It is 15°C in 2026.")
        #expect(weather.words.allSatisfy { !$0.tokenRange.isEmpty })
        // Mixed alphanumeric spells out (em one kay three), not silence.
        #expect(g2p.phonemeTokens("M1K3").isEmpty == false)
        // Percentages and decimals speak too.
        #expect(g2p.phonemeTokens("3.5% today").isEmpty == false)
    }

    @Test("compound OOV words split against the real dictionary — the 'grandmaster' fix")
    func bundledCompoundSplit() throws {
        let g2p = try KokoroG2P.bundled()
        // "grandmaster" is not a single dict entry, but grand + master are — it
        // used to be silently DROPPED from speech (the live TTS skip Kev caught).
        // Now it speaks as one karaoke word with a non-empty token span.
        let result = g2p.annotatedTokens("grandmaster")
        #expect(!result.tokens.isEmpty)
        #expect(result.words.count == 1)
        #expect(!result.words[0].tokenRange.isEmpty)
    }

    @Test("OOV inflected forms speak against the real dictionary — the 'plays' fix")
    func bundledInflections() throws {
        let g2p = try KokoroG2P.bundled()
        // The spike dict has bases + "-ing" but NOT "-s"/"-ed" — every one of
        // these used to be silently dropped from speech. Each must now produce
        // a non-empty, single-word span.
        for word in ["plays", "games", "cats", "runs", "makes", "words", "wanted", "walked", "played",
                     "churches", "judges", "watched", "bridged"]
        {
            let result = g2p.annotatedTokens(word)
            #expect(!result.tokens.isEmpty, "\(word) is still silent")
            #expect(result.words.count == 1)
            #expect(!result.words[0].tokenRange.isEmpty, "\(word) has an empty token span")
        }
    }
}
