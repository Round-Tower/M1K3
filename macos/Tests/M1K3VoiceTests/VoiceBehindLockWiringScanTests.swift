import Foundation
import Testing

/// The iPhone shell is not built by `swift test`, so the mic invariants of voice behind the lock (#909) are pinned on
/// its source. The mic runs between listens behind the lock; every way out must stop it, and the Lock Screen must
/// never say "listening" with the mic off.
struct VoiceBehindLockWiringScanTests {
    private static func code(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The text of one function, from its declaration to the next one at the same indent.
    private static func body(of declaration: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: declaration))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        return rest[..<end]
    }

    @Test("leaving voice mode clears the keep-running flag before the guard, ends the card, and releases the mic")
    func exitStopsTheMic() throws {
        let exit = try Self.body(of: "func exitVoiceMode()", in: Self.code("M1K3iOSApp/AppCore+Voice.swift"))
        let flag = try #require(exit.range(of: "keepsMicRunningBetweenListens = false"))
        let guardLine = try #require(exit.range(of: "guard let controller = voiceLoop"))
        let stop = try #require(exit.range(of: "controller.exit()"))
        let release = try #require(exit.range(of: "releaseAudioHardware()"))
        #expect(flag.lowerBound < guardLine.lowerBound, "no path out of exitVoiceMode leaves the flag on")
        #expect(exit.contains("voiceBehindLock.conversationEnded()"))
        #expect(stop.lowerBound < release.lowerBound, "the release covers an engine no listen holds")
    }

    @Test("the return from behind the lock, and a stand-down in front, both clear the flag and release the mic")
    func returnStopsTheKeptMic() throws {
        let shell = try Self.code("M1K3iOSApp/AppCore+VoiceBehindLock.swift")
        let back = try Self.body(of: "func voiceBehindLockReturning()", in: shell)
        #expect(back.components(separatedBy: "keepsMicRunningBetweenListens = false").count == 3)
        #expect(back.components(separatedBy: "releaseAudioHardware()").count == 3)
    }

    @Test("going inactive starts the engine ahead of the lock, and only for a conversation the lock would keep")
    func inactiveStartsTheEngine() throws {
        let shell = try Self.code("M1K3iOSApp/AppCore+VoiceBehindLock.swift")
        let inactive = try Self.body(of: "func voiceBehindLockGoingInactive()", in: shell)
        let keep = try #require(inactive.range(of: "guard voiceBehindLockBrain != nil"))
        let start = try #require(inactive.range(of: "startKeepingMicRunning()"))
        #expect(keep.lowerBound < start.lowerBound)
    }

    @Test("behind the lock nothing runs on the GPU: the room classifier is off and Kokoro hands over")
    func noGPUBehindTheLock() throws {
        let shell = try Self.code("M1K3iOSApp/AppCore+VoiceBehindLock.swift")
        let enter = try Self.body(of: "func enterVoiceBehindLock(", in: shell)
        #expect(enter.contains("hearsRoom = false"))
        #expect(enter.contains("speech.setProvider(builtinSpeech)"))
        #expect(enter.contains("lookCamera.close()"))
    }
}
