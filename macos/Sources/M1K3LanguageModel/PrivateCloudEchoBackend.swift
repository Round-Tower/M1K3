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

#if DEBUG
    import Foundation

    public struct PrivateCloudEchoBackend: PrivateCloudAnswering, Equatable {
        public enum Mode: String, Sendable, CaseIterable {
            case echo, network, rateLimited, unavailable, quota, midAnswer
        }

        public static let environmentKey = "M1K3_PCC_ECHO"

        public let mode: Mode

        public init(mode: Mode) {
            self.mode = mode
        }

        /// The backend a Debug launch asked for, or nil.
        public static func fromEnvironment(_ environment: [String: String]) -> Self? {
            environment[environmentKey].flatMap(Mode.init(rawValue:)).map(Self.init(mode:))
        }

        private static var resetDate: Date {
            Date().addingTimeInterval(3 * 3600)
        }

        public func status() async -> PrivateCloudStatus {
            PrivateCloudStatus(
                available: mode != .unavailable,
                quota: mode == .quota ? .limitReached(resetsAt: Self.resetDate) : .belowLimit
            )
        }

        public func answer(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error> {
            let mode = mode
            return AsyncThrowingStream { continuation in
                switch mode {
                case .network, .rateLimited, .unavailable, .quota:
                    let failure: PrivateCloudFailure = switch mode {
                    case .network: .network
                    case .rateLimited: .rateLimited
                    case .quota: .quotaLimitReached(resetsAt: Self.resetDate)
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
