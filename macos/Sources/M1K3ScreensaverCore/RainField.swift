//
//  RainField.swift
//  M1K3ScreensaverCore
//
//  The ambient pixel-rain for the screensaver — blocks drifting upward through
//  the phosphor, the same CRT/data-rain language as the in-app thinking-rain
//  (M1K3Avatar.InferencePhosphor), but self-contained so the sandboxed `.saver`
//  process links no app modules.
//
//  Pure + DETERMINISTIC: seeded SplitMix64, no Foundation RNG, so a test can
//  advance the field and assert exact positions (and CI stays reproducible).
//  The `.saver` calls `advance(by:)` once per frame and draws `drops`.
//
//  Signed: Kev + claude-opus-4-8, 2026-08-20, Confidence 0.85 (pure sim,
//  TDD'd; the felt density/speed is a verify-by-eye taste call on the surface).
//  Prior: InferencePhosphor's rising-glyph model (2026-08-19).
//

/// One falling/rising block in the rain. `column` indexes the grid; `y` is the
/// unit vertical position (0 = top, 1 = bottom); `brightness` its current glow.
public struct RainDrop: Sendable, Equatable {
    public let column: Int
    public var y: Double
    public var speed: Double
    public var brightness: Double

    public init(column: Int, y: Double, speed: Double, brightness: Double) {
        self.column = column
        self.y = y
        self.speed = speed
        self.brightness = brightness
    }
}

public struct RainField: Sendable {
    public private(set) var drops: [RainDrop] = []
    public let columns: Int

    private var state: UInt64

    /// - Parameters:
    ///   - columns: number of vertical lanes across the width.
    ///   - density: drops per column on average (0…several).
    ///   - seed: SplitMix64 seed — same seed ⇒ same rain (deterministic tests).
    public init(columns: Int = 40, density: Double = 1.4, seed: UInt64 = 0x4D31_4B33) {
        self.columns = max(1, columns)
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        let perColumn = max(0, density)
        for col in 0 ..< self.columns {
            let n = Int(perColumn.rounded()) + (nextUnit() < (perColumn - perColumn.rounded() + 0.5) ? 1 : 0)
            for _ in 0 ..< max(0, n) {
                drops.append(spawn(in: col))
            }
        }
    }

    // MARK: - Deterministic unit random (SplitMix64)

    private mutating func nextUnit() -> Double {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        // 53-bit mantissa → [0,1)
        return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    private mutating func spawn(in column: Int) -> RainDrop {
        RainDrop(
            column: column,
            y: nextUnit(),
            speed: 0.03 + nextUnit() * 0.07, // unit / second, gentle
            brightness: 0.25 + nextUnit() * 0.75
        )
    }

    // MARK: - Advance

    /// Advance the field by `dt` seconds. Drops rise (y decreases); a drop that
    /// climbs past the top respawns at the bottom in the same lane with a fresh
    /// speed/brightness, so the field is stationary in aggregate (constant
    /// density) — the CRT never empties or piles up.
    public mutating func advance(by dt: Double) {
        guard dt > 0 else { return }
        for i in drops.indices {
            drops[i].y -= drops[i].speed * dt
            if drops[i].y < -0.02 {
                let respawn = spawn(in: drops[i].column)
                drops[i].y = 1.02
                drops[i].speed = respawn.speed
                drops[i].brightness = respawn.brightness
            }
        }
    }
}
