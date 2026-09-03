//
//  BrainPairingScreen.swift
//  M1K3iOS / M1K3visionOS
//
//  The Brain at Home pairing ceremony, device side: scan the QR the Mac
//  shows (in-app scanner only — spec N1), or paste the m1k3-pair:// link
//  (the Simulator/visionOS path; visionOS apps get no camera feed, and the
//  Simulator has no camera). States mirror the ceremony: scan → contacting →
//  "Approve on your Mac…" → paired / a plain-words failure.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.8 (flow states
//  drive the TDD'd ceremony; the scanner + live pairing feel are the Phase C
//  hardware verify). Prior: Unknown.
//
//  Review: Kev + claude-fable-5.1, 2026-09-03 — cognitive-load cut: shorter paired/expiry copy.
//

#if os(iOS)
    import AVFoundation
#endif
import M1K3BrainLink
import SwiftUI

struct BrainPairingScreen: View {
    @Environment(AppCore.self) private var core
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case scanning
        case working(String)
        case failed(String)
        case done
    }

    @State private var phase: Phase = .scanning
    @State private var pastedLink = ""

    var body: some View {
        Form {
            switch phase {
            case .scanning:
                scanSections
            case let .working(message):
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(message)
                    }
                }
            case let .failed(message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Try Again") {
                        phase = .scanning
                    }
                }
            case .done:
                Section {
                    Label(
                        "Paired with \(core.homeBrain?.name ?? "your Mac"). Choose Home under Brain to use it.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Pair with your Mac")
    }

    @ViewBuilder private var scanSections: some View {
        Section {
            Text(
                "On the Mac: M1K3 → Settings → Privacy → Brain at Home → Pair a Device. "
                    + "Then scan the code it shows."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        #if os(iOS)
            if QRScannerView.cameraLikelyAvailable {
                Section {
                    QRScannerView { code in
                        begin(code)
                    }
                    .frame(height: 280)
                    .listRowInsets(EdgeInsets())
                }
            }
        #endif
        Section {
            TextField("m1k3-pair://…", text: $pastedLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
            Button("Pair with Pasted Link") {
                begin(pastedLink)
            }
            .disabled(pastedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("No camera? Paste the link")
        } footer: {
            Text("Codes expire after about a minute.")
        }
    }

    private func begin(_ code: String) {
        guard case .scanning = phase else { return } // scanner fires repeatedly
        phase = .working("Contacting your Mac…")
        Task {
            let failure = await core.pairWithMac(
                payloadString: code,
                onAwaitingApproval: { phase = .working("Now click Approve on your Mac…") }
            )
            phase = failure.map { .failed($0) } ?? .done
        }
    }
}

#if os(iOS)

    /// In-app QR scanner (spec N1: never the Camera app / a scanning
    /// extension — the pairing secret must not transit anything else).
    /// AVCaptureSession + metadata output; the session lives on a background
    /// queue and dies with the view.
    struct QRScannerView: UIViewRepresentable {
        let onCode: @MainActor (String) -> Void

        /// The Simulator has no camera device; hide the viewfinder there so
        /// the paste path leads.
        static var cameraLikelyAvailable: Bool {
            AVCaptureDevice.default(for: .video) != nil
        }

        func makeUIView(context: Context) -> ScannerPreviewView {
            let view = ScannerPreviewView()
            context.coordinator.start(in: view)
            return view
        }

        func updateUIView(_: ScannerPreviewView, context _: Context) {}

        static func dismantleUIView(_: ScannerPreviewView, coordinator: Coordinator) {
            coordinator.stop()
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(onCode: onCode)
        }

        final class ScannerPreviewView: UIView {
            override class var layerClass: AnyClass {
                AVCaptureVideoPreviewLayer.self
            }

            var previewLayer: AVCaptureVideoPreviewLayer {
                layer as! AVCaptureVideoPreviewLayer
            }
        }

        final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
            private let onCode: @MainActor (String) -> Void
            private let session = AVCaptureSession()
            private let queue = DispatchQueue(label: "app.m1k3.brainlink.scanner")

            init(onCode: @escaping @MainActor (String) -> Void) {
                self.onCode = onCode
            }

            func start(in view: ScannerPreviewView) {
                view.previewLayer.session = session
                view.previewLayer.videoGravity = .resizeAspectFill
                queue.async { [session, self] in
                    guard session.inputs.isEmpty,
                          let device = AVCaptureDevice.default(for: .video),
                          let input = try? AVCaptureDeviceInput(device: device),
                          session.canAddInput(input)
                    else { return }
                    session.addInput(input)
                    let output = AVCaptureMetadataOutput()
                    guard session.canAddOutput(output) else { return }
                    session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: queue)
                    guard output.availableMetadataObjectTypes.contains(.qr) else { return }
                    output.metadataObjectTypes = [.qr]
                    session.startRunning()
                }
            }

            func stop() {
                queue.async { [session] in
                    if session.isRunning { session.stopRunning() }
                }
            }

            func metadataOutput(
                _: AVCaptureMetadataOutput,
                didOutput objects: [AVMetadataObject],
                from _: AVCaptureConnection
            ) {
                guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                      code.hasPrefix(PairingPayload.scheme)
                else { return }
                Task { @MainActor [onCode] in
                    onCode(code)
                }
            }
        }
    }

#endif
