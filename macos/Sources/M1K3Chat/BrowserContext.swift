//
//  BrowserContext.swift
//  M1K3Chat
//
//  What's open beside the chat, as it stands. The review panel renders a real
//  page — the user's own browser inside M1K3 — but until now nothing about it
//  ever reached the model: open_link's brief covers the moment of opening, and
//  a turn later "what do you make of this page?" was answered from nothing
//  (Kev, 2026-09-04: "general what's going on in the browser as it stands").
//  The app captures the rendered document's title and text when a page finishes
//  loading; this renders it as one labelled grounding block, capped so the
//  browser never crowds out the question. Present only while a page is showing.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-04, Confidence 0.8 (pure render +
//  placement pinned; whether a 4B brain leans on the block for "this page"
//  questions is a live A/B). Prior: Unknown.

import Foundation

public struct BrowserContext: Sendable, Equatable {
    public let url: URL
    public let title: String
    public let text: String

    public init(url: URL, title: String, text: String) {
        self.url = url
        self.title = title
        self.text = text
    }

    /// Enough to say what the page is and what it's about; not a substitute
    /// for fetch_page when the user wants it read in full.
    public static let textBudget = 600

    public func render(textBudget: Int = Self.textBudget) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedTitle.isEmpty ? (url.host ?? url.absoluteString) : trimmedTitle
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let body = lines.count > textBudget
            ? lines.prefix(textBudget).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            : lines
        return "OPEN BESIDE THE CHAT (the review panel, as it stands — when the user asks about "
            + "\"this page\", \"the site\", or what's open, this is it; describe only this text):\n"
            + "\"\(name)\" — \(url.absoluteString)\n\(body)"
    }
}
