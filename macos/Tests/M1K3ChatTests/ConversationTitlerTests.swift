//
//  ConversationTitlerTests.swift
//  M1K3ChatTests
//
//  TitlePrompt and TitleSanitizer are pure; ProviderConversationTitler is a
//  thin adapter pinned with a fake provider. Small local models return messy
//  strings — quotes, "Title:" prefixes, trailing periods, whole paragraphs —
//  so the sanitizer carries the real behaviour.
//

import M1K3Chat
import M1K3Inference
import Testing

struct TitleSanitizerTests {
    @Test("trims whitespace, strips wrapping quotes and a Title: prefix")
    func basicCleanup() {
        #expect(TitleSanitizer.sanitize("  \"Conveyor seal failure\"  ") == "Conveyor seal failure")
        #expect(TitleSanitizer.sanitize("Title: Weather in Cork") == "Weather in Cork")
        #expect(TitleSanitizer.sanitize("'Plant maintenance'") == "Plant maintenance")
        #expect(TitleSanitizer.sanitize("`Code review notes`") == "Code review notes")
    }

    @Test("strips trailing sentence punctuation and collapses internal whitespace")
    func punctuationAndWhitespace() {
        #expect(TitleSanitizer.sanitize("Weather in Cork.") == "Weather in Cork")
        #expect(TitleSanitizer.sanitize("Big   news\ttoday!") == "Big news today")
    }

    @Test("takes only the first non-empty line of a rambling answer")
    func firstLine() {
        #expect(TitleSanitizer.sanitize("\n\nSeal failure\nHere is why I chose this title…") == "Seal failure")
    }

    @Test("caps at 60 characters on a word boundary")
    func capAtWordBoundary() throws {
        let long = "An extremely detailed conversation about the hydraulic conveyor seal replacement schedule"
        let title = TitleSanitizer.sanitize(long)
        #expect(title != nil)
        #expect(try #require(title?.count) <= 60)
        #expect(try !#require(title?.hasSuffix(" ")))
        // Cut lands between words, not mid-word.
        #expect(try long.hasPrefix(#require(title)))
    }

    @Test("garbage input returns nil")
    func garbage() {
        #expect(TitleSanitizer.sanitize("") == nil)
        #expect(TitleSanitizer.sanitize("   \n  ") == nil)
        #expect(TitleSanitizer.sanitize("\"\"") == nil)
        #expect(TitleSanitizer.sanitize("...") == nil)
    }

    /// Live titles, #285: the model's "FOLLOWUPS: [...]" trailer walked past
    /// the old sanitizer (which only stripped quotes/punctuation) and landed
    /// in the history drawer verbatim, mangled by the 60-char word-boundary
    /// cut. Untitled beats mangled.
    @Test("rejects a title carrying the FOLLOWUPS trailer (the two live titles)")
    func rejectsFollowUpsTrailer() {
        #expect(TitleSanitizer.sanitize(#"M1K3 and Kev's Quiet Code Chat FOLLOWUPS: ["What's new with"#) == nil)
        #expect(TitleSanitizer.sanitize(#"CorkEngineerWithHoneyTombMemoryFactsFollowups: ["What else"#) == nil)
    }

    @Test("rejects a run of 25+ non-whitespace characters even without the word FOLLOWUPS")
    func rejectsLongCamelCaseRun() {
        // The second live title's shape in isolation: a model that drops all
        // spacing produces one long unreadable run — the same CamelCase mangle,
        // caught by length rather than by the word "Followups".
        #expect(TitleSanitizer.sanitize("ThisIsAnExtremelyLongIdentifierWithNoSpacesAtAll") == nil)
    }

    @Test("a normal multi-word title is unaffected by the FOLLOWUPS/run guards")
    func normalTitleStillPasses() {
        #expect(TitleSanitizer.sanitize("Weekend hiking plans") == "Weekend hiking plans")
        #expect(TitleSanitizer.sanitize("Onboarding") == "Onboarding")
    }
}

struct TitlePromptTests {
    @Test("the prompt carries both texts and the word-count instruction")
    func promptShape() {
        let prompt = TitlePrompt.build(user: "what's the weather in Cork?", assistant: "Cloudy, 15°C.")
        #expect(prompt.contains("what's the weather in Cork?"))
        #expect(prompt.contains("Cloudy, 15°C."))
        #expect(prompt.contains("3-6 word"))
    }

    @Test("long turns are truncated to keep the titling prompt cheap")
    func truncation() {
        let longUser = String(repeating: "a", count: 1000)
        let prompt = TitlePrompt.build(user: longUser, assistant: "ok")
        #expect(!prompt.contains(String(repeating: "a", count: 401)))
    }
}

private struct CannedProvider: InferenceProvider {
    let canned: String
    var name: String {
        "canned"
    }

    var isAvailable: Bool {
        true
    }

    func generate(prompt _: String) async throws -> String {
        canned
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

/// Records the exact prompt it was asked to complete — proves what the
/// titler SENDS, not just what it returns.
private actor PromptCapturingProvider: InferenceProvider {
    private(set) var lastPrompt: String?
    private let canned: String
    nonisolated let name = "prompt-capturing"
    nonisolated let isAvailable = true

    init(canned: String) {
        self.canned = canned
    }

    func generate(prompt: String) async throws -> String {
        lastPrompt = prompt
        return canned
    }

    nonisolated func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

struct ProviderConversationTitlerTests {
    @Test("the adapter returns the provider's output for the built prompt")
    func adapter() async throws {
        let titler = ProviderConversationTitler(provider: CannedProvider(canned: "\"Cork weather\""))
        let raw = try await titler.title(forUser: "weather?", assistant: "15°C")
        #expect(raw == "\"Cork weather\"")
    }

    /// #285 belt fix: if a FOLLOWUPS trailer is still attached to the
    /// assistant text on some path (the live titler always reads a
    /// post-split `ChatMessage.text`, but this is defence in depth), the
    /// titling PROMPT itself must never carry the sentinel through to the
    /// model.
    @Test("the assistant text is FollowUpSplit'd before it reaches the title prompt")
    func stripsFollowUpsBeforeBuildingThePrompt() async throws {
        let provider = PromptCapturingProvider(canned: "Untitled chat")
        let titler = ProviderConversationTitler(provider: provider)
        _ = try await titler.title(
            forUser: "yo",
            assistant: #"Ah, Kev. Just back. FOLLOWUPS: ["What's new with the Mac?"]"#
        )
        let prompt = try #require(await provider.lastPrompt)
        #expect(!prompt.contains("FOLLOWUPS:"))
        #expect(prompt.contains("Ah, Kev. Just back."))
    }
}
