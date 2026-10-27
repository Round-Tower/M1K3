//
//  AnswerBlock.swift
//  M1K3AnswerBlocks
//
//  Typed answer blocks (#717): the on-device answer to "Intelligent UI", sized
//  for 4B brains. A model writes a fenced block whose info string names the
//  kind and whose body is a small JSON object:
//
//      ```m1k3-steps
//      {"steps": ["Loosen the nut.", "Lift the cover."]}
//      ```
//
//      ```m1k3-choices
//      {"prompt": "Which engine?", "options": ["Lil", "Big", "Mini"]}
//      ```
//
//  This file is the body parser only. Garbage in → nil out, never a throw: nil
//  means the fence stays the raw markdown it was and renders as today's code
//  card (AnswerBlockSegmenter decides that). FollowUpSplit's posture, with one
//  deliberate difference for steps: a step list is a SEQUENCE, so it is never
//  deduped and never trimmed to a cap. Past a cap the whole block degrades to
//  raw markdown, because a card that silently lost step 13 hides an
//  instruction; the code card shows every word. Choices are suggestions, so
//  they follow FollowUpSplit exactly (dedupe, drop the overlong, cap).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pure, every rule
//  pinned in AnswerBlockTests; the caps are a taste call). Prior: none (new file).
//

import Foundation

/// The fence tags the renderer knows. Any other info string is ordinary code.
public enum AnswerBlockKind: String, CaseIterable, Sendable {
    case steps = "m1k3-steps"
    case choices = "m1k3-choices"
}

/// One parsed typed block.
public enum AnswerBlock: Equatable, Sendable {
    /// Ordered instructions, checkable for the session.
    case steps([String])
    /// A question and the answers a tap sends as the user's next message.
    case choices(prompt: String, options: [String])

    /// A real block is a few hundred bytes. The cap keeps a runaway body (the
    /// renderer re-segments on every streamed frame) out of the JSON parser.
    static let maxBodyBytes = 16384
    static let maxSteps = 12
    static let maxStepLength = 300
    static let maxOptions = 6
    /// FollowUpSplit.maxQuestionLength: a tap target, not a paragraph.
    static let maxOptionLength = 150
    static let maxPromptLength = 300

    public var kind: AnswerBlockKind {
        switch self {
        case .steps: .steps
        case .choices: .choices
        }
    }

    /// The block a fence of `kind` carries, or nil when the body is not that
    /// kind's shape. Never throws.
    public static func parse(kind: AnswerBlockKind, body: String) -> AnswerBlock? {
        guard body.utf8.count <= maxBodyBytes,
              let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        switch kind {
        case .steps: return steps(from: object)
        case .choices: return choices(from: object)
        }
    }

    private static func steps(from object: [String: Any]) -> AnswerBlock? {
        guard let items = strings(object["steps"]) else { return nil }
        let steps = items.map(trimmed).filter { !$0.isEmpty }
        guard !steps.isEmpty,
              steps.count <= maxSteps,
              steps.allSatisfy({ $0.count <= maxStepLength })
        else { return nil }
        return .steps(steps)
    }

    private static func choices(from object: [String: Any]) -> AnswerBlock? {
        guard let rawPrompt = object["prompt"] as? String,
              let items = strings(object["options"])
        else { return nil }
        let prompt = trimmed(rawPrompt)
        guard !prompt.isEmpty, prompt.count <= maxPromptLength else { return nil }
        var seen = Set<String>()
        var options: [String] = []
        for item in items.map(trimmed) {
            guard !item.isEmpty, item.count <= maxOptionLength else { continue }
            guard seen.insert(item.lowercased()).inserted else { continue }
            options.append(item)
            if options.count == maxOptions { break }
        }
        return options.isEmpty ? nil : .choices(prompt: prompt, options: options)
    }

    /// The value as a list of strings, or nil. One non-string element degrades
    /// the whole list (FollowUpSplit's rule: the wrong shape gets no partial credit).
    private static func strings(_ value: Any?) -> [String]? {
        guard let list = value as? [Any] else { return nil }
        var result: [String] = []
        for element in list {
            guard let string = element as? String else { return nil }
            result.append(string)
        }
        return result
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
