//
//  UserNameFenceTests.swift
//  M1K3ChatTests
//
//  A fact that names the user is refused only when the "name" is no name, the
//  assistant's own, or a word the user only ever addressed someone with — and
//  never when the account or an introduction backs it. Fixtures: the three
//  wrong rows found live on 2026-11-13, then the challenger's blind set, which
//  broke the first (fail-closed) cut of this fence.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85. Prior: none (new file).
//

import Foundation
@testable import M1K3Chat
import Testing

struct UserNameFenceTests {
    private let kev = DistillationAttribution.userNames(fullName: "Kevin Murphy")
    private let nobody = DistillationAttribution.UserNames.none // iOS: the account has no name

    private func supported(
        _ fact: String, said turns: [String], names: DistillationAttribution.UserNames? = nil
    ) -> Bool {
        UserNameFence.isSupported(fact: fact, userTurns: turns, selfNames: names ?? kev)
    }

    @Test("the assistant's name never names the user, however the fact words it")
    func assistantName() {
        let turns = ["Hey Mike, what's the weather in Cork?", "Mike what time is it"]
        for fact in [
            "The user is named Mike.", "The user's name is Mike", "The user's first name is Mike.",
            "The user's nickname is Mike.", "The user prefers to be called Mike.", "The user is known as Mikey.",
        ] {
            #expect(!supported(fact, said: turns), "\(fact)")
        }
        #expect(!supported("The user is called M1K3.", said: ["M1K3, are you there?"]))
    }

    @Test("a word the user only ever addressed someone with is not their name")
    func addressOnly() {
        #expect(!supported("The user's name is paL.", said: ["Lift the freeze pal", "what's my name, pal?"]))
        #expect(!supported("The user prefers to be called pal.", said: ["Lift the freeze pal"]))
        #expect(!supported("The user is called Boss.", said: ["Right so boss, what's next"]))
        #expect(!supported("The user is named Sam.", said: ["Thanks Sam", "Sam, can you check the diary?"], names: nobody))
    }

    @Test("a word for no name is not a name")
    func absentName() {
        #expect(!supported("The user's name is not provided.", said: ["What's my name?"]))
        #expect(!supported("The user's name is unknown", said: ["do you know my name"]))
        #expect(!supported("The user's full name is unspecified.", said: ["hello there"]))
    }

    @Test("the account's own name stands, given name by fragment")
    func accountName() {
        #expect(supported("The user's name is Kev.", said: ["what's my name?"]))
        #expect(supported("The user is named Kevin Murphy.", said: ["hello there"]))
        #expect(supported("The user's name is Murphy", said: ["hello there"]))
        // Even addressed: it is still their name.
        #expect(supported("The user is named Kev.", said: ["Kev, that's me"]))
    }

    @Test("an introduction supports any name, the assistant's included: a real Mike is a Mike")
    func introductionSupports() {
        #expect(supported("The user is named Mike.", said: ["My name is Mike, by the way"], names: nobody))
        #expect(supported("The user is called Mike", said: ["Hey Mike", "Call me Mike too"], names: nobody))
        #expect(supported("The user's name is Aoife.", said: ["hi, I\u{2019}m Aoife"], names: nobody))
        #expect(supported("The user is named Buddy.", said: ["everyone calls me Buddy"], names: nobody))
        #expect(supported("The user goes by the name Kev", said: ["I go by just Kev"], names: nobody))
    }

    /// The challenger's blind set (2026-11-13): real names the fail-closed cut dropped.
    @Test("real names survive however they were given: the fence fails open")
    func blindSetRealNames() {
        let cases: [(fact: String, turn: String)] = [
            ("The user's name is Kevin.", "no, it's Kevin not Kev"),
            ("The user is named Kevin.", "Kevin here, quick question about the budget"),
            ("The user's name is Niamh.", "I'm, uh, Niamh"),
            ("The user's name is Dr. Sarah Chen.", "My name is Dr. Sarah Chen"),
            ("The user is called Kev.", "Kev's fine"),
            ("The user's name is Siobhan.", "It\u{2019}s Siobhán"),
            ("The user is named Rachel Green.", "Sign the letter from me, Rachel Green"),
            ("The user's name is Sean.", "My name is Seán"),
            ("The user's name is Léa.", "Je m'appelle Léa"),
            ("The user's name is Diego.", "Me llamo Diego y vivo en Cork"),
            ("The user's first name is Alex.", "this is Sam's laptop but I'm Alex"),
        ]
        for item in cases {
            #expect(supported(item.fact, said: [item.turn], names: nobody), "\(item.fact) ⟵ \(item.turn)")
        }
    }

    @Test("near-misses of an introduction do not rescue the assistant's name")
    func introductionNearMisses() {
        for turn in ["I'm Mike's brother", "I'm not Mike", "I'm Mikey", "Tim, call me Mike's number", "a slim mike stand"] {
            #expect(!supported("The user is named Mike.", said: [turn], names: nobody), "\(turn)")
        }
    }

    @Test("a name with a mark inside it is one name")
    func namesWithMarks() {
        #expect(UserNameFence.claimedName(in: "The user\u{2019}s name is O\u{2019}Brien.") == "o'brien")
        #expect(supported("The user's name is O'Brien.", said: ["I\u{2019}m O\u{2019}Brien"], names: nobody))
        #expect(supported("The user is called Anne-Marie", said: ["call me Anne-Marie"], names: nobody))
        #expect(!supported("The user's name is O'Brien.", said: ["thanks O'Brien"], names: nobody))
    }

    @Test("a fact that names nobody is none of this fence's business")
    func nonNamingFactsPass() {
        for fact in [
            "The user is Irish.", "The user identifies as a researcher.", "The user goes by train to work.",
            "Kev's sister is called Aoife.", "The user's project is called M1K3.", "The user's app is named Mike.",
            "The user's dog's name is Rex.", "The user prefers metric units.", "The user's company name is Round Tower.",
        ] {
            #expect(UserNameFence.claimedName(in: fact) == nil, "\(fact)")
            #expect(supported(fact, said: ["hello there"]), "\(fact)")
        }
    }

    @Test("the claimed name is the first word after the naming phrase, past a title")
    func claimedName() {
        #expect(UserNameFence.claimedName(in: "The user\u{2019}s name is Kevin Murphy.") == "kevin")
        #expect(UserNameFence.claimedName(in: "The user is called Kev by his friends") == "kev")
        #expect(UserNameFence.claimedName(in: "The user's name is Dr. Sarah Chen.") == "sarah")
        #expect(UserNameFence.claimedName(in: "The user's name is Seán.") == "sean")
        #expect(UserNameFence.claimedName(in: "The user's name is not provided.") == "not")
    }
}
