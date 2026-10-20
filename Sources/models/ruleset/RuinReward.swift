// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct RuinDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let notification: String
    let uniques: [String]
    let excludedDifficulties: [String]
    let weight: Int   // Unciv RuinReward.weight: how many lottery tickets the reward gets
    /// Unciv ICivilopediaText.civilopediaText: the lines the Ancient ruins page shows under this reward
    var civilopediaText: [CivilopediaLine] = []
    var uniqueObjects: [Unique] { uniques.map(Unique.init) }
    private enum CodingKeys: String, CodingKey { case name, notification, uniques, excludedDifficulties, weight, civilopediaText }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        notification = try c.decodeIfPresent(String.self, forKey: .notification) ?? ""   // Unciv RuinReward.notification = ""
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        excludedDifficulties = try c.decodeIfPresent([String].self, forKey: .excludedDifficulties) ?? []
        weight = try c.decodeIfPresent(Int.self, forKey: .weight) ?? 1   // Unciv RuinReward.weight = 1, a declared 0 really means 0
        civilopediaText = try c.decodeIfPresent([CivilopediaLine].self, forKey: .civilopediaText) ?? []
    }
}
