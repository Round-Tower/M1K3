#if compiler(>=6.2)
    import Foundation
    @_weakLinked import FoundationModels
    @testable import M1K3Inference
    import Synchronization
    import Testing

    /// Mini's native tool turn used to let the model carry on after a call: the
    /// stub returned "(Tool result will follow.)" and Mini wrote a whole answer the
    /// agent then threw away, before the real tool ran. The wrapper now records the
    /// call and throws `Intercepted`, which ends the generation at the call.
    struct AFMNativeToolTests {
        @Test("a call is recorded, then the generation is stopped at it")
        func callIsRecordedThenIntercepted() async throws {
            let seen = Mutex<[String]>([])
            let tool = AFMNativeTool(name: "web_search", description: "search") { name, query in
                seen.withLock { $0.append("\(name):\(query)") }
            }
            await #expect(throws: AFMNativeTool.Intercepted.self) {
                _ = try await tool.call(arguments: AFMToolArguments(query: "apple silicon news"))
            }
            #expect(seen.withLock { $0 } == ["web_search:apple silicon news"])
        }

        @Test("the session reads an intercepted call as a call, and anything else as a failure")
        func interceptIsRecognised() {
            let tool = AFMNativeTool(name: "datetime", description: "") { _, _ in }
            let intercepted = LanguageModelSession.ToolCallError(tool: tool, underlyingError: AFMNativeTool.Intercepted())
            let broken = LanguageModelSession.ToolCallError(tool: tool, underlyingError: CancellationError())
            #expect(AFMNativeTool.isIntercept(intercepted))
            #expect(!AFMNativeTool.isIntercept(broken))
            #expect(!AFMNativeTool.isIntercept(CancellationError()))
        }
    }
#endif
