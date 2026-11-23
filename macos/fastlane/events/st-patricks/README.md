# "St Patrick's in the Lair": the St Patrick's event (in-app event, iPhone + iPad)

The look: `stpatricks` (Mar 14–17, local calendar): shamrock at rest, gold speaking, white thinking, tricolour orange listening. Greeting: "Happy St Patrick's Day from an AI made in Ireland!"
The "Seasonal looks" opt-out in Settings covers it, and nothing leaves the device. Force it for art or
checks with `-seasonalLook stpatricks`. The calendar logic is in `Sources/M1K3Avatar/SeasonalLook.swift`,
and why this event exists is in `../CALENDAR.md`.

**Gate:** the build that carries this look (1.6) must be live on the iOS App Store before the event
publishes (2027-03-07T10:00:00Z). Read `itunes.apple.com/lookup?id=6780230835` first. If the look isn't
live yet, move `publishStart` (and `eventStart` if needed): never publish ahead of the build.

Event dates: 2027-03-14T00:00:00Z → 2027-03-18T00:00:00Z. Deep link: `m1k3://event/st-patricks`.

## Copy (`event.json`; en-US below, the other eleven locales in its `localizations` table)

| Field | Cap | Text |
|---|---|---|
| name | 30 | St Patrick's in the Lair (24) |
| shortDescription | 50 | Shamrock green from an AI made in Ireland. (42) |
| longDescription | 120 | From Mar 14 to 17, the Phosphor Fox glows shamrock green and gold and wishes you a happy St Patrick's Day. Irish-made. (118) |

Counts are Python `len`. These are drafts by the model; ar-SA and ru need a native read before submission.
