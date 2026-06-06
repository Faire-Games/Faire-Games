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
        model.newGame(difficulty: BlockBlastDifficulty.hard)
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
        #expect(restored.difficulty == BlockBlastDifficulty.hard)
    }

    @Test func difficultyDrivesSolvabilityAttempts() throws {
        let model = GameModel()
        model.newGame(difficulty: BlockBlastDifficulty.easy)
        #expect(model.difficulty == BlockBlastDifficulty.easy)
        #expect(model.solvabilityAttempts == 20)

        model.newGame(difficulty: BlockBlastDifficulty.normal)
        #expect(model.difficulty == BlockBlastDifficulty.normal)
        #expect(model.solvabilityAttempts == 10)

        model.newGame(difficulty: BlockBlastDifficulty.hard)
        #expect(model.difficulty == BlockBlastDifficulty.hard)
        #expect(model.solvabilityAttempts == 0)

        // Calling newGame() without a difficulty preserves the current tier.
        model.newGame()
        #expect(model.difficulty == BlockBlastDifficulty.hard)
    }

    @Test func loadingPreV170SavedStateIsDiscarded() throws {
        // The new BlockBlastSavedState carries a required `difficultyRaw` field.
        // A pre-1.7 saved state written without that field must fail to decode
        // and be silently discarded — the player gets routed to the difficulty
        // picker instead of being restored into a half-initialised model.
        let oldJson = "{\"grid\":[[-1,-1,-1,-1,-1,-1,-1,-1],[-1,-1,-1,-1,-1,-1,-1,-1],[-1,-1,-1,-1,-1,-1,-1,-1],[-1,-1,-1,-1,-1,-1,-1,-1],[-1,-1,-1,-1,-1,-1,-1,-1],[-1,-1,-1,-1,-1,-1,-1,-1],[-1,-1,-1,-1,-1,-1,-1,-1],[-1,-1,-1,-1,-1,-1,-1,-1]],\"pieceShapeIds\":[\"dot\",\"dot\",\"dot\"],\"score\":42,\"highScore\":100,\"isGameOver\":false,\"comboStreak\":0,\"boardCleared\":false}"
        let data = oldJson.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(BlockBlastSavedState.self, from: data)
        #expect(decoded == nil, "saved states from before difficulty was added must be rejected")
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
