// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Unciv GlobalUniques: the ruleset-wide uniques, plus `unitUniques` that every BaseUnit folds into its own
/// (BaseUnit.setRuleset: own uniques, then these, then its unit type's).
struct GlobalUniquesDef: Decodable {
    let uniques: [String]
    let unitUniques: [String]
    /// Unciv GlobalUniques.civilopediaText: the Global Uniques page's own text.
    let civilopediaText: [CivilopediaLine]
    var uniqueObjects: [Unique] { uniques.map(Unique.init) }
    private enum CodingKeys: String, CodingKey { case uniques, unitUniques, civilopediaText }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        unitUniques = try c.decodeIfPresent([String].self, forKey: .unitUniques) ?? []
        civilopediaText = (try? c.decodeIfPresent([CivilopediaLine].self, forKey: .civilopediaText)) ?? []
    }
}
