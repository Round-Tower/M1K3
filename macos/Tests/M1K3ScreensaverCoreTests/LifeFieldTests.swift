//
//  LifeFieldTests.swift
//  M1K3ScreensaverCoreTests
//
//  Conway's Game of Life (B3/S23) on a torus, the ambient field behind the
//  Settings header and the store frames. The rules are the classic ones, so
//  the tests are the classic patterns; the M1K3-specific parts are the ages
//  (newborns glow brightest) and the reseed that keeps an ambient field from
//  ever going dark or freezing.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-23, Confidence 0.9, Prior: Unknown
//

@testable import M1K3ScreensaverCore
import Testing

struct LifeFieldTests {
    @Test("a blinker oscillates with period 2")
    func blinker() {
        var field = LifeField(columns: 5, rows: 5, alive: [(1, 2), (2, 2), (3, 2)])
        field.step()
        #expect(field.aliveCells == [Cell(2, 1), Cell(2, 2), Cell(2, 3)])
        field.step()
        #expect(field.aliveCells == [Cell(1, 2), Cell(2, 2), Cell(3, 2)])
    }

    @Test("a block is a still life")
    func block() {
        var field = LifeField(columns: 6, rows: 6, alive: [(2, 2), (3, 2), (2, 3), (3, 3)])
        let before = field.aliveCells
        field.step()
        #expect(field.aliveCells == before)
    }

    @Test("a glider travels one cell diagonally every four generations, wrapping the torus")
    func gliderWraps() {
        // The standard south-east glider.
        let glider = [(1, 0), (2, 1), (0, 2), (1, 2), (2, 2)]
        var field = LifeField(columns: 6, rows: 6, alive: glider)
        for _ in 0 ..< 4 {
            field.step()
        }
        #expect(field.aliveCells == Set(glider.map { Cell($0.0 + 1, $0.1 + 1) }))
        // 24 generations later it has crossed the 6x6 torus and is home again.
        for _ in 0 ..< 20 {
            field.step()
        }
        #expect(field.aliveCells == Set(glider.map { Cell(($0.0 + 6) % 6, ($0.1 + 6) % 6) }))
    }

    @Test("a newborn cell has age 1 and a survivor ages each generation, capped")
    func ages() {
        var field = LifeField(columns: 6, rows: 6, alive: [(2, 2), (3, 2), (2, 3), (3, 3)])
        #expect(field.age(column: 2, row: 2) == 1)
        field.step()
        #expect(field.age(column: 2, row: 2) == 2)
        for _ in 0 ..< 300 {
            field.step()
        }
        #expect(field.age(column: 2, row: 2) == LifeField.maxAge)
        #expect(field.age(column: 0, row: 0) == 0)
    }

    @Test("the same seed makes the same soup; a different seed makes a different one")
    func deterministicSoup() {
        let first = LifeField(columns: 32, rows: 18, density: 0.3, seed: 7)
        let again = LifeField(columns: 32, rows: 18, density: 0.3, seed: 7)
        let other = LifeField(columns: 32, rows: 18, density: 0.3, seed: 8)
        #expect(first.aliveCells == again.aliveCells)
        #expect(first.aliveCells != other.aliveCells)
        #expect(first.population > 32 * 18 / 10) // roughly the density asked for
        #expect(first.population < 32 * 18 / 2)
    }

    @Test("an ambient field never goes dark: a dead field reseeds itself")
    func deadFieldReseeds() {
        var field = LifeField(columns: 20, rows: 12, alive: [(5, 5)], seed: 3) // a lone cell dies at once
        for _ in 0 ..< LifeField.staleGenerations + 2 {
            field.advance()
        }
        #expect(field.population > 0)
    }

    @Test("an ambient field never freezes: a still life gets company after the stale window")
    func frozenFieldReseeds() {
        var field = LifeField(columns: 20, rows: 12, alive: [(2, 2), (3, 2), (2, 3), (3, 3)], seed: 3)
        for _ in 0 ..< LifeField.staleGenerations - 1 {
            field.advance()
        }
        #expect(field.population == 4) // still just the block
        field.advance()
        field.advance()
        #expect(field.population > 4) // company arrived
    }

    @Test("a blinker counts as frozen too — period-2 life is not ambient motion")
    func oscillatorReseeds() {
        var field = LifeField(columns: 20, rows: 12, alive: [(9, 6), (10, 6), (11, 6)], seed: 5)
        for _ in 0 ..< LifeField.staleGenerations + 2 {
            field.advance()
        }
        #expect(field.population > 3)
    }

    @Test("degenerate sizes clamp instead of trapping")
    func degenerate() {
        var field = LifeField(columns: 0, rows: -3, density: 0.5, seed: 1)
        field.advance()
        #expect(field.columns >= 1)
        #expect(field.rows >= 1)
    }
}
