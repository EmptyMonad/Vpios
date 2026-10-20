// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct QuestDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let type: String
    let influence: Double
    let duration: Int
    let minimumCivs: Int
    let weightForCityStateType: [String: Double]
    private enum CodingKeys: String, CodingKey { case name, description, type, influence, duration, minimumCivs, weightForCityStateType }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""   // Unciv Quest.description = ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "Individual"
        influence = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .influence) ?? 40)   // Unciv Quest.influence: Float
        duration = try c.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        minimumCivs = try c.decodeIfPresent(Int.self, forKey: .minimumCivs) ?? 1
        weightForCityStateType = (try c.decodeIfPresent([String: Double].self, forKey: .weightForCityStateType) ?? [:]).mapValues { Stats.f32($0) }   // HashMap<String, Float>
    }
    var isGlobal: Bool { type == "Global" }
}
