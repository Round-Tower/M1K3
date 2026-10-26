//
//  ChatEvalFixtures+GroundedLong.swift
//  M1K3Eval
//
//  grounded-long: a whole document, not a sentence. grounded-Q seeds one line, so its turns
//  prefill ~160 tokens and never reach the grounding budget (the 2026-10-25 Release baseline);
//  nothing measured what the 1100-token budget buys. Each doc here is six headed sections of
//  ~one chunk each (`DocumentChunker.targetChars`), sized so the top five hits land near 1100.
//  In the first wired run (2026-10-26) they came in at or under it — no "grounding cap" line
//  fired — so 1100 is the full-retrieval arm and 400 the first that cuts.
//
//  The questions are built to break a tight budget in different ways: two facts in two sections
//  (names, a decision and its deadline, a date then a hotel), a number in its section's last
//  sentence (the tail `GroundingBudget` truncates first), near-miss place names (what TokenGate,
//  arXiv 2610.26754, loses first under aggressive pruning), and nothing to find at all.
//  Run them through the budget arm: `--kinds grounded-long --app-arg=-groundingBudget --app-arg=400`,
//  with `--router dispatch` as the app routes. The harness gives these turns the app's real corpus tools
//  over the seeded store (web tools stay stubbed), and each score names the tools its turn ran.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-26, Confidence 0.7 (the documents are invented and the
//  section sizes are checked by a test; whether they rank the way a real document does is
//  what the first run shows). Prior: none (new file).
//  Review: Kev + claude-opus-5-5, 2026-10-26 — the "overfill" claim was wrong: the first wired run
//  logged no cap at 1100. The header now says so; "don't specify" (Big's abstention) joins the markers.
//  Review: Kev + claude-opus-5-5, 2026-10-26 — the cross arm: three world questions over keyword-sharing docs,
//  the false-steer check `ToolDispatch.documentCorrected` owes (challenger). Confidence 0.7.
//

import Foundation

public extension ChatEvalFixtures {
    static let groundedLong: [ChatEvalFixture] = [
        .init(
            id: "long-incident-names", kind: .groundedLong,
            prompt: "Who first reported the leak on Press Line 4, and who signed off the repair?",
            seedDoc: GroundedLongDocs.incidentReport,
            expectation: .init(mustContainAll: ["brennan", "wilk"], minChars: 10, wholeWordFacts: true)
        ),
        .init(
            id: "long-hub-torque", kind: .groundedLong,
            prompt: "What torque do the hub nuts on the trailer axle take?",
            seedDoc: GroundedLongDocs.axleManual,
            // The figure WITH the manual's unit: a generic web spec ("120 and 145 ft-lbs", the first
            // wired run's lookup_fact answer) carries the number by coincidence.
            expectation: .init(
                mustContainAny: ["145 nm", "145nm", "145 n·m", "145 n m", "145 newton"], minChars: 5
            )
        ),
        .init(
            id: "long-itinerary-hop", kind: .groundedLong,
            prompt: "Where am I sleeping the night of my Galway talk?",
            seedDoc: GroundedLongDocs.itinerary,
            expectation: .init(mustContainAny: ["doolin"], minChars: 5, wholeWordFacts: true)
        ),
        .init(
            id: "long-sample-place", kind: .groundedLong,
            prompt: "Where was the second batch of water samples collected?",
            seedDoc: GroundedLongDocs.surveyNotes,
            expectation: .init(mustContainAny: ["ballyvourney"], minChars: 5, wholeWordFacts: true)
        ),
        .init(
            id: "long-lease-decision", kind: .groundedLong,
            prompt: "What did the board decide about the Cork office lease, and by when do we have to tell "
                + "the landlord?",
            seedDoc: GroundedLongDocs.boardMinutes,
            expectation: .init(
                mustContainAny: ["14 march", "march 14", "14th march", "march 14th", "14th of march"],
                mustContainAll: ["renew"], minChars: 10
            )
        ),
        .init(
            id: "long-absent", kind: .groundedLong,
            prompt: "What's the warranty period on the trailer axle?",
            seedDoc: GroundedLongDocs.axleManual,
            // The manual never mentions a warranty: a good brain says so rather than inventing a term.
            // Abstain phrases, whole words: a bare "not" (ground-absent's marker) is found in the
            // seeded doc's own title, "Notes", and in the manual's "do not weld", so an invented
            // "24 months (Notes)" passed it — and this is the cell a tight budget pushes to invent.
            expectation: .init(
                mustContainAny: [
                    "doesn't mention", "does not mention", "no mention", "not mentioned", "doesn't say",
                    "does not say", "doesn't cover", "does not cover", "doesn't include", "doesn't list",
                    "couldn't find", "can't find", "could not find", "cannot find", "no warranty",
                    "no information", "isn't in", "is not in", "not in the", "don't have", "do not have",
                    "don't see", "not covered", "not specified", "not stated",
                    // The first wired run's honest abstentions (2026-10-26) the list above missed.
                    "doesn't state", "does not state", "doesn't explicitly", "doesn't specify",
                    "does not specify", "isn't listed", "not listed", "there isn't", "there is no",
                    "there's no", "don't specify", "doesn't actually",
                ],
                minChars: 5, wholeWordFacts: true
            )
        ),
        // The cross arm (2026-10-26): world questions over a seeded doc that shares their words. A kept
        // document turns a lookup_fact pick into a plain turn over it (`ToolDispatch.documentCorrected`);
        // these pass only if the brain still answers the world, not the doc. The survey notes name the
        // River Sullane by Cork; the river through the city is the Lee. The limit: all three are famous
        // facts, so the arm can't show the cost on one the brain doesn't know.
        .init(
            id: "long-cross-tyre", kind: .groundedLong,
            prompt: "Who invented the pneumatic tyre?",
            seedDoc: GroundedLongDocs.axleManual,
            expectation: .init(mustContainAny: ["dunlop", "thomson"], minChars: 5, wholeWordFacts: true)
        ),
        .init(
            id: "long-cross-river", kind: .groundedLong,
            prompt: "Which river flows through the centre of Cork city?",
            seedDoc: GroundedLongDocs.surveyNotes,
            expectation: .init(mustContainAny: ["lee"], minChars: 5, wholeWordFacts: true)
        ),
        .init(
            id: "long-cross-galway", kind: .groundedLong,
            prompt: "Which ocean is Galway Bay part of?",
            seedDoc: GroundedLongDocs.itinerary,
            expectation: .init(mustContainAny: ["atlantic"], minChars: 5, wholeWordFacts: true)
        ),
    ]
}

/// The seeded documents. Each section is one chunk (under `DocumentChunker.targetChars`), its heading
/// in the chunker's `3 Title` form.
enum GroundedLongDocs {
    static let incidentReport = """
    1 Summary
    On the night shift of 3 October a hydraulic leak on Press Line 4 stopped production for six hours. Fluid \
    escaped from the lower manifold of the main ram, pooled under the bolster and reached the drainage channel \
    beside the line. Nobody was injured. The line was isolated, cleaned and returned to service the next \
    afternoon after the manifold seal and one supply hose were replaced. This report records how the leak was \
    found, what was done, who did it and what changes follow. It was compiled from the shift log, the \
    maintenance work order and interviews with the people on the floor that night, and it was reviewed by the \
    plant engineering team before release. The line had run without a hydraulic fault since its last overhaul in \
    the spring, and the shift had been running the door panel order at full rate when the leak started. The \
    timings in this report are from the shift log and the press controller's event history, which agree to \
    within a minute.
    2 Discovery
    At 01:40 the press operator, Aoife Brennan, noticed a sheen of fluid spreading from under Press Line 4 while \
    loading blanks, and saw the pressure gauge on the main ram drifting below its normal band. She stopped the \
    press with the cycle stop, not the emergency stop, so the ram parked at the top of its stroke, and called it \
    in on the shift radio. She was the first to report the leak and the first to see it. She then put out the \
    yellow spill boards from the line-side station and kept the forklift lane clear until help arrived, and her \
    timeline in the shift log is the one this report uses. The shift log shows the press had completed its last \
    good cycle at 01:38, two minutes before she raised the alarm. Her quick stop meant no blank was trapped in \
    the die and the tooling was undamaged, which saved several hours on the restart.
    3 Shift response
    The shift supervisor, Ciarán Byrne, arrived at 01:46 and took charge of the area. He confirmed the press was \
    stopped, ordered the hydraulic power unit isolated and locked out, and moved the two neighbouring lines to a \
    reduced rate so their crews could help with the spill. He phoned the on-call maintenance technician at \
    01:52. He also logged the downtime against the line and told the planning office that the morning's orders \
    for the door panels would slip. The spill kit from bay C was used to contain the fluid; roughly 40 litres \
    were recovered into drums and labelled for disposal by the waste contractor. He kept a written timeline of \
    who entered the area and when, so the lockout could be checked at handover. Two operators from the \
    neighbouring line helped lay absorbent socks along the drainage channel, and the channel was blocked off \
    before fluid reached the main drain.
    4 Investigation
    The on-call technician, Marta Nowak, arrived at 02:30 and traced the leak to the lower manifold of the main \
    ram. The manifold seal had extruded at one corner and a braided supply hose beside it showed abrasion where \
    it rubbed a bracket. She photographed both, took the fluid temperature and pressure readings from the unit's \
    log, and found the system had run about eight degrees hotter than normal for the previous week. Her view, \
    recorded on the work order, is that the heat softened the seal and the vibration from the loose bracket wore \
    the hose. The hydraulic supplier's field engineer was asked to confirm the seal material is right for the \
    fluid. The previous inspection, three weeks earlier, had recorded the bracket as secure, so the loosening \
    happened since then. A sample of the fluid was sent for analysis to rule out contamination or water in the \
    oil as a cause of the higher temperature.
    5 Repair
    The repair was carried out on the day shift by Marta Nowak and a second fitter. They replaced the manifold \
    seal with the uprated compound the supplier recommended, replaced the abraded hose, re-clamped the bracket \
    with a rubber-lined clip and flushed the circuit. The unit's cooler fins were cleaned, which brought the \
    fluid temperature back into its normal band on the test run. The press was cycled empty for thirty minutes \
    and then on scrap blanks for twenty while the pressure gauge was watched. No weeping was seen at the \
    manifold or the new hose, and the drip tray under the ram stayed dry through both runs and the following \
    hour. Parts came from the stores held for this press, so there was no wait for delivery. The old seal and \
    hose were bagged and tagged for the supplier to examine, and the fluid lost was replaced with fresh fluid \
    from a sealed drum to the level on the sight glass.
    6 Close-out
    The line was handed back to production at 14:10 on 4 October. The repair was signed off by the maintenance \
    manager, Tomasz Wilk, after he inspected the manifold, read the test-run pressure trace and checked the \
    lockout had been removed correctly. His sign-off is on the work order with the parts used. Three actions \
    follow: add the cooler fins to the weekly checklist, fit rubber-lined clips on every press with the same \
    bracket, and review the seal material across the other three lines. The waste contractor collected the drums \
    on 6 October, and this report closes the incident in the safety register. The planning office was told the \
    line was back, and the delayed door panel order was finished on the following shift. The incident was \
    discussed at the weekly safety meeting, where the quick stop and the spill response were noted as good \
    practice for the other lines.
    """

    static let axleManual = """
    1 About this manual
    This manual covers routine service of the single and tandem braked axles fitted to the T-series general \
    purpose trailers, both the 2,000 kg and 3,500 kg gross weight versions. It is written for a competent owner \
    or a workshop with ordinary hand tools, a calibrated torque wrench, axle stands rated for the trailer's \
    weight and a wheel brace. Service intervals are given in kilometres or months, whichever comes first. Always \
    work on level, firm ground with the trailer unhitched, the jockey wheel locked and the opposite wheels \
    chocked. Never work under a trailer supported only by a jack. Part numbers are listed at the back of the \
    manual. Read each section through before starting work, and replace any fastener that is damaged or corroded \
    rather than reusing it. If the trailer has been in an accident or has hit a kerb hard, have the axle \
    alignment checked by a workshop before relying on any of the checks below.
    2 Wheels and tyres
    Check tyre pressures cold before every journey; the correct pressure is on the plate on the drawbar and \
    differs between the two gross weight versions. Inspect tyres for cuts, bulges and uneven wear, which usually \
    points to a bent axle or a seized brake. Tread depth must be at least 1.6 mm across the central three \
    quarters of the tread. When refitting a wheel, clean the mating faces of the wheel and the hub, start every \
    wheel nut by hand and tighten them in a star pattern. Wheel nuts are torqued to 110 Nm, then re-checked \
    after the first 50 km, because the wheel beds in on the hub and the nuts can lose tension. Spare wheels must \
    be the same size, load rating and offset as the road wheels, and the spare should be checked at the same \
    time as the others. Do not mix radial and cross-ply tyres on the same axle, and replace tyres that are more \
    than six years old whatever the tread depth.
    3 Hubs and bearings
    The hub bearings are sealed, pre-greased cartridge units that need no regreasing, but they must be checked \
    for play every 5,000 km or twelve months. With the wheel off the ground, grip it at the top and bottom and \
    rock it: any movement you can feel or hear is too much, and the bearing must be replaced, not adjusted. Spin \
    the wheel and listen for rumbling. To replace a bearing, remove the dust cap, the split pin and the castle \
    nut, pull the hub, and press the new cartridge in using a drift on its outer race only. Fit a new split pin \
    every time and never reuse the old one. Check the hub seals for grease weeping at the same time, and replace \
    a seal that is wet. Clean the stub axle and inspect it for scoring before the new bearing goes on, because a \
    scored stub will destroy a new bearing quickly. Rotate the hub while tightening so the bearing seats evenly. \
    Refit the hub, then torque the hub nuts to 145 Nm in a star pattern.
    4 Brakes
    The brakes are cable-operated drum brakes driven by the overrun coupling. Adjust them every 3,000 km or six \
    months, and whenever the handbrake lever travels more than half way before the brakes bite. Adjust at the \
    wheels first: turn the adjuster on the back plate until the wheel locks, then back it off until the wheel \
    turns freely with only a light drag. Then take the slack out of the main cable at the compensator, leaving a \
    little free play so the brakes are not dragging when the coupling is extended. Brake caliper mounting bolts \
    on the disc-braked option are torqued to 85 Nm. Replace the brake shoes when the lining is below 2 mm. After \
    any brake work, test the brakes at low speed in a safe place before towing on the road. The breakaway cable \
    must be attached to the towing vehicle every time the trailer is hitched, and replaced if it is frayed or \
    kinked, because it applies the brakes if the trailer separates.
    5 Suspension
    The axles use rubber torsion suspension, which has no springs or dampers to service but does age. With the \
    trailer unladen on level ground, measure from the centre of each hub to the underside of the chassis rail \
    and compare the two sides; a difference of more than 15 mm means the rubber in one arm has settled and the \
    axle beam should be replaced as a unit. Check the axle mounting bolts for tightness at every service, look \
    for cracking around the mounting brackets, and look for rust where the beam meets the chassis. Do not weld \
    or drill the axle beam: the rubber inserts are bonded inside and are destroyed by heat. Grease the coupling \
    head and the drawshaft bellows at the same time, because a dry coupling feels like a suspension fault on the \
    road. Overloading is the most common cause of early settling, so check the load against the plate rather \
    than the volume of the trailer bed.
    6 Lighting and electrics
    Check every lamp before every journey with the trailer plugged in: side lights, brake lights, indicators, \
    the fog lamp, the reversing lamp where fitted, and the number plate lamp. Most faults are a corroded pin in \
    the plug or socket; clean both with a contact cleaner and a small brush, and smear the pins with a little \
    dielectric grease. The earth wire runs to a stud on the drawbar and must be bright metal under the ring \
    terminal. When replacing a lamp unit, use the same type and rating so the towing vehicle's bulb-out warning \
    still works. Coil the cable on the bracket provided when unhitched so it does not drag on the road. If a \
    lamp works with the trailer on one car and not another, the fault is usually in the car's towing socket \
    rather than the trailer. A short test lead with a known good socket is the quickest way to tell the two \
    apart at the roadside.
    """

    static let itinerary = """
    1 Trip overview
    The trip runs from Monday 10 November to Friday 14 November, starting and ending at Shannon Airport. There \
    are three speaking engagements on the trip: one in Limerick, one in Galway and one in Ennis, plus a half-day \
    workshop with a partner school in Clare. A hire car is booked for the whole week and is collected at the \
    airport desk on arrival. Most of the driving is under ninety minutes a day, but the Galway leg on Wednesday \
    is the longest and leaves early. Everything below is confirmed unless it is marked as pending. Keep the \
    booking references in the last section to hand, because two of the hotels ask for them at check-in. The \
    diary below is in date order, then grouped by topic in the later sections. Times are local Irish time. The \
    organisers of each event have a copy of the relevant part, and anything that changes will be updated here \
    first and then emailed to them.
    2 Talks and events
    Monday afternoon is the opening talk at the University of Limerick, at 15:00 in the main lecture hall, on \
    assistive technology in the classroom. Tuesday is the Clare workshop at the partner school in Ennistymon, \
    from 09:30 to 13:00, with the afternoon free. The Galway talk is on Wednesday 12 November at 18:30 at the \
    Galway City Library, on reading support tools for dyslexic adults, with questions afterwards and a short \
    reception. Thursday morning is the Ennis talk at the Glór theatre at 11:00, the last formal event. Friday \
    has no events; the flight home is in the early afternoon. Slides for all three talks are already on the \
    laptop and on the memory stick. Each organiser has asked for the talk to run about forty five minutes with \
    fifteen for questions, except the Galway talk, which is part of the library's evening series and runs a \
    little longer because of the reception afterwards. A clicker and an HDMI adapter are in the laptop bag.
    3 Travel
    Monday: collect the car at Shannon and drive to Limerick, about thirty minutes. Tuesday: Limerick to \
    Ennistymon for the workshop, about an hour and a quarter, and then the afternoon is free on the coast. \
    Wednesday: drive to Galway in the afternoon, about an hour and forty minutes through the Burren, arriving in \
    good time for the evening talk. After the reception, the plan is to drive back south rather than stay in the \
    city, because Thursday's talk is in Ennis. Thursday: drive to Ennis for the morning, then back to the coast. \
    Friday: return the car at Shannon by noon. Fuel the car on Thursday evening so there is no stop needed on \
    the Friday. The roads across the Burren are narrow and slow in the dark, so allow extra time for the drive \
    back after the Galway reception. The hire car has a built-in navigation system, but the phone's offline maps \
    are downloaded as well in case the signal drops in the hills.
    4 Accommodation
    Monday night, 10 November: the Savoy Hotel, Limerick, one night, breakfast included. Tuesday night, 11 \
    November: Hotel Doolin, Doolin, two nights, so Tuesday and Wednesday nights are both in Doolin, breakfast \
    included and a late check-in arranged for the Wednesday because of the drive back from the city. Thursday \
    night, 13 November: the Old Ground Hotel, Ennis, one night. The g Hotel in Galway was considered for \
    Wednesday and turned down because of the early start on Thursday. All rooms are paid in advance except the \
    Old Ground, which is paid on departure. Parking is free at all three hotels, though Doolin's car park is \
    small. Late check-in at Doolin is confirmed by email until midnight, and the night porter has the booking. \
    If the reception in Galway runs past nine, ring the hotel to say so. Breakfast at the Old Ground starts at \
    seven, which leaves plenty of time before the Ennis talk on Thursday.
    5 Meals and free time
    Dinner on Monday is with the Limerick organisers at a restaurant near the campus, booked for 19:30. Tuesday \
    afternoon is free; the Cliffs of Moher walk from Doolin is about two hours return if the weather holds, and \
    the ferry to Inis Oírr is an option if it is calm. Wednesday's reception at the library has food, so no \
    dinner is booked that night. Thursday lunch is with the Ennis organisers after the talk. Bring walking boots \
    and a rain jacket, because the coast path is exposed. The hotels in Doolin and Ennis both have restaurants \
    that take walk-ins, and there is a good café beside the library in Galway for the afternoon. Doolin has a \
    few pubs with traditional music most evenings, which is an option on Tuesday. There is no need to book for \
    lunch on Tuesday or Friday. Water and snacks for the Wednesday drive are worth picking up in Ennistymon on \
    Tuesday, because the shops on the Burren road close early.
    6 Bookings and contacts
    Flight references and the hire car confirmation are in the travel folder on the laptop. The Savoy booking is \
    under the organisers' account and needs no reference at check-in. Hotel Doolin's reference is DL-58213 and \
    they ask for it at check-in. The Old Ground's reference is OG-11947. The Galway City Library contact is the \
    events coordinator, who is the person to ring if the drive runs late; the number is in the event email. The \
    Limerick organiser and the partner school head are both in the phone's contacts under the trip label. Travel \
    insurance covers the hire car's excess, and the policy document is in the same folder. If anything goes \
    wrong with the car, the hire company's roadside number is on the key fob and in the confirmation email. The \
    organisers of the Limerick and Ennis talks have both offered a lift if needed. Receipts for fuel and parking \
    should be kept for the expenses claim at the end of the trip.
    """

    static let surveyNotes = """
    1 Purpose
    These notes record the autumn round of the river water quality survey, which samples three upland catchments \
    in Munster and Connacht each October for nitrate, phosphate, dissolved oxygen and conductivity. The survey \
    compares this year's readings with the five years of earlier rounds and looks for any change after the new \
    slurry spreading rules came in. Samples are collected in batches, one batch per catchment, each from five \
    sites along a short stretch of river, and the batches are numbered in the order they were taken. The \
    laboratory results are in the attached spreadsheet; these notes cover the field side: where, when, by whom \
    and under what conditions. The field protocol is the same as in earlier years so that the readings stay \
    comparable, and any change to a site or a method is recorded in the section for the batch where it happened. \
    Where a reading was repeated, both values are kept on the sheet and the reason is noted.
    2 Batch one
    The first batch was collected on 7 October at Ballyvaughan, County Clare, from the small river that drains \
    the north side of the Burren into Galway Bay. Five sites were sampled between the road bridge and the shore, \
    starting at the upstream site at 09:15. Flow was low after a dry fortnight, and the water was clear with a \
    slight brown tint from the bog. Conductivity was high, as it always is on the limestone here. One site was \
    moved twenty metres downstream because a fallen tree blocked access to the usual spot. The samples were kept \
    in the cool box and reached the laboratory that evening, within the six-hour limit for the phosphate test. \
    The upstream site sits just below a farm track ford, so it was sampled before any vehicle crossed. Water \
    temperature was 11 degrees. A dipper was seen at the second site, which is a good sign for the river. \
    Nitrate in the field kit was low at every site, lower than last October's readings.
    3 Batch two
    The second batch was collected on 9 October at Ballyvourney, County Cork, on the upper River Sullane, which \
    runs through the Gaeltacht on the edge of the Derrynasaggart Mountains. Five sites were sampled between the \
    village and the confluence with the small tributary below it. Rain overnight had raised the flow and the \
    water was cloudy at the two lower sites, which was noted on the labels because sediment can raise the \
    phosphate reading. Dissolved oxygen was good everywhere. The landowner at the third site gave permission on \
    the morning and asked for a copy of the results, which will be posted when the laboratory report is back. \
    Access to the lowest site is through a field gate that is now locked, so the landowner's permission each \
    year matters. Water temperature was 10 degrees. The sediment at the lower sites was photographed for the \
    record, and the laboratory was asked to run a filtered phosphate test as well as the usual one.
    4 Batch three
    The third batch was collected on 11 October at Ballyvolane, on the northern edge of Cork city, from a small \
    urban stream that runs through a culvert for part of its length. This catchment was added to the survey \
    three years ago as an urban comparison for the two rural ones. Five sites were sampled, two of them in the \
    open channel above the culvert and three below it. There was a strong smell of sewage at the fourth site and \
    a grey film on the stones, which was reported to the local authority's environment section the same day. \
    Litter was heavy below the culvert outfall, as in previous years. Water temperature was 13 degrees, the \
    warmest of the round, which is normal for a stream that runs past buildings and roads. The open channel \
    above the culvert had reasonable oxygen, which drops below it every year. The local authority acknowledged \
    the report and said an inspection is planned for this month.
    5 Conditions and equipment
    All three batches were taken by the same two-person team using the same meter, which was calibrated each \
    morning against the standard solutions and logged in the calibration sheet. Air temperatures ranged from 9 \
    to 14 degrees. The weather was dry for batch one, wet overnight before batch two and dry again for batch \
    three. Bottles were rinsed three times with river water before filling, labelled at the bank with the site \
    code, date and time, and kept below eight degrees in the cool box. Chain of custody forms were signed at \
    handover to the laboratory. One spare meter probe was carried and was not needed this year. Field sheets \
    were photographed at the end of each day and backed up, in case a sheet was lost or damaged in the rain. The \
    team followed the lone working rules, carried a first aid kit and checked in with the office at the end of \
    each field day, as the survey's safety plan requires.
    6 Early observations
    The laboratory results are not complete, but the field readings already show the usual pattern: the Clare \
    river is clean but hard, the Cork upland river is soft and well oxygenated with some sediment after rain, \
    and the urban stream is the worst of the three, with low oxygen below the culvert. Nitrate in the field kits \
    was lower than last October at the two rural catchments, which would fit the new spreading rules, but one \
    year is not a trend. The urban stream's sewage problem is a known issue and has been raised again. A fuller \
    comparison will follow when the spreadsheet is finished and checked. The spring round is planned for April \
    and will use the same sites and the same team where possible. The landowner contacts and site access notes \
    have been updated in the site register, and the locked gate at the Cork site has been flagged so permission \
    can be asked well before the spring visit.
    """

    static let boardMinutes = """
    1 Attendance and apologies
    The quarterly board meeting was held on 20 February in the Dublin office and online. Present in the room \
    were the chair, the chief executive, the finance director and three non-executive directors; two more joined \
    online. Apologies were received from the head of people, whose report was taken as read. The company \
    secretary took the minutes. The chair confirmed the meeting was quorate and that no new conflicts of \
    interest had been declared since the last meeting. The minutes of the November meeting were approved without \
    changes, and the action log was reviewed: four of the six actions are closed and two are carried forward. \
    The papers were circulated a week in advance through the board portal, and directors confirmed they had read \
    them. The chair reminded the board that the meeting would run until one o'clock and that the Cork lease item \
    needed a decision today, because of the notice period in the current lease.
    2 Finance report
    The finance director presented the results for the third quarter. Revenue was eight per cent ahead of the \
    same quarter last year, driven by the schools contracts, while costs were slightly over budget because of \
    the new hires in support. Cash is healthy at just over five months of operating costs. The auditors' \
    management letter raised two minor points on expense approvals, both now addressed. The board noted the \
    report and asked for a forecast of the year-end position at the next meeting, including the effect of the \
    Cork lease decision below and of the salary review, before any further hiring is approved. The board also \
    discussed the pricing of the new schools tier and agreed to keep it unchanged until the pilots end. The \
    finance director confirmed that the grant income from the enterprise agency is now received in full, and \
    that the second tranche of the innovation grant is expected in the summer.
    3 Product and operations
    The chief executive reported that the reading app's new release went out in January with good feedback from \
    teachers, and that support tickets fell after the onboarding changes. Two large school groups in the \
    north-west are in a pilot that ends in April. The data protection review found no issues; the annual \
    penetration test is booked for May. Staff numbers are 41, up from 36. The Galway office is now full and the \
    team there is asking for meeting rooms to be shared with the co-working space next door. The board thanked \
    the team for the release and asked for a short summary of the pilot results in May. The chief executive \
    noted that recruitment for the two senior engineering roles is under way, with interviews in March. A \
    director asked about the accessibility audit of the app; the chief executive confirmed it is booked with an \
    external firm and that its findings will be shared with the board in full.
    4 Cork office lease
    The Cork office lease expires on 30 June. Three options were presented: leave and move the Cork team to \
    remote working, move to a smaller unit in the city centre, or renew the existing lease. The finance \
    director's paper showed the revised rent offered by the landlord is eleven per cent lower than the current \
    rent in return for a longer term, and that moving would cost about as much as a year of the saving once \
    fit-out is counted. After discussion the board decided to renew the Cork lease for three years at the \
    revised rent, with a break clause at two years, and asked the finance director to negotiate the break clause \
    terms. The Cork team's head joined for this item and spoke in favour of staying, because the team has grown \
    and the location suits the staff who commute by train. A non-executive director asked whether the lower rent \
    was fixed for the whole term, and the finance director confirmed it was, with no rent review until the break \
    date.
    5 Risk register
    The board reviewed the top five risks. The dependence on two school group contracts remains the largest \
    commercial risk, and the pilot in the north-west is part of the response. The cyber risk is unchanged and \
    the penetration test in May will be reported back. A new risk was added on key-person dependence in the \
    engineering team, with a plan for documentation and cross-training to be presented by the chief executive. \
    The currency risk on the UK contracts was lowered after the hedging put in place last year. The board was \
    content that the register reflects the main risks and that the owners and actions are clear. Directors asked \
    for the risk owners to attend the next meeting for their items, so each risk can be discussed with the \
    person managing it. The audit committee chair noted the committee will review the register in detail in \
    April and report to the board in May.
    6 Actions and next meeting
    Actions agreed: the finance director to give the landlord, Harrington Estates, written notice of the \
    decision to renew the Cork lease by 14 March, which is the notice date in the current lease, and to report \
    back on the break clause; the chief executive to present the key-person plan in May; the company secretary \
    to circulate the revised risk register within two weeks; the finance director to bring the year-end \
    forecast. The next meeting is on 22 May in the Galway office, which is the first time the board will meet \
    there. The meeting closed at 13:05. The chair thanked the Cork team's head for attending. Any other \
    business: the company secretary noted that the annual return is due in April and is on track, and the chair \
    reminded directors to complete the board effectiveness survey before the next meeting.
    """
}
