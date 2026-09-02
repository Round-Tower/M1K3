//
//  CurrentLocationToolTests.swift
//  M1K3AgentToolsTests
//
//  The location sense (context-tools charter, Phase 2): grid-cell coarse
//  rounding (the audit's "grid cells, not place names" fold; coarse by
//  default, precise opt-up per Kev's 2026-09-01 ruling) + the tool over a
//  fake provider. `.localSensitive` by charter — pinned here.
//
//  Signed: Kev + claude-sonnet-5, 2026-09-01, Confidence 0.85 (red-first;
//  the CoreLocation adapter is app-side, verify-by-launch). Prior: none
//  (new file).
//

import Foundation
@testable import M1K3AgentTools
import Testing

struct CoarseLocationTests {
    @Test("coarse snaps to a 0.1° grid cell and says so")
    func coarseSnap() {
        let snapshot = LocationSnapshot(latitude: 51.9472, longitude: -7.7231)
        #expect(CoarseLocation.describe(snapshot, precision: .coarse)
            == "About 51.9°N, 7.7°W (coarse — a ~10 km grid cell).")
    }

    @Test("coarse rounds to the NEAREST cell, both hemispheres")
    func nearestCell() {
        let snapshot = LocationSnapshot(latitude: -33.8688, longitude: 151.2093)
        #expect(CoarseLocation.describe(snapshot, precision: .coarse)
            == "About 33.9°S, 151.2°E (coarse — a ~10 km grid cell).")
    }

    @Test("precise keeps four decimals and is labelled as the opt-up")
    func preciseOptUp() {
        let snapshot = LocationSnapshot(latitude: 51.9472, longitude: -7.7231)
        #expect(CoarseLocation.describe(snapshot, precision: .precise)
            == "51.9472°N, 7.7231°W (precise).")
    }
}

struct CurrentLocationToolTests {
    private struct FakeProvider: LocationProviding {
        let snapshot: LocationSnapshot
        func currentLocation() async throws -> LocationSnapshot {
            snapshot
        }
    }

    @Test("coarse is the default output")
    func coarseDefault() async throws {
        let tool = CurrentLocationTool(
            provider: FakeProvider(snapshot: LocationSnapshot(latitude: 51.9472, longitude: -7.7231)),
            precision: .coarse
        )
        let result = try await tool.execute(input: [:])
        #expect(result.output == "About 51.9°N, 7.7°W (coarse — a ~10 km grid cell).")
    }

    @Test("precise opt-up flows through")
    func preciseFlows() async throws {
        let tool = CurrentLocationTool(
            provider: FakeProvider(snapshot: LocationSnapshot(latitude: 51.9472, longitude: -7.7231)),
            precision: .precise
        )
        let result = try await tool.execute(input: [:])
        #expect(result.output == "51.9472°N, 7.7231°W (precise).")
    }

    @Test("a provider failure lands as a recoverable Error: observation")
    func deniedIsRecoverable() async throws {
        struct DeniedProvider: LocationProviding {
            func currentLocation() async throws -> LocationSnapshot {
                throw ContextSenseUnavailable(message: "Location access is off in System Settings.")
            }
        }
        let result = try await CurrentLocationTool(provider: DeniedProvider(), precision: .coarse)
            .execute(input: [:])
        #expect(result.output == "Error: Location access is off in System Settings.")
    }

    @Test("a raw CoreLocation error is rendered as calm copy, never leaked to the model")
    func rawErrorIsCalm() async throws {
        struct FailingProvider: LocationProviding {
            func currentLocation() async throws -> LocationSnapshot {
                // A CLError is an NSError in kCLErrorDomain — the app adapter's
                // didFailWithError resumes with exactly this, raw.
                throw NSError(
                    domain: "kCLErrorDomain", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "The operation couldn't be completed. (kCLErrorDomain error 2.)"]
                )
            }
        }
        let result = try await CurrentLocationTool(provider: FailingProvider(), precision: .coarse)
            .execute(input: [:])
        #expect(result.output.hasPrefix("Error:"))
        #expect(!result.output.contains("kCLErrorDomain"))
    }

    @Test("location is local-sensitive by charter")
    func localSensitive() {
        let tool = CurrentLocationTool(
            provider: FakeProvider(snapshot: LocationSnapshot(latitude: 0, longitude: 0)),
            precision: .coarse
        )
        #expect(tool.exclusionClass == .localSensitive)
    }

    @Test("the warm-only provider never reads")
    func warmProviderThrows() async {
        await #expect(throws: ContextSenseUnavailable.self) {
            _ = try await NullLocationProviding().currentLocation()
        }
    }
}
