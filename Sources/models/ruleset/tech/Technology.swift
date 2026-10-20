// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct TechDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let row: Int
    let prerequisites: [String]
    let quote: String?
    let uniques: [String]
    /// Unciv ICivilopediaText.civilopediaText (Future Tech's "Who knows what the future holds?")
    var civilopediaText: [CivilopediaLine] = []
    // filled from the enclosing column
    var column: Int = 0
    var era: String = ""
    var cost: Int = 0
    var uniqueObjects: [Unique] { uniques.map(Unique.init) }

    private enum CodingKeys: String, CodingKey { case name, row, prerequisites, quote, uniques, cost, civilopediaText }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        row = try c.decodeIfPresent(Int.self, forKey: .row) ?? 0
        cost = try c.decodeIfPresent(Int.self, forKey: .cost) ?? 0   // Unciv: 0 means take the column cost
        // Unciv Technology.prerequisites is a HashSet<String>: libGDX adds the JSON list in order (a repeated name
        // once) and every reader walks it in Java bucket order - getRequiredTechsToDestination's BFS (whose stable
        // sortedBy column keeps it among same-column techs, so it decides the picker's research queue), the
        // Civilopedia's "Requires all of the following" and the ruleset checks.
        let rawPrerequisites = try c.decodeIfPresent([String].self, forKey: .prerequisites) ?? []
        var seenPrerequisites = Set<String>()
        prerequisites = javaHashMapOrder(rawPrerequisites.filter { seenPrerequisites.insert($0).inserted })
        quote = try c.decodeIfPresent(String.self, forKey: .quote)
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        civilopediaText = try c.decodeIfPresent([CivilopediaLine].self, forKey: .civilopediaText) ?? []
    }
}
