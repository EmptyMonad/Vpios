// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/map/mapunit/UnitTurnManager.kt`: what happens to a unit when it arrives somewhere, and at the turn boundary.
extension GameState {
    /// Unciv MapUnit.moveThroughTile, after the entering-tile triggers and in its order: clearEncampment, the
    /// ancient ruins, the capture of an unguarded enemy civilian, the promotions adjacent terrain grants. The last
    /// step, updateVisibleTiles, is `revealFromCurrentTile` + the natural wonders, called by moveThroughTile.
    func onUnitArrived(unitId: Int) {
        guard let i = unitIndex(unitId) else { return }
        let unit = units[i]
        guard let civ = civ(unit.civId), let tile = map[unit.coord] else { return }
        // clearEncampment must run first (any unit of a non-barbarian civ)
        if !civ.isBarbarian && tile.hasBarbarianCamp { clearEncampment(unitId: unitId, at: unit.coord) }
        // Unciv: `if (civ.isMajorCiv() && improvement?.isAncientRuinsEquivalent() == true) getAncientRuinBonus(tile)`
        if civ.isMajor && tile.hasRuins {
            map[unit.coord]?.improvement = nil
            exploreRuins(unitId: unitId)
        }
        // Capture an enemy civilian without a military unit guarding it
        if unit.isMilitary, let cu = self.unit(unitId) {
            let here = units(at: cu.coord)
            if !here.contains(where: { $0.isMilitary && !$0.def.isAir && $0.id != unitId }), let victim = here.first(where: { $0.isCivilian && $0.civId != cu.civId }), areAtWar(cu.civId, victim.civId) {
                captureCivilianUnit(.unit(unitId), .unit(victim.id))
            }
        }
        grantTerrainPromotions(unitId: unitId)
    }

    /// Unciv MapUnit.moveThroughTile: `tile.neighbors.flatMap { it.allTerrains }` with TerrainGrantsPromotion, each
    /// added as a free promotion to a unit that matches the filter - barbarians included, the unit's own tile not.
    func grantTerrainPromotions(unitId: Int) {
        guard let u = unit(unitId) else { return }
        for n in map.neighbors(of: u.coord) {
            guard let t = map[n] else { continue }
            let allTerrains = [t.baseTerrain] + (t.naturalWonder.map { [$0] } ?? []) + t.features   // Unciv Tile.allTerrains
            for name in allTerrains {
                for pu in rs.terrains[name]?.uniqueObjects ?? [] where pu.pattern == "Grants [] ([]) to adjacent [] units for the rest of the game" {
                    guard let now = self.unit(unitId), unitMatches(now, pu.param(2)) else { continue }
                    addPromotion(unitId: unitId, pu.param(0), isFree: true)
                }
            }
        }
    }

    /// Unciv MapUnit.clearEncampment: the city-state quests first (before the improvement goes), then the camp is
    /// removed and the gold - a Float: the difficulty's reward, the German recruit bonus, × game speed, × the
    /// Songhai multipliers - is added truncated.
    func clearEncampment(unitId: Int, at c: HexCoord) {
        guard let unit = unit(unitId) else { return }
        onCampCleared(at: c, by: unit.civId)
        map[c]?.improvement = nil
        for cs in cityStates { handleObsoleteQuests(cityState: cs.id) }   // Unciv clearEncampment → tile.removeImprovement() → handleObsoleteGlobalQuests
        var goldGained = Float(difficulty(for: unit.civId).clearBarbarianCampReward)
        goldGained += Float(recruitFromEncampment(civId: unit.civId, at: c))
        goldGained *= Float(speed.goldCostModifier)
        let ctx = UniqueContext(civId: unit.civId, unit: unit, tile: map[c])
        for u in civUniques(unit.civId) where (u.pattern == "Receive []% Gold from Barbarian encampments and pillaging Cities" || u.pattern == "Gain []% of the gold from encampments and cities" || u.pattern == "[]% Gold gained from encampments and cities") && conditionalsHold(u, ctx) {
            goldGained *= Float(100 + u.double(0)) / 100   // Unciv toPercent()
        }
        if let ci = civIndex(unit.civId) { civs[ci].gold += Double(Int(goldGained)); goldTrace(unit.civId, Double(Int(goldGained))) }   // Unciv addGold(goldGained.toInt())
        notify(unit.civId, "We have captured a barbarian encampment and recovered [\(Int(goldGained))] gold!", category: .War, icons: ["Gold"], coord: c)
    }

    /// Unciv RuinsManager.selectNextRuinsReward: weight-expanded lottery shuffled with a tile-position seed, skipping the last two rewards,
    /// trying candidates until one of their uniques actually had an effect.
    func exploreRuins(unitId: Int) {
        guard let unit = unit(unitId), let ci = civIndex(unit.civId) else { return }
        let ctx = UniqueContext(civId: unit.civId, unit: unit, tile: map[unit.coord])   // Unciv GameContext(civInfo, unit = unit, tile = unit.getTile())
        let last = civs[ci].lastRuinRewards
        let possible = rs.ruins.filter { r in
            !last.contains(r.name) && !r.excludedDifficulties.contains(settings.difficulty)
                && !r.uniqueObjects.contains { $0.pattern == "Unavailable" && conditionalsHold($0, ctx) }
                && r.uniqueObjects.filter { $0.pattern == "Only available" }.allSatisfy { conditionalsHold($0, ctx) }
        }
        var candidates: [RuinDef] = []
        for r in possible { for _ in 0..<r.weight { candidates.append(r) } }
        // Unciv RuinsManager: `Random(triggeringUnit.getTile().position.toVector2().hashCode())`
        // — Random(Int), libGDX Vector2 hash'i (HexCoord hash'i DEGIL)
        var rng = SeededRandom(kotlinSeed: uncivPositionVector2Hash(unit.coord))
        for pick in rng.shuffled(candidates) {
            let uniques = pick.uniqueObjects.filter { $0.pattern != "Unavailable" && $0.pattern != "Only available" && conditionalsHold($0, ctx) }
            // Unciv: `triggerUnique(unique, triggeringUnit, notification = possibleReward.notification, triggerNotificationText =
            // "from the ruins")` - a reward with an empty notification (the stash of gold) announces "{Gained [..]}{ }{from the ruins}"
            guard triggerUniques(uniques, civId: unit.civId, cityId: nil, unitId: unitId, notification: pick.notification, triggerText: "from the ruins") else { continue }
            // (the world screen's turn runs on a background thread: the sound is played on the main one, as Unciv's
            // SoundPlayer posts to the GL thread)
            if !isAIOrAutoPlaying(unit.civId), let snd = pick.uniqueObjects.first(where: { $0.pattern == "Play [] sound" }) {
                let name = snd.param(0)
                DispatchQueue.main.async { Audio.shared.play(name) }
            }
            civs[ci].lastRuinRewards = [last.count > 1 ? last[1] : "", pick.name]
            break
        }
    }
}

// MARK: - Unciv UnitTurnManager.startTurn / endTurn
extension GameState {
    /// Unciv MapUnit.getTriggeredUniques(trigger) + triggerUnique(unique, unit): the unit's OWN uniques only
    /// (tempUniquesMap: base unit, its type, promotions, statuses) - not the civ's.
    private func triggerUnitOwnUniques(_ unitId: Int, _ matches: (Unique) -> Bool) {
        guard let u = unit(unitId) else { return }
        let triggered = u.promotionUniques.filter { $0.conditionals.contains(where: matches) }.map { $0.withoutConditionals(where: matches) }
        guard !triggered.isEmpty else { return }
        triggerUniques(triggered, civId: u.civId, cityId: nil, unitId: unitId)
    }

    /// Unciv UnitTurnManager.startTurn, for one unit and in its order. TurnManager.startTurn runs it for every unit
    /// of the civ once the cities are done. We did it in three passes over all the units (movement and statuses,
    /// then the displaced units, then the sleepers), and woke the fully healed ones at the END of the previous turn,
    /// so a fortified-until-healed unit lost its fortification for the enemy turns in between.
    func unitStartTurn(_ unitId: Int) {
        // clearPathfindingCache BEFORE the movement comes back: the cache remembers last turn's leftover movement,
        // so it stays valid only for a unit that did not move at all last turn, until it next moves.
        clearPathfindingCache(unitId)
        guard let i = unitIndex(unitId) else { return }
        units[i].movementLeft = maxMovement(of: units[i])
        units[i].attacksThisTurn = 0
        units[i].due = true
        // Epochs' own per-turn counter, reset where Unciv resets attacksThisTurn
        units[i].actedThisTurn = false

        triggerUnitOwnUniques(unitId) { $0.pattern == "upon turn start" }

        // Wake sleeping units if there's an enemy in vision range:
        // Military units always but civilians only if not protected.
        if let u = unit(unitId), isSleeping(u),
           u.isMilitary || (!units(at: u.coord).contains { $0.isMilitary && !$0.def.isAir } && city(at: u.coord) == nil) {
            let viewable = visibleTiles(for: u.civId)   // Unciv unit.civ.viewableTiles
            // Unciv: it.militaryUnit - air units live in tile.airUnits, so they do not wake anybody
            let enemyNear = map.tilesWithin(u.coord, radius: 3).contains { c in
                viewable.contains(c) && units(at: c).contains { $0.isMilitary && !$0.def.isAir && areAtWar(u.civId, $0.civId) }
            }
            if enemyNear, let k = unitIndex(unitId) { units[k].order = .none }
        }

        if let u = unit(unitId), u.order != .none, u.health > 99, isActionUntilHealed(u), let k = unitIndex(unitId) {
            units[k].order = .none   // wake up when healed
            // Unciv: "[${unit.shortDisplayName()}] has fully healed", so "[[Warrior]] has fully healed" (UnitTurnManager.kt:157)
            notify(u.civId, "[\(u.shortDisplayName)] has fully healed", category: .Units, icons: [u.name], actions: [.unit(u.coord, u.id)])
        }

        // if an enemy city expanded onto this tile while I was in it
        if let u = unit(unitId), let owner = map[u.coord]?.ownerCivId, owner != u.civId,
           !u.promotionUniques.contains(where: { $0.pattern.hasPrefix("May enter foreign tiles without open borders") }),   // cache.canEnterForeignTerrain
           !canPassThroughTiles(u.civId, owner), civ(owner)?.isCityState == false {
            teleportToClosestMoveableTile(unitId)
        }

        guard let j = unitIndex(unitId) else { return }
        units[j].addMovementMemory()
        units[j].attacksSinceTurnStart.removeAll()   // Unciv UnitTurnManager.startTurn: `unit.attacksSinceTurnStart.clear()`, right after addMovementMemory
        // Unciv: `for (status in statusMap.values.toList()) { turnsLeft--; if (turnsLeft <= 0) removeStatus(name) }` -
        // removeStatus fires the "upon losing the [] status" triggers.
        for name in units[j].statuses.keys.sorted() {
            guard let k = unitIndex(unitId), let left = units[k].statuses[name] else { continue }
            units[k].statuses[name] = left - 1
            if left - 1 <= 0 { removeStatus(unitId: unitId, name) }
        }
        updateUnitUniquesCache(unitId)   // Unciv startTurn ends in `unit.updateUniques()`
    }

    /// Unciv UnitTurnManager.endTurn, for one unit and in its order: the worker's turn, fortification, healing,
    /// the religious strength lost abroad, citadel damage, terrain damage, the movement memory and the
    /// end-of-turn-in-tile triggers. We ran the citadels and the terrain as passes of their own after every unit had
    /// healed, and removed the units they killed without the upkeep and resources Unciv's destroy() recounts.
    func unitEndTurn(_ unitId: Int) {
        clearPathfindingCache(unitId)
        triggerUnitOwnUniques(unitId) { $0.pattern == "upon turn end" }

        // `if (unit.hasMovement() && tile.improvementInProgress != null && unit.canBuildImprovement(...)) tile.doWorkerTurn(unit)`
        doWorkerTurn(unitId: unitId)

        guard let i = unitIndex(unitId) else { return }
        let u = units[i]
        let moved = hasUnitMovedThisTurn(u)
        if !moved && (isFortified(u) || (isGuarding(u) && canFortify(u))) && u.turnsFortified < 2 { units[i].turnsFortified += 1 }
        if !isFortified(u) && !isGuarding(u) { units[i].turnsFortified = 0 }

        // `(!hasUnitMovedThisTurn() && attacksThisTurn == 0) || HealsEvenAfterAction` - attacksThisTurn counts the
        // interceptions too
        if (!moved && u.attacksThisTurn == 0) || u.promotionUniques.contains(where: { $0.pattern == "Unit will heal every turn, even if it performs an action" }) {
            let amountToHealBy = healAmountForCurrentTile(u)
            if amountToHealBy != 0 { healBy(unitId: unitId, amountToHealBy) }
        }

        // Religious units in the land of a major civ they may not pass through
        if let u = unit(unitId), u.def.isReligious, let owner = map[u.coord]?.ownerCivId, civ(owner)?.isCityState == false, !canPassThroughTiles(u.civId, owner) {
            let ctx = UniqueContext(civId: u.civId, unit: u, tile: map[u.coord])
            let lost = u.promotionUniques.filter { $0.pattern == "May enter foreign tiles without open borders, but loses [] religious strength each turn it ends there" && conditionalsHold($0, ctx) }.map { $0.int(0) }.min()
            if let lost, let k = unitIndex(unitId) { units[k].religiousStrengthLost += lost }
            if let k = unitIndex(unitId), units[k].religiousStrengthLost >= u.def.religiousStrength {
                notify(u.civId, "Your [\(u.name)] lost its faith after spending too long inside enemy territory!", category: .Units, icons: [u.name], coord: u.coord)
                destroyUnit(unitId)
                return
            }
        }

        doCitadelDamage(unitId)
        guard unit(unitId) != nil else { return }
        doTerrainDamage(unitId)
        guard let j = unitIndex(unitId) else { return }

        units[j].addMovementMemory()

        if let now = unit(unitId), let t = map[now.coord] {
            triggerUnitOwnUniques(unitId) { $0.pattern == "upon ending a turn in a [] tile" && self.tileMatches(t, $0.param(0), civId: now.civId) }
        }
    }

    /// Unciv UnitTurnManager.doCitadelDamage: of the neighbours owned by a civ we are at war with and carrying an
    /// unpillaged improvement, the one whose "Adjacent enemy units ending their turn take [] damage" sum is the
    /// largest (the first such) - damage does not stack between citadels.
    private func doCitadelDamage(_ unitId: Int) {
        guard let u = unit(unitId) else { return }
        var best: (coord: HexCoord, damage: Int)? = nil
        for n in map.neighbors(of: u.coord) {
            guard let t = map[n], let owner = t.ownerCivId, let imp = t.improvement, !t.pillaged, areAtWar(u.civId, owner) else { continue }
            let ctx = UniqueContext(civId: owner, tile: t)   // tile.stateThisTile
            let damage = (rs.improvements[imp]?.uniqueObjects ?? []).filter { $0.pattern == "Adjacent enemy units ending their turn take [] damage" && conditionalsHold($0, ctx) }.reduce(0) { $0 + $1.int(0) }
            if best == nil || damage > best!.damage { best = (n, damage) }   // maxByOrNull keeps the first maximum
        }
        guard let (citadelTile, damage) = best, damage != 0 else { return }
        let improvementName = map[citadelTile]?.improvement ?? ""
        let acts: [NotificationAction] = [.location(citadelTile), .location(u.coord)]
        takeDamage(unitId: unitId, damage)
        if unit(unitId) == nil {
            notify(u.civId, "An enemy [\(improvementName)] has destroyed our [\(u.name)]", category: .War, icons: [improvementName, "Death", u.name], actions: acts)
            if let owner = map[citadelTile]?.ownerCivId { notify(owner, "Your [\(improvementName)] has destroyed an enemy [\(u.name)]", category: .War, icons: [improvementName, "Death", u.name], actions: acts) }
        } else {
            notify(u.civId, "An enemy [\(improvementName)] has attacked our [\(u.name)]", category: .War, icons: [improvementName, "War", u.name], actions: acts)
        }
    }

    /// Unciv UnitTurnManager.doTerrainDamage: getDamageFromTerrain() of the tile the unit ends its turn on.
    private func doTerrainDamage(_ unitId: Int) {
        guard let u = unit(unitId) else { return }
        let tileDamage = damageFromTerrain(u, at: u.coord)
        if tileDamage == 0 { return }
        takeDamage(unitId: unitId, tileDamage)
        if unit(unitId) == nil {
            notify(u.civId, "Our [\(u.name)] took [\(tileDamage)] tile damage and was destroyed", category: .Units, icons: [u.name, "Death"], coord: u.coord)
        } else {
            notify(u.civId, "Our [\(u.name)] took [\(tileDamage)] tile damage", category: .Units, icons: [u.name], actions: [.unit(u.coord, u.id)])
        }
    }
}

// MARK: - Unciv MapUnit.setStatus / removeStatus (temporary promotions)
extension GameState {

    /// Statuses do not stack: reapplying keeps the higher remaining duration. "upon gaining the [status] status" triggers fire on a fresh gain.
    func setStatus(unitId: Int, _ name: String, turns: Int) {
        guard let i = unitIndex(unitId), rs.promotions[name] != nil else { return }
        let fresh = units[i].statuses[name] == nil
        units[i].statuses[name] = max(units[i].statuses[name] ?? 0, turns)
        guard fresh else { return }   // Unciv: an existing status only has its turns raised - no updateUniques, no trigger
        updateUnitUniquesCache(unitId)   // Unciv setStatus: updateUniques, then the triggers
        if let unit = unit(unitId) { triggerUnitConditionalUniques(unit: unit) { $0.pattern == "upon gaining the [] status" && $0.param(0) == name } }   // Unciv MapUnit.setStatus: the unit's own triggered uniques
    }

    func removeStatus(unitId: Int, _ name: String) {
        guard let i = unitIndex(unitId), units[i].statuses[name] != nil else { return }
        units[i].statuses[name] = nil
        updateUnitUniquesCache(unitId)   // Unciv removeStatus: updateUniques, then the triggers
        guard let u = unit(unitId) else { return }
        triggerUnitConditionalUniques(unit: u) { $0.pattern == "upon losing the [] status" && $0.param(0) == name }   // Unciv MapUnit.removeStatus
    }
}

// MARK: - Unciv PromotionPickerScreen "Use default promotions"
extension GameState {
}
