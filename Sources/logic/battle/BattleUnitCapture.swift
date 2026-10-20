// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/BattleUnitCapture.kt`: prize ships, recruiting a defeated unit, and capturing a civilian.
extension GameState {
    /// Unciv BattleUnitCapture.tryCaptureMilitaryUnit: a defeated military unit may be taken as a prize or recruited.
    /// Both ways are tried (neither short-circuits the other), then one unit is placed.
    func tryCaptureMilitaryUnit(_ attacker: Combatant, _ defender: Combatant, attackedTile: HexCoord) -> Bool {
        guard defender.isMapUnitCombatant, attacker.isMapUnitCombatant, let du = cUnit(defender), let au = cUnit(attacker) else { return false }
        // GameContext(unit = defender.unit, ourCombatant = defender, theirCombatant = attacker, attackedTile)
        let ctx = UniqueContext(civId: du.civId, unit: du, attackedTile: map[attackedTile], opponentUnit: au, opponentCivId: nil)
        if unitHasUnique(du, "Uncapturable", ctx) { return false }
        if !cIsDefeated(defender) || du.isCivilian { return false }
        let prizeShip = unitCapturedPrizeShipsUnique(attacker, defender)
        let recruited = unitGainFromDefeatingUnit(attacker, defender)
        guard prizeShip || recruited else { return false }
        // The defeated defender has been destroyed and removed from its tile, but it still knows where it stood,
        // so the new unit is placed exactly where the defender was.
        return spawnCapturedUnit(defender, attacker)
    }

    /// Unciv BattleUnitCapture.unitCapturedPrizeShipsUnique: "May capture killed [filter] units" with chance
    /// min(0.8, 0.1 + attack / defence × 0.4) on the two sides' own strengths. The seed is
    /// `(turns * position.toVector2().hashCode()).toLong()` - an Int product widened afterwards, unlike getRandomness.
    private func unitCapturedPrizeShipsUnique(_ attacker: Combatant, _ defender: Combatant) -> Bool {
        guard let au = cUnit(attacker) else { return false }
        if !unitMatchingUniques(au, "May capture killed [] units").contains(where: { cMatchesFilter(defender, $0.param(0)) }) { return false }
        let captureChance = min(Float(0.8), Float(0.1) + Float(combatantAttackingStrength(attacker, defender: defender)) / Float(combatantDefendingStrength(defender, attacker: attacker)) * Float(0.4))
        let turns = Int32(truncatingIfNeeded: turn - (barbarianPhase ? 0 : 1))
        var random = SeededRandom(kotlinSeedLong: Int64(turns &* uncivPositionVector2Hash(cCoord(defender))))
        return random.nextFloat() <= captureChance
    }

    /// Unciv BattleUnitCapture.unitGainFromDefeatingUnit: melee only; every "When defeating a [filter] unit, earn [n]
    /// Gold and recruit it" that holds pays its gold.
    private func unitGainFromDefeatingUnit(_ attacker: Combatant, _ defender: Combatant) -> Bool {
        guard cIsMelee(attacker), let au = cUnit(attacker), let du = cUnit(defender) else { return false }
        // GameContext(attacker civ, ourCombatant = attacker, theirCombatant = defender): no tile, no action, no other civ
        let state = UniqueContext(civId: au.civId, unit: au, opponentUnit: du)
        var unitCaptured = false
        for unique in unitMatchingUniques(au, "When defeating a [] unit, earn [] Gold and recruit it", state, checkCivInfoUniques: true) where unitMatches(du, unique.param(0)) {
            addGold(au.civId, unique.int(1))
            unitCaptured = true
        }
        return unitCaptured
    }

    /// Unciv BattleUnitCapture.spawnCapturedUnit: the same unit, at half health and without movement, for the
    /// attacker, near where the defender stood; a civilian left on that tile is captured when the new unit could
    /// not be placed on it.
    private func spawnCapturedUnit(_ defender: Combatant, _ attacker: Combatant) -> Bool {
        guard let du = cUnit(defender) else { return false }
        let defenderTile = du.coord
        let attackerCiv = cCivId(attacker)
        guard let added = spawnUnit(du.name, civId: attackerCiv, at: defenderTile), let ai = unitIndex(added.id) else { return false }
        units[ai].movementLeft = 0
        units[ai].health = 50
        notify(attackerCiv, "An enemy [\(du.name)] has joined us!", category: .War, icons: [du.name], actions: [.unit(units[ai].coord, added.id)])
        notify(du.civId, "An enemy [\(cName(attacker))] has captured our [\(du.name)]", category: .War, icons: [cName(attacker), "War", du.name], coord: defenderTile)
        if let placed = unit(added.id), placed.coord != defenderTile, let civilian = civilianUnitOn(defenderTile), civilian.civId != attackerCiv {
            captureCivilianUnit(attacker, .unit(civilian.id))
        }
        return true
    }

    /// Unciv BattleUnitCapture.captureCivilianUnit: an uncapturable unit, or a settler taken by a city-state, is
    /// destroyed; our own former unit comes back as it is; a human may give a civilian rescued from barbarians back
    /// to its owner; anything else is captured (a settler becoming a worker). The loser is told either way, and a
    /// civ left with nothing is defeated.
    func captureCivilianUnit(_ attacker: Combatant, _ defender: Combatant, checkDefeat: Bool = true) {
        guard let did = defender.unitId, let di0 = unitIndex(did) else { return }
        let attackerCiv = cCivId(attacker)
        guard attackerCiv != units[di0].civId else { return }   // Can't capture our own unit!
        // need to save this because if the unit is captured its owner will be overwritten
        let defenderCiv = units[di0].civId
        // Stop current action
        units[di0].order = .none
        units[di0].automated = false   // `capturedUnit.automated = false`
        if units[di0].originalCiv < 0 { units[di0].originalCiv = defenderCiv }   // saves from before the owner was recorded
        let capturedUnit = units[di0]
        let capturedUnitTile = capturedUnit.coord
        let originalOwner = capturedUnit.originalCiv >= 0 ? capturedUnit.originalCiv : nil
        let attackerName = cName(attacker), defenderName = capturedUnit.name
        var wasDestroyedInstead = false
        let foundsCity = capturedUnit.promotionUniques.contains { $0.pattern == "Founds a new city" || $0.pattern == "Founds a new puppet city" }
        if unitHasUnique(capturedUnit, "Uncapturable") {
            // Uncapturable units are destroyed
            destroyUnit(did); wasDestroyedInstead = true
        } else if civ(attackerCiv)?.isCityState == true && foundsCity {
            // City states can never capture settlers at all
            destroyUnit(did); wasDestroyedInstead = true
        } else if attackerCiv == originalOwner {
            // Our old unit: recaptured without converting settlers to workers
            capturedBy(did, attackerCiv)
        } else if civ(defenderCiv)?.isBarbarian == true, let orig = originalOwner.flatMap({ civ($0) }), !orig.isBarbarian, attackerCiv != orig.id,
                  civ(attackerCiv)?.metCivs.contains(orig.id) == true, orig.isAlive, !areAtWar(attackerCiv, orig.id),
                  civ(attackerCiv)?.isPlayer == true, !epochsAutoplay {   // Unciv `playerType == PlayerType.Human`
            // Only humans get the choice to return a captured civilian to its original owner
            capturedBy(did, attackerCiv)
            addAlert(attackerCiv, .RecapturedCivilian, "\(did)")
        } else if captureOrConvertToWorker(did, attackerCiv) == nil {
            wasDestroyedInstead = true
        }

        let at = cUnit(defender)?.coord ?? capturedUnitTile
        if !wasDestroyedInstead {
            notify(defenderCiv, "An enemy [\(attackerName)] has captured our [\(defenderName)]", category: .War, icons: [attackerName, "War", defenderName], coord: at)
        } else {
            notify(defenderCiv, "An enemy [\(attackerName)] has destroyed our [\(defenderName)]", category: .War, icons: [attackerName, "War", defenderName], coord: at)
            triggerDefeatUniques(defender, attacker, attackedTile: capturedUnitTile)
        }
        if checkDefeat { destroyIfDefeated(defenderCiv, attacker: attackerCiv) }
        // `capturedUnit.updateVisibleTiles()`: the unit's own update, against the view it stored before the capture -
        // the same tiles unless it was moved or its new civ's sight differs, and then no civ view is stored
        // (MapUnit.kt:842); a barbarian captor's too
        if unit(did) != nil { revealFromCurrentTile(did) }
    }

    /// Unciv MapUnit.capturedBy: out of the old owner's list (UnitManager.removeUnit and its updates), onto the end
    /// of the captor's (UnitManager.addUnit and its updates), no movement left, and moved off a tile it may no
    /// longer stand on.
    func capturedBy(_ unitId: Int, _ captor: Int) {
        if let old = unit(unitId)?.civId { rotateCivUnitsToNextDue(old) }   // Unciv `civ.units.removeUnit(this)`: the old owner's list starts at nextPotentiallyDueAt
        guard let i = unitIndex(unitId) else { return }
        let lost = units[i]
        if GameState.evlogOn { evUnitDie(lost) }   // EVLOG: UNIT_DIE for the loser, UNIT_ADD for the captor below
        units[i].civId = captor
        units[i].escorting = false
        unitManagerRemoved(lost)
        moveUnitToEndOfList(unitId)   // Unciv assignOwner → UnitManager.addUnit: APPENDED to the new owner's list
        if let now = unit(unitId) { unitManagerAdded(now); if GameState.evlogOn { evUnitAdd(now) } }   // EVLOG: UNIT_ADD (capture)
        updateUnitUniquesCache(unitId)   // Unciv assignOwner ends in cache.updateUniques()
        guard let j = unitIndex(unitId) else { return }
        units[j].movementLeft = 0
        // It's possible that the unit can no longer stand on the tile it was captured on
        if let cu = unit(unitId), !canPassThrough(cu, cu.coord) { teleportToClosestMoveableTile(unitId) }
    }

    /// Unciv BattleUnitCapture.captureOrConvertToWorker: a settler captured by anyone but barbarians is destroyed and
    /// replaced by the ruleset's first civilian that builds land improvements; anything else is simply captured.
    /// Returns where the unit ended up, nil when nothing took the settler's place.
    @discardableResult
    func captureOrConvertToWorker(_ unitId: Int, _ capturingCiv: Int) -> HexCoord? {
        guard let u = unit(unitId) else { return nil }
        let foundsCity = u.promotionUniques.contains { $0.pattern == "Founds a new city" }
        if !foundsCity || civ(capturingCiv)?.isBarbarian == true {
            capturedBy(unitId, capturingCiv)
            return unit(unitId)?.coord
        }
        let position = u.coord
        destroyUnit(unitId)
        // So that later checks of whether the unit was captured (postBattleMoveToAttackedTile) see the captor
        battleGraveyard[unitId]?.civId = capturingCiv
        guard let workerType = rs.unitOrder.compactMap({ rs.units[$0] }).first(where: { d in
            d.isCivilian && d.uniqueObjects.contains { $0.pattern == "Can build [] improvements on tiles" && $0.param(0) == "Land" }
        }) else { return nil }
        return spawnUnit(workerType.name, civId: capturingCiv, at: position)?.coord
    }

    /// Unciv UnitManager.removeUnit(unit) with updateCivInfo: the owner's stats for next turn (unit upkeep), its
    /// resources when the unit used any, and "upon losing a [filter] unit".
    func unitManagerRemoved(_ u: Unit) {
        updateStatsForNextTurn(u.civId)
        if !resourceRequirementsPerTurn(requiredResource: u.def.requiredResource, uniques: u.def.uniqueObjects, ctx: UniqueContext(civId: u.civId, unit: u)).isEmpty {
            updateCivResources(u.civId)
        }
        triggerConditionalUniques(civId: u.civId) { $0.pattern == "upon losing a [] unit" && self.unitMatches(u, $0.param(0)) }
    }

    /// Unciv UnitManager.addUnit(unit) with updateCivInfo: the new owner's stats for next turn, and its resources
    /// when the unit uses any.
    func unitManagerAdded(_ u: Unit) {
        updateStatsForNextTurn(u.civId)
        if !resourceRequirementsPerTurn(requiredResource: u.def.requiredResource, uniques: u.def.uniqueObjects, ctx: UniqueContext(civId: u.civId, unit: u)).isEmpty {
            updateCivResources(u.civId)
        }
    }
}
