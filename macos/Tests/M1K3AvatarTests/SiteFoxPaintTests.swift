//
//  SiteFoxPaintTests.swift
//  M1K3AvatarTests
//
//  The site Fox in the app (Kev, 2026-10-22: "go with the site fox, it's iconic"): solid black
//  triangles under a white lattice, as m1k3.app draws it. The baked body (0x111111, roughness .55,
//  metallic .25) is lit PBR, so the app's lighting washed it to grey; the paint is unlit black.
//  Seasons colour the LATTICE, not the body. Which mesh part is which, when the paint applies and
//  what colour the lines take are pinned here; the RealityKit glue is verify-by-launch.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-22, Confidence 0.85 (rule pinned; part names read off
//  the shipped USDZ in a Simulator log: fox1 slot 0, fox_wire_mesh slot 1). Prior: none (new file).
//

@testable import M1K3Avatar
import Testing

struct SiteFoxPaintTests {
    @Test("the lattice is the fox_wire part; everything else on the Fox is body")
    func partRoles() {
        #expect(SiteFoxPaint.role(ofPart: "fox_wire_mesh") == .lattice)
        #expect(SiteFoxPaint.role(ofPart: "FOX_WIRE") == .lattice)
        #expect(SiteFoxPaint.role(ofPart: "fox1") == .body)
        #expect(SiteFoxPaint.role(ofPart: "fox") == .body)
    }

    @Test("only a model that carries a lattice part gets the site paint")
    func onlyTheLatticeFox() {
        #expect(SiteFoxPaint.applies(toParts: ["fox1", "fox_wire_mesh"], style: .off))
        #expect(!SiteFoxPaint.applies(toParts: ["Gecko_Body", "Gecko_Eyes"], style: .off))
        #expect(!SiteFoxPaint.applies(toParts: [], style: .off))
    }

    @Test("the default and phosphor styles get the site paint; cel keeps its own shader")
    func stylesThatPaint() {
        let fox = ["fox1", "fox_wire_mesh"]
        #expect(SiteFoxPaint.applies(toParts: fox, style: .off))
        #expect(SiteFoxPaint.applies(toParts: fox, style: .phosphor))
        #expect(!SiteFoxPaint.applies(toParts: fox, style: .cel))
    }

    @Test("out of season the lattice is the site's white 0xe8e8e8")
    func whiteLattice() {
        let white = SiteFoxPaint.latticeColour(style: .off, treatment: .calm)
        #expect(white == SIMD3<Float>(0.91, 0.91, 0.91))
        #expect(SiteFoxPaint.latticeColour(style: .off, treatment: .halloweenCalm) == white)
    }

    @Test("under phosphor (a season wears it) the lattice takes the treatment's colour")
    func seasonalLattice() {
        let pumpkin = SiteFoxPaint.latticeColour(style: .phosphor, treatment: .halloweenCalm)
        #expect(pumpkin == SIMD3<Float>(1.0, 0.541, 0.122))
        let runway = SiteFoxPaint.latticeColour(style: .phosphor, treatment: .flightCalm)
        #expect(runway == SIMD3<Float>(PhosphorTreatment.flightCalm.red, PhosphorTreatment.flightCalm.green,
                                       PhosphorTreatment.flightCalm.blue))
    }

    @Test("the body is solid black, so the triangles read as the site's")
    func blackBody() {
        #expect(SiteFoxPaint.bodyColour == SIMD3<Float>(0, 0, 0))
    }

    @Test("every seasonal lattice is bright enough to read on black (relative luminance ≥ 0.45)")
    func latticeReadsOnBlack() {
        func luminance(_ t: PhosphorTreatment) -> Float {
            0.2126 * t.red + 0.7152 * t.green + 0.0722 * t.blue
        }
        for t in [PhosphorTreatment.flightCalm, .flightSpeaking, .flightThinking, .flightListening,
                  .halloweenCalm, .halloweenSpeaking, .halloweenThinking, .halloweenListening]
        {
            #expect(luminance(t) >= 0.45, "\(t) is too dark for a line on black")
        }
    }
}
