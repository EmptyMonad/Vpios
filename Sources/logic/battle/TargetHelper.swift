// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/TargetHelper.kt`: what a unit may attack, and from how far.
extension GameState {
    /// Unciv MapUnit.getRange(): `if (baseUnit.isMelee()) return 1` and otherwise `baseUnit.range` plus any
    /// "[+n] Range". `isMelee()` is `!isRanged() && strength > 0`, so it does NOT cover a CIVILIAN - a Worker
    /// has strength 0, falls past that line, and answers with `BaseUnit.range`, whose Kotlin default is 2.
    /// We short-circuited on `isRanged` and answered 1 for civilians too. It only shows through the danger
    /// map: measured on t_45, Byzantium's worker at 1,4 has an enemy Worker at 0,1, and the ring it makes
    /// dangerous is `(movement - 1) + range` - 3 in Unciv, 2 in ours. Tile 2,4 sits in that one ring, so Unciv
    /// avoided it and built its farm on 2,5 while we built ours on 2,4.
    func attackRange(_ unit: Unit) -> Int {
        if !unit.def.isRanged && unit.def.strength > 0 { return 1 }   // Unciv BaseUnit.isMelee()
        // Unciv getMatchingUniques(UniqueType.Range, checkCivInfoUniques = true): the civ's "[+n] Range" count too
        return unit.def.range + unitMatchingUniques(unit, "[] Range", nil, checkCivInfoUniques: true).reduce(0) { $0 + $1.int(0) }
    }

    /// Unciv TargetHelper.containsAttackableEnemy for a unit: the tile's combatant (the city, else the military
    /// unit, else the civilian) belongs to a civ we are at war with, we may attack it from where we are, and -
    /// outside a city centre - we can see it.
    func containsAttackableEnemy(_ c: HexCoord, attacker: Unit) -> Bool {
        guard let t = map[c] else { return false }
        let combatant: Combatant = .probe(attacker)
        if isEmbarked(attacker) && !unitHasUnique(attacker, "May attack when embarked") {
            // Can't attack water units while embarked, only land
            if t.isWater || attacker.def.isRanged { return false }
        }
        guard let tileCombatant = getMapCombatantOfTile(c) else { return false }
        let theirCiv = cCivId(tileCombatant)
        if theirCiv == attacker.civId { return false }
        // Unciv: `if (tileCombatant is CityCombatant && tileCombatant.city.hasJustBeenConquered) return false`
        if case .city(let cc) = tileCombatant, city(cc)?.hasJustBeenConquered == true { return false }
        if !areAtWar(attacker.civId, theirCiv) { return false }
        if attacker.def.isLand && attacker.def.isMelee && t.isWater && !civHasEmbarkation(attacker.civId)
            && !unitHasUnique(attacker, "May travel on Water tiles without embarking") { return false }
        // GameContext(unit, tile, ourCombatant, theirCombatant, combatAction = Attack)
        var ctx = combatContext(combatant, tileCombatant, attackedTile: nil, action: "Attack")
        ctx.tile = t
        if attacker.def.cannotAttack || unitHasUnique(attacker, "Cannot attack", ctx) { return false }
        let onlyUnits = unitMatchingUniques(attacker, "Can only attack [] units", ctx)
        if !onlyUnits.isEmpty && !onlyUnits.contains(where: { cMatchesFilter(tileCombatant, $0.param(0)) }) { return false }
        let onlyTiles = unitMatchingUniques(attacker, "Can only attack [] tiles", ctx)
        if !onlyTiles.isEmpty && !onlyTiles.contains(where: { tileMatches(t, $0.param(0), civId: attacker.civId) }) { return false }
        // Only units with the right unique can see submarines (or other invisible units) from more than one tile away.
        // Garrisoned invisible units can be attacked by anyone, as else the city would be invincible.
        if !t.isCityCenter { return combatantIsVisible(tileCombatant, to: attacker.civId) }
        return true
    }

    /// Unciv MapUnit.isVisibleTo(civ): our own always; otherwise the tile must be visible and, for an invisible
    /// unit, detected.
    func combatantIsVisible(_ c: Combatant, to civId: Int) -> Bool {
        guard let u = cUnit(c) else { return true }   // CityCombatant.isVisibleTo: true
        if u.civId == civId { return true }
        if !visibleTiles(for: civId).contains(u.coord) { return false }
        if !u.def.isInvisible { return true }
        return canSeeInvisibleUnit(u, from: civId)
    }

    /// Unciv TargetHelper.getAttackableEnemies: from every tile the unit can reach this turn with movement to spare
    /// (only its own tile when it stays or flies), every tile in reach - the neighbours for a melee unit, the tiles
    /// in range for aircraft, nukes and indirect fire, what it can see otherwise - that holds an attackable enemy.
    /// `order` is the insertion order of the PathsToTilesWithinTurn `distanceToTiles` came from, when that is not
    /// this turn's own search (UnitAutomation.tryAdvanceTowardsCloseEnemy passes a three-turn one).
    func attackableEnemies(_ unit: Unit, distanceToTiles: [HexCoord: Double], tilesToCheck: [HexCoord]? = nil, stayOnTile: Bool = false, order: [HexCoord]? = nil) -> [AttackableTile] {
        let range = attackRange(unit)
        var out: [AttackableTile] = []
        let mustSetUp = unitHasUnique(unit, "Must set up to ranged attack")
        let isNuke = unitHasUnique(unit, "Nuclear weapon of Strength []")
        var tilesToAttackFrom: [(HexCoord, Double)]
        if stayOnTile || unit.def.isAir {
            tilesToAttackFrom = [(unit.coord, unit.movementLeft)]
        } else {
            // getTilesToAttackFromWhenUnitMoves: sorted by the movement spent (stable), less what setting up costs
            tilesToAttackFrom = []
            let discovery = Dictionary(uniqueKeysWithValues: (order ?? turnPaths(unit).order).enumerated().map { ($1, $0) })
            let sorted = distanceToTiles.sorted { $0.value != $1.value ? $0.value < $1.value : (discovery[$0.key] ?? Int.max) < (discovery[$1.key] ?? Int.max) }
            let hereLeft = Stats.f32(unit.movementLeft - ((mustSetUp && !unit.isSetUp) ? 1.0 : 0))
            if Float(hereLeft) > Float(GameState.minimumMovementEpsilon) { tilesToAttackFrom.append((unit.coord, hereLeft)) }
            for (tile, distance) in sorted where tile != unit.coord {
                let left = Stats.f32(Stats.f32(unit.movementLeft - distance) - (mustSetUp ? 1.0 : 0))
                if Float(left) > Float(GameState.minimumMovementEpsilon) && canMoveTo(unit, tile) { tilesToAttackFrom.append((tile, left)) }
            }
        }
        let maxDist = (tilesToAttackFrom.map { $0.0.distance(to: unit.coord) }.max() ?? 0) + range
        if !isNuke && !anyEnemyWithin(unit.coord, civId: unit.civId, dist: maxDist) { return [] }
        let visible = visibleTiles(for: unit.civId)
        let checkSet = tilesToCheck.map { Set($0) }
        var tilesWithEnemies: Set<HexCoord> = [], tilesWithout: Set<HexCoord> = []
        // an escorting melee unit only attacks from tiles its escorted unit can still reach this turn with movement to spare
        let escort = (unit.def.isMelee && isEscorting(unit)) ? otherEscortUnit(unit) : nil
        let escortReach = escort.map { self.distanceToTiles($0) } ?? [:]
        let indirectFire = unitHasUnique(unit, "Ranged attacks may be performed over obstacles", nil, checkCivInfoUniques: true)
        for (reachable, movementLeft) in tilesToAttackFrom {
            if let e = escort {
                let cost = reachable == e.coord ? 0 : escortReach[reachable]
                guard let c = cost, Stats.f32(e.movementLeft - c) > 0 else { continue }
            }
            // Nukes ignore line of sight when checking range, and don't require a visible enemy on the target tile
            let inRange: [HexCoord]
            if unit.def.isMelee { inRange = map.neighbors(of: reachable) }
            else if unit.def.isAir || isNuke || indirectFire { inRange = map.tilesWithin(reachable, radius: range) }
            else { inRange = viewableTilesList(from: reachable, radius: range, viewerBonus: 0, forAttack: true) }
            for c in inRange {
                // military units can technically enter tiles with enemy civilians; don't attack from the tile itself
                if c == reachable { continue }
                if isNuke {
                    if mayUseNuke(unit, target: c) { out.append(AttackableTile(tileToAttackFrom: reachable, tileToAttack: c, movementLeftAfterMovingToAttackTile: movementLeft)) }
                    continue
                }
                if tilesWithEnemies.contains(c) { out.append(AttackableTile(tileToAttackFrom: reachable, tileToAttack: c, movementLeftAfterMovingToAttackTile: movementLeft)); continue }
                if tilesWithout.contains(c) { continue }   // avoid checking the same empty tile multiple times
                if tileContainsAttackableEnemy(unit, c, inScope: checkSet?.contains(c) ?? visible.contains(c)) {
                    tilesWithEnemies.insert(c)
                    out.append(AttackableTile(tileToAttackFrom: reachable, tileToAttack: c, movementLeftAfterMovingToAttackTile: movementLeft))
                } else { tilesWithout.insert(c) }
            }
        }
        return out
    }

    /// Unciv TargetHelper.tileContainsAttackableEnemy: in scope, an attackable enemy, and - for a melee unit
    /// facing a lone civilian - a tile it can pass through.
    private func tileContainsAttackableEnemy(_ unit: Unit, _ c: HexCoord, inScope: Bool) -> Bool {
        guard inScope, containsAttackableEnemy(c, attacker: unit), let mapCombatant = getMapCombatantOfTile(c) else { return false }
        return !unit.def.isMelee || !mapCombatant.isMapUnitCombatant || !cIsCivilian(mapCombatant) || canPassThrough(unit, c)
    }

    /// Unciv TargetHelper.getBombardableTiles: visible tiles within the bombard range holding an attackable enemy
    func bombardableTiles(_ city: City) -> [HexCoord] {
        let vis = visibleTiles(for: city.civId)
        return map.tilesWithin(city.coord, radius: rs.constants.baseCityBombardRange).filter { c in
            vis.contains(c) && cityContainsAttackableEnemy(c, city: city)
        }
    }

    /// Unciv TargetHelper.containsAttackableEnemy for a CityCombatant
    private func cityContainsAttackableEnemy(_ c: HexCoord, city: City) -> Bool {
        guard let tileCombatant = getMapCombatantOfTile(c) else { return false }
        let theirCiv = cCivId(tileCombatant)
        if theirCiv == city.civId || !areAtWar(city.civId, theirCiv) { return false }
        if map[c]?.isCityCenter != true { return combatantIsVisible(tileCombatant, to: city.civId) }
        return true
    }
}
