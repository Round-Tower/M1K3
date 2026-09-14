//
//  AppEnvironment+PrivateCloud.swift
//  M1K3App
//
//  The Private Cloud Compute rung's composition (ADR 0006): which backend this
//  process has, the rung's state for the views, and the one send. Glue only —
//  every decision is `PrivateCloudRung` / `PrivateCloudTurn` /
//  `ChatSession.sendPrivateCloud`, unit-tested in the package.
//
//  No backend is the default and, today, the only state a user can reach: the
//  real one needs the macOS 27 SDK and an entitlement not yet granted, and the
//  echo stand-in exists only in a Debug build launched with M1K3_PCC_ECHO. With
//  no backend the switch, the control and the label never appear, and a send
//  never goes anywhere but this Mac.
//
//  App glue, committed with TDD_SKIP: every decision it makes is a tested
//  package call (PrivateCloudRung, ChatEgressConsent.persisted, ChatSession).
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85 (glue over tested
//  policy; verified by launch against the Debug echo backend in every mode, a
//  send-time refusal included: it was silent and emptied the field until the
//  consent read matched the views'. The real PCC path is verify-owed until the
//  entitlement). Prior: Unknown
//

import Foundation
import M1K3Agent
import M1K3Chat
import M1K3LanguageModel
import M1K3LogCore

extension AppEnvironment {
    private static let privateCloudLog = M1K3Log.logger(.security)

    /// The PCC backend in THIS process, resolved once: the real one only when
    /// the adapter is compiled in, the OS has it and the entitlement is held
    /// (`PrivateCloudBackends.live()`); in a Debug build, the echo stand-in when
    /// launched with M1K3_PCC_ECHO. nil everywhere else.
    nonisolated static let privateCloudBackend: (any PrivateCloudAnswering)? = {
        if let live = PrivateCloudBackends.live() { return live }
        #if DEBUG
            return PrivateCloudEchoBackend.fromEnvironment(ProcessInfo.processInfo.environment)
        #else
            return nil
        #endif
    }()

    /// The rung's inputs right now. `consent` is passed in by the view that
    /// holds it in @AppStorage, so the view re-renders when it flips (a plain
    /// UserDefaults read here would not be observed).
    func privateCloudState(consent: Bool?) -> PrivateCloudState {
        PrivateCloudState(
            backendPresent: Self.privateCloudBackend != nil,
            available: privateCloudStatus?.available ?? true,
            consent: consent,
            // A configuration profile's managed preference lands in this domain.
            managedOff: UserDefaults.standard.bool(forKey: PrivateCloudRung.managedOffDefaultsKey),
            quota: privateCloudStatus?.quota ?? .unknown
        )
    }

    /// The persisted consent, raw (nil = never answered = no), read the same way
    /// the views' @AppStorage reads it (`ChatEgressConsent.persisted`).
    var privateCloudConsentPersisted: Bool? {
        ChatEgressConsent.persisted(in: .standard)
    }

    func refreshPrivateCloudStatus() async {
        guard let backend = Self.privateCloudBackend else { return }
        privateCloudStatus = await backend.status()
    }

    /// Send one turn to PCC after the user confirmed the consent sheet. The
    /// gate is re-checked here, at send time: consent or the org switch can
    /// change while the sheet is open, and the sheet's own view of them is not
    /// the authority. Returns false when it refused — nothing left this Mac,
    /// and the caller hands the words back instead of eating them.
    @discardableResult
    func sendPrivateCloud(_ consent: PrivateCloudTurn.Consent, includeConversation: Bool) async -> Bool {
        guard isReady, let backend = Self.privateCloudBackend else {
            Self.privateCloudLog.notice("pcc send refused: no brain ready or no backend")
            return false
        }
        // Read at send time from the persisted consent, not the sheet's copy;
        // ChatSession refuses the send itself unless this gate is open.
        let gate = privateCloudState(consent: privateCloudConsentPersisted)
        guard PrivateCloudRung.escalation(armed: true, gate) == .privateCloud else {
            let control = String(describing: PrivateCloudRung.control(gate))
            Self.privateCloudLog.notice("pcc send refused at send time: control=\(control, privacy: .public)")
            return false
        }
        brainServe?.preemptForLocalTurn()
        avatar.setActivity(.thinking)
        beginAutoSpeakSession()
        await chat.sendPrivateCloud(
            consent, includeConversation: includeConversation, backend: backend,
            gate: gate, localBrainName: selectedBrain.displayName
        )
        if case .speaking = avatar.state.activity {} else { avatar.resetToIdle() }
        await refreshPrivateCloudStatus()
        return true
    }
}
