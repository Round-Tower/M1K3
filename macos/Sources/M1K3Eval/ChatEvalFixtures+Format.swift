//
//  ChatEvalFixtures+Format.swift
//  M1K3Eval
//
//  format: shape follows content, UNPROMPTED. The `document` kind asks for its table ("Make a Markdown
//  table…"); these never name a shape, because the persona's shape bullet (#716) is what is under test:
//  a comparison across a few points should come back as a small table, a how-to with ordered actions as
//  numbered steps, and small talk as prose with no markdown at all — the character must survive, so a
//  results-page answer to a bid for banter is the fail this kind exists to see.
//
//  Two voice-path fixtures carry `spokenNoMarkup`: the live stage hands the scorer what SpeechTextPolish
//  would say for the turn, and that text must carry no pipe, bold, fence or heading (the flatten learned
//  tables and dash bullets in the same change). On the bare arm, or under `swift test`, nothing is handed in
//  and the check skips rather than guesses. The voice prompts never ask for a shape either; there is no
//  spoken-shape turn clause today, so the flatten is what keeps speech clean (Kev's call whether to add one).
//
//  Run wired like the app: `--kinds format --router dispatch` (a compare prompt may be dispatched to
//  web_search by the router; the answer must still carry the table). #717's typed answer blocks add their
//  fixtures here.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-26, Confidence 0.75 (the fixtures are hand-written and shape-pinned
//  by ChatEvalFixturesTests; whether Lil and Big actually answer in these shapes is what the first wired run
//  shows — the eval stage of the overnight run, then ⌘R by feel). Prior: none (new file).
//

import Foundation

/// GFM separator rows come spaced ("| --- |"), tight ("|---|") or aligned ("|:--"); any of them is a table.
private let gfmSeparators = ["|---", "| ---", "|:--", "| :--"]

/// Any markdown at all, for the small-talk fixtures: a table pipe, bold, a fence, a heading, a bullet, a
/// numbered item. Each fires whole on a line quoting it (ChatEvalFixturesTests.everyForbiddenMarkerFires).
private let markupMarkers = ["|", "**", "```", "\n#", "\n- ", "\n* ", "\n1. "]

public extension ChatEvalFixtures {
    static let format: [ChatEvalFixture] = [
        // Comparisons: the things and the points are named, never the shape.
        .init(
            id: "fmt-compare-drinks", kind: .format,
            prompt: "Compare tea and coffee as a morning drink on caffeine, ritual and cost.",
            expectation: .init(
                mustContainAny: gfmSeparators, mustContainAll: ["tea", "coffee"],
                mustNotContain: leakMarkers, mustComply: true, minChars: 80, wholeWordFacts: true
            )
        ),
        .init(
            id: "fmt-compare-ui", kind: .format,
            prompt: "Compare SwiftUI and AppKit on learning curve, control and longevity.",
            expectation: .init(
                mustContainAny: gfmSeparators, mustContainAll: ["swiftui", "appkit"],
                mustNotContain: leakMarkers, mustComply: true, minChars: 80, wholeWordFacts: true
            )
        ),
        // How-tos with ordered actions: numbered steps, "1." or "1)" at a line start.
        .init(
            id: "fmt-howto-tyre", kind: .format,
            prompt: "How do I change a flat bicycle tyre?",
            expectation: .init(
                mustContainAny: ["\n1.", "\n1)"], mustContainAll: ["2.", "3."],
                mustNotContain: leakMarkers, mustComply: true, minChars: 120, wholeWordFacts: true
            )
        ),
        .init(
            id: "fmt-howto-press", kind: .format,
            prompt: "How do I make a pot of French-press coffee?",
            expectation: .init(
                mustContainAny: ["\n1.", "\n1)"], mustContainAll: ["2.", "3."],
                mustNotContain: leakMarkers, mustComply: true, minChars: 120, wholeWordFacts: true
            )
        ),
        // Small talk and banter: prose, nothing else. No mustComply — a bid for an opinion may read as a
        // decline to the refusal heuristic and still be the right answer (the interview kind's lesson).
        .init(
            id: "fmt-smalltalk-cork", kind: .format,
            prompt: "Cork in October — worth the trip, or is it all rain?",
            expectation: .init(mustNotContain: leakMarkers + markupMarkers, minChars: 40)
        ),
        .init(
            id: "fmt-smalltalk-mind", kind: .format,
            prompt: "Tell me something you've changed your mind about.",
            expectation: .init(mustNotContain: leakMarkers + markupMarkers, minChars: 40)
        ),
        // The voice path: whatever shape the screen gets, the spoken text carries no markup.
        .init(
            id: "fmt-voice-howto", kind: .format,
            prompt: "Talk me through descaling a kettle.",
            expectation: .init(
                mustNotContain: leakMarkers, mustComply: true, minChars: 80, spokenNoMarkup: true
            )
        ),
        .init(
            id: "fmt-voice-compare", kind: .format,
            prompt: "Which is better for a beginner, a ukulele or a guitar? Compare them on cost, size and how "
                + "fast you get a tune out.",
            expectation: .init(
                mustContainAll: ["ukulele", "guitar"], mustNotContain: leakMarkers, mustComply: true,
                minChars: 80, wholeWordFacts: true, spokenNoMarkup: true
            )
        ),
    ]
}
