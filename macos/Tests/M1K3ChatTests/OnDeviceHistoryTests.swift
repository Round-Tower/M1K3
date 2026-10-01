import Foundation
@testable import M1K3Chat
import Testing

/// With PCC consent asked once (2026-10-01), "also send this conversation" can
/// ride along without a sheet. Text that never left this Mac must still be seen
/// before it goes, so the sheet re-asks whenever the history holds an on-device
/// message it hasn't shown. This pins WHICH messages count as on-device.
struct OnDeviceHistoryTests {
    private func answer(_ text: String, pcc: Bool, status: ChatMessage.Status = .complete) -> ChatMessage {
        var message = ChatMessage(role: .assistant, text: text, status: status)
        if pcc { message.answerOrigin = .privateCloudCompute }
        return message
    }

    private func ask(_ text: String = "hi") -> ChatMessage {
        ChatMessage(role: .user, text: text, status: .complete)
    }

    @Test("an empty or all-PCC conversation holds nothing on-device")
    func pccOnly() {
        #expect(ChatSession.onDeviceMessageIDs([]).isEmpty)
        #expect(ChatSession.onDeviceMessageIDs([ask(), answer("from the cloud", pcc: true)]).isEmpty)
    }

    @Test("a local answer and the question it answered are both on-device")
    func localTurnCounts() {
        let question = ask()
        let local = answer("from Lil", pcc: false)
        let ids = ChatSession.onDeviceMessageIDs([ask(), answer("cloud", pcc: true), question, local])
        #expect(ids == [question.id, local.id])
    }

    /// Round-two review (b): a question whose on-device answer failed, was
    /// stopped or is still streaming is still shared, and it never left.
    @Test("a question with no PCC answer after it is on-device, even when its own answer never finished")
    func unansweredQuestionCounts() {
        let question = ask("what about this")
        let ids = ChatSession.onDeviceMessageIDs([question, answer("half", pcc: false, status: .streaming)])
        #expect(ids == [question.id])
    }

    @Test("only what the conversation would share counts: empty and excluded messages don't")
    func mirrorsWhatWouldBeShared() {
        var excluded = answer("script output", pcc: false)
        excluded.contextExcluded = true
        let first = ask()
        let ids = ChatSession.onDeviceMessageIDs([first, answer("cloud", pcc: true), excluded, answer("", pcc: false)])
        #expect(ids.isEmpty)
    }
}
