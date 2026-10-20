// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's unit/HeadTowardsEnemyCityAutomation.kt.

extension GameState {
    // MARK: - HeadTowardsEnemyCityAutomation

    /// Unciv HeadTowardsEnemyCityAutomation.getEnemyCitiesByPriority
    func enemyCitiesByPriority(_ unit: Unit) -> [City] {
        let enemies = knownCivs(unit.civId).filter { areAtWar(unit.civId, $0.id) && !cities(of: $0.id).isEmpty }
        guard let closest = enemies.compactMap({ foreignCityNearCapital(of: unit.civId, foreignCiv: $0.id) }).min(by: { $0.distance < $1.distance })?.city else { return [] }
        // Unciv `.sortedBy { it.value }` over `closestEnemyCity.civ.cities` - stable, and two cities the
        // same distance from the target are the normal case, so the order the civ lists them in decides.
        var list = cities(of: closest.civId).map { ($0, $0.coord.distance(to: closest.coord)) }.filter { $0.1 <= 10 }
            .enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map { $0.element.0 }
        if unit.def.isRanged { list = list.filter { $0.health != 1 } }
        return list
    }
    func tryHeadTowardsEnemyCity(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId), !cities(of: unit.civId).isEmpty else { return false }
        for city in enemyCitiesByPriority(unit) {
            if let p = path(for: unit, to: city.coord), !p.isEmpty { return headTowardsEnemyCity(unitId, city.coord, path: p) }
        }
        return false
    }
    private var maxDistanceForLanding: Int { 5 }
    private var minDistanceForLanding: Int { 3 }
    /// Unciv HeadTowardsEnemyCityAutomation.headTowardsEnemyCity
    func headTowardsEnemyCity(_ unitId: Int, _ cityTile: HexCoord, path: [HexCoord]) -> Bool {
        guard let unit = unit(unitId) else { return false }
        let range = attackRange(unit)
        if range > 2 { return headTowardsEnemyCityLongRange(unitId, cityTile, range) }
        guard let next = path.first else { return false }
        // Unciv getShortestPath lists per-turn stops, so its size is the number of turns to get there
        // Unciv `unit.movement.moveToTile(nextTileInPath)` - this turn's stop on the path it already has. Heading
        // "toward the city" instead re-pathed to the city tile itself, which a ship can never enter, and left
        // Yerevan's trireme where it was.
        if unit.coord.distance(to: cityTile) > maxDistanceForLanding && path.count > minDistanceForLanding { moveToTile(unitId, next); return true }
        let ours = map.tilesWithin(cityTile, radius: 6).flatMap { units(at: $0) }.filter { $0.isMilitary && $0.civId == unit.civId }
        if epochsDebug, epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)", let c = city(at: cityTile) {
            let exp = ours.reduce(0) { $0 + (combatPreview(attacker: $1, targetTile: c.coord, resolving: true)?.damageToDefender ?? 0) }
            let n0 = uncivPosition(next), ct = uncivPosition(cityTile)
            print("TRACEH t=\(turn) city=\(c.name)@\(ct.x),\(ct.y) hp=\(c.health) next=\(n0.x),\(n0.y) pathLen=\(path.count) ours=\(ours.count) expected=\(exp) cannot=\(cannotTakeCitySoon(ours, c)) | " + ours.map { u in let q = uncivPosition(u.coord); return "\(u.name)@\(q.x),\(q.y):hp\(u.health):d\(combatPreview(attacker: u, targetTile: c.coord, resolving: true)?.damageToDefender ?? -1)" }.joined(separator: " "))
        }
        if let city = city(at: cityTile), cannotTakeCitySoon(ours, city) { return headToLandingGrounds(unitId, cityTile) }
        moveToTile(unitId, next)   // Unciv moveToTile(shortestPath[0]): this turn's stop on the way
        return true
    }
    /// Unciv: cannot take within 5 turns
    func cannotTakeCitySoon(_ ours: [Unit], _ city: City) -> Bool {
        // Unciv calculateDamageToDefender(MapUnitCombatant(it), cityCombatant) with its default
        // tileToAttackFrom = defender.getTile(): no attack-from tile, so no across-river or landing penalty -
        // what our resolving preview computes. The unit itself stays where it is (its great general, its terrain).
        let expected = ours.reduce(0) { $0 + (combatPreview(attacker: $1, targetTile: city.coord, resolving: true)?.damageToDefender ?? 0) }
        let healing = 20
        return expected < city.health && (expected <= healing || city.health / max(1, expected - healing) > 5)
    }
    private func headToLandingGrounds(_ unitId: Int, _ cityTile: HexCoord) -> Bool {
        guard let unit = unit(unitId) else { return false }
        let candidates = map.tilesWithin(cityTile, radius: maxDistanceForLanding).filter { c in c.distance(to: cityTile) >= minDistanceForLanding && map[c]?.isLand == true && damageFromTerrain(unit, at: c) <= 0 }
            .enumerated().sorted { ($0.element.distance(to: unit.coord), $0.offset) < ($1.element.distance(to: unit.coord), $1.offset) }.map { $0.element }   // Unciv sortedBy, stable over the ring order
        if let t = candidates.first(where: { ($0 == unit.coord || canUnitEnter(unit, $0)) && canReach(unit, $0) }) { moveUnit(unitId, toward: t) }
        return true
    }
    private func headTowardsEnemyCityLongRange(_ unitId: Int, _ cityTile: HexCoord, _ range: Int) -> Bool {
        guard let unit = unit(unitId) else { return false }
        if unit.coord.distance(to: cityTile) <= range { return true }
        let bombard = Set(map.tilesWithin(cityTile, radius: 2))
        let dist = distanceToTiles(unit)
        // Unciv `sortedWith(compareBy({ aerialDistance }, { totalMovement }))` over getDistanceToTiles: a STABLE
        // sort, so tiles equal on both keep the order the movement search found them in. Swift's sort is not
        // stable, and equal distance at equal cost is the usual case on open ground.
        let candidates = ([unit.coord] + reachableTilesInOrder(unit)).filter { $0.distance(to: cityTile) >= range && !bombard.contains($0) && damageFromTerrain(unit, at: $0) <= 0 && canMoveTo(unit, $0) }
            .enumerated().sorted { a, b in
                let da = a.element.distance(to: cityTile), db = b.element.distance(to: cityTile)
                if da != db { return da < db }
                let ma = Float(dist[a.element] ?? 0), mb = Float(dist[b.element] ?? 0)
                return ma != mb ? ma < mb : a.offset < b.offset
            }.map { $0.element }
        if let t = candidates.first { moveUnit(unitId, toward: t); return true }
        return false
    }
}
