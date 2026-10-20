// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Unciv TileResource.DepositAmount: strategic amount per map resource setting.
struct DepositAmount: Decodable {
    var sparse = 1
    var `default` = 2
    var abundant = 3
    private enum CodingKeys: String, CodingKey { case sparse, `default`, abundant }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sparse = try c.decodeIfPresent(Int.self, forKey: .sparse) ?? 1
        `default` = try c.decodeIfPresent(Int.self, forKey: .default) ?? 2
        abundant = try c.decodeIfPresent(Int.self, forKey: .abundant) ?? 3
    }
    /// Unciv setTileResource: MapResourceSetting sparse / abundant, everything else uses default.
    func amount(for setting: String) -> Int { setting == "Sparse" ? sparse : setting == "Abundant" ? abundant : `default` }
}

struct ResourceDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let resourceType: String   // Bonus, Luxury, Strategic
    let terrainsCanBeFoundOn: [String]
    let stats: Stats
    let improvement: String?
    let improvementStats: Stats
    let revealedBy: String?
    let uniques: [String]
    /// Parsed once at load, as Unciv's IHasUniques does (`uniqueObjects by lazy`): tile filters ask every resource for
    /// these (UniqueParameterType's "has a resource with this unique"), and parsing them on each ask cost the city screen
    /// most of its construction list
    let uniqueObjects: [Unique]
    /// Unciv TileResource.majorDepositAmount / minorDepositAmount
    let majorDepositAmount: DepositAmount
    let minorDepositAmount: DepositAmount
    /// Unciv TileResource.improvedBy: further improvements that unlock this resource (vanilla Oil: Oil well, Offshore Platform).
    let improvedBy: [String]
    /// Unciv TileResource.isStockpiled / isCityWide
    var isStockpiled: Bool { uniques.contains("Stockpiled") }
    var isCityWide: Bool { uniques.contains("City-level resource") }
    private enum CodingKeys: String, CodingKey { case name, resourceType, terrainsCanBeFoundOn, improvement, improvementStats, revealedBy, uniques, majorDepositAmount, minorDepositAmount, improvedBy }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        resourceType = try c.decodeIfPresent(String.self, forKey: .resourceType) ?? "Bonus"
        terrainsCanBeFoundOn = try c.decodeIfPresent([String].self, forKey: .terrainsCanBeFoundOn) ?? []
        stats = try Stats(from: decoder)
        improvement = try c.decodeIfPresent(String.self, forKey: .improvement)
        improvementStats = try c.decodeIfPresent(Stats.self, forKey: .improvementStats) ?? .zero
        revealedBy = try c.decodeIfPresent(String.self, forKey: .revealedBy)
        majorDepositAmount = try c.decodeIfPresent(DepositAmount.self, forKey: .majorDepositAmount) ?? DepositAmount()
        minorDepositAmount = try c.decodeIfPresent(DepositAmount.self, forKey: .minorDepositAmount) ?? DepositAmount()
        improvedBy = try c.decodeIfPresent([String].self, forKey: .improvedBy) ?? []
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        uniqueObjects = uniques.map(Unique.init)
    }
}
