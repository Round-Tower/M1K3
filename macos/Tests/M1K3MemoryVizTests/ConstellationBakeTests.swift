//
//  ConstellationBakeTests.swift
//  M1K3MemoryVizTests
//
//  The merged geometry the settled constellation draws: one mesh per mote colour plus
//  one for every thread, in place of an entity (and a draw) per memory and per edge.
//

@testable import M1K3MemoryViz
import simd
import Testing

struct ConstellationBakeTests {
    @Test("a sphere's vertices all sit on its radius around its centre")
    func sphereOnRadius() {
        let center = SIMD3<Float>(1, 2, 3)
        let parts = ConstellationBake.sphere(center: center, radius: 0.5)
        #expect(!parts.positions.isEmpty)
        #expect(parts.positions.count == parts.normals.count)
        for p in parts.positions {
            #expect(abs(simd_distance(p, center) - 0.5) < 0.0001)
        }
        #expect(parts.indices.count % 3 == 0)
        #expect(parts.indices.allSatisfy { Int($0) < parts.positions.count })
    }

    @Test("a thread box spans from one mote to the other at the given thickness")
    func boxSpansEndpoints() {
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(2, 0, 0)
        let parts = ConstellationBake.box(from: a, to: b, thickness: 0.01)
        #expect(parts.positions.count == 24)
        #expect(parts.indices.count == 36)
        let xs = parts.positions.map(\.x)
        #expect(abs((xs.min() ?? 9) - 0) < 0.0001)
        #expect(abs((xs.max() ?? 9) - 2) < 0.0001)
        let ys = parts.positions.map(\.y)
        #expect(abs((ys.max() ?? 9) - 0.005) < 0.0001)
    }

    @Test("appending offsets the second shape's indices past the first's vertices")
    func appendOffsetsIndices() {
        var merged = ConstellationBake.Parts()
        let one = ConstellationBake.box(from: .zero, to: SIMD3<Float>(0, 1, 0), thickness: 0.1)
        merged.append(one)
        merged.append(one)
        #expect(merged.positions.count == 48)
        #expect(merged.indices.count == 72)
        #expect(merged.indices[36] == one.indices[0] + 24)
    }

    @Test("motes merge into one mesh per colour, however many memories share it")
    func motesGroupByColour() {
        let red = ConstellationBake.Colour(hue: 0.0, saturation: 0.8)
        let blue = ConstellationBake.Colour(hue: 0.6, saturation: 0.5)
        let motes = [
            ConstellationBake.Mote(center: .zero, radius: 0.1, colour: red),
            ConstellationBake.Mote(center: SIMD3<Float>(1, 0, 0), radius: 0.1, colour: blue),
            ConstellationBake.Mote(center: SIMD3<Float>(0, 1, 0), radius: 0.2, colour: red),
        ]
        let groups = ConstellationBake.motes(motes)
        #expect(groups.count == 2)
        let single = ConstellationBake.sphere(center: .zero, radius: 0.1).positions.count
        #expect(groups[red]?.positions.count == 2 * single)
        #expect(groups[blue]?.positions.count == single)
    }

    @Test("a zero-length thread is skipped, not drawn as a NaN box")
    func zeroLengthThreadSkipped() {
        let parts = ConstellationBake.threads([(SIMD3<Float>(1, 1, 1), SIMD3<Float>(1, 1, 1))], thickness: 0.01)
        #expect(parts.positions.isEmpty)
    }
}
