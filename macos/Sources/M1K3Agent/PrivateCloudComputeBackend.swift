//
//  PrivateCloudComputeBackend.swift
//  M1K3Agent
//
//  ADR 0006's real adapter: wraps Apple's `PrivateCloudComputeLanguageModel`
//  behind `PrivateCloudAnswering` (M1K3LanguageModel). Compile-gated on the
//  FoundationModels SDK (Xcode 27+); runtime-gated on @available(macOS 27, *).
//
//  Everything above `PrivateCloudAnswering` (the rung's pure policy, the consent
//  sheet, ChatSession's send path) builds and tests on any toolchain against
//  fakes — this file is the one place that touches the real API, and it never
//  runs unless the product decides PCC is allowed for this turn.
//
//  No tools, ever (ADR 0006's constraint list): a PCC turn gets exactly
//  `instructions` + `prompt`, nothing M1K3-side attached. A backend that wanted
//  to call tools would have to widen `PrivateCloudAnswering`'s signature, in
//  review — that seam is deliberately narrow.
//
//  `PrivateCloudBackends.live()` is the ALWAYS-compiled half: it exists in every
//  build (stable 26.x CI included) and returns nil unless THREE things are true
//  at once — M1K3_FM27 compiled in, the OS is 27+, and this process holds the
//  `com.apple.developer.private-cloud-compute` entitlement. Absence is silence
//  (PrivateCloudRung.swift's own words): a shipping 1.0/1.1 build with no
//  entitlement is byte-behaviourally what it was before this file existed.
//
//  Signed: Kev + claude-sonnet-5 (apple-specialist agent; directed + reviewed by
//  claude-opus-5), 2026-09-14, Confidence 0.8 (the API shapes are
//  read from the 27A5194q swiftinterface and the file compiles against it under
//  M1K3_FM27; a real PCC generation is verify-owed until Apple grants the
//  entitlement — this Mac reads `available` today but every send 1046s
//  unentitled, per ADR 0006's own context section). Prior: Unknown
//  Review: Kev + claude-opus-4-6, 2026-09-16 — M1K3_FM27 env-var gate removed;
//  now #if canImport(FoundationModels). Confidence now 0.85.
//

import Foundation
import M1K3LanguageModel

#if os(macOS)
    import Security
#endif

#if canImport(FoundationModels)
    import FoundationModels
    import M1K3LogCore

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
    public struct PrivateCloudComputeBackend: PrivateCloudAnswering {
        /// Shares the AFM category — both are Apple Foundation Models sessions;
        /// splitting a "pcc" category off for one adapter file isn't worth a new
        /// catalogue entry the SubsystemGuard test would then have to carry forever.
        private static let log = M1K3Log.logger(.afm)

        /// Cap on logged error text — same bound and same reasoning as
        /// AppleFoundationModelsProvider's `errorPreviewCap`: long enough to
        /// recognise a new error shape, short enough that a chatty payload can't
        /// dump conversation-adjacent text into the log.
        private static let errorPreviewCap = 200

        private let model: PrivateCloudComputeLanguageModel

        public init(model: PrivateCloudComputeLanguageModel = PrivateCloudComputeLanguageModel()) {
            self.model = model
        }

        public func status() async -> PrivateCloudStatus {
            let available = switch model.availability {
            case .available: true
            case .unavailable: false
            }
            return PrivateCloudStatus(available: available, quota: Self.quota(from: model.quotaUsage))
        }

        /// A fresh session per call, on purpose (header): PCC turns are never
        /// KV-reused across the conversation the way the local MLX tiers are — the
        /// grounding attached to THIS turn is exactly what the consent sheet showed,
        /// and nothing else. No tools (`tools: []`), per ADR 0006.
        public func answer(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error> {
            AsyncThrowingStream { continuation in
                let session = LanguageModelSession(model: model, tools: [], instructions: instructions)
                let task = Task {
                    do {
                        for try await snapshot in session.streamResponse(to: prompt) {
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        // Cancellation finishes the stream quietly — a user-cancelled
                        // PCC turn is not a failure the rung needs to explain (ADR
                        // 0006's fallback notices are for PCC's OWN failures).
                        continuation.finish()
                    } catch {
                        let described = String(describing: error)
                        let preview = LogPreview.preview(described, max: Self.errorPreviewCap)
                        Self.log.error("pcc failed: \(preview, privacy: .public)")
                        continuation.finish(throwing: PrivateCloudError(Self.failure(for: error)))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        static func quota(from usage: PrivateCloudComputeLanguageModel.QuotaUsage) -> PrivateCloudQuota {
            switch usage.status {
            case .belowLimit:
                .belowLimit
            case .limitReached:
                // `resetDate` lives on `QuotaUsage` itself, not the nested
                // `LimitReached` payload (the swiftinterface carries no fields there).
                .limitReached(resetsAt: usage.resetDate)
            @unknown default:
                // `Status` isn't `@frozen` (unlike `Availability`) — a future OS could
                // add a case. `.unknown` is exactly the "not a reason to refuse, the
                // send finds out" quota state PrivateCloudQuota's own doc comment names.
                .unknown
            }
        }

        /// Maps whatever the session throws onto the rung's own failure vocabulary
        /// (PrivateCloudRung.swift). Three shapes are live on the 27A5194q SDK:
        /// PCC's own `Error` (network/quota/service), the unified
        /// `LanguageModelError.rateLimited`, and the pre-27 deprecated
        /// `LanguageModelSession.GenerationError.rateLimited` some paths may still
        /// surface. Anything else is `.other` — `PrivateCloudError.failure(for:)`
        /// already gives every OTHER kind of thrown error that same fallback, so
        /// this only needs to special-case the ones the rung explains differently.
        static func failure(for error: any Error) -> PrivateCloudFailure {
            if let pcc = error as? PrivateCloudComputeLanguageModel.Error {
                return switch pcc {
                case .networkFailure: .network
                case let .quotaLimitReached(reached): .quotaLimitReached(resetsAt: reached.resetDate)
                case .serviceUnavailable: .unavailable
                // `Error` isn't `@frozen` either — an unrecognised PCC failure still
                // needs a fallback notice; `.other` is that fallback everywhere else.
                @unknown default: .other
                }
            }
            if case .rateLimited = error as? LanguageModelError {
                return .rateLimited
            }
            if case .rateLimited = error as? LanguageModelSession.GenerationError {
                return .rateLimited
            }
            return .other
        }
    }
#endif

/// The always-compiled half — exists on every toolchain so the composition root
/// has one call to make regardless of SDK availability.
public enum PrivateCloudBackends {
    /// The entitlement Apple granted 2026-09-14 (`docs/PCC_ENTITLEMENT_REQUEST.md`,
    /// ADR 0006).
    static let entitlementKey = "com.apple.developer.private-cloud-compute"

    /// A PCC backend for THIS process, or nil. Never partial: `PrivateCloudState`
    /// (PrivateCloudRung.swift) reads `backendPresent` from whether this returns
    /// non-nil, so a backend that could exist but can't actually generate must
    /// come back nil here, not a backend that would 1046 on first use.
    public static func live() -> (any PrivateCloudAnswering)? {
        #if canImport(FoundationModels)
            #if os(macOS)
                guard #available(macOS 27.0, *) else { return nil }
                guard processHasEntitlement() else { return nil }
                return PrivateCloudComputeBackend()
            #else
                return nil
            #endif
        #else
            return nil
        #endif
    }

    /// Whether THIS process (not the app in general — a `swift test` binary, a
    /// debug run, the shipped app, each answer independently) holds the PCC
    /// entitlement. Split out from `live()` so it's testable without a macOS 27
    /// runtime: the SecTask read works on any OS version, and a plain test
    /// process should always read false.
    public static func processHasEntitlement() -> Bool {
        #if os(macOS)
            guard let task = SecTaskCreateFromSelf(nil) else { return false }
            var error: Unmanaged<CFError>?
            // A CFError out-parameter comes back +1 (Create rule); release it on
            // every path, including the nil return every unentitled process takes.
            defer { error?.release() }
            guard let value = SecTaskCopyValueForEntitlement(task, entitlementKey as CFString, &error) else {
                return false
            }
            // CFBoolean bridges to either Bool or NSNumber depending on the call
            // site's static type inference; check both rather than assume one.
            if let boolValue = value as? Bool { return boolValue }
            if let number = value as? NSNumber { return number.boolValue }
            return false
        #else
            return false
        #endif
    }
}
