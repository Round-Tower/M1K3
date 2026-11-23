# "Diwali Lights": the Diwali event (in-app event, iPhone + iPad)

The look: `diwali` (Dhanteras through Bhai Dooj: Lakshmi Puja ± 2 local days): marigold gold at rest, diya-flame white speaking, rangoli magenta thinking, toran green listening. Greeting: "Happy Diwali! May your home be full of light." No villain costume, no jokes. en-GB's name carries "Deepavali", the South Indian (and Malaysian / Singaporean) name, because India's storefront reads en-GB here; `hi` joined 2026-11-23 (no en-IN: App Store Connect has no such locale).

Diwali's date comes from a table in `Sources/M1K3Avatar/SeasonalLook.swift` (`diwaliDates`, 2026–2035, each year checked against two sources), not from a calendar: Foundation's Indian calendars can't name the evening Amavasya falls on. A test fails two years before the table runs out.

**Halloween wins (Kev, 2026-11-23).** Diwali 2027 (Oct 29) and 2030 (Oct 26) sit wholly inside Halloween's season (Oct 24 – Nov 1), which keeps its look unbroken, because the Halloween event is M1K3's biggest reach. So there is **no Diwali look or event in 2027 or 2030**. This spec is dated for **2028 (Oct 15–19)**, the next clear year, by `./events.py next diwali --year 2028 --write`. 2026 and 2029 sit inside Flight Club, where Diwali wins.

The "Seasonal looks" opt-out in Settings covers it, and nothing leaves the device. Force it for art or
checks with `-seasonalLook diwali`. The calendar logic is in `Sources/M1K3Avatar/SeasonalLook.swift`,
and why this event exists is in `../CALENDAR.md`.

**Gate:** the build that carries this look (1.6 or later) must be live on the iOS App Store before the event
publishes (2028-10-01T10:00:00Z). Read `itunes.apple.com/lookup?id=6780230835` first. If the look isn't
live yet, move `publishStart` (and `eventStart` if needed): never publish ahead of the build.

Event: 2028-10-15T10:00:00Z → 2028-10-19T10:00:00Z. It starts at 10:00Z, local midnight in UTC−10, so no zone east of
Hawaii sees the card before the look is on. It ends by 10:00Z on the look's last day, local midnight in UTC+14,
so no zone sees the card after the look is off. Deep link: `m1k3://event/diwali`.

**Next years** (Lakshmi Puja; re-date with `events.py update`, and check each against Halloween and Flight Club):
2028 Oct 17, 2029 Nov 5 (inside Flight Club, which it wins), 2030 Oct 26 (inside Halloween).

## Copy (`event.json`; en-US below, the other twelve locales (eleven plus `hi`) in its `localizations` table)

| Field | Cap | Text |
|---|---|---|
| name | 30 | Diwali Lights (13) |
| shortDescription | 50 | A marigold glow and a warm hello. (33) |
| longDescription | 120 | For Diwali, the Phosphor Fox glows marigold gold like a diya and wishes your home full of light. All on your device. (116) |

Counts are Python `len`. These are drafts by the model: every non-English locale is **native read owed**, ar-SA and
ru before submission. **`hi` (Hindi, Devanagari) is machine-drafted, native read owed** (name 15, short 46, long 112):
it is an event-only locale, beyond the iPhone listing's twelve, added for India's reach. It keeps the avatar's name as a
transliteration (फॉस्फर फॉक्स) and says "सब कुछ आपके डिवाइस पर" for "All on your device". Which locales the IN storefront
indexes for events is still unchecked, and ASC may refuse an event language the listing lacks: read the live result.

Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.7 — the dates are two-source checked and the window is
pinned by tests; the copy is a model draft, and the reach is a bet to measure. Prior: Unknown (new file).
Review: Kev + claude-opus-5-5, 2026-11-23 (Kev: events "as often as possible" for reach) — `hi` added, machine-drafted,
native read owed. No vi or zh-Hant: Diwali has no real audience there. Confidence 0.6: the Hindi is a model draft.
