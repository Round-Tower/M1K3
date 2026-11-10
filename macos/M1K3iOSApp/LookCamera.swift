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
//  The camera closes itself when the app leaves the foreground or iOS takes the
//  camera away, so the green dot never outlives the screen that asked for it.
//  WHEN it is on is M1K3Chat/LookCameraLifecycle, where `swift test` holds the
//  races (a close during the permission ask, a close during the start).
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
//  Review: Kev + claude-fable-5.2, 2026-11-09 (review fold, before the first
//  push) — the on/off rules moved to `LookCameraLifecycle` and were fixed there
//  (the camera could stay on after a close during the permission ask); the
//  observers register at init and now cover interruptions and runtime errors;
//  a buffer older than a second is refused, forced or not. Confidence 0.7: the
//  rules are tested, the AVFoundation notifications are untried on a phone.
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
    typealias State = LookCameraLifecycle.State

    @ObservationIgnored private let worker: LookCaptureWorker
    /// The on/off rules (M1K3Chat, held by `swift test`); this type is the capture around them.
    @ObservationIgnored private let lifecycle: LookCameraLifecycle
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    var state: State {
        lifecycle.state
    }

    var isOpen: Bool {
        lifecycle.isOpen
    }

    /// Open, or opening: what a toggle reads.
    var isOn: Bool {
        lifecycle.isOn
    }

    /// False on the Simulator and on visionOS: the eye is not offered there.
    static var deviceHasCamera: Bool {
        LookCaptureWorker.deviceHasCamera
    }

    init() {
        let worker = LookCaptureWorker()
        self.worker = worker
        lifecycle = LookCameraLifecycle(
            hasCamera: { LookCaptureWorker.deviceHasCamera },
            access: { await LookCaptureWorker.access() },
            start: { await worker.start() },
            stop: { worker.stop() }
        )
        closeWhenTheCameraIsNotOurs()
    }

    /// Turn the camera on, asking for permission the first time. True once
    /// frames are flowing. Two callers at once share one start.
    func open() async -> Bool {
        await lifecycle.open()
    }

    func close() {
        lifecycle.close()
    }

    /// One upright JPEG of what the camera sees now, or nil when it is closed
    /// or its newest picture is stale. A camera that has only just opened is
    /// given a moment to settle first.
    func frame() async -> Data? {
        guard isOpen else { return nil }
        let deadline = ContinuousClock.now + LookFrame.settleWait
        while ContinuousClock.now < deadline {
            if let jpeg = await worker.jpeg(force: false) { return isOpen ? jpeg : nil }
            try? await Task.sleep(for: .milliseconds(40))
            guard isOpen else { return nil }
        }
        let jpeg = await worker.jpeg(force: true)
        return isOpen ? jpeg : nil
    }

    /// Registered once, at init, so no open can come before them: the camera
    /// closes when the app leaves the foreground, and when iOS takes the
    /// camera away or the session fails (a call, another app's camera, a
    /// media-services reset). A closed eye is honest; a frozen one is not.
    private func closeWhenTheCameraIsNotOurs() {
        #if os(iOS)
            let center = NotificationCenter.default
            let session = worker.session
            let reasons: [(Notification.Name, AnyObject?)] = [
                (UIApplication.didEnterBackgroundNotification, nil),
                (AVCaptureSession.wasInterruptedNotification, session),
                (AVCaptureSession.runtimeErrorNotification, session),
            ]
            observers = reasons.map { name, object in
                center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.close() }
                }
            }
        #endif
    }
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
        private var latestAt: ContinuousClock.Instant?
        private var framesSeen = 0
        private var rotation: AVCaptureDevice.RotationCoordinator?

        /// Read once: device discovery is not free, and SwiftUI bodies ask.
        static let deviceHasCamera = AVCaptureDevice.default(for: .video) != nil

        /// Ask FIRST, then build the session (the pairing scanner's order).
        static func access() async -> LookCameraLifecycle.Access {
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
                forgetFrames()
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
                // The invariant behind `@unchecked Sendable`: the delegate queue IS this worker's queue, so
                // every read and write of its state, the frame callback included, happens on that one queue.
                output.setSampleBufferDelegate(self, queue: queue)
                rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                configured = true
            }
            forgetFrames()
            if !session.isRunning { session.startRunning() }
            return session.isRunning
        }

        private func forgetFrames() {
            latest = nil
            latestAt = nil
            framesSeen = 0
        }

        private func renderOnQueue(force: Bool) -> Data? {
            // Never the past: a session that stalled (an interruption, a
            // stop) keeps its last buffer, and even a forced read refuses it.
            guard let buffer = latest, let latestAt, LookFrame.fresh(age: ContinuousClock.now - latestAt),
                  force || LookFrame.settled(framesSeen: framesSeen)
            else { return nil }
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
            latestAt = .now
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

        static func access() async -> LookCameraLifecycle.Access {
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
