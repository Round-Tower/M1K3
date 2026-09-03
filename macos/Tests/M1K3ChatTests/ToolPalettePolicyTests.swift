import Foundation
import M1K3Agent
import M1K3AgentTools
import M1K3Chat
import M1K3Knowledge
import M1K3KnowledgeTools
import Testing

/// The availability palette: a tool is offered only while what it does is
/// actually there — a corpus to search, a web the toggle allows, a bigger brain
/// the dive would really reach, a battery to read. Inputs are STABLE facts
/// (they change on a toggle, a download, a first document — never per turn),
/// so the palette stays a stable PersonaPrefixCache key: "tune the grounding,
/// never the palette" (ROADMAP) holds.
struct ToolPalettePolicyTests {
    private let everything = ToolPalettePolicy.Availability(
        corpusHasItems: true, webAllowed: true, deepBrainAvailable: true, hasBattery: true
    )

    private func names(_ excluded: Set<String>) -> Set<String> {
        excluded
    }

    @Test("everything available — nothing is excluded")
    func everythingAvailable() {
        #expect(ToolPalettePolicy.excludedNames(for: everything).isEmpty)
    }

    @Test("an empty corpus drops the three knowledge tools and nothing else")
    func emptyCorpus() {
        var a = everything
        a.corpusHasItems = false
        #expect(ToolPalettePolicy.excludedNames(for: a) == ["search_knowledge", "list_documents", "get_document"])
    }

    @Test("web off drops the web trio AND open_link — a page render reaches the internet too")
    func webOff() {
        var a = everything
        a.webAllowed = false
        #expect(ToolPalettePolicy.excludedNames(for: a) == ["web_search", "fetch_page", "lookup_fact", "open_link"])
    }

    @Test("no reachable bigger brain drops delegate_deep")
    func noDeepBrain() {
        var a = everything
        a.deepBrainAvailable = false
        #expect(ToolPalettePolicy.excludedNames(for: a) == ["delegate_deep"])
    }

    @Test("no battery drops battery_status")
    func noBattery() {
        var a = everything
        a.hasBattery = false
        #expect(ToolPalettePolicy.excludedNames(for: a) == ["battery_status"])
    }

    @Test("exclusions compose")
    func compose() {
        let a = ToolPalettePolicy.Availability(
            corpusHasItems: false, webAllowed: false, deepBrainAvailable: false, hasBattery: false
        )
        #expect(ToolPalettePolicy.excludedNames(for: a).count == 9)
    }

    @Test("filter keeps order, drops by name, and passes unknown tools through")
    func filterKeepsOrderAndUnknowns() {
        var a = everything
        a.deepBrainAvailable = false
        let tools: [any AgentTool] = [
            StubTool(name: "datetime"), StubTool(name: "delegate_deep"), StubTool(name: "custom_tool"),
        ]
        let kept = ToolPalettePolicy.filter(tools, availability: a).map(\.name)
        #expect(kept == ["datetime", "custom_tool"])
    }

    /// The policy names tools as strings (M1K3Chat cannot link the tool
    /// modules); a rename that misses this pin would silently un-gate the tool.
    @Test("every governed name matches a live tool declaration")
    func namesMatchLiveTools() throws {
        let store = try KnowledgeStore()
        let knowledge = [
            SearchKnowledgeTool(store: store).name,
            ListDocumentsTool(store: store).name,
            GetDocumentTool(store: store).name,
        ]
        #expect(Set(knowledge) == ToolPalettePolicy.knowledgeToolNames)
        let web = [
            WebSearchTool(deepReader: FetchPageTool()).name,
            FetchPageTool().name,
            WikipediaTool().name,
            OpenLinkTool(onOpen: { _ in }).name,
        ]
        #expect(Set(web) == ToolPalettePolicy.webToolNames)
        #expect([DelegateDeepTool(startDelegation: { _ in "" }).name] == Array(ToolPalettePolicy.deepBrainToolNames))
        #expect([BatteryStatusTool().name] == Array(ToolPalettePolicy.batteryToolNames))
    }
}

private struct StubTool: AgentTool {
    let name: String
    var description: String {
        "stub \(name)"
    }

    let parameters: [ToolParameter] = []
    func execute(input _: [String: String]) async throws -> ToolResult {
        ToolResult(output: "")
    }
}
