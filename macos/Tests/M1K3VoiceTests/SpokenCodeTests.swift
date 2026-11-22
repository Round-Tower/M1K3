//
//  SpokenCodeTests.swift
//  M1K3VoiceTests
//
//  Code is for the eyes (Kev, 2026-11-22: "Mike still speaks code"). Driven as the shells drive
//  it, character by character: the sentence folder, then the polish.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-22, Confidence 0.85 (pure pipeline; the sound of it is
//  verify-on-device). Prior: none (new file).
//

@testable import M1K3Voice
import Testing

struct SpokenCodeTests {
    private func heard(_ answer: String) -> String {
        var folder = SentenceStreamFolder()
        var chunks: [String] = []
        var streamed = ""
        for character in answer {
            streamed.append(character)
            chunks += folder.ingest(streamed)
        }
        if let tail = folder.flush() { chunks.append(tail) }
        return chunks.compactMap(SpeechTextPolish.spokenSentence).joined(separator: " ")
    }

    @Test("streamed code is never heard, and the words around it are", arguments: [
        "Here it is.\n```html\n<h1>CANARY. Hello!</h1>\n```\nThat's the page.",
        "Here it is.\n  ```python\n  print(\"CANARY. Hi\")\n  ```\nThat's the page.",
        "Here it is.\n```python\nfence = \"```\"\nprint(\"CANARY. Hi\")\n```\nThat's the page.",
        "Here it is.\n```markdown\n# Setup\n```sh\necho CANARY. Hi\n```\nThat's the page.",
        "Here it is.\n````markdown\n```sh\necho CANARY. Hi\n```\nCANARY again.\n````\nThat's the page.",
    ])
    func streamedCodeIsSilent(answer: String) {
        let spoken = heard(answer)
        #expect(!spoken.contains("CANARY"))
        #expect(spoken.contains("Here it is."))
        #expect(spoken.contains("That's the page."))
    }

    @Test("an answer cut off inside code doesn't read it")
    func unclosedCodeIsSilent() {
        let spoken = heard("Here it is.\n```html\n<p>CANARY. Still going")
        #expect(!spoken.contains("CANARY"))
    }

    @Test("a lone code chunk polishes to words: an empty one would be read raw by the voice loop")
    func loneChunkIsNeverEmpty() {
        #expect(SpeechTextPolish.polish("```swift\nlet x = 1\n```") == "I've put that on screen.")
    }
}
