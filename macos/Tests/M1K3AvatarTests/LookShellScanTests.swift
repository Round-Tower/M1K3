//
//  LookShellScanTests.swift
//  M1K3AvatarTests
//
//  Source-scan pins on the phone's look wiring (#768). The shell has no pure
//  seam for these (the camera, a SwiftUI body, the composition root), so the
//  guard reads the files from disk, the VoiceModeFloorTests idiom. Each pin is
//  a promise the camera makes: the frame goes to the on-device slot and through
//  `chat.look` (never a send, so never a tool), the eye is shut when voice mode
//  or the Look screen goes away or the app leaves the foreground, and the
//  permission text says what the camera is for and that a frame is kept.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.6 (coarse tripwires
//  on spelling; the behaviour itself is verify-on-device). Prior: none (new file).
//

import Foundation
import Testing

struct LookShellScanTests {
    private static func source(_ relative: String) throws -> String {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Source with comment lines stripped, so headers may describe what is pinned.
    private static func code(_ relative: String) throws -> String {
        let src = try source(relative)
        #expect(!src.isEmpty, "scan read an empty file: \(relative) moved")
        return src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("a frame is asked of the on-device slot through chat.look, never through a send")
    func theFrameTakesTheLeanRoute() throws {
        let wiring = try Self.code("M1K3iOSApp/AppCore+Look.swift")
        #expect(wiring.contains("chat.look(question, frame: frame, looker: looker)"))
        #expect(!wiring.contains("chat.send("), "a look must not become a send: a send can pick a tool")
        #expect(!wiring.contains("homeBrain"), "the look wiring must not reach for Brain at Home")
        let core = try Self.code("M1K3iOSApp/AppCore.swift")
        #expect(core.contains("var looker: any ImageLooking {\n        activeProvider\n    }"))
    }

    @Test("the eye is offered only when the answering brain sees on this device")
    func canLookFollowsImagesAccepted() throws {
        let wiring = try Self.code("M1K3iOSApp/AppCore+Look.swift")
        #expect(wiring.contains("imagesAccepted && LookCamera.deviceHasCamera"))
    }

    @Test("a voice turn tries the look before the ordinary send")
    func voiceTriesTheLookFirst() throws {
        let voice = try Self.code("M1K3iOSApp/AppCore+Voice.swift")
        let look = try #require(voice.range(of: "if await voiceLook(question) { return }"))
        let send = try #require(voice.range(of: "await chat.send(prepared.question)"))
        #expect(look.lowerBound < send.lowerBound)
    }

    @Test("the camera never outlives what asked for it")
    func theEyeCloses() throws {
        let voice = try Self.code("M1K3iOSApp/AppCore+Voice.swift")
        let exit = try #require(voice.range(of: "func exitVoiceMode()"))
        let close = try #require(voice.range(of: "lookCamera.close()"))
        #expect(exit.lowerBound < close.lowerBound, "leaving voice mode must close the eye")

        let screen = try Self.code("M1K3iOSApp/LookScreen.swift")
        #expect(screen.contains(".onDisappear {\n            core.lookCamera.close()"))

        let camera = try Self.code("M1K3iOSApp/LookCamera.swift")
        #expect(camera.contains("UIApplication.didEnterBackgroundNotification"))

        // A spoken ask with the eye closed is one glance.
        let wiring = try Self.code("M1K3iOSApp/AppCore+Look.swift")
        #expect(wiring.contains("if !eyesOpen { lookCamera.close() }"))
    }

    @Test("the camera holds no file handle and no network: it hands back bytes")
    func theCameraStoresAndSendsNothing() throws {
        let camera = try Self.code("M1K3iOSApp/LookCamera.swift")
        for banned in ["URLSession", "FileManager", "write(to:", "PHPhotoLibrary", "AVCaptureMovieFileOutput"] {
            #expect(!camera.contains(banned), "LookCamera reaches for \(banned)")
        }
    }

    @Test("the iPhone's camera permission text says both jobs and that a frame is kept")
    func thePermissionTextIsTruthful() throws {
        let yml = try Self.source("project.yml")
        let lines = yml.split(separator: "\n").filter { $0.contains("NSCameraUsageDescription:") }
        #expect(lines.count == 2, "expected one camera string each for iOS and visionOS")
        let ios = try #require(lines.first.map(String.init))
        #expect(ios.contains("pairing code"))
        #expect(ios.contains("look at what you point it at when you ask"))
        #expect(ios.contains("saved with that chat"))
        #expect(!ios.contains("only to scan"), "the iPhone camera is no longer pairing-only")
        #expect(!ios.contains("No photos or video are captured or stored"))
    }
}
