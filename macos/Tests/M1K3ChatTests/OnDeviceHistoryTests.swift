@testable import M1K3Chat
import Testing

/// With PCC consent asked once (2026-10-01), "also send this conversation" can
/// ride along without a sheet. A conversation holding answers made on this Mac
/// has history that never left it, so the sheet shows once there: this is the
/// test of that question.
struct OnDeviceHistoryTests {
    private func answer(_ text: String, pcc: Bool, status: ChatMessage.Status = .complete) -> ChatMessage {
        var message = ChatMessage(role: .assistant, text: text, status: status)
        if pcc { message.answerOrigin = .privateCloudCompute }
        return message
    }

    private let question = ChatMessage(role: .user, text: "hi", status: .complete)

    @Test("an empty or all-PCC conversation holds no on-device answers")
    func pccOnly() {
        #expect(!ChatSession.holdsOnDeviceAnswers([]))
        #expect(!ChatSession.holdsOnDeviceAnswers([question, answer("from the cloud", pcc: true)]))
    }

    @Test("one answer from this Mac is enough")
    func oneLocalAnswer() {
        #expect(ChatSession.holdsOnDeviceAnswers([question, answer("from Lil", pcc: false), answer("cloud", pcc: true)]))
    }

    @Test("only what the conversation would share counts: empty, unfinished and excluded turns don't")
    func mirrorsWhatWouldBeShared() {
        var excluded = answer("script output", pcc: false)
        excluded.contextExcluded = true
        #expect(!ChatSession.holdsOnDeviceAnswers([question, answer("", pcc: false)]))
        #expect(!ChatSession.holdsOnDeviceAnswers([question, answer("half", pcc: false, status: .streaming)]))
        #expect(!ChatSession.holdsOnDeviceAnswers([question, excluded]))
    }
}
