import Foundation
import M1K3LiveActivity
import Testing

/// The Live Activity says WHERE a turn is, never WHAT it is about. These pins make a free-text
/// field (a question, a file name, an answer) a failing test rather than a code-review catch:
/// the Lock Screen and the Dynamic Island are readable by anyone holding a locked phone.
struct TurnActivityStateTests {
    @Test("the content state encodes to exactly one key, the phase")
    func contentStateIsPhaseOnly() throws {
        let data = try JSONEncoder().encode(TurnActivityState(phase: .answering))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["phase"])
        #expect(object["phase"] as? String == "answering")
    }

    @Test("the only stored property is the phase, and the phase is a closed enum of fixed words")
    func phaseIsAClosedEnum() {
        let labels = Mirror(reflecting: TurnActivityState(phase: .thinking)).children.map(\.label)
        #expect(labels == ["phase"])
        #expect(Set(TurnActivityPhase.allCases.map(\.rawValue))
            == ["thinking", "reading", "answering", "ready", "paused"])
    }

    @Test("every phase round-trips", arguments: TurnActivityPhase.allCases)
    func roundTrips(phase: TurnActivityPhase) throws {
        let state = TurnActivityState(phase: phase)
        let back = try JSONDecoder().decode(TurnActivityState.self, from: JSONEncoder().encode(state))
        #expect(back == state)
    }

    @Test("the tap target is the chat, with no query, fragment or path to carry a question")
    func tapLinkCarriesNothing() throws {
        let components = try #require(URLComponents(url: TurnActivityLink.url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "m1k3")
        #expect(components.host == "chat")
        #expect(components.query == nil)
        #expect(components.fragment == nil)
        #expect(components.path.isEmpty)
    }

    @Test("the module stays tiny: every source imports only Foundation or ActivityKit")
    func sourcesImportAlmostNothing() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/M1K3LiveActivity")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let imports = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .filter { $0.hasPrefix("import ") }.map { $0.dropFirst(7).trimmingCharacters(in: .whitespaces) }
            #expect(Set(imports).isSubset(of: ["Foundation", "ActivityKit"]), "\(file.lastPathComponent): \(imports)")
        }
    }
}
