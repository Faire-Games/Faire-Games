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

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
