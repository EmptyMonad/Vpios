// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct ModOptionsDef: Decodable {
    let constants: ModConstants?
    let uniques: [String]
    private enum CodingKeys: String, CodingKey { case constants, uniques }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        constants = try c.decodeIfPresent(ModConstants.self, forKey: .constants)
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
    }
}

// MARK: - Events (Unciv models/ruleset/Event.kt: Events.json)
