//
//  PrivateCloudPhonePickTests.swift
//  M1K3LanguageModelTests
//
//  The phone's one PCC control (Kev, 2026-10-13): the brain list's Private Cloud
//  row is both the chat-egress yes and the pick, so it reads PCC's own state as
//  if allowed (`pickerControl`) and exists wherever the rung can. The scan pins
//  that every shell with a consent sheet can arm it: #585 shipped the iOS sheet
//  with nothing that ever armed it, so the sheet never opened.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.85 (pure; the scan is a
//  string pin, cheap and blunt). Prior: Unknown (new file).
//  Review: Kev + claude-opus-5-5, 2026-10-13 — the onboarding brain step arms it too (Kev: "the
//  on boarding Pick a brain screen also needs it"). Confidence 0.85.
//

import Foundation
@testable import M1K3LanguageModel
import Testing

struct PrivateCloudPhonePickTests {
    private func state(
        backend: Bool = true, available: Bool = true, consent: Bool? = nil,
        managedOff: Bool = false, quota: PrivateCloudQuota = .belowLimit
    ) -> PrivateCloudState {
        PrivateCloudState(
            backendPresent: backend, available: available, consent: consent,
            managedOff: managedOff, quota: quota
        )
    }

    @Test("the phone's row ignores the stored yes: picking it IS the yes")
    func rowIgnoresStoredConsent() {
        for consent in [nil, false, true] as [Bool?] {
            #expect(PrivateCloudRung.pickerControl(state(consent: consent)) == .ready)
        }
    }

    @Test("no backend, or the org switch, hides the row whatever was stored")
    func rowHiddenWhereTheRungCannotExist() {
        for consent in [nil, false, true] as [Bool?] {
            #expect(PrivateCloudRung.pickerControl(state(backend: false, consent: consent)) == .hidden)
            #expect(PrivateCloudRung.pickerControl(state(consent: consent, managedOff: true)) == .hidden)
        }
    }

    @Test("an outage or a spent limit shows on the row, like a locked brain")
    func rowCarriesAvailability() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PrivateCloudRung.pickerControl(state(available: false)) == .unavailable)
        #expect(
            PrivateCloudRung.pickerControl(state(consent: false, quota: .limitReached(resetsAt: reset)))
                == .exhausted(resetsAt: reset)
        )
    }

    @Test("picked through the row, the send control is ready and the first send asks")
    func pickedRowAsksOnFirstSend() {
        // The row writes the yes and the pick together (AppCore.pickPrivateCloud).
        var arming = PrivateCloudArming()
        arming.select(true)
        let control = PrivateCloudRung.control(state(consent: true))
        #expect(control == .ready)
        #expect(arming.action(control: control, hasAttachments: false, onDeviceMessages: []) == .askConsent)
    }

    @Test("a PCC send doesn't wait for the local brain; a local send does")
    func sendReadyFollowsTheRoute() {
        #expect(PrivateCloudRung.sendReady(localBrainReady: false, servesPrivateCloud: true))
        #expect(PrivateCloudRung.sendReady(localBrainReady: true, servesPrivateCloud: false))
        #expect(!PrivateCloudRung.sendReady(localBrainReady: false, servesPrivateCloud: false))
    }

    @Test("every shell with a PCC consent sheet has a row that arms it")
    func everyShellCanArm() throws {
        let macos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: macos.appendingPathComponent(path), encoding: .utf8)
        }
        #expect(try source("M1K3App/ContentView.swift").contains("privateCloudArming.select(true)"))
        let settings = try source("M1K3iOSApp/SettingsScreen.swift")
        #expect(settings.contains("pickPrivateCloud(true)"), "the iOS brain list arms PCC")
        #expect(
            try source("M1K3iOSApp/OnboardingScreen.swift").contains("pickPrivateCloud(true)"),
            "the iOS onboarding brain step offers PCC"
        )
        #expect(!settings.contains("Toggle(\"Private Cloud Compute\""), "one control on the phone, not a switch too")
        #expect(try source("M1K3iOSApp/AppCore.swift").contains("privateCloudArming.select(on)"))
        #expect(try source("M1K3iOSApp/ChatScreen.swift").contains("PrivateCloudRung.sendReady("), "the phone's send gate")
    }
}
