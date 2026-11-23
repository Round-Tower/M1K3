# The seasonal event calendar

**Why:** the Halloween event (`halloween/`, 24 Oct → 1 Nov 2026) drew 10–18k App Store search
impressions a day outside the ad countries, mostly in PK, KZ, DZ, IN, IQ and UZ. When it ended, those
impressions fell about 98% overnight (ASC Discovery and Engagement, read 2026-11-23). An event with a
widely searched word in its name is the cheapest reach M1K3 has. Kev, 2026-11-23: "do them as often
as possible and capitalize on the reach there." The traffic is low-intent: 0.57% of those impressions
became page views, against 2.06% in the ad countries. So every event's copy says plainly what the app
is, which keeps the visitors it brings in the ones who want an offline AI.

**How it works:** each event is a look in the app (`Sources/M1K3Avatar/SeasonalLook.swift`: a phosphor
palette and one greeting line), plus a spec here that `macos/tools/asc/events.py` turns into an
App Store event. Apple wants the event to happen in the app, so **the look must be live in the store
before the event publishes**. The whole calendar ships in one build (1.6, Kev's call 2026-11-23), so
every later event needs App Store Connect work only.

| Look (`-seasonalLook`) | In the app (local days) | Event spec | Event (UTC) | Publish | Reach |
|---|---|---|---|---|---|
| `halloween` | Oct 24 – Nov 1 | `halloween/` | yearly | — | the proven one |
| `flightclub` (offline only) | Nov 3 – Dec 1 | `flight-club/` | 2026: Nov 6 – Dec 1 | live | low ("airplane mode") |
| `christmas` | Dec 2 – Jan 7 | `christmas/` | Dec 2 10:00 → Jan 2 09:00 | Nov 25 | everywhere; en-GB names New Year for KZ/UZ |
| `lunarnewyear` | Chinese calendar: New Year's Eve – day 15 (Eve and Day always; the rest yields to Ramadan and Eid) | `lunar-new-year/` | 2027: Feb 5 10:00 → Feb 7 10:00 | Jan 22 | CN, TW, HK, KR, VN, SG, MY; never "Chinese New Year"; en-GB names Tết |
| `ramadan` → `moonsighting` → `eid` | Umm al-Qura: Ramadan 1–28, Ramadan 29 – Shawwal 1, Shawwal 2–4 | `ramadan/` | 2027: Feb 8 10:00 → Mar 11 09:00 | Jan 25 | PK, DZ, IQ, EG, the Gulf; en-GB says "Ramzan" for PK/IN |
| `stpatricks` | Mar 14 – 17 | `st-patricks/` | 2027: Mar 14 10:00 → Mar 17 10:00 | Mar 7 | US, IE, GB |
| `nowruz` | Farvardin 1 – 7 | `nowruz/` | 2027: Mar 21 10:00 → Mar 27 10:00 | Mar 14 | KZ, UZ, KG (the name carries all three spellings) |
| `diwali` | Lakshmi Puja ± 2 (dated table, 2026–2035) | `diwali/` | 2028: Oct 15 10:00 → Oct 19 10:00 (none in 2027 or 2030: Halloween wins) | Oct 1 | IN (top-3 reach), and the diaspora; en-GB names Deepavali |

**Halloween first, then main days:** the looks overlap more than they look. Diwali sits inside Halloween in 2027 and
2030 and inside Flight Club in 2026 and 2029; Lunar New Year meets Ramadan or Eid every year from 2026 to 2031.
**Halloween wins its whole season, Oct 24 – Nov 1** (Kev, 2026-11-23: its event is our biggest reach), so Diwali 2027
and 2030 get no look and no event. After that each feast's main days come first (Diwali's five days, Lunar New Year's
Eve and Day), then a short feast wins a long season, and the rest of Lunar New Year yields to Ramadan and Eid. Any
event that runs across another look's days must say only what is true on all of them.

**Event times:** an event starts at 10:00Z, which is local midnight in UTC−10, so no zone east of Hawaii sees the
card before the look is on. It ends by 10:00Z on the look's last day, local midnight in UTC+14, so no zone sees it
after the look is off. The 31-day events end an hour short of Apple's cap.

**The moon-sighting days:** Pakistan and India begin Ramadan and Eid a day or two after Umm al-Qura (Saudi
Arabia). So on the days that may be either the last fast or Eid (Ramadan 29–30, Shawwal 1), the app says a line
that names neither, and "Eid Mubarak" waits for Shawwal 2.

**Next year:** Ramadan moves about 11 days earlier each year (2028: Jan 28; 2029: Jan 16), Nowruz
falls on Mar 20 or 21, and the app follows both on its own. The specs follow with one command:
`tools/asc/events.py next --all` reads the app's own windows (it compiles `SeasonalLook.swift`, so no
calendar is restated anywhere) and prints each yearly spec's next dates as a diff; `--write` saves them,
and `events.py create` / `update` (Kev's) is still how App Store Connect hears. It re-dates, never
re-words: copy that names the old day (Nowruz's "From Mar 21") is flagged for a re-word. A spec is
yearly when it lists its `"looks"`, so a new event is its look in the app plus a spec with that line.
`events.py check` and `SeasonalEventSpecTests` hold every yearly spec inside its looks from UTC−10 to
UTC+14. The 2026 Christmas dates assume 1.6 is live by Nov 25. If it isn't, move
`publishStart` (and `eventStart` if needed) to after the release; never publish ahead of the build.

**Rules every event keeps:**
- The copy promises only the look and the greeting. Ramadan and Eid wear no villain costume, and
  their lines carry no jokes.
- Name ≤ 30, short ≤ 50, long ≤ 120 characters (Python `len`), in all 12 store locales. Event-only reach locales
  (beyond the iPhone listing; `EXTRA_EVENT_LOCALES` in `test_events.py` pins them): `hi` on Diwali; `zh-Hant` and `vi`
  on Lunar New Year. There is no `en-IN` (ASC has no such locale).
- ar-SA never addresses the reader as "you", so it stays gender-neutral. The fox keeps its local
  names (Phosphorfuchs, zorro fosforescente, …).
- Every translation here is a model draft. ar-SA and ru need a native read before submission
  (see the translation traps in the growth notes); the rest should have one. `hi`, `zh-Hant` and `vi` are
  machine-drafted, native read owed.
- Art: textless stills from the screengrab harness with `-seasonalLook <look>`, 1920×1080 card
  and 1080×1920 details, kept in gitignored `marketing/events/<folder>/`.
- Apple shows up to 5 published events at once and holds up to 10 approved, so plan around that.
- Submission is Kev's click in App Store Connect. `events.py` makes DRAFTs only.

Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.7. The Halloween → impressions link is a
timing match (Apple reports no search terms); the other events' reach is a bet. Measure each one in
`metrics.py analytics fetch --name "App Store Discovery and Engagement Detailed"` and keep only the
ones that earn it.
Review: Kev + claude-opus-5-5, 2026-11-23 (Diwali + Lunar New Year) — two rows and the "main days first" note: both
new looks collide with older ones (Halloween, Flight Club, Ramadan, Eid), so each feast's main days now win first.
Lunar New Year 2027 is a two-day event because Ramadan begins on its third day. Confidence 0.7.

Review: Kev + claude-opus-5-5, 2026-11-23 (Kev: events "as often as possible") — "Next year" now names
`events.py next` / `check` and the specs' `looks` line instead of re-dating each spec by hand.
Confidence 0.85.

Review: Kev + claude-opus-5-5, 2026-11-23 (Kev: events "as often as possible") — `hi` (Diwali) and `zh-Hant` + `vi`
(Lunar New Year) added as event-only locales, machine-drafted, native read owed; the spec test now pins them.
Open: ASC may refuse an event language the app listing lacks, and no live `create` has tried; read it back.
Confidence 0.6.
