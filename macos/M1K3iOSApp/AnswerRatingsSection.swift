//
//  AnswerRatingsSection.swift
//  M1K3iOS / M1K3visionOS
//
//  Settings ▸ Answer ratings (Kev, 2026-10-13): how many answers carry a thumbs,
//  and Export ratings (JSONL), a share-sheet file in AnswerFeedbackExport's
//  eval-fixture shape. AirDrop it to the Mac and run tools/eval/ratings_report.py.
//  Read once when the section appears; ratings can't change while Settings is up.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.8 (verify-by-launch;
//  the export itself is pinned in PhoneAnswerActionsTests). Prior: none (new file).
//  Review: Kev + claude-opus-5-5, 2026-10-13 (#597 follow-up) — one read off the main actor
//  (`loadAnswerRatings`), Clear ratings behind a confirmation, and a footer that says the file
//  holds each question and answer, not only the thumbs. Confidence 0.85.
//  TDD_SKIP: view body.
//

import CoreTransferable
import M1K3Chat
import SwiftUI
import UniformTypeIdentifiers

struct AnswerRatingsSection: View {
    @Environment(AppCore.self) private var core
    @State private var ratings = AnswerRatings(count: 0, jsonl: "")
    @State private var confirmClear = false

    var body: some View {
        Section {
            LabeledContent("Rated answers", value: "\(ratings.count)")
            ShareLink(
                item: AnswerRatingsFile(jsonl: ratings.jsonl),
                preview: SharePreview("M1K3 answer ratings")
            ) {
                Label("Export ratings (JSONL)", systemImage: "square.and.arrow.up")
            }
            .disabled(ratings.count == 0)
            Button("Clear ratings", role: .destructive) { confirmClear = true }
                .disabled(ratings.count == 0)
                .confirmationDialog(
                    "Delete all \(ratings.count) ratings?", isPresented: $confirmClear, titleVisibility: .visible
                ) {
                    Button("Delete ratings", role: .destructive) {
                        Task {
                            await core.chat.clearAnswerRatings()
                            ratings = await core.chat.loadAnswerRatings()
                        }
                    }
                } message: {
                    Text("Every thumb and note goes. Your conversations stay.")
                }
        } header: {
            Text("Answer ratings")
        } footer: {
            Text("Your thumbs up and down, with any notes, and the question and answer each one rates. "
                + "They stay on this device unless you export them.")
        }
        .task { ratings = await core.chat.loadAnswerRatings() }
    }
}

/// The ratings export as a file the share sheet can save or AirDrop: JSONL, one
/// rated answer per line.
private struct AnswerRatingsFile: Transferable {
    let jsonl: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType(filenameExtension: "jsonl") ?? .plainText) { file in
            Data(file.jsonl.utf8)
        }
        .suggestedFileName("m1k3-answer-ratings.jsonl")
    }
}
