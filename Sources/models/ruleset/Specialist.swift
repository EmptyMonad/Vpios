// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct SpecialistDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let stats: Stats
    let greatPersonPoints: [String: Int]
    /// Unciv Specialist.color (RGB)
    let color: [Int]?
    private enum CodingKeys: String, CodingKey { case name, greatPersonPoints, color }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent([Int].self, forKey: .color)
        stats = try Stats(from: decoder)
        greatPersonPoints = try c.decodeIfPresent([String: Int].self, forKey: .greatPersonPoints) ?? [:]
    }
}
