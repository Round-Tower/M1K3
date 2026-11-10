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
//  Review: Kev + claude-fable-5.2, 2026-11-09 (review fold) — the close pins
//  were too loose to mean anything (any `lookCamera.close()` after the exit's
//  signature passed): they now read the BODY of the function they pin, the
//  observers are pinned to `init`, whitespace no longer decides a pass, and a
//  new pin lists every `ImageLooking` conformer in the repo, so a provider
//  that gains eyes (Brain at Home, Private Cloud) fails here by name.
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

    /// Source code with every run of whitespace collapsed to one space, so a
    /// reformat cannot pass or fail a pin.
    private static func flat(_ relative: String) throws -> String {
        try flatten(code(relative))
    }

    private static func flatten(_ text: some StringProtocol) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The body of the first declaration that starts with `signature`, by
    /// brace matching from its opening brace.
    private static func body(of signature: String, in code: String) throws -> String {
        let start = try #require(code.range(of: signature), "\(signature) is gone")
        let open = try #require(code[start.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var index = open
        while index < code.endIndex {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return String(code[open ... index]) }
            }
            index = code.index(after: index)
        }
        Issue.record("\(signature) never closes")
        return ""
    }

    private static func swiftFiles(under relative: String) throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test("a frame is asked of the on-device slot through chat.look, never through a send")
    func theFrameTakesTheLeanRoute() throws {
        let wiring = try Self.code("M1K3iOSApp/AppCore+Look.swift")
        #expect(wiring.contains("chat.look(question, frame: frame, looker: looker)"))
        #expect(!wiring.contains("chat.send("), "a look must not become a send: a send can pick a tool")
        #expect(!wiring.contains("homeBrain"), "the look wiring must not reach for Brain at Home")
        // A look with no frame says so as a look; it never falls through.
        #expect(wiring.contains("chat.lookMissed(question, saying:"))
        let voiceLook = try Self.body(of: "func voiceLook(", in: wiring)
        let matched = try #require(voiceLook.range(of: "LookIntent.voiceTurnLooks("))
        let after = voiceLook[matched.upperBound...]
        #expect(
            after.components(separatedBy: "return false").count == 2,
            "once the words asked for the camera the turn is spent: only the matcher's own guard may hand it back"
        )
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
        // Leaving voice mode closes the eye, inside the exit itself.
        let voice = try Self.code("M1K3iOSApp/AppCore+Voice.swift")
        let exit = try Self.body(of: "func exitVoiceMode()", in: voice)
        #expect(exit.contains("lookCamera.close()"), "leaving voice mode must close the eye")

        // The Look screen closes it on the way out, and opens it from ONE
        // task tied to the scene phase (cancelled with the screen).
        let screen = try Self.flat("M1K3iOSApp/LookScreen.swift")
        #expect(screen.contains(".onDisappear { core.lookCamera.close() }"))
        #expect(screen.contains(".task(id: scenePhase) {"))
        #expect(!screen.contains(".onChange(of: scenePhase)"), "an unowned reopen can outlive the screen")

        // The camera closes itself when the app leaves the front or iOS takes
        // the camera away, and it starts listening the moment it exists.
        let camera = try Self.code("M1K3iOSApp/LookCamera.swift")
        let cameraInit = try Self.body(of: "init()", in: camera)
        #expect(cameraInit.contains("closeWhenTheCameraIsNotOurs()"))
        let listening = try Self.body(of: "func closeWhenTheCameraIsNotOurs()", in: camera)
        for reason in [
            "UIApplication.didEnterBackgroundNotification",
            "AVCaptureSession.wasInterruptedNotification",
            "AVCaptureSession.runtimeErrorNotification",
        ] {
            #expect(listening.contains(reason), "the camera does not close on \(reason)")
        }
        #expect(listening.contains("self?.close()"))

        // A spoken ask with the eye closed is one glance; a look from the
        // screen never opens a camera; neither does a turn after voice mode.
        let wiring = try Self.code("M1K3iOSApp/AppCore+Look.swift")
        let voiceLook = try Self.body(of: "func voiceLook(", in: wiring)
        #expect(voiceLook.contains("if !eyeWasOn { lookCamera.close() }"))
        let guardLine = try #require(voiceLook.range(of: "guard voiceLoop != nil else { return false }"))
        let opens = try #require(voiceLook.range(of: "lookCamera.open()"))
        #expect(guardLine.lowerBound < opens.lowerBound, "a turn that lands after voice mode opens no camera")
        let look = try Self.body(of: "func look(", in: wiring)
        #expect(!look.contains("lookCamera.open()"), "the Look screen owns its camera: a look never opens one")
        let stored = try Self.body(of: "func storedFrame()", in: wiring)
        #expect(!stored.contains("lookCamera.open()"))
    }

    @Test("only the on-device brains and their two façades have eyes")
    func theConformerSetIsClosed() throws {
        // The egress rule rests on WHO conforms to `ImageLooking`: a frame
        // handed to the seam reaches only these. A new conformer is a privacy
        // decision, so it fails here by name until this list is edited on purpose.
        var conformers: Set<String> = []
        for directory in ["Sources", "M1K3App", "M1K3iOSApp"] {
            for file in try Self.swiftFiles(under: directory) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//"), !trimmed.contains("protocol "),
                          let colon = trimmed.firstIndex(of: ":"),
                          let brace = trimmed.lastIndex(of: "{"), colon < brace
                    else { continue }
                    let inherited = trimmed[trimmed.index(after: colon) ..< brace]
                        .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                    guard inherited.contains("ImageLooking") else { continue }
                    let declared = trimmed[..<colon].split(separator: " ")
                    guard let keyword = declared.first(where: {
                        ["extension", "class", "struct", "actor", "enum"].contains(String($0))
                    }), let name = declared.last, name != keyword else { continue }
                    conformers.insert(String(name))
                }
            }
        }
        #expect(conformers == [
            "AppleFoundationModelsProvider", // Mini: Apple's on-device model
            "MLXBrainProvider", // Lil and Big: MLX on this device
            "SwappableInferenceProvider", // the package façade: forwards to the active one
            "RuntimeInferenceProvider", // the Mac app's façade: the same forward
        ])
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
