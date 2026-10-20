// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/Nuke.kt`: firing a nuclear weapon and what it leaves behind.
extension GameState {
    /// Unciv Nuke.mayUseNuke: not the launch tile, must be explored and in range, and every civ that would be hit must be
    /// attackable - DiplomacyManager.canAttack, `turnsToPeaceTreaty() == 0` in the attacker's own copy of the trades.
    func mayUseNuke(_ nuke: Unit, target: HexCoord) -> Bool {
        guard nuke.coord != target, civ(nuke.civId)?.explored.contains(target) == true, nuke.coord.distance(to: target) <= airRange(nuke) else { return false }
        let radius = nukeBlastRadius(nuke)
        func attackable(_ other: Int?) -> Bool {
            guard let other, other != nuke.civId, let c = civ(other), c.isAlive, !isDefeated(c), !c.isBarbarian else { return true }
            if civ(nuke.civId)?.metCivs.contains(other) != true { return false }
            return turnsToPeaceTreaty(nuke.civId, other) == 0
        }
        for c in map.tilesWithin(target, radius: radius) {
            if !attackable(map[c]?.ownerCivId) { return false }
            if let combatant = getMapCombatantOfTile(c), !attackable(cCivId(combatant)) { return false }
        }
        return true
    }

    /// Unciv MapUnit.getNukeBlastRadius: "Blast radius [n]", else 2
    func nukeBlastRadius(_ nuke: Unit) -> Int { nuke.promotionUniques.first { $0.pattern == "Blast radius []" }?.int(0) ?? nuclearBlastRadiusDefault }

    /// Unciv Nuke.NUKE: war on everyone hit (and interception by their units), the notifications, the explosion
    /// tile by tile, self-destruction, the diplomatic penalty with every known civ.
    func detonate(unitId: Int, at target: HexCoord, strength nukeStrength: Int) -> String {
        guard let ai = unitIndex(unitId), mayUseNuke(units[ai], target: target) else { return "" }
        battleGraveyard = [:]
        let attacker: Combatant = .unit(unitId)
        let nuke = units[ai]
        let attackingCiv = nuke.civId
        let attackerName = nuke.name
        let hitTiles = map.tilesWithin(target, radius: nukeBlastRadius(nuke))

        // declareWarOnHitCivs
        var notifyDeclaredWarCivs: [Int] = []
        func tryDeclareWar(_ civSuffered: Int) {
            guard civSuffered != attackingCiv, civ(civSuffered)?.metCivs.contains(attackingCiv) == true, !areAtWar(attackingCiv, civSuffered) else { return }
            declareWar(attackingCiv, on: civSuffered)
            if !notifyDeclaredWarCivs.contains(civSuffered) { notifyDeclaredWarCivs.append(civSuffered) }
        }
        var hitCivsTerritory: [Int] = []
        for owner in hitTiles.compactMap({ map[$0]?.ownerCivId }) where !hitCivsTerritory.contains(owner) {
            hitCivsTerritory.append(owner)
            tryDeclareWar(owner)
        }
        // Declare war on all potentially hit units. They'll try to intercept the nuke before it drops
        var unitCivs: [Int] = []
        for c in hitTiles { for u in units(at: c) where !unitCivs.contains(u.civId) { unitCivs.append(u.civId) } }
        for civWhoseUnitWasAttacked in unitCivs where civWhoseUnitWasAttacked != attackingCiv {
            tryDeclareWar(civWhoseUnitWasAttacked)
            if nuke.def.isAir && !cIsDefeated(attacker) {
                _ = tryInterceptAirAttack(attacker, attackedTile: target, interceptingCiv: civWhoseUnitWasAttacked, defender: nil)
            }
        }

        // addNukeNotifications: if the nuke has been intercepted and destroyed then it fails to detonate. Every one of
        // its notifications carries `nukeNotificationAction = sequenceOf(LocationAction(targetTile.position),
        // CivilopediaAction("Units/" + attacker.getName()))`
        let attackerNation = civ(attackingCiv)?.nation ?? "?"
        // Unciv `nukeNotificationAction = sequenceOf(LocationAction(targetTile.position), CivilopediaAction("Units/" +
        // attacker.getName()))` on every one of them (Nuke.kt:106); ours gave the location alone
        let nukeActions: [NotificationAction] = [.location(target), .civilopedia("Units/\(attackerName)")]
        if cIsDefeated(attacker) {
            for d in notifyDeclaredWarCivs { notify(attackingCiv, "After an attempted attack by our [\(attackerName)], [\(civ(d)?.nation ?? "?")] has declared war on us!", category: .Diplomacy, icons: [civ(d)?.nation ?? "", "War", attackerName], actions: nukeActions, coord: target) }
            return "\(attackerName) intercepted."
        }
        for d in notifyDeclaredWarCivs { notify(attackingCiv, "After being hit by our [\(attackerName)], [\(civ(d)?.nation ?? "?")] has declared war on us!", category: .Diplomacy, icons: [civ(d)?.nation ?? "", "War", attackerName], actions: nukeActions, coord: target) }
        for other in civs where other.isAlive && other.id != attackingCiv {
            if hitCivsTerritory.contains(other.id) { notify(other.id, "A(n) [\(attackerName)] from [\(attackerNation)] has exploded in our territory!", category: .War, icons: [attackerNation, "War", attackerName], actions: nukeActions, coord: target) }
            else if other.metCivs.contains(attackingCiv) { notify(other.id, "A(n) [\(attackerName)] has been detonated by [\(attackerNation)]!", category: .War, icons: [attackerNation, "War", attackerName], actions: nukeActions, coord: target) }
            else { notify(other.id, "A(n) [\(attackerName)] has been detonated by [an unknown civilization]!", category: .War, icons: ["War", attackerName], actions: nukeActions, coord: target) }
        }
        // Unciv Nuke.NUKE: `attacker.unit.attacksSinceTurnStart.add(targetTile.position)` once the nuke got through,
        // before the explosions (movement-arrow overlay)
        if let ni = unitIndex(unitId) { units[ni].attacksSinceTurnStart.append(target) }

        for c in hitTiles { doNukeExplosionForTile(attacker, c, nukeStrength: nukeStrength, isGroundZero: c == target) }

        // Instead of postBattleAction() just destroy the unit, all other functions are not relevant
        if let live = unit(unitId), unitHasUnique(live, "Self-destructs when attacking") { destroyUnit(unitId) }
        // a penalty with every known civ
        for known in knownCivs(attackingCiv) { setModifier(known.id, attackingCiv, .UsedNuclearWeapons, -50) }
        if !cIsDefeated(attacker), let i = unitIndex(unitId) { units[i].attacksThisTurn += 1 }   // the movement is not spent
        return "Nuclear detonation at the target."
    }

    /// Unciv Nuke.doNukeExplosionForTile: the city (damaged or destroyed), each unit on the tile, then - away from a
    /// city centre - features, improvements, roads and fallout.
    private func doNukeExplosionForTile(_ attacker: Combatant, _ c: HexCoord, nukeStrength: Int, isGroundZero: Bool) {
        guard let nuke = cUnit(attacker) else { return }
        var damageModifierFromMissingResource: Float = 1
        if civ(nuke.civId)?.isBarbarian == false {
            let civResources = resourceCounts(nuke.civId)
            let needs = resourceRequirementsPerTurn(requiredResource: nuke.def.requiredResource, uniques: nuke.def.uniqueObjects, ctx: UniqueContext(civId: nuke.civId, unit: nuke))
            for r in needs.keys where (civResources[r] ?? 0) < 0 { damageModifierFromMissingResource *= 0.5 }
        }
        var buildingModifier: Float = 1   // a bunker mitigates damage to the garrison, even if the city is destroyed
        if let city = city(at: c) {
            buildingModifier = cityAggregateModifier(city, "Damage to garrison from nuclear attacks []% []")
            doNukeExplosionDamageToCity(city, nukeStrength: nukeStrength, damageModifierFromMissingResource: damageModifierFromMissingResource, attacker: attacker)
            let defenderCity: Combatant = .city(city.id)
            postBattleNotifications(attacker, defenderCity, attackedTile: city.coord)
            destroyIfDefeated(cCivId(defenderCity), attacker: nuke.civId, at: city.coord)
        }
        // Damage and/or destroy units on the tile
        for u in units(at: c) {
            let defender: Combatant = .unit(u.id)
            // GameContext(attacker.civ, ourCombatant = attacker, theirCombatant = defender, tile = tile)
            var ctx = combatContext(attacker, defender, attackedTile: nil, action: nil)
            ctx.tile = map[c]; ctx.opponentCivId = nil   // the primary constructor: otherCiv stays null (the combat constructor would set it)
            var rng = stateBasedRandom("Nuke.doNukeExplosionForTile", ctx)
            let base: Int
            if isGroundZero || nukeStrength >= 2 { base = 100 }
            else if nukeStrength == 1 { base = 30 + rng.nextInt(below: 40) + rng.nextInt(below: 40) }   // NUKE_UNIT_DAMAGE_BASE / RAND_1 / RAND_2
            else { base = 20 + rng.nextInt(below: 30) }   // Level 0 does not exist in Civ5
            let damage = Int(Float(base) * buildingModifier * damageModifierFromMissingResource + Float(1).ulp)
            if u.isCivilian {
                if u.health - damage <= 40 { destroyUnit(u.id) }   // Civ5: NUKE_NON_COMBAT_DEATH_THRESHOLD = 60
            } else {
                cTakeDamage(defender, damage)
            }
            postBattleNotifications(attacker, defender, attackedTile: cCoord(defender))
            destroyIfDefeated(cCivId(defender), attacker: nuke.civId)
        }
        // Pillage improvements, pillage roads, add fallout
        guard let t = map[c], !t.isCityCenter else { return }   // Never touch city centers - if they survived
        // tileContext = attacker.unit.cache.state.copy(tile = tile)
        var tileRng = stateBasedRandom("Nuke.doExplosionForTile", UniqueContext(civId: nuke.civId, unit: nuke, tile: map[c]))
        if t.terrainNames.contains(where: { rs.terrains[$0]?.uniqueObjects.contains(where: { $0.pattern == "[]% Chance to be destroyed by nukes" }) == true }) {
            // Unciv walks the feature list as it was (removeTerrainFeature replaces the list)
            for f in t.features {
                for u in rs.terrains[f]?.uniqueObjects ?? [] where u.pattern == "[]% Chance to be destroyed by nukes" {
                    let chance = Float(u.double(0)) / 100
                    if (chance > 0 && isGroundZero) || tileRng.nextFloat() < chance {
                        map.update(c) { $0.features.removeAll { $0 == f } }   // Tile.removeTerrainFeature
                        applyPillageAndFallout(c)
                    }
                }
            }
        } else if isGroundZero || tileRng.nextFloat() < 0.5 { applyPillageAndFallout(c) }   // Civ5 NUKE_FALLOUT_PROB
    }

    /// Unciv Nuke.applyPillageAndFallout: an unpillaged improvement that is not Irremovable is removed
    /// (Unpillagable) or pillaged through Tile.setPillaged, then an unpillaged road goes through setPillaged,
    /// then Fallout is added. We set the tile fields by hand, which skipped setPillaged's side effects: the
    /// cleared improvement queue and CreatesOneImprovement marker, a naval improvement destroyed, the owning
    /// city's deferred reassignment and resource recount, and removeImprovement's own refresh.
    private func applyPillageAndFallout(_ c: HexCoord) {
        guard let t = map[c] else { return }
        if let imp = t.improvement, !t.pillaged, let def = rs.improvements[imp], !def.uniques.contains("Irremovable") {
            if def.uniques.contains("Unpillagable") { removeImprovement(at: c) } else { setPillaged(at: c) }
        }
        if let t2 = map[c], (t2.roads || t2.railroad) && !t2.roadPillaged { setPillaged(at: c) }   // getUnpillagedRoad() != None
        guard let t3 = map[c], !(t3.isWater || t3.isImpassable || t3.features.contains("Fallout")) else { return }
        map.update(c) { $0.features.append("Fallout") }   // Tile.addTerrainFeature
    }

    /// Unciv Nuke.doNukeExplosionDamageToCity: strong nukes destroy small cities (never original capitals or holy
    /// cities), otherwise half the health and a strength-scaled share of the population.
    private func doNukeExplosionDamageToCity(_ city: City, nukeStrength: Int, damageModifierFromMissingResource: Float, attacker: Combatant) {
        if (nukeStrength > 2 || (nukeStrength > 1 && city.population < 5)) && canBeDestroyedForBattle(city, justCaptured: true) {
            destroyCity(cityId: city.id); return
        }
        let cityCombatant: Combatant = .city(city.id)
        // GameContext(attacker.civ, ourCombatant = attacker, theirCombatant = CityCombatant(city), tile = tile)
        var ctx = combatContext(attacker, cityCombatant, attackedTile: nil, action: nil)
        ctx.tile = map[city.coord]; ctx.opponentCivId = nil   // primary constructor: no otherCiv in the hash
        var rng = stateBasedRandom("Nuke.doNukeExplosionDamageToCity", ctx)
        cTakeDamage(cityCombatant, Int(Float(cHealth(cityCombatant)) * 0.5 * damageModifierFromMissingResource))
        // Civ5 rounds population loss down twice - before and after bomb shelters
        let share: Float
        switch nukeStrength {
        case 0: share = 0
        case 1: share = Float(30 + rng.nextInt(below: 20) + rng.nextInt(below: 20)) / 100
        case 2: share = Float(60 + rng.nextInt(below: 10) + rng.nextInt(below: 10)) / 100
        default: share = 1   // hypothetical nukeStrength 3 -> always to 1 pop
        }
        guard let ci = cityIndex(city.id) else { return }
        let populationLoss = Int(Float(cities[ci].population) * cityAggregateModifier(cities[ci], "Population loss from nuclear attacks []% []") * share)
        addPopulation(cityIndex: ci, -populationLoss)
    }

    /// Unciv City.getAggregateModifier: the product of every matching unique's percentage, as a Float
    private func cityAggregateModifier(_ city: City, _ pattern: String) -> Float {
        var modifier: Float = 1
        for u in cityUniquesCivFirst(city) where u.pattern == pattern && u.conditionals.isEmpty && cityMatchesFilter(u.param(1), city: city, viewer: city.civId) {
            modifier *= Float(Stats.toPercent(u.double(0)))
        }
        return modifier
    }
}
