//
//  AFMNativeToolTurnSession.swift
//  M1K3Inference
//
//  A ToolTurnSession backed by LanguageModelSession(tools:) — the macOS 26+
//  native tool-calling path. The session registers AFMNativeTool wrappers so
//  the model sees structured JSON-Schema tool definitions and can call them
//  natively. The wrappers return STUB results — the real execution stays in
//  LocalAgent's dispatch core, which owns the repeat-guard, exclusion classes
//  and activity events.
//
//  Flow per send():
//    1. Render the ToolMessage transcript → a text prompt.
//    2. Call session.respond(to:, options:) with toolCallingMode: .allowed.
//    3. If the model called a tool → the wrapper fires onCall and records it.
//       Return .toolCalls so the agent dispatches the REAL tool.
//    4. If no tool was called → return .text(answer).
//
//  The session is created FRESH per send() — same cost as the AFMToolDecision
//  path (Phase 15 review note 1). A future optimisation: hold one session
//  across the turn, feeding tool results as Transcript entries.

#if compiler(>=6.2)
    import Foundation
    @_weakLinked import FoundationModels
    import M1K3LogCore
    import os

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    final class AFMNativeToolTurnSession: ToolTurnSession, @unchecked Sendable {
        private let instructions: String
        private let tools: [AFMNativeTool]
        private let toolDefinitions: [ToolDefinition]
        private static let log = M1K3Log.logger(.afm)
        private let callLog: ToolCallLog

        final class ToolCallLog: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [(name: String, query: String)] = []

            func append(_ name: String, _ query: String) {
                lock.withLock { entries.append((name, query)) }
            }

            func drain() -> [(name: String, query: String)] {
                lock.withLock {
                    let result = entries
                    entries.removeAll()
                    return result
                }
            }
        }

        private var iteration = 0

        init(instructions: String, toolDefinitions: [ToolDefinition]) {
            let log = ToolCallLog()
            self.toolDefinitions = toolDefinitions
            callLog = log
            tools = AFMNativeTool.wrap(toolDefinitions) { name, query in
                log.append(name, query)
            }
            self.instructions = instructions
        }

        func send(
            _ messages: [ToolMessage],
            onToken: @escaping @Sendable (String) -> Void
        ) async throws -> ToolTurn {
            _ = callLog.drain()
            defer { iteration += 1 }

            let body = AFMToolPrompt.render(messages: messages, tools: toolDefinitions)
            let imageURLs = AFMToolPrompt.imageURLs(from: messages)
            let standing = AFMToolPrompt.systemInstructions(from: messages) ?? instructions

            let session = LanguageModelSession(
                tools: tools,
                instructions: standing
            )

            do {
                let response: LanguageModelSession.Response<String>

                #if compiler(>=6.4)
                    if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) {
                        let options = GenerationOptions(toolCallingMode: .allowed)
                        if !imageURLs.isEmpty {
                            response = try await session.respond(options: options) {
                                body
                                for url in imageURLs {
                                    Attachment(imageURL: url)
                                }
                            }
                        } else {
                            response = try await session.respond(to: body, options: options)
                        }
                    } else {
                        response = try await session.respond(to: body)
                    }
                #else
                    response = try await session.respond(to: body)
                #endif

                let calls = callLog.drain()

                if !calls.isEmpty {
                    let parsed = calls.map { call in
                        ParsedToolCall(
                            name: call.name,
                            arguments: [AFMToolMapping.argumentKey: .string(call.query)]
                        )
                    }
                    Self.log.notice(
                        "afm native tools: \(calls.count, privacy: .public) call(s) — \(calls.map(\.name).joined(separator: ", "), privacy: .public)"
                    )
                    return .toolCalls(parsed)
                }

                onToken(response.content)
                return .text(response.content)

            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let described = String(describing: error)
                let preview = LogPreview.preview(described, max: 200)
                Self.log.error(
                    "afm native tool session failed: \(preview, privacy: .public)"
                )
                return .text("")
            }
        }
    }
#endif
