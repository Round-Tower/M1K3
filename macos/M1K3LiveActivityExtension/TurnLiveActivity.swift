//
//  TurnLiveActivity.swift
//  M1K3LiveActivityExtension
//
//  The Lock Screen card and the Dynamic Island (compact, minimal, expanded) for a long answer or a
//  file read: "M1K3 is thinking… / reading… / answering…", then "Answer ready". Tapping any of it
//  opens the chat (`m1k3://chat`, no question in the URL). Dark, like the app: the same near-black
//  navy the onboarding and the chat field use, system type so Dynamic Type works, one combined
//  VoiceOver element per surface.
//
//  The extension has a ~30 MB ceiling: it links M1K3LiveActivity (Foundation + ActivityKit) and
//  nothing else from the package.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.6 (compile-checked only; layout, tint and
//  the Island's three sizes are verify-on-device), Prior: none (new file).

import ActivityKit
import M1K3LiveActivity
import SwiftUI
import WidgetKit

@main
struct M1K3LiveActivityBundle: WidgetBundle {
    var body: some Widget {
        TurnLiveActivity()
    }
}

struct TurnLiveActivity: Widget {
    private static let background = Color(red: 0.05, green: 0.05, blue: 0.11)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurnActivityAttributes.self) { context in
            TurnLockScreenView(copy: TurnActivityCopy(phase: context.state.phase))
                .activityBackgroundTint(Self.background)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(TurnActivityLink.url)
        } dynamicIsland: { context in
            let copy = TurnActivityCopy(phase: context.state.phase)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TurnSymbol(copy: copy).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(copy.title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(copy.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } compactLeading: {
                TurnSymbol(copy: copy)
            } compactTrailing: {
                Text(copy.short)
                    .font(.caption2)
                    .lineLimit(1)
            } minimal: {
                TurnSymbol(copy: copy)
            }
            .widgetURL(TurnActivityLink.url)
        }
    }
}

/// The phase's symbol: still (nothing animates, so Reduce Motion has nothing to honour), labelled for VoiceOver.
private struct TurnSymbol: View {
    let copy: TurnActivityCopy

    var body: some View {
        Image(systemName: copy.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(copy.isWorking ? Color.accentColor : Color.white)
            .accessibilityLabel(copy.title)
    }
}

private struct TurnLockScreenView: View {
    let copy: TurnActivityCopy

    var body: some View {
        HStack(spacing: 12) {
            TurnSymbol(copy: copy).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.title).font(.headline)
                Text(copy.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}
