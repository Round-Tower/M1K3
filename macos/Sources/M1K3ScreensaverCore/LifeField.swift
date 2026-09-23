//
//  LifeField.swift
//  M1K3ScreensaverCore
//
//  Conway's Game of Life (B3/S23) on a torus — the ambient field behind the
//  Settings header (and the store frames' backgrounds, which port the same
//  rules to JS). The phosphor rain says "thinking"; the Life field says
//  "alive, quietly": cells are born, age and die on their own, the way M1K3's
//  memory and heartbeat keep ticking while nobody is typing.
//
//  Two M1K3 additions to the classic rules:
//    - every live cell carries an AGE (1 = newborn, capped), so a renderer can
//      light births brightest and let old still-lifes sink into the background;
//    - `advance()` never lets the field go dark or freeze: after
//      `staleGenerations` without change (a die-off, a still life, a period-2
//      blinker) it drops a small seeded soup somewhere, so an ambient
//      background keeps moving forever. `step()` is the pure rule, untouched.
//
//  Pure + DETERMINISTIC (seeded SplitMix64, the RainField convention), so the
//  tests assert exact patterns and the frames render the same field every run.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-23, Confidence 0.9 (the rules are the
//  classic ones, pinned by the classic patterns; the reseed cadence and the
//  on-screen density are taste, verify-by-eye). Prior: Unknown
//

/// A grid coordinate. Column first, like `x, y`.
public struct Cell: Hashable, Sendable, CustomStringConvertible {
    public let column: Int
    public let row: Int

    public init(_ column: Int, _ row: Int) {
        self.column = column
        self.row = row
    }

    public var description: String {
        "(\(column),\(row))"
    }
}

public struct LifeField: Sendable, Equatable {
    /// Ages stop counting here — "old" is old enough for a renderer.
    public static let maxAge: UInt8 = 60
    /// Generations without change before `advance()` reseeds.
    public static let staleGenerations = 24

    public let columns: Int
    public let rows: Int
    public private(set) var generation = 0

    /// Row-major; 0 = dead, otherwise the cell's age.
    private var ages: [UInt8]
    private var state: UInt64
    /// Signatures of the last two generations (period ≤ 2 counts as frozen).
    private var recent: [Int] = []
    private var staleCount = 0

    /// A random soup: each cell alive with probability `density`.
    public init(columns: Int, rows: Int, density: Double, seed: UInt64 = 0x4D31_4B33) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        ages = Array(repeating: 0, count: self.columns * self.rows)
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        let density = min(max(density, 0), 1)
        for index in ages.indices where nextUnit() < density {
            ages[index] = 1
        }
    }

    /// An explicit pattern (the tests' classic shapes). `seed` drives reseeds.
    public init(columns: Int, rows: Int, alive: [(Int, Int)], seed: UInt64 = 0x4D31_4B33) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        ages = Array(repeating: 0, count: self.columns * self.rows)
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        for (column, row) in alive {
            ages[index(column, row)] = 1
        }
    }

    // MARK: - Reading

    public var population: Int {
        ages.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
    }

    public var aliveCells: Set<Cell> {
        var cells = Set<Cell>()
        for row in 0 ..< rows {
            for column in 0 ..< columns where ages[row * columns + column] > 0 {
                cells.insert(Cell(column, row))
            }
        }
        return cells
    }

    /// 0 when dead; 1 for a newborn, counting up to `maxAge`.
    public func age(column: Int, row: Int) -> UInt8 {
        ages[index(column, row)]
    }

    // MARK: - Rules

    /// One generation of B3/S23 on the torus.
    public mutating func step() {
        var next = ages
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let neighbours = liveNeighbours(column, row)
                let here = row * columns + column
                if ages[here] > 0 {
                    next[here] = (neighbours == 2 || neighbours == 3) ? min(ages[here] + 1, Self.maxAge) : 0
                } else {
                    next[here] = neighbours == 3 ? 1 : 0
                }
            }
        }
        ages = next
        generation += 1
    }

    /// `step()`, then reseed if the field has been dark or frozen (period ≤ 2)
    /// for `staleGenerations` — an ambient field must keep moving.
    public mutating func advance() {
        step()
        let signature = aliveSignature()
        if population == 0 || recent.contains(signature) {
            staleCount += 1
        } else {
            staleCount = 0
        }
        recent.append(signature)
        if recent.count > 2 { recent.removeFirst() }
        if staleCount >= Self.staleGenerations {
            sprinkle()
            staleCount = 0
            recent.removeAll()
        }
    }

    // MARK: - Internals

    private func index(_ column: Int, _ row: Int) -> Int {
        let c = ((column % columns) + columns) % columns
        let r = ((row % rows) + rows) % rows
        return r * columns + c
    }

    private func liveNeighbours(_ column: Int, _ row: Int) -> Int {
        var count = 0
        for dr in -1 ... 1 {
            for dc in -1 ... 1 where !(dr == 0 && dc == 0) {
                if ages[index(column + dc, row + dr)] > 0 { count += 1 }
            }
        }
        return count
    }

    /// Alive-set identity, ages ignored (a still life's ages keep climbing).
    private func aliveSignature() -> Int {
        var hasher = Hasher()
        for (offset, age) in ages.enumerated() where age > 0 {
            hasher.combine(offset)
        }
        return hasher.finalize()
    }

    /// A small seeded soup (about a third alive) in a random patch, sized to
    /// the field: enough to restart motion, never a flood.
    private mutating func sprinkle() {
        let width = max(3, min(columns, 8))
        let height = max(3, min(rows, 8))
        let originColumn = Int(nextUnit() * Double(columns))
        let originRow = Int(nextUnit() * Double(rows))
        for dr in 0 ..< height {
            for dc in 0 ..< width where nextUnit() < 0.38 {
                ages[index(originColumn + dc, originRow + dr)] = 1
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
        return Double(z >> 11) / Double(1 << 53)
    }
}
