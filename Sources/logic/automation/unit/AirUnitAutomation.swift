// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's unit/AirUnitAutomation.kt.

extension GameState {
    /// Unciv AirUnitAutomation.automateFighter
    func automateFighter(_ unitId: Int) {
        guard let unit = unit(unitId), unit.health >= 75 else { return }
        let range = airRange(unit)
        let enemyTiles = tilesWithEnemyUnitsInDistance(unit.coord, civId: unit.civId, maxDist: range)
        let friendlyAir = map.tilesWithin(unit.coord, radius: range).flatMap { units(at: $0) }.filter { $0.civId == unit.civId && $0.def.isAir }
        let enemyAir = enemyTiles.flatMap { units(at: $0) }.filter { $0.def.isAir && areAtWar(unit.civId, $0.civId) }
        let enemyFighters = enemyAir.count / 2
        // Unciv MapUnit.canAttack: movement left and attacks left this turn
        func canAttackNow(_ u: Unit) -> Bool { u.hasMovement && u.attacksThisTurn < 1 + u.promotionUniques.filter { $0.pattern == "[] additional attacks per turn" }.reduce(0) { $0 + $1.int(0) } }
        let unused = friendlyAir.filter { canAttackNow($0) }.count
        let used = friendlyAir.filter { !canAttackNow($0) }.count
        if unused < enemyFighters { return }
        if used <= enemyFighters {
            let sweepBonus = unit.promotionUniques.filter { $0.pattern == "[]% Strength when performing Air Sweep" }.reduce(0) { $0 + $1.int(0) }
            if used + unused < enemyFighters && !unit.promotionUniques.contains(where: { $0.pattern == "Unit will heal every turn, even if it performs an action" }) && sweepBonus <= 0 { return }
            if tryAirSweep(unitId, enemyTiles) { return }
        }
        guard let live = self.unit(unitId), live.health >= 80 else { return }   // Unciv reads the live unit, which the sweep has just damaged
        if tryAttackNearbyEnemy(unitId) { return }
        if unit.promotionUniques.contains(where: { $0.pattern == "Cannot move" }) { return }   // Unciv cache.cannotMove
        if tryRelocateToCitiesWithEnemyNearBy(unitId) { return }
        let (paths, order) = aerialPathsToCities(unit)
        if paths.isEmpty { return }
        // Unciv: tiles within getMaxMovementForAirUnits (range × 2) whose first air unit is at war with us.
        // `pathsToCities.keys.groupBy { .. }` keeps the HashMap's walk inside each group, and `minByOrNull` the first
        // of equal path lengths - ours broke those ties by (q, r).
        let byNeed = Dictionary(grouping: order, by: { c in map.tilesWithin(c, radius: airRange(unit) * 2).filter { t in units(at: t).first(where: { $0.def.isAir }).map { areAtWar(unit.civId, $0.civId) } ?? false }.count })
        if let maxNeed = byNeed.keys.max(), maxNeed > 0, let chosen = byNeed[maxNeed]!.min(by: { paths[$0]!.count < paths[$1]!.count }) {
            // Unciv `unit.movement.moveToTile(firstStepInPath)`: the air branch teleports without asking for movement
            if let first = paths[chosen]?.first { moveToTile(unitId, first) }; return
        }
        tryMoveToCitiesToAerialAttackFrom(paths, order, unitId)
    }
    private func tryAirSweep(_ unitId: Int, _ enemyTiles: [HexCoord]) -> Bool {
        guard let unit = unit(unitId), unit.def.canAirSweep else { return false }
        // Unciv: a tile with a unit of a civ at war (the city check sits inside the unit check, so empty cities never qualify)
        guard let target = enemyTiles.filter({ c in canAirSweep(unit, c) && units(at: c).contains { u in areAtWar(unit.civId, u.civId) || (city(at: c).map { areAtWar(unit.civId, $0.civId) } ?? false) } }).min(by: { $0.distance(to: unit.coord) < $1.distance(to: unit.coord) }) else { return false }
        _ = airSweep(unitId: unitId, target: target)
        return !(self.unit(unitId)?.hasMovement ?? false)
    }
    /// Unciv AirUnitAutomation.automateBomber
    func automateBomber(_ unitId: Int) {
        guard let unit = unit(unitId), unit.health >= 75 else { return }
        if tryAttackNearbyEnemy(unitId) { return }
        if unit.health <= 90 || (unit.health < 100 && !isAtWarAtAll(unit.civId)) { return }
        if unit.promotionUniques.contains(where: { $0.pattern == "Cannot move" }) { return }   // Unciv cache.cannotMove
        if tryRelocateToCitiesWithEnemyNearBy(unitId) { return }
        let (paths, order) = aerialPathsToCities(unit)
        if paths.isEmpty { return }
        tryMoveToCitiesToAerialAttackFrom(paths, order, unitId)
    }
    /// Unciv UnitMovement.canMoveTo for air units: an own city, or a carrier with room for this unit
    func airCanMoveTo(_ unit: Unit, _ c: HexCoord) -> Bool {
        if let city = city(at: c), city.civId == unit.civId {
            // Unciv tile.airUnits includes the unit itself, so its own full city is not a legal destination.
            return units.filter { $0.coord == c && $0.def.isAir && !$0.isTransported }.count < maxAirUnits(city)
        }
        return units(at: c).contains { $0.civId == unit.civId && $0.id != unit.id && carrierCapacity($0) > 0 && canBeCarried(unit, by: $0) && carrierAvailableCapacity($0, for: unit) > 0 }
    }
    /// Unciv UnitMovement.getAerialPathsToCities: breadth-first hops of the unit's range between tiles it can move to.
    /// `order` stands for the walk of the returned HashMap<Tile, ...>. Unciv fills `tilesReached` (a HashMap, the
    /// start first) in the order the tiles are reached, then a SECOND HashMap `pathsToCities` by walking
    /// `tilesReached.keys` - start included - and only then `pathsToCities.remove(startingTile)`. Under identity
    /// hash 1 that is JavaHash1Set's walk of JavaHash1Set's walk, with the removal played on the second map: from
    /// 11 tiles on, the two walks differ and a tree bin's removal reorders it again.
    private func aerialPathsToCities(_ unit: Unit) -> (paths: [HexCoord: [HexCoord]], order: [HexCoord]) {
        let range = airRange(unit)
        var parent: [HexCoord: HexCoord] = [unit.coord: unit.coord]
        var reached: [HexCoord] = [unit.coord]
        var toCheck = [unit.coord]
        while !toCheck.isEmpty {
            var next: [HexCoord] = []
            for cur in toCheck {
                for c in map.tilesWithin(cur, radius: range) where airCanMoveTo(unit, c) && parent[c] == nil { parent[c] = cur; reached.append(c); next.append(c) }
            }
            toCheck = next
        }
        var paths: [HexCoord: [HexCoord]] = [:]
        let tilesReachedWalk = JavaHash1Set.iterationOrder(reached)   // `for (city in tilesReached.keys)`
        let order = JavaHash1Set.iterationOrder(tilesReachedWalk, removing: unit.coord)   // pathsToCities, after remove(startingTile)
        for dest in order {
            var path: [HexCoord] = []; var cur = dest
            while cur != unit.coord { path.append(cur); cur = parent[cur]! }
            paths[dest] = path.reversed()
        }
        return (paths, order)
    }
    private func tryMoveToCitiesToAerialAttackFrom(_ paths: [HexCoord: [HexCoord]], _ order: [HexCoord], _ unitId: Int) {
        guard let unit = unit(unitId) else { return }
        let range = airRange(unit)
        let candidates = order.filter { dest in dest != unit.coord && map.tilesWithin(dest, radius: range).contains { containsAttackableEnemy($0, attacker: unit) } }
        // Unciv `minByOrNull { pathsToCities[it]!!.size }`: the first of equal lengths in the map's walk
        guard let closest = candidates.min(by: { paths[$0]!.count < paths[$1]!.count }), let first = paths[closest]?.first else { return }
        // Unciv `airUnit.movement.moveToTile(firstStepInPath)`: no movement check - a plane or missile bought this
        // turn (0 movement) still relocates. The player's Rebase action (rebase(unitId:to:)) is the one that needs it.
        moveToTile(unitId, first)
    }
    /// Unciv AirUnitAutomation.automateNukes
    func automateNukes(_ unitId: Int) {
        guard let unit = unit(unitId), isAtWarAtAll(unit.civId) else { return }
        if unit.def.isAir {
            let inRange = map.tilesWithin(unit.coord, radius: airRange(unit)).filter { $0.distance(to: unit.coord) >= 2 }
            // Unciv calls Nuke.NUKE directly - no canAttack, so a missile bought this turn (0 movement) still launches
            if let best = inRange.map({ ($0, nukeLocationValue(unit, $0)) }).max(by: { $0.1 < $1.1 }), best.1 > 0,
               let strength = unitMatchingUniques(unit, "Nuclear weapon of Strength []").first?.int(0) {
                _ = detonate(unitId: unitId, at: best.0, strength: strength)
            }
            tryRelocateMissileToNearbyAttackableCities(unitId)
        } else {
            let attackable = attackableEnemies(unit, distanceToTiles: distanceToTiles(unit))
            if let best = attackable.map({ ($0, nukeLocationValue(unit, $0.tileToAttack)) }).max(by: { $0.1 < $1.1 }), best.1 > 0 { moveAndAttack(unitId, best.0) }
            _ = tryHeadTowardsEnemyCity(unitId)
        }
    }
    /// Unciv AirUnitAutomation.getNukeLocationValue
    private func nukeLocationValue(_ nuke: Unit, _ target: HexCoord) -> Int {
        let civId = nuke.civId
        guard mayUseNuke(nuke, target: target) else { return Int.min }
        let radius = nukeBlastRadius(nuke)   // Unciv getNukeBlastRadius: the unit's uniques
        let blast = map.tilesWithin(target, radius: radius)
        let civsInBlast = Set(blast.compactMap { map[$0]?.ownerCivId } + blast.compactMap { units(at: $0).first?.civId })   // Unciv getFirstUnit
        if civsInBlast.contains(where: { $0 != civId && !areAtWar(civId, $0) }) { return -100000 }
        if !civsInBlast.contains(where: { areAtWar(civId, $0) }) { return -100000 }
        var value = -500
        func evaluate(_ target: Int, _ ours: Int, _ theirs: Int) -> Int { target == civId ? ours : theirs }
        let vis = visibleTiles(for: civId)
        let seenIds = Set(visibleUnits(for: civId).map { $0.id })
        for c in blast {
            if vis.contains(c) {
                for u in units(at: c) where u.civId == civId || seenIds.contains(u.id) {   // Unciv: targetUnit.isInvisible(civ) is skipped
                    let tileValue = c == target ? 80 : 50
                    if u.isMilitary { value += c == target ? evaluate(u.civId, -200, tileValue) : evaluate(u.civId, -150, 50) }
                    else { value += evaluate(u.civId, -100, tileValue / 2) }
                }
            }
            if let city = city(at: c), !(city.health <= 50 && map.neighbors(of: c).contains { militaryUnitOn($0)?.civId == civId }) {   // Unciv `it.militaryUnit?.civ == civ`
                value += evaluate(city.civId, -100000, 250)
            } else if let t = map[c], let owner = t.ownerCivId {
                if !(t.isWater || t.isImpassable || t.features.contains("Fallout")) { value += evaluate(owner, -40, 10) }
                if t.improvement != nil && !t.pillaged { value += evaluate(owner, -40, 20) }
            }
            if value < -1000 { return value }
        }
        return value
    }
    /// Unciv AirUnitAutomation.automateMissile
    func automateMissile(_ unitId: Int) {
        if tryAttackNearbyEnemy(unitId) { return }
        tryRelocateMissileToNearbyAttackableCities(unitId)
    }
    /// Unciv: tiles within range (spiral order) the missile can move to, next to an enemy city
    private func tryRelocateMissileToNearbyAttackableCities(_ unitId: Int) {
        guard let unit = unit(unitId) else { return }
        let range = airRange(unit)
        // Unciv getTilesInDistance is `range.flatMap { getTilesAtDistance(origin, it) }` - ring by ring, each
        // ring in its own walk order, and no sort anywhere. `tilesWithin` already IS that order, so the sort
        // that was here could only scramble it: Swift's `sorted(by:)` is not stable and every ring is a tie.
        for c in map.tilesWithin(unit.coord, radius: range) where airCanMoveTo(unit, c) {
            // Unciv `unit.movement.moveToTile(city)`: returns at once when already there, and never asks for movement
            if map.tilesWithin(c, radius: range).contains(where: { t in city(at: t).map { areAtWar(unit.civId, $0.civId) } ?? false }) { moveToTile(unitId, c); return }
        }
        let (paths, order) = aerialPathsToCities(unit)
        if !paths.isEmpty { tryMoveToCitiesToAerialAttackFrom(paths, order, unitId) }
    }
    /// Unciv: cities and carriers within range × 2 (spiral order, current tile included) with a visible attackable enemy in range
    private func tryRelocateToCitiesWithEnemyNearBy(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId) else { return false }
        let vis = visibleTiles(for: unit.civId)
        let range = airRange(unit)
        for c in map.tilesWithin(unit.coord, radius: range * 2) where airCanMoveTo(unit, c) {   // Unciv getTilesInDistance: ring order, no sort
            if map.tilesWithin(c, radius: range).contains(where: { vis.contains($0) && containsAttackableEnemy($0, attacker: unit) }) { moveToTile(unitId, c); return true }   // Unciv moveToTile, no movement check
        }
        return false
    }
}
