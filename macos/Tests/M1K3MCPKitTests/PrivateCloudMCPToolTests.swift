//
//  PrivateCloudMCPToolTests.swift
//  M1K3MCPKitTests
//
//  Pins `ask_private_cloud`: it hands the app exactly the agent's prompt and
//  instructions, refuses an empty prompt before anything leaves, and says in
//  its own description that it is not local.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.85, Prior: none (new file).
//

@testable import M1K3MCPKit
import MCP
import Synchronization
import Testing

private final class Asked: Sendable {
    let calls = Mutex<[(prompt: String, instructions: String)]>([])
}

private func run(
    _ args: [String: Value]?, answer: String = "An answer.", asked: Asked = Asked()
) async -> (isError: Bool, text: String, asked: [(prompt: String, instructions: String)]) {
    let registry = MCPToolRegistry(makePrivateCloudToolDefinitions(handlers: PrivateCloudToolHandlers { prompt, instructions in
        asked.calls.withLock { $0.append((prompt, instructions)) }
        return answer
    }))
    let result = await registry.call(name: "ask_private_cloud", arguments: args)
    let text: String = if case let .text(text, _, _) = result.content.first { text } else { "" }
    return (result.isError == true, text, asked.calls.withLock { $0 })
}

struct PrivateCloudMCPToolTests {
    @Test("The agent's prompt and instructions are handed over as given, and the answer comes back")
    func passesTheCallersWords() async {
        let result = await run(["prompt": "Summarise this.", "instructions": "Be brief."])
        #expect(!result.isError)
        #expect(result.text == "An answer.")
        #expect(result.asked.count == 1)
        #expect(result.asked.first?.prompt == "Summarise this.")
        #expect(result.asked.first?.instructions == "Be brief.")
    }

    @Test("Instructions are optional and default to none")
    func instructionsOptional() async {
        let result = await run(["prompt": "Hi"])
        #expect(result.asked.first?.instructions == "")
    }

    @Test("An empty or missing prompt is refused before anything is asked")
    func emptyPromptRefused() async {
        for args: [String: Value]? in [nil, [:], ["prompt": "   "]] {
            let result = await run(args)
            #expect(result.isError)
            #expect(result.asked.isEmpty)
        }
    }

    @Test("An empty answer is an error, never an empty success")
    func emptyAnswerIsAnError() async {
        let result = await run(["prompt": "Hi"], answer: "  ")
        #expect(result.isError)
    }

    @Test("The tool says in its own description that it is not local, and what is sent")
    func descriptionSaysItLeavesTheMac() throws {
        let tool = try #require(makePrivateCloudToolDefinitions(handlers: PrivateCloudToolHandlers { _, _ in "" }).first?.tool)
        let description = tool.description ?? ""
        #expect(tool.name == PrivateCloudMCPTool.name)
        #expect(description.contains("NOT local"))
        #expect(description.contains("Private Cloud Compute"))
        #expect(description.contains("ask_m1k3"))
    }
}
