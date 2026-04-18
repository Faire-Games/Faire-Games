// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import OSLog
import Foundation
@testable import Tetris

let logger: Logger = Logger(subsystem: "Tetris", category: "Tests")

@Suite struct TetrisTests {

    @Test func tetris() throws {
        logger.log("running testTetris")
        #expect(1 + 2 == 3, "basic test")
    }

    @Test func saveAndRestoreState() throws {
        let model = TetrisModel()
        model.grid[19][0] = 0
        model.grid[19][1] = 1
        model.score = 500
        model.level = 3
        model.totalLinesCleared = 12
        model.currentRow = 5
        model.currentCol = 4

        let state = model.makeSavedState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TetrisSavedState.self, from: data)

        let restored = TetrisModel()
        restored.restoreState(decoded)
        #expect(restored.score == 500)
        #expect(restored.level == 3)
        #expect(restored.totalLinesCleared == 12)
        #expect(restored.grid[19][0] == 0)
        #expect(restored.grid[19][1] == 1)
    }

    @Test func decodeType() throws {
        // load the TestData.json file from the Resources folder and decode it into a struct
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "Tetris")
    }

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
