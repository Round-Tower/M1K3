# "Ramadan Lanterns": the Ramadan & Eid al-Fitr event (in-app event, iPhone + iPad)

The look: `ramadan` (Umm al-Qura month 9) then `eid` (Shawwal 1–3): one palette, lantern gold at rest, warm white speaking, moonlit indigo thinking, tile turquoise listening. Greetings: "Ramadan Kareem. I'm here whenever you need me, day or night." then "Eid Mubarak! Wishing you and yours a joyful Eid." No villain costume, no jokes.
The "Seasonal looks" opt-out in Settings covers it, and nothing leaves the device. Force it for art or
checks with `-seasonalLook ramadan`. The calendar logic is in `Sources/M1K3Avatar/SeasonalLook.swift`,
and why this event exists is in `../CALENDAR.md`.

**Gate:** the build that carries this look (1.6) must be live on the iOS App Store before the event
publishes (2027-01-25T10:00:00Z). Read `itunes.apple.com/lookup?id=6780230835` first. If the look isn't
live yet, move `publishStart` (and `eventStart` if needed): never publish ahead of the build.

Event dates: 2027-02-08T00:00:00Z → 2027-03-11T00:00:00Z. Deep link: `m1k3://event/ramadan`.

## Copy (`event.json`; en-US below, the other eleven locales in its `localizations` table)

| Field | Cap | Text |
|---|---|---|
| name | 30 | Ramadan Lanterns (16) |
| shortDescription | 50 | A lantern-gold glow and a warm hello. (37) |
| longDescription | 120 | Through Ramadan and Eid al-Fitr, the Phosphor Fox glows lantern gold and greets you: Ramadan Kareem, then Eid Mubarak. (118) |

Counts are Python `len`. These are drafts by the model; ar-SA and ru need a native read before submission.
