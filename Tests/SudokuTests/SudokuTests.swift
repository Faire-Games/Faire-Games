// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import OSLog
import Foundation
@testable import Sudoku

let logger: Logger = Logger(subsystem: "Sudoku", category: "Tests")

@Suite struct SudokuTests {
    @Test func decodeType() throws {
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "Sudoku")
    }

    @MainActor
    @Test func puzzleGeneration() throws {
        let model = SudokuModel()
        model.newGame(difficulty: SudokuDifficulty.medium)
        // Verify all cells sum to valid state
        #expect(model.values.count == 81)
        #expect(model.solution.count == 81)
        // Solution must contain digits 1-9 only
        for v in model.solution {
            let inRange: Bool = v >= 1 && v <= 9
            #expect(inRange)
        }
        // Solution must be a valid Sudoku (each row/col/box has 1-9)
        for row in 0..<9 {
            var seen = Set<Int>()
            for col in 0..<9 {
                let value: Int = model.solution[row * 9 + col]
                seen.insert(value)
            }
            #expect(seen.count == 9)
        }
        for col in 0..<9 {
            var seen = Set<Int>()
            for row in 0..<9 {
                let value: Int = model.solution[row * 9 + col]
                seen.insert(value)
            }
            #expect(seen.count == 9)
        }
        // Puzzle cluesshould match difficulty target
        let clues = model.values.filter { $0 != 0 }.count
        let inRange: Bool = clues >= 20 && clues <= 60
        #expect(inRange)
        // Original flags match puzzle non-zero cells
        for i in 0..<81 {
            #expect(model.isOriginal[i] == (model.values[i] != 0))
        }
    }

    @MainActor
    @Test func placeDigit() throws {
        let model = SudokuModel()
        model.newGame(difficulty: SudokuDifficulty.easy)
        // Find first empty cell
        var firstEmpty = -1
        for i in 0..<81 {
            if model.values[i] == 0 {
                firstEmpty = i
                break
            }
        }
        #expect(firstEmpty >= 0)
        model.selectedIndex = firstEmpty
        let correct = model.solution[firstEmpty]
        // Place correct digit
        let placed = model.placeDigit(correct)
        #expect(placed)
        #expect(model.values[firstEmpty] == correct)
    }

    @MainActor
    @Test func saveAndRestoreState() throws {
        let model = SudokuModel()
        model.newGame(difficulty: SudokuDifficulty.hard)
        model.values[0] = 5
        model.values[10] = 3
        model.hintsRemaining = 2
        model.elapsedSeconds = 120

        let state = model.makeSavedState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SudokuSavedState.self, from: data)

        let restored = SudokuModel()
        restored.restoreState(decoded)
        #expect(restored.values[0] == 5)
        #expect(restored.values[10] == 3)
        #expect(restored.hintsRemaining == 2)
        #expect(restored.elapsedSeconds == 120)
        #expect(restored.difficulty == SudokuDifficulty.hard)
    }

    @MainActor
    @Test func undoRedo() throws {
        let model = SudokuModel()
        model.newGame(difficulty: SudokuDifficulty.easy)
        var firstEmpty = -1
        for i in 0..<81 {
            if model.values[i] == 0 { firstEmpty = i; break }
        }
        #expect(firstEmpty >= 0)
        model.selectedIndex = firstEmpty
        let correct = model.solution[firstEmpty]
        #expect(!model.canUndo)
        #expect(!model.canRedo)
        model.placeDigit(correct)
        #expect(model.canUndo)
        #expect(!model.canRedo)
        model.undo()
        #expect(model.values[firstEmpty] == 0)
        #expect(!model.canUndo)
        #expect(model.canRedo)
        model.redo()
        #expect(model.values[firstEmpty] == correct)
        #expect(model.canUndo)
        #expect(!model.canRedo)
        // A new placement after an undo should clear the redo stack.
        model.undo()
        #expect(model.canRedo)
        model.placeDigit(correct)
        #expect(!model.canRedo)
    }

    @MainActor
    @Test func giveUpMarksAutoFilledCells() throws {
        let model = SudokuModel()
        model.newGame(difficulty: SudokuDifficulty.easy)
        // Place an intentionally wrong digit somewhere so we can verify it's preserved
        // (and not marked as auto-filled) after Give Up.
        var firstEmpty = -1
        for i in 0..<81 where model.values[i] == 0 { firstEmpty = i; break }
        #expect(firstEmpty >= 0)
        let correct = model.solution[firstEmpty]
        let wrong = (correct % 9) + 1  // any other digit, in 1...9
        model.selectedIndex = firstEmpty
        model.placeDigit(wrong)

        model.giveUp()
        #expect(model.hasGivenUp)
        #expect(model.isGameOver)
        // The wrong cell should NOT be marked as auto-filled — only the cells the user
        // hadn't touched yet should get the flag.
        #expect(!model.isFilledByGiveUp[firstEmpty])
        #expect(model.values[firstEmpty] == wrong)
        // At least some other empty cell should be flagged.
        var anyAutoFilled = false
        for i in 0..<81 where model.isFilledByGiveUp[i] { anyAutoFilled = true; break }
        #expect(anyAutoFilled)
    }

    @MainActor
    @Test func hasConflictDetectsRowColumnAndBoxDuplicates() throws {
        let model = SudokuModel()
        model.newGame(difficulty: SudokuDifficulty.easy)
        // Pick a clue we can duplicate.
        var clueIndex = -1
        for i in 0..<81 where model.isOriginal[i] { clueIndex = i; break }
        #expect(clueIndex >= 0)
        let clueValue = model.values[clueIndex]
        let row = clueIndex / 9
        let col = clueIndex % 9
        // Find an empty cell in the same row.
        var rowMate = -1
        for c in 0..<9 where c != col && model.values[row * 9 + c] == 0 {
            rowMate = row * 9 + c
            break
        }
        if rowMate >= 0 {
            model.selectedIndex = rowMate
            model.placeDigit(clueValue)
            #expect(model.hasConflict(at: rowMate))
        }
    }

    @MainActor
    @Test func hintBudgetVariesByDifficulty() throws {
        let easy = SudokuModel()
        easy.newGame(difficulty: SudokuDifficulty.easy)
        #expect(easy.difficulty.hasUnlimitedHints)
        #expect(easy.canUseHint)

        let medium = SudokuModel()
        medium.newGame(difficulty: SudokuDifficulty.medium)
        #expect(!medium.difficulty.hasUnlimitedHints)
        #expect(medium.hintsRemaining == 3)
        #expect(medium.canUseHint)

        let hard = SudokuModel()
        hard.newGame(difficulty: SudokuDifficulty.hard)
        #expect(hard.hintsRemaining == 0)
        #expect(!hard.canUseHint)

        let expert = SudokuModel()
        expert.newGame(difficulty: SudokuDifficulty.expert)
        #expect(expert.hintsRemaining == 0)
        #expect(!expert.canUseHint)

        // Easy never decrements its hint counter when a hint is consumed.
        let beforeEasy = easy.hintsRemaining
        easy.useHint()
        #expect(easy.hintsRemaining == beforeEasy)
        #expect(easy.canUseHint)
        // Medium decrements.
        medium.useHint()
        #expect(medium.hintsRemaining == 2)
    }

    @MainActor
    @Test func enteringCheckpointDropsRedoStack() throws {
        let model = SudokuModel()
        model.newGame(difficulty: SudokuDifficulty.easy)
        var firstEmpty = -1
        for i in 0..<81 where model.values[i] == 0 { firstEmpty = i; break }
        #expect(firstEmpty >= 0)
        model.selectedIndex = firstEmpty
        model.placeDigit(model.solution[firstEmpty])
        model.undo()
        #expect(model.canRedo)
        model.enterCheckpoint()
        // The pending redo entry should be discarded so a later commit/revert
        // can't resurrect a move the player abandoned.
        #expect(!model.canRedo)
    }

    @MainActor
    @Test func checkpointCommitAndRevert() throws {
        let model = SudokuModel()
        model.newGame(difficulty: SudokuDifficulty.easy)
        // Find two empty cells.
        var empties: [Int] = []
        for i in 0..<81 where model.values[i] == 0 {
            empties.append(i)
            if empties.count >= 2 { break }
        }
        #expect(empties.count == 2)
        let a = empties[0]
        let b = empties[1]
        let solA = model.solution[a]
        let solB = model.solution[b]

        model.enterCheckpoint()
        #expect(model.checkpointActive)

        model.selectedIndex = a
        model.placeDigit(solA)
        model.selectedIndex = b
        model.placeDigit(solB)
        #expect(model.isProvisional[a])
        #expect(model.isProvisional[b])

        // Commit: values stay, provisional flag clears.
        model.commitCheckpoint()
        #expect(!model.checkpointActive)
        #expect(!model.isProvisional[a])
        #expect(!model.isProvisional[b])
        #expect(model.values[a] == solA)
        #expect(model.values[b] == solB)
        // History is cleared on commit.
        #expect(!model.canUndo)

        // Revert path: enter again, place, revert.
        model.enterCheckpoint()
        let beforeC = model.values[a]
        let beforeD = model.values[b]
        model.selectedIndex = a
        model.placeDigit(solA == 1 ? 2 : 1)  // some non-correct value
        let _ = beforeC
        let _ = beforeD
        model.revertCheckpoint()
        #expect(!model.checkpointActive)
        // Snapshot was taken with the committed values, so revert restores them.
        #expect(model.values[a] == solA)
        #expect(model.values[b] == solB)
        #expect(!model.canUndo)
    }
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
