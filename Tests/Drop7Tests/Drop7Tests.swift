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

    @Test func explodesOnContiguousRowRun() throws {
        // Build a state where the row containing the disc has length-3 contiguous run
        // including the disc, so a "3" should explode.
        let model = Drop7Model()
        model.newGame(diff: Drop7Difficulty.easy)
        // Clear the grid for a controlled setup
        var i = 0
        while i < model.stateGrid.count {
            model.stateGrid[i] = 0
            model.valueGrid[i] = 0
            i += 1
        }
        // Row 6 (bottom): discs in cols 0, 1, 2 contiguous (run of 3) plus a separate disc in col 5.
        // The disc at col 2 will be the dropped "3" — its row run length is 3 (cols 0,1,2).
        // Under a (wrong) total-count rule the row count would be 4 and 3 would NOT explode.
        // Under the contiguous rule, 3 matches the run length and DOES explode.
        let r = 6
        model.stateGrid[r * 7 + 0] = 1; model.valueGrid[r * 7 + 0] = 5
        model.stateGrid[r * 7 + 1] = 1; model.valueGrid[r * 7 + 1] = 5
        model.stateGrid[r * 7 + 2] = 1; model.valueGrid[r * 7 + 2] = 3
        model.stateGrid[r * 7 + 5] = 1; model.valueGrid[r * 7 + 5] = 5

        let scoreBefore = model.score
        let step = model.runOneExplosionStep(stepNumber: 1)
        #expect(step != nil)
        let s = try #require(step)
        // The disc at (6, 2) must be in the exploded set.
        #expect(s.exploded.contains(r * 7 + 2))
        #expect(s.scoreGained > scoreBefore - scoreBefore)
    }

    @Test func doesNotExplodeOnNonContiguousRow() throws {
        // Row has 3 total discs but they are not contiguous, so a "3" should NOT explode.
        let model = Drop7Model()
        model.newGame(diff: Drop7Difficulty.easy)
        var i = 0
        while i < model.stateGrid.count {
            model.stateGrid[i] = 0
            model.valueGrid[i] = 0
            i += 1
        }
        let r = 6
        // Discs at (6, 0), (6, 3), (6, 6) — three total in the row but each in its own run of 1.
        // Under the total-count rule a "3" at any of these would explode (wrong).
        // Under the contiguous-run rule, none should explode.
        model.stateGrid[r * 7 + 0] = 1; model.valueGrid[r * 7 + 0] = 3
        model.stateGrid[r * 7 + 3] = 1; model.valueGrid[r * 7 + 3] = 3
        model.stateGrid[r * 7 + 6] = 1; model.valueGrid[r * 7 + 6] = 3

        let step = model.runOneExplosionStep(stepNumber: 1)
        #expect(step == nil)
    }

    @Test func explodesOnContiguousColumnRun() throws {
        // Three discs stacked at the bottom of column 0, with the topmost being a "3".
        // Column run through (4, 0) is 3 (rows 4, 5, 6) — should explode.
        let model = Drop7Model()
        model.newGame(diff: Drop7Difficulty.easy)
        var i = 0
        while i < model.stateGrid.count {
            model.stateGrid[i] = 0
            model.valueGrid[i] = 0
            i += 1
        }
        model.stateGrid[6 * 7 + 0] = 1; model.valueGrid[6 * 7 + 0] = 5
        model.stateGrid[5 * 7 + 0] = 1; model.valueGrid[5 * 7 + 0] = 5
        model.stateGrid[4 * 7 + 0] = 1; model.valueGrid[4 * 7 + 0] = 3

        let step = model.runOneExplosionStep(stepNumber: 1)
        #expect(step != nil)
        let s = try #require(step)
        #expect(s.exploded.contains(4 * 7 + 0))
    }

    @Test func screenClearAwards70000Bonus() throws {
        // Set up a board with exactly two discs whose row-run-of-2 will trigger
        // both to explode, leaving the board completely empty.
        let model = Drop7Model()
        model.newGame(diff: Drop7Difficulty.easy)
        var i = 0
        while i < model.stateGrid.count {
            model.stateGrid[i] = 0
            model.valueGrid[i] = 0
            i += 1
        }
        let r = 6
        // Two contiguous "2" discs at the bottom row — row run length 2 matches value 2.
        model.stateGrid[r * 7 + 0] = 1; model.valueGrid[r * 7 + 0] = 2
        model.stateGrid[r * 7 + 1] = 1; model.valueGrid[r * 7 + 1] = 2

        let scoreBefore = model.score
        let step = model.runOneExplosionStep(stepNumber: 1)
        let s = try #require(step)
        #expect(s.screenCleared == true)
        // The chain-1 bonus is 7 per disc * 2 discs = 14, plus the 70,000 clear bonus.
        #expect(model.score - scoreBefore == 14 + drop7ScreenClearBonus)
        #expect(model.isBoardEmpty())
    }

    @Test func partialClearDoesNotAwardBonus() throws {
        // Two contiguous "2" discs explode, but a wrapped disc remains — no bonus.
        let model = Drop7Model()
        model.newGame(diff: Drop7Difficulty.easy)
        var i = 0
        while i < model.stateGrid.count {
            model.stateGrid[i] = 0
            model.valueGrid[i] = 0
            i += 1
        }
        let r = 6
        model.stateGrid[r * 7 + 0] = 1; model.valueGrid[r * 7 + 0] = 2
        model.stateGrid[r * 7 + 1] = 1; model.valueGrid[r * 7 + 1] = 2
        // A separate wrapped disc that won't be cracked (not adjacent to the explosion)
        model.stateGrid[r * 7 + 6] = 3; model.valueGrid[r * 7 + 6] = 5

        let step = model.runOneExplosionStep(stepNumber: 1)
        let s = try #require(step)
        #expect(s.screenCleared == false)
        #expect(model.isBoardEmpty() == false)
    }

    @Test func levelTargetDecreasesWithLevel() throws {
        let model = Drop7Model()
        model.newGame(diff: Drop7Difficulty.normal)
        // Normal: starts at 30 drops/level, decreases by 1 per level, floor 5.
        #expect(model.currentLevelTarget() == 30)
        model.level = 2
        #expect(model.currentLevelTarget() == 29)
        model.level = 10
        #expect(model.currentLevelTarget() == 21)
        model.level = 26
        #expect(model.currentLevelTarget() == 5)
        model.level = 100
        #expect(model.currentLevelTarget() == 5) // hits floor
    }

    @Test func levelBonusAwardedOnPushUp() throws {
        let model = Drop7Model()
        model.newGame(diff: Drop7Difficulty.normal)
        // Clear the board so push-up has no overflow risk.
        var i = 0
        while i < model.stateGrid.count {
            model.stateGrid[i] = 0
            model.valueGrid[i] = 0
            i += 1
        }
        model.dropsThisLevel = 29 // one more drop will trigger level-up at level 1 (target 30)
        let scoreBefore = model.score
        let levelBefore = model.level
        let result = model.advanceLevel()
        #expect(result.didPushUp == true)
        #expect(result.levelBonusGained == 7_000)
        #expect(model.score - scoreBefore == 7_000)
        #expect(model.level == levelBefore + 1)
    }

    @Test func levelBonusNotAwardedBetweenPushUps() throws {
        let model = Drop7Model()
        model.newGame(diff: Drop7Difficulty.easy)
        let scoreBefore = model.score
        let result = model.advanceLevel()
        #expect(result.didPushUp == false)
        #expect(result.levelBonusGained == 0)
        #expect(model.score == scoreBefore)
    }

    @Test func levelBonusVariesByDifficulty() throws {
        #expect(Drop7Difficulty.easy.levelBonus == 5_000)
        #expect(Drop7Difficulty.normal.levelBonus == 7_000)
        #expect(Drop7Difficulty.hard.levelBonus == 14_000)
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
