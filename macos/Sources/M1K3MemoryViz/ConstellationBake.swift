//
//  ConstellationBake.swift
//  M1K3MemoryViz
//
//  The settled constellation as a handful of merged meshes. Every memory was its own
//  ModelEntity (a generated sphere and a material each) and every edge another, so
//  ~450 memories drew as ~1,000 entities, and RealityKit's render loop runs at display
//  rate while the field is mounted, paused or not. Measured 2026-10-20 on Kev's M1 Max,
//  idle in front, paused: the Constellation held M1K3 at ~132% CPU, the Fox at ~65%.
//  The motes never move relative to each other (only the whole field breathes, floats
//  and spins), so the view bakes them into one mesh per colour and the threads into one
//  mesh: the same picture in a few draws. Pure geometry here; the view owns the swap.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-20, Confidence 0.75 (the geometry is TDD'd;
//  the CPU win is verify-by-launch). Prior: none.
//

import simd

public enum ConstellationBake {
    /// Merged triangle geometry.
    public struct Parts: Equatable, Sendable {
        public var positions: [SIMD3<Float>] = []
        public var normals: [SIMD3<Float>] = []
        public var indices: [UInt32] = []

        public init() {}

        public mutating func append(_ other: Parts) {
            let offset = UInt32(positions.count)
            positions += other.positions
            normals += other.normals
            indices += other.indices.map { $0 + offset }
        }
    }

    /// A mote's colour, as the palette takes it. Kinds map to a handful of these.
    public struct Colour: Hashable, Sendable {
        public let hue: Float
        public let saturation: Float

        public init(hue: Float, saturation: Float) {
            self.hue = hue
            self.saturation = saturation
        }
    }

    public struct Mote: Sendable {
        public let center: SIMD3<Float>
        public let radius: Float
        public let colour: Colour

        public init(center: SIMD3<Float>, radius: Float, colour: Colour) {
            self.center = center
            self.radius = radius
            self.colour = colour
        }
    }

    /// Latitude bands and longitude segments per mote: a round silhouette at hub size.
    static let rings = 12
    static let segments = 24

    /// Every mote merged into one mesh per colour.
    public static func motes(_ motes: [Mote]) -> [Colour: Parts] {
        var groups: [Colour: Parts] = [:]
        for mote in motes {
            groups[mote.colour, default: Parts()].append(sphere(center: mote.center, radius: mote.radius))
        }
        return groups
    }

    /// Every thread merged into one mesh. A zero-length thread has no direction, so it is skipped.
    public static func threads(_ ends: [(SIMD3<Float>, SIMD3<Float>)], thickness: Float) -> Parts {
        var parts = Parts()
        for (from, to) in ends where simd_distance(from, to) > 1e-6 {
            parts.append(box(from: from, to: to, thickness: thickness))
        }
        return parts
    }

    /// A UV sphere.
    static func sphere(center: SIMD3<Float>, radius: Float) -> Parts {
        var parts = Parts()
        for ring in 0 ... rings {
            let theta = Float(ring) / Float(rings) * .pi
            for segment in 0 ... segments {
                let phi = Float(segment) / Float(segments) * 2 * .pi
                let normal = SIMD3<Float>(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
                parts.positions.append(center + normal * radius)
                parts.normals.append(normal)
            }
        }
        let row = UInt32(segments + 1)
        for ring in 0 ..< UInt32(rings) {
            for segment in 0 ..< UInt32(segments) {
                let a = ring * row + segment, b = a + row
                parts.indices += [a, a + 1, b, b, a + 1, b + 1]
            }
        }
        return parts
    }

    /// A thin box from `from` to `to`, flat-shaded (four vertices per face), as the old
    /// per-edge `generateBox` drew it: +Y is the long axis, turned toward the far mote.
    static func box(from: SIMD3<Float>, to: SIMD3<Float>, thickness: Float) -> Parts {
        let half = SIMD3<Float>(thickness / 2, simd_distance(from, to) / 2, thickness / 2)
        let rotation = ConstellationGeometry.orientation(from: from, to: to)
        let mid = ConstellationGeometry.midpoint(from, to)
        // Each face: its normal and two in-plane axes, corners wound counter-clockwise from outside.
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            ([1, 0, 0], [0, 0, -1], [0, 1, 0]), ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
            ([0, 1, 0], [1, 0, 0], [0, 0, -1]), ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [-1, 0, 0], [0, 1, 0]),
        ]
        var parts = Parts()
        for (normal, u, v) in faces {
            let base = UInt32(parts.positions.count)
            for (su, sv) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                let local = (normal + u * su + v * sv) * half
                parts.positions.append(mid + rotation.act(local))
                parts.normals.append(rotation.act(normal))
            }
            parts.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return parts
    }
}
