//
//  AFMNativeTool.swift
//  M1K3Inference
//
//  Bridges M1K3's ToolDefinition → the macOS 26+ FoundationModels `Tool`
//  protocol, so Apple's on-device model sees STRUCTURED tool definitions
//  (JSON Schema + descriptions) instead of a text catalogue. The model
//  decides which tool to call natively; the wrapper's `call(arguments:)`
//  returns a STUB result — the real execution happens in LocalAgent's
//  dispatch core (repeat-guard, exclusion classes, activity events).
//
//  Each wrapper carries a single-string `@Generable` argument struct —
//  every current M1K3 AgentTool takes one text parameter under "query".

#if compiler(>=6.2)
    import Foundation
    @_weakLinked import FoundationModels

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    @Generable
    public struct AFMToolArguments: Sendable {
        @Guide(description: "The input query or argument to pass to this tool.")
        public var query: String
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    public struct AFMNativeTool: Tool, @unchecked Sendable {
        public typealias Arguments = AFMToolArguments
        public typealias Output = String

        public let name: String
        public let description: String

        private let onCall: @Sendable (String, String) -> Void

        public init(
            name: String,
            description: String,
            onCall: @escaping @Sendable (String, String) -> Void
        ) {
            self.name = name
            self.description = description
            self.onCall = onCall
        }

        public func call(arguments: AFMToolArguments) async throws -> String {
            onCall(name, arguments.query)
            return "(Tool result will follow.)"
        }
    }

    // MARK: - Factory

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    public extension AFMNativeTool {
        static func wrap(
            _ tools: [ToolDefinition],
            onCall: @escaping @Sendable (String, String) -> Void
        ) -> [AFMNativeTool] {
            tools.map { def in
                AFMNativeTool(
                    name: def.name,
                    description: def.description,
                    onCall: onCall
                )
            }
        }
    }
#endif
