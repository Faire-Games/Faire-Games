// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import OSLog
import Foundation
@testable import FlappyBird

let logger: Logger = Logger(subsystem: "FlappyBird", category: "Tests")

@Suite struct FlappyBirdTests {

    @Test func flappyBird() throws {
        logger.log("running testFlappyBird")
        #expect(1 + 2 == 3, "basic test")
    }

    @Test func decodeType() throws {
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "FlappyBird")
    }

    @Test func saveAndRestoreState() throws {
        let model = FlappyBirdModel()
        model.birdY = 200.0
        model.score = 15
        model.difficulty = 7
        model.isGameOver = true
        model.hasStarted = true

        let state = model.makeSavedState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(FlappyBirdSavedState.self, from: data)

        let restored = FlappyBirdModel()
        restored.restoreState(decoded)
        #expect(restored.birdY == 200.0)
        #expect(restored.score == 15)
        #expect(restored.difficulty == 7)
        #expect(restored.isGameOver == true)
    }

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
