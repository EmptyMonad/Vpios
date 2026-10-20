// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's unit/CivilianUnitAutomation.kt.

extension GameState {
    // MARK: - CivilianUnitAutomation

    func automateCivilianUnit(_ unitId: Int, dangerousTiles: Set<HexCoord>) {
        guard let unit = unit(unitId), let civ = civ(unit.civId) else { return }
        if unit.def.isSettler && !(civ.isCityState && unit.isMilitary) { AI.timed("c.settler") { automateSettlerActions(unitId, dangerousTiles: dangerousTiles) }; return }
        if tryRunAwayIfNecessary(unitId) { return }
        let traced = epochsDebug && epochsTraceUnit == "\(civ.nation)/\(unit.name)"
        if traced {
            let p = uncivPosition(unit.coord)
            print("CIVAUTO t=\(turn) \(unit.name) at=\(p.x),\(p.y) mv=\(unit.movementLeft) clear=\(shouldClearTileForAddInCapitalUnits(unit, unit.coord))")
        }
        if shouldClearTileForAddInCapitalUnits(unit, unit.coord) {
            let dist = distanceToTiles(unit)
            // Unciv: the own tile is in getDistanceToTiles at movement 0, so the minimum is always it and the move is a no-op
            if let t = ([unit.coord] + reachableTilesInOrder(unit)).filter({ canUnitEnter(unit, $0) }).min(by: { (dist[$0] ?? 0) < (dist[$1] ?? 0) }) { moveUnit(unitId, toward: t) }
        }
        guard let u1 = self.unit(unitId) else { return }
        if traced { let p = uncivPosition(u1.coord); print("CIVAUTO t=\(turn) \(u1.name) after-clear at=\(p.x),\(p.y)") }
        if isConnectingRoad(u1) { connectRoadStep(unitId: unitId); return }   // Unciv isAutomatingRoadConnection -> automateConnectRoad
        // Unciv hasUniqueToBuildImprovements: any "Can build [] improvements on tiles" - a Legion at peace too
        if hasUniqueToBuildImprovements(u1) { AI.timed("c.worker") { automateWorkerAction(unitId, dangerousTiles: dangerousTiles) }; return }
        if u1.def.createsWaterImprovements { if !automateWorkBoats(unitId) { _ = tryExplore(unitId) }; return }
        if u1.def.canFoundReligion && civ.religionName == nil && canFoundReligion(civ) { foundReligionWith(unitId); return }
        if u1.def.canFoundReligion && civ.isCityState { disband(unitId: unitId); return }
        if u1.def.canEnhanceReligion && mayEnhanceReligion(civ) { enhanceReligionWith(unitId); return }
        if u1.def.canAddInCapital || u1.def.isSpaceshipPart { automateAddInCapital(unitId); return }
        if u1.def.hasStrengthBonusInRadius && automateGreatGeneral(unitId) { return }
        if u1.def.hasCitadelPlacement && automateCitadelPlacer(unitId) { return }
        if maySpreadReligionAtAll(u1) { automateMissionary(unitId); return }
        if u1.def.preventsSpreadingReligion || u1.def.canRemoveReligions { automateInquisitor(unitId); return }
        let lateGame = isLateGame(unit.civId)
        if lateGame {
            // Unciv getHurryResearchActions: only with a current technology that is not "Cannot be hurried"
            if u1.def.canHurryTech, let cur = self.civ(unit.civId)?.currentTech, rs.techs[cur]?.uniques.contains("Cannot be hurried") != true, let a = greatPersonActions(u1).first(where: { $0.1 == .hurryTech }) { performGreatPersonAction(unitId: unitId, a.1); return }
            if u1.def.canHurryPolicy, let a = greatPersonActions(u1).first(where: { $0.1 == .hurryPolicy }) { performGreatPersonAction(unitId: unitId, a.1); return }
        }
        if u1.def.canTradeMission && lateGame { if conductTradeMission(unitId) { return } }
        if u1.def.canSpeedupConstruction { if speedupWonderConstruction(unitId) { return } }
        // Unciv GainFreeBuildings: walk to the closest reachable city without the building and trigger the unique there
        if let gain = u1.def.uniqueObjects.first(where: { $0.pattern == "Gain a free [] []" }) {
            let options = cities(of: unit.civId).filter { !hasBuildingOrEquivalent($0, gain.param(0)) && (canUnitEnter(u1, $0.coord) || u1.coord == $0.coord) }
                .compactMap { c -> (City, Int)? in
                    if c.coord == u1.coord { return (c, 1) }
                    guard let p = path(for: u1, to: c.coord), !p.isEmpty else { return nil }
                    return (c, p.count)
                }
            if let target = options.min(by: { $0.1 < $1.1 })?.0 {
                if u1.coord == target.coord {
                    triggerUniques([gain], civId: unit.civId, cityId: target.id, unitId: unitId)
                    activateActionSideEffects(unitId: unitId, unique: gain)
                    return
                }
                moveUnit(unitId, toward: target.coord)
            }
            return
        }
        if automateImprovementPlacer(unitId) { return }
        if u1.def.canStartGoldenAge, let a = greatPersonActions(u1).first(where: { $0.1 == .goldenAge }) { performGreatPersonAction(unitId: unitId, a.1); return }
        // The AI doesn't know how to handle unknown civilian units
    }
    func shouldClearTileForAddInCapitalUnits(_ unit: Unit, _ c: HexCoord) -> Bool {
        guard let city = city(at: c), city.isCapital, !(unit.def.canAddInCapital || unit.def.isSpaceshipPart) else { return false }
        return units(of: unit.civId).contains { $0.def.canAddInCapital || $0.def.isSpaceshipPart }
    }
    /// Unciv CivilianUnitAutomation.isLateGame: `researchedTechnologies.size * 1.0f / technologies.size >= 0.55f`, in Float
    func isLateGame(_ civId: Int) -> Bool { Stats.f32(Double(civ(civId).map { researchedTechnologiesSize($0) } ?? 0) / Double(max(1, rs.techs.count))) >= Stats.f32(0.55) }
    /// Unciv ReligionManager.maySpreadReligionAtAll: a major civ, religion on, the unit's religion a founded (not
    /// pantheon) one, and a usable "Can Spread Religion" action left
    func maySpreadReligionAtAll(_ u: Unit) -> Bool {
        guard civ(u.civId)?.isMajor == true, religionEnabled, let r = u.religion, religionIsMajor(r) else { return false }
        return u.def.canSpreadReligion && u.charges > 0
    }
    /// Unciv CivilianUnitAutomation.tryRunAwayIfNeccessary
    @discardableResult
    func tryRunAwayIfNecessary(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId) else { return false }
        let enemiesInWalkingDistance = distanceToTiles(unit).keys.filter { tileHasMilitaryEnemy($0, for: unit.civId) }
        if epochsDebug, epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)" {
            let at = uncivPosition(unit.coord)
            print("RUNAWAYE t=\(uncivTurns) at=\(at.x),\(at.y) enemies=[\(enemiesInWalkingDistance.map { let p = uncivPosition($0); return "(\(p.x),\(p.y))" }.joined(separator: " "))] mil=\(militaryUnitOn(unit.coord)?.name ?? "null")")
        }
        if !enemiesInWalkingDistance.isEmpty && !unit.isMilitary && militaryUnitOn(unit.coord) == nil && map[unit.coord]?.isCityCenter != true {
            runAway(unitId); return true
        }
        return false
    }
    private func runAway(_ unitId: Int) {
        guard let unit = unit(unitId) else { return }
        if let c = reachableTilesInOrder(unit).first(where: { map[$0]?.isCityCenter == true && canUnitEnter(unit, $0) }) { moveUnit(unitId, toward: c); return }
        if let c = reachableTilesInOrder(unit).first(where: { t in militaryUnitOn(t)?.civId == unit.civId && civilianUnitOn(t) == nil }) { moveUnit(unitId, toward: c); return }
        let dangerousOrdered = dangerousTilesInUncivOrder(for: unit)
        let dangerous = Set(dangerousOrdered)
        // Unciv: sortedByDescending(has enemy).minByOrNull(distance): distance decides, capture threats win ties
        // Ties keep the walk of Unciv's HashSet<Tile> (identity hash 1), see dangerousTilesInUncivOrder.
        let closestDanger = dangerousOrdered.enumerated().sorted { a, b in
            let da = a.element.distance(to: unit.coord), db = b.element.distance(to: unit.coord)
            if da != db { return da < db }
            let ea = !enemyUnitsOnTiles([a.element], civId: unit.civId).isEmpty
            let eb = !enemyUnitsOnTiles([b.element], civId: unit.civId).isEmpty
            return ea != eb ? ea : a.offset < b.offset
        }.map { $0.element }.first ?? unit.coord
        // Unciv `sortedWith(compareByDescending { aerialDistanceTo(tileClosestToDanger) }.thenByDescending
        // { isFriendlyTerritory })` is STABLE, so tiles equally far from the threat and equally friendly keep
        // the order `getDistanceToTiles()` found them in. Swift's sort is not, and a tie here is the normal
        // case - a boat fleeing across open water has a whole arc of tiles the same distance from the enemy.
        let furthest = ([unit.coord] + reachableTilesInOrder(unit)).filter { canUnitEnter(unit, $0) && damageFromTerrain(unit, at: $0) < unit.health && !dangerous.contains($0) }
            .enumerated().sorted { a, b in
                let da = a.element.distance(to: closestDanger), db = b.element.distance(to: closestDanger)
                if da != db { return da > db }
                let fa = isFriendlyTerritory(a.element, for: unit.civId), fb = isFriendlyTerritory(b.element, for: unit.civId)
                return fa != fb ? fa : a.offset < b.offset
            }.map { $0.element }.first
        if epochsDebug, epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)" {
            let cd = uncivPosition(closestDanger), me = uncivPosition(unit.coord)
            let dl = uncivTileOrder(dangerous).prefix(6).map { c -> String in let p = uncivPosition(c); return "(\(p.x),\(p.y))@\(c.distance(to: unit.coord))" }.joined(separator: " ")
            let t = furthest.map { uncivPosition($0) }
            print("RUNTOE t=\(uncivTurns) at=\(me.x),\(me.y) closestDanger=\(cd.x),\(cd.y) dangerous=\(dangerous.count) [\(dl)] target=\(t.map { "\($0.x),\($0.y)" } ?? "-")")
        }
        if let t = furthest { moveUnit(unitId, toward: t) }
    }
    /// Unciv Tile.isFriendlyTerritory: ours, a known city-state that counts as friendly, or a civ whose borders are open to us
    func isFriendlyTerritory(_ c: HexCoord, for civId: Int) -> Bool {
        guard let owner = map[c]?.ownerCivId else { return false }
        if owner == civId { return true }
        guard let oc = self.civ(owner), self.civ(civId)?.metCivs.contains(owner) == true else { return false }
        if oc.isCityState && (isFriend(civId, of: owner) || isAlly(civId, of: owner) || civUniques(civId).contains { $0.pattern == "City-State territory always counts as friendly territory" }) { return true }
        return hasOpenBorders(civId, in: owner)
    }
}
