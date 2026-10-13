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
//  TDD_SKIP: view body.
//

import CoreTransferable
import M1K3Chat
import SwiftUI
import UniformTypeIdentifiers

struct AnswerRatingsSection: View {
    @Environment(AppCore.self) private var core
    @State private var ratedAnswers = 0
    @State private var ratingsJSONL = ""

    var body: some View {
        Section {
            LabeledContent("Rated answers", value: "\(ratedAnswers)")
            ShareLink(
                item: AnswerRatingsFile(jsonl: ratingsJSONL),
                preview: SharePreview("M1K3 answer ratings")
            ) {
                Label("Export ratings (JSONL)", systemImage: "square.and.arrow.up")
            }
            .disabled(ratedAnswers == 0)
        } header: {
            Text("Answer ratings")
        } footer: {
            Text("Your thumbs up and down on M1K3's answers, with any notes. They stay on this device "
                + "until you export them, to see what worked and what didn't.")
        }
        .task {
            ratedAnswers = core.chat.ratedAnswerCount()
            ratingsJSONL = core.chat.answerRatingsJSONL()
        }
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
