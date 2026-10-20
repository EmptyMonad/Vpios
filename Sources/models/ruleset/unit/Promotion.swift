// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct PromotionDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let prerequisites: [String]
    let uniques: [String]
    let unitTypes: [String]
    /// Unciv Promotion.row / column: picker position; -1 means the modder has not set one.
    let row: Int
    let column: Int
    var uniqueObjects: [Unique] { uniques.map(Unique.init) }
    private enum CodingKeys: String, CodingKey { case name, prerequisites, uniques, unitTypes, row, column }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        prerequisites = try c.decodeIfPresent([String].self, forKey: .prerequisites) ?? []
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        unitTypes = try c.decodeIfPresent([String].self, forKey: .unitTypes) ?? []
        row = try c.decodeIfPresent(Int.self, forKey: .row) ?? -1
        column = try c.decodeIfPresent(Int.self, forKey: .column) ?? 0   // Unciv Promotion: row = -1, column = 0
    }
    /// Promotions like "Heal Instantly" consume the choice without staying on the unit.
    var isOneShot: Bool { uniques.contains("Doing so will consume this opportunity to choose a Promotion") }
}
