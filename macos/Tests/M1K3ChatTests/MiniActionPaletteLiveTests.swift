//
//  MiniActionPaletteLiveTests.swift
//  M1K3ChatTests
//
//  Live, opt-in (`M1K3_AFM_EVAL=1`): what the native tool session's palette costs Mini in
//  tokens, measured by AFM itself (`SystemLanguageModel.tokenCount(for: [Tool])`) over the
//  same wrapping the session uses (`AFMNativeTool.wrap`). #427: an action pick's agent turn
//  overflowed at 4,282 tokens on 375 with the whole palette; the action-only palette is the
//  fix, and this is the number behind it.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.85 (AFM's own count; the palette
//  mirrors the Mac interactive one minus the settings-gated senses and scripts). Prior: none.
//

#if canImport(FoundationModels)
    import Foundation
    import FoundationModels
    import M1K3Agent
    import M1K3AgentTools
    @testable import M1K3Chat
    import M1K3Inference
    import M1K3Knowledge
    import M1K3KnowledgeTools
    import Testing

    @Suite(.enabled(if: ProcessInfo.processInfo.environment["M1K3_AFM_EVAL"] == "1"))
    struct MiniActionPaletteLiveTests {
        /// The Mac interactive palette, web on, without the settings-gated senses and scripts.
        static func interactivePalette(store: KnowledgeStore) -> [any AgentTool] {
            [
                WebSearchTool(), FetchPageTool(), WikipediaTool(), DateTimeTool(), SystemStatusTool(),
                SearchKnowledgeTool(store: store), ListDocumentsTool(store: store), GetDocumentTool(store: store),
                DelegateDeepTool(startDelegation: { _ in "" }), RecentActivityTool(reader: NullActivityReading()),
                OpenLinkTool(onOpen: { _ in }),
            ]
        }

        @available(macOS 26.4, iOS 26.4, visionOS 26.4, *)
        static func tokens(_ tools: [any AgentTool]) async throws -> Int {
            let wrapped = AFMNativeTool.wrap(tools.map(\.toolDefinition)) { _, _ in }
            return try await SystemLanguageModel.default.tokenCount(for: wrapped)
        }

        @Test("the action-only palette costs Mini's native session far less than the whole one")
        func actionPaletteIsSmaller() async throws {
            guard #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) else { return }
            try #require(SystemLanguageModel.default.isAvailable, "Apple Intelligence is not available to this process")
            let palette = try Self.interactivePalette(store: KnowledgeStore())
            let acting = ToolDispatch.actionPalette(palette)
            let full = try await Self.tokens(palette)
            let action = try await Self.tokens(acting)
            let persona = try await SystemLanguageModel.default.tokenCount(for: Instructions(M1K3Persona.miniSystemPrompt))
            print("""
            palette tokens: full \(full) (\(palette.count) tools) · action-only \(action) \
            (\(acting.map(\.name).sorted().joined(separator: ", "))) · saved \(full - action) · \
            Mini persona \(persona) · window \(SystemLanguageModel.default.contextSize)
            """)
            #expect(action < full)
        }
    }
#endif
