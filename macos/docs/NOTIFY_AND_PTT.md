# Notify and push to talk — voice comms for paired devices and remote agents

**Status: DRAFT v2 (2026-10-02). Nothing here is built.** This is the design
for three things that keep coming up from outside the Mac: a remote agent or
device telling M1K3 to *say* something, M1K3 holding its tongue at the right
moments, and Kev answering an agent by voice without opening a window. It
was drafted from a read of the code as it stands, so every seam it names
exists today; the open calls at the end are Kev's.

The driving case: a Claude cloud session finishes a long run (a netcode test
phase, a build) and wants the Mac to say so, while Kev is wearing a headset
in another room. Then Kev wants to answer it, by voice, without finding the
right browser tab.

**v2 is the seamless pass.** v1 had seven places where a person, an agent or
a device had to do something at message time: a toggle per capability, a
secret per session, an agent deciding to notify, a quiet tool to call, a
route to declare, a hotkey to hold, a reply to poll for. v2 removes each
one with a signal the Mac already has, and keeps the explicit control only
as the override. The rule: **nobody does anything at message time.**

## §0 Why not just open `speak` to the network

`speak`, `listen` and `stop_speaking` are excluded from the LAN allowlist
(`MCPToolScope.lanAllowedTools`, M1K3BrainServe) on purpose: the 2026-08-19
audit ruled that a paired device must not drive the Mac's speakers and mic.
`speak` is also the wrong shape for the job:

- Its text is bounded only by `MCPInput.maxText`; a paired device could read
  a page aloud, or impersonate M1K3 in its own voice at length.
- It has no sender, so nothing can be rate-limited or muted per device.
- It animates the avatar with a caller-chosen emotion, which is M1K3's layer,
  not a visitor's (doctrine principle 1).
- Loopback `speak` already queues visitors behind each other (#283). A
  remote announcement should not sit in that queue behind a 25-second read.

So the answer is a **new, narrower tool** with a fixed sentence shape, a
sender, an urgency and a hold policy, and `speak` stays loopback-only.

## §1 `notify` — the shape

One tool, served on loopback and (behind a pairing-time grant, §2) on the
LAN `/mcp` route, plus `m1k3 notify` in the CLI and a `/v1/notify` route for
the mailbox relay (§3).

```
notify { text: string ≤ 200 chars,
         sender?: string ≤ 40 chars,          default: the transport identity's name
         urgency?: "low" | "normal" | "urgent" default: "normal" }
```

Only `text` is required. A caller that knows nothing but "say this" gets
the right behaviour; the other two fields are refinements, never
prerequisites. What M1K3 does with it, in order:

1. **Trim and classify.** Text is one line: newlines collapse to a space,
   control characters are dropped, and anything past 200 characters is cut
   with no ellipsis spoken. The sender is a label, never trusted as an
   identity; the identity is the transport's (the loopback visitor name
   stamped by `LoopbackRequestGate`, the paired device row on the LAN, the
   send-key on the relay). A missing sender is the identity's own name.
2. **Rate-limit per identity.** A token bucket: 1 per 30 s, burst 3, per
   identity. Beyond that the call returns `isError` with the retry time and
   nothing is spoken. `urgent` does not bypass the bucket; it only changes
   the hold rule in step 3.
3. **Hold or play.** A pure `NotifyHoldPolicy` (M1K3MCPKit, TDD'd like
   `TurnNotificationPolicy`) reads the inferred signals in §4. Held messages
   go to a small in-memory queue (cap 8 per identity, 32 total, oldest
   dropped) and drain in order when the hold lifts.
4. **Pick the surface** (§5): the Mac's speakers if Kev is at the Mac, else
   the paired device Kev is using, else the banner alone.
5. **Say it.** A short chime (an existing sound, not a new asset), then the
   sentence `"<sender>: <text>"` through the current
   `SwappableSpeechProvider` at the current voice tier. The avatar shows
   `.neutral` for the duration; the caller cannot pick an emotion. A
   drained queue of several messages from one sender collapses to one
   preface: `"<sender>, three messages:"`.
6. **Listen for the reply** (§6): after the sentence, if the mic is free and
   the reply grant is on, M1K3 listens for a few seconds. That is the whole
   push-to-talk story in the common case.
7. **Mirror visually.** The same line posts as a local notification through
   `TurnNotifier` with a new `Kind.notify` and a per-sender identifier, so
   the banner replaces the sender's previous one instead of stacking. The
   banner is useful on its own when the Mac is muted.
8. **Never into memory, never to the agent.** A notify is not a chat turn:
   it does not enter the transcript, so `MemoryDistillationCoordinator`
   cannot distil it (the structural exclusion the heartbeat store relies
   on), and `ask_m1k3` never sees it as context. It is logged to the Agent
   Interaction Log as a visit, like any other tool call, with its sender.

The response tells the caller what happened: `Spoken.`, `Held: on a call
(queue 2).`, `Sent to Kev's iPhone.`, or the rate-limit refusal. No `wait`
argument; a caller that wants to know when it played polls `get_status`,
which gains a `notifications_held` count next to `queued`.

**What a caller cannot do with `notify`:** speak more than one short line,
pick a voice or emotion, open the mic for itself, interrupt M1K3
mid-sentence, bypass Do Not Disturb, write to memory, or see what M1K3 is
doing beyond the status it already publishes.

### §1a The agent never decides to notify

The sending side mirrors the long-think ping. `TurnNotificationPolicy` pings
Kev when a turn ran past eight seconds while the app was in the background;
an agent session gets the same rule, pointed the other way: a **Stop hook**
in the Claude Code session (cloud or local) that calls `notify` when the
turn it is ending ran longer than a threshold (two minutes to start; the
challenger pass sets it) or ended in an error. The agent that finishes the
netcode phase never thinks about announcing it. The hook is one line in
the session's settings and ships as a skill in this repo, so a new session
picks it up with nothing typed. An agent can still call `notify` by hand
for something the hook would not catch ("I need a decision"), and that is
the only time it needs to know the tool exists.

## §2 On the home network — Brain at Home

- Add `"notify"` and `"get_replies"` as a **new** `MCPToolScope.lan` grant
  tier rather than to `lanAllowedTools` directly: `lanAllowedTools` stays
  read/ask, and a second set `lanAnnounceTools` is merged in per device
  while that device holds the grant. A new tool stays LAN-invisible until
  named, as today.
- **The grant is given at Approve, not in a second ceremony.** The pairing
  sheet already asks «name» wants to pair — Approve? It gains two
  checkboxes, both ticked by default for a device Kev is approving right
  now: *Can announce* and *Can receive replies*. The paired-devices list
  shows the same two checks per row, so one noisy device is silenced
  without revoking it. That is where Kev changes his mind; Approve is the
  moment of trust and the only ceremony. The route-level switch stays as
  it is (`BrainServeController.lanMCPKey`, default OFF, never inherited):
  no grant means anything while the LAN MCP route is off.
- The paired device row becomes the identity for the rate bucket and the
  log stamp. This is the "LAN-MCP client-name stamping" item already on the
  roadmap's Brain at Home list; `notify` is the first tool that needs it,
  so it lands with this PR.
- Transport is unchanged: TLS 1.2 ECDHE-PSK, private-source gate, the 16
  connection cap and the 10 s request deadline all apply. No new route; it
  is two more tools on the scoped `/mcp` session.
- The iPhone, iPad and Vision Pro shells already hold `M1K3BrainLink` and a
  paired key, so they can call `notify` on the Mac with no new pairing. A
  Quest or another Mac pairs with the same QR.

**Verify:** `swift test` on the scope filter (notify absent without the
grant, present with it, absent from `.lan` when only `lanMCPEnabled` is
on), the hold policy table, and the bucket. Hardware-owed: the chime over
real speakers while a Focus mode is on; a held message draining after a
voice-mode exit; the Approve sheet with its two checks.

## §3 Across networks — the mailbox relay

The Mac accepts no inbound connections from outside the home network (spec
§3: cellular and tunnel interfaces prohibited, RFC1918 only), and that stays.
A cloud session like the one that drafted this, or the phone on 4G, cannot
reach `/mcp`. So for WAN the Mac **fetches** instead:

- A tiny relay (one HTTPS endpoint, stateless apart from a per-mailbox
  queue with a short TTL) holds **sealed** messages. The Mac keeps one
  outbound long-poll or WebSocket open to its mailbox while the feature is
  on, so the relay sees ciphertext, a mailbox id and timestamps, nothing
  else. The Mac decrypts and feeds `notify` with the sender taken from the
  key that sealed the message.
- **One key per account, minted once.** The Mac mints a send-only key (an
  X25519 public key for sealing plus a short sender id) and shows it as a
  QR or a copyable line. For Claude it goes into the cloud environment's
  secrets **once**; after that every session in that environment can reach
  the Mac with nothing added, and the §1a Stop hook finds it in the
  environment. The sender id names the environment, so the Mac's log reads
  "Claude (m1k3 env)" and not a session hash. A second key for the phone on
  4G is the same ceremony on the phone. The Mac's private key lives in the
  Keychain under `app.m1k3`, device-only, like the Brain at Home PSKs.
  Revoking a sender deletes its id from the Mac's accept list; the relay
  never needs to know.
- **Replay and flood.** Each message carries a nonce and a timestamp; the
  Mac rejects anything older than five minutes or seen before, then applies
  the §1 bucket per sender id. The relay caps queue length and body size
  (one message is well under 1 KB sealed).
- **The reply must wake the session, not wait for a poll.** A Claude cloud
  session can register an inbound webhook that wakes it when something
  posts to it (`watch_url` in the claude-code-remote tools). Its deliveries
  are signed with a secret sealed to Claude's own artifact service, so
  whether a third-party relay can deliver to it is **unverified** and is
  the first task of this phase: an afternoon with a stub relay and one
  session. If it works, the reply lands in the session as a message from
  Kev a second or two after he stops speaking. If it does not, the
  fallback is the hook reading the reply mailbox at the start of every
  turn, which is seamless for a session that is working and late for one
  that is idle. The design does not depend on the answer; the feel does.
- **What it costs the promise.** This is the only part of the design where
  a byte leaves the Mac: the open connection to the relay reveals that an
  M1K3 is online and when it polls. That is less than a PCC turn reveals,
  but it is not nothing, and "private by design" (ADR 0006) means it has to
  be opt-in, labelled and off by default: **Settings → Privacy → Remote
  announcements**, with a footer that says the relay holds sealed one-line
  messages and sees when the Mac is online. It is its own switch, not a
  child of Brain at Home, because it is a different trust story. M1K3 for
  Teams gets a policy key to force it off.
- **Who runs the relay.** Round Tower, as a static-ish Cloudflare Worker or
  equivalent; self-hosting is a URL field in the same pane. Nothing in the
  app depends on the relay being up: a dead relay means no remote
  announcements and one quiet status line, never an error on launch.
- **Tailscale** is the no-code alternative for the phone on 4G: with the
  Mac's tailnet address, the phone could reach the LAN route if the
  `.other` interface prohibition were relaxed for a user-named tailnet. That
  is a separate ruling (the audit prohibited tunnels deliberately) and does
  not help the cloud-session case, where the container cannot join a
  tailnet. Listed so it is a conscious no, not a forgotten option.

Order within this phase: the webhook probe, then the Mac side (decrypt,
accept list, the pane) with a fake relay in tests, then the Worker, then
the Stop hook skill.

## §4 Quiet — inferred, never declared

v1 asked a test runner, a headset or Kev to tell M1K3 when to be quiet.
v2 infers it from signals the Mac already exposes, and keeps one explicit
override for the case no signal covers.

| Signal | Source | Normal | Urgent |
|---|---|---|---|
| Voice mode live | `env.voiceLoop != nil` | hold | hold |
| M1K3's own mic open (dictation, call recording) | `env.isListening`, `env.isRecording` | hold | hold |
| **Any process has the input device running** | CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input | hold | hold |
| Chat turn responding | `env.chat.isResponding` | hold | play after |
| Visitor `speak` in flight | `isSpeaking` | hold | play after |
| macOS Focus on (any mode) | `INFocusStatusCenter`, needs the Communication Notifications entitlement | hold | play |
| Explicit quiet window (§4a) | `set_quiet` | hold | hold |
| Mac display asleep or locked | `NSWorkspace` session notifications | route elsewhere (§5) | route elsewhere |

The third row is the one that does the work. The input device running in
any process means a call, a game's voice chat, a recording, a dictation in
another app: every case v1 needed a tool call for, read from one property
with no grant. It is polled on the same ten-second cadence as
`backgroundWorkAllowed`, and a held message drains within ten seconds of
the mic closing. A game that runs its own voice chat over a headset keeps
the Mac quiet for exactly the length of the session, with nobody doing
anything.

"Play after" means the message waits for the current utterance or turn to
end, then plays before anything queued behind it. If the Focus entitlement
is not granted the row degrades to unknown and is treated as off, named in
the Settings footer.

### §4a The explicit override

For the case no signal covers (a test suite that is sensitive to the Mac
speaking but never opens the mic), one tool and one CLI verb:
`m1k3 quiet --for 20m "netcode tests"`, loopback only, `set_quiet` as the
tool name. While a window is open every non-urgent notify holds and the
menu-bar line shows the reason. A runner opens it at start and clears it
at exit, or lets it expire. Never longer than four hours; an app restart
clears it. It is the exception path, so it earns no Settings surface.

## §5 Where it lands — presence, not routing

An announcement should land where Kev is, not where the Mac is. v1 made a
device declare itself the route; v2 infers it:

1. **Kev is at the Mac** if the session is unlocked and the last input
   event is under two minutes old (`CGEventSource.secondsSinceLastEventType`
   on the combined session state, no Accessibility grant needed). The Mac's
   speakers, or whatever output macOS has selected, play it.
2. **Otherwise, the device Kev is using.** Paired shells report a
   lightweight presence beat over the existing LAN session while they are
   in the foreground (the iPhone app open, the Vision Pro worn), at most
   once a minute. The most recent beat under three minutes old wins. The
   Mac posts the sentence back over that session as a pending announcement
   the device collects on its next beat and speaks with its own
   `AVSpeechProvider` or shows. The iPhone, iPad and Vision Pro shells
   already have the speech stack (`AppCore+Voice.swift`); a Quest client is
   a web or Android shell and is Phase C of Brain at Home, not this spec.
3. **Otherwise, the banner alone**, and the sentence waits in the queue for
   the next presence signal, up to an hour, then drops. A message Kev was
   not there for is a banner he reads later, not a sentence spoken to an
   empty room.

AirPods or a Bluetooth headset on the Mac need no routing of their own: the
one addition is a check that pauses an utterance when the output route
changes mid-sentence, so a message does not finish on the speakers after
the headset disconnects.

## §6 The reply — listen after announce, hotkey as the fallback

The walkie-talkie half. v1 led with a hotkey; v2 leads with the thing that
needs no key at all.

- **Listen after announce.** When the sentence has played on the Mac and
  the §4 mic rows are all clear, M1K3 opens the mic for a short window
  (five seconds of silence closes it, twenty seconds caps it) through the
  existing `TranscriptionRouter` on the dictation path, the sharper
  engine, exactly like chat dictation. The face shows the listening state
  the way voice mode already does, so it is visibly M1K3 listening and not
  a hidden hot mic. Speak, and the words go to the sender. Say nothing,
  and the window closes with no reply. The karaoke band shows the live
  transcript, and a two-second cancel after the endpoint (Escape or a
  second tap) is the only control. This is one toggle, **Settings →
  Privacy → "Listen for a reply after an announcement"**, default OFF
  until the challenger pass says otherwise, because M1K3 opening the mic
  unprompted is exactly what the `.microphone` grant exists for. The
  difference from `listen` is that no agent asked: M1K3 listens on its
  own terms, the audio never leaves the Mac, and only the final text goes
  to the sender.
- **On the device,** the same window runs in the paired shell after it
  speaks the sentence, with a hold-to-reply button as the visible
  affordance and the same cancel.
- **The hotkey is the follow-up path.** A global hotkey on the Mac (default
  ⌥Space, configurable, registered through Carbon `RegisterEventHotKey`,
  which needs no Accessibility grant; an event tap would, so it is not the
  plan) for replying after the window has closed. Hold, speak, release,
  the same two-second cancel. AirPods stem presses reach the app only as
  media remote commands and are not reliable for hold, so the stem is a
  later experiment, not a promise.
- **Target: last sender wins.** The reply goes to the identity whose
  notify most recently played or was held, within the last 30 minutes.
  The band names it before the countdown starts: "→ Claude (m1k3 env)" or
  "→ M1K3". If nothing qualifies, the hotkey text goes to the chat as a
  normal turn to M1K3's own brain, so the gesture is never wasted. The
  listen-after-announce window never falls back: it only ever exists
  because a sender just spoke.
- **Delivery.** A reply is a pending message the sender collects:
  - loopback and LAN visitors call `get_replies` (scoped with `notify`,
    returns and clears pending text for that identity);
  - a relay sender gets it sealed to its own key in its mailbox, and the
    relay wakes the session if §3's probe says it can;
  - a Claude session reads it as a message from Kev, so this is a remote
    way to instruct an agent. The spoken reply on a paired device, or at
    the unlocked Mac, is what proves it is Kev; anything destructive the
    agent proposes still goes through its normal confirmation on its own
    side.
- **Never into memory.** Like `notify`, a reply does not enter the
  transcript or the memory graph. It is logged in the Agent Interaction
  Log as an outbound line with its target.

**Verify:** the target rule, the window timings and the cancel are pure
state (`PushToTalkMachine`, TDD'd like `VoiceLoopMachine`); the hotkey, the
band, the listening face and the live transcription are verify-by-launch.

## §7 Order of work

1. **`notify` on loopback + LAN** (one PR, `M1K3MCPKit` + `M1K3BrainServe`
   + the Approve-sheet grants + client-name stamping + the CoreAudio and
   idle-time signals). Changes no privacy copy. `challenger` before it
   lands: the 200-character cap, the bucket numbers, the hold table and
   the two-minute idle threshold are all thresholds.
2. **Presence and the device surface** (§5): the beat, the pending
   announcement, the device-side speech in the mobile shell.
3. **The reply** (§6): listen-after-announce, the machine, `get_replies`,
   the hotkey. Independent of the relay; useful on loopback alone for an
   agent in a local Claude Code session, and the Stop hook skill ships
   here so local sessions get it first.
4. **The mailbox relay** (§3): the webhook probe first, then the only phase
   that touches the privacy story, so it ships last and only after the
   Settings copy and SECURITY.md paragraph are agreed. Its own ADR, the way
   PCC got 0006.

## §8 Open calls (Kev)

1. Does the relay exist at all, or is WAN delivery left to Tailscale plus a
   relaxed tunnel rule for a user-named tailnet? Either is a privacy
   ruling; the spec is written for the relay because it is the only route
   that reaches a cloud container.
2. Listen-after-announce default: OFF (the spec's position, mic grants are
   never default-on) or ON for a device Kev approved himself?
3. The chime: reuse the boot sound, the heartbeat tone, or none (voice
   only)? Doctrine says one sound per meaning, so a new asset needs a new
   meaning.
4. Does `urgent` play through a Focus mode by default, or is that a
   per-sender grant? The table above lets it through; the safer default is
   not to.
5. Should a hotkey reply with no live sender go to M1K3's own brain (the
   fallback in §6), or do nothing? The fallback makes the key useful every
   day; the no-op makes it predictable.

---
*Signed: Kev + Claude, 2026-10-02, DRAFT v2, Confidence 0.7 (every seam
named exists and was read; the CoreAudio and idle-time signals are
documented OS properties and not yet exercised in this codebase; the
thresholds are by feel and owed a challenger pass; the Focus state, the
hotkey and the session webhook are verify-by-launch or verify-by-probe).
Prior: v1 of this document (same day), `BRAIN_AT_HOME_SPEC.md` §2 and §6,
`MCPToolScope.swift`, `LoopbackToolGrants.swift`, `VoiceMCPTools.swift`,
`TurnNotificationPolicy.swift`, ADR 0006.*
