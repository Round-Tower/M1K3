# "Ramadan Lanterns": the Ramadan & Eid al-Fitr event (in-app event, iPhone + iPad)

The look: one lantern palette (gold at rest, warm white speaking, moonlit indigo thinking, tile turquoise listening) across three looks on the Umm al-Qura calendar: `ramadan` (days 1–28, "Ramadan Kareem. I'm here whenever you need me, day or night."), `moonsighting` (Ramadan 29–30 and Shawwal 1, "Wishing you and yours peace and blessings.": Pakistan and India sight the moon a day or two after Saudi Arabia, so on these days either Ramadan or Eid may be true), then `eid` (Shawwal 2–4, "Eid Mubarak! Wishing you and yours a joyful Eid."). No villain costume, no jokes. en-GB's name carries "Ramzan", the spelling used in Pakistan and India.

The "Seasonal looks" opt-out in Settings covers it, and nothing leaves the device. Force it for art or
checks with `-seasonalLook ramadan`. The calendar logic is in `Sources/M1K3Avatar/SeasonalLook.swift`,
and why this event exists is in `../CALENDAR.md`.

**Gate:** the build that carries this look (1.6) must be live on the iOS App Store before the event
publishes (2027-01-25T10:00:00Z). Read `itunes.apple.com/lookup?id=6780230835` first. If the look isn't
live yet, move `publishStart` (and `eventStart` if needed): never publish ahead of the build.

Event: 2027-02-08T10:00:00Z → 2027-03-11T09:00:00Z. It starts at 10:00Z, local midnight in UTC−10, so no zone east of
Hawaii sees the card before the look is on. It ends by 10:00Z on the look's last day, local midnight in UTC+14,
so no zone sees the card after the look is off. Deep link: `m1k3://event/ramadan`.

## Copy (`event.json`; en-US below, the other eleven locales in its `localizations` table)

| Field | Cap | Text |
|---|---|---|
| name | 30 | Ramadan Lanterns (16) |
| shortDescription | 50 | A lantern-gold glow and a warm hello. (37) |
| longDescription | 120 | Through Ramadan and Eid al-Fitr, the Phosphor Fox glows lantern gold and greets you: Ramadan Kareem, then Eid Mubarak. (118) |

Counts are Python `len`. These are drafts by the model; ar-SA and ru need a native read before submission.
