// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import OSLog
import Foundation
@testable import Breakout

let logger: Logger = Logger(subsystem: "Breakout", category: "Tests")

@Suite struct BreakoutTests {

    @Test func breakout() throws {
        logger.log("running testBreakout")
        #expect(1 + 2 == 3, "basic test")
    }

    @Test func decodeType() throws {
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "Breakout")
    }

    @Test func saveAndRestoreState() throws {
        let model = BreakoutModel()
        model.newGame()
        model.score = 55
        model.lives = 2
        model.level = 3
        model.ballX = 150.0
        model.ballY = 400.0
        model.isLaunched = true

        let state = model.makeSavedState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BreakoutSavedState.self, from: data)

        let restored = BreakoutModel()
        restored.restoreState(decoded)
        #expect(restored.score == 55)
        #expect(restored.lives == 2)
        #expect(restored.level == 3)
        #expect(restored.ballX == 150.0)
        #expect(restored.isLaunched == true)
    }

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
