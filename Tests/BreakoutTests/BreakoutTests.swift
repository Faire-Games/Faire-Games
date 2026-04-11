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

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
