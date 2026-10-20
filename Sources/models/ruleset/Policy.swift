// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct PolicyDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let uniques: [String]
    let row: Int
    let column: Int
    let requires: [String]
    var uniqueObjects: [Unique] { uniques.map(Unique.init) }
    private enum CodingKeys: String, CodingKey { case name, uniques, row, column, requires }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        row = try c.decodeIfPresent(Int.self, forKey: .row) ?? 0
        column = try c.decodeIfPresent(Int.self, forKey: .column) ?? 0
        requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? []
    }
    var isBranchCompletion: Bool { name.hasSuffix(" Complete") }
}
