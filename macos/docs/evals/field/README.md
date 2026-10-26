# Field reports — exchanges users chose to send

What lands here: the exchanges users email to hello@round-tower.ie from a
thumbs-down in the Mac app (#708, the "Send this exchange to Round Tower…"
sheet). M1K3 offers one exchange: the user's message (an attached file's text
and name are left out), M1K3's answer, the brain that wrote it, the app version
and build, and the user's own note. Nothing else is drawn from their Mac beyond
what the answer itself quotes. The sender saw the whole body and could edit it
before their mail app opened it, so treat every report as unverified and
possibly personal. Their Sent folder is the record.

How one becomes a fixture:

1. Rewrite it as a synthetic case before anything is written down: new names,
   places and projects, nothing that could point back at a person.
   CONTRIBUTING.md's rule stands (fixtures must be synthetic), so a report that
   cannot be rewritten that way is read for the lesson and not kept.
2. Add the synthetic case to a `ChatEvalFixtures` list under the kind it
   exposes (sycophancy, instruction-following, tool-use, …) with the
   expectation the answer missed. The lists and kinds live in
   `macos/Sources/M1K3Eval/ChatEvalFixture.swift`.
3. Keep the original email out of the repo. This folder holds only a one-line
   note per report: the brain, the version, and the fixture id it became.
4. The sheet tells the sender that Round Tower deletes a report if they ask.
   When someone asks, delete the email and its note here.

Nothing here is read by the app or the tests.

<!-- Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.8 — the code-review fold's copy: the email
     is what M1K3 offers and the sender could edit (not "exactly one exchange and nothing else"), file
     text stays behind, fixtures are rewritten as synthetic into a ChatEvalFixtures list, the folder
     holds notes only, and a deletion request is honoured. Prior: the first version of this file, commit
     3e490a2a (#708). -->
