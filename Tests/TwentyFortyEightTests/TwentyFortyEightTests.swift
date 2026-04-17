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

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
