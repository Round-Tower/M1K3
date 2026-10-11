//
//  AvatarDisplayTests.swift
//  M1K3AvatarTests
//
//  The avatar in the Mac chat is the backdrop or off — the 200 pt panel is gone (Kev,
//  2026-10-11, TestFlight). A stored "panel" from an older build must land on the backdrop
//  in every reader, so the mapping lives in the package and is pinned here.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85. Prior: none (new file).
//

import Foundation
@testable import M1K3Avatar
import Testing

struct AvatarDisplayTests {
    @Test("a stored panel from an older build becomes the backdrop")
    func legacyPanelMapsToBackground() {
        #expect(AvatarDisplay(persisted: "panel") == .background)
    }

    @Test("nil, empty and unknown values fall to the default", arguments: [nil, "", "garbage", "Panel"])
    func unknownFallsToDefault(raw: String?) {
        #expect(AvatarDisplay(persisted: raw) == AvatarDisplay.defaultValue)
        #expect(AvatarDisplay.defaultValue == .background)
    }

    @Test func offAndBackgroundRoundTrip() {
        #expect(AvatarDisplay(persisted: "off") == .off)
        #expect(AvatarDisplay(persisted: "background") == .background)
        for mode in AvatarDisplay.allCases {
            #expect(AvatarDisplay(persisted: mode.rawValue) == mode)
        }
    }

    @Test func twoChoicesAndTheSameKeyAsBefore() {
        #expect(AvatarDisplay.allCases == [.background, .off])
        #expect(AvatarDisplay.storageKey == "chat.avatarDisplay")
    }
}
