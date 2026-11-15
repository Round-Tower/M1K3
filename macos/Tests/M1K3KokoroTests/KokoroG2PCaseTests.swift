//
//  KokoroG2PCaseTests.swift
//  M1K3KokoroTests
//
//  #837: the walker lowercased every word before the dictionary, so "I'm" and the
//  4,306 capitalised misaki-gb keys with no lowercase twin ("Alzheimer's", "Abuja",
//  "iOS") were never found. These pin the rescue through the REAL bundled
//  pipeline, and pin that every word that hits in lowercase today is unchanged.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.85 (the dictionary keys
//  were probed before writing these; how each sounds is verify-by-ear). Prior: none (new file).
//

import Foundation
@testable import M1K3Kokoro
import Testing

struct KokoroG2PCaseTests {
    private static let g2p = Result { try KokoroG2P.bundled() }
    private static let dictionary = Result { try KokoroG2P.bundledDictionary() }

    /// The tokens the walker gave the word that covers `word` inside `sentence`.
    private func spoken(_ word: String, in sentence: String) throws -> [Int] {
        let result = try Self.g2p.get().annotatedTokens(sentence)
        let utf16: [UInt16] = Array(sentence.utf16)
        let target: [UInt16] = Array(word.utf16)
        let found: G2PWord? = result.words.first { Array(utf16[$0.textRange]) == target }
        let match = try #require(found, "no word \(word) in \(sentence)")
        return Array(result.tokens[match.tokenRange])
    }

    @Test("I'm, I'll, I'd and I've come from the dictionary, at the start and in the middle")
    func firstPersonContractions() throws {
        let dictionary = try Self.dictionary.get()
        for word in ["I'm", "I'll", "I'd", "I've"] {
            let entry = try #require(dictionary[word], "\(word) left the dictionary")
            #expect(dictionary[word.lowercased()] == nil, "\(word) has a lowercase twin now; this test proves nothing")
            #expect(try spoken(word, in: "\(word) here.") == entry, "\(word) at the start")
            #expect(try spoken(word, in: "Well, \(word) here.") == entry, "\(word) in the middle")
        }
    }

    @Test("a capitalised key with no lowercase twin is found as written (Alzheimer's, Abuja, iOS, Lloyd's)")
    func capitalisedOnlyKeys() throws {
        let dictionary = try Self.dictionary.get()
        for word in ["Alzheimer's", "Abuja", "iOS", "Lloyd's", "ASEAN"] {
            let entry = try #require(dictionary[word])
            #expect(dictionary[word.lowercased()] == nil)
            #expect(try spoken(word, in: "About \(word) today.") == entry, "\(word)")
        }
    }

    @Test("a word typed in the wrong case still reaches its title-case key (abuja, ALZHEIMER'S)")
    func titleCaseFallback() throws {
        let dictionary = try Self.dictionary.get()
        #expect(try spoken("abuja", in: "to abuja") == dictionary["Abuja"])
        #expect(try spoken("ALZHEIMER'S", in: "ALZHEIMER'S RESEARCH") == dictionary["Alzheimer's"])
        #expect(try spoken("i'm", in: "yes i'm fine") == dictionary["I'm"])
    }

    @Test("a word that hits in lowercase today keeps exactly today's tokens, capitalised or not")
    func lowercaseHitsUnchanged() throws {
        let dictionary = try Self.dictionary.get()
        // "Polish" has its own capitalised entry that differs (the nationality); the
        // lowercase "polish" hit wins, as it always has. Changing that is not this fix.
        #expect(dictionary["Polish"] != dictionary["polish"])
        for (word, key) in [("Polish", "polish"), ("Reading", "reading"), ("AI", "ai"), ("NASA", "nasa"),
                            ("Hello", "hello"), ("OK", "ok")]
        {
            #expect(try spoken(word, in: "\(word) now.") == dictionary[key], "\(word)")
        }
    }

    @Test("house words still win over the dictionary at any case (Kev, Kokoro)")
    func houseWordsUnchanged() throws {
        #expect(try spoken("Kev", in: "Hi Kev.") == HouseLexicon.tokens(for: "kev"))
        #expect(try spoken("Kokoro", in: "Kokoro speaks.") == HouseLexicon.tokens(for: "kokoro"))
    }

    @Test("an inflected capitalised-only word resolves its base by title case (Abujas = Abuja + /z/)")
    func inflectedProperNoun() throws {
        let dictionary = try Self.dictionary.get()
        let base = try #require(dictionary["Abuja"])
        #expect(dictionary["Abujas"] == nil && dictionary["abujas"] == nil)
        #expect(try spoken("Abujas", in: "two Abujas") == base + [68])
    }

    @Test("a capitalised-only key beats the inflection guess it used to get (Phillips, Thebes)")
    func ownEntryBeatsInflection() throws {
        // 18 such keys measured 2026-11-15: "Phillips" used to be "phillip" + /s/. The name's own
        // entry is the dictionary's answer, so it wins; this is the one deliberate change of path.
        let dictionary = try Self.dictionary.get()
        for word in ["Phillips", "Thebes"] {
            let entry = try #require(dictionary[word])
            #expect(dictionary[word.lowercased()] == nil)
            #expect(dictionary[String(word.lowercased().dropLast())] != nil, "\(word) no longer has an inflection base")
            #expect(try spoken(word, in: "From \(word) now.") == entry, "\(word)")
        }
    }

    @Test("a quoted word is rescued too ('abuja', 'I'm')")
    func quotedWords() throws {
        let dictionary = try Self.dictionary.get()
        #expect(try spoken("abuja'", in: "say 'abuja' twice") == dictionary["Abuja"])
        #expect(try spoken("I'm'", in: "he said 'I'm' only") == dictionary["I'm"])
    }

    @Test("karaoke ranges are unchanged: one word per run, every rescued word non-empty")
    func oneWordPerRun() throws {
        let sentence = "I'm sure I'll see Abuja, and I've read about Alzheimer's."
        let result = try Self.g2p.get().annotatedTokens(sentence)
        #expect(result.words.count == 10)
        #expect(result.words.allSatisfy { !$0.tokenRange.isEmpty })
    }
}
