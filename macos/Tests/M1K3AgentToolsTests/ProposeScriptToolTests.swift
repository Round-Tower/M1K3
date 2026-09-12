//
//  ProposeScriptToolTests.swift
//  M1K3AgentToolsTests
//
//  The inert half of the hands: proposing a script surfaces it to the app for
//  the user's review — nothing is written, nothing runs, until they install it.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5, 2026-09-12, Confidence 0.85 — pins the description line that keeps
//  web pages and documents out of the script tool (Kev: "coding / document generation is not being invoked").

import Foundation
@testable import M1K3AgentTools
import Testing

struct ProposeScriptToolTests {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _proposal: ScriptProposal?
        var proposal: ScriptProposal? {
            lock.withLock { _proposal }
        }

        func set(_ proposal: ScriptProposal) {
            lock.withLock { _proposal = proposal }
        }
    }

    @Test("declares the propose_script contract the model sees")
    func contract() {
        let tool = ProposeScriptTool { _ in }
        #expect(tool.name == "propose_script")
        #expect(tool.parameters.map(\.name) == ["name", "content", "purpose"])
        #expect(tool.exclusionClass == nil) // inert: the human review is the gate
    }

    @Test("the description keeps web pages and documents out of the script tool (2026-09-12)")
    func notForWebPages() {
        // Byte-replayed on Lil: "code me a tiny HTML page" went to propose_script 3/4 on
        // master as a bash heredoc writing counter.html; with this line and the carve's
        // matching sentence, 1/12 across the page probes — and a real disk-space script
        // still reached the tool 6/6.
        let description = ProposeScriptTool { _ in }.description
        #expect(description.contains("Never for a web page or a document"))
        #expect(description.contains("```html or ```markdown block"))
        #expect(description.contains("runnable script (shell/bash/zsh)"))
    }

    @Test("a valid proposal reaches the app and the observation says review is owed")
    func proposes() async throws {
        let box = Box()
        let tool = ProposeScriptTool { box.set($0) }
        let result = try await tool.execute(input: [
            "name": "disk_report.sh",
            "content": "#!/bin/zsh\ndf -h",
            "purpose": "report free disk space",
        ])
        #expect(box.proposal?.name == "disk_report.sh")
        #expect(box.proposal?.content.contains("df -h") == true)
        #expect(!result.output.hasPrefix("Error:"))
        #expect(result.output.lowercased().contains("review"))
    }

    @Test("bad names are refused before the app sees anything")
    func refusesBadNames() async throws {
        let box = Box()
        let tool = ProposeScriptTool { box.set($0) }
        for name in ["", "../up.sh", "a/b.sh", ".hidden", "spaced name.sh"] {
            let result = try await tool.execute(input: ["name": name, "content": "x", "purpose": "p"])
            #expect(result.output.hasPrefix("Error:"), "expected refusal for \(name)")
        }
        #expect(box.proposal == nil)
    }

    @Test("empty content is refused")
    func refusesEmptyContent() async throws {
        let box = Box()
        let tool = ProposeScriptTool { box.set($0) }
        let result = try await tool.execute(input: ["name": "ok.sh", "content": "  ", "purpose": "p"])
        #expect(result.output.hasPrefix("Error:"))
        #expect(box.proposal == nil)
    }
}
