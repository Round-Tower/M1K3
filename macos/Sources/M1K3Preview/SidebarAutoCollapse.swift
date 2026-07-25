//
//  SidebarAutoCollapse.swift
//  M1K3Preview
//
//  The narrow-window sidebar behaviour macOS never gave us. On iPhone/iPad,
//  NavigationSplitView's `.automatic` adapts to size classes; on macOS it just
//  leaves the sidebar pinned, which at 560pt clips the nav labels off the
//  window edge (Kev's 07-25 report). This is the missing behaviour as a pure
//  transition machine, edge-triggered on purpose:
//
//  - CROSSING below the threshold collapses the sidebar (transient — the
//    persisted preference is untouched).
//  - CROSSING back above restores whatever the user prefers.
//  - Resizing WITHIN a band is nil (no opinion): a user who explicitly
//    re-opened the sidebar on a narrow window keeps it until the next crossing
//    — width must not keep slamming it shut.
//
//  Threshold = sidebar min column (220) + the chat detail floor (480): below
//  700pt both cannot honestly fit.
//
//  Lives in M1K3Preview with the other window-chrome policies (the review
//  panel router) so the app target stays glue-only.
//
//  Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.9, Prior: Unknown
//

import CoreGraphics

public enum SidebarAutoCollapse {
    /// Below this window width the sidebar auto-collapses: 220 (sidebar min
    /// column) + 480 (chat detail floor).
    public static let threshold: CGFloat = 700

    /// The effective-visibility transition for a width change.
    /// - Returns: The new effective visibility, or nil when this resize is no
    ///   crossing and the current state should stand.
    public static func transition(
        from oldWidth: CGFloat?,
        to newWidth: CGFloat,
        preferredVisible: Bool
    ) -> Bool? {
        guard let oldWidth else {
            // First layout: collapse if born narrow, else honour the preference.
            return newWidth < threshold ? false : preferredVisible
        }
        let wasWide = oldWidth >= threshold
        let isWide = newWidth >= threshold
        guard wasWide != isWide else { return nil }
        return isWide ? preferredVisible : false
    }

    /// Whether an explicit visibility write should persist as the preference.
    /// Only wide-window writes persist — while auto-collapsed, the system
    /// echoing `.detailOnly` back through the binding must not clobber the
    /// user's real preference. A pre-layout write (nil width) can only be the
    /// user's own toggle, so it persists.
    public static func persistsPreference(atWidth width: CGFloat?) -> Bool {
        guard let width else { return true }
        return width >= threshold
    }
}
