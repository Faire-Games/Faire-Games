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
