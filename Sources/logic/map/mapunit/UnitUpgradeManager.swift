// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/map/mapunit/UnitUpgradeManager.kt`: what a unit may become, and what that costs.
extension GameState {
    /// Unciv UnitActionsUpgrade: only the direct `upgradesTo` (or the nation's equivalent of it); obsolescence of the
    /// target is ignored, but its tech must be known.
    /// Unciv UnitActionsUpgrade.getUpgradeActions: "Can upgrade to []" uniques first, then upgradesTo, each as the civ's equivalent unit
    func upgradeOptions(_ unit: Unit) -> [UnitDef] {
        guard let civ = civ(unit.civId) else { return [] }
        let ctx = UniqueContext(civId: unit.civId, unit: unit)
        var names = unit.def.uniqueObjects.filter { $0.pattern == "Can upgrade to []" && conditionalsHold($0, ctx) }.map { $0.param(0) }
        if let base = unit.def.upgradesTo { names.append(base) }
        return names.compactMap { rs.units[$0] }.map { base in rs.units.values.first { $0.replaces == base.name && $0.uniqueTo == civ.nation } ?? base }
    }

    /// Unciv UnitUpgradeManager.canUpgrade: rejection reasons with the old unit's resources credited, ignoring construction-only and obsolete reasons
    func unitCanUpgrade(_ unit: Unit, to target: UnitDef, ignoreRequirements: Bool = false, ignoreResources: Bool = false) -> Bool {
        guard unit.name != target.name else { return false }
        let credit = resourceRequirementsPerTurn(requiredResource: unit.def.requiredResource, uniques: unit.def.uniqueObjects, ctx: UniqueContext(civId: unit.civId, unit: unit))
        var reasons = unitRejections(target, civId: unit.civId, city: nil, additionalResources: credit).filter { !["Unbuildable", "CannotBeBuilt", "CanOnlyBeBuiltInSpecificCities", "Obsoleted"].contains($0.type) }
        if ignoreRequirements { reasons.removeAll { ["Obsoleted", "RequiresTech", "RequiresPolicy", "MorePolicyBranches", "RequiresBuildingInSomeCity"].contains($0.type) } }
        if ignoreResources { reasons.removeAll { $0.type == "ConsumesResources" } }
        return reasons.isEmpty
    }

    /// The upgrade the unit panel offers: the first option in Unciv's order that the unit can upgrade to
    func upgradeTarget(_ unit: Unit, free: Bool = false) -> UnitDef? {
        upgradeOptions(unit).first { unitCanUpgrade(unit, to: $0, ignoreRequirements: free, ignoreResources: free) }
    }

    /// Unciv UnitUpgradeManager.getCostOfUpgrade: (10 + 2 × Δproduction) × civ modifiers × speed, rounded down to 5.
    /// All in Kotlin Float, as there: the constants are Floats, `toPercent()` is (100 + x) / 100f, `pow` is
    /// Math.pow of the two Floats rounded back to Float. In Double, Professional Army's -33% made 1 - 0.33 =
    /// 0.66999…, and a 1000-gold upgrade came out 665 instead of 670.
    func upgradeCost(_ unit: Unit, to target: UnitDef) -> Int {
        let k = rs.constants
        var civModifier: Float = 1
        let ctx = UniqueContext(civId: unit.civId, unit: unit, tile: map[unit.coord])
        for u in civUniques(unit.civId) where u.pattern == "[]% Gold cost of upgrading" && conditionalsHold(u, ctx) { civModifier *= Float(100 + u.double(0)) / 100 }
        var cost = Float(k.unitUpgradeCostBase)
        cost += max(0, Float(k.unitUpgradeCostPerProduction) * Float(target.cost - unit.def.cost))
        if let era = rs.era(named: target.requiredTech.flatMap { rs.techs[$0]?.era } ?? "") { cost *= 1 + Float(rs.eraIndex(era.name)) * Float(k.unitUpgradeCostEraMultiplier) }
        cost = Float(pow(Double(cost * civModifier), Double(Float(k.unitUpgradeCostExponent))))
        cost *= Float(speed.modifier)
        return GameState.roundedUpgradeCost(cost, roundTo: k.unitUpgradeCostRoundTo)
    }
    /// Unciv's `goldCostOfUpgrade += (cost / constants.roundTo).toInt() * constants.roundTo` (UnitUpgradeManager.kt:73) in
    /// Kotlin Ints: Float.toInt saturates (a NaN is 0) and the product wraps at 32 bits - a mod's `"roundTo": 0` makes the
    /// quotient infinite and the cost 0, where Swift's Int(inf) stopped the app.
    static func roundedUpgradeCost(_ cost: Float, roundTo: Int) -> Int {
        let q = cost / Float(roundTo)
        let n: Int32 = q.isNaN ? 0 : q >= Float(Int32.max) ? .max : q <= Float(Int32.min) ? .min : Int32(q)
        return Int(n &* Int32(truncatingIfNeeded: roundTo))
    }

    /// Upgrade is offered inside our own borders; the unit must still have movement and not be embarked.
    /// Resources the old unit already consumes are credited toward the new unit's requirement.
    /// Unciv upgrade action availability (except gold): movement left, our tile, not embarked, canUpgrade
    /// Unciv UnitUpgradeMenu: every upgrade this unit may take where it stands, each with its own cost.
    func upgradeChoices(_ unit: Unit) -> [(target: UnitDef, cost: Int, missingResource: String?)] {
        guard let tile = map[unit.coord], tile.ownerCivId == unit.civId, unit.hasMovement, !isEmbarked(unit) else { return [] }
        // Unciv UnitUpgradeMenu lists with ignoreResources and disables the button instead, so the player can see
        // what the upgrade would need.
        return upgradeOptions(unit).filter { unitCanUpgrade(unit, to: $0, ignoreResources: true) }.map { target in
            let missing = unitCanUpgrade(unit, to: target) ? nil : target.requiredResource
            return (target, upgradeCost(unit, to: target), missing)
        }
    }

    func canUpgrade(_ unit: Unit) -> (UnitDef, Int)? {
        guard let tile = map[unit.coord], tile.ownerCivId == unit.civId, unit.hasMovement, !isEmbarked(unit),
              let target = upgradeTarget(unit) else { return nil }
        return (target, upgradeCost(unit, to: target))
    }

    @discardableResult
    func upgradeUnit(_ unitId: Int, free: Bool = false, to chosen: UnitDef? = nil) -> Bool {
        guard let i = unitIndex(unitId), let ci = civIndex(units[i].civId) else { return false }
        guard let target = chosen ?? upgradeTarget(units[i], free: free) else { return false }
        var cost = 0
        if !free {
            guard let tile = map[units[i].coord], tile.ownerCivId == units[i].civId, units[i].hasMovement, !isEmbarked(units[i]), unitCanUpgrade(units[i], to: target) else { return false }
            cost = upgradeCost(units[i], to: target)
            guard civs[ci].gold >= Double(cost) else { return false }
        }
        // Unciv UnitUpgradeManager.performUpgrade: `unit.destroy()` and then `placeUnitNearTile(..., unit.id)`.
        // The old unit leaves the civ's unit list - UnitManager.removeUnit: `updateStatsForNextTurn()`, and
        // `updateCivResources()` if it was eating a resource - and the new one is APPENDED to the end of it -
        // addUnit: the same two refreshes for what it eats. Ours renamed the unit where it stood: no refresh at
        // all, so a Swordsman that started eating Iron left the stored supply a whole turn behind (measured on
        // `fresh`, France, 448 stale reads), and the upgraded unit kept its old place in the automation order.
        let civId = units[i].civId
        // Unciv: `val wasEscorting = unit.isEscorting(); unit.destroy(destroyTransportedUnit = false)` - destroy
        // stops the escort, and UnitManager.removeUnit recounts upkeep and resources and fires TriggerUponLosingUnit.
        let wasEscorting = isEscorting(units[i])
        stopEscorting(unitId: unitId)
        rotateCivUnitsToNextDue(civId)   // UnitManager.removeUnit: the civ's list starts at nextPotentiallyDueAt, which goes back to 0
        guard let i = unitIndex(unitId) else { return false }
        // The destroyed MapUnit keeps its UnitPromotions; the new one gets a clone (copyStatisticsTo), so a city's
        // saved default promotions stop following it here.
        freezeSavedUnitPromotions(unitId: unitId)
        var upgraded = units.remove(at: i)
        if GameState.evlogOn { evUnitDie(upgraded) }   // EVLOG: UNIT_DIE (unit.destroy())
        // unit.destroy() hands the old unit's attacks since its turn start to the civ, under the old name; the new
        // MapUnit starts with none (copyStatisticsTo does not copy them)
        civs[ci].attacksSinceTurnStart += upgraded.attacksSinceTurnStart.map { HistoricalAttackMemory(attackingUnit: upgraded.name, source: upgraded.coord, target: $0) }
        upgraded.attacksSinceTurnStart = []
        pathfindingCache[unitId] = nil   // the new MapUnit starts with a fresh movement object
        unitCannotEnterOceanTiles[unitId] = nil   // ...and a fresh MapUnitCache (setTransients → updateUniques)
        func eats(_ u: Unit) -> Bool { !resourceRequirementsPerTurn(requiredResource: u.def.requiredResource, uniques: u.def.uniqueObjects, ctx: UniqueContext(civId: civId, unit: u)).isEmpty }
        updateStatsForNextTurn(civId)
        if eats(upgraded) { updateCivResources(civId) }
        let lost = upgraded
        triggerConditionalUniques(civId: civId) { $0.pattern == "upon losing a [] unit" && self.unitMatches(lost, $0.param(0)) }
        // unit.destroy() ends in `civ.cache.updateViewableTiles()` (MapUnit.kt:954), the old unit already off the map;
        // the new MapUnit's own viewableTiles start empty, so its putInTile finds its view changed
        updateExploration(for: civId)
        unitStoredViewableTiles[unitId] = nil
        let old = upgraded.name
        upgraded.name = target.name
        upgraded.movementLeft = 0
        rotateCivUnitsToNextDue(civId)   // placeUnitNearTile → assignOwner → UnitManager.addUnit (the index is 0 again: no turn)
        units.append(upgraded)
        if GameState.evlogOn { evUnitAdd(upgraded) }   // EVLOG: UNIT_ADD (placeUnitNearTile)
        guard let i = unitIndex(unitId) else { return false }
        updateStatsForNextTurn(civId)
        if eats(units[i]) { updateCivResources(civId) }
        let placedAt = units[i].coord
        if !free { civs[ci].gold -= Double(cost); goldTrace(civs[ci].id, -Double(cost)) }   // Unciv: `if (!isFree) civ.addGold(-cost)` after the new unit is placed
        // Unciv MapUnit.copyStatisticsTo: the new unit merges its built-in promotions; fortification, statuses and ability uses start fresh
        for p in target.promotions where rs.promotions[p] != nil && !units[i].promotions.contains(p) { units[i].promotions.append(p) }
        units[i].turnsFortified = 0; units[i].statuses = [:]; units[i].abilityToTimesUsed = [:]; units[i].religiousStrengthLost = 0
        // Unciv UnitUpgradeManager: wake units that can no longer fortify or guard
        if isFortified(units[i]) && !canFortify(units[i], ignoreAlreadyFortified: true) { units[i].order = .none }
        if units[i].order == .guardPost && !units[i].promotionUniques.contains(where: { $0.pattern == "Withdraws before melee combat" }) { units[i].order = .none }
        // Unciv placeUnitNearTile → putInTile ends in moveThroughTile → updateVisibleTiles: the upgraded unit looks
        // around at once with its own sight (a Trireme become a Caravel sees one tile further, and the civ explores it).
        unitViewCache[unitId] = nil
        moveThroughTile(unitId, placedAt)
        revealFromCurrentTile(unitId)   // copyStatisticsTo: `newUnit.updateVisibleTiles()`, after the promotions it merged
        guard let i = unitIndex(unitId) else { return true }
        unitGainedTriggers(units[i])
        if let ci2 = civIndex(units[i].civId) { civs[ci2].everEarnedUnits.insert(target.name) }
        // Re-escort if it was escorting
        if wasEscorting, unit(unitId)?.coord == placedAt { startEscorting(unitId: unitId) }
        return true
    }
}


/// Unciv UnitUpgradeMenu helpers: "Upgrade all".
extension GameState {
    /// Units of the same base type that could upgrade to the same target right now (UnitUpgradeMenu.allUpgradableUnits).
    func allUpgradableUnits(like unit: Unit) -> [Unit] {
        guard let target = upgradeTarget(unit) else { return [] }
        return units(of: unit.civId).filter { u in
            u.def.name == unit.def.name && u.hasMovement && map[u.coord]?.ownerCivId == u.civId && !isEmbarked(u) && upgradeTarget(u)?.name == target.name && canUpgrade(u) != nil
        }
    }
}
