// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Unciv ModConstants (ModOptions.json "constants"); every field has Unciv's default. The fields Unciv declares as
/// Float are rounded to Float here (read and default alike); its Double ones (8.0, 0.4, ...) stay Double.
struct ModConstants: Decodable {
    var maxXPfromBarbarians = 30
    var cityStrengthBase = 8.0
    var cityStrengthPerPop = 0.4
    var cityStrengthFromTechsMultiplier = 5.5
    var cityStrengthFromTechsExponent = 2.8
    var cityStrengthFromTechsFullMultiplier = 1.0
    var cityStrengthFromGarrison = 0.2
    var unitSupplyPerPopulation = 0.5
    var minimalCityDistance = 3
    var minimalCityDistanceOnDifferentContinents = 2
    var baseCityBombardRange = 2
    var cityWorkRange = 3
    var cityExpandRange = 5
    var cityAirUnitCapacity = 6
    var goldGiftMultiplier = Stats.f32(1.0)
    var goldGiftTradeMultiplier = Stats.f32(0.8)
    var goldGiftDegradationMultiplier = Stats.f32(1.0)
    var unitUpgradeCostBase = Stats.f32(10.0)
    var unitUpgradeCostPerProduction = Stats.f32(2.0)
    var unitUpgradeCostEraMultiplier = Stats.f32(0.0)
    var unitUpgradeCostExponent = Stats.f32(1.0)
    var unitUpgradeCostRoundTo = 5
    var naturalWonderCountMultiplier = Stats.f32(0.124)
    var naturalWonderCountAddedConstant = Stats.f32(0.1)
    var ancientRuinCountMultiplier = Stats.f32(0.025)
    var spawnIceBelowTemperature = -0.8        // Unciv ModConstants: declared but never read in Unciv either
    var maxLakeSize = 10
    var riverCountMultiplier = Stats.f32(0.01)
    var minRiverLength = 5
    var maxRiverLength = 666                  // Unciv ModConstants: arbitrary cap on river length / closest-water search
    var maxImprovementTechErasForward = -1    // Unciv ModConstants: -1 = improvement picker proposes techs from any era
    var religionLimitBase = 1
    var religionLimitMultiplier = Stats.f32(0.5)
    var pantheonBase = 10
    var pantheonGrowth = 5
    var workboatAutomationSearchMaxTiles = 37
    var minimumCityLocationTileValue = Stats.f32(53.0)
    var minimumWarDuration = 10
    var baseTurnsUntilRevolt = 4
    var cityStateElectionTurns = 15
    var maxGoldTradeOffer = 10000
    var tributeGlobalModifier = 100
    var tributeLocalModifier = 100
    var maxSpyRank = 3
    var spyRankSkillPercentBonus = 30
    var spyRankStealPercentBonus = 25
    var spyTechStealCostModifier = Stats.f32(1.25)
    var scoreFromPopulation = 3
    var scoreFromWonders = 40
    init() {}
    private struct UpgradeCost: Decodable { var base: Double?; var perProduction: Double?; var eraMultiplier: Double?; var exponent: Double?; var roundTo: Int? }
    private enum CodingKeys: String, CodingKey {
        case maxXPfromBarbarians, cityStrengthBase, cityStrengthPerPop, cityStrengthFromTechsMultiplier, cityStrengthFromTechsExponent, cityStrengthFromTechsFullMultiplier, cityStrengthFromGarrison, unitSupplyPerPopulation, minimalCityDistance, minimalCityDistanceOnDifferentContinents, baseCityBombardRange, cityWorkRange, cityExpandRange, cityAirUnitCapacity, goldGiftMultiplier, goldGiftTradeMultiplier, goldGiftDegradationMultiplier, unitUpgradeCost, naturalWonderCountMultiplier, naturalWonderCountAddedConstant, ancientRuinCountMultiplier, spawnIceBelowTemperature, maxLakeSize, riverCountMultiplier, minRiverLength, maxRiverLength, maxImprovementTechErasForward, religionLimitBase, religionLimitMultiplier, pantheonBase, pantheonGrowth, workboatAutomationSearchMaxTiles, minimumCityLocationTileValue, minimumWarDuration, baseTurnsUntilRevolt, cityStateElectionTurns, maxGoldTradeOffer, tributeGlobalModifier, tributeLocalModifier, maxSpyRank, spyRankSkillPercentBonus, spyRankStealPercentBonus, spyTechStealCostModifier, scoreFromPopulation, scoreFromWonders
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func i(_ k: CodingKeys, _ d: Int) -> Int { (try? c.decodeIfPresent(Int.self, forKey: k)).flatMap { $0 } ?? d }
        func d(_ k: CodingKeys, _ d: Double) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)).flatMap { $0 } ?? d }
        maxXPfromBarbarians = i(.maxXPfromBarbarians, 30); cityStrengthBase = d(.cityStrengthBase, 8); cityStrengthPerPop = d(.cityStrengthPerPop, 0.4)
        cityStrengthFromTechsMultiplier = d(.cityStrengthFromTechsMultiplier, 5.5); cityStrengthFromTechsExponent = d(.cityStrengthFromTechsExponent, 2.8)
        cityStrengthFromTechsFullMultiplier = d(.cityStrengthFromTechsFullMultiplier, 1); cityStrengthFromGarrison = d(.cityStrengthFromGarrison, 0.2)
        unitSupplyPerPopulation = d(.unitSupplyPerPopulation, 0.5); minimalCityDistance = i(.minimalCityDistance, 3); minimalCityDistanceOnDifferentContinents = i(.minimalCityDistanceOnDifferentContinents, 2)
        baseCityBombardRange = i(.baseCityBombardRange, 2); cityWorkRange = i(.cityWorkRange, 3); cityExpandRange = i(.cityExpandRange, 5); cityAirUnitCapacity = i(.cityAirUnitCapacity, 6)
        goldGiftMultiplier = Stats.f32(d(.goldGiftMultiplier, 1)); goldGiftTradeMultiplier = Stats.f32(d(.goldGiftTradeMultiplier, 0.8)); goldGiftDegradationMultiplier = Stats.f32(d(.goldGiftDegradationMultiplier, 1))
        if let u = try? c.decodeIfPresent(UpgradeCost.self, forKey: .unitUpgradeCost) {
            unitUpgradeCostBase = Stats.f32(u.base ?? 10); unitUpgradeCostPerProduction = Stats.f32(u.perProduction ?? 2); unitUpgradeCostEraMultiplier = Stats.f32(u.eraMultiplier ?? 0); unitUpgradeCostExponent = Stats.f32(u.exponent ?? 1); unitUpgradeCostRoundTo = u.roundTo ?? 5
        }
        naturalWonderCountMultiplier = Stats.f32(d(.naturalWonderCountMultiplier, 0.124)); naturalWonderCountAddedConstant = Stats.f32(d(.naturalWonderCountAddedConstant, 0.1)); ancientRuinCountMultiplier = Stats.f32(d(.ancientRuinCountMultiplier, 0.025)); spawnIceBelowTemperature = d(.spawnIceBelowTemperature, -0.8)
        maxLakeSize = i(.maxLakeSize, 10); riverCountMultiplier = Stats.f32(d(.riverCountMultiplier, 0.01)); minRiverLength = i(.minRiverLength, 5); maxRiverLength = i(.maxRiverLength, 666); maxImprovementTechErasForward = i(.maxImprovementTechErasForward, -1)
        religionLimitBase = i(.religionLimitBase, 1); religionLimitMultiplier = Stats.f32(d(.religionLimitMultiplier, 0.5)); pantheonBase = i(.pantheonBase, 10); pantheonGrowth = i(.pantheonGrowth, 5)
        workboatAutomationSearchMaxTiles = i(.workboatAutomationSearchMaxTiles, 37); minimumCityLocationTileValue = Stats.f32(d(.minimumCityLocationTileValue, 53)); minimumWarDuration = i(.minimumWarDuration, 10)
        baseTurnsUntilRevolt = i(.baseTurnsUntilRevolt, 4); cityStateElectionTurns = i(.cityStateElectionTurns, 15); maxGoldTradeOffer = i(.maxGoldTradeOffer, 10000)
        tributeGlobalModifier = i(.tributeGlobalModifier, 100); tributeLocalModifier = i(.tributeLocalModifier, 100); maxSpyRank = i(.maxSpyRank, 3)
        spyRankSkillPercentBonus = i(.spyRankSkillPercentBonus, 30); spyRankStealPercentBonus = i(.spyRankStealPercentBonus, 25); spyTechStealCostModifier = Stats.f32(d(.spyTechStealCostModifier, 1.25))
        scoreFromPopulation = i(.scoreFromPopulation, 3); scoreFromWonders = i(.scoreFromWonders, 40)
    }
}
