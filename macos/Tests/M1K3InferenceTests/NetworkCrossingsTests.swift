//
//  NetworkCrossingsTests.swift
//  M1K3InferenceTests
//
//  The one list of ways M1K3 reaches the internet, per build lane, and the two lines of in-app copy
//  made from it (HelloView's privacy line, the Privacy pane's Tools footer). The old copy called web
//  search "the one thing that sends anything out": false since the embedder, WhisperKit, Kokoro and
//  the pocket Mini download too.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure; the site and store copy are
//  hand-written and checked by tools/site). Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-10-26 — #708: both lanes end with `.fieldReport`, the opt-in
//  "Send this exchange" email the USER's mail app makes (madeByApp false), so Hello's App-Review line is
//  unchanged by construction. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-29 — #750: the field-report crossing's phrase names the snag report.
//  Confidence unchanged.

@testable import M1K3Inference
import Testing

struct NetworkCrossingsTests {
    @Test("the Developer ID DMG has no Private Cloud Compute crossing; the App Store build has it, opt-in")
    func laneAwareList() {
        let dmg = NetworkCrossings.crossings(for: .developerID).map(\.kind)
        let store = NetworkCrossings.crossings(for: .appStore).map(\.kind)
        #expect(dmg == [.modelDownloads, .webTools, .updates, .fieldReport])
        #expect(store == [.modelDownloads, .webTools, .updates, .privateCloud, .fieldReport])
        let pcc = NetworkCrossings.crossings(for: .appStore).first { $0.kind == .privateCloud }
        #expect(pcc?.optIn == true)
    }

    @Test("the field report is opt-in per message and the user's mail app makes the connection, so the Hello line never names it")
    func fieldReportIsOptInAndNotMadeByTheApp() throws {
        for lane in [NetworkCrossings.Lane.developerID, .appStore] {
            let crossing = try #require(NetworkCrossings.crossings(for: lane).first { $0.kind == .fieldReport })
            #expect(crossing.optIn)
            #expect(!crossing.madeByApp, "the user's mail client sends it, like an update rides the store")
            #expect(!crossing.hasSettingsSwitch, "per-message opt-in is the control; there is nothing to leave on")
            #expect(crossing.phrase.contains("Round Tower"))
            #expect(crossing.phrase.contains("one exchange"))
            #expect(crossing.phrase.contains("snag"), "#750's report rides the same crossing")
            let hello = NetworkCrossings.helloPrivacyLine(for: lane)
            #expect(!hello.contains("Round Tower") && !hello.contains("email"), "App Review's line is unchanged")
        }
    }

    @Test("the lane follows whether the build carries a Private Cloud Compute backend")
    func laneFromBackend() {
        #expect(NetworkCrossings.Lane(privateCloudBackendPresent: true) == .appStore)
        #expect(NetworkCrossings.Lane(privateCloudBackendPresent: false) == .developerID)
    }

    @Test("every download names where it comes from: Hugging Face for weights, github.com for the Kokoro voice pack")
    func hostsPerDownload() {
        for kind in DownloadKind.allCases {
            #expect(!NetworkCrossings.hosts(for: kind).isEmpty, "\(kind) has no declared host")
        }
        #expect(NetworkCrossings.hosts(for: .voice) == ["huggingface.co", "github.com"])
        for kind in [DownloadKind.lil, .big, .pocket, .semanticMemory, .sharperEars] {
            #expect(NetworkCrossings.hosts(for: kind) == ["huggingface.co"])
        }
        #expect(NetworkCrossings.downloadHosts == ["github.com", "huggingface.co"])
    }

    @Test("Hello's privacy line names downloads and web search in both lanes, and never the 'one thing' claim")
    func helloLine() {
        for lane in [NetworkCrossings.Lane.developerID, .appStore] {
            let line = NetworkCrossings.helloPrivacyLine(for: lane)
            #expect(line.contains("no account"))
            #expect(line.contains("download the models you choose (brains, speech, voice)"))
            #expect(line.contains("search the web"))
            #expect(!line.contains("one thing"))
        }
    }

    @Test("only the App Store lane's line mentions Private Cloud Compute")
    func helloLineIsBuildAware() {
        #expect(!NetworkCrossings.helloPrivacyLine(for: .developerID).contains("Private Cloud Compute"))
        let store = NetworkCrossings.helloPrivacyLine(for: .appStore)
        #expect(store.contains("Private Cloud Compute"))
        #expect(store.contains("each a switch in Settings"))
    }

    @Test("the Tools footer says web search is the one capability beyond downloads only while no PCC rung exists")
    func toolsFooter() {
        let dmg = NetworkCrossings.webSearchFootnote(for: .developerID)
        #expect(dmg.contains("Besides model downloads"))
        #expect(dmg.contains("every search and page read shows in the reply"))
        let store = NetworkCrossings.webSearchFootnote(for: .appStore)
        #expect(!store.contains("one capability"), "the claim is false once a PCC rung exists")
        #expect(store.hasPrefix("Every search and page read shows in the reply"))
        #expect(!dmg.hasPrefix("The one capability"), "the old absolute claim is back")
    }
}
