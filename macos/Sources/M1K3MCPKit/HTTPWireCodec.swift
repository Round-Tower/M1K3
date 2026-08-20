//
//  HTTPWireCodec.swift
//  M1K3MCPKit
//
//  Pure HTTP/1.1 wire codec for the in-app MCP listener: raw bytes ↔ the MCP
//  SDK's framework-agnostic HTTPRequest/HTTPResponse. No sockets here — the
//  NWListener shell (LocalMCPHTTPServer) stays thin and this layer carries
//  the unit tests. Connection: close on every response; one request per
//  connection keeps v1 honest.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.9 (parse/encode
//  test-pinned incl. split packets; HTTP/1.1 subset is deliberate — no
//  chunked encoding, no keep-alive). Prior: Unknown.
//  Review: claude-fable-5, 2026-08-19 — added `clientName(fromInitializeBody:)`
//  (initialize clientInfo → the Agent Log identity stamp; test-pinned).
//

import Foundation
import MCP

public enum HTTPWireCodec {
    /// Parse one complete request from accumulated bytes. Returns nil until
    /// the head AND the full Content-Length body have arrived.
    public static func parseRequest(_ data: Data) -> (request: HTTPRequest, consumed: Int)? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = data.subdata(in: 0 ..< headEnd.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let path = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headEnd.upperBound
        let contentLength = headers.first { $0.key.lowercased() == "content-length" }
            .flatMap { Int($0.value) } ?? 0
        guard data.count - bodyStart >= contentLength else { return nil }
        let body = contentLength > 0 ? data.subdata(in: bodyStart ..< bodyStart + contentLength) : nil

        let request = HTTPRequest(method: method, headers: headers, body: body, path: path)
        return (request, bodyStart + contentLength)
    }

    /// Encode an SDK response as HTTP/1.1 bytes. `.stream` cannot occur on the
    /// stateless transport; it degrades to an empty 200 if it ever does.
    public static func encode(_ response: HTTPResponse) -> Data {
        let body = response.bodyData ?? Data()
        var head = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(response.statusCode))\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Detect an `initialize` JSON-RPC request — the cue to rebuild the
    /// (Server, transport) pair, because the SDK Server rejects a second
    /// initialize for its lifetime (Server.swift:928 at pin 0.12.1).
    public static func isInitializeRequest(body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return json["method"] as? String == "initialize"
    }

    /// The MCP client's self-reported name (`params.clientInfo.name`) off an
    /// initialize body — the identity the opt-in Agent Interaction Log stamps
    /// on captured calls so the timeline can fold "visits" per client. Nil for
    /// non-initialize bodies, junk JSON, or a missing/blank name; UNTRUSTED
    /// display data either way (any process can claim any name).
    public static func clientName(fromInitializeBody body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["method"] as? String == "initialize",
              let params = json["params"] as? [String: Any],
              let clientInfo = params["clientInfo"] as? [String: Any],
              let name = (clientInfo["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return name
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 415: "Unsupported Media Type"
        case 500: "Internal Server Error"
        default: "Status \(status)"
        }
    }
}
