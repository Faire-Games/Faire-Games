// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import OSLog
import Foundation
@testable import BlockBlast

let logger: Logger = Logger(subsystem: "BlockBlast", category: "Tests")

@Suite struct BlockBlastTests {

    @Test func blockBlast() throws {
        logger.log("running testBlockBlast")
        #expect(1 + 2 == 3, "basic test")
    }

    @Test func saveAndRestoreState() throws {
        let model = GameModel()
        model.newGame()
        model.score = 99
        model.comboStreak = 3
        model.grid[0][0] = 2
        model.grid[3][5] = 4

        let state = model.makeSavedState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BlockBlastSavedState.self, from: data)

        let restored = GameModel()
        restored.restoreState(decoded)
        #expect(restored.score == 99)
        #expect(restored.comboStreak == 3)
        #expect(restored.grid[0][0] == 2)
        #expect(restored.grid[3][5] == 4)
    }

    @Test func decodeType() throws {
        // load the TestData.json file from the Resources folder and decode it into a struct
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "BlockBlast")
    }

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
