# Notify and push to talk — voice comms for paired devices and remote agents

**Status: DRAFT (2026-10-02). Nothing here is built.** This is the design for
three things that keep coming up from outside the Mac: a remote agent or
device telling M1K3 to *say* something, M1K3 holding its tongue at the right
moments, and Kev answering an agent by voice without opening a window. It
was drafted from a read of the code as it stands, so every seam it names
exists today; the open calls at the end are Kev's.

The driving case: a Claude cloud session finishes a long run (a netcode test
phase, a build) and wants the Mac to say so, while Kev is wearing a headset
in another room. Then Kev wants to answer it, by voice, without finding the
right browser tab.

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

One tool, served on loopback and (behind its own toggle, §2) on the LAN
`/mcp` route, plus `m1k3 notify` in the CLI and a `/v1/notify` route for the
mailbox relay (§3).

```
notify { sender: string ≤ 40 chars, text: string ≤ 200 chars,
         urgency: "low" | "normal" | "urgent" }
```

What M1K3 does with it, in order:

1. **Trim and classify.** Text is one line: newlines collapse to a space,
   control characters are dropped, and anything past 200 characters is cut
   with no ellipsis spoken. The sender is a label, never trusted as an
   identity; the identity is the transport's (the loopback visitor name
   stamped by `LoopbackRequestGate`, the paired device row on the LAN, the
   send-key on the relay).
2. **Rate-limit per identity.** A token bucket: 1 per 30 s, burst 3, per
   identity. Beyond that the call returns `isError` with the retry time and
   nothing is spoken. `urgent` does not bypass the bucket; it only changes
   the hold rule in step 3.
3. **Hold or play.** A pure `NotifyHoldPolicy` (M1K3MCPKit, TDD'd like
   `TurnNotificationPolicy`) reads the same predicates `get_status` already
   publishes from `MCPHostController` (`inConversation`, `micInUse`,
   `isSpeaking`) plus macOS Focus state and a new "quiet while" set (§4).
   Held messages go to a small in-memory queue (cap 8 per identity, 32
   total, oldest dropped) and drain in order when the hold lifts. `urgent`
   plays through a Focus mode and through an in-flight MCP `speak`, but
   never through voice mode, a call recording or the microphone being open.
4. **Say it.** A short chime (the existing boot or heartbeat sound, not a new
   asset), then the sentence `"<sender>: <text>"` through the current
   `SwappableSpeechProvider` at the current voice tier. The avatar shows
   `.neutral` for the duration; the caller cannot pick an emotion. A
   drained queue of several messages from one sender collapses to one
   preface: `"<sender>, three messages:"`.
5. **Mirror visually.** The same line posts as a local notification through
   `TurnNotifier` with a new `Kind.notify` and a per-sender identifier, so
   the banner replaces the sender's previous one instead of stacking. The
   banner is useful on its own when the Mac is muted.
6. **Never into memory, never to the agent.** A notify is not a chat turn:
   it does not enter the transcript, so `MemoryDistillationCoordinator`
   cannot distil it (the structural exclusion the heartbeat store relies
   on), and `ask_m1k3` never sees it as context. It is logged to the Agent
   Interaction Log as a visit, like any other tool call, with its sender.

The response tells the caller what happened: `Spoken.`, `Held: on a call
(queue 2).`, or the rate-limit refusal. No `wait` argument; a caller that
wants to know when it played polls `get_status`, which gains a
`notifications_held` count next to `queued`.

**What a caller cannot do with `notify`:** speak more than one short line,
pick a voice or emotion, open the mic, interrupt M1K3 mid-sentence, bypass
Do Not Disturb, write to memory, or see what M1K3 is doing beyond the status
it already publishes.

## §2 On the home network — Brain at Home

- Add `"notify"` to a **new** `MCPToolScope.lan` grant tier rather than to
  `lanAllowedTools` directly: `lanAllowedTools` stays read/ask, and a second
  set `lanNotifyTools = ["notify"]` is merged in only while a new toggle is
  on. Same pattern as the LAN MCP route's own switch
  (`BrainServeController.lanMCPKey`, default OFF, never inherited): **Settings
  → Privacy → Brain at Home → "Let paired devices announce"**, default OFF,
  nested under the MCP route toggle so it cannot be on while the route is
  off. A new tool stays LAN-invisible until named, as today.
- The paired device row becomes the identity for the rate bucket and the
  log stamp. This is the "LAN-MCP client-name stamping" item already on the
  roadmap's Brain at Home list; `notify` is the first tool that needs it,
  so it lands with this PR.
- Per-device mute: the paired-devices list gains a "can announce" check per
  row, so one noisy device can be silenced without revoking it. Revoke
  still kills everything.
- Transport is unchanged: TLS 1.2 ECDHE-PSK, private-source gate, the 16
  connection cap and the 10 s request deadline all apply. No new route; it
  is one more tool on the scoped `/mcp` session.
- The iPhone, iPad and Vision Pro shells already hold `M1K3BrainLink` and a
  paired key, so they can call `notify` on the Mac with no new pairing. A
  Quest or another Mac pairs with the same QR.

**Verify:** `swift test` on the scope filter (notify absent with the toggle
off, present with it on, absent from `.lan` when only `lanMCPEnabled` is
on), the hold policy table, and the bucket. Hardware-owed: the chime over
real speakers while a Focus mode is on; a held message draining after a
voice-mode exit.

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
- **Keys at pairing.** The Mac mints a per-sender send-only key (an X25519
  public key for sealing plus a short sender id) and shows it as a QR or a
  copyable line. For a Claude cloud session the line goes into the
  environment's secrets; the session then posts to the relay with `curl`
  or a one-file helper. The Mac's private key lives in the Keychain under
  `app.m1k3`, device-only, like the Brain at Home PSKs. Revoking a sender
  deletes its id from the Mac's accept list; the relay never needs to know.
- **Replay and flood.** Each message carries a nonce and a timestamp; the
  Mac rejects anything older than five minutes or seen before, then applies
  the §1 bucket per sender id. The relay caps queue length and body size
  (one message is well under 1 KB sealed).
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

Order within this phase: the Mac side (decrypt, accept list, the pane) with
a fake relay in tests, then the Worker, then the cloud-session helper.

## §4 Quiet while — when M1K3 holds its tongue

The hold policy's inputs, all already observable in the app:

| Signal | Source | Normal | Urgent |
|---|---|---|---|
| Voice mode live | `env.voiceLoop != nil` | hold | hold |
| Mic open (dictation, call recording) | `env.isListening`, `env.isRecording` | hold | hold |
| Chat turn responding | `env.chat.isResponding` | hold | play after |
| Visitor `speak` in flight | `isSpeaking` | hold | play after |
| macOS Focus on (any mode) | `INFocusStatusCenter` / Focus filter | hold | play |
| "Quiet while" shortcut active | §4a | hold | hold |
| Mac display asleep or locked | `NSWorkspace` session notifications | banner only | banner only |

"Play after" means the message waits for the current utterance or turn to
end, then plays before anything queued behind it. Focus state needs the
Communication Notifications entitlement or a Focus filter intent; if neither
is granted the row degrades to "unknown" and is treated as off, named in
the Settings footer.

### §4a The explicit quiet window

The netcode tests and the LAN play sessions are not visible to M1K3. Rather
than teach it about Mariachi Rumble, give it a general switch an external
process can hold: `m1k3 quiet --for 20m "netcode tests"` (and the same via
a `quiet` argument on `notify`'s sibling tool `set_quiet`, loopback only).
While a quiet window is open every non-urgent notify holds and the menu-bar
line shows the reason. A test runner opens it at start and clears it at
exit, or lets it expire. The window is never longer than four hours and
survives nothing: an app restart clears it.

The headset case is the same switch from the other side: a paired device
that is being worn calls `set_quiet` on the LAN with `route: device`, which
means hold on the Mac's speakers and, instead, deliver the sentence to the
device (§5).

## §5 Where the reply goes — routing to the device you are using

An announcement should land where Kev is, not where the Mac is:

- **Mac speakers** is the default and the only route in the first PR.
- **The paired device**, when it has declared itself the active route
  (§4a): the Mac posts the sentence back over the same LAN session as a
  pending notification the device polls, and the device speaks it with its
  own `AVSpeechProvider` or shows it. The Vision Pro and iPhone shells have
  the speech stack already (`AppCore+Voice.swift`); a Quest client is a web
  or Android shell and is Phase C of Brain at Home, not this spec.
- **AirPods or a Bluetooth headset on the Mac** need no routing: macOS
  already sends playback to the selected output. The one addition is a
  "pause when the output route changes mid-sentence" check so a message
  does not finish on the speakers after the headset disconnects.

## §6 Push to talk — answering by voice

The walkie-talkie half. Hold a key, speak, release; the words go back to
whoever last spoke.

- **Trigger.** A global hotkey on the Mac (default ⌥Space, configurable,
  registered through Carbon `RegisterEventHotKey`, which needs no
  Accessibility grant; an event tap would, so it is not the plan). On a paired
  iPhone, Watch or Vision Pro, a hold on a button in the shell. AirPods
  stem presses reach the app only as media remote commands and are not
  reliable for hold, so the stem is a later experiment, not a promise.
- **Capture.** While held, M1K3 transcribes on-device through the existing
  `TranscriptionRouter` (dictation path, the sharper engine, no echo
  cancellation preference, exactly like chat dictation). Audio never
  leaves the Mac; only the final text does. The karaoke band shows the
  live transcript so Kev can see what is about to be sent.
- **Release.** A two-second cancel window: the band shows the text with a
  countdown, Escape or a second tap cancels, and the text is otherwise
  committed. No confirmation sheet; the hold is the intent.
- **Target: last sender wins.** The reply goes to the identity that most
  recently delivered a notify (held or played), within the last 30
  minutes. If nothing qualifies, the text goes to the chat as a normal
  turn to M1K3's own brain, so the gesture is never wasted. The band names
  the target before the countdown starts: "→ Mariachi session" or "→ M1K3".
- **Delivery.** A reply is a pending message the sender collects:
  - loopback and LAN visitors poll a new `get_replies` tool (scoped like
    `notify`, returns and clears pending text for that identity);
  - a relay sender gets it sealed to its own key in its mailbox, the
    mirror of §3;
  - a Claude cloud session reads it on its next poll of the relay. The
    reply arrives in that session as a message from Kev, so this is a
    remote way to instruct an agent. The physical hold on a paired device
    is what proves it is Kev; anything destructive the agent proposes
    still goes through its normal confirmation on its own side.
- **Never into memory.** Like `notify`, a PTT reply does not enter the
  transcript or the memory graph. It is logged in the Agent Interaction
  Log as an outbound line with its target.

**Verify:** the target rule and the cancel window are pure state
(`PushToTalkMachine`, TDD'd like `VoiceLoopMachine`); the hotkey, the band
and the live transcription are verify-by-launch.

## §7 Order of work

1. **`notify` on loopback + LAN** (one PR, `M1K3MCPKit` + `M1K3BrainServe`
   + the Settings toggle + client-name stamping). Small, rides on Brain at
   Home as built, changes no privacy copy. `challenger` before it lands:
   the 200-character cap, the bucket numbers and the hold table are
   thresholds.
2. **Quiet while + device routing** (§4a, §5): the `set_quiet` tool, the
   CLI verb, the menu-bar reason line, the device-side delivery in the
   mobile shell.
3. **Push to talk** (§6): hotkey + machine + `get_replies`. Independent of
   the relay; useful on loopback alone for an agent in a local Claude Code
   session.
4. **The mailbox relay** (§3): the only phase that touches the privacy
   story, so it ships last and only after the Settings copy and SECURITY.md
   paragraph are agreed. Its own ADR, the way PCC got 0006.

## §8 Open calls (Kev)

1. Does the relay exist at all, or is WAN delivery left to Tailscale plus a
   relaxed tunnel rule for a user-named tailnet? Either is a privacy
   ruling; the spec is written for the relay because it is the only route
   that reaches a cloud container.
2. The chime: reuse the boot sound, the heartbeat tone, or none (voice
   only)? Doctrine says one sound per meaning, so a new asset needs a new
   meaning.
3. Does `urgent` play through a Focus mode by default, or is that a
   per-sender grant? The table above lets it through; the safer default is
   not to.
4. Push-to-talk default hotkey, and whether a Watch hold is in scope for
   the first cut or waits on the mobile shell's parity ladder.
5. Should a reply ever go to M1K3's own brain when no sender is live (the
   fallback in §6), or should the gesture do nothing then? The fallback
   makes the key useful every day; the no-op makes it predictable.

---
*Signed: Kev + Claude, 2026-10-02, DRAFT, Confidence 0.7 (every seam named
exists and was read; the thresholds are by feel and owed a challenger
pass; the Focus-state and hotkey mechanics are verify-by-launch and may
need an entitlement). Prior: `BRAIN_AT_HOME_SPEC.md` §2 and §6,
`MCPToolScope.swift`, `LoopbackToolGrants.swift`, `VoiceMCPTools.swift`,
ADR 0006.*
