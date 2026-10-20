// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct UnitType: Decodable {
    let name: String
    let movementType: String
    let uniques: [String]
    let uniqueObjects: [Unique]
    /// Unciv RulesetObject.civilopediaText (the Siege type's note on setting up).
    let civilopediaText: [CivilopediaLine]
    var isLand: Bool { movementType == "Land" }
    private enum CodingKeys: String, CodingKey { case name, movementType, uniques, civilopediaText }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        movementType = try c.decodeIfPresent(String.self, forKey: .movementType) ?? "Land"
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        uniqueObjects = uniques.map(Unique.init)
        civilopediaText = (try? c.decodeIfPresent([CivilopediaLine].self, forKey: .civilopediaText)) ?? []
    }
}
