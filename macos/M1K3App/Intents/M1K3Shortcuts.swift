//
//  M1K3Shortcuts.swift
//  M1K3App
//
//  Siri phrases for the App Intents — what makes "Ask M1K3 …" / "Tell M1K3 to
//  speak" / "Search M1K3's knowledge" etc. work by voice and appear in Spotlight
//  & the Shortcuts gallery. Free-text parameters aren't embedded in the spoken
//  phrase (Siri prompts for the value via each intent's requestValueDialog).
//
//  App-glue (verify-by-launch). Signed: Kev + claude-opus-4-8, 2026-06-17,
//  Confidence 0.75, Prior: Unknown
//  Review: Kev + claude-opus-4-6, 2026-09-16 — five new intents: SearchKnowledge,
//  RecallMemory, ListTodos, ProposeTodo, OpenVoiceMode. Confidence now 0.8.
//

import AppIntents

struct M1K3Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskM1K3Intent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Ask M1K3",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: SpeakWithM1K3Intent(),
            phrases: [
                "Have \(.applicationName) speak",
                "Tell \(.applicationName) to speak",
            ],
            shortTitle: "Speak with M1K3",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: RememberWithM1K3Intent(),
            phrases: [
                "Remember this with \(.applicationName)",
                "Have \(.applicationName) remember something",
            ],
            shortTitle: "Remember with M1K3",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: SearchKnowledgeIntent(),
            phrases: [
                "Search \(.applicationName)'s knowledge",
                "Search \(.applicationName) for something",
            ],
            shortTitle: "Search Knowledge",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: RecallMemoryIntent(),
            phrases: [
                "Recall a memory from \(.applicationName)",
                "What does \(.applicationName) remember about",
            ],
            shortTitle: "Recall Memory",
            systemImageName: "brain.head.profile"
        )
        AppShortcut(
            intent: ListTodosIntent(),
            phrases: [
                "List \(.applicationName)'s todos",
                "What's on \(.applicationName)'s list",
            ],
            shortTitle: "List Todos",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: ProposeTodoIntent(),
            phrases: [
                "Add a todo with \(.applicationName)",
                "Have \(.applicationName) add a task",
            ],
            shortTitle: "Add Todo",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: OpenVoiceModeIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Open \(.applicationName) voice mode",
            ],
            shortTitle: "Talk to M1K3",
            systemImageName: "mic"
        )
    }
}
