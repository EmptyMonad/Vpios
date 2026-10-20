// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct CityStateTypeDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let friendBonusUniques: [String]
    let allyBonusUniques: [String]
    let uniques: [String]
    let color: [Int]?
    private enum CodingKeys: String, CodingKey { case name, friendBonusUniques, allyBonusUniques, color, uniques }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        friendBonusUniques = try c.decodeIfPresent([String].self, forKey: .friendBonusUniques) ?? []
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        allyBonusUniques = try c.decodeIfPresent([String].self, forKey: .allyBonusUniques) ?? []
        color = try c.decodeIfPresent([Int].self, forKey: .color)
    }
}
