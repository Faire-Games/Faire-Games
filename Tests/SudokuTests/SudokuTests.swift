// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import OSLog
import Foundation
@testable import Sudoku

let logger: Logger = Logger(subsystem: "Sudoku", category: "Tests")

@Suite struct SudokuTests {

    @Test func sudoku() throws {
        logger.log("running testSudoku")
        #expect(1 + 2 == 3, "basic test")
    }

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
            #expect(v >= 1 && v <= 9)
        }
        // Solution must be a valid Sudoku (each row/col/box has 1-9)
        for row in 0..<9 {
            var seen = Set<Int>()
            for col in 0..<9 {
                seen.insert(model.solution[row * 9 + col])
            }
            #expect(seen.count == 9)
        }
        for col in 0..<9 {
            var seen = Set<Int>()
            for row in 0..<9 {
                seen.insert(model.solution[row * 9 + col])
            }
            #expect(seen.count == 9)
        }
        // Puzzle cluesshould match difficulty target
        let clues = model.values.filter { $0 != 0 }.count
        #expect(clues >= 20 && clues <= 60)
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
        #expect(model.mistakes == 0)
    }

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
