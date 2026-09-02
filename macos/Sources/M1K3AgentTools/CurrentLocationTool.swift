//
//  CurrentLocationTool.swift
//  M1K3AgentTools
//
//  The location sense — Phase 2 of the context-tools charter
//  (docs/CONTEXT_TOOLS_PLAN.md): grid-cell coarse by default (the audit's
//  "grid cells, not place names" fold — no gazetteer supply chain, no
//  network geocoder), precise as a separate opt-up (Kev's 2026-09-01
//  ruling). `.localSensitive`: firing it withholds the web tools for the
//  turn (P1) and distillation-taints the turn (P3) — a coordinate can never
//  become a permanent memory fact or a search-query parameter.
//
//  The CoreLocation adapter lives in the app target (the TCC prompt belongs
//  to the app, toggle-first per charter rule 4); this file is framework-free
//  so the package stays portable.
//
//  Signed: Kev + claude-sonnet-5, 2026-09-01, Confidence 0.85 (rounding +
//  tool TDD'd; the CoreLocation adapter is verify-by-launch). Prior: none
//  (new file).
//

import Foundation
import M1K3Agent

/// One position fix, already stripped to coordinates (charter rule 2).
public struct LocationSnapshot: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// The OS seam — fake in tests, CoreLocation in the app. Throws
/// `ContextSenseUnavailable` when access is off.
public protocol LocationProviding: Sendable {
    func currentLocation() async throws -> LocationSnapshot
}

/// Warm-only stub (the NullScriptRunning precedent) — a warm must never
/// fire a TCC prompt at launch.
public struct NullLocationProviding: LocationProviding {
    public init() {}
    public func currentLocation() async throws -> LocationSnapshot {
        throw ContextSenseUnavailable(message: "warm-only provider never reads")
    }
}

public enum LocationPrecision: String, Sendable, Equatable {
    case coarse
    case precise
}

/// Pure precision policy: coarse snaps to a 0.1° grid cell (~11 km of
/// latitude — town-level, no place-name lookup); precise keeps four
/// decimals. The output names its own granularity so the model can't
/// oversell what it knows.
public enum CoarseLocation {
    public static let cellDegrees = 0.1

    public static func snap(_ value: Double) -> Double {
        (value / cellDegrees).rounded() * cellDegrees
    }

    public static func describe(_ snapshot: LocationSnapshot, precision: LocationPrecision) -> String {
        switch precision {
        case .coarse:
            let lat = degrees(snap(snapshot.latitude), positive: "N", negative: "S", decimals: 1)
            let lon = degrees(snap(snapshot.longitude), positive: "E", negative: "W", decimals: 1)
            return "About \(lat), \(lon) (coarse — a ~10 km grid cell)."
        case .precise:
            let lat = degrees(snapshot.latitude, positive: "N", negative: "S", decimals: 4)
            let lon = degrees(snapshot.longitude, positive: "E", negative: "W", decimals: 4)
            return "\(lat), \(lon) (precise)."
        }
    }

    private static func degrees(
        _ value: Double, positive: String, negative: String, decimals: Int
    ) -> String {
        let hemisphere = value < 0 ? negative : positive
        return String(format: "%.\(decimals)f°%@", abs(value), hemisphere)
    }
}

public struct CurrentLocationTool: AgentTool {
    public let name = "current_location"
    public let description =
        "The user's current location — a coarse area by default. "
            + "Argument: optional, ignored."
    public let parameters = [
        ToolParameter(name: "query", description: "ignored"),
    ]
    public let exclusionClass: ToolExclusionClass? = .localSensitive

    private let provider: any LocationProviding
    private let precision: LocationPrecision

    public init(provider: any LocationProviding, precision: LocationPrecision) {
        self.provider = provider
        self.precision = precision
    }

    public func execute(input _: [String: String]) async throws -> ToolResult {
        do {
            let snapshot = try await provider.currentLocation()
            return ToolResult(output: CoarseLocation.describe(snapshot, precision: precision))
        } catch let unavailable as ContextSenseUnavailable {
            return ToolResult(output: "Error: \(unavailable.message)")
        } catch {
            // Any other failure is a raw OS error (a CLError in kCLErrorDomain,
            // say) — never leak its domain/code text to the model. Render a calm,
            // recoverable observation instead, the ContextSenseUnavailable shape.
            return ToolResult(output: "Error: Location isn't available right now — try again.")
        }
    }
}
