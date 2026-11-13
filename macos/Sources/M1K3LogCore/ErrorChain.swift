//
//  ErrorChain.swift
//  M1K3LogCore
//
//  An error's domains and codes, all the way down, as one short log field.
//  `String(describing:)` on a wrapped NSError spends a 200-character preview on
//  the outer "The operation couldn't be completed" and cuts off before the
//  underlying errors, which are the cause: on 2026-11-13 two ask_private_cloud
//  failures logged `LanguageModelError Code=-1 … NSMultipleUnderlyingErrorsKey=(
//  "Error Domain=…` and stopped there.
//
//  Domains and codes only: no descriptions and no userInfo values, so nothing a
//  prompt or a path could ride in on. Safe to log `.public`.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85 (pinned on
//  hand-built NSErrors in ErrorChainTests; the real Private Cloud Compute chain
//  is read off the next live failure). Prior: none (new file).
//

import Foundation

public enum ErrorChain {
    /// How deep the walk goes, and how many siblings one level lists.
    public static let maxDepth = 4
    public static let maxSiblings = 4

    /// `Outer(-1) ← Inner(1046) ← Root(7)`; siblings from
    /// `NSMultipleUnderlyingErrorsKey` are listed in brackets:
    /// `Outer(-1) ← [A(1) ← Root(7), B(2)]`.
    public static func summary(_ error: any Error) -> String {
        describe(error as NSError, depth: 1)
    }

    private static func describe(_ error: NSError, depth: Int) -> String {
        let here = "\(error.domain)(\(error.code))"
        guard depth < maxDepth else { return here }
        var causes: [NSError] = []
        if let single = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            causes.append(single)
        }
        if let many = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] {
            causes.append(contentsOf: many.map { $0 as NSError })
        }
        guard !causes.isEmpty else { return here }
        let listed = causes.prefix(maxSiblings).map { describe($0, depth: depth + 1) }
        let more = causes.count > maxSiblings ? ", +\(causes.count - maxSiblings) more" : ""
        let tail = listed.count == 1 && more.isEmpty ? listed[0] : "[" + listed.joined(separator: ", ") + more + "]"
        return "\(here) ← \(tail)"
    }
}
