//
//  ScreengrabCadence.swift
//  M1K3Screengrab
//
//  The voice loop's endpoint cadence under the harness: the conversational
//  preset with the 30 s `maxWait` stretched to ten minutes. XCTest's element
//  snapshots over the avatar surface can take tens of seconds, and the
//  listening plate was twice shot AFTER maxWait had submitted the turn.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.85 (pinned), Prior: Unknown
//

import M1K3Voice

public extension EndpointCadence {
    static let screengrab = EndpointCadence(
        silence: EndpointCadence.conversational.silence,
        hold: EndpointCadence.conversational.hold,
        maxWait: .seconds(600),
        cadenceMargin: EndpointCadence.conversational.cadenceMargin,
        cadenceCeiling: EndpointCadence.conversational.cadenceCeiling,
        emptyListensBeforeParking: EndpointCadence.conversational.emptyListensBeforeParking
    )
}
