//
//  CompanionShadingStyleTests.swift
//  M1K3AvatarTests
//
//  Pins the style→shader-function map (the names must match Phosphor.metal's
//  [[visible]] entry points), the off→baked contract, and which style needs the
//  original texture (cel). The on-screen look is verify-at-⌘R; the routing is not.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-18, Confidence 0.95 (pure map). Prior: Unknown.
//

@testable import M1K3Avatar
import Testing

struct CompanionShadingStyleTests {
    @Test("off keeps the baked materials — no shader, no texture rebuild")
    func offUsesNoShader() {
        #expect(CompanionShadingStyle.off.shaderFunctionName == nil)
        #expect(CompanionShadingStyle.off.usesShader == false)
        #expect(CompanionShadingStyle.off.usesOriginalTexture == false)
    }

    @Test("each glow style maps to its metallib function name")
    func glowStyleFunctions() {
        #expect(CompanionShadingStyle.phosphor.shaderFunctionName == "phosphorSurface")
        #expect(CompanionShadingStyle.cel.shaderFunctionName == "celSurface")
    }

    @Test("cel adapts the original texture; phosphor does not")
    func textureUse() {
        #expect(CompanionShadingStyle.cel.usesOriginalTexture)
        #expect(CompanionShadingStyle.phosphor.usesOriginalTexture == false)
    }

    @Test("every glow style reports usesShader true")
    func glowStylesUseShader() {
        for style in CompanionShadingStyle.allCases where style != .off {
            #expect(style.usesShader, "\(style.rawValue) should use a shader")
        }
    }

    @Test("rawValue round-trips (the @AppStorage persistence contract)")
    func rawValueRoundTrips() {
        for style in CompanionShadingStyle.allCases {
            #expect(CompanionShadingStyle(rawValue: style.rawValue) == style)
        }
    }

    @Test("every style has a non-empty display name")
    func displayNames() {
        for style in CompanionShadingStyle.allCases {
            #expect(!style.displayName.isEmpty)
        }
    }

    @Test("a season costumes only the Phosphor Fox: the lattice is what it colours, and the others have none")
    func seasonIsFoxOnly() {
        // Kev's iPhone, 2026-10-30: the costume is a rim glow on a near-black body on anything else,
        // which "looks poor". The fox wears it; the others keep their own textures through a season.
        #expect(CompanionShadingStyle.off.wearing(.halloween, on: .phosphorFox) == .phosphor)
        #expect(CompanionShadingStyle.off.wearing(.flightClub, on: .phosphorFox) == .phosphor)
        for spec in CompanionSpec.all where spec != .phosphorFox {
            #expect(CompanionShadingStyle.off.wearing(.halloween, on: spec) == .off, "\(spec.id)")
            #expect(CompanionShadingStyle.cel.wearing(.flightClub, on: spec) == .cel, "\(spec.id)")
        }
    }

    @Test("out of season, the user's pick stands on every companion")
    func outOfSeason() {
        for spec in CompanionSpec.all {
            #expect(CompanionShadingStyle.cel.wearing(nil, on: spec) == .cel, "\(spec.id)")
        }
    }
}
