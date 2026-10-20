// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct EraDef: Decodable {
    let name: String
    let startingSettlerCount: Int
    let startingWorkerCount: Int
    let startingMilitaryUnitCount: Int
    let startingMilitaryUnit: String
    /// Unciv Era.startingSettlerUnit / startingWorkerUnit: "For mods which have differently named settlers"
    let startingSettlerUnit: String
    let startingWorkerUnit: String
    let settlerPopulation: Int
    let iconRGB: [Int]?
    let embarkDefense: Int
    let uniques: [String]
    let startingGold: Int
    let startingCulture: Int
    let settlerBuildings: [String]
    let researchAgreementCost: Int
    let baseUnitBuyCost: Int
    let citySound: String?
    /// Unciv Era.startPercent: share of the speed's turn range already elapsed when a game starts in this era (year display only).
    let startPercent: Int
    /// Unciv Era.startingObsoleteWonders: world wonders unavailable when the game starts in this era.
    let startingObsoleteWonders: [String]
    private enum CodingKeys: String, CodingKey { case name, startingSettlerCount, startingSettlerUnit, startingWorkerUnit, startingWorkerCount, startingMilitaryUnitCount, startingMilitaryUnit, settlerPopulation, iconRGB, embarkDefense, startingGold, startingCulture, uniques, settlerBuildings, researchAgreementCost, baseUnitBuyCost, citySound, startPercent, startingObsoleteWonders }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        startingSettlerCount = try c.decodeIfPresent(Int.self, forKey: .startingSettlerCount) ?? 1
        startingWorkerCount = try c.decodeIfPresent(Int.self, forKey: .startingWorkerCount) ?? 0
        startingMilitaryUnitCount = try c.decodeIfPresent(Int.self, forKey: .startingMilitaryUnitCount) ?? 1
        startingMilitaryUnit = try c.decodeIfPresent(String.self, forKey: .startingMilitaryUnit) ?? Names.brave
        startingSettlerUnit = try c.decodeIfPresent(String.self, forKey: .startingSettlerUnit) ?? Names.settler
        startingWorkerUnit = try c.decodeIfPresent(String.self, forKey: .startingWorkerUnit) ?? Names.laborer
        settlerPopulation = try c.decodeIfPresent(Int.self, forKey: .settlerPopulation) ?? 1
        iconRGB = try c.decodeIfPresent([Int].self, forKey: .iconRGB)
        embarkDefense = try c.decodeIfPresent(Int.self, forKey: .embarkDefense) ?? 3
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        startingGold = try c.decodeIfPresent(Int.self, forKey: .startingGold) ?? 0
        startingCulture = try c.decodeIfPresent(Int.self, forKey: .startingCulture) ?? 0
        settlerBuildings = try c.decodeIfPresent([String].self, forKey: .settlerBuildings) ?? []
        researchAgreementCost = try c.decodeIfPresent(Int.self, forKey: .researchAgreementCost) ?? 300
        baseUnitBuyCost = try c.decodeIfPresent(Int.self, forKey: .baseUnitBuyCost) ?? 200
        citySound = try c.decodeIfPresent(String.self, forKey: .citySound)
        startPercent = try c.decodeIfPresent(Int.self, forKey: .startPercent) ?? 0
        startingObsoleteWonders = try c.decodeIfPresent([String].self, forKey: .startingObsoleteWonders) ?? []
    }

    /// Unciv Era.getStartingUnits: the era's settlers, workers and military units by name - a settler or worker the
    /// ruleset does not have is the first city founder / improvement builder in ruleset order, and none throws.
    func startingUnits(_ rs: Ruleset) throws -> [String] {
        let settler = rs.units[startingSettlerUnit] != nil ? startingSettlerUnit
            : rs.unitOrder.first { rs.units[$0]?.hasFoundCityUnique == true }
        guard let settler else { throw EraUnitError(message: "No Settler unit found for era \(name)") }
        let worker = startingWorkerCount == 0 || rs.units[startingWorkerUnit] != nil ? startingWorkerUnit
            : rs.unitOrder.first { rs.units[$0]?.rulesetUniqueObjects.contains { $0.pattern == "Can build [] improvements on tiles" } == true }
        guard let worker else { throw EraUnitError(message: "No Worker unit found for era \(name)") }
        return [String](repeating: settler, count: startingSettlerCount) + [String](repeating: worker, count: startingWorkerCount)
            + [String](repeating: startingMilitaryUnit, count: startingMilitaryUnitCount)
    }
}

/// Unciv's UncivShowableException out of a new game's starting units; NewGameScreen.startNewGame shows the map failure.
struct EraUnitError: Error, CustomStringConvertible { var message: String; var description: String { message } }
