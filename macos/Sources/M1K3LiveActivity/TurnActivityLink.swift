//
//  TurnActivityLink.swift
//  M1K3LiveActivity
//
//  The Live Activity's tap target. `m1k3://chat` opens the conversation (the app's DeepLink
//  reads any `m1k3://` URL as the chat screen). It never carries a question: no query, no path.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.85, Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-16 — the unreachable `file:///` fallback is a precondition: the
//  literal is constant, so a failure is a programming error that tests catch, not a state to limp on in.

import Foundation

public enum TurnActivityLink {
    public static let url: URL = {
        guard let url = URL(string: "m1k3://chat") else { preconditionFailure("m1k3://chat is a valid URL") }
        return url
    }()
}
