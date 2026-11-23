# "Nowruz · Nauryz · Navruz": the Nowruz · Nauryz · Navruz event (in-app event, iPhone + iPad)

The look: `nowruz` (Farvardin 1–7 of the Persian calendar): blossom pink at rest, spring sun speaking, sky thinking, sabzeh green listening. Greeting: "Happy Nowruz! A new spring, a fresh start." The name carries all three spellings, because KZ and UZ index en-GB only.

The "Seasonal looks" opt-out in Settings covers it, and nothing leaves the device. Force it for art or
checks with `-seasonalLook nowruz`. The calendar logic is in `Sources/M1K3Avatar/SeasonalLook.swift`,
and why this event exists is in `../CALENDAR.md`.

**Gate:** the build that carries this look (1.6) must be live on the iOS App Store before the event
publishes (2027-03-14T10:00:00Z). Read `itunes.apple.com/lookup?id=6780230835` first. If the look isn't
live yet, move `publishStart` (and `eventStart` if needed): never publish ahead of the build.

Event: 2027-03-21T10:00:00Z → 2027-03-27T10:00:00Z. It starts at 10:00Z, local midnight in UTC−10, so no zone east of
Hawaii sees the card before the look is on. It ends by 10:00Z on the look's last day, local midnight in UTC+14,
so no zone sees the card after the look is off. Deep link: `m1k3://event/nowruz`.

## Copy (`event.json`; en-US below, the other eleven locales in its `localizations` table)

| Field | Cap | Text |
|---|---|---|
| name | 30 | Nowruz · Nauryz · Navruz (24) |
| shortDescription | 50 | A spring glow and a new-year hello. (35) |
| longDescription | 120 | From Mar 21, for the new year's first week, the Phosphor Fox wears blossom pink and spring sun. Happy Nowruz! (109) |

Counts are Python `len`. These are drafts by the model; ar-SA and ru need a native read before submission.
