//
//  TTSRoundTrip.swift
//  M1K3Eval
//
//  #838 slice 1, the pure half of the Kokoro → Whisper round trip: Kokoro speaks a
//  fixed corpus, WhisperKit transcribes it, and each class is scored separately with
//  WordErrorRate (TTSRoundTripStage in the app runs the engines: Kokoro is MLX, so
//  `swift test` can't). A clip scores against whichever reading Whisper wrote down,
//  the written form ("3rd") or the spoken one ("third"): the round trip measures
//  INTELLIGIBILITY, not accent or stress, because Whisper's language model forgives a
//  lot. It screens; a sample of each class is still heard by ear.
//
//  The report carries numbers and fallback counts, never what was heard, so it can be
//  committed; the clips and transcripts stay beside the corpus on the machine.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.75 (the corpus is a first
//  cut: #838's table, common contractions, names and hard words Kev's users meet, and
//  an original five-minute passage; Kev's heard examples belong here first). Prior:
//  none (new file).
//  Format: MurphySig v0.4 (https://murphysig.dev/spec)
//

import Foundation

public enum TTSRoundTrip {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case contractions
        case numbers
        case properNouns = "proper-nouns"
        case hardWords = "hard-words"
        case passage
    }

    public struct Item: Sendable, Equatable {
        public let id: String
        public let kind: Kind
        /// What Kokoro is given, as written.
        public let text: String
        /// How it should sound, as words (the clip's .txt reference).
        public let spoken: String

        public init(id: String, kind: Kind, text: String, spoken: String) {
            self.id = id
            self.kind = kind
            self.text = text
            self.spoken = spoken
        }

        /// The spoken reading first, then the written one.
        public var references: [String] {
            spoken == text ? [spoken] : [spoken, text]
        }

        /// `clip-<id>`: the .wav and .txt pair SpeechToTextCorpus reads.
        public var clipName: String {
            "clip-\(id)"
        }
    }

    /// The lower-error reading of the two: Whisper may write "£5" or "five pounds".
    public static func score(_ item: Item, heard: String) -> WordErrorRate.Score {
        let scores = item.references.map { WordErrorRate.score(reference: $0, hypothesis: heard) }
        return scores.min { lhs, rhs in
            Double(lhs.errors) / Double(max(lhs.words, 1)) < Double(rhs.errors) / Double(max(rhs.words, 1))
        } ?? WordErrorRate.score(reference: item.spoken, hypothesis: heard)
    }

    private static func items(_ kind: Kind, _ pairs: [(String, String?)]) -> [Item] {
        pairs.enumerated().map { index, pair in
            Item(id: String(format: "%@-%02d", kind.rawValue, index + 1), kind: kind,
                 text: pair.0, spoken: pair.1 ?? pair.0)
        }
    }

    public static let corpus: [Item] = items(.contractions, [
        ("I'm sure it's fine.", nil),
        ("I'll call you when I've finished.", nil),
        ("I'd rather we didn't.", nil),
        ("You're right, they've gone home.", nil),
        ("We'll see what she'd say.", nil),
        ("It isn't what you'd think.", nil),
        ("Don't worry, I won't forget.", nil),
        ("They're here and we're ready.", nil),
    ]) + items(.numbers, [
        ("She came 3rd in her 21st race.", "She came third in her twenty first race."),
        ("It was -5 overnight.", "It was minus five overnight."),
        ("It costs £5, or $20, or €3.50.", "It costs five pounds, or twenty dollars, or three euros fifty."),
        ("The train leaves at 10:30.", "The train leaves at ten thirty."),
        ("We expect 1500 people and 2048 tokens.",
         "We expect one thousand five hundred people and two thousand and forty eight tokens."),
        ("From 1990–2000, see pages 4-7.", "From nineteen ninety to two thousand, see pages four to seven."),
        ("Add 1/2 a cup, then 3/4 of the rest.", "Add a half a cup, then three quarters of the rest."),
        ("Your code is 4815162342108.", "Your code is four eight one, five one six, two three four, two one zero, eight."),
        ("Henry VIII had six wives.", "Henry the eighth had six wives."),
        ("Read Psalm XXIII and Book IV.", "Read Psalm twenty three and Book four."),
        ("Look up John 3:16 tonight.", "Look up John three sixteen tonight."),
        ("Euclid proves it in Elements I.47.", "Euclid proves it in Elements book one, proposition forty seven."),
        ("Update to v1.2.3 today.", "Update to version one point two point three today."),
        ("In 1984 the house sold for £5 million.", "In nineteen eighty four the house sold for five million pounds."),
    ]) + items(.properNouns, [
        ("Kev lives in Ardmore, near Dungarvan.", nil),
        ("Siobhan and Niamh flew from Dublin to Reykjavik.", nil),
        ("Tchaikovsky and Dvořák both wrote symphonies.", nil),
        ("We met Aoife at the Guinness Storehouse.", nil),
        ("Abuja is the capital of Nigeria.", nil),
        ("Lloyd's of London insured the ship.", nil),
        ("Ask M1K3 about Kokoro and WhisperKit.", "Ask Mike about Kokoro and WhisperKit."),
        ("Saoirse Ronan starred in Brooklyn.", nil),
    ]) + items(.hardWords, [
        ("The sternocleidomastoid and the gastrocnemius are muscles.", nil),
        ("The eigenvalue of a Hermitian matrix is real.", nil),
        ("Dukkha, anicca and anatta are the three marks of existence.", nil),
        ("Quercus robur and Taraxacum officinale grow in the field.", nil),
        ("The epiglottis covers the oesophagus when you swallow.", nil),
        ("Phenylketonuria is screened for at birth.", nil),
        ("Nietzsche wrote about the Ubermensch.", nil),
        ("A rhombicosidodecahedron has sixty two faces.", nil),
    ]) + items(.passage, [(passage, nil)])

    /// Original prose, about five minutes aloud: the audiobook question on #752.
    static let passage = """
    The lighthouse at the end of the headland had not been lit for years, but people still walked out to it \
    in the evenings, as if it might remember what it was for. The path ran along the top of the cliff, \
    between the gorse and the drop, and in the summer the gorse smelled faintly of coconut, which surprised \
    everyone the first time and nobody after that. Children ran ahead and were called back. Dogs ran ahead \
    and were not. The sea below was the colour of slate on most days, and on the rare good days it turned a \
    green so clear you could see the rocks under the surface, long and pale, like the backs of sleeping \
    animals. My grandmother used to say that the rocks had names, and that the fishermen who knew them by \
    name came home, and the ones who did not, sometimes did not. She told this as a joke, but she never \
    laughed when she told it, and so I was never sure what kind of joke it was. When I was small I tried to \
    learn the names. I asked the old men on the pier, and they told me different names for the same rock, \
    and the same name for different rocks, and after a while I understood that the names were not really \
    about the rocks at all. They were about who had been out on the water, and when, and what had happened \
    to them. A rock was called after a boat that had broken on it, or a man who had been pulled from the \
    sea beside it, or a storm that people still talked about in low voices. The names were a kind of map, \
    but it was a map of the past, not of the coast. The lighthouse keeper's cottage stood at the foot of the \
    tower, with a slate roof and two small windows that looked out to the west. Nobody had lived there since \
    the light was automated, and then the light itself was switched off when the new beacon went up on the \
    island. The door was painted a deep red once, and you could still see the colour in the cracks, though \
    the rest had weathered to the grey of driftwood. Someone had planted fuchsia along the wall, a long time \
    ago, and it had grown wild, so that in August the whole front of the cottage was hung with small red \
    and purple bells that shook in the wind. I went back there last autumn, after a long time away. The path \
    was narrower than I remembered, and the drop was steeper, or perhaps I was more careful than I used to \
    be. The gorse was still there, and the smell of coconut, and the sea was the colour of slate. I walked \
    to the end and stood with my back to the tower and looked out at the water for a long time. There was a \
    boat far out, a small one, moving slowly against the tide, and I watched it until it went behind the \
    island and did not come out again for a while. I thought about my grandmother and the names of the \
    rocks, and I found that I could still remember some of them, though I could not have said which rock \
    went with which name. It did not seem to matter. The names were still there, the way the colour was \
    still there in the cracks of the door. On the way back the light was going, and the first stars came \
    out over the hills behind the town. A woman passed me walking a black dog, and she nodded, and the dog \
    looked at me with great seriousness and then ran ahead and was not called back. I stopped at the gate \
    at the top of the path and looked back once. The tower stood dark against the last of the evening, and \
    for a moment, out of the corner of my eye, I thought I saw a light turning at the top of it, slow and \
    steady, the way it used to. Then I looked properly and there was nothing there, only the dark shape of \
    the tower and the sky behind it, and the sound of the sea below, going on as it always had, patient \
    and enormous and not in the least concerned with any of us. I walked down into the town, where the \
    streetlights were coming on one by one, and I did not tell anyone about the light, because I knew \
    exactly what they would say, and I knew that they would be right, and I did not want to hear it.
    """
}

/// The committed report: the speech-to-text arms (one per class) plus which G2P
/// fallback spoke each class's words. No transcripts.
public struct TTSRoundTripReport: Sendable, Encodable, Equatable {
    public let speech: SpeechToTextReport
    public let voice: String
    public let transcriber: String
    /// class → fallback → words.
    public let fallbacks: [String: [String: Int]]

    public init(speech: SpeechToTextReport, voice: String, transcriber: String, fallbacks: [String: [String: Int]]) {
        self.speech = speech
        self.voice = voice
        self.transcriber = transcriber
        self.fallbacks = fallbacks
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
