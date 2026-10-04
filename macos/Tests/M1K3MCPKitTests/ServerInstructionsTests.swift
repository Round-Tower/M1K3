//
//  ServerInstructionsTests.swift
//  M1K3MCPKitTests
//
//  The MCP `instructions` M1K3 hands every agent at initialize: built from the
//  tools a server actually registers, so an agent is told to talk through
//  `speak` only where `speak` exists, and never told about a tool it lacks.
//

@testable import M1K3MCPKit
import MCP
import Testing

private let voice: Set<String> = ["speak", "get_status", "listen", "stop_speaking"]
private let knowledge: Set<String> = ["search_knowledge", "remember", "ask_m1k3"]

@Test func aServerWithSpeakMakesM1K3TheAgentsVoice() {
    let text = M1K3ServerInstructions.text(toolNames: voice.union(knowledge))
    #expect(text.contains("`speak`"))
    #expect(text.contains("`get_status`"))
}

@Test func speakWithoutStatusNeverPointsAtAMissingTool() {
    let text = M1K3ServerInstructions.text(toolNames: ["speak"])
    #expect(text.contains("`speak`"))
    #expect(!text.contains("get_status"))
}

@Test func aServerWithNoToolsSaysOnlyWhoM1K3Is() {
    let text = M1K3ServerInstructions.text(toolNames: [])
    #expect(!text.contains("`"))
}

@Test func speakingIsHeardByTheRoomSoSecretsStayOnScreen() {
    let text = M1K3ServerInstructions.text(toolNames: voice)
    #expect(text.contains("secret"))
}

@Test func aServerWithoutSpeakNeverMentionsIt() {
    let text = M1K3ServerInstructions.text(toolNames: knowledge)
    #expect(!text.contains("speak"))
    #expect(!text.contains("get_status"))
    #expect(text.contains("`search_knowledge`"))
    #expect(text.contains("`remember`"))
}

@Test func onlyTheKnowledgeToolsPresentAreNamed() {
    let text = M1K3ServerInstructions.text(toolNames: ["search_knowledge"])
    #expect(text.contains("`search_knowledge`"))
    #expect(!text.contains("`remember`"))
    #expect(!text.contains("`ask_m1k3`"))
}

@Test func theInstructionsStayShortBecauseTheyLoadIntoEveryAgentTurn() {
    let text = M1K3ServerInstructions.text(toolNames: voice.union(knowledge))
    #expect(text.count < M1K3ServerInstructions.characterBudget)
}

@Test func makeM1K3ServerHandsTheInstructionsToEveryClient() async {
    let speak = MCPToolDefinition(
        tool: Tool(name: "speak", description: "say it", inputSchema: .object([:])),
        handler: { _ in "Spoken." }
    )
    let server = await makeM1K3Server(registry: MCPToolRegistry([speak]))
    #expect(server.instructions?.contains("`speak`") == true)
}
