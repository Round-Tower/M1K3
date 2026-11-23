# "Lunar New Year Glow": the Lunar New Year event (in-app event, iPhone + iPad)

The look: `lunarnewyear` (the Chinese calendar's New Year's Eve through the Lantern Festival, day 15, local days): vermilion red at rest, firecracker gold speaking, jade thinking, tangerine listening. Greeting: "Happy Lunar New Year! Wishing you luck and good health." It is never "Chinese New Year": the same day is Seollal in Korea and Tết in Vietnam. No zodiac animal anywhere (the animal changes every year; the copy shouldn't). en-GB's name carries "Tết" for Vietnam's storefront, ko says 설날 (Seollal), zh-Hans says 春节.

**It meets Ramadan every year from 2026 to 2031.** In the app, Lunar New Year's Eve and Day always keep their own look;
the rest of its fortnight yields to Ramadan and Eid, so the Ramadan event's "Through Ramadan" stays true. In 2027
Ramadan begins on Lunar day 3 (Feb 8), so the look runs **Feb 5 – Feb 7** only (Eve, New Year's Day, day 2), and so
does this event. The copy names no length. Years when it runs longer: 2029 (Eve and Day Feb 12–13, then days 6–15,
Feb 18–27, after Eid) and 2030 (Feb 2–3, then Feb 8–17). A two-day card may not earn a slot among Apple's five; Kev's call.

The "Seasonal looks" opt-out in Settings covers it, and nothing leaves the device. Force it for art or
checks with `-seasonalLook lunarnewyear`. The calendar logic is in `Sources/M1K3Avatar/SeasonalLook.swift`,
and why this event exists is in `../CALENDAR.md`.

**Gate:** the build that carries this look (1.6 or later) must be live on the iOS App Store before the event
publishes (2027-01-22T10:00:00Z). Read `itunes.apple.com/lookup?id=6780230835` first. If the look isn't
live yet, move `publishStart` (and `eventStart` if needed): never publish ahead of the build.

Event: 2027-02-05T10:00:00Z → 2027-02-07T10:00:00Z. It starts at 10:00Z, local midnight in UTC−10, so no zone east of
Hawaii sees the card before the look is on. It ends by 10:00Z on the look's last day, local midnight in UTC+14,
so no zone sees the card after the look is off. Deep link: `m1k3://event/lunar-new-year`.

## Copy (`event.json`; en-US below, the other eleven locales in its `localizations` table)

| Field | Cap | Text |
|---|---|---|
| name | 30 | Lunar New Year Glow (19) |
| shortDescription | 50 | Lucky red and gold for the new year. (36) |
| longDescription | 120 | For Lunar New Year, the Phosphor Fox glows red and gold and wishes you luck and good health. All on your device. (112) |

Counts are Python `len`. These are drafts by the model: every non-English locale is **native read owed**, ar-SA and
ru before submission, and zh-Hans and ko first among the rest (they carry this event's reach). zh-Hant (Taiwan,
Hong Kong) and vi aren't in the 12-locale table; adding them is the next reach lever, and Kev's call.

Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.7 — the window is read off Foundation's Chinese calendar and
pinned by tests; the precedence against Ramadan is a judgement call, the copy is a model draft, and the reach is a bet
to measure. Prior: Unknown (new file).
