import M1K3LiveActivity
import M1K3ScreensaverCore
import Testing

/// The pixel face on the Live Activity is a COPY of the screensaver's grid (the extension cannot link the
/// screensaver core). These pins keep the copy honest: same matrix, same eyes, same resting smile.
struct TurnFaceTests {
    @Test("the matrix is the screensaver's, cell for cell")
    func sameMatrix() {
        #expect(TurnFace.cols == PixelFace.cols)
        #expect(TurnFace.rows == PixelFace.rows)
        #expect(TurnFace.leftEye == TurnFace.Cell(col: PixelFace.leftEye.col, row: PixelFace.leftEye.row))
        #expect(TurnFace.rightEye == TurnFace.Cell(col: PixelFace.rightEye.col, row: PixelFace.rightEye.row))
        #expect(TurnFace.mouthRow == PixelFace.mouthRow)
    }

    @Test("ready is the resting face: exactly what the screensaver lights at rest")
    func readyIsTheRestingFace() {
        let resting = Set(PixelFace.litCells(at: 0).map { TurnFace.Cell(col: $0.col, row: $0.row) })
        #expect(TurnFace.cells(for: .ready) == resting)
    }

    @Test("every phase fits the matrix and has two eyes' worth of light", arguments: TurnActivityPhase.allCases)
    func fitsTheMatrix(phase: TurnActivityPhase) {
        let cells = TurnFace.cells(for: phase)
        #expect(cells.count >= 6)
        #expect(cells.allSatisfy { (0 ..< TurnFace.cols).contains($0.col) && (0 ..< TurnFace.rows).contains($0.row) })
    }

    @Test("each phase has its own face, so the mark says where the turn is")
    func phasesDiffer() {
        let faces = TurnActivityPhase.allCases.map { TurnFace.cells(for: $0) }
        #expect(Set(faces).count == TurnActivityPhase.allCases.count)
    }

    @Test("paused has its eyes shut: a flat three-cell line where each eye was (the screensaver's blink)")
    func pausedEyesAreShut() {
        let cells = TurnFace.cells(for: .paused)
        for eye in [TurnFace.leftEye, TurnFace.rightEye] {
            for dc in -1 ... 1 {
                #expect(cells.contains(TurnFace.Cell(col: eye.col + dc, row: eye.row)))
            }
        }
        // Nothing lit in the eye rows outside the two lines (no open pupil beside them).
        #expect(cells.filter { $0.row == TurnFace.leftEye.row }.count == 6)
    }

    @Test("listening looks up, mouth closed: waiting for the person to talk")
    func listeningLooksUp() {
        let cells = TurnFace.cells(for: .listening)
        #expect(cells.contains(TurnFace.Cell(col: TurnFace.leftEye.col, row: TurnFace.leftEye.row - 1)))
        #expect(cells.contains(TurnFace.Cell(col: TurnFace.rightEye.col, row: TurnFace.rightEye.row - 1)))
        #expect(cells.filter { $0.row > TurnFace.mouthRow }.isEmpty)
    }

    @Test("speaking opens wider than answering: the words are out loud, not on screen")
    func speakingOpensWide() {
        let mouth = { (phase: TurnActivityPhase) in TurnFace.cells(for: phase).filter { $0.row >= TurnFace.mouthRow } }
        #expect(mouth(.speaking).isStrictSuperset(of: mouth(.answering)))
    }
}
