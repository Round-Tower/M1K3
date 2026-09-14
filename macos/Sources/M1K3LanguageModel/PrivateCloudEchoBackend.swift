//
//  PrivateCloudEchoBackend.swift
//  M1K3LanguageModel
//
//  A DEBUG-only stand-in for Private Cloud Compute (ADR 0006), so the rung's
//  UI can be driven by launch before Apple grants the entitlement. It never
//  leaves the process: it answers by showing the tester exactly what it was
//  sent, or fails the way the real backend can. `M1K3_PCC_ECHO=<mode>` in a
//  Debug build's environment turns it on; Release builds don't contain it.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.9 (pure; its only job
//  is to be honest about being a stand-in). Prior: Unknown
//
//  Review: Kev + claude-opus-5, 2026-09-14 (later) — `quota` mode's limit lifts
//  at a fixed moment (`M1K3_PCC_ECHO_QUOTA_SECONDS`, default 3 hours). Its reset
//  used to move 3 hours ahead on every read, so a control's recovery could
//  never be watched. Confidence 0.9.
//

#if DEBUG
    import Foundation

    public struct PrivateCloudEchoBackend: PrivateCloudAnswering, Equatable {
        public enum Mode: String, Sendable, CaseIterable {
            case echo, network, rateLimited, unavailable, quota, midAnswer
        }

        public static let environmentKey = "M1K3_PCC_ECHO"
        /// How long `quota` mode's limit lasts from launch (default 3 hours).
        public static let quotaSecondsKey = "M1K3_PCC_ECHO_QUOTA_SECONDS"

        public let mode: Mode
        /// When `quota` mode's limit lifts: a fixed moment, so the control's
        /// recovery can be watched by launch.
        public let quotaResetsAt: Date

        public init(mode: Mode, quotaResetsAt: Date = Date().addingTimeInterval(3 * 3600)) {
            self.mode = mode
            self.quotaResetsAt = quotaResetsAt
        }

        /// The backend a Debug launch asked for, or nil.
        public static func fromEnvironment(_ environment: [String: String], now: Date = Date()) -> Self? {
            guard let mode = environment[environmentKey].flatMap(Mode.init(rawValue:)) else { return nil }
            let seconds = environment[quotaSecondsKey].flatMap(TimeInterval.init) ?? 3 * 3600
            return Self(mode: mode, quotaResetsAt: now.addingTimeInterval(seconds))
        }

        /// The quota as of `now`: reached until the reset, then clear.
        func quota(now: Date) -> PrivateCloudQuota {
            mode == .quota && now < quotaResetsAt ? .limitReached(resetsAt: quotaResetsAt) : .belowLimit
        }

        public func status() async -> PrivateCloudStatus {
            PrivateCloudStatus(available: mode != .unavailable, quota: quota(now: Date()))
        }

        public func answer(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error> {
            // Past its reset, quota mode answers like echo.
            let mode: Mode = self.mode == .quota && quota(now: Date()) == .belowLimit ? .echo : self.mode
            let resetsAt = quotaResetsAt
            return AsyncThrowingStream { continuation in
                switch mode {
                case .network, .rateLimited, .unavailable, .quota:
                    let failure: PrivateCloudFailure = switch mode {
                    case .network: .network
                    case .rateLimited: .rateLimited
                    case .quota: .quotaLimitReached(resetsAt: resetsAt)
                    default: .unavailable
                    }
                    continuation.finish(throwing: PrivateCloudError(failure))
                case .midAnswer:
                    continuation.yield("(Debug stand-in for Private Cloud Compute) This answer will stop partway")
                    continuation.finish(throwing: PrivateCloudError(.network))
                case .echo:
                    let text = """
                    (Debug stand-in for Private Cloud Compute — nothing left this Mac.) I received \
                    \(instructions.count) characters of instructions and this prompt:

                    \(prompt)
                    """
                    continuation.yield(String(text.prefix(40)))
                    continuation.yield(text)
                    continuation.finish()
                }
            }
        }
    }
#endif
