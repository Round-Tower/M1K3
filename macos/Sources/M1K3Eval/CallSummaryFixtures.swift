//
//  CallSummaryFixtures.swift
//  M1K3Eval
//
//  Synthetic calls for CallSummaryEval, written for the job: every name,
//  company and number is invented. Each call leans on one way a summary goes
//  wrong. The standup counts owners, the sales call corrects a number mid-call,
//  the rescheduling call retracts a day, the catch-up has no work in it at all
//  (so any action item is invented), the landlord call is a one-sided
//  appointment, and the long planning call is bigger than Mini's whole window,
//  with the facts at the start, the middle and the end.
//
//  Traps are things no correct summary would say: names nobody spoke, numbers
//  nobody gave. A retracted day is NOT a trap ("moved from Thursday to Monday"
//  is a fine summary); the fact it was moved TO is what's scored.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.8 (hand-written;
//  the long call is generated filler around three planted facts). Prior: Unknown.
//

import Foundation

public enum CallSummaryFixtures {
    public static let all: [CallSummaryFixture] = [
        standup, salesCorrection, reschedule, catchUp, landlord, longPlanning,
    ]

    static let standup = CallSummaryFixture(
        id: "standup",
        title: "Tuesday standup",
        transcript: """
        Aoife: Morning. Quick one today. Where are we on the export bug?
        Ravi: I found it. The CSV writer drops the last row when the file ends without a newline. Fix is up for review.
        Aoife: Great. Marta, can you review Ravi's fix today?
        Marta: Yes, I'll review it after lunch.
        Aoife: And the onboarding copy?
        Marta: Still waiting on legal. I'll chase them this afternoon.
        Ravi: One blocker from me: the staging database is full again.
        Aoife: I'll ask ops to expand staging. That's it, thanks all.
        """,
        facts: [["csv", "export"], ["last row"], ["staging"], ["legal"]],
        actions: [["marta", "review"], ["marta", "legal"], ["aoife", "staging"]],
        traps: ["friday", "deadline extended", "john"]
    )

    static let salesCorrection = CallSummaryFixture(
        id: "sales-correction",
        title: "Harbourline renewal",
        transcript: """
        Niamh: Thanks for making time. Harbourline's renewal is up in March.
        Dev: Right. We'd like to add the analytics seats this year.
        Niamh: For twenty seats the annual price is forty thousand — sorry, I misread that, it's forty-five thousand euro with analytics.
        Dev: Forty-five. Okay. Can you put that in writing?
        Niamh: I'll send the revised proposal by Thursday.
        Dev: And I'll need our finance lead, Colm, to sign off before we commit.
        Niamh: Understood. Talk Thursday.
        """,
        facts: [["45", "forty-five", "forty five"], ["twenty seats", "20 seats"], ["analytics"], ["colm"], ["march"]],
        actions: [["proposal"], ["colm"]],
        traps: ["fifty thousand", "50,000", "discount"]
    )

    static let reschedule = CallSummaryFixture(
        id: "reschedule",
        title: "Workshop date",
        transcript: """
        Sam: About the design workshop. Can we do Thursday?
        Lena: Thursday works for me.
        Sam: Actually, no, scratch Thursday. The room's booked. Let's do Monday at ten instead.
        Lena: Monday at ten is fine. I'll book the big room.
        Sam: Perfect. I'll send the agenda on Friday.
        """,
        facts: [["monday"], ["ten", "10"], ["workshop"]],
        actions: [["lena", "room"], ["sam", "agenda"]],
        traps: ["tuesday", "wednesday", "cancelled"]
    )

    static let catchUp = CallSummaryFixture(
        id: "catch-up",
        title: "Catch-up with Orla",
        transcript: """
        Orla: How was Donegal?
        Kev: Wet, but brilliant. We did the cliff walk at Slieve League.
        Orla: Jealous. I've only been to Galway this summer.
        Kev: Galway's never a bad call. How's the new puppy?
        Orla: Chewing everything. Her name's Biscuit.
        Kev: Ha. Good name. Right, I'd better go. Great to catch up.
        """,
        facts: [["donegal"], ["slieve league", "cliff"], ["biscuit", "puppy"]],
        actions: [],
        traps: ["meeting", "deadline", "follow-up call"]
    )

    static let landlord = CallSummaryFixture(
        id: "landlord",
        title: "Boiler repair",
        transcript: """
        Agent: Hello, Brennan Lettings.
        Tenant: Hi, the boiler at 14 Castle Street has stopped heating water since Sunday.
        Agent: Sorry to hear it. I can get a technician out Wednesday between nine and twelve.
        Tenant: Wednesday morning works. Do I need to be in?
        Agent: Yes, someone has to be home. The technician will call thirty minutes before arriving.
        Tenant: Okay, I'll make sure I'm home.
        """,
        facts: [["boiler"], ["wednesday"], ["castle street", "14"], ["technician"]],
        actions: [["home|present|be in|be there"]],
        traps: ["thursday", "plumber fee", "€"]
    )

    /// Over 16k characters (more than Mini's 4,096 tokens on its own). Three
    /// facts are planted: the budget at the start, the venue in the middle, the
    /// decision at the end.
    static let longPlanning: CallSummaryFixture = {
        let filler = [
            "Ciara: On the agenda side, I think we keep the morning sessions short and leave room for questions.",
            "Tom: Agreed. Last year the afternoon dragged, people were checking email by three.",
            "Ciara: We could move the panel to after lunch and put the workshops in the morning.",
            "Tom: The catering team asked again about dietary requirements, I told them we'd send numbers later.",
            "Ciara: Registration is tracking about the same as last year, maybe slightly ahead.",
            "Tom: I spoke to the AV people, they want the run of show two weeks before.",
            "Ciara: Let's make sure the badges are printed in advance this time, the queue was a nightmare.",
            "Tom: The photographer from last year is available, same rate as before.",
        ]
        var lines = [
            "Ciara: Let's start with money. The total budget for the offsite is ninety thousand euro, fixed.",
            "Tom: Ninety thousand, understood. That includes travel?",
            "Ciara: Travel included, yes.",
        ]
        for round in 0 ..< 200 {
            lines.append(filler[round % filler.count])
            if round == 100 {
                lines.append("Tom: On venue, the shortlist came back and Lisbon is the clear winner on cost and flights.")
                lines.append("Ciara: Lisbon it is, then, pending the dates.")
            }
        }
        lines += [
            "Tom: So we're deciding the dates today?",
            "Ciara: Yes. Final decision: the second week of May. Tom, please confirm the venue contract by Friday.",
            "Tom: I'll confirm the venue contract by Friday.",
        ]
        return CallSummaryFixture(
            id: "long-planning",
            title: "Offsite planning",
            transcript: lines.joined(separator: "\n"),
            facts: [["ninety thousand", "90,000", "90k", "90 000", "€90"], ["lisbon"], ["of may", "in may", "mid-may"]],
            actions: [["venue", "contract"]],
            traps: ["barcelona", "porto", "hundred thousand"]
        )
    }()
}
