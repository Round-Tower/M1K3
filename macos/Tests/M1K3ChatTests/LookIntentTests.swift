//
//  LookIntentTests.swift
//  M1K3ChatTests
//
//  The spoken trigger for a look (#768). A match turns the camera on, so the
//  matcher is tight on purpose: these pin both directions, and the near-misses
//  matter more than the hits (a miss costs a tap on the eye button, a false
//  hit opens a camera nobody asked for).
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.7, Prior: none (new file)
//  Context: the lists here are the ones the matcher was written against. The
//  blind score (a set written by an agent that never saw the phrases) is in
//  the PR body, not here: a blind set stops being blind once it is a fixture.
//

import M1K3Chat
import Testing

struct LookIntentTests {
    @Test("a plain ask to look is heard", arguments: [
        "What am I looking at?",
        "hey mike what am i looking at",
        "Ok so what am I looking at here",
        "what am I holding",
        "What's in front of me?",
        "what is in front of me right now",
        "What do you see?",
        "what can you see",
        "tell me what you see",
        "Look at this.",
        "can you look at this please",
        "Take a look at this",
        "could you have a look at this for me",
        "look at that",
        "Can you see this?",
        "Read this to me",
        "read that out",
        "read this sign",
        "what does this say",
        "What does that say?",
        "Use the camera",
        "open your eyes",
        "can you turn on the camera",
        "what's this thing",
        "What is this I'm holding?",
        "Identify this",
        "what kind of plant is this",
        "What type of bird is that?",
        "Look at this and tell me what it is",
        "whats this in front of me",
    ])
    func hears(_ utterance: String) {
        #expect(LookIntent.asksToLook(utterance))
    }

    @Test("talk that only sounds like looking leaves the camera off", arguments: [
        "",
        "   ",
        "Look, I just think we should wait",
        "I see what you mean",
        "Can you see why that failed?",
        "Look up the weather in Galway",
        "have a look at my notes",
        "take a look at my calendar for tomorrow",
        "What do you see in my notes about the trip?",
        "what do you see happening with interest rates",
        "Look at this from my point of view",
        "look at that, another rainy day",
        "What am I looking at for a new boiler?",
        "what am I looking at in terms of cost",
        "Can you see images?",
        "Do you have a camera?",
        "How do you use the camera?",
        "do you use the camera to spy on me",
        "I was looking at flats yesterday",
        "I told her to look at this",
        "What's this about then?",
        "What's that?",
        "What is this?",
        "what is that supposed to mean",
        "what does it say",
        "what does that say about me",
        "read this back to me later when I ask",
        "Read me the news",
        "what kind of music is this conversation about",
        "There's a long road in front of me",
        "Set a timer for ten minutes",
        "What's the capital of Peru?"
    ])
    func leavesTheCameraOff(_ utterance: String) {
        #expect(!LookIntent.asksToLook(utterance))
    }

    @Test("speech-to-text shapes read the same: no apostrophes, odd casing, stray punctuation")
    func speechShapes() {
        #expect(LookIntent.asksToLook("WHATS IN FRONT OF ME"))
        #expect(LookIntent.asksToLook("what’s in front of me"))
        #expect(LookIntent.asksToLook("look at this... please"))
        #expect(LookIntent.asksToLook("what is this im holding"))
    }

    @Test("a long ramble is never a trigger, whatever it contains")
    func longRamble() {
        let ramble = "so I was walking down the road and I thought to myself you know "
            + "what am I looking at here"
        #expect(!LookIntent.asksToLook(ramble))
    }

    // MARK: - The voice turn's route

    @Test("with the eyes open every voice turn is a look, whatever the words")
    func eyesOpenAlwaysLooks() {
        #expect(LookIntent.voiceTurnLooks("Is it ripe?", eyesOpen: true, canLook: true))
        #expect(LookIntent.voiceTurnLooks("", eyesOpen: true, canLook: true))
    }

    @Test("with the eyes closed only an ask to look opens them")
    func eyesClosedNeedsTheAsk() {
        #expect(LookIntent.voiceTurnLooks("What am I looking at?", eyesOpen: false, canLook: true))
        #expect(!LookIntent.voiceTurnLooks("Is it ripe?", eyesOpen: false, canLook: true))
    }

    @Test("a brain or a device that cannot look never takes the look route")
    func cannotLook() {
        #expect(!LookIntent.voiceTurnLooks("What am I looking at?", eyesOpen: false, canLook: false))
        #expect(!LookIntent.voiceTurnLooks("Is it ripe?", eyesOpen: true, canLook: false))
    }
}
