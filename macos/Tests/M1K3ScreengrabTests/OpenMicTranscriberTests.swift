//
//  OpenMicTranscriberTests.swift
//  M1K3ScreengrabTests
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.85, Prior: Unknown
//

import M1K3Screengrab
import M1K3Voice
import Testing

struct OpenMicTranscriberTests {
    @Test func aSilentMicStaysOpenUntilStopped() async throws {
        let mic = OpenMicTranscriber(partial: nil, wordDelay: .milliseconds(5))
        let stream = try mic.startListening(finality: .keepsListening)
        var iterator = stream.makeAsyncIterator()
        let race = Task { await iterator.next() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!race.isCancelled)
        mic.stopListening()
        let segment = await race.value
        #expect(segment == nil, "stop finishes the stream; nothing was ever final")
    }

    @Test func thePartialArrivesWordByWordAndIsNeverFinal() async throws {
        let mic = OpenMicTranscriber(partial: "summarise the call", wordDelay: .milliseconds(5))
        var seen: [TranscriptSegment] = []
        for await segment in try mic.startListening() {
            seen.append(segment)
            if segment.text == "summarise the call" { break }
        }
        #expect(seen.map(\.text) == ["summarise", "summarise the", "summarise the call"])
        #expect(seen.allSatisfy { !$0.isFinal })
        #expect(mic.isAvailable)
        #expect(!mic.attemptsEchoCancellation)
    }

    @Test func aNonSubmittingMicKeepsDictatingAfterTheSentence() async throws {
        let mic = OpenMicTranscriber(partial: "one two", wordDelay: .milliseconds(5))
        var seen: [String] = []
        for await segment in try mic.startListening() {
            seen.append(segment.text)
            if seen.count == 3 { break }
        }
        #expect(seen == ["one", "one two", "one two one"], "the partial keeps growing — the mic never goes quiet")
    }

    @Test func aSubmittingMicEndsOnOneFinalSegment() async throws {
        let mic = OpenMicTranscriber(partial: "summarise the call", wordDelay: .milliseconds(5), submits: true)
        var finals: [TranscriptSegment] = []
        for await segment in try mic.startListening() where segment.isFinal {
            finals.append(segment)
            break
        }
        #expect(finals.map(\.text) == ["summarise the call"])
    }
}
