//
//  BrainWordmark.swift
//  M1K3Chat
//
//  The small pixel tag beside the M1K3 wordmark on the chat's empty state:
//  MINI M1K3, LIL M1K3, BIG M1K3. It says which brain is in, in the face the
//  wordmark wears, and types on when the brain changes.
//
//  The tag is an app-controlled string (a brain's own short name), which is
//  what the pixel face's house rules allow (PixelFont.swift). A brain that
//  answers from somewhere else (Brain at Home, Private Cloud) gets no tag: the
//  wordmark never claims a brain on this device that is not the one answering.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-10, Confidence 0.8, Prior: none (new file)
//  Context: Kev, 2026-11-10: "adding an animation to the m1k3 pixelated title…
//  to either little, big, or mini… slightly abbreviated or smaller… we need to
//  use the pixelated font a bit more in animations and like the thinking and
//  loading sort of stuff."
//

import M1K3Inference

public enum BrainWordmark {
    /// The tag for the brain that answers, or nil when it is not on this device.
    public static func tag(for tier: BrainTier, elsewhere: Bool) -> String? {
        elsewhere ? nil : tier.displayName.uppercased()
    }

    /// The tag as typed so far: `step` letters of it.
    public static func typed(_ tag: String, step: Int) -> String {
        String(tag.prefix(max(0, step)))
    }
}
