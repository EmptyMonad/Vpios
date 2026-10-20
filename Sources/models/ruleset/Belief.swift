// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct BeliefDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let type: String          // Pantheon, Founder, Follower, Enhancer
    let uniques: [String]
    /// Parsed once at load, as Unciv's IHasUniques does (`uniqueObjects by lazy`) - the city's religion uniques are asked
    /// for on every construction's purchase check
    let uniqueObjects: [Unique]
    private enum CodingKeys: String, CodingKey { case name, type, uniques }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "None"   // Unciv Belief.type = BeliefType.None
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        uniqueObjects = uniques.map(Unique.init)
    }
}
