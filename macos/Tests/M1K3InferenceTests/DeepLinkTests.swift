//
//  DeepLinkTests.swift
//  M1K3InferenceTests
//
//  The `m1k3://` scheme the iOS app registers (#603): App Store Connect wants a
//  deep link for an in-app event, and every event "is the chat screen". The
//  parser is total: anything it can't read still lands on chat, never a crash.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-14, Confidence 0.85 (pure; the
//  onOpenURL wiring in the iOS shell is verify-by-launch).
//  Review: Kev + claude-sonnet-5.5, 2026-10-22 — pins `m1k3://event/offline-ai-flight-club` (the November event's
//  deep link): hyphens survive and it opens chat. Confidence 0.9.
//

import Foundation
@testable import M1K3Inference
import Testing

struct DeepLinkTests {
    @Test("m1k3://event/<name> names the event")
    func eventLink() throws {
        let url = try #require(URL(string: "m1k3://event/halloween"))
        #expect(DeepLink(url: url) == .event("halloween"))
    }

    @Test("the Flight Club event link keeps its hyphens and opens chat like any event")
    func flightClubEventLink() throws {
        let url = try #require(URL(string: "m1k3://event/offline-ai-flight-club"))
        #expect(DeepLink(url: url) == .event("offline-ai-flight-club"))
    }

    @Test("the event name is lowercased and a trailing slash is tolerated")
    func eventNormalised() throws {
        let url = try #require(URL(string: "m1k3://event/Halloween/"))
        #expect(DeepLink(url: url) == .event("halloween"))
    }

    @Test("an event link with no name falls back to chat")
    func eventWithoutName() throws {
        for text in ["m1k3://event", "m1k3://event/", "m1k3://event//"] {
            let url = try #require(URL(string: text))
            #expect(DeepLink(url: url) == .chat, "\(text)")
        }
    }

    @Test("unknown hosts, paths and bare scheme all open chat")
    func unknownIsChat() throws {
        for text in ["m1k3://", "m1k3:", "m1k3://settings", "m1k3://whatever/else?x=1", "M1K3://EVENT/Boo"] {
            let url = try #require(URL(string: text))
            let link = DeepLink(url: url)
            #expect(link != nil, "\(text)")
            if text == "M1K3://EVENT/Boo" { #expect(link == .event("boo")) } else { #expect(link == .chat, "\(text)") }
        }
    }

    @Test("another scheme is not ours: nil, so the shell ignores it")
    func foreignScheme() throws {
        for text in ["https://event/halloween", "mailto:a@b.c", "file:///tmp/x"] {
            let url = try #require(URL(string: text))
            #expect(DeepLink(url: url) == nil, "\(text)")
        }
    }
}
