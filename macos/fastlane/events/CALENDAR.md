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
| `ramadan` → `moonsighting` → `eid` | Umm al-Qura: Ramadan 1–28, Ramadan 29 – Shawwal 1, Shawwal 2–4 | `ramadan/` | 2027: Feb 8 10:00 → Mar 11 09:00 | Jan 25 | PK, DZ, IQ, EG, the Gulf; en-GB says "Ramzan" for PK/IN |
| `stpatricks` | Mar 14 – 17 | `st-patricks/` | 2027: Mar 14 10:00 → Mar 17 10:00 | Mar 7 | US, IE, GB |
| `nowruz` | Farvardin 1 – 7 | `nowruz/` | 2027: Mar 21 10:00 → Mar 27 10:00 | Mar 14 | KZ, UZ, KG (the name carries all three spellings) |

**Event times:** an event starts at 10:00Z, which is local midnight in UTC−10, so no zone east of Hawaii sees the
card before the look is on. It ends by 10:00Z on the look's last day, local midnight in UTC+14, so no zone sees it
after the look is off. The 31-day events end an hour short of Apple's cap.

**The moon-sighting days:** Pakistan and India begin Ramadan and Eid a day or two after Umm al-Qura (Saudi
Arabia). So on the days that may be either the last fast or Eid (Ramadan 29–30, Shawwal 1), the app says a line
that names neither, and "Eid Mubarak" waits for Shawwal 2.

**Next year:** Ramadan moves about 11 days earlier each year (2028: Jan 28; 2029: Jan 16), and the
app follows it on its own. The specs' dates don't, so re-date each one with `events.py update`
before resubmitting. The 2026 Christmas dates assume 1.6 is live by Nov 25. If it isn't, move
`publishStart` (and `eventStart` if needed) to after the release; never publish ahead of the build.

**Rules every event keeps:**
- The copy promises only the look and the greeting. Ramadan and Eid wear no villain costume, and
  their lines carry no jokes.
- Name ≤ 30, short ≤ 50, long ≤ 120 characters (Python `len`), in all 12 locales.
- ar-SA never addresses the reader as "you", so it stays gender-neutral. The fox keeps its local
  names (Phosphorfuchs, zorro fosforescente, …).
- Every translation here is a model draft. ar-SA and ru need a native read before submission
  (see the translation traps in the growth notes); the rest should have one.
- Art: textless stills from the screengrab harness with `-seasonalLook <look>`, 1920×1080 card
  and 1080×1920 details, kept in gitignored `marketing/events/<folder>/`.
- Apple shows up to 5 published events at once and holds up to 10 approved, so plan around that.
- Submission is Kev's click in App Store Connect. `events.py` makes DRAFTs only.

Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.7. The Halloween → impressions link is a
timing match (Apple reports no search terms); the other events' reach is a bet. Measure each one in
`metrics.py analytics fetch --name "App Store Discovery and Engagement Detailed"` and keep only the
ones that earn it.
