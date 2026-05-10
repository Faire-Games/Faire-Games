// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import OSLog
import Foundation
@testable import Drop7

let logger: Logger = Logger(subsystem: "Drop7", category: "Tests")

@Suite struct Drop7Tests {

    @Test func drop7Smoke() throws {
        logger.log("running drop7Smoke")
        #expect(1 + 2 == 3, "basic test")
    }

    @Test func decodeType() throws {
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "Drop7")
    }

    @Test func newGameFillsStartingRows() throws {
        let model = Drop7Model()
        model.newGame(diff: Drop7Difficulty.normal)
        // Difficulty .normal starts with 5 rows of wrapped discs at the bottom of a 7×7 grid.
        var nonEmpty = 0
        for v in model.stateGrid {
            if v != 0 { nonEmpty += 1 }
        }
        #expect(nonEmpty == 5 * 7)
        #expect(model.score == 0)
        #expect(model.level == 1)
        #expect(model.isGameOver == false)
    }

    @Test func dropLandsAtBottomOfEmptyColumn() throws {
        let model = Drop7Model()
        model.newGame(diff: Drop7Difficulty.easy)
        // Easy difficulty has 3 starting wrapped rows. The top 4 rows are empty.
        // Force a known piece value that will not trigger an explosion: pick a value larger than any current row/column count.
        model.currentPiece = 7
        model.nextPiece = 7

        // Find an empty column (any column) — every column has space at the top.
        let col = 0
        let ok = model.drop(column: col)
        #expect(ok == true)
        // After dropping, the disc should occupy row (gridRows - startingRows - 1) = 7 - 3 - 1 = 3
        // since the bottom 3 rows (4,5,6) are wrapped, the disc lands at row 3.
        // Note: the disc may have caused a chain that removed it; for a value of 7 with only 4 discs in the column it should not explode.
        // Verify either it landed at row 3 OR it exploded (depending on starting wrapped count).
        let landedRow = 3
        let st = model.getState(landedRow, col)
        let v = model.getValue(landedRow, col)
        // It might have exploded if row count == 7 (would need a full row); not the case here.
        #expect(st == 1) // stateNormal
        #expect(v == 7)
    }

    @Test func saveAndRestoreState() throws {
        let model = Drop7Model()
        model.newGame(diff: Drop7Difficulty.normal)
        model.score = 4321
        model.level = 3
        model.dropsThisLevel = 5
        model.currentPiece = 4
        model.nextPiece = 6

        let state = model.makeSavedState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(Drop7SavedState.self, from: data)

        let restored = Drop7Model()
        restored.restoreState(decoded)
        #expect(restored.score == 4321)
        #expect(restored.level == 3)
        #expect(restored.dropsThisLevel == 5)
        #expect(restored.currentPiece == 4)
        #expect(restored.nextPiece == 6)
        #expect(restored.difficulty == Drop7Difficulty.normal)
        #expect(restored.stateGrid.count == 7 * 7)
    }
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
