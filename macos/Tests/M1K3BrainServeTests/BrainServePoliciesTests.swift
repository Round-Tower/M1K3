//
//  BrainServePoliciesTests.swift
//  M1K3BrainServeTests
//
//  Route classification, request parsing, SSE frames, remote-turn admission,
//  and the LAN tool scope.
//

import Foundation
@testable import M1K3BrainServe
import M1K3MCPKit
import MCP
import Testing

struct BrainServeRouteTests {
    @Test("the four routes classify; everything else is notFound")
    func classify() {
        #expect(BrainServeRoute.classify(method: "POST", path: "/v1/generate") == .generate)
        #expect(BrainServeRoute.classify(method: "GET", path: "/v1/health") == .health)
        #expect(BrainServeRoute.classify(method: "POST", path: "/mcp") == .mcp)
        #expect(BrainServeRoute.classify(method: "POST", path: "/v1/pair") == .pair)
        #expect(BrainServeRoute.classify(method: "GET", path: "/v1/generate") == .notFound)
        #expect(BrainServeRoute.classify(method: "POST", path: "/admin") == .notFound)
    }
}

struct GenerateRequestTests {
    @Test("a valid body parses prompt and optional max_tokens")
    func valid() {
        let body = Data(#"{"prompt":"why is the sky blue?","max_tokens":128}"#.utf8)
        #expect(GenerateRequest.parse(body) == GenerateRequest(prompt: "why is the sky blue?", maxTokens: 128))
        let bare = Data(#"{"prompt":"hi"}"#.utf8)
        #expect(GenerateRequest.parse(bare) == GenerateRequest(prompt: "hi", maxTokens: nil))
    }

    @Test("junk JSON, no body, and a blank prompt all refuse to parse")
    func invalid() {
        #expect(GenerateRequest.parse(nil) == nil)
        #expect(GenerateRequest.parse(Data("not json".utf8)) == nil)
        #expect(GenerateRequest.parse(Data(#"{"prompt":"  "}"#.utf8)) == nil)
    }
}

struct RemoteTurnDecisionTests {
    @Test("thermal pressure outranks busy; both refuse; idle+cool serves")
    func decisions() {
        #expect(RemoteTurnDecision.decide(localBusy: false, thermalPressure: false) == .serve)
        #expect(RemoteTurnDecision.decide(localBusy: true, thermalPressure: false)
            == .busyLocal(retryAfterSeconds: 15))
        // Remote yields FIRST under heat (§8a.3) — even if local is also busy.
        #expect(RemoteTurnDecision.decide(localBusy: true, thermalPressure: true)
            == .coolingDown(retryAfterSeconds: 120))
    }

    @Test("a not-ready brain refuses with warming — a remote turn can never trigger a load")
    func notReadyRefuses() {
        #expect(RemoteTurnDecision.decide(localBusy: false, thermalPressure: false, notReady: true)
            == .warmingUp(retryAfterSeconds: 30))
        // Thermal still outranks; warming outranks plain busy (more specific).
        #expect(RemoteTurnDecision.decide(localBusy: true, thermalPressure: true, notReady: true)
            == .coolingDown(retryAfterSeconds: 120))
        #expect(RemoteTurnDecision.decide(localBusy: true, thermalPressure: false, notReady: true)
            == .warmingUp(retryAfterSeconds: 30))
    }
}

struct BrainServeFramesTests {
    @Test("a token event is real JSON — quotes and newlines can't break the frame")
    func tokenEscaping() {
        let frame = String(decoding: BrainServeFrames.tokenEvent("say \"hi\"\nplease"), as: UTF8.self)
        #expect(frame.hasPrefix("data: "))
        #expect(frame.hasSuffix("\n\n"))
        // The payload between "data: " and the frame terminator decodes back.
        let payload = frame.dropFirst(6).dropLast(2)
        let decoded = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String]
        #expect(decoded?["token"] == "say \"hi\"\nplease")
    }

    @Test("busy decisions render 429 + Retry-After; serve renders nothing")
    func busyFrames() throws {
        #expect(BrainServeFrames.busy(.serve) == nil)
        let busy = try String(decoding: #require(BrainServeFrames.busy(.busyLocal(retryAfterSeconds: 15))), as: UTF8.self)
        #expect(busy.contains("429"))
        #expect(busy.contains("Retry-After: 15"))
        let cooling = try String(decoding: #require(BrainServeFrames.busy(.coolingDown(retryAfterSeconds: 120))), as: UTF8.self)
        #expect(cooling.contains("cooling"))
        let warming = try String(decoding: #require(BrainServeFrames.busy(.warmingUp(retryAfterSeconds: 30))), as: UTF8.self)
        #expect(warming.contains("429"))
        #expect(warming.contains("warming"))
        let remote = try String(decoding: #require(BrainServeFrames.busy(.busyRemote(retryAfterSeconds: 15))), as: UTF8.self)
        #expect(remote.contains("429"))
    }

    @Test("the SSE head declares an event stream and closes the connection after")
    func sseHead() {
        let head = String(decoding: BrainServeFrames.sseHead(), as: UTF8.self)
        #expect(head.contains("text/event-stream"))
        #expect(head.contains("Connection: close"))
        #expect(!head.contains("Content-Length")) // the stream IS the body
    }
}

struct MCPToolScopeTests {
    private func definition(_ name: String) -> MCPToolDefinition {
        MCPToolDefinition(
            tool: Tool(name: name, description: "", inputSchema: ["type": "object"]),
            handler: { _ in "" }
        )
    }

    @Test("loopback passes everything; lan is the read/ask allowlist")
    func scoping() {
        let names = [
            "search_knowledge", "remember", "forget_memory", "speak", "listen",
            "stop_speaking", "open_link", "ask_m1k3", "get_answer", "get_status",
            "memory_stats", "recall_memory", "related_memory", "list_documents",
            "get_document",
        ]
        let defs = names.map(definition)
        #expect(scopedToolDefinitions(defs, scope: .loopback).count == names.count)

        let lan = scopedToolDefinitions(defs, scope: .lan).map(\.tool.name)
        // Reads and asks survive…
        #expect(lan.contains("search_knowledge"))
        #expect(lan.contains("ask_m1k3"))
        #expect(lan.contains("recall_memory"))
        // …every write/effectful tool is gone: remember + forget mutate the
        // user's permanent memory; speak/listen/stop drive the Mac's speakers
        // and MICROPHONE; open_link drives the screen. None belong to a
        // remote caller by default (audit N4: no silent widening).
        for excluded in ["remember", "forget_memory", "speak", "listen", "stop_speaking", "open_link"] {
            #expect(!lan.contains(excluded), "\(excluded) must not reach the LAN scope")
        }
    }

    @Test("the allowlist is an ALLOWlist — an unknown new tool is LAN-invisible")
    func unknownToolExcluded() {
        let lan = scopedToolDefinitions([definition("brand_new_tool")], scope: .lan)
        #expect(lan.isEmpty)
    }
}
