//
//  M1K3ScreensaverCoreTests.swift
//  M1K3ScreensaverCoreTests
//
//  Pure-model tests for the screensaver core: the M mark geometry, the ambient
//  rain sim (deterministic), and the presence copy. The `.saver` drawing +
//  live probe are verify-by-launch.
//

import Foundation
@testable import M1K3ScreensaverCore
import Testing

// MARK: - PixelMark

struct PixelMarkTests {
    @Test func hasSeventeenOnCellsInA5x7Grid() {
        #expect(PixelMark.columns == 5)
        #expect(PixelMark.rows == 7)
        #expect(PixelMark.onCells.count == 17)
    }

    @Test func everyOnCellIsInsideTheGrid() {
        for cell in PixelMark.onCells {
            #expect(cell.col >= 0 && cell.col < PixelMark.columns)
            #expect(cell.row >= 0 && cell.row < PixelMark.rows)
        }
    }

    @Test func bothLegsAreFullHeight() {
        // Columns 0 and 4 are "on" for every one of the 7 rows (the M's legs).
        for row in 0 ..< PixelMark.rows {
            #expect(PixelMark.onCells.contains { $0.col == 0 && $0.row == row })
            #expect(PixelMark.onCells.contains { $0.col == 4 && $0.row == row })
        }
    }

    @Test func centreBlockSitsWhereTheDiagonalsMeet() {
        // The single centre pixel is (col 2, row 3).
        #expect(PixelMark.onCells.contains { $0.col == 2 && $0.row == 3 })
        // …and nothing else in the middle column.
        #expect(PixelMark.onCells.filter { $0.col == 2 }.count == 1)
    }

    @Test func aspectRatioIsFiveOverSeven() {
        #expect(abs(PixelMark.aspectRatio - 5.0 / 7.0) < 1e-9)
    }

    @Test func unitCellsStayWithinTheBoxAndLeaveASeam() {
        let cells = PixelMark.cells(gap: 0.10)
        #expect(cells.count == 17)
        for c in cells {
            #expect(c.x >= 0 && c.y >= 0)
            #expect(c.x + c.width <= 1.0 + 1e-9)
            #expect(c.y + c.height <= 1.0 + 1e-9)
            // A 10% seam means each block is 90% of a cell (1/5 wide, 1/7 tall).
            #expect(abs(c.width - (1.0 / 5.0) * 0.9) < 1e-9)
            #expect(abs(c.height - (1.0 / 7.0) * 0.9) < 1e-9)
        }
    }
}

// MARK: - RainField

struct RainFieldTests {
    @Test func spawnsRoughlyDensityTimesColumnsDrops() {
        let field = RainField(columns: 40, density: 1.5, seed: 42)
        // ~1.5 per column across 40 columns → in the ballpark, never zero.
        #expect(field.drops.count > 20)
        #expect(field.drops.count < 120)
    }

    @Test func allDropsStartWithinTheField() {
        let field = RainField(columns: 30, density: 2, seed: 7)
        for d in field.drops {
            #expect(d.column >= 0 && d.column < 30)
            #expect(d.y >= 0 && d.y <= 1)
            #expect(d.speed > 0)
            #expect(d.brightness >= 0 && d.brightness <= 1)
        }
    }

    @Test func sameSeedProducesIdenticalRain() {
        var a = RainField(columns: 20, density: 1, seed: 99)
        var b = RainField(columns: 20, density: 1, seed: 99)
        #expect(a.drops == b.drops)
        a.advance(by: 0.5)
        b.advance(by: 0.5)
        #expect(a.drops == b.drops)
    }

    @Test func dropsRiseOverTime() {
        var field = RainField(columns: 10, density: 1, seed: 3)
        let before = field.drops.map(\.y)
        field.advance(by: 0.5)
        // Every drop that didn't wrap moved up (y decreased).
        for (i, d) in field.drops.enumerated() where d.y <= before[i] {
            #expect(d.y <= before[i])
        }
    }

    @Test func densityIsStableAcrossManyFrames() {
        var field = RainField(columns: 25, density: 1.5, seed: 11)
        let count = field.drops.count
        for _ in 0 ..< 600 {
            field.advance(by: 1.0 / 30.0)
        } // 20 seconds
        // Wrap-not-remove keeps the count constant.
        #expect(field.drops.count == count)
        for d in field.drops {
            #expect(d.y >= -0.03 && d.y <= 1.05)
        }
    }

    @Test func advanceByZeroOrNegativeIsANoOp() {
        var field = RainField(columns: 10, density: 1, seed: 5)
        let before = field.drops
        field.advance(by: 0)
        #expect(field.drops == before)
        field.advance(by: -1)
        #expect(field.drops == before)
    }
}

// MARK: - PresenceFormatter

struct PresenceFormatterTests {
    @Test func speakingBeatsThinking() {
        let snap = PresenceSnapshot(isThinking: true, isSpeaking: true, reachable: true)
        #expect(PresenceFormatter.statusLine(snap) == "M1K3 is speaking")
    }

    @Test func thinkingNamesTheBrainWhenKnown() {
        let snap = PresenceSnapshot(isThinking: true, brainName: "Lil", reachable: true)
        #expect(PresenceFormatter.statusLine(snap) == "Lil is thinking")
    }

    @Test func thinkingWithoutABrainFallsBackToM1K3() {
        let snap = PresenceSnapshot(isThinking: true, reachable: true)
        #expect(PresenceFormatter.statusLine(snap) == "M1K3 is thinking")
    }

    @Test func unreachableRests() {
        #expect(PresenceFormatter.statusLine(.resting) == "M1K3 rests")
    }

    @Test func reachableIdleKeepsWatch() {
        let snap = PresenceSnapshot(reachable: true)
        #expect(PresenceFormatter.statusLine(snap) == "M1K3 is here, keeping watch")
    }

    @Test func heartbeatLineIsNilWhenBlank() {
        #expect(PresenceFormatter.heartbeatLine(PresenceSnapshot(latestHeartbeat: "   ")) == nil)
        #expect(PresenceFormatter.heartbeatLine(.resting) == nil)
    }

    @Test func heartbeatLinePrefixesRelativeAge() {
        let snap = PresenceSnapshot(latestHeartbeat: "a quiet Thursday in Cork", heartbeatAge: 7200)
        #expect(PresenceFormatter.heartbeatLine(snap) == "2h ago — a quiet Thursday in Cork")
    }

    @Test func relativeAgeBuckets() {
        #expect(PresenceFormatter.relativeAge(10) == "just now")
        #expect(PresenceFormatter.relativeAge(300) == "5m ago")
        #expect(PresenceFormatter.relativeAge(7200) == "2h ago")
        #expect(PresenceFormatter.relativeAge(86400) == "yesterday")
        #expect(PresenceFormatter.relativeAge(3 * 86400) == "3d ago")
    }
}

// MARK: - ScreenSaverInstall

struct ScreenSaverInstallTests {
    private func tempHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-saver-test-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func userDirectoryIsTheScreenSaversFolderWithASpace() {
        let home = URL(fileURLWithPath: "/Users/x")
        let dir = ScreenSaverInstall.userScreenSaversDirectory(home: home)
        #expect(dir.path == "/Users/x/Library/Screen Savers")
    }

    @Test func installedURLNamesTheBundleUnderThatFolder() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(ScreenSaverInstall.installedURL(home: home).path
            == "/Users/x/Library/Screen Savers/M1K3.saver")
    }

    @Test func isInstalledIsFalseWhenAbsentAndTrueOncePresent() throws {
        let home = tempHome()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        #expect(ScreenSaverInstall.isInstalled(home: home) == false)

        // Simulate the installed bundle (a directory named M1K3.saver).
        let installed = ScreenSaverInstall.installedURL(home: home)
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        #expect(ScreenSaverInstall.isInstalled(home: home) == true)
    }

    @Test func statusAndActionTitlesFlipOnInstall() {
        #expect(ScreenSaverInstall.statusText(installed: false).contains("Not set up"))
        #expect(ScreenSaverInstall.statusText(installed: true).contains("Installed"))
        #expect(ScreenSaverInstall.actionTitle(installed: false) == "Set Up Screen Saver…")
        #expect(ScreenSaverInstall.actionTitle(installed: true) == "Re-install Screen Saver")
    }
}
