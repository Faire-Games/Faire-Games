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

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
