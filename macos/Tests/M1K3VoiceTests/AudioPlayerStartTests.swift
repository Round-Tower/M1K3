import Foundation
@testable import M1K3Voice
import Testing

/// The audio player's start can raise an NSException ("player did not see an IO cycle") that Swift cannot
/// catch; on the phone it aborted the app at the background exit. The catch is pinned here with a plain
/// NSException; the player's own refusal needs a device.
struct AudioPlayerStartTests {
    @Test("a framework call that raises an NSException comes back as its reason, not a crash")
    func anExceptionIsAValue() {
        let reason = AudioPlayerStart.attempt {
            NSException(name: .internalInconsistencyException, reason: "player did not see an IO cycle.").raise()
        }
        #expect(reason == "player did not see an IO cycle.")
    }

    @Test("an exception with no reason reports its name")
    func noReasonReportsTheName() {
        let reason = AudioPlayerStart.attempt {
            NSException(name: .rangeException, reason: nil).raise()
        }
        #expect(reason == NSExceptionName.rangeException.rawValue)
    }

    @Test("a call that does not raise reports nothing, and has run")
    func aCleanCallRuns() {
        var ran = false
        #expect(AudioPlayerStart.attempt { ran = true } == nil)
        #expect(ran)
    }

    /// No bare `player.play()` in the module: every start goes through the guard.
    @Test("every player start in the module goes through the guard")
    func noBareStarts() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/M1K3Voice")
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var bare: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" && file.lastPathComponent != "AudioPlayerStart.swift" {
            for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                // Any receiver: `player.play()`, `node.play()`, `self.playerNode.play()`.
                let code = line.components(separatedBy: " //").first ?? ""
                if code.contains(".play()") { bare.append("\(file.lastPathComponent):\(index + 1)") }
            }
        }
        #expect(bare.isEmpty, "bare player starts: \(bare)")
    }

    private static func streaming() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/M1K3Voice/EffectfulSpeechProvider+Streaming.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("a start refused before anything was heard reports not spoken, so the fallback voice gets its turn")
    func aSilentRefusalFallsBack() throws {
        let source = try Self.streaming()
        #expect(source.contains("return started && (heard || !startRefused)"))
        let refused = try #require(source.range(of: "startRefused = true"))
        let heard = try #require(source.range(of: "heard = true"))
        #expect(refused.lowerBound < heard.lowerBound, "heard is set only after a start that was not refused")
    }

    @Test("a refused start does not also end the stream (the session would complete twice)")
    func noDoubleCompletion() throws {
        #expect(try Self.streaming().contains("if !startRefused { session.markStreamEnded() }"))
    }
}
