// Vox Populi 4.22 military supply and the VP growth penalties for the Unciv 4X core (MPL-2.0).
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// CvPlayer::GetNumUnitsSupplied (handicap + cities + population, reduced by era and tech progress, scaled by empire
// size and difficulty), GetNumUnitsOutOfSupply (military units only), calculateUnitProductionMaintenanceMod and
// calculateUnitGrowthMaintenanceMod (5% each per unit over, up to 70%), and GetUnhappinessGrowthPenalty
// (2.5% per point of approval below 50). Active only with jsons/VPNeeds.json.
// Not ported: supply from expended Great People, war weariness supply reduction, trait supply.

import Foundation

extension GameState {
    private func vpDefine(_ vp: VPNeedsData, _ k: String, _ d: Double) -> Int { Int(vp.define(k, d)) }

    /// CvPlayer::GetNumUnitsSupplied for a major civ or a city-state.
    func vpUnitSupply(_ civId: Int) -> Int? {
        guard let vp = vpNeeds, let civ = civ(civId), !civ.isBarbarian else { return nil }
        let d = vp.difficulties[difficulty.name] ?? VPNeedsData.Difficulty()
        let human = civ.isPlayer
        let eraIndex = rs.eras.firstIndex { $0.name == civ.eraName } ?? 0
        let myCities = cities(of: civId)
        let techPct = min(max(civ.techs.count * 100 / max(1, rs.techs.count), 0), 100)
        let ctx = UniqueContext(civId: civId)
        func uniqueSum(_ pattern: String) -> Int { civUniques(civId).filter { $0.pattern == pattern && conditionalsHold($0, ctx) }.reduce(0) { $0 + $1.int(0) } }

        var base: Int, perCity: Int, popPercent: Int
        if civ.isCityState {
            base = d.cityStateUnitSupplyBase; perCity = d.cityStateUnitSupplyPerCity; popPercent = d.cityStateUnitSupplyPopulationPercent
        } else {
            base = (vp.eraSupplyBase?[settings.startingEra] ?? 0) + d.unitSupplyBase + d.unitSupplyPerEraFlat * eraIndex
            if !human { base = (vp.eraSupplyBase?[settings.startingEra] ?? 0) + d.aiUnitSupplyBase + d.aiUnitSupplyPerEraFlat * eraIndex }
            perCity = human ? d.unitSupplyPerCity : d.aiUnitSupplyPerCity
            popPercent = human ? d.unitSupplyPopulationPercent : d.aiUnitSupplyPopulationPercent
        }
        // GetNumUnitsSuppliedByHandicap: one less per era
        base = max(0, base + uniqueSum("[] Unit Supply") - eraIndex * vpDefine(vp, "UNIT_SUPPLY_BASE_TECH_REDUCTION_PER_ERA", 100) / 100)
        // GetNumUnitsSuppliedByCities
        var citySupply = (perCity + uniqueSum("[] Unit Supply per city")) * myCities.count
        let cityTech = techPct * vpDefine(vp, "UNIT_SUPPLY_CITIES_TECH_REDUCTION_MULTIPLIER", 100) / 100
        citySupply = max(0, citySupply * 100 / max(100 + cityTech, 1))
        // GetNumUnitsSuppliedByPopulation: x% of each city's citizens, half for puppets
        var popSupply = 0
        for c in myCities {
            let pop = c.isPuppet ? c.population * vpDefine(vp, "UNIT_SUPPLY_POPULATION_PUPPET_PERCENT", 50) : c.population * 100
            popSupply += pop * popPercent / 100
        }
        let popTech = techPct * vpDefine(vp, "UNIT_SUPPLY_POPULATION_TECH_REDUCTION_MULTIPLIER", 100) / 100
        popSupply = max(0, popSupply * 100 / max(100 + popTech, 1) / 100)
        var supply = base + citySupply + popSupply
        // empire size: 5% less per city beyond the first (World NumCitiesUnitSupplyMod)
        let effective = max(0, myCities.filter { !$0.isPuppet }.count - 1)
        supply = supply * 100 / (100 + effective * vpDefine(vp, "NUM_CITIES_UNIT_SUPPLY_MOD", 5))
        if civ.isMajor {
            let bonus = human ? d.unitSupplyBonusPercent + d.unitSupplyPerEraModifier * eraIndex
                              : d.unitSupplyBonusPercent + d.aiUnitSupplyBonusPercent + (d.unitSupplyPerEraModifier + d.aiUnitSupplyPerEraModifier) * eraIndex
            supply = supply * (100 + bonus) / 100
        }
        return max(0, supply)
    }

    /// CvPlayer::GetNumUnitsOutOfSupply: military units beyond the supply.
    func vpUnitsOutOfSupply(_ civId: Int) -> Int? {
        guard let supply = vpUnitSupply(civId) else { return nil }
        return max(0, units(of: civId).filter { $0.isMilitary }.count - supply)
    }

    /// Production penalty (%, positive) for units over supply.
    func vpSupplyProductionPenalty(_ civId: Int) -> Double? {
        guard let vp = vpNeeds, let over = vpUnitsOutOfSupply(civId) else { return nil }
        return Double(min(max(vpDefine(vp, "MAX_UNIT_SUPPLY_PRODMOD", 70), 0), over * max(vpDefine(vp, "PRODUCTION_PENALTY_PER_UNIT_OVER_SUPPLY", 5), 0)))
    }

    /// The growth modifiers VP applies to a city's surplus food, in percent: supply and approval.
    func vpGrowthModifiers(_ civId: Int) -> [(String, Double)]? {
        guard let vp = vpNeeds, let civ = civ(civId), civ.isMajor else { return nil }
        var out: [(String, Double)] = []
        if let over = vpUnitsOutOfSupply(civId), over > 0 {
            let p = min(max(vpDefine(vp, "MAX_UNIT_SUPPLY_GROWTH_MOD", 70), 0), over * max(vpDefine(vp, "GROWTH_PENALTY_PER_UNIT_OVER_SUPPLY", 5), 0))
            out.append(("Units over supply", -Double(p)))
        }
        if let approval = vpCachedApproval(civId) {
            let threshold = Double(vp.define("UNHAPPY_THRESHOLD", 50))
            let pen = min(0, max(-100, (vp.define("GLOBAL_GROWTH_PENALTY_PER_UNHAPPY", 2.5) * (Double(approval) - threshold)).rounded(.towardZero)))
            if pen < 0 { out.append(("Unhappiness", pen)) }
        }
        return out
    }

    /// Approval as of the civ's last stats update: the empire's stored happiness rows, recomputed at most once per turn
    /// and city count (city stats ask for it on every update).
    func vpCachedApproval(_ civId: Int) -> Int? {
        guard vpNeeds != nil else { return nil }
        let key = VPApprovalCache.Key(game: ObjectIdentifier(self), civ: civId, turn: turn, cities: cities(of: civId).count)
        if let hit = VPApprovalCache.get(key) { return hit }
        let a = vpApproval(civId: civId) ?? 100
        VPApprovalCache.set(key, a)
        return a
    }
}

enum VPApprovalCache {
    struct Key: Hashable { let game: ObjectIdentifier; let civ: Int; let turn: Int; let cities: Int }
    nonisolated(unsafe) private static var values: [Key: Int] = [:]
    private static let lock = NSLock()
    static func get(_ k: Key) -> Int? { lock.lock(); defer { lock.unlock() }; return values[k] }
    static func set(_ k: Key, _ v: Int) {
        lock.lock(); defer { lock.unlock() }
        if values.count > 512 { values.removeAll() }
        values[k] = v
    }
}
