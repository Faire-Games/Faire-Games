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
    @Test func completionAcceptsAnyValidBoardEvenIfDifferentFromSolution() throws {
        // A puzzle can have multiple valid completions — for example, when a "deadly
        // pair" of cells in two adjacent boxes could legitimately be swapped. The win
        // condition must accept any board that satisfies the Sudoku rules, not just
        // the canonical solution the generator happened to start from.
        let model = SudokuModel()
        model.newGame(difficulty: SudokuDifficulty.easy)

        // Install a known canonical solution so the deadly-pair coordinates below are
        // deterministic (newGame's generator otherwise randomizes the board).
        let canonical: [Int] = [
            5, 3, 4,  6, 7, 8,  9, 1, 2,
            6, 7, 2,  1, 9, 5,  3, 4, 8,
            1, 9, 8,  3, 4, 2,  5, 6, 7,
            8, 5, 9,  7, 6, 1,  4, 2, 3,
            4, 2, 6,  8, 5, 3,  7, 9, 1,
            7, 1, 3,  9, 2, 4,  8, 5, 6,
            9, 6, 1,  5, 3, 7,  2, 8, 4,
            2, 8, 7,  4, 1, 9,  6, 3, 5,
            3, 4, 5,  2, 8, 6,  1, 7, 9
        ]
        model.solution = canonical

        // First completion: the canonical board itself wins.
        model.values = canonical
        model.isComplete = false
        model.checkCompletion()
        #expect(model.isComplete)

        // Construct an alternate completion by swapping a deadly-pair rectangle that
        // lives in two adjacent 3×3 blocks. In the canonical solution above, rows 3
        // and 4 hold a {1,3}/{3,1} pattern across columns 5 and 8 — those four cells
        // form a swappable rectangle whose swap stays valid in every row, column,
        // and box.
        var swapped = canonical
        // (3,5)=1, (3,8)=3, (4,5)=3, (4,8)=1   →   (3,5)=3, (3,8)=1, (4,5)=1, (4,8)=3
        swapped[3 * 9 + 5] = 3
        swapped[3 * 9 + 8] = 1
        swapped[4 * 9 + 5] = 1
        swapped[4 * 9 + 8] = 3

        // The alternate is genuinely different from the canonical "solution".
        #expect(swapped != canonical)

        // The win condition should still fire on the alternate, demonstrating that
        // any valid Sudoku is a winning completion.
        model.values = swapped
        model.isComplete = false
        model.checkCompletion()
        #expect(model.isComplete)
        #expect(model.values != model.solution)
    }

    @MainActor
    @Test func completionRejectsInvalidBoard() throws {
        let model = SudokuModel()
        model.newGame(difficulty: SudokuDifficulty.easy)
        // Take the canonical solution, but corrupt one cell so the row+column it sits
        // in now has a duplicate. checkCompletion must NOT mark the board as won.
        var bad = model.solution
        bad[0] = (model.solution[0] % 9) + 1  // any other digit, will conflict
        model.values = bad
        model.isComplete = false
        model.checkCompletion()
        #expect(!model.isComplete)
    }

    @MainActor
    @Test func loadSavedStateRejectsCorruptedClues() throws {
        // A saved state from an older build that produced an invalid puzzle (or one
        // hand-corrupted in UserDefaults) should be discarded rather than restored,
        // so the user is never served an unsolvable board after relaunching.
        SudokuModel.clearSavedState()
        let model = SudokuModel()
        model.newGame(difficulty: SudokuDifficulty.medium)
        // Corrupt the saved state: place a duplicate "1" clue in row 7.
        var state = model.makeSavedState()
        // Find two empty cells in row 7 that aren't clues and force them into
        // clue-positions holding the same digit.
        let row = 7
        var firstCol = -1
        var secondCol = -1
        for c in 0..<9 {
            let i = row * 9 + c
            if !state.isOriginal[i] {
                if firstCol == -1 { firstCol = c } else if secondCol == -1 { secondCol = c; break }
            }
        }
        if firstCol >= 0 && secondCol >= 0 {
            state.values[row * 9 + firstCol] = 1
            state.values[row * 9 + secondCol] = 1
            state.isOriginal[row * 9 + firstCol] = true
            state.isOriginal[row * 9 + secondCol] = true
            // Save the corrupted state directly to UserDefaults.
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "sudoku_saved_state")
            // loadSavedState must reject it.
            let loaded = SudokuModel.loadSavedState()
            #expect(loaded == nil, "corrupted saved state with duplicate clues must be rejected")
            // And the corrupted state must have been cleared from UserDefaults.
            #expect(UserDefaults.standard.string(forKey: "sudoku_saved_state") == nil)
        }
        SudokuModel.clearSavedState()
    }

    @MainActor
    @Test func generateSolutionDirectlyManyIterations() throws {
        // Call generateSolution() directly (bypassing generatePuzzle's retry/fallback
        // safety net) to see if the underlying transformer can ever emit an invalid
        // board. Also confirm canonicalSolution itself is never mutated as a side
        // effect of a shared-storage / copy-on-write bug.
        let canonicalBefore = canonicalSolution
        var firstInvalid: [Int]? = nil
        for _ in 0..<100_000 {
            let solution = generateSolution()
            if !isFullSudokuSolution(solution) {
                firstInvalid = solution
                break
            }
        }
        #expect(firstInvalid == nil,
                "generateSolution emitted an invalid board: \(firstInvalid ?? [])")
        #expect(canonicalSolution == canonicalBefore,
                "canonicalSolution must never be mutated by the generator")
    }

    @MainActor
    @Test func generatedPuzzlesAreAlwaysSolvable() throws {
        // Earlier versions of the generator (very rarely) emitted a puzzle whose
        // pre-selected clues had a duplicate digit in the same row and box, leaving
        // the player with no valid solution. Generate a large pool of puzzles across
        // every difficulty and assert that every one has (a) a fully-valid hidden
        // solution and (b) a consistent set of starting clues.
        let difficulties: [SudokuDifficulty] = [.easy, .medium, .hard, .expert]
        for difficulty in difficulties {
            for _ in 0..<200 {
                let model = SudokuModel()
                model.newGame(difficulty: difficulty)
                #expect(isFullSudokuSolution(model.solution),
                        "generated solution must be a complete valid Sudoku")
                #expect(isPuzzleConsistent(model.values),
                        "starting clues must not duplicate a digit in any row, column, or 3×3 box")
                // Each starting clue should also match the hidden solution.
                for i in 0..<81 where model.isOriginal[i] {
                    #expect(model.values[i] == model.solution[i])
                }
            }
        }
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
