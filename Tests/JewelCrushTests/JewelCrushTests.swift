// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import OSLog
import Foundation
@testable import JewelCrush

let logger: Logger = Logger(subsystem: "JewelCrush", category: "Tests")

@Suite struct JewelCrushTests {

    @Test func jewelCrush() throws {
        logger.log("running testJewelCrush")
        #expect(1 + 2 == 3, "basic test")
    }

    @Test func decodeType() throws {
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "JewelCrush")
    }

    @Test func saveAndRestoreState() throws {
        let model = JewelCrushModel()
        model.score = 350
        model.currentLevel = 5
        model.targetScore = 2000
        model.movesRemaining = 12
        model.isGameOver = false

        let state = model.makeSavedState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(JewelCrushSavedState.self, from: data)

        let restored = JewelCrushModel()
        restored.restoreState(decoded)
        #expect(restored.score == 350)
        #expect(restored.currentLevel == 5)
        #expect(restored.targetScore == 2000)
        #expect(restored.movesRemaining == 12)
    }

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
