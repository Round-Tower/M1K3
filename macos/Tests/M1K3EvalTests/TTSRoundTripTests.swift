import Foundation
@testable import M1K3Eval
import Testing

/// #838 slice 1, the pure half of the Kokoro → Whisper round trip: the corpus, the
/// either-reading score, and a report that carries numbers, never transcripts.
struct TTSRoundTripTests {
    @Test("the corpus has every class, unique ids, and a long passage")
    func corpusShape() {
        let corpus = TTSRoundTrip.corpus
        #expect(Set(corpus.map(\.id)).count == corpus.count)
        for kind in TTSRoundTrip.Kind.allCases {
            #expect(corpus.contains { $0.kind == kind }, "no \(kind.rawValue) items")
        }
        let passageWords = corpus.filter { $0.kind == .passage }
            .map { $0.text.split(whereSeparator: \.isWhitespace).count }.reduce(0, +)
        // Several minutes of continuous prose (785 words, 177 s at Kokoro's pace on 2026-11-15).
        #expect(passageWords >= 650)
    }

    @Test("every row of #838's table is in the numbers class")
    func everyTableRow() {
        let numbers = TTSRoundTrip.corpus.filter { $0.kind == .numbers }.map(\.text).joined(separator: " ")
        for form in ["3rd", "21st", "-5", "£5", "$20", "€3.50", "10:30", "1500 people", "2048 tokens", "1990–2000",
                     "4-7", "1/2", "3/4", "Henry VIII", "Psalm XXIII", "Book IV", "John 3:16", "I.47", "v1.2.3"]
        {
            #expect(numbers.contains(form), "missing \(form)")
        }
        #expect(numbers.contains { $0.isNumber } && numbers.split(separator: " ").contains { $0.filter(\.isNumber).count > 12 },
                "no digit string longer than 12")
    }

    @Test("every item has a spoken reading, and the clip text is the spoken one")
    func references() {
        for item in TTSRoundTrip.corpus {
            #expect(item.references.first == item.spoken)
            #expect(item.references.contains(item.text))
        }
    }

    @Test("a clip scores against whichever reading Whisper wrote down")
    func eitherReading() throws {
        let item = try #require(TTSRoundTrip.corpus.first { $0.text.contains("Henry VIII") })
        let spoken = TTSRoundTrip.score(item, heard: item.spoken)
        #expect(spoken.errors == 0)
        let written = TTSRoundTrip.score(item, heard: item.text)
        #expect(written.errors == 0)
        let wrong = TTSRoundTrip.score(item, heard: "Henry vee eye eye eye had six wives.")
        #expect(wrong.errors > 0)
    }

    @Test("keys catch what the word scorer forgives: a dropped sign, symbol or ordinal")
    func keys() throws {
        let minus = try #require(TTSRoundTrip.corpus.first { $0.text.contains("-5") })
        // The normaliser strips "-", so "five" scores 0 errors against "-5"; the key does not.
        #expect(TTSRoundTrip.score(minus, heard: "It was five overnight.").errors == 0)
        #expect(TTSRoundTrip.keysHeard(minus, heard: "It was five overnight.") == 0)
        #expect(TTSRoundTrip.keysHeard(minus, heard: "It was minus five overnight.") == 1)
        #expect(TTSRoundTrip.keysHeard(minus, heard: "It was -5 overnight.") == 1)
        let money = try #require(TTSRoundTrip.corpus.first { $0.text.contains("£5,") })
        #expect(money.keys.count == 3)
        #expect(TTSRoundTrip.keysHeard(money, heard: "It costs 5 or 20 or 3.50.") == 0)
        #expect(TTSRoundTrip.keysHeard(money, heard: "It costs £5 or $20 or €3.50.") == 3)
        #expect(TTSRoundTrip.keysHeard(money, heard: "five Pounds, twenty dollars, three euros fifty") == 3)
        // Every numbers item but the plain-digit ones carries keys; no other class needs them.
        let keyed = TTSRoundTrip.corpus.filter { !$0.keys.isEmpty }
        #expect(keyed.allSatisfy { $0.kind == .numbers })
        #expect(keyed.count >= 11)
    }

    @Test("clip file names pair audio with text and sort by class then index")
    func clipNames() {
        let item = TTSRoundTrip.Item(id: "numbers-03", kind: .numbers, text: "x", spoken: "x")
        #expect(item.clipName == "clip-numbers-03")
    }

    @Test("the report carries numbers and fallback counts, never what was heard")
    func reportHasNoTranscripts() throws {
        var arm = SpeechToTextArm(name: "numbers")
        arm.add(WordErrorRate.score(reference: "one two", hypothesis: "one too"), audioSeconds: 2, processingSeconds: 1)
        let report = TTSRoundTripReport(
            speech: SpeechToTextReport(date: "2026-11-15", clips: 1, locale: "en_GB", arms: [arm]),
            voice: "bm_daniel", transcriber: "small.en",
            fallbacks: ["numbers": ["number": 2]],
            keys: ["numbers": TTSRoundTripReport.KeyTally(heard: 9, total: 12)]
        )
        let json = try #require(String(data: report.encoded(), encoding: .utf8))
        #expect(json.contains("\"voice\" : \"bm_daniel\""))
        #expect(json.contains("\"number\" : 2"))
        #expect(json.contains("\"heard\" : 9"))
        #expect(!json.contains("too"))
    }
}

struct PCMWaveTests {
    @Test("a 16-bit mono WAV: RIFF header, the rate, clipped samples")
    func header() {
        let data = PCMWave.data(samples: [0, 1, -1, 2], sampleRate: 24000)
        #expect(data.count == 44 + 8)
        #expect(String(data: data[0 ..< 4], encoding: .ascii) == "RIFF")
        #expect(String(data: data[8 ..< 12], encoding: .ascii) == "WAVE")
        func le32(_ at: Int) -> UInt32 {
            data[at ..< at + 4].enumerated().reduce(0) { $0 | UInt32($1.1) << (8 * $1.0) }
        }
        func le16(_ at: Int) -> Int16 {
            Int16(bitPattern: UInt16(data[at]) | UInt16(data[at + 1]) << 8)
        }
        #expect(le32(4) == UInt32(data.count - 8))
        #expect(le32(24) == 24000)
        #expect(le32(40) == 8)
        #expect(le16(44) == 0)
        #expect(le16(46) == Int16.max)
        #expect(le16(48) == -Int16.max)
        #expect(le16(50) == Int16.max) // 2.0 clips
    }
}
