//
//  BrainAtHomeSettingsPane.swift
//  M1K3App
//
//  The "Brain at Home" Settings pane (1.1; Kev, TestFlight: Brain at Home gets its own header,
//  it used to sit at the foot of Privacy): a grouped Form around BrainAtHomeSection, which
//  owns the serve toggle, the pairing ceremony and the paired-device list.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (a Form wrapper; the section
//  itself is unchanged and signed in BrainAtHomeSection.swift). Prior: Unknown (new file;
//  the mount line came from PrivacySettingsPane.swift).
//

import SwiftUI

struct BrainAtHomeSettingsPane: View {
    var body: some View {
        Form {
            BrainAtHomeSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
