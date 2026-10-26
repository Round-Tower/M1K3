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
//  Two voice-path fixtures carry `spokenNoMarkup`: the stage hands the scorer what the speech lane would say
//  for the turn — auto-speak's sentence fold, then SpeechTextPolish on each sentence, on both arms — and that
//  text must carry no pipe, bold, fence or heading (the flatten learned tables and dash bullets in the same
//  change). Under `swift test` nothing is handed in and the check skips rather than guesses. The voice prompts
//  never ask for a shape either; there is no spoken-shape turn clause today, so the flatten is what keeps
//  speech clean (Kev's call whether to add one).
//
//  Bold is the one markup banter may carry: the shape bullet allows the key fact bold, once, so the small-talk
//  bid that invites a fact (Cork) does not forbid it; the pure banter bid does.
//
//  Run wired like the app: `--kinds format --router dispatch --full-answers` (the scorecard prints a format
//  answer whole only when the run keeps it; the preview is 240 characters otherwise, and a table or a how-to
//  is longer). A compare prompt may be dispatched to web_search by the router; the answer must still carry
//  the table. #717's typed answer blocks add their fixtures here.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-26, Confidence 0.75 (the fixtures are hand-written and shape-pinned
//  by ChatEvalFixturesTests; whether Lil and Big actually answer in these shapes is what the first wired run
//  shows — the eval stage of the overnight run, then ⌘R by feel). Prior: none (new file).
//  Review: same day (pre-push review fold) — the how-to fixtures want three dotted steps at line starts
//  (`mustContainAll`; the scorer reads the first line as a line start, so step 1 may open the answer; "1)" is
//  not accepted, pinned), bold leaves the Cork bid's markers, and the run line carries `--full-answers`.
//  Confidence 0.8.
//

import Foundation

/// GFM separator rows come spaced ("| --- |"), tight ("|---|") or aligned ("|:--"); any of them is a table.
private let gfmSeparators = ["|---", "| ---", "|:--", "| :--"]

/// Structure, for the small-talk fixtures: a table pipe, a fence, a heading, a bullet, a numbered item. Each
/// fires whole on a line quoting it (ChatEvalFixturesTests.everyForbiddenMarkerFires). Bold is not here: the
/// shape bullet allows the key fact bold, once, so only `pureBanterMarkers` forbids it.
private let structureMarkers = ["|", "```", "\n#", "\n- ", "\n* ", "\n1. "]
private let pureBanterMarkers = structureMarkers + ["**"]

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
        // How-tos with ordered actions: three numbered steps at line starts, "1." "2." "3." — the answer may
        // open with its list (the scorer reads the first line as a line start). Dotted numbering only: the
        // brains write "1.", and a "1)" list is pinned as not accepted (ChatEvalScorerTests) rather than half
        // accepted by an any-list no all-list could follow.
        .init(
            id: "fmt-howto-tyre", kind: .format,
            prompt: "How do I change a flat bicycle tyre?",
            expectation: .init(
                mustContainAll: ["\n1.", "\n2.", "\n3."],
                mustNotContain: leakMarkers, mustComply: true, minChars: 120, wholeWordFacts: true
            )
        ),
        .init(
            id: "fmt-howto-press", kind: .format,
            prompt: "How do I make a pot of French-press coffee?",
            expectation: .init(
                mustContainAll: ["\n1.", "\n2.", "\n3."],
                mustNotContain: leakMarkers, mustComply: true, minChars: 120, wholeWordFacts: true
            )
        ),
        // Small talk and banter: prose. No structure; bold only where there is a fact to bold (Cork invites
        // one), none on pure banter. No mustComply — a bid for an opinion may read as a decline to the
        // refusal heuristic and still be the right answer (the interview kind's lesson).
        .init(
            id: "fmt-smalltalk-cork", kind: .format,
            prompt: "Cork in October — worth the trip, or is it all rain?",
            expectation: .init(mustNotContain: leakMarkers + structureMarkers, minChars: 40)
        ),
        .init(
            id: "fmt-smalltalk-mind", kind: .format,
            prompt: "Tell me something you've changed your mind about.",
            expectation: .init(mustNotContain: leakMarkers + pureBanterMarkers, minChars: 40)
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
