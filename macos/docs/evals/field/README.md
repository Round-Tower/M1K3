# Field reports — exchanges users chose to send

What lands here: the exchanges users email to hello@round-tower.ie from a
thumbs-down in the Mac app (#708, the "Send this exchange to Round Tower…"
sheet). Each email is exactly one exchange — the user's message, M1K3's answer,
the brain that wrote it, the app version and build, and the user's own note —
and nothing else from their Mac. The sender saw and could edit the whole body
before their mail app opened it; their Sent folder is the record.

How one becomes a fixture:

1. Anonymise by hand before anything is written here — names, places, projects,
   anything that could point back at a person. CONTRIBUTING.md's rule stands:
   no user data in fixtures, so a report that cannot be made synthetic is read
   for the lesson and not kept.
2. Write it as a `ChatEvalFixture` case under the kind it exposes
   (sycophancy, instruction-following, tool-use, …) with the expectation the
   answer missed. The eval kinds live in `macos/Sources/M1K3Eval/ChatEvalFixture.swift`.
3. Keep the original email out of the repo. This folder holds only the
   anonymised fixture and a one-line note of the brain and version that failed.

Nothing here is read by the app or the tests. It is a curated input for the
eval board, folded into ChatEvalStage by hand.
