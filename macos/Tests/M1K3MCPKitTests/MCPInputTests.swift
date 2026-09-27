//
//  MCPInputTests.swift
//  M1K3MCPKitTests
//
//  The free-text argument gate every MCP tool reads through (#378, #379): a wrong-typed
//  argument is refused rather than read as empty, and an over-cap one is refused before
//  it reaches the embedder, the model or the voice.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.85 (pure; the caps are
//  judgement, pinned so a change is deliberate). Prior: none (new file).
//

@testable import M1K3MCPKit
import MCP
import Testing

private func refusal(_ body: () throws -> String?) -> String? {
    do {
        _ = try body()
        return nil
    } catch {
        return (error as? MCPInputError)?.description
    }
}

struct MCPInputTests {
    @Test("a string argument comes back trimmed; absent, null or blank is nil")
    func trimmedOrNil() throws {
        #expect(try MCPInput.text(["q": .string("  hi \n")], "q", tool: "t", maxLength: 10) == "hi")
        #expect(try MCPInput.text(nil, "q", tool: "t", maxLength: 10) == nil)
        #expect(try MCPInput.text(["q": .null], "q", tool: "t", maxLength: 10) == nil)
        #expect(try MCPInput.text(["q": .string("   ")], "q", tool: "t", maxLength: 10) == nil)
    }

    @Test("#378: a wrong-typed argument is refused, not read as empty")
    func wrongTypeRefused() {
        let message = refusal { try MCPInput.text(["query": .int(42)], "query", tool: "search_knowledge", maxLength: 10) }
        #expect(message == "search_knowledge: query must be a string")
    }

    @Test("#379: over the cap is refused, and the refusal never reflects the text")
    func overCapRefused() throws {
        #expect(try MCPInput.text(["q": .string(String(repeating: "a", count: 10))], "q", tool: "t", maxLength: 10) != nil)
        // The cap counts the trimmed text: padding doesn't push a fitting query over.
        #expect(try MCPInput.text(["q": .string("  " + String(repeating: "a", count: 10) + "  ")], "q", tool: "t", maxLength: 10) != nil)
        let long = String(repeating: "brain tier ", count: 12000)
        let message = try #require(refusal { try MCPInput.text(["q": .string(long)], "q", tool: "t", maxLength: 1000) })
        #expect(message == "t: q is over 1000 characters (got 131999)")
    }

    @Test("#439 review: combining marks can't hide a payload inside one character")
    func combiningMarksCounted() throws {
        let zalgo = "a" + String(repeating: "\u{0301}", count: 5000)
        #expect(zalgo.count == 1) // one grapheme: what the cap used to count
        let message = try #require(refusal { try MCPInput.text(["q": .string(zalgo)], "q", tool: "t", maxLength: 1000) })
        #expect(message == "t: q is over 1000 characters (got 5001)")
    }

    @Test("an echo of the caller's text is cut short")
    func echoCut() {
        #expect(MCPInput.echo("short") == "short")
        let echoed = MCPInput.echo(String(repeating: "x", count: 500))
        #expect(echoed.count == MCPInput.echoLength)
        #expect(echoed.hasSuffix("…"))
    }

    @Test("the caps: queries are short, questions longer, notes and speech the longest")
    func capsTable() {
        #expect(MCPInput.maxQuery == 1000)
        #expect(MCPInput.maxQuestion == 4000)
        #expect(MCPInput.maxTitle == 200)
        #expect(MCPInput.maxText == 20000)
    }
}
