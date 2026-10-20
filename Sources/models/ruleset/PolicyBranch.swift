// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct PolicyBranch: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let era: String
    let uniques: [String]
    let policies: [PolicyDef]
    /// Unciv PolicyBranch.priorities: AI priority per preferred victory type.
    let priorities: [String: Int]
    var uniqueObjects: [Unique] { uniques.map(Unique.init) }
    private enum CodingKeys: String, CodingKey { case name, era, uniques, policies, priorities }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        era = try c.decodeIfPresent(String.self, forKey: .era) ?? ""
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        policies = try c.decodeIfPresent([PolicyDef].self, forKey: .policies) ?? []
        priorities = try c.decodeIfPresent([String: Int].self, forKey: .priorities) ?? [:]
    }
    var regularPolicies: [PolicyDef] { policies.filter { !$0.isBranchCompletion } }
    var completion: PolicyDef? { policies.first { $0.isBranchCompletion } }
}
