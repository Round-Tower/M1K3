//
//  WindowField.swift
//  M1K3iOS / M1K3visionOS
//
//  The one floor the chat and voice screens sit on (Kev, 2026-10-09: voice mode
//  should have the window's background, like the open chat — not a private one).
//  iOS: the window's own field, `.background`, the phone's counterpart of the
//  Mac's behind-window glass. visionOS: the deep gradient the screens always had —
//  `Color.clear` would hand the floor to the system glass pane, which the
//  challenger ruled NO-GO until a RealityView hero over it is seen on a device
//  (a bright creature on pale glass loses its contrast). Non-interactive.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.7 (the iOS arm is
//  near-invisible under the 1.1 forced dark; the visionOS arm is unchanged by
//  design). Prior: none (new file; the gradient was ChatScreen's and VoiceScreen's).
//

import SwiftUI

struct WindowField: View {
    var body: some View {
        #if os(visionOS)
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.05, blue: 0.11), .black],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        #else
            Rectangle().fill(.background)
                .allowsHitTesting(false)
        #endif
    }
}
