//
//  JSONRPCIDRemap.swift
//  M1K3MCPKit
//
//  Per-connection isolation of JSON-RPC response routing.
//
//  WHY: the in-app MCP server funnels every HTTP connection through ONE shared
//  `StatelessHTTPServerTransport`, whose `responseWaiters` are keyed by the
//  CLIENT-CHOSEN request `id`, globally. Every MCP client numbers its requests
//  from 1, so two concurrent clients — or one client reusing ids — collide on
//  the same id: the second registration overwrites the first's response
//  continuation, and the orphaned request hangs until the transport is torn
//  down. Measured 2026-09-01: one client polling get_status at ~7/s (all id=1)
//  hung a concurrent search_knowledge for its whole run; with DISJOINT ids the
//  same search returned in 0.12s. This is the entire DoS (see issue #176).
//
//  FIX: the listener rewrites each incoming request's id to a process-unique
//  token before the shared transport sees it, then maps the response's id back
//  to the client's original. Waiter keys are now globally unique regardless of
//  what ids clients pick.
//
//  Signed: Kev + claude-opus-4-8, 2026-09-01, Confidence 0.95 (root cause
//  proven by the disjoint-id control: colliding ids hang, unique ids run fully
//  concurrent — 4 parallel searches in 0.23s wall. Pure remap logic pinned
//  here; the wiring in LocalMCPHTTPServer is verify-by-launch against the
//  repro.) Prior: none (new file).
//

import Foundation
import MCP

/// A JSON-RPC message id: an integer or a string (per the spec; M1K3 emits
/// string tokens for its unique ids).
public enum JSONRPCID: Equatable, Sendable {
    case int(Int)
    case string(String)
    /// An explicit `"id": null` — a valid (if discouraged) JSON-RPC REQUEST id,
    /// distinct from an absent id (a notification). It must be remapped like any
    /// other id, or two clients both sending `id: null` would collide exactly as
    /// the numeric case does (claude-review #177, finding 1).
    case null

    fileprivate var jsonValue: Any {
        switch self {
        case let .int(n): return n
        case let .string(s): return s
        case .null: return NSNull()
        }
    }

    fileprivate init?(jsonValue: Any) {
        if jsonValue is NSNull {
            self = .null
        } else if let s = jsonValue as? String {
            self = .string(s)
        } else if let n = jsonValue as? Int {
            self = .int(n)
        } else if let n = jsonValue as? NSNumber {
            // JSON numbers arrive as NSNumber; accept only integral ids.
            let d = n.doubleValue
            guard d == d.rounded(), abs(d) < 9.007e15 else { return nil }
            self = .int(n.intValue)
        } else {
            return nil
        }
    }
}

public extension HTTPWireCodec {
    /// The top-level JSON-RPC `id` of a body, or nil for a notification (the
    /// `id` key is ABSENT), a batch (array), or anything that doesn't parse as a
    /// JSON object. An explicit `"id": null` is a request id (`.null`), NOT a
    /// notification — it is returned and remapped like any other id.
    static func requestID(inBody body: Data) -> JSONRPCID? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let rawID = obj["id"]
        else { return nil }
        return JSONRPCID(jsonValue: rawID)
    }

    /// A copy of `body` with its top-level `id` replaced by `id`. Returns nil
    /// if the body isn't a JSON object with an `id` (leave it untouched then).
    static func replacingID(inBody body: Data, with id: JSONRPCID) -> Data? {
        guard
            var obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            obj["id"] != nil
        else { return nil }
        obj["id"] = id.jsonValue
        return try? JSONSerialization.data(withJSONObject: obj)
    }

    /// A copy of `response` with the `id` in its JSON body replaced by `id` —
    /// but ONLY for a `.data` response (the JSON-RPC success/result body a
    /// client matches by id). Every other case (accepted/ok/stream/error) is
    /// returned unchanged: notifications carry no id, and transport-level
    /// errors are exceptional and rare enough to leave as-is.
    static func replacingResponseID(_ response: HTTPResponse, with id: JSONRPCID) -> HTTPResponse {
        guard case let .data(body, headers) = response else { return response }
        guard let rewritten = replacingID(inBody: body, with: id) else { return response }
        return .data(rewritten, headers: headers)
    }
}

/// The request-in / response-out halves of the id isolation, extracted so BOTH
/// the loopback server (`LocalMCPHTTPServer`) and the LAN Brain-at-Home route
/// (`BrainServeController.handleLANMCP`) apply it identically. The LAN route
/// forwarded straight to its shared transport, so the #176 collision was still
/// live there after the loopback fix (issue #176/#177 covered only loopback) —
/// this shared seam closes that gap and keeps the two paths from drifting.
public enum MCPRequestIDRemap {
    public struct Isolated {
        /// The request to forward to the shared transport: id rewritten onto the
        /// caller's unique token, or the ORIGINAL request unchanged when there is
        /// no id to isolate (a notification, or an unparseable body).
        public let request: HTTPRequest
        /// The client's original id to restore on the response, or nil when there
        /// is nothing to restore (notification / pass-through).
        public let clientID: JSONRPCID?
    }

    /// Rewrite `request`'s JSON-RPC id onto `uniqueID` for waiter isolation.
    /// Returns nil ONLY when the body carries an id but re-encoding failed — the
    /// caller should then forward the original request and log the (now
    /// un-isolated) collision risk.
    public static func isolate(_ request: HTTPRequest, as uniqueID: JSONRPCID) -> Isolated? {
        guard let body = request.body, let clientID = HTTPWireCodec.requestID(inBody: body) else {
            return Isolated(request: request, clientID: nil)
        }
        guard let rewrittenBody = HTTPWireCodec.replacingID(inBody: body, with: uniqueID) else {
            return nil
        }
        return Isolated(
            request: HTTPRequest(
                method: request.method, headers: request.headers,
                body: rewrittenBody, path: request.path
            ),
            clientID: clientID
        )
    }

    /// Map a forwarded response's id back to the client's original id — a no-op
    /// when `clientID` is nil.
    public static func restore(_ response: HTTPResponse, to clientID: JSONRPCID?) -> HTTPResponse {
        guard let clientID else { return response }
        return HTTPWireCodec.replacingResponseID(response, with: clientID)
    }
}
