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
