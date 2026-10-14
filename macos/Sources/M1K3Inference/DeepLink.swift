//
//  DeepLink.swift
//  M1K3Inference
//
//  The `m1k3://` URLs the iOS app opens from. Today there is one destination:
//  chat. An in-app event (Halloween: `m1k3://event/halloween`) "is the chat
//  screen", so the event name is carried for logs and later, but every link
//  routes the same way. Total on purpose: a URL it can't read still opens
//  chat; only a foreign scheme is refused (nil) so the shell can ignore it.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-14, Confidence 0.85 (pure + tested;
//  the onOpenURL wiring is verify-by-launch). Prior: none (new file).

import Foundation

public enum DeepLink: Equatable, Sendable {
    /// `m1k3://event/<name>`; the name is lowercased.
    case event(String)
    /// Anything else under our scheme: just open the chat screen.
    case chat

    public static let scheme = "m1k3"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        guard url.host(percentEncoded: false)?.lowercased() == "event" else {
            self = .chat
            return
        }
        let name = url.pathComponents.first { $0 != "/" && !$0.isEmpty }
        if let name {
            self = .event(name.lowercased())
        } else {
            self = .chat
        }
    }
}
