//
//  IntentInputsTests.swift
//  M1K3ChatTests
//
//  Pure validation/derivation for the App Intents (Ask · Speak · Remember).
//  The perform() bodies are app-glue (verify-by-launch); this is the testable
//  boundary they call before touching any service.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.85, Prior: Unknown
//

@testable import M1K3Chat
import Testing

struct IntentInputsTests {
    // MARK: askQuestion

    @Test("askQuestion trims surrounding whitespace")
    func askTrims() throws {
        #expect(try IntentInput.askQuestion("  what's the time?  ") == "what's the time?")
    }

    @Test("askQuestion rejects empty / whitespace-only input")
    func askRejectsEmpty() {
        #expect(throws: IntentInput.EmptyInput.self) { try IntentInput.askQuestion("") }
        #expect(throws: IntentInput.EmptyInput.self) { try IntentInput.askQuestion("   \n\t ") }
    }

    @Test("askQuestion's empty error names the question field")
    func askErrorField() {
        do {
            _ = try IntentInput.askQuestion(" ")
            Issue.record("expected EmptyInput")
        } catch let error as IntentInput.EmptyInput {
            #expect(error.field == "question")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: speakText

    @Test("speakText trims and passes content through")
    func speakTrims() throws {
        #expect(try IntentInput.speakText("  hello there  ") == "hello there")
    }

    @Test("speakText rejects empty input")
    func speakRejectsEmpty() {
        #expect(throws: IntentInput.EmptyInput.self) { try IntentInput.speakText("   ") }
    }

    // MARK: rememberText (body)

    @Test("rememberText trims and returns the body")
    func rememberBodyTrims() throws {
        #expect(try IntentInput.rememberText("  Aoife likes hiking  ") == "Aoife likes hiking")
    }

    @Test("rememberText rejects empty input")
    func rememberRejectsEmpty() {
        #expect(throws: IntentInput.EmptyInput.self) { try IntentInput.rememberText("\n  ") }
    }

    // MARK: rememberTitle

    @Test("rememberTitle prefers a non-empty explicit title (trimmed)")
    func titleUsesExplicit() {
        #expect(IntentInput.rememberTitle(from: "anything", explicit: "  Galway trip  ") == "Galway trip")
    }

    @Test("rememberTitle falls back to derivation when explicit is empty or nil")
    func titleFallsBack() {
        #expect(IntentInput.rememberTitle(from: "I met Aoife in Galway. She hikes.", explicit: "   ")
            == "I met Aoife in Galway")
        #expect(IntentInput.rememberTitle(from: "I met Aoife in Galway. She hikes.", explicit: nil)
            == "I met Aoife in Galway")
    }

    @Test("derived title takes the first sentence and collapses whitespace")
    func titleFirstSentence() {
        #expect(IntentInput.rememberTitle(from: "  Buy   milk\nand eggs. Later.", explicit: nil)
            == "Buy milk and eggs")
    }

    @Test("derived title truncates long single-sentence text at a word boundary with an ellipsis")
    func titleTruncates() {
        let long = String(repeating: "word ", count: 40) // 200+ chars, no sentence break
        let title = IntentInput.rememberTitle(from: long, explicit: nil)
        #expect(title.count <= IntentInput.titleCharacterCap + 1) // +1 for the ellipsis
        #expect(title.hasSuffix("…"))
        #expect(!title.contains("  ")) // word boundary, not mid-word
    }

    @Test("derived title truncates a single over-long word at the cap with an ellipsis")
    func titleTruncatesSingleWord() {
        let giant = String(repeating: "x", count: 70) // no spaces — exercises the hard-cut fallback
        let title = IntentInput.rememberTitle(from: giant, explicit: nil)
        #expect(title.count == IntentInput.titleCharacterCap + 1) // cap chars + the ellipsis
        #expect(title.hasSuffix("…"))
        #expect(title.hasPrefix("x"))
    }

    @Test("derived title degrades to a stable fallback for content-less text")
    func titleFallbackLabel() {
        #expect(IntentInput.rememberTitle(from: "   \n  ", explicit: nil) == "Memory")
    }

    // MARK: searchQuery

    @Test("searchQuery trims surrounding whitespace")
    func searchTrims() throws {
        #expect(try IntentInput.searchQuery("  local RAG  ") == "local RAG")
    }

    @Test("searchQuery rejects empty input")
    func searchRejectsEmpty() {
        #expect(throws: IntentInput.EmptyInput.self) { try IntentInput.searchQuery("") }
        #expect(throws: IntentInput.EmptyInput.self) { try IntentInput.searchQuery("   ") }
    }

    @Test("searchQuery's empty error names the query field")
    func searchErrorField() {
        do {
            _ = try IntentInput.searchQuery(" ")
            Issue.record("expected EmptyInput")
        } catch let error as IntentInput.EmptyInput {
            #expect(error.field == "query")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: recallQuery

    @Test("recallQuery trims and passes content through")
    func recallTrims() throws {
        #expect(try IntentInput.recallQuery("  hiking trip  ") == "hiking trip")
    }

    @Test("recallQuery rejects empty input")
    func recallRejectsEmpty() {
        #expect(throws: IntentInput.EmptyInput.self) { try IntentInput.recallQuery("  \n ") }
    }

    // MARK: todoTitle

    @Test("todoTitle trims and passes content through")
    func todoTitleTrims() throws {
        #expect(try IntentInput.todoTitle("  Buy milk  ") == "Buy milk")
    }

    @Test("todoTitle rejects empty input")
    func todoTitleRejectsEmpty() {
        #expect(throws: IntentInput.EmptyInput.self) { try IntentInput.todoTitle("") }
    }

    @Test("todoTitle's empty error names the title field")
    func todoTitleErrorField() {
        do {
            _ = try IntentInput.todoTitle(" ")
            Issue.record("expected EmptyInput")
        } catch let error as IntentInput.EmptyInput {
            #expect(error.field == "title")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}
