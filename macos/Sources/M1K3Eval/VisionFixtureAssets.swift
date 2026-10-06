//
//  VisionFixtureAssets.swift
//  M1K3Eval
//
//  Resolves a vision fixture's image name to the PNG shipped in this module's
//  bundle (`Resources/VisionFixtures`, drawn by
//  tools/eval/make_vision_fixtures.swift). The eval stage hands the URL to the
//  production chat path as an `ImageAttachment`.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-06, Confidence 0.85, Prior: none (new
//  file; GEMMA_1_1_PLAN Stream A).

import Foundation

public enum VisionFixtureAssets {
    /// The bundled PNG for `name` (no extension), or nil when it doesn't ship.
    public static func url(for name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "VisionFixtures")
    }
}
