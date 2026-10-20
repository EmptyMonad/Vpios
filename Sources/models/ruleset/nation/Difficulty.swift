// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Unciv Difficulty: every modifier is a Float, so each is rounded to Float as it is read.
struct DifficultyDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let baseHappiness: Int
    let extraHappinessPerLuxury: Double
    let researchCostModifier: Double
    let unitCostModifier: Double
    let buildingCostModifier: Double
    let policyCostModifier: Double
    let unhappinessModifier: Double
    let barbarianBonus: Double
    let barbarianSpawnDelay: Int
    let playerBonusStartingUnits: [String]
    let aiCityGrowthModifier: Double
    let aiUnitCostModifier: Double
    let aiBuildingCostModifier: Double
    let aiWonderCostModifier: Double
    let aiFreeTechs: [String]
    let aiMajorCivBonusStartingUnits: [String]
    let aiUnhappinessModifier: Double
    let turnBarbariansCanEnterPlayerTiles: Int
    let clearBarbarianCampReward: Int
    let unitSupplyBase: Int
    let unitSupplyPerCity: Int
    let aiUnitMaintenanceModifier: Double
    let aiUnitSupplyModifier: Double
    let aiBuildingMaintenanceModifier: Double
    let aiCityStateBonusStartingUnits: [String]
    let aiDifficultyLevel: String?
    private enum CodingKeys: String, CodingKey {
        case name, baseHappiness, extraHappinessPerLuxury, researchCostModifier, unitCostModifier, buildingCostModifier, policyCostModifier, unhappinessModifier, barbarianBonus, barbarianSpawnDelay, playerBonusStartingUnits, aiCityGrowthModifier, aiUnitCostModifier, aiBuildingCostModifier, aiWonderCostModifier, aiFreeTechs, aiMajorCivBonusStartingUnits, aiUnhappinessModifier, turnBarbariansCanEnterPlayerTiles, clearBarbarianCampReward, unitSupplyBase, unitSupplyPerCity, aiUnitMaintenanceModifier, aiUnitSupplyModifier, aiBuildingMaintenanceModifier, aiCityStateBonusStartingUnits, aiDifficultyLevel
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        baseHappiness = try c.decodeIfPresent(Int.self, forKey: .baseHappiness) ?? 0   // Unciv Difficulty.baseHappiness = 0
        extraHappinessPerLuxury = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .extraHappinessPerLuxury) ?? 0)
        researchCostModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .researchCostModifier) ?? 1)
        unitCostModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .unitCostModifier) ?? 1)
        buildingCostModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .buildingCostModifier) ?? 1)
        policyCostModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .policyCostModifier) ?? 1)
        unhappinessModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .unhappinessModifier) ?? 1)
        barbarianBonus = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .barbarianBonus) ?? 0)
        barbarianSpawnDelay = try c.decodeIfPresent(Int.self, forKey: .barbarianSpawnDelay) ?? 0
        playerBonusStartingUnits = try c.decodeIfPresent([String].self, forKey: .playerBonusStartingUnits) ?? []
        aiCityGrowthModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .aiCityGrowthModifier) ?? 1)
        aiUnitCostModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .aiUnitCostModifier) ?? 1)
        aiBuildingCostModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .aiBuildingCostModifier) ?? 1)
        aiWonderCostModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .aiWonderCostModifier) ?? 1)
        aiFreeTechs = try c.decodeIfPresent([String].self, forKey: .aiFreeTechs) ?? []
        aiMajorCivBonusStartingUnits = try c.decodeIfPresent([String].self, forKey: .aiMajorCivBonusStartingUnits) ?? []
        aiUnhappinessModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .aiUnhappinessModifier) ?? 1)
        turnBarbariansCanEnterPlayerTiles = try c.decodeIfPresent(Int.self, forKey: .turnBarbariansCanEnterPlayerTiles) ?? 0
        clearBarbarianCampReward = try c.decodeIfPresent(Int.self, forKey: .clearBarbarianCampReward) ?? 25
        unitSupplyBase = try c.decodeIfPresent(Int.self, forKey: .unitSupplyBase) ?? 5
        unitSupplyPerCity = try c.decodeIfPresent(Int.self, forKey: .unitSupplyPerCity) ?? 2
        aiUnitMaintenanceModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .aiUnitMaintenanceModifier) ?? 1)
        aiUnitSupplyModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .aiUnitSupplyModifier) ?? 0)
        aiBuildingMaintenanceModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .aiBuildingMaintenanceModifier) ?? 1)
        aiCityStateBonusStartingUnits = try c.decodeIfPresent([String].self, forKey: .aiCityStateBonusStartingUnits) ?? []
        aiDifficultyLevel = try c.decodeIfPresent(String.self, forKey: .aiDifficultyLevel)
    }
}
