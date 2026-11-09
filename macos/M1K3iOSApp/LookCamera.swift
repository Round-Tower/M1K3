//
//  LookCamera.swift
//  M1K3iOS / M1K3visionOS
//
//  M1K3's eyes on the phone (#768): the camera, on only while the Look screen
//  or voice mode's eye is open, and one upright frame handed back when a look
//  asks for it. The frame is the newest buffer off a video data output, so
//  there is no shutter sound and no photo pipeline; it is scaled to about
//  1,024 px (the size the spike measured) and returned as JPEG bytes. Nothing
//  here stores or sends anything: the caller (AppCore+Look) puts the frame in
//  the attachment store and hands it to the on-device brain.
//
//  The camera closes itself when the app leaves the foreground, so the green
//  dot never outlives the screen that asked for it.
//
//  Upright is by gravity (`RotationCoordinator`), not by the interface: a label
//  read with the phone turned sideways still reaches the brain the right way up.
//
//  visionOS has no camera for an app like this one: there the type is an inert
//  stub that never opens, so the shared shell needs no platform checks.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.6, Prior: none (new file)
//  Context: Kev, 2026-11-09: "Let's implement the vision on this research pal,
//  and make it easily accessible via chat, and voice interfaces".
//  Open: capture is device work `swift test` cannot reach; the pure numbers
//  (scale, orientation, settle) are in M1K3Chat/LookFrame. The settle count is
//  a guess, and the heat and battery cost of an open eye is unmeasured (#768).
//

import Foundation
import M1K3Chat
import Observation
import SwiftUI
#if os(iOS)
    import AVFoundation
    import CoreImage
    import UIKit
#endif

@MainActor
@Observable
final class LookCamera {
    enum State: Equatable {
        case closed, opening, open, denied, restricted, unavailable
    }

    private(set) var state: State = .closed

    var isOpen: Bool {
        state == .open
    }

    @ObservationIgnored private let worker = LookCaptureWorker()
    @ObservationIgnored private var opening: Task<Bool, Never>?
    /// Bumped by every close, so a start that was overtaken by one stays closed.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var backgroundObserver: (any NSObjectProtocol)?

    /// False on the Simulator and on visionOS: the eye is not offered there.
    static var deviceHasCamera: Bool {
        LookCaptureWorker.deviceHasCamera
    }

    /// Turn the camera on, asking for permission the first time. True once
    /// frames are flowing. Two callers at once share one start.
    func open() async -> Bool {
        if state == .open { return true }
        if let opening { return await opening.value }
        let task = Task { await self.start() }
        opening = task
        let result = await task.value
        opening = nil
        return result
    }

    func close() {
        generation += 1
        worker.stop()
        if state == .open || state == .opening { state = .closed }
    }

    /// One upright JPEG of what the camera sees now, or nil when it is closed.
    /// A camera that has only just opened is given a moment to settle first.
    func frame() async -> Data? {
        guard state == .open else { return nil }
        let deadline = ContinuousClock.now + LookFrame.settleWait
        while ContinuousClock.now < deadline {
            if let jpeg = await worker.jpeg(force: false) { return jpeg }
            try? await Task.sleep(for: .milliseconds(40))
            guard state == .open else { return nil }
        }
        return await worker.jpeg(force: true)
    }

    private func start() async -> Bool {
        guard Self.deviceHasCamera else {
            state = .unavailable
            return false
        }
        state = .opening
        switch await LookCaptureWorker.access() {
        case .granted: break
        case .denied:
            state = .denied
            return false
        case .restricted:
            state = .restricted
            return false
        }
        let mine = generation
        let running = await worker.start()
        guard mine == generation else { return false } // a close won the race; it already stopped the worker
        state = running ? .open : .unavailable
        if running { closeWhenBackgrounded() }
        return running
    }

    private func closeWhenBackgrounded() {
        #if os(iOS)
            guard backgroundObserver == nil else { return }
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        #endif
    }
}

enum LookCameraAccess {
    case granted, denied, restricted
}

#if os(iOS)

    extension LookCamera {
        /// For the preview layer only.
        var session: AVCaptureSession {
            worker.session
        }
    }

    /// The capture session and its newest frame. `@unchecked` because the
    /// mutable state (the buffer, the counters) is confined to `queue` by hand:
    /// AVFoundation's types are not Sendable, and the delegate arrives there.
    final class LookCaptureWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "app.m1k3.look.camera")
        private let context = CIContext()
        private var configured = false
        private var latest: CVPixelBuffer?
        private var framesSeen = 0
        private var rotation: AVCaptureDevice.RotationCoordinator?

        static var deviceHasCamera: Bool {
            AVCaptureDevice.default(for: .video) != nil
        }

        /// Ask FIRST, then build the session (the pairing scanner's order).
        static func access() async -> LookCameraAccess {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: .granted
            case .notDetermined: await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
            case .restricted: .restricted
            default: .denied
            }
        }

        func start() async -> Bool {
            await withCheckedContinuation { done in
                queue.async { [self] in done.resume(returning: startOnQueue()) }
            }
        }

        func stop() {
            queue.async { [self] in
                if session.isRunning { session.stopRunning() }
                latest = nil
                framesSeen = 0
            }
        }

        /// The newest frame as an upright JPEG. Nil until the picture has
        /// settled, unless `force` takes whatever there is.
        func jpeg(force: Bool) async -> Data? {
            await withCheckedContinuation { done in
                queue.async { [self] in done.resume(returning: renderOnQueue(force: force)) }
            }
        }

        private func startOnQueue() -> Bool {
            if !configured {
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device)
                else { return false }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                guard session.canAddInput(input), session.canAddOutput(output) else { return false }
                // 720p is already past the 1,024 px a look keeps; more is heat for nothing.
                if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                session.addInput(input)
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: queue)
                rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                configured = true
            }
            latest = nil
            framesSeen = 0
            if !session.isRunning { session.startRunning() }
            return session.isRunning
        }

        private func renderOnQueue(force: Bool) -> Data? {
            guard let buffer = latest, force || LookFrame.settled(framesSeen: framesSeen) else { return nil }
            let angle = Double(rotation?.videoRotationAngleForHorizonLevelCapture ?? 90)
            let orientation = CGImagePropertyOrientation(
                rawValue: LookFrame.exifOrientation(forRotationAngle: angle)
            ) ?? .right
            var image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
            let scale = LookFrame.scale(width: image.extent.width, height: image.extent.height)
            if scale < 1 {
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            return context.jpegRepresentation(
                of: image,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
            )
        }

        func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            latest = buffer
            framesSeen += 1
        }
    }

    /// What the camera sees, live: the pairing scanner's preview view on the
    /// look's session.
    struct LookPreview: UIViewRepresentable {
        let camera: LookCamera

        func makeUIView(context _: Context) -> QRScannerView.ScannerPreviewView {
            let view = QRScannerView.ScannerPreviewView()
            view.previewLayer.session = camera.session
            view.previewLayer.videoGravity = .resizeAspectFill
            return view
        }

        func updateUIView(_: QRScannerView.ScannerPreviewView, context _: Context) {}
    }

#else

    final class LookCaptureWorker: Sendable {
        static let deviceHasCamera = false

        static func access() async -> LookCameraAccess {
            .denied
        }

        func start() async -> Bool {
            false
        }

        func stop() {}

        func jpeg(force _: Bool) async -> Data? {
            nil
        }
    }

    struct LookPreview: View {
        let camera: LookCamera

        var body: some View {
            Color.black
        }
    }

#endif
