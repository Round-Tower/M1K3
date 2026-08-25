//
//  BrainLinkWireTests.swift
//  M1K3BrainLinkTests
//
//  The client's half of the wire, tested against the SERVER'S OWN frame
//  encoders (M1K3BrainServe.BrainServeFrames) — the two ends can't drift
//  apart without a red here. The SSE parser is fed byte-by-byte in the
//  torture tests because NWConnection chunk boundaries are arbitrary.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.9 (pure, TDD'd
//  red-first against real server frame bytes). Prior: Unknown.
//

import Foundation
import M1K3BrainLink
import M1K3BrainServe
import Testing

struct HTTPResponseParserTests {
    @Test func parsesTheServersBufferedResponse() throws {
        let wire = BrainServeFrames.buffered(
            status: 200, reason: "OK", json: #"{"ok":true,"brain":"Big","ready":true,"v":"1"}"#
        )
        let parsed = HTTPResponseParser.parseHead(wire)
        #expect(parsed?.head.status == 200)
        #expect(parsed?.head.contentLength == 46)
        #expect(parsed?.head.isEventStream == false)
        let body = try wire.suffix(from: #require(parsed?.bodyStart))
        #expect(String(data: body, encoding: .utf8)?.contains("\"brain\":\"Big\"") == true)
    }

    @Test func parsesTheServers429WithRetryAfter() throws {
        let wire = try #require(BrainServeFrames.busy(.coolingDown(retryAfterSeconds: 120)))
        let parsed = HTTPResponseParser.parseHead(wire)
        #expect(parsed?.head.status == 429)
        #expect(parsed?.head.retryAfterSeconds == 120)
    }

    @Test func recognisesTheSSEHead() {
        let parsed = HTTPResponseParser.parseHead(BrainServeFrames.sseHead())
        #expect(parsed?.head.status == 200)
        #expect(parsed?.head.isEventStream == true)
    }

    @Test func incompleteHeadReturnsNil() {
        let wire = BrainServeFrames.buffered(status: 200, reason: "OK", json: "{}")
        for cut in 0 ..< 20 {
            #expect(HTTPResponseParser.parseHead(wire.prefix(cut)) == nil)
        }
    }

    @Test func headerNamesAreCaseInsensitive() {
        let raw = "HTTP/1.1 200 OK\r\nCONTENT-LENGTH: 2\r\ncOnTeNt-TyPe: application/json\r\n\r\n{}"
        let parsed = HTTPResponseParser.parseHead(Data(raw.utf8))
        #expect(parsed?.head.contentLength == 2)
    }

    @Test func garbageStatusLineReturnsNil() {
        #expect(HTTPResponseParser.parseHead(Data("not http at all\r\n\r\n".utf8)) == nil)
    }
}

struct SSEParserTests {
    @Test func parsesARealTokenEvent() {
        var parser = SSEParser()
        let events = parser.feed(BrainServeFrames.tokenEvent("Hello, Kev"))
        #expect(events == [.token("Hello, Kev")])
    }

    @Test func tokenWithQuotesAndNewlinesSurvives() {
        var parser = SSEParser()
        let tricky = "line one\nsaid \"hi\"\tend"
        let events = parser.feed(BrainServeFrames.tokenEvent(tricky))
        #expect(events == [.token(tricky)])
    }

    @Test func parsesTheDoneEvent() {
        var parser = SSEParser()
        #expect(parser.feed(BrainServeFrames.doneEvent()) == [.done])
    }

    @Test func parsesTheErrorEvent() {
        var parser = SSEParser()
        #expect(parser.feed(BrainServeFrames.errorEvent("brain fell over")) == [.error("brain fell over")])
    }

    @Test func byteByByteFeedYieldsTheSameEvents() {
        var wire = Data()
        wire.append(BrainServeFrames.tokenEvent("alpha"))
        wire.append(BrainServeFrames.tokenEvent("beta"))
        wire.append(BrainServeFrames.doneEvent())
        var parser = SSEParser()
        var events: [SSEParser.Event] = []
        for byte in wire {
            events.append(contentsOf: parser.feed(Data([byte])))
        }
        #expect(events == [.token("alpha"), .token("beta"), .done])
    }

    @Test func unknownEventKindsAreSkippedNotFatal() {
        var parser = SSEParser()
        let frame = Data("event: heartbeat\ndata: {}\n\n".utf8)
        #expect(parser.feed(frame).isEmpty)
        // …and the stream keeps working after one.
        #expect(parser.feed(BrainServeFrames.doneEvent()) == [.done])
    }

    @Test func junkDataPayloadIsSkipped() {
        var parser = SSEParser()
        #expect(parser.feed(Data("data: not json\n\n".utf8)).isEmpty)
    }
}

struct BrainLinkFramesTests {
    @Test func getRequestIsWellFormed() throws {
        let wire = try #require(String(data: BrainLinkFrames.get("/v1/health", host: "192.168.1.24"), encoding: .utf8))
        #expect(wire.hasPrefix("GET /v1/health HTTP/1.1\r\n"))
        #expect(wire.contains("Host: 192.168.1.24\r\n"))
        #expect(wire.contains("Connection: close\r\n"))
        #expect(wire.hasSuffix("\r\n\r\n"))
    }

    @Test func postCarriesContentLengthAndBody() throws {
        let body = Data(#"{"prompt":"hi"}"#.utf8)
        let wire = BrainLinkFrames.post("/v1/generate", host: "mac.local", body: body)
        let text = try #require(String(data: wire, encoding: .utf8))
        #expect(text.hasPrefix("POST /v1/generate HTTP/1.1\r\n"))
        #expect(text.contains("Content-Length: \(body.count)\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.hasSuffix("\r\n\r\n" + #"{"prompt":"hi"}"#))
    }

    @Test func pairBodyRoundTripsThroughTheServersParser() {
        let body = BrainLinkFrames.pairBody(deviceName: "Kev’s iPad")
        #expect(PairRequest.parse(body).deviceName == "Kev’s iPad")
    }

    @Test func generateBodyRoundTripsThroughTheServersParser() {
        let body = BrainLinkFrames.generateBody(prompt: "say hi\n\"quoted\"", maxTokens: 128)
        let parsed = GenerateRequest.parse(body)
        #expect(parsed?.prompt == "say hi\n\"quoted\"")
        #expect(parsed?.maxTokens == 128)
    }

    @Test func generateBodyOmitsNilMaxTokens() {
        let parsed = GenerateRequest.parse(BrainLinkFrames.generateBody(prompt: "hi", maxTokens: nil))
        #expect(parsed?.maxTokens == nil)
    }
}
