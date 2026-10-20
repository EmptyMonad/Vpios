// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's unit/BattleHelper.kt.

extension GameState {
    /// Damage previews for the AI. Unciv builds these from MapUnitCombatant(unit), which stands on the unit's
    /// own tile - putting the probe on the defender's tile instead lost an embarked unit's landing penalty and
    /// measured the Great General aura from the wrong hex, so the AI picked different targets to Unciv's.
    func damageToDefender(_ unit: Unit, from: HexCoord, target: HexCoord) -> Int {
        var probe = unit; probe.coord = from
        return combatPreview(attacker: probe, targetTile: target)?.damageToDefender ?? 0
    }
    func damageToAttacker(_ unit: Unit, from: HexCoord, target: HexCoord) -> Int {
        var probe = unit; probe.coord = from
        return combatPreview(attacker: probe, targetTile: target)?.damageToAttacker ?? 0
    }
    // MARK: - BattleHelper

    /// Unciv BattleHelper.tryAttackNearbyEnemy: returns true if the unit cannot further move this turn.
    func tryAttackNearbyEnemy(_ unitId: Int, stayOnTile: Bool = false) -> Bool {
        // Unciv `unit.hasUnique(UniqueType.CannotAttack)`: the unit's uniques, promotions included, conditionals applied
        guard let unit = unit(unitId), !unitHasUnique(unit, "Cannot attack") else { return false }
        // Cheap pre-check: no enemy anywhere within reach + range means no attack scan (and no movement Dijkstra) is needed.
        // Conservative bound (railroads cost 0.1 per tile) so the pre-check never skips an enemy Unciv would find.
        // Unciv still ends in `return !unit.hasMovement()` when there is nothing to attack - a unit without
        // movement answers true - so the shortcut has to answer the same, not false.
        // The movement is any Float the console's `unit setmovement` takes (Unciv ConsoleUnitCommands: `movement < 0f`
        // refuses neither 1e39, an infinity, nor NaN) and AutoPlay Military Once automates a unit without asking
        // hasMovement: Kotlin's toInt (NaN 0, clamped to Int32) where Swift's Int() stopped the app. Unciv has no such
        // shortcut; an infinite reach scans everything, as it does, and a NaN one ends in `!hasMovement` as its empty
        // getDistanceToTiles does.
        let reach = (stayOnTile || unit.def.isAir ? 0 : GameState.kotlinToInt((unit.movementLeft * 10).rounded(.up))) + attackRange(unit) + 1
        guard anyEnemyWithin(unit.coord, civId: unit.civId, dist: reach) else { return !unit.hasMovement }
        let dist = distanceToTiles(unit)
        let selfDestructs = unitHasUnique(unit, "Self-destructs when attacking")
        let attackable = attackableEnemies(unit, distanceToTiles: dist, stayOnTile: stayOnTile).filter { a in
            selfDestructs || (damageToAttacker(unit, from: unit.coord, target: a.tileToAttack) < unit.health && damageFromTerrain(unit, at: a.tileToAttackFrom) <= 0)
        }
        if epochsDebug, epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)" {
            let u0 = uncivPosition(unit.coord)
            let all = attackableEnemies(unit, distanceToTiles: dist, stayOnTile: stayOnTile).map { a -> String in
                let ta = uncivPosition(a.tileToAttack), fr = uncivPosition(a.tileToAttackFrom)
                let v = city(at: a.tileToAttack).map { cityAttackValue(unit, $0) } ?? unitAttackValue(unit, a)
                let there = units(at: a.tileToAttack).filter { $0.civId != unit.civId }
                let mil = there.first(where: { $0.isMilitary })
                let dmg = damageToDefender(unit, from: unit.coord, target: a.tileToAttack)
                return "\(ta.x),\(ta.y)<-\(fr.x),\(fr.y)v\(v)[def=\(mil?.name ?? there.first?.name ?? "-")hp\(mil?.health ?? there.first?.health ?? 0)dmg\(Int(dmg))mv\(a.movementLeftAfterMovingToAttackTile)]"
            }
            print("ATKE t=\(turn) \(unit.name)@\(u0.x),\(u0.y) hp=\(unit.health) all=[\(all.joined(separator: " "))] kept=\(attackable.count)")
        }
        if let target = chooseAttackTarget(unit, attackable) {
            // Unciv `tileToAttack.militaryUnit == null && isRanged() && canMoveTo(tile) && distanceToTiles.containsKey(tile)`
            if militaryUnitOn(target.tileToAttack) == nil && unit.def.isRanged && canMoveTo(unit, target.tileToAttack) && dist[target.tileToAttack] != nil {
                moveToTile(unitId, target.tileToAttack)     // ranged units capture civilians by walking in (Unciv moveToTile)
            } else { moveAndAttack(unitId, target) }
        }
        return !(self.unit(unitId)?.hasMovement ?? false)
    }
    /// Unciv BattleHelper.tryDisembarkUnitToAttackPosition
    func tryDisembarkUnitToAttackPosition(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId), unit.def.isMelee, unit.def.isLand, isEmbarked(unit) else { return false }
        let dist = distanceToTiles(unit)
        let candidates = attackableEnemies(unit, distanceToTiles: dist).filter { a in
            damageToAttacker(unit, from: unit.coord, target: a.tileToAttack) < unit.health && map[a.tileToAttackFrom]?.isLand == true
        }
        if let target = chooseAttackTarget(unit, candidates) { moveToTile(unitId, target.tileToAttackFrom); return true }   // Unciv moveToTile
        return false
    }
    /// Unciv BattleHelper.chooseAttackTarget
    func chooseAttackTarget(_ unit: Unit, _ attackable: [AttackableTile]) -> AttackableTile? {
        var highest = 0, best: AttackableTile? = nil
        for a in attackable {
            let v = city(at: a.tileToAttack).map { cityAttackValue(unit, $0) } ?? unitAttackValue(unit, a)
            if v > highest { highest = v; best = a }
        }
        return highest > 30 ? best : nil
    }
    /// Unciv BattleHelper.getCityAttackValue
    func cityAttackValue(_ attacker: Unit, _ city: City) -> Int {
        let canCapture = attacker.def.isMelee && !unitHasUnique(attacker, "Cannot capture cities")
        if city.health == 1 { return canCapture ? 10000 : 0 }
        let dmg = max(1, damageToDefender(attacker, from: attacker.coord, target: city.coord))   // Unciv MapUnitCombatant: the attacker stands where it is
        if canCapture && city.health <= dmg { return 10000 }
        if attacker.def.isMelee {
            let battleDamage = damageToAttacker(attacker, from: attacker.coord, target: city.coord)
            if attacker.health - battleDamage * 2 <= 0 && !unitHasUnique(attacker, "Self-destructs when attacking") {
                // Unciv `it.militaryUnit?.civ == attacker.civ` within 3 - the tile's military unit, aircraft aside
                let friendly = map.tilesWithin(city.coord, radius: 3).filter { militaryUnitOn($0)?.civId == attacker.civId }.count
                if friendly < 5 {
                    // Unciv `1.0 + 1.0 / friendlyUnitsAroundCity` - a Double division, so with nobody around it is
                    // infinite and any damage at all says "we'll probably die". Ours floored the count at 1.
                    let mod = 1.0 + 1.0 / Double(friendly)
                    if Double(attacker.health) - Double(battleDamage) * mod <= 0 { return 0 }
                }
            }
        }
        var value = 100
        if attacker.def.isProbablySiegeUnit { value += 100 } else if attacker.def.isRanged { value += 10 }
        value -= (city.health - 60) / 2
        for c in map.tilesWithin(city.coord, radius: 2) {
            guard let m = militaryUnitOn(c) else { continue }   // Unciv `it.militaryUnit`
            if areAtWar(m.civId, attacker.civId) { value -= 5 }
            if areAtWar(m.civId, city.civId) { value += 15 }
        }
        return value
    }
    /// Unciv BattleHelper.getUnitAttackValue
    func unitAttackValue(_ attacker: Unit, _ a: AttackableTile) -> Int {
        var value = Int.min
        // Unciv `attackTile.tileToAttack.militaryUnit` / `.civilianUnit`: the tile's own slots (aircraft aside)
        if let mil = militaryUnitOn(a.tileToAttack) {
            value = 200 - mil.health + damageToDefender(attacker, from: attacker.coord, target: a.tileToAttack)
        } else if let civ = civilianUnitOn(a.tileToAttack) {
            value = 50
            // Unciv `attacker.movement.canReachInCurrentTurn(tileToAttack)`
            if attacker.def.isMelee || canReachInCurrentTurn(attacker, a.tileToAttack) {
                if civ.isGreatPerson { value += 150 }
                // Unciv `hasUnique(UniqueType.FoundCity, GameContext.IgnoreConditionals)`
                if civ.promotionUniques.contains(where: { $0.pattern == "Founds a new city" }) { value += 60 }
            } else if attacker.def.isRanged && !unitHasUnique(civ, "Uncapturable") { return 10 }
        }
        if value == Int.min { return value }
        // Unciv `attackValue += (movementLeftAfterMovingToAttackTile * 5).toInt()` - a Float product, truncated: 1.4f * 5
        // is 7 in Float and 6.99999988 in Double - Kotlin's toInt (an infinite movement is Int.MAX_VALUE) and a 32-bit
        // Int sum, which wraps that to a negative value
        value = Int(Int32(truncatingIfNeeded: value + GameState.kotlinToInt(Double(Float(a.movementLeftAfterMovingToAttackTile) * 5))))
        return value
    }
}
