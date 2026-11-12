# 0011. Private Cloud Compute can be lent to other apps on this Mac, behind its own switches

Date: 2026-11-12
Status: ACCEPTED — Kev, 2026-11-12 ("Option 1 pal - other apps do offer similar, but that doesn't make it okay.. no timing, we don't want to annoy users either"). The ask came from Reddit feedback: "people want PCC available via the OpenAI server, and via MCP".
Deciders: Kev + claude-fable-5.2
Supersedes: [ADR 0006](0006-private-cloud-compute-rung-and-the-private-by-design-posture.md), in part (two of its constraints, named below, for these two paths only)

## Context

M1K3 reaches Apple's Private Cloud Compute (PCC) from chat only: a brain you
pick, a consent sheet that shows what leaves, a label on every answer (ADRs
0006, 0007, 0010). Since 1.4 the Mac app also lends its loaded brain to other
apps on the same Mac through the Local API, and to agents through the MCP
server. People asked for PCC on both.

ADR 0006 says two things these paths cannot keep as written:

- "Default OFF, per request. No turn goes to PCC unless the user escalated it."
  A script calling an API is not the user escalating a turn.
- "Visible, every time. Every answer produced by PCC carries a label in the
  transcript." These calls have no transcript in M1K3.

The pitch kept in `docs/PCC_ENTITLEMENT_REQUEST.md` says the same in other
words ("never used without the user's explicit action"). Apple's form had no
free-text field, so that pitch was written for follow-ups and App Review
notes; whether it was ever sent is not recorded.

## Decision

PCC is lent on two surfaces, each behind its own switch, both off by default.

- **Local API:** a second model id, `cloud-m1k3`. Listed after the brains on
  this Mac, always last, so a client that takes the first model stays local
  whenever a local brain is ready. Switch: Settings ▸ Server ▸ Local API ▸
  "Also offer Private Cloud Compute".
- **MCP:** a tool, `ask_private_cloud(prompt, instructions?)`, on the loopback
  server only (never Brain at Home's LAN palette, never the stdio binary).
  Switch: Settings ▸ Server ▸ MCP server ▸ "Let agents ask Private Cloud
  Compute", a fourth `LoopbackToolGrants` grant.
- **Two yeses.** Each switch works only while the chat rung's own gate is open:
  a backend in this process, no organisation policy against it, and the Privacy
  pane's Private Cloud Compute switch on. The gate is read again on every call.
  Turning the Privacy switch off means no new call is served (one in flight
  finishes).
- **Only the caller's words leave,** behind one fixed line of M1K3's: the
  acceptable-use rule Apple's licence asks for (see the Reviews below). The
  caller's system text and messages, or the agent's prompt and instructions. No M1K3 persona, memory, knowledge,
  tools or chat history is added, and nothing is stored. This is why
  `ask_private_cloud` is a separate tool and not an option on `ask_m1k3`.
- **The chat consent sheet is not on these paths.** It exists to show the M1K3
  history about to leave; here there is none. The caller chose the cloud by
  name and knows what it sent.

What replaces ADR 0006's two constraints on these paths:

- "The user escalated it" becomes **the owner switched lending on for that
  surface, and the caller asked for the cloud by name**. A switch is a standing
  yes, not a per-request one. This is the real change.
- "A label in the transcript" becomes **a count on the Settings pane** of the
  calls that have left since launch, per surface, a notice-level log line for
  each, and for an agent's call a line in the menu bar's agent activity ("Claude
  Code asked Private Cloud Compute"). The model id and the tool's own
  description say it is not local.

Everything else in ADR 0006 stands, for chat and for these paths: default off,
never automatic, honest failures (an OpenAI-shaped error or a plain sentence,
never an empty answer), Apple's claims cited rather than paraphrased.

## Consequences

- **The promise changes shape.** "PCC is never used without your explicit
  action" is now true of chat, and true of other apps only in the sense that
  you turned lending on. The site, the store privacy copy and the App Review
  notes must say so before a build with this ships.
- **An agent can carry your data out.** An agent that holds the MCP token can
  already read memory and documents with no grant, and can now pass what it
  read to PCC. It could already pass it to its own cloud model; PCC keeps
  nothing. The Settings text says this in one sentence.
- **Quota is shared.** Lent calls spend the same daily limit chat uses. A tool
  in a loop can spend it, and the chat pick then falls back to the local brain.
  The count on the pane is how the owner sees why. M1K3 caps lent calls at 30 an
  hour across both surfaces, and the MCP tool at one call at a time. Open: 30
  is a first number, not a measured one (Apple does not publish the limit).
- **Two consent models for PCC** (the sheet for chat, a switch for lending).
  Any later PCC change has to keep both true.
- **Unknown, and Kev's risk to weigh:** Apple's public PCC page is silent on an
  app serving the model to other processes (read 2026-11-12). The Apple
  Intelligence Terms and Conditions it points to could not be found (the
  guessed URL is a 404). Two other Apple pages were read the same day and bear
  on it; neither names proxying or re-serving:
  - The Foundation Models framework's Acceptable Use Requirements open their
    prohibited-uses list with "You may not use, prompt, or expose the Foundation
    Models framework" for the uses listed, nor "encourage or enable others to
    do the same". A caller's own instructions are outside M1K3's guardrails
    here, as they already are for Mini on the Local API (1.4.0).
  - The Developer Program License Agreement, read word for word on 2026-11-12.
    Section 3.2: "You will not ... (3) programmatically access or use Apple
    models through Apple Software or Services except as expressly permitted."
    Section 3.3.11 A: "By accessing, prompting, or otherwise using the
    Foundation Models Framework, or a model accessed by the Foundation Models
    Framework, You agree to follow, and to maintain reasonable guardrails
    supporting, the Foundation Models Framework Acceptable Use Requirements."
    The Acceptable Use Requirements address "developers that wish to use,
    prompt, or expose" the framework, so exposing it is contemplated; what is
    asked for is guardrails. Our reading, not legal advice: M1K3 reaches the
    models through the framework Apple documents, which is the permitted
    route. The open point is "reasonable guardrails": a lent call runs under
    the caller's instructions, with Apple's own safety filter and nothing of
    M1K3's on top. That holds for Mini on the Local API as well as for the
    cloud model. The agreement does not mention Private Cloud Compute by name.

  The entitlement is granted to the account; losing it would take PCC from
  chat too.
- Not honoured on the cloud model: `max_tokens`, `temperature`, token counts
  (the seam is two strings on purpose, ADR 0006). `stop` works.
- v1 keeps the Local API's admission rules for the cloud model too: one call at
  a time, and the person at the Mac goes first, although PCC does not need the
  local brain. Simpler; revisit if people ask.

## Alternatives considered

- **A timed arming** ("lend PCC for the next hour", then off by itself). Keeps
  "an explicit, visible action" closer to literal. Rejected by Kev: "no timing,
  we don't want to annoy users either".
- **Local API only, no MCP tool.** The challenger's pick: an MCP caller is
  usually a cloud agent with a cloud brain already. Kev asked for both.
- **An option on `ask_m1k3`.** Rejected: its grounding is the owner's private
  store, which would leave with no sheet.
- **Do not lend PCC.** Keeps ADR 0006 whole. The answer if the terms forbid it.

<!-- Signed: Kev + claude-fable-5.2, 2026-11-12. Kev's ask; the shape (two
     switches, two yeses, caller's words only, a count in place of a label) is
     the proposal, pressure-tested by a challenger pass that named the ADR 0006
     conflict and the first-model trap. Confidence 0.6: the code is pinned, the
     posture change and the terms question are Kev's to settle. Prior: ADRs
     0006, 0010. -->
<!-- Review: Kev + claude-fable-5.2, 2026-11-12 — ACCEPTED as proposed (Kev: option 1,
     the persistent switch, both surfaces, no timed arming). His note stands beside
     it: that other apps offer the same "doesn't make it okay", so the switches,
     the count and the cap are the terms it ships on. Still open: the terms
     question above (two Apple pages read, one clause unverified). Confidence 0.7. -->
<!-- Review: Kev + claude-fable-5.2, 2026-11-12 (later) — Kev: "Let's read that section". The
     licence clauses are now quoted word for word from Apple's page, and the lending was
     tried against the real service on Kev's Mac (both surfaces answered). The open
     point is narrowed to "reasonable guardrails" on a lent Apple model. Confidence 0.7. -->
<!-- Review: Kev + claude-fable-5.2, 2026-11-12 (guardrail) — Kev, asked whether to add a
     short acceptable-use instruction of M1K3's own to a lent Apple model before App
     Review: "Please do that." `LentAppleModelGuardrail` puts one fixed line ahead of the
     caller's instructions on Mini (Local API) and on Private Cloud Compute (Local API and
     MCP). "Only the caller's words leave" now reads "the caller's words behind that one
     line". It is our answer to "reasonable guardrails"; whether Apple finds it reasonable
     is not something we can know from here. Confidence 0.7. -->
