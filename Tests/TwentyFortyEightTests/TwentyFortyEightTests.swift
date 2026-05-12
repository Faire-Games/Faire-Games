// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import OSLog
import Foundation
@testable import TwentyFortyEight

let logger: Logger = Logger(subsystem: "TwentyFortyEight", category: "Tests")

@Suite struct TwentyFortyEightTests {

    @Test func twentyFortyEight() throws {
        logger.log("running testTwentyFortyEight")
        #expect(1 + 2 == 3, "basic test")
    }

    @Test func decodeType() throws {
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "TwentyFortyEight")
    }

    @Test func previewMoveLeftIdentifiesMergeAbsorbedAndDestination() throws {
        // Row 0: [2, 0, 2, 4] — sliding left merges the two 2s; the 4 shifts left.
        let model = TwentyFortyEightModel()
        model.grid = Array(repeating: 0, count: 16)
        model.grid[0] = 2
        model.grid[2] = 2
        model.grid[3] = 4

        let preview = model.previewMove(Direction.left)
        #expect(preview.anyMovement == true)

        // Tile at cell 0 stays at cell 0 (merge destination)
        // Tile at cell 2 moves to cell 0 (absorbed source)
        // Tile at cell 3 moves to cell 1 (just slides)
        var destOfMerge: Int = -1
        var absorbedSource: Int = -1
        var slideEnd: Int = -1
        for m in preview.movements {
            if m.startCell == 0 && m.endCell == 0 { destOfMerge = m.startCell }
            if m.startCell == 2 && m.isAbsorbedSource { absorbedSource = m.startCell; #expect(m.endCell == 0) }
            if m.startCell == 3 { slideEnd = m.endCell }
        }
        #expect(destOfMerge == 0)
        #expect(absorbedSource == 2)
        #expect(slideEnd == 1)

        // Calling previewMove must not mutate the grid.
        #expect(model.grid[0] == 2)
        #expect(model.grid[2] == 2)
        #expect(model.grid[3] == 4)
    }

    @Test func previewMoveRightMirrors() throws {
        // Row 0: [4, 2, 0, 2] — sliding right merges the two 2s into cell 3.
        let model = TwentyFortyEightModel()
        model.grid = Array(repeating: 0, count: 16)
        model.grid[0] = 4
        model.grid[1] = 2
        model.grid[3] = 2

        let preview = model.previewMove(Direction.right)
        #expect(preview.anyMovement == true)

        // The 4 ends at cell 2. The 2 at cell 1 is absorbed into cell 3.
        // The 2 at cell 3 stays at cell 3 (merge destination).
        for m in preview.movements {
            if m.startCell == 0 { #expect(m.endCell == 2); #expect(m.isAbsorbedSource == false) }
            if m.startCell == 1 { #expect(m.endCell == 3); #expect(m.isAbsorbedSource == true) }
            if m.startCell == 3 { #expect(m.endCell == 3); #expect(m.isAbsorbedSource == false) }
        }
    }

    @Test func previewMoveAgainstWallIsNoOp() throws {
        // All non-zero tiles already pinned against the right wall and no
        // adjacent equal tiles → dragging right should produce no movement.
        let model = TwentyFortyEightModel()
        model.grid = Array(repeating: 0, count: 16)
        model.grid[3] = 8
        model.grid[7] = 4
        model.grid[11] = 16
        model.grid[15] = 2

        let preview = model.previewMove(Direction.right)
        #expect(preview.anyMovement == false)
    }

    @Test func saveAndRestoreState() throws {
        let model = TwentyFortyEightModel()
        model.grid = Array(repeating: 0, count: 16)
        model.grid[0] = 2
        model.grid[1] = 4
        model.grid[5] = 128
        model.score = 1234
        model.isGameOver = false
        model.hasWon = false
        model.continueAfterWin = false

        let state = model.makeSavedState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TwentyFortyEightSavedState.self, from: data)

        let restored = TwentyFortyEightModel()
        restored.restoreState(decoded)
        #expect(restored.grid[0] == 2)
        #expect(restored.grid[1] == 4)
        #expect(restored.grid[5] == 128)
        #expect(restored.score == 1234)
    }

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
