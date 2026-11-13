//
//  UserNameFenceTests.swift
//  M1K3ChatTests
//
//  A fact that names the user needs the account's own name or a
//  self-introduction behind it. Fixtures are the three wrong rows found live
//  on 2026-11-13 and the wordings that must keep working.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85. Prior: none (new file).
//

import Foundation
@testable import M1K3Chat
import Testing

struct UserNameFenceTests {
    private let kev = DistillationAttribution.userNames(fullName: "Kevin Murphy")

    private func supported(
        _ fact: String, said turns: [String], names: DistillationAttribution.UserNames? = nil
    ) -> Bool {
        UserNameFence.isSupported(fact: fact, userTurns: turns, selfNames: names ?? kev)
    }

    @Test("the assistant's spoken name, said to ADDRESS it, never names the user")
    func addressIsNotIntroduction() {
        #expect(!supported("The user is named Mike.", said: ["Hey Mike, what's the weather in Cork?"]))
        #expect(!supported("The user's name is Mike", said: ["Thanks Mike", "Mike, set a timer"]))
        #expect(!supported("The user is called M1K3.", said: ["M1K3, are you there?"]))
    }

    @Test("a term of address is not a name, however it was spelled")
    func termOfAddress() {
        #expect(!supported("The user's name is paL.", said: ["Lift the freeze pal", "what's my name, pal?"]))
        #expect(!supported("The user is called Boss.", said: ["Right so boss, what's next"]))
    }

    @Test("an absent name is not a name")
    func absentName() {
        #expect(!supported("The user's name is not provided.", said: ["What's my name?"]))
        #expect(!supported("The user's name is unknown", said: ["do you know my name"]))
    }

    @Test("the account's own name stands with no introduction, given name by fragment")
    func accountName() {
        #expect(supported("The user's name is Kev.", said: ["what's my name?"]))
        #expect(supported("The user is named Kevin Murphy.", said: ["hello there"]))
        #expect(supported("The user's name is Murphy", said: ["hello there"]))
        // A surname never matches by fragment (the attribution fence's own rule).
        #expect(!supported("The user is named Murph", said: ["hello there"]))
    }

    @Test("an introduction supports any name, the assistant's included: a real Mike is a Mike")
    func introductionSupports() {
        let nobody = DistillationAttribution.UserNames.none // iOS: the account has no name
        #expect(supported("The user is named Mike.", said: ["My name is Mike, by the way"], names: nobody))
        #expect(supported("The user is called Mike", said: ["Call me Mike"], names: nobody))
        #expect(supported("The user's name is Aoife.", said: ["hi, I\u{2019}m Aoife"], names: nobody))
        #expect(supported("The user is named Buddy.", said: ["everyone calls me Buddy"], names: nobody))
        #expect(supported("The user goes by the name Kev", said: ["I go by just Kev"], names: nobody))
    }

    @Test("a name with a mark inside it keeps its introduction")
    func namesWithMarks() {
        let nobody = DistillationAttribution.UserNames.none
        #expect(UserNameFence.claimedName(in: "The user\u{2019}s name is O\u{2019}Brien.") == "o'brien")
        #expect(supported("The user's name is O'Brien.", said: ["I\u{2019}m O\u{2019}Brien"], names: nobody))
        #expect(supported("The user is called Anne-Marie", said: ["call me Anne-Marie"], names: nobody))
        #expect(!supported("The user's name is O'Brien.", said: ["ask O'Brien about it"], names: nobody))
    }

    @Test("near-misses of an introduction do not count")
    func introductionNearMisses() {
        let nobody = DistillationAttribution.UserNames.none
        #expect(!supported("The user is named Mike.", said: ["I'm Mike's brother"], names: nobody))
        #expect(!supported("The user is named Mike.", said: ["I'm not Mike"], names: nobody))
        #expect(!supported("The user is named Mike.", said: ["I'm Mikey"], names: nobody))
        #expect(!supported("The user is named Mike.", said: ["Tim, call me Mike's number"], names: nobody))
        // "im" inside a word is not "I'm".
        #expect(!supported("The user is named Mike.", said: ["a slim mike stand"], names: nobody))
    }

    @Test("a fact that names nobody is none of this fence's business")
    func nonNamingFactsPass() {
        for fact in [
            "The user is Irish.", "The user identifies as a researcher.", "The user goes by train to work.",
            "Kev's sister is called Aoife.", "The user's project is called M1K3.", "The user's app is named Mike.",
            "The user's dog's name is Rex.", "The user prefers metric units.",
        ] {
            #expect(UserNameFence.claimedName(in: fact) == nil, "\(fact)")
            #expect(supported(fact, said: ["hello there"]), "\(fact)")
        }
    }

    @Test("the claimed name is the first word after the naming phrase")
    func claimedName() {
        #expect(UserNameFence.claimedName(in: "The user\u{2019}s name is Kevin Murphy.") == "kevin")
        #expect(UserNameFence.claimedName(in: "The user is called Kev by his friends") == "kev")
        #expect(UserNameFence.claimedName(in: "The user's name is not provided.") == "not")
    }
}
