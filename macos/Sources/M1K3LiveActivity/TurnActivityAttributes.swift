//
//  TurnActivityAttributes.swift
//  M1K3LiveActivity
//
//  The ActivityKit face of `TurnActivityState`. No static attributes either: nothing about the
//  turn is carried, only its phase. iOS only today (`Activity.request` is unavailable in the
//  macOS 27.2 SDK); the macOS 27.3 Mac adopts it by widening this one gate, not by rewriting.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.8, Prior: none (new file).

import Foundation
#if os(iOS) && canImport(ActivityKit)
    import ActivityKit

    public struct TurnActivityAttributes: ActivityAttributes {
        public typealias ContentState = TurnActivityState

        public init() {}
    }
#endif
