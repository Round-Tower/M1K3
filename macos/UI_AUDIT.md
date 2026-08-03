# M1K3 macOS — UI, SF Symbols, Typography & Accessibility Audit

> ⚠️ **SUPERSEDED (2026-08-03).** Point-in-time audit of the June 2026 app
> (907 lines, 5 view files — the app is now ~34 surfaces). The 🔴 accessibility
> findings were addressed in #30. Kept as history; do not read the verdicts as
> current.

> Scope: the SwiftUI app shell in `macos/M1K3App/` (ContentView, MessageView,
> CallsView, DocumentsView, SettingsView). 907 lines, 5 view files.
> Goal: lean into a Mac-native look (SF Symbols + SF Pro intentionality) and make
> the app genuinely accessible. Authored 2026-06-07.

## TL;DR

| Area | State | Verdict |
|---|---|---|
| **Typography** | Semantic text styles (`.caption`/`.headline`/`.callout`…) used almost everywhere | 🟢 Strong foundation — Dynamic Type-ready. 3 hardcoded sizes to fix. |
| **SF Symbols** | Used throughout, but all default monochrome, no weights, no state convention, one hand-rolled shape | 🟡 Present but flat — leaning in = rendering modes + conventions + tasteful motion. |
| **Accessibility** | 2 `.help()` tooltips, **zero** labels/hints/values/traits; color-only status; all-glass, no Reduce Transparency | 🔴 The real work. Icon-only buttons are unlabeled; status is color-only; no Dynamic Type / Reduce Motion / Contrast handling. |

---

## 1 · SF Symbols

**Inventory** (16 distinct, all `Image(systemName:)` / `Label(systemImage:)`):
`brain`(M1K3 mark), `square.and.pencil`, `doc.badge.plus`, `books.vertical`,
`phone.bubble`(×4), `record.circle`, `gearshape`(×2), `mic`/`mic.fill`,
`arrow.up`, `speaker.wave.2`, `doc.text.magnifyingglass`, `trash`, `tray`,
`tray.and.arrow.down`, `checkmark.circle.fill`, `exclamationmark.triangle`,
`circle.fill`.

**Issues**
1. **No rendering modes anywhere.** Every symbol is flat monochrome. macOS-native
   UIs use `.symbolRenderingMode(.hierarchical)` for depth and `.palette`/
   `.multicolor` for state. → `brain`, `record.circle`, `checkmark.circle.fill`,
   `exclamationmark.triangle` all want hierarchical/multicolor.
2. **No weight/scale alignment.** Symbols don't track adjacent text. Use
   `.imageScale(.medium)` + `.fontWeight()` (or a shared `.font`) so a symbol next
   to `.headline` reads as `.headline`.
3. **Hand-rolled shape instead of a symbol.** `ContentView.swift:170` draws the
   recording indicator as `Circle().fill(.red)` — inconsistent with the symbol
   language. Use `record.circle.fill` (or `dot.radiowaves.left.and.right`).
4. **No state convention.** `mic`↔`mic.fill` flips on listening (good!), but
   elsewhere fill/no-fill is ad hoc. **Adopt a rule:** outline = inactive/idle,
   `.fill` = active/selected/destructive-confirmed.
5. **No motion.** macOS 26 ships `.symbolEffect`. Tasteful wins:
   - recording dot → `.symbolEffect(.pulse)` (gated on Reduce Motion, see §3)
   - listening mic → `.symbolEffect(.variableColor.iterative)`
   - speaking → `speaker.wave.2` → `.symbolEffect(.variableColor)` while playing
   - download/working → `.symbolEffect(.pulse)` instead of bare `ProgressView`.

**Recommended conventions**
```swift
// M1K3 symbol tokens (proposed)
extension Image {
    func m1k3Glyph(_ scale: Image.Scale = .medium) -> some View {
        self.symbolRenderingMode(.hierarchical).imageScale(scale)
    }
}
// status symbols carry meaning in shape, not just colour (see §3)
```

---

## 2 · Typography

**What's right (keep it):** ~46 of ~49 `.font()` calls use **semantic styles**
(`.caption`×24, `.headline`×4, `.callout`×3, `.caption2`×4, `.subheadline`,
`.title3`, `.body`). These are SF Pro and **scale with Dynamic Type for free** —
the correct Mac-native foundation. Don't replace them with fixed sizes.

**Issues**
1. **3 hardcoded sizes break Dynamic Type:**
   - `ContentView.swift:131,141` — `.system(size: 16, weight: .semibold)` on the
     mic/send glyphs. Won't grow for low-vision users. → use `.imageScale` +
     `.title3`/`.headline`, or `@ScaledMetric`.
   - `CallsView.swift:195` — `.font(.system(size: 5))` bullet dot. Effectively
     invisible and unscalable. → use a `.fill` symbol at `.caption2` or a real
     `Label` bullet.
2. **No `.monospacedDigit()` on changing numbers** — item counts, "12 chunks",
   "8 lines", download `NN%`, the call timestamp. They'll jitter/reflow as they
   update. Mac-native polish: add `.monospacedDigit()`.
3. **`.caption` is overworked (×24)** — hierarchy is flat. A small type scale
   (below) clarifies intent: title / section / body / meta / micro.
4. **Fixed sheet frames vs Dynamic Type** — `Settings 440×440`, `Calls 480×540`,
   `Documents 480×480`, `CallDetail 520×560`. At large accessibility text sizes
   the content overflows a fixed box. → use `minWidth/idealHeight` + let it grow,
   or cap with `.dynamicTypeSize(...DynamicTypeSize.accessibility3)` thoughtfully.

**Proposed type tokens** (semantic → role, so usage is consistent):
| Token | Style | Use |
|---|---|---|
| `title` | `.headline` | sheet headers, dialog titles |
| `section` | `.subheadline.weight(.semibold)` | section headings |
| `body` | `.body` / `.callout` | message text, transcript |
| `meta` | `.caption` | timestamps, source labels, status |
| `micro` | `.caption2` | counts, chunk badges (+ `.monospacedDigit()`) |

---

## 3 · Accessibility — the real work

Today: **2 `.help()` tooltips** (`ContentView:137` mic, `DocumentsView:91` delete)
and **zero** `accessibilityLabel/Hint/Value/addTraits`, no Dynamic Type guards, no
Reduce Motion/Transparency/Contrast handling. For a privacy-first product that
"respects user… trust," a11y is table stakes. Priorities below.

### P0 — blocks VoiceOver users
1. **Icon-only buttons have no labels.** VoiceOver reads the symbol name, not the
   action:
   - Send (`arrow.up`, `ContentView:139`) → "arrow up". Add
     `.accessibilityLabel("Send")`.
   - Mic toggle → label "Voice input", `.accessibilityValue(isListening ? "On" : "Off")`,
     `.accessibilityHint("Dictate a message")`. (The `.help` helps pointer users,
     not VoiceOver value.)
   - Trash (`DocumentsView:87`) → `.accessibilityLabel("Delete \(doc.title)")`.
   - Speak (`MessageView:71`) → label "Speak this answer".
2. **Status is colour-only** (WCAG 1.4.1 fail):
   - Recording = red dot + red text. The dot alone carries state. Give the
     container `.accessibilityElement(children: .ignore)` +
     `.accessibilityLabel("Recording")` + `.accessibilityAddTraits(.updatesFrequently)`.
   - Provider/runtime dot (`ContentView:178`, green/orange) is unlabeled → VoiceOver
     gets nothing. Add `.accessibilityLabel("Model \(providerAvailable ? "ready" : "unavailable")")`.
   - Never rely on red/green/orange alone — pair with a shape/symbol difference too.
3. **Chat turns fragment under VoiceOver.** Each `MessageView` should be ONE element
   with a composed label: user → "You said: …"; assistant → "M1K3: …, 3 sources".
   Wrap in `.accessibilityElement(children: .combine)`.

### P1 — environment adaptation
4. **Reduce Transparency** — the whole UI is Liquid Glass. Honour
   `@Environment(\.accessibilityReduceTransparency)` → swap `glassEffect`/white-opacity
   fills for solid surfaces. Biggest single a11y win for a glass-heavy app.
5. **Reduce Motion** — gate the scroll animation (`ContentView:97`
   `withAnimation(.easeOut…)`) and every proposed `.symbolEffect` on
   `@Environment(\.accessibilityReduceMotion)`.
6. **Increase Contrast** — `.secondary`/`.tertiary` text on 6–8% white glass is
   likely < 4.5:1 (e.g. CallsView "8 lines" `.tertiary`, the dim captions). Audit
   ratios; respond to `@Environment(\.colorSchemeContrast) == .increased` with
   stronger foregrounds and less translucency.
7. **Dynamic Type** — fix the 3 fixed sizes (§2.1); test at
   `.accessibility5`; let fixed sheet frames grow.

### P2 — polish & flow
8. **Live announcements** — streaming assistant text and status flips
   ("Recording…", "Downloading Gemma 3… 40%", "Transcribed — indexed") should post
   `AccessibilityNotification.Announcement(...)` so VoiceOver users hear progress.
9. **Hit targets** — mic/send glyphs are `frame(width:22,height:22)` inside the
   buttons (`ContentView:132,142`). Ensure the *button* hit area is ≥ 28–44pt
   (pad the button, not just the glyph).
10. **Focus on present** — when a sheet opens, move VoiceOver focus to its header
    (`.accessibilityFocused`), and label each sheet as a modal surface.
11. **Keyboard** — Return-to-send is wired (`ContentView:146`). Verify full keyboard
    traversal of toolbar + sheets and visible focus rings (free if we don't fight
    the system).

---

## Prioritised punch-list

**Quick wins (an afternoon, high impact):**
- [ ] `accessibilityLabel` on every icon-only button (send, mic, trash, speak, toolbar)
- [ ] Replace `Circle().fill(.red)` recording dot → `record.circle.fill` symbol
- [ ] `.monospacedDigit()` on all counters/percentages/timestamps
- [ ] Fix the 3 hardcoded font sizes → Dynamic Type-safe
- [ ] `.symbolRenderingMode(.hierarchical)` pass on status/accent symbols

**Then (the substance):**
- [ ] `accessibilityElement(.combine)` on MessageView turns + composed labels
- [ ] Reduce Transparency → solid-surface fallback for the glass system
- [ ] Reduce Motion gate on scroll anim + symbol effects
- [ ] Contrast pass on `.secondary`/`.tertiary` over glass
- [ ] Live announcements for streaming + status

**Stretch / craft:**
- [ ] Tasteful `.symbolEffect` motion (pulse/variableColor) — Reduce-Motion-gated
- [ ] Type-token + symbol-token helpers (§1, §2) so it stays consistent
- [ ] Dynamic Type test pass at `.accessibility5`; let sheets grow

---

## How to verify (no rate limits, it's the real app)
- **VoiceOver**: ⌘F5, tab through every control — each should announce a role,
  label, and (for stateful controls) a value.
- **Accessibility Inspector** (Xcode → Open Developer Tool) → run the audit on the
  running app; it flags unlabeled elements, contrast, and hit targets automatically.
- **Settings → Accessibility**: toggle Reduce Transparency, Reduce Motion, Increase
  Contrast, and bump Display text size — the UI should adapt, not break.

> Signed: Kev + claude-opus-4-8, 2026-06-07, Confidence 0.8, Prior: Unknown —
> static audit of the SwiftUI source; runtime checks (VoiceOver/Inspector) are
> Kev's at ⌘R.
