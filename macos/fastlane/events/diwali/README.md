# "Diwali Lights": the Diwali event (in-app event, iPhone + iPad)

The look: `diwali` (Dhanteras through Bhai Dooj: Lakshmi Puja ± 2 local days): marigold gold at rest, diya-flame white speaking, rangoli magenta thinking, toran green listening. Greeting: "Happy Diwali! May your home be full of light." No villain costume, no jokes. en-GB's name carries "Deepavali", the South Indian (and Malaysian / Singaporean) name, because India's storefront reads en-GB here; there is no hi or en-IN locale in this spec (see below).

Diwali's date comes from a table in `Sources/M1K3Avatar/SeasonalLook.swift` (`diwaliDates`, 2026–2035, each year checked against two sources), not from a calendar: Foundation's Indian calendars can't name the evening Amavasya falls on. A test fails two years before the table runs out.

**2027 meets Halloween.** Diwali 2027 (Oct 29) sits inside Halloween (Oct 24 – Nov 1). In the app Diwali wins its days, but Halloween night keeps its own look, so the 2027 look runs **Oct 27 – Oct 30** (Bhai Dooj, Oct 31, is Halloween). A Halloween 2027 event that promises the pumpkin look would be wrong on Oct 27–30: say so in its copy, or give the Halloween event Oct 31 – Nov 1 only. Kev's call. (2030 is the same: Diwali Oct 24–28, Halloween Oct 29 – Nov 1.)

The "Seasonal looks" opt-out in Settings covers it, and nothing leaves the device. Force it for art or
checks with `-seasonalLook diwali`. The calendar logic is in `Sources/M1K3Avatar/SeasonalLook.swift`,
and why this event exists is in `../CALENDAR.md`.

**Gate:** the build that carries this look (1.6 or later) must be live on the iOS App Store before the event
publishes (2027-10-13T10:00:00Z). Read `itunes.apple.com/lookup?id=6780230835` first. If the look isn't
live yet, move `publishStart` (and `eventStart` if needed): never publish ahead of the build.

Event: 2027-10-27T10:00:00Z → 2027-10-30T10:00:00Z. It starts at 10:00Z, local midnight in UTC−10, so no zone east of
Hawaii sees the card before the look is on. It ends by 10:00Z on the look's last day, local midnight in UTC+14,
so no zone sees the card after the look is off. Deep link: `m1k3://event/diwali`.

**Next years** (Lakshmi Puja; re-date with `events.py update`, and check each against Halloween and Flight Club):
2028 Oct 17, 2029 Nov 5 (inside Flight Club, which it wins), 2030 Oct 26 (inside Halloween).

## Copy (`event.json`; en-US below, the other eleven locales in its `localizations` table)

| Field | Cap | Text |
|---|---|---|
| name | 30 | Diwali Lights (13) |
| shortDescription | 50 | A marigold glow and a warm hello. (33) |
| longDescription | 120 | For Diwali, the Phosphor Fox glows marigold gold like a diya and wishes your home full of light. All on your device. (116) |

Counts are Python `len`. These are drafts by the model: every non-English locale is **native read owed**, ar-SA and
ru before submission. India's own languages aren't in the 12-locale table: adding `hi` (and checking which
locales the IN storefront indexes) is the biggest reach lever here, and it is Kev's call.

Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.7 — the dates are two-source checked and the window is
pinned by tests; the copy is a model draft, and the reach is a bet to measure. Prior: Unknown (new file).
