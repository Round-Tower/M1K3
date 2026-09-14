//
//  PrivateCloudEchoBackendTests.swift
//  M1K3LanguageModelTests
//
//  The DEBUG stand-in for Private Cloud Compute. It exists so the rung's UI —
//  the switch, the control, the consent sheet, the label, the fallback line —
//  can be driven by launch before Apple grants the entitlement. It answers by
//  showing the tester exactly what it received, and can be told to fail each
//  way the real backend can.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.9, Prior: Unknown
//

#if DEBUG
    import Foundation
    @testable import M1K3LanguageModel
    import Testing

    struct PrivateCloudEchoBackendTests {
        private func collect(
            _ stream: AsyncThrowingStream<String, any Error>
        ) async -> (last: String, error: (any Error)?) {
            var last = ""
            do {
                for try await snapshot in stream {
                    last = snapshot
                }
                return (last, nil)
            } catch {
                return (last, error)
            }
        }

        @Test("echo mode answers with exactly what it was sent")
        func echoesTheRequest() async {
            let backend = PrivateCloudEchoBackend(mode: .echo)
            let (last, error) = await collect(backend.answer(instructions: "INSTR", prompt: "the question"))
            #expect(error == nil)
            #expect(last.contains("the question"))
            #expect(last.contains("5 characters of instructions"))
        }

        @Test("each failure mode throws its failure, before any text")
        func failureModes() async {
            let cases: [(PrivateCloudEchoBackend.Mode, PrivateCloudFailure)] = [
                (.network, .network), (.rateLimited, .rateLimited), (.unavailable, .unavailable),
            ]
            for (mode, expected) in cases {
                let stream = PrivateCloudEchoBackend(mode: mode).answer(instructions: "", prompt: "q")
                let (last, error) = await collect(stream)
                #expect(last.isEmpty, "\(mode)")
                #expect(error.map(PrivateCloudError.failure(for:)) == expected, "\(mode)")
            }
        }

        @Test("mid-answer mode sends some text, then drops the connection")
        func midAnswer() async {
            let stream = PrivateCloudEchoBackend(mode: .midAnswer).answer(instructions: "", prompt: "q")
            let (last, error) = await collect(stream)
            #expect(!last.isEmpty)
            #expect(error.map(PrivateCloudError.failure(for:)) == .network)
        }

        @Test("quota mode reports the limit before a send, and fails with the reset date on one")
        func quotaMode() async throws {
            let backend = PrivateCloudEchoBackend(mode: .quota)
            let status = await backend.status()
            guard case .limitReached(resetsAt: .some) = status.quota else {
                Issue.record("expected a reached quota with a reset date, got \(status.quota)")
                return
            }
            let (_, error) = await collect(backend.answer(instructions: "", prompt: "q"))
            let failure = try #require(error.map(PrivateCloudError.failure(for:)))
            guard case .quotaLimitReached(resetsAt: .some) = failure else {
                Issue.record("expected quotaLimitReached with a reset date")
                return
            }
        }

        /// The limit lifts at a fixed moment, so the control's recovery can be
        /// watched by launch (`M1K3_PCC_ECHO_QUOTA_SECONDS=45`).
        @Test("quota mode's limit lifts at its reset; after it, the stand-in answers")
        func quotaLifts() async {
            let resets = Date(timeIntervalSince1970: 1_800_000_000)
            let backend = PrivateCloudEchoBackend(mode: .quota, quotaResetsAt: resets)
            #expect(backend.quota(now: resets.addingTimeInterval(-1)) == .limitReached(resetsAt: resets))
            #expect(backend.quota(now: resets) == .belowLimit)
            let lifted = PrivateCloudEchoBackend(mode: .quota, quotaResetsAt: .distantPast)
            #expect(await lifted.status().quota == .belowLimit)
            let (last, error) = await collect(lifted.answer(instructions: "", prompt: "after the reset"))
            #expect(error == nil)
            #expect(last.contains("after the reset"))
        }

        @Test("M1K3_PCC_ECHO_QUOTA_SECONDS sets when quota mode's limit lifts")
        func quotaSecondsFromEnvironment() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let backend = PrivateCloudEchoBackend.fromEnvironment(
                ["M1K3_PCC_ECHO": "quota", "M1K3_PCC_ECHO_QUOTA_SECONDS": "45"], now: now
            )
            #expect(backend?.quotaResetsAt == now.addingTimeInterval(45))
            #expect(PrivateCloudEchoBackend.fromEnvironment(["M1K3_PCC_ECHO": "quota"], now: now)?.quotaResetsAt
                == now.addingTimeInterval(3 * 3600))
        }

        @Test("the mode comes from M1K3_PCC_ECHO; unset or unknown means no backend")
        func modeFromEnvironment() {
            #expect(PrivateCloudEchoBackend.fromEnvironment([:]) == nil)
            #expect(PrivateCloudEchoBackend.fromEnvironment(["M1K3_PCC_ECHO": "nonsense"]) == nil)
            #expect(PrivateCloudEchoBackend.fromEnvironment(["M1K3_PCC_ECHO": "echo"])?.mode == .echo)
            #expect(PrivateCloudEchoBackend.fromEnvironment(["M1K3_PCC_ECHO": "network"])?.mode == .network)
        }
    }
#endif
