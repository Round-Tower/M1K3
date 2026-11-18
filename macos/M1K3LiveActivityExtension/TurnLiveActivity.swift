//
//  TurnLiveActivity.swift
//  M1K3LiveActivityExtension
//
//  The Lock Screen card and the Dynamic Island (compact, minimal, expanded) for a long answer or a
//  file read: "M1K3 is thinking… / reading… / answering…", then "Answer ready". Tapping any of it
//  opens the chat (`m1k3://chat`, no question in the URL). On brand (TurnBrand): the pixel face as the
//  mark, Silkscreen for the title and the compact word, phosphor on ink; the detail line is system type
//  so Dynamic Type works. One combined VoiceOver element per surface.
//
//  The extension has a ~30 MB ceiling: it links M1K3LiveActivity (Foundation + ActivityKit) and
//  nothing else from the package.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.6 (compile-checked; layout, tint and
//  the Island's three sizes are verify-on-device), Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-16 — Kev: "It doesn't look on brand." SF Symbols and the system
//  blue are gone: the pixel face, Silkscreen and the brand ink and phosphor (TurnBrand).
//  Review: Kev + claude-opus-5.5, 2026-11-17 — passes `context.isStale` to the copy (the stale look). Compile-checked.

import ActivityKit
import M1K3LiveActivity
import SwiftUI
import WidgetKit

@main
struct M1K3LiveActivityBundle: WidgetBundle {
    init() {
        TurnBrand.registerFonts()
    }

    var body: some Widget {
        TurnLiveActivity()
    }
}

struct TurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurnActivityAttributes.self) { context in
            TurnLockScreenView(copy: TurnActivityCopy(phase: context.state.phase, isStale: context.isStale))
                .activityBackgroundTint(TurnBrand.ink)
                .activitySystemActionForegroundColor(TurnBrand.mark)
                .widgetURL(TurnActivityLink.url)
        } dynamicIsland: { context in
            let copy = TurnActivityCopy(phase: context.state.phase, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TurnFaceMark(copy: copy)
                        .frame(width: 44, height: 37)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(copy.title)
                        .font(TurnBrand.pixel(15))
                        .foregroundStyle(copy.titleColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(copy.detail)
                        .font(.subheadline)
                        .foregroundStyle(TurnBrand.detail)
                        .multilineTextAlignment(.center)
                }
            } compactLeading: {
                TurnFaceMark(copy: copy)
                    .frame(width: 24, height: 20)
            } compactTrailing: {
                Text(copy.short)
                    .font(TurnBrand.pixel(12))
                    .foregroundStyle(copy.titleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityHidden(true) // the face carries the label
            } minimal: {
                TurnFaceMark(copy: copy)
                    .frame(width: 22, height: 18)
            }
            .keylineTint(TurnBrand.phosphor)
            .widgetURL(TurnActivityLink.url)
        }
    }
}

private struct TurnLockScreenView: View {
    let copy: TurnActivityCopy

    var body: some View {
        HStack(spacing: 14) {
            TurnFaceMark(copy: copy)
                .frame(width: 52, height: 44)
                .accessibilityHidden(true) // the title below says it; combined, VoiceOver read it twice
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.title)
                    .font(TurnBrand.pixel(15))
                    .foregroundStyle(copy.titleColor)
                Text(copy.detail)
                    .font(.subheadline)
                    .foregroundStyle(TurnBrand.detail)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}
