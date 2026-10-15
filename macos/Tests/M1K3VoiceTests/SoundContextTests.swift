//
//  SoundContextTests.swift
//  M1K3VoiceTests
//
//  Pins SoundContext: what the built-in sound classifier heard during a listen,
//  as one short line for the turn, and whether the listen was music without a
//  speaker (the "wrote down the lyrics" turn). Labels are SoundAnalysis's
//  `.version1` identifiers; the eval that grounds the rules is
//  docs/evals/2026-10-15-sound-context.md.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.8. Prior: Unknown.
//  (challenger's guards pinned: majority of windows, our own playback, no crying-as-baby.)

import AVFoundation
@testable import M1K3Voice
import Testing

struct SoundContextTests {
    private func context(_ windows: [[String: Double]]) -> SoundContext {
        var context = SoundContext()
        for window in windows {
            context.observe(window)
        }
        return context
    }

    @Test("speech alone takes the turn and adds no context")
    func speechAlone() {
        let heard = context([["speech": 0.96], ["speech": 0.98], ["speech": 0.97, "breathing": 0.42]])
        #expect(heard.verdict == .take)
        #expect(heard.contextLine == nil)
    }

    @Test("music with no speaker is not a turn")
    func musicWithoutSpeech() {
        let heard = context([["music": 0.94, "guitar": 0.91], ["music": 0.9, "singing": 0.8], ["music": 0.92]])
        #expect(heard.verdict == .musicWithoutSpeech)
    }

    @Test("a faint voice under loud music still takes the turn: a dropped turn is the worse mistake")
    func faintVoiceUnderMusic() {
        // Kev's clips 10 dB under music read speech 0.1-0.5 (docs/evals/2026-10-15-sound-context.md).
        let heard = context([["music": 0.95, "speech": 0.12], ["music": 0.97]])
        #expect(heard.verdict == .take)
        #expect(context([["music": 0.95, "speech": 0.05], ["music": 0.97]]).verdict == .musicWithoutSpeech)
    }

    @Test("singing alone is not a turn either")
    func singingAlone() {
        let heard = context([["choir_singing": 0.92, "singing": 0.81], ["singing": 0.7]])
        #expect(heard.verdict == .musicWithoutSpeech)
    }

    @Test("talking over music takes the turn, and says so")
    func speechOverMusic() {
        let heard = context([["music": 0.96, "guitar": 0.94, "speech": 0.91], ["music": 0.95, "guitar": 0.9]])
        #expect(heard.verdict == .take)
        #expect(heard.contextLine == "music (guitar)")
    }

    @Test("a sound has to persist or be certain: one weak window is noise")
    func persistence() {
        #expect(context([["speech": 0.9], ["speech": 0.9, "dog_bark": 0.65]]).contextLine == nil)
        let twice = context([["speech": 0.9, "dog_bark": 0.65], ["speech": 0.9, "dog_bark": 0.7]])
        #expect(twice.contextLine == "a dog barking")
        #expect(context([["speech": 0.9, "door_bell": 0.95]]).contextLine == "the doorbell")
    }

    @Test("the line leads with what needs attention and stays short")
    func ordering() {
        let heard = context([
            ["speech": 0.9, "rain": 0.8, "baby_crying": 0.9, "music": 0.8, "typing": 0.7, "dog_bark": 0.8],
            ["speech": 0.9, "rain": 0.8, "baby_crying": 0.9, "music": 0.8, "typing": 0.7, "dog_bark": 0.8],
        ])
        #expect(heard.contextLine == "a baby crying, music, a dog barking")
    }

    @Test("synonyms say one thing once")
    func synonymsCollapse() {
        let heard = context([
            ["speech": 0.9, "dog": 0.9, "dog_bark": 0.9, "police_siren": 0.9, "siren": 0.9],
        ])
        #expect(heard.contextLine == "a siren, a dog barking")
    }

    @Test("one burst of music in a quiet listen is not a song: most windows must be music")
    func burstIsNotASong() {
        #expect(context([["music": 0.95]]).verdict == .take) // one window decides nothing
        #expect(context([["ringtone": 0.9, "music": 0.8], [:], [:]]).verdict == .take)
        #expect(context([["music": 0.9], ["music": 0.9], [:]]).verdict == .musicWithoutSpeech)
    }

    @Test("if M1K3 made a sound during the listen, the music may be ours: always take the turn")
    func ownPlaybackNeverVetoes() {
        var heard = context([["music": 0.95, "synthesizer": 0.9], ["music": 0.95]])
        #expect(heard.verdict == .musicWithoutSpeech)
        heard.noteOwnPlayback()
        #expect(heard.verdict == .take)
        heard.reset()
        heard.observe(["music": 0.9])
        heard.observe(["music": 0.9])
        #expect(heard.verdict == .musicWithoutSpeech) // a reset forgets our playback too
    }

    @Test("crying is never announced as a baby unless the classifier said baby")
    func cryingIsNotABaby() {
        #expect(context([["speech": 0.9, "crying_sobbing": 0.95]]).contextLine == nil)
        #expect(context([["speech": 0.9, "baby_crying": 0.95]]).contextLine == "a baby crying")
    }

    @Test("ties order the same way every time")
    func tiesAreDeterministic() {
        let window = ["speech": 0.9, "laughter": 0.95, "applause": 0.95, "cough": 0.95, "crowd": 0.95]
        #expect(context([window]).contextLine == "applause, coughing, laughter")
        let tiedInstruments = context([["speech": 0.9, "music": 0.95, "piano": 0.91, "guitar": 0.91]])
        #expect(tiedInstruments.contextLine == "music (guitar)")
    }

    @Test("labels outside the map never reach the line")
    func unmappedLabelsStayOut() {
        let heard = context([["speech": 0.9, "mosquito_buzz": 0.95, "silence": 0.99]])
        #expect(heard.contextLine == nil)
    }

    @Test("nothing heard takes the turn: the transcript decides, not the classifier")
    func emptyListen() {
        let heard = context([])
        #expect(heard.verdict == .take)
        #expect(heard.contextLine == nil)
    }

    @Test("a stream matches on rate, channels and sample format, not channel layout")
    func streamFormatIgnoresLayout() throws {
        let plain = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Mono)
        let laidOut = try #require(layout.map { AVAudioFormat(standardFormatWithSampleRate: 16000, channelLayout: $0) })
        #expect(SoundContextListener.sameStream(plain, laidOut))
        let faster = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        #expect(!SoundContextListener.sameStream(plain, faster))
    }

    @Test("reset forgets the listen")
    func resetForgets() {
        var heard = context([["music": 0.95], ["music": 0.95]])
        heard.reset()
        #expect(heard.verdict == .take)
        #expect(heard.contextLine == nil)
    }
}
