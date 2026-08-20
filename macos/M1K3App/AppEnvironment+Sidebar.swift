//
//  AppEnvironment+Sidebar.swift
//  M1K3App
//
//  The leading sidebar's navigation model. `SidebarSelection` is what the
//  sidebar List binds its selection to and ContentView's detail switch reads;
//  `.conversation(id)` is a TRANSIENT pick (ContentView's onChange switches
//  the conversation and immediately snaps selection back to `.chat` — tapping
//  a past conversation should show it, not leave you staring at a picker).
//
//  Deliberately local @State in ContentView, NOT promoted to AppEnvironment
//  (unlike env.review.isPresented): nothing outside the view tree needs to
//  drive which sidebar destination is showing today. Only the sidebar's
//  VISIBILITY persists (mirrors AppEnvironment+Avatar.swift's avatarDisplayKey
//  shape) — the selection itself resets to .chat every launch, matching the
//  app's existing "chat is the front door" convention.
//
//  Signed: Kev + claude-fable-5, 2026-07-19, Confidence 0.85 (thin nav-state
//  glue; verify-by-launch). Prior: Unknown
//

import Foundation

/// What the sidebar + detail pane are showing.
enum SidebarSelection: Hashable {
    case chat
    case documents
    case memories
    case calls
    /// The Heartbeat timeline — promoted from a summoned Window to a real
    /// destination 2026-08-19 (it stays selected + swaps the detail pane,
    /// which is exactly the destination-vs-app-action line SidebarView
    /// polices). Other scenes reach it via `pendingSidebarRequest`.
    case heartbeat
    /// A tap on a past-conversation row — transient, see file header.
    case conversation(UUID)
}

extension AppEnvironment {
    /// Persisted sidebar column visibility (`NavigationSplitViewVisibility`
    /// isn't UserDefaults-storable directly — ContentView stores this Bool
    /// and bridges it via a computed Binding, the same shape as
    /// `avatarDisplayKey`/`AvatarDisplay`).
    nonisolated static let sidebarVisibleKey = "sidebar.visible"
}
