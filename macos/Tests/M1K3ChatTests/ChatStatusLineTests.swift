//
//  ChatStatusLineTests.swift
//  M1K3ChatTests
//
//  The one line over the composer that says who answers and whether the web is in play
//  (Kev, 2026-11-03: "It's about trust").
//
//  Signed: Kev + claude-opus-5.5, 2026-11-03, Confidence 0.85. Prior: none (new file).
//

@testable import M1K3Chat
import M1K3LanguageModel
import Testing

struct ChatStatusLineTests {
    @Test("names the brain and says the web is on")
    func brainAndWebOn() {
        let line = ChatStatusLine(brainName: "Lil", privateCloudNext: false, webSearchOn: true)
        #expect(line.brainText == "Lil")
        #expect(line.webText == "Web on")
        #expect(line.text == "Lil · Web on")
    }

    @Test("says the web is off when the switch is off")
    func webOff() {
        let line = ChatStatusLine(brainName: "Mini", privateCloudNext: false, webSearchOn: false)
        #expect(line.text == "Mini · Web off")
        #expect(ChatStatusLine.webText(on: false) == line.webText)
    }

    @Test("Private Cloud Compute replaces the brain when the next send goes there")
    func privateCloudNames() {
        let line = ChatStatusLine(brainName: "Lil", privateCloudNext: true, webSearchOn: true)
        #expect(line.brainText == PrivateCloudLabel.text)
        #expect(line.brainSymbol == "cloud.fill")
    }

    @Test("VoiceOver hears a sentence, not the dot")
    func accessibility() {
        let line = ChatStatusLine(brainName: "Lil", privateCloudNext: false, webSearchOn: false)
        #expect(line.accessibilityLabel == "Lil answers. Web search is off.")
        let cloud = ChatStatusLine(brainName: "Lil", privateCloudNext: true, webSearchOn: true)
        #expect(cloud.accessibilityLabel == "Private Cloud Compute answers. Web search is on.")
        #expect(!line.accessibilityLabel.contains("·"))
    }
}
