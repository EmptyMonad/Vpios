// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/Battle.kt`: resolving one attack, and everything that follows from it.
struct CombatPreview {
    let attackerStrength: Double
    let defenderStrength: Double
    let damageToDefender: Int
    let damageToAttacker: Int
    let isRanged: Bool
    let targetIsCity: Bool
    // Unciv BattleTable: calculateDamageTo…(randomnessFactor 1f / 0f), plus getExtraRangedAttackBonusDamage for the defender
    var maxDamageToDefender = 0, minDamageToDefender = 0
    var maxDamageToAttacker = 0, minDamageToAttacker = 0
    var hasExtraRangedAttack = false
}

/// Unciv Battle.DamageDealt: what the attacker dealt to the defender and the defender to the attacker.
struct DamageDealt {
    var attackerDealt: Int
    var defenderDealt: Int
    static let none = DamageDealt(attackerDealt: 0, defenderDealt: 0)
    static func + (a: DamageDealt, b: DamageDealt) -> DamageDealt {
        DamageDealt(attackerDealt: a.attackerDealt + b.attackerDealt, defenderDealt: a.defenderDealt + b.defenderDealt)
    }
}

extension GameState {
    // MARK: - previews

    /// Unciv BattleDamage.calculateDamageToDefender / calculateDamageToAttacker for `attacker` as it stands, against
    /// whatever Battle.getMapCombatantOfTile finds on the target. `resolving` is the AI's and the fight's own call,
    /// where the attack comes "from" the defender's tile (Unciv's default) and the river penalty never applies;
    /// the battle table passes `resolving: false` to measure from the tile it would attack from (`attackFrom`, the
    /// attacker's own tile by default), as Unciv's BattleTable does with getAttackableEnemies' tileToAttackFrom.
    /// `shownDefender` is the battle table's: the combatant the player can see there (TileView.getCombatant), not whatever
    /// getMapCombatantOfTile would fight - an undetected submarine stays hidden behind the work boat on its tile.
    func combatPreview(attacker: Unit, targetTile: HexCoord, resolving: Bool = true, attackFrom: HexCoord? = nil, shownDefender: Combatant? = nil) -> CombatPreview? {
        guard let defender = shownDefender ?? getMapCombatantOfTile(targetTile), cCivId(defender) != attacker.civId else { return nil }
        let a: Combatant = .probe(attacker)
        let from = resolving ? targetTile : (attackFrom ?? attacker.coord)
        let aStr = getAttackingStrength(a, defender, tileToAttackFrom: from)
        let civilianDefender = cIsCivilian(defender)
        let dStr = civilianDefender ? 0 : getDefendingStrength(a, defender, tileToAttackFrom: from)
        // calculateDamageToDefender / calculateDamageToAttacker, with the two strengths worked out once
        let noReturnFire = (cIsRanged(a) && !cIsAirUnit(a)) || civilianDefender
        let toAttackerRatio = getHealthDependantDamageRatio(defender), toDefenderRatio = getHealthDependantDamageRatio(a)
        func toDefender(_ r: Float) -> Int {
            civilianDefender ? BattleConstants.damageToCivilianUnit : Stats.roundToInt(Double(uncivDamageModifier(aStr / dStr, damageToAttacker: false, randomnessFactor: r) * toDefenderRatio))
        }
        func toAttacker(_ r: Float) -> Int {
            noReturnFire ? 0 : Stats.roundToInt(Double(uncivDamageModifier(aStr / dStr, damageToAttacker: true, randomnessFactor: r) * toAttackerRatio))
        }
        var p = CombatPreview(attackerStrength: Double(aStr), defenderStrength: Double(dStr),
                              damageToDefender: toDefender(getRandomness(defender)),
                              damageToAttacker: toAttacker(getRandomness(a)),
                              isRanged: attacker.def.isRanged, targetIsCity: defender.isCity)
        p.maxDamageToDefender = toDefender(1); p.minDamageToDefender = toDefender(0)
        p.maxDamageToAttacker = toAttacker(1); p.minDamageToAttacker = toAttacker(0)
        // Unciv BattleTable.simulateBattle: `!defender.isCity() && attacker.hasUnique(ExtraRangedAttack)` - a civilian included
        if !getExtraRangedAttackFakeUnits(a).isEmpty && defender.isMapUnitCombatant {
            p.hasExtraRangedAttack = true
            let (maxExtra, minExtra) = getExtraRangedAttackBonusDamage(a, defender, tileToAttackFrom: from)
            p.maxDamageToDefender += maxExtra; p.minDamageToDefender += minExtra
        }
        return p
    }

    // MARK: - Battle.moveAndAttack / movePreparingAttack / attackOrNuke

    /// Unciv Battle.moveAndAttack: move to the tile to attack from, set up, pillage on the way to heal, then attack.
    func moveAndAttack(_ unitId: Int, _ attackableTile: AttackableTile) {
        guard movePreparingAttack(unitId, attackableTile, tryHealPillage: true) else { return }
        attackOrNuke(.unit(unitId), attackableTile)
    }

    /// Unciv Battle.movePreparingAttack: returns whether an attack is still possible.
    @discardableResult
    func movePreparingAttack(_ unitId: Int, _ attackableTile: AttackableTile, tryHealPillage: Bool = false) -> Bool {
        guard let u = unit(unitId) else { return false }
        let distanceToTiles = turnPaths(u)
        let tilesMovedThrough = distanceToTiles.contains(attackableTile.tileToAttackFrom) ? distanceToTiles.path(to: attackableTile.tileToAttackFrom) : []
        moveToTile(unitId, attackableTile.tileToAttackFrom)
        // A hidden tile counted as 1 movement point may turn out impassable, and the unit stops halfway.
        guard let moved = unit(unitId), moved.coord == attackableTile.tileToAttackFrom else { return false }
        // Moving through a civilian on the way may have captured the very unit that was the target.
        guard let combatant = getMapCombatantOfTile(attackableTile.tileToAttack), cCivId(combatant) != moved.civId else { return false }
        // We reached the tile but it was a hill or something, and a unit that must set up does so now.
        if unitHasUnique(moved, "Must set up to ranged attack") && !moved.isSetUp && moved.hasMovement, let i = unitIndex(unitId) {
            units[i].isSetUp = true
            if units[i].order != .automate { units[i].order = .none }   // Unciv: `action = SetUp` replaces whatever action the unit had; `automated` stays
            useMovementPoints(unitId, 1)
        }
        if tryHealPillage {
            // Retroactively pillage an improvement on the path to heal, while still being able to attack
            for tileToPillage in tilesMovedThrough {
                guard let live = unit(unitId), !(live.movementLeft <= 1 || live.health > 90) else { break }   // We are done pillaging
                if canPillage(live, at: tileToPillage) && map[tileToPillage]?.canPillageImprovement == true {
                    pillage(unitId: unitId, tile: tileToPillage)
                }
            }
        }
        return unit(unitId)?.hasMovement ?? false
    }

    /// Unciv Battle.attackOrNuke: meant to be called only after all prerequisite checks have been done.
    @discardableResult
    func attackOrNuke(_ attacker: Combatant, _ attackableTile: AttackableTile) -> DamageDealt {
        if case .unit(let id) = attacker, let u = unit(id), let nuke = unitMatchingUniques(u, "Nuclear weapon of Strength []").first {
            _ = detonate(unitId: id, at: attackableTile.tileToAttack, strength: nuke.int(0))
            return .none
        }
        guard let defender = getMapCombatantOfTile(attackableTile.tileToAttack) else { return .none }
        return attack(attacker, defender)
    }

    /// A player's attack from the UI, after movePreparingAttack said an attack is still possible (Unciv
    /// MapUnitView.attackOrNuke): the same Battle.attackOrNuke, summed up in a line.
    @discardableResult
    func attack(unitId: Int, _ attackableTile: AttackableTile) -> String {
        guard let attacker = unit(unitId) else { return "" }
        // movePreparingAttack has already refused a tile without a foreign combatant; only a nuke gets here without one
        guard let defender = getMapCombatantOfTile(attackableTile.tileToAttack) else { attackOrNuke(.unit(unitId), attackableTile); return "" }
        let defenderName = cName(defender)
        let dealt = attackOrNuke(.unit(unitId), attackableTile)
        var summary = "\(attacker.name) dealt \(dealt.attackerDealt), took \(dealt.defenderDealt)"
        if cIsDefeated(defender) && !defender.isCity { summary += ". \(defenderName) destroyed!" }
        if let c = cCity(defender), c.civId == attacker.civId { summary = "\(attacker.name) captured \(c.name)!" }
        if unit(unitId) == nil { summary += ". \(attacker.name) was lost." }
        return summary
    }

    // MARK: - Battle.attack

    /// Unciv Battle.attack: interception, withdrawal, the extra ranged attack, the combat triggers, the exchange,
    /// prize ships, notifications, the barbarian camp, a defeated city, the kill rewards and triggers, wake-up,
    /// self-destruction, the move into the tile, movement and attacks spent, XP - in that order.
    /// BTL trace: "<civ>:<name>@x,y:<health>" as the patched Unciv copy prints a combatant
    func btlC(_ c: Combatant) -> String {
        let p = uncivPosition(cCoord(c))
        return "\(civ(cCivId(c))?.nation ?? "-"):\(cName(c).replacingOccurrences(of: " ", with: "_"))@\(p.x),\(p.y):\(cHealth(c))"
    }
    @discardableResult
    func attack(_ attacker: Combatant, _ defender: Combatant) -> DamageDealt {
        if epochsBtlDbg { print("BTL t=\(uncivTurns) ATTACK \(btlC(attacker)) -> \(btlC(defender))") }
        battleGraveyard = [:]
        let attackedTile = cCoord(defender)
        // Unciv Battle.attack: the attack is remembered for the movement-arrow overlay first thing - a unit's in its own
        // attacksSinceTurnStart, anything else's (a city's) in its civ's, as HistoricalAttackMemory(null, from, to)
        if attacker.isMapUnitCombatant {
            if case .unit(let id) = attacker, let ai = unitIndex(id) { units[ai].attacksSinceTurnStart.append(attackedTile) }
        } else if let ci = civIndex(cCivId(attacker)) {
            civs[ci].attacksSinceTurnStart.append(HistoricalAttackMemory(attackingUnit: nil, source: cCoord(attacker), target: attackedTile))
        }
        if ProcessInfo.processInfo.environment["ATKLOG"] != nil {
            let a = uncivPosition(cCoord(attacker)), d = uncivPosition(attackedTile)
            print("ATKE t=\(uncivTurns) \(civ(cCivId(attacker))?.nation ?? "-") \(cName(attacker))@\(a.x),\(a.y):hp\(cHealth(attacker)):mv\(cUnit(attacker).map { "\(Float($0.movementLeft))" } ?? "nil") -> \(civ(cCivId(defender))?.nation ?? "-") \(cName(defender))@\(d.x),\(d.y):hp\(cHealth(defender))")
        }
        let attackerUnitBefore = attacker.isMapUnitCombatant ? cUnit(attacker) : nil
        let event = attackerUnitBefore.map { beginAttackEvent(attacker: $0, target: attackedTile) }
        let defenderHealthBefore = cHealth(defender), attackerHealthBefore = cHealth(attacker)
        let attackerCoordBefore = cCoord(attacker)
        let defBefore = epochsTradeDbg ? units(at: attackedTile).filter { $0.civId != cCivId(attacker) } : []
        let cityHere = cCity(defender)
        var modsDbg = ""
        if epochsTradeDbg, attacker.isMapUnitCombatant, !cIsCivilian(defender) {
            let am = getAttackModifiers(attacker, defender, tileToAttackFrom: attackedTile).entries
            let dm = getDefenceModifiers(attacker, defender, tileToAttackFrom: attackedTile).entries
            modsDbg = " atk=\(getAttackingStrength(attacker, defender, tileToAttackFrom: attackedTile))\(am) def=\(getDefendingStrength(attacker, defender, tileToAttackFrom: attackedTile))\(dm)"
        }

        var interceptDamage = DamageDealt.none
        if attacker.isMapUnitCombatant, cUnit(attacker)?.def.isAir == true {
            interceptDamage = tryInterceptAirAttack(attacker, attackedTile: attackedTile, interceptingCiv: cCivId(defender), defender: defender)
            if cIsDefeated(attacker) {
                if let e = event { finishAttackEvent(e) }
                return interceptDamage
            }
        }

        if hasWithdrawnFromMelee(attacker, defender, attackedTile: attackedTile) {
            if let e = event { finishAttackEvent(e, withdrawn: true) }
            return .none
        }

        let isAlreadyDefeatedCity = defender.isCity && cIsDefeated(defender)
        let extraRangedAttackDamage = tryExtraRangedAttack(attacker, defender, attackedTile: attackedTile)
        triggerCombatUniques(attacker, defender, attackedTile: attackedTile)
        let damageDealt = takeDamage(attacker, defender) + extraRangedAttackDamage

        // check if unit is captured by the attacker (prize ships unique) - only the aggressor captures
        let captureMilitaryUnitSuccess = tryCaptureMilitaryUnit(attacker, defender, attackedTile: attackedTile)
        // a capture creates a new unit while `defender` is still the original, which would announce a kill
        if !captureMilitaryUnitSuccess { postBattleNotifications(attacker, defender, attackedTile: attackedTile, attackerTile: cCoord(attacker), damageDealt: damageDealt) }

        if civ(cCivId(defender))?.isBarbarian == true && map[attackedTile]?.hasBarbarianCamp == true { campAttacked(at: attackedTile) }

        // This needs to come BEFORE the move-to-tile, because if we haven't conquered it we can't move there =)
        handleCityDefeated(defender, attacker)

        // Culture for a defeated barbarian with Honor, gold for a killed enemy, and the like - either side may be the killer
        triggerPostKillingUniques(defender, attacker, attackedTile: attackedTile)

        if attacker.isMapUnitCombatant && defender.isMapUnitCombatant {
            triggerDamageUniquesForUnit(attacker, defender, attackedTile: attackedTile, action: "Attack")
            if !cIsRanged(attacker) { triggerDamageUniquesForUnit(defender, attacker, attackedTile: attackedTile, action: "Defend") }
        }

        // Exploring units surviving an attack should "wake up"
        if !cIsDefeated(defender), defender.isMapUnitCombatant, let did = defender.unitId, let di = unitIndex(did), units[di].order == .explore {
            units[di].order = .none
        }

        if attacker.isMapUnitCombatant, let au = cUnit(attacker) {
            if unitHasUnique(au, "Self-destructs when attacking") {
                if unit(au.id) != nil { destroyUnit(au.id) }
            } else if let ai = unitIndex(au.id), case .moveTo = units[ai].order {
                units[ai].order = .none
            }
            doDestroyImprovementsAbility(attacker, attackedTile: attackedTile, defender)
        }

        // Should be called after tryCaptureUnit(), as that might spawn a unit on the tile we go to
        if !captureMilitaryUnitSuccess { postBattleMoveToAttackedTile(attacker, defender, attackedTile: attackedTile) }

        reduceAttackerMovementPointsAndAttacks(attacker, defender, attackedTile: attackedTile)

        if !isAlreadyDefeatedCity { postBattleAddXp(attacker, defender) }

        if let cid = attacker.cityId, let city = cCity(attacker) {
            removeFirstNotification(civId: city.civId, text: "Your city [\(city.name)] can bombard the enemy!")
            _ = cid
        }

        if let e = event { finishAttackEvent(e) }
        if epochsTradeDbg {
            let ap = uncivPosition(attackerCoordBefore), tp = uncivPosition(attackedTile)
            let before = defBefore.map { "\(civ($0.civId)?.nation ?? "?")/\($0.name):\($0.health)" }.joined(separator: "+")
            let after = defBefore.map { d in self.unit(d.id).map { "\($0.name):\($0.health)" } ?? "\(d.name):dead" }.joined(separator: "+")
            let cityStr = cityHere.map { c in "\(c.name):\(defenderHealthBefore)->\(self.city(c.id).map { "\($0.health)" } ?? "razed")" } ?? "-"
            print("ATKE t=\(turn) \(civ(cCivId(attacker))?.nation ?? "?")/\(cName(attacker))@\(ap.x),\(ap.y) -> \(tp.x),\(tp.y) def=[\(before)] after=[\(after)] city=\(cityStr) me=\(attackerHealthBefore)->\(cIsDefeated(attacker) && !attacker.isCity ? "dead" : "\(cHealth(attacker))")\(modsDbg)")
        }
        return damageDealt + interceptDamage
    }

    /// Unciv Battle.triggerPostKillingUniques
    private func triggerPostKillingUniques(_ defender: Combatant, _ attacker: Combatant, attackedTile: HexCoord) {
        if cIsDefeated(defender) && defender.isMapUnitCombatant && !(cUnit(defender)?.isCivilian ?? true) {
            tryEarnFromKilling(attacker, defender)
            tryHealAfterKilling(attacker)
            if attacker.isMapUnitCombatant { triggerVictoryUniques(attacker, defender, attackedTile: attackedTile) }
            triggerDefeatUniques(defender, attacker, attackedTile: attackedTile)
        } else if cIsDefeated(attacker) && attacker.isMapUnitCombatant && !(cUnit(attacker)?.isCivilian ?? true) {
            tryEarnFromKilling(defender, attacker)
            tryHealAfterKilling(defender)
            if defender.isMapUnitCombatant { triggerVictoryUniques(defender, attacker, attackedTile: attackedTile) }
            triggerDefeatUniques(attacker, defender, attackedTile: attackedTile)
        }
    }

    /// Unciv Battle.handleCityDefeated: a defeated city is destroyed by a unit that destroys cities, raided by
    /// barbarians, or conquered.
    private func handleCityDefeated(_ defender: Combatant, _ attacker: Combatant) {
        guard cIsDefeated(defender), let cityId = defender.cityId, case .unit = attacker, let au = cUnit(attacker) else { return }
        if !cIsMelee(attacker) && !unitHasUnique(au, "Destroys [] cities instead of capturing", nil, checkCivInfoUniques: true) { return }
        if unitHasUnique(au, "Unable to capture cities", nil, checkCivInfoUniques: true) { return }
        guard let city = city(cityId) else { return }

        // Must come before normal conquest logic so units that cannot capture cities can still destroy them
        if canBeDestroyedForBattle(city) {
            let destroyFilters = unitMatchingUniques(au, "Destroys [] cities instead of capturing").map { $0.param(0) }
            if destroyFilters.contains(where: { cityMatchesFilter($0.trimmingCharacters(in: .whitespaces), city: city, viewer: au.civId) }) {
                let defendingCiv = city.civId
                notify(au.civId, "We have destroyed the city of [\(city.name)]!", category: .War, icons: ["War"], coord: city.coord)
                destroyCity(cityId: cityId)
                if cities(of: defendingCiv).isEmpty { destroyIfDefeated(defendingCiv, attacker: au.civId, at: city.coord) }
                return   // stop further logic because city was destroyed
            }
        }

        // Barbarians can't capture cities, instead raiding them for gold
        if civ(au.civId)?.isBarbarian == true {
            cTakeDamage(defender, -1)   // Back to 2 HP
            let ransom = min(200, Int(civ(city.civId)?.gold ?? 0))
            addGold(city.civId, -ransom)
            notify(city.civId, "Barbarians raided [\(city.name)] and stole [\(ransom)] Gold from your treasury!", category: .War, icons: ["War"], coord: city.coord)
            destroyUnit(au.id)   // Remove the barbarian
        } else {
            conquerCity(cityId, attacker)
        }
    }

    /// Unciv City.canBeDestroyed(justCaptured)
    func canBeDestroyedForBattle(_ city: City, justCaptured: Bool = false) -> Bool {
        if settings.noCityRazing { return false }
        let allowRazeCapital = rs.modOptionUniques.contains { $0.pattern == "Allow raze capital" }
        let allowRazeHolyCity = rs.modOptionUniques.contains { $0.pattern == "Allow raze holy city" }
        if city.isOriginalCapital && !allowRazeCapital { return false }
        if city.isHolyCity && !allowRazeHolyCity { return false }
        if city.isCapital && !justCaptured && !allowRazeCapital { return false }
        return true
    }

    /// Unciv Battle.triggerCombatUniques: "upon entering combat" for both units, before the exchange
    private func triggerCombatUniques(_ attacker: Combatant, _ defender: Combatant, attackedTile: HexCoord) {
        if attacker.isMapUnitCombatant, let au = cUnit(attacker) {
            triggerUnitConditionalUniques(unit: au, targetUnitId: defender.isMapUnitCombatant ? defender.unitId : nil) { $0.pattern == "upon entering combat" }
        }
        if defender.isMapUnitCombatant, let du = cUnit(defender) {
            triggerUnitConditionalUniques(unit: du, targetUnitId: attacker.isMapUnitCombatant ? attacker.unitId : nil) { $0.pattern == "upon entering combat" }
        }
    }

    /// Unciv Battle.triggerVictoryUniques: "upon defeating a [filter] unit"
    private func triggerVictoryUniques(_ ourUnit: Combatant, _ enemy: Combatant, attackedTile: HexCoord) {
        guard let our = cUnit(ourUnit), let them = cUnit(enemy) else { return }
        triggerUnitConditionalUniques(unit: our, targetUnitId: them.id, triggerText: "due to \(cNotificationDisplay(ourUnit, "our ")) defeating a [\(them.name)]") {
            $0.pattern == "upon defeating a [] unit" && self.unitMatches(them, $0.param(0))
        }
    }

    /// Unciv Battle.triggerDamageUniquesForUnit: "upon damaging a [filter] unit"
    private func triggerDamageUniquesForUnit(_ triggeringUnit: Combatant, _ enemy: Combatant, attackedTile: HexCoord, action: String) {
        guard let our = cUnit(triggeringUnit), let them = cUnit(enemy) else { return }
        triggerUnitConditionalUniques(unit: our, targetUnitId: them.id, triggerText: "due to \(cNotificationDisplay(triggeringUnit, "our ")) damaging a [\(them.name)]") {
            $0.pattern == "upon damaging a [] unit" && self.cMatchesFilter(enemy, $0.param(0))
        }
    }

    /// Unciv Battle.triggerDefeatUniques: "upon being defeated"
    func triggerDefeatUniques(_ ourUnit: Combatant, _ enemy: Combatant, attackedTile: HexCoord) {
        guard let our = cUnit(ourUnit) else { return }
        triggerUnitConditionalUniques(unit: our, triggerText: "due to \(cNotificationDisplay(ourUnit, "our ")) being defeated by a [\(cName(enemy))]") { $0.pattern == "upon being defeated" }
    }

    /// Unciv Battle.tryEarnFromKilling: the kill-plunder uniques, the city-states grateful for a dead barbarian,
    /// and the city-states' war-with-major pseudo-quest.
    private func tryEarnFromKilling(_ civUnit: Combatant, _ defeatedUnit: Combatant) {
        guard let dead = cUnit(defeatedUnit) else { return }
        let civId = cCivId(civUnit)
        let unitStr = max(dead.def.strength, dead.def.rangedStrength)
        let unitCost = dead.def.cost
        for unique in getKillUnitPlunderUniques(civUnit, defeatedUnit) {
            guard cMatchesFilter(defeatedUnit, unique.param(1)) else { continue }
            let yieldPercent = Float(unique.double(0)) / 100
            let yieldTypeSourceAmount = unique.param(2) == "Cost" ? unitCost : unitStr
            let yieldAmount = Int(Float(yieldTypeSourceAmount) * yieldPercent)
            guard isGameResource(unique.param(3)) else { continue }
            addGameResource(civId, unique.param(3), yieldAmount)
        }
        // CS friendship from killing barbarians
        if civ(dead.civId)?.isBarbarian == true && !cIsCivilian(defeatedUnit) && civ(civId)?.isMajor == true {
            threateningBarbarianKilled(dead, by: civId)
        }
        // CS war with major pseudo-quest
        warWithMajorUnitKilled(killer: civId, killed: dead.civId)
    }

    /// Unciv Battle.getKillUnitPlunderUniques: the killer's own (a unit's and its civ's, a city's civ's), then those
    /// of the first city centre within 4 tiles of the killer whose religion pays for kills near it.
    private func getKillUnitPlunderUniques(_ civUnit: Combatant, _ defeatedUnit: Combatant) -> [Unique] {
        var bonusUniques: [Unique] = []
        let civId = cCivId(civUnit)
        // GameContext(civInfo, ourCombatant = civUnit, theirCombatant = defeatedUnit)
        var ctx = combatContext(civUnit, defeatedUnit, attackedTile: nil, action: nil)
        ctx.tile = nil; ctx.city = nil
        if civUnit.isMapUnitCombatant, let u = cUnit(civUnit) {
            bonusUniques += unitMatchingUniques(u, "Earn []% of killed [] unit's [] as []", ctx, checkCivInfoUniques: true)
        } else {
            bonusUniques += civUniques(civId).filter { $0.pattern == "Earn []% of killed [] unit's [] as []" && conditionalsHold($0, ctx) }
        }
        for t in map.tilesWithin(cCoord(civUnit), radius: 4) {
            guard let city = city(at: t) else { continue }
            let near = killPlunderNearCityUniques(city, ctx)
            if !near.isEmpty { bonusUniques += near; break }
        }
        return bonusUniques
    }

    /// Unciv City.getMatchingUniques(KillUnitPlunderNearCity): the follower beliefs of the city's majority religion
    private func killPlunderNearCityUniques(_ city: City, _ ctx: UniqueContext) -> [Unique] {
        guard let r = majorityReligion(of: city), let owner = religionOwner(r) else { return [] }
        return owner.religionBeliefs.flatMap { rs.beliefs[$0]?.uniqueObjects ?? [] }
            .filter { $0.pattern == "Earn []% of [] unit's [] as [] when killed within 4 tiles of a city following this religion" && conditionalsHold($0, ctx) }
    }

    /// Unciv Battle.takeDamage: both damages worked out first, then a civilian is captured, a ranged attack lands
    /// in one go, or the melee exchange takes one HP at a time from whichever side the roll picks until one dies.
    @discardableResult
    func takeDamage(_ attacker: Combatant, _ defender: Combatant) -> DamageDealt {
        let attackerContext = combatContext(attacker, defender, attackedTile: cCoord(defender), action: "Attack")
        var potentialDamageToDefender = calculateDamageToDefender(attacker, defender)
        var potentialDamageToAttacker = calculateDamageToAttacker(attacker, defender)
        var rng = stateBasedRandom("Battle.takeDamage", attackerContext)
        if epochsBtlDbg { print("BTL t=\(uncivTurns) TAKEDMG \(btlC(attacker)) -> \(btlC(defender)) potD=\(potentialDamageToDefender) potA=\(potentialDamageToAttacker)") }
        if epochsBtlDbg {
            func m(_ c: ModifierCounter) -> String { "{" + c.keys.sorted().map { "\($0)=\(c[$0])" }.joined(separator: ", ") + "}" }
            let dt = cCoord(defender)
            print("BTL t=\(uncivTurns) MODS atk=\(getAttackingStrength(attacker, defender, tileToAttackFrom: dt))\(m(getAttackModifiers(attacker, defender, tileToAttackFrom: dt))) def=\(getDefendingStrength(attacker, defender, tileToAttackFrom: dt))\(m(getDefenceModifiers(attacker, defender, tileToAttackFrom: dt))) rA=\(getRandomness(attacker)) rD=\(getRandomness(defender))")
        }
        let attackerHealthBefore = cHealth(attacker)
        let defenderHealthBefore = cHealth(defender)
        if epochsTradeDbg {
            if defender.isCity { print("CITYATK t=\(turn) \(cName(attacker)) -> \(cName(defender)) potDef=\(potentialDamageToDefender) potAtt=\(potentialDamageToAttacker) attHP=\(attackerHealthBefore) defHP=\(defenderHealthBefore)") }
            else { print("TAKEDMG t=\(turn) \(cName(attacker))->\(cName(defender)) potDef=\(potentialDamageToDefender) potAtt=\(potentialDamageToAttacker) aHP=\(attackerHealthBefore) dHP=\(defenderHealthBefore)") }
            if potentialDamageToDefender == 0 && potentialDamageToAttacker == 0 { print("ATKZERO t=\(turn) \(cName(attacker))") }
        }

        if defender.isMapUnitCombatant && cIsCivilian(defender) && cIsMelee(attacker) {
            captureCivilianUnit(attacker, defender)
        } else if cIsRanged(attacker) && !cIsAirUnit(attacker) {   // Air Units are Ranged, but take damage as well
            cTakeDamage(defender, potentialDamageToDefender)   // straight up
        } else {
            // melee attack is complicated, because either side may defeat the other midway,
            // so for each round we randomize who gets the attack in
            while potentialDamageToDefender + potentialDamageToAttacker > 0 {
                if rng.int(0...(potentialDamageToDefender + potentialDamageToAttacker - 1)) < potentialDamageToDefender {
                    potentialDamageToDefender -= 1
                    cTakeDamage(defender, 1)
                    if cIsDefeated(defender) { break }
                } else {
                    potentialDamageToAttacker -= 1
                    cTakeDamage(attacker, 1)
                    if cIsDefeated(attacker) { break }
                }
            }
        }

        if epochsBtlDbg { print("BTL t=\(uncivTurns) RESULT \(btlC(attacker)) -> \(btlC(defender))") }
        let defenderDamageDealt = attackerHealthBefore - cHealth(attacker)
        let attackerDamageDealt = defenderHealthBefore - cHealth(defender)
        triggerLosingHPUniques(attacker, attackerDamageDealt, defender, defenderDamageDealt)
        plunderFromDamage(attacker, defender, damageDealt: attackerDamageDealt)
        return DamageDealt(attackerDealt: attackerDamageDealt, defenderDealt: defenderDamageDealt)
    }

    /// Unciv Battle.triggerLosingHPUniques: "upon losing at least [n] HP in a single attack"
    private func triggerLosingHPUniques(_ attacker: Combatant, _ attackerDamageDealt: Int, _ defender: Combatant, _ defenderDamageDealt: Int) {
        if let au = cUnit(attacker) {
            triggerUnitConditionalUniques(unit: au, targetUnitId: defender.unitId, triggerText: "due to losing [\(defenderDamageDealt)] HP") {
                $0.pattern == "upon losing at least [] HP in a single attack" && $0.int(0) <= defenderDamageDealt
            }
        }
        if let du = cUnit(defender) {
            triggerUnitConditionalUniques(unit: du, targetUnitId: attacker.unitId, triggerText: "due to losing [\(attackerDamageDealt)] HP") {
                $0.pattern == "upon losing at least [] HP in a single attack" && $0.int(0) <= attackerDamageDealt
            }
        }
    }

    /// Unciv Battle.plunderFromDamage: "Earn [n]% of the damage done to [filter] units as [resource]". Stockpiled
    /// and other non-stat resources are rounded and paid one by one; the stats are summed (as Floats) and paid
    /// truncated, in Stat order, after the loop.
    private func plunderFromDamage(_ plunderingUnit: Combatant, _ plunderedUnit: Combatant, damageDealt: Int) {
        guard plunderingUnit.isMapUnitCombatant, let pu = cUnit(plunderingUnit) else { return }
        let civId = pu.civId
        var plunderedGoods: [String: Float] = [:]
        let plunderedName = cName(plunderedUnit), plunderedIcon = plunderedUnit.isCity ? "City" : plunderedName
        for unique in unitMatchingUniques(pu, "Earn []% of the damage done to [] units as []", nil, checkCivInfoUniques: true) {
            guard cMatchesFilter(plunderedUnit, unique.param(1)) else { continue }
            let percentage = Float(unique.double(0))
            let amount = percentage / 100 * Float(damageDealt)
            let resourceName = unique.param(2)
            guard isGameResource(resourceName) else { continue }
            if isStatName(resourceName) {
                plunderedGoods[resourceName, default: 0] += amount
                continue   // Notification and adding to the civ happens all at once for stats further down
            }
            let plunderedAmount = Stats.roundToInt(Double(amount))
            addGameResource(civId, resourceName, plunderedAmount)
            // Unciv: `if (resource is SubStat) resource.icon else "ResourceIcons/$resourceName"` - a sub-stat's
            // NotificationIcon (Golden Age points: Happiness, Stored Food: Food), a tile resource's folder path
            let resourceIcon = resourceName == "Golden Age points" ? "StatIcons/Happiness" : resourceName == "Stored Food" ? "StatIcons/Food" : "ResourceIcons/" + resourceName
            notify(civId, "\(cNotificationDisplay(plunderingUnit, "Your ")) plundered [\(plunderedAmount)] [\(resourceName)] from [\(plunderedName)]",
                   category: .War, icons: [pu.name, "War", resourceIcon, plunderedIcon], coord: cCoord(plunderedUnit))
        }
        for stat in ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith"] {
            guard let value = plunderedGoods[stat] else { continue }
            let plunderedAmount = Int(value)
            if plunderedAmount == 0 { continue }
            addGameResource(civId, stat, plunderedAmount)
            notify(civId, "\(cNotificationDisplay(plunderingUnit, "your ")) plundered [\(plunderedAmount)] [\(stat)] from [\(plunderedName)]",
                   category: .War, icons: [pu.name, "War", "StatIcons/" + stat, plunderedIcon], coord: cCoord(plunderedUnit))
        }
    }

    /// Unciv Battle.postBattleNotifications, sent to the defender's civ. A captured civilian is announced by
    /// captureCivilianUnit instead.
    func postBattleNotifications(_ attacker: Combatant, _ defender: Combatant, attackedTile: HexCoord, attackerTile: HexCoord? = nil, damageDealt: DamageDealt? = nil) {
        let defenderCiv = cCivId(defender)
        guard cCivId(attacker) != defenderCiv else { return }
        let (battleActionIcon, battleActionString): (String, String)
        if !attacker.isCity && cIsDefeated(attacker) { (battleActionIcon, battleActionString) = ("War", "was destroyed while attacking") }
        else if !cIsDefeated(defender) { (battleActionIcon, battleActionString) = ("War", "has attacked") }
        else if defender.isCity && cIsMelee(attacker) && civ(cCivId(attacker))?.isBarbarian == true { (battleActionIcon, battleActionString) = ("War", "has raided") }
        else if defender.isCity && cIsMelee(attacker) { (battleActionIcon, battleActionString) = ("War", "has captured") }
        else { (battleActionIcon, battleActionString) = ("Death", "has destroyed") }
        let attackerString = attacker.isCity ? "Enemy city [\(cName(attacker))]" : "An enemy [\(cName(attacker))]"
        let defenderString: String
        if defender.isCity { defenderString = cIsDefeated(defender) && cIsRanged(attacker) ? " the defence of [\(cName(defender))]" : " [\(cName(defender))]" }
        else { defenderString = cNotificationDisplay(defender, "our ") }
        let attackerHurtString = damageDealt.map { $0.defenderDealt != 0 ? " ([-\($0.defenderDealt)] HP)" : "" } ?? ""
        let defenderHurtString = damageDealt.map { " ([-\($0.attackerDealt)] HP)" } ?? ""
        let notificationString = "\(attackerString)\(attackerHurtString) \(battleActionString) \(defenderString)\(defenderHurtString)"
        let attackerIcon = attacker.isCity ? "City" : cName(attacker)
        let defenderIcon = defender.isCity ? "City" : cName(defender)
        let actions: [NotificationAction] = attackerTile.map { [.location(attackedTile), .location($0)] } ?? [.location(attackedTile)]
        notify(defenderCiv, notificationString, category: .War, icons: [attackerIcon, battleActionIcon, defenderIcon], actions: actions, coord: attackedTile)
    }

    /// Unciv Battle.tryHealAfterKilling: "Heals [n] damage if it kills a unit", the unit's and its civ's
    private func tryHealAfterKilling(_ attacker: Combatant) {
        guard attacker.isMapUnitCombatant, let u = cUnit(attacker) else { return }
        for unique in unitMatchingUniques(u, "Heals [] damage if it kills a unit", nil, checkCivInfoUniques: true) { unitHealBy(u.id, unique.int(0)) }
    }

    /// Unciv Battle.postBattleMoveToAttackedTile: a melee unit that defeated (or captured) what it attacked moves
    /// in, if it still can reach and enter the tile, without zone of control.
    private func postBattleMoveToAttackedTile(_ attacker: Combatant, _ defender: Combatant, attackedTile: HexCoord) {
        guard cIsMelee(attacker) else { return }
        guard cIsDefeated(defender) || cCivId(defender) == cCivId(attacker) else { return }
        guard attacker.isMapUnitCombatant, let aid = attacker.unitId, let au = unit(aid) else { return }
        if unitCannotMove(au) { return }
        // Example: If the unit we attacked made us lose movement points
        guard canReachInCurrentTurn(au, attackedTile) else { return }
        // This is so that if we attack e.g. a barbarian in enemy territory that we can't enter, we won't enter it
        guard canMoveTo(au, attackedTile) else { return }
        // Units moving in after a kill are not affected by zone of control
        moveToTile(aid, attackedTile, considerZOC: false)
        if let i = unitIndex(aid) { units[i].mostRecentMoveType = "UnitAttacked" }
    }

    /// Unciv Battle.postBattleAddXp: air 4/2, ranged 3/2 against a city and 2/2 otherwise, melee 5/4 unless the
    /// defender was a civilian (captured units grant none).
    private func postBattleAddXp(_ attacker: Combatant, _ defender: Combatant) {
        func addBoth(_ attackerXp: Int, _ defenderXp: Int) {
            addXp(attacker, attackerXp, defender)
            addXp(defender, defenderXp, attacker)
        }
        if cIsAirUnit(attacker) { addBoth(4, 2) }
        else if cIsRanged(attacker) { if defender.isCity { addBoth(3, 2) } else { addBoth(2, 2) } }
        else if !cIsCivilian(defender) { addBoth(5, 4) }
    }

    /// Unciv Battle.addXp: flat and percentage XP uniques, the barbarian cap, great general points for major civs
    /// (a destroyed unit still earns them), and "can be promoted" when the unit just crossed the line.
    func addXp(_ thisCombatant: Combatant, _ amount: Int, _ otherCombatant: Combatant) {
        guard thisCombatant.isMapUnitCombatant, let id = thisCombatant.unitId, var u = cUnit(thisCombatant) else { return }
        let alive = unitIndex(id) != nil
        if alive, let i = unitIndex(id) { migratePromotionState(i); u = units[i] }
        let civId = u.civId
        let otherIsBarbarian = civ(cCivId(otherCombatant))?.isBarbarian == true
        if otherIsBarbarian && u.totalXpProduced >= rs.constants.maxXPfromBarbarians { return }
        // Unciv asks the unit itself, alive or not: a barbarian removed by its raid (Battle.handleCityDefeated's unit.destroy(),
        // health untouched) still earns its XP and is told it can be promoted
        let unitCouldAlreadyPromote = promotionsAvailable(u) > 0 && !availablePromotions(for: u).isEmpty
        // GameContext(civInfo = civ, ourCombatant = thisCombatant, theirCombatant = otherCombatant)
        var ctx = combatContext(thisCombatant, otherCombatant, attackedTile: nil, action: nil)
        ctx.tile = nil
        let baseXP = amount + unitMatchingUniques(u, "[] XP gained from combat", ctx, checkCivInfoUniques: true).reduce(0) { $0 + $1.int(0) }
        let xpBonus = unitMatchingUniques(u, "[]% XP gained from combat", ctx, checkCivInfoUniques: true).reduce(0.0) { $0 + $1.double(0) }
        let xpModifier = 1.0 + xpBonus / 100
        let xpGained = Int(Double(baseXP) * xpModifier)
        if alive, let i = unitIndex(id) { units[i].xp += xpGained } else { battleGraveyard[id]?.xp += xpGained }

        if !otherIsBarbarian, let ci = civIndex(civId), civs[ci].isMajor {   // Can't get great generals from Barbarians
            let nation = civs[ci].nation
            for name in rs.unitOrder {
                guard let gp = rs.units[name], gp.greatPersonType != nil else { continue }
                // only great generals this civ may have: not another nation's unique, not replaced by our own unique unit
                if let owner = gp.uniqueTo, owner != nation { continue }
                if rs.units.values.contains(where: { $0.uniqueTo == nation && $0.replaces == gp.name }) { continue }
                guard gp.uniqueObjects.contains(where: { $0.pattern == "Can be earned through combat" && conditionalsHold($0, ctx) }) else { continue }
                let greatGeneralPointsBonus = unitMatchingUniques(u, "[] is earned []% faster", ctx, checkCivInfoUniques: true)
                    .filter { $0.param(0) == gp.name || $0.param(0) == gp.replaces || $0.param(0) == "Great Person" }
                    .reduce(0.0) { $0 + $1.double(1) }
                let greatGeneralPointsModifier = 1.0 + greatGeneralPointsBonus / 100
                let greatGeneralPointsGained = Int(Double(xpGained) * greatGeneralPointsModifier)
                let now = (civs[ci].greatGeneralPoints[gp.name] ?? 0) + greatGeneralPointsGained
                if now == 0 { civs[ci].greatGeneralPoints[gp.name] = nil; civs[ci].greatGeneralOrder.removeAll { $0 == gp.name } }   // a Counter drops a zero
                else {
                    if civs[ci].greatGeneralPoints[gp.name] == nil { civs[ci].greatGeneralOrder.append(gp.name) }
                    civs[ci].greatGeneralPoints[gp.name] = now
                }
            }
        }

        // MapUnitCombatant.isDefeated is health <= 0, so a unit taken off the map with its health left (the raider) counts
        if !cIsDefeated(thisCombatant), !unitCouldAlreadyPromote, let v = (unitIndex(id).map { units[$0] } ?? battleGraveyard[id]),
           promotionsAvailable(v) > 0, !availablePromotions(for: v).isEmpty {
            notify(v.civId, "[\(uncivDisplayName(v))] can be promoted!", category: .Units, icons: [v.name], actions: [.unit(v.coord, v.id), .promoteUnit(v.customName ?? v.name, v.coord, v.id)])
        }
    }

    /// Unciv Battle.reduceAttackerMovementPointsAndAttacks: a city only marks that it attacked; a unit counts the
    /// attack and spends a movement point (all of them when it has no attacks left and cannot move after
    /// attacking) - unless it captured a civilian by stepping onto it, which is not an attack.
    private func reduceAttackerMovementPointsAndAttacks(_ attacker: Combatant, _ defender: Combatant, attackedTile: HexCoord) {
        guard attacker.isMapUnitCombatant else {
            if let cid = attacker.cityId, let ci = cityIndex(cid) { cities[ci].attackedThisTurn = true }   // Unciv City.attackedThisTurn
            return
        }
        guard let id = attacker.unitId, let i0 = unitIndex(id) else { return }
        // If captured this civilian, doesn't count as attack, and we've used a movement already
        if cIsCivilian(defender) && units[i0].coord == cCoord(defender) { return }
        let ctx = combatContext(attacker, defender, attackedTile: attackedTile, action: "Attack")
        units[i0].attacksThisTurn += 1
        let u = units[i0]
        if unitHasUnique(u, "Can move after attacking", ctx) || 1 + extraAttacks(of: u) > u.attacksThisTurn {
            // a melee unit that won already paid for moving onto the tile, and an air unit only has 1 movement anyway
            if !u.def.isAir && !(cIsMelee(attacker) && cIsDefeated(defender)) { useMovementPoints(id, 1) }
        } else { units[i0].movementLeft = 0 }
        guard let i = unitIndex(id) else { return }
        switch units[i].order {
        case .fortify, .fortifyUntilHealed, .sleep, .sleepUntilHealed, .guardPost: units[i].order = .none   // but not Set Up
        default: break
        }
    }

    // MARK: - conquest

    /// Unciv Battle.conquerCity: the units on the city tile (the garrison and the aircraft destroyed, a civilian
    /// captured), the capture plunder from the city's stats as they stood, then the city changes hands - retaken
    /// capital annexed, a human asked, the AI deciding - and "upon conquering a city".
    private func conquerCity(_ cityId: Int, _ attacker: Combatant) {
        guard let city0 = city(cityId), let au = cUnit(attacker) else { return }
        let attackerCiv = au.civId
        notify(attackerCiv, "We have conquered the city of [\(city0.name)]!", category: .War, icons: ["War"], coord: city0.coord)   // Unciv: first thing
        // Unciv: `city.hasJustBeenConquered = true` - until moveToCiv it lets the conqueror's units in (the city centre's
        // captured civilian stays put: settled turn 146, Japan's new Worker in Adrianople) and keeps other attackers off it.
        if let ci = cityIndex(cityId) { cities[ci].hasJustBeenConquered = true }
        let center = city0.coord
        if let military = militaryUnitOn(center) { destroyUnit(military.id) }
        if let civilian = civilianUnitOn(center), civilian.civId != attackerCiv { captureCivilianUnit(attacker, .unit(civilian.id), checkDefeat: false) }
        for airUnit in units(at: center) where airUnit.def.isAir { destroyUnit(airUnit.id) }

        // GameContext(civInfo = attackerCiv, city = city, unit = attacker.unit, ourCombatant = attacker, attackedTile = center)
        let ctx = UniqueContext(civId: attackerCiv, city: city0, unit: au, attackedTile: map[center])
        let cityStats = currentCityStats(cityId).total   // city.cityStats.currentCityStats - still the loser's
        for unique in unitMatchingUniques(au, "Upon capturing a city, receive [] times its [] production as [] immediately", ctx, checkCivInfoUniques: true) {
            guard isGameResource(unique.param(2)) else { continue }
            let stat: Double
            switch unique.param(1) {
            case "Production": stat = cityStats.production
            case "Food": stat = cityStats.food
            case "Gold": stat = cityStats.gold
            case "Science": stat = cityStats.science
            case "Culture": stat = cityStats.culture
            case "Happiness": stat = cityStats.happiness
            case "Faith": stat = cityStats.faith
            default: continue
            }
            addGameResource(attackerCiv, unique.param(2), unique.int(0) * Int(Float(stat)))
        }

        if civ(attackerCiv)?.isBarbarian == true || isOneCityChallenger(attackerCiv) {
            destroyCity(cityId: cityId, overrideSafeties: true)   // Unciv: city.destroyCity(true) - capitals and holy cities too
            // and no destroyIfDefeated on this path: a civ whose last city that was is defeated from now on (Unciv computes
            // isDefeated - `hasEverOwnedOriginalCapital -> cities.isEmpty()`), its units left standing and never moved again,
            // no "destroyed" notification; our stored flag follows at once (getKnownCivs, the walk, automateTurn read it)
            refreshDefeatedFlags()
            return
        }

        // puppetCity (+ annexCity for our old capital) / the human's popup / automateCityConquer, then the
        // "upon conquering a city" triggers (CityConquestFunctions.swift)
        conquerCityDecision(cityId: cityId, by: attackerCiv, attackerUnitId: au.id)
    }

    /// Unciv Civilization.isOneCityChallenger: a human in a One City Challenge
    func isOneCityChallenger(_ civId: Int) -> Bool { settings.oneCityChallenge && civ(civId)?.isPlayer == true }

    /// Unciv Battle.destroyIfDefeated
    func destroyIfDefeated(_ attackedCiv: Int, attacker: Int, at location: HexCoord? = nil) {
        guard let c = civ(attackedCiv), c.isAlive, isDefeated(c) else { return }
        eliminate(civId: attackedCiv, by: attacker, at: location)   // cityStateDestroyed, destroy, the Defeated popup
    }

    // MARK: - withdrawal

    /// Unciv Battle.hasWithdrawnFromMelee
    private func hasWithdrawnFromMelee(_ attacker: Combatant, _ defender: Combatant, attackedTile: HexCoord) -> Bool {
        guard attacker.isMapUnitCombatant, cIsMelee(attacker), defender.isMapUnitCombatant, let du = cUnit(defender), let au = cUnit(attacker) else { return false }
        // GameContext(civInfo = defender civ, ourCombatant = defender, theirCombatant = attacker, tile = attackedTile):
        // named arguments, so no attacked tile, no combat action and no other civ
        let ctx = UniqueContext(civId: du.civId, unit: du, tile: map[attackedTile], opponentUnit: au)
        return unitHasUnique(du, "Withdraws before melee combat", ctx) && doWithdrawFromMeleeAbility(attacker, defender)
    }

    /// Unciv Battle.doWithdrawFromMeleeAbility: a free step to a neighbour away from the attacker (else one beside
    /// it), picked by the state-based random; the attack still counts.
    private func doWithdrawFromMeleeAbility(_ attacker: Combatant, _ defender: Combatant) -> Bool {
        guard let du = cUnit(defender), let did = defender.unitId else { return false }
        if isEmbarked(du) { return false }
        if unitCannotMove(du) { return false }
        if isEscorting(du) { return false }   // running away and leaving the escorted unit defeats the purpose of escorting
        if isGuarding(du) { return false }    // guarding this post and will fight to the death!
        let fromTile = du.coord
        let attackerTile = cCoord(attacker)
        var rng = stateBasedRandom("Battle.doWithdrawFromMeleeAbility", combatContext(attacker, defender, attackedTile: fromTile, action: "Defend"))
        func canNotWithdrawTo(_ c: HexCoord) -> Bool {
            guard let t = map[c] else { return true }
            return !canMoveTo(du, c)
                || du.def.isLand && !t.isLand   // forbid retreat from land to sea - embarked already excluded
                || t.isCityCenter && t.ownerCivId != du.civId   // forbid retreat into a city which doesn't belong to the defender
        }
        let attackerRing = map.neighbors(of: attackerTile)
        let ring = map.neighbors(of: fromTile)
        let firstCandidateTiles = ring.filter { !($0 == attackerTile || attackerRing.contains($0)) }.filter { !canNotWithdrawTo($0) }
        let secondCandidateTiles = ring.filter { attackerRing.contains($0) }.filter { !canNotWithdrawTo($0) }
        let toTile: HexCoord
        if let t = rng.pick(firstCandidateTiles) { toTile = t }
        else if let t = rng.pick(secondCandidateTiles) { toTile = t }
        else { return false }
        // Withdraw success: a free teleport, not a move - removeFromTile, putInTile(toTile)
        guard let di = unitIndex(did) else { return false }
        let evFrom = units[di].coord
        units[di].coord = toTile
        if GameState.evlogOn { evUnitMove(did, from: evFrom) }   // EVLOG: UNIT_MOVE (putInTile)
        // putInTile ends in moveThroughTile: the entering-tile triggers, the camp, the ruins, an unguarded enemy
        // civilian captured, the terrain promotions, and updateVisibleTiles last (as moveToTile and paradrop do)
        moveThroughTile(did, toTile)   // its updateVisibleTiles is the only view update of the withdrawal (Battle.kt:813-815)
        // Unciv sets it on the same MapUnit object; the ruins may have replaced or moved ours in the list, so look it up again
        if let dj = unitIndex(did) { units[dj].mostRecentMoveType = "UnitWithdrew" }
        // and count 1 attack for attacker but leave it in place
        reduceAttackerMovementPointsAndAttacks(attacker, defender, attackedTile: fromTile)
        let attackerName = cName(attacker), defenderName = du.name
        let notificationString = "[\(defenderName)] withdrew from a [\(attackerName)]"
        let actions: [NotificationAction] = [.location(toTile), .location(cCoord(attacker))]
        notify(du.civId, notificationString, category: .War, icons: [defenderName, "War", attackerName], actions: actions, coord: toTile)
        notify(cCivId(attacker), notificationString, category: .War, icons: [defenderName, "War", attackerName], actions: actions, coord: toTile)
        return true
    }

    /// Unciv Battle.doDestroyImprovementsAbility
    private func doDestroyImprovementsAbility(_ attacker: Combatant, attackedTile: HexCoord, _ defender: Combatant) {
        guard let au = cUnit(attacker), let imp = map[attackedTile]?.improvement, let def = rs.improvements[imp] else { return }
        var ctx = combatContext(attacker, defender, attackedTile: attackedTile, action: "Attack")
        ctx.tile = nil
        if !def.uniques.contains("Unpillagable") && unitHasUnique(au, "Destroys tile improvements when attacking", ctx) {
            map.update(attackedTile) { $0.improvement = nil; $0.pillaged = false }
            notify(cCivId(defender), "An enemy [\(au.name)] has destroyed our tile improvement [\(imp)]", category: .War, icons: [au.name, "War"],
                   actions: [.location(attackedTile), .location(au.coord)])
        }
    }

    // MARK: - extra ranged attack

    /// Unciv Battle.tryExtraRangedAttack: each stand-in fires before the main exchange, at a non-civilian unit
    private func tryExtraRangedAttack(_ attacker: Combatant, _ defender: Combatant, attackedTile: HexCoord) -> DamageDealt {
        guard attacker.isMapUnitCombatant, defender.isMapUnitCombatant, !cIsCivilian(defender) else { return .none }
        var damageDealt = DamageDealt.none
        for fakeAttacker in getExtraRangedAttackFakeUnits(attacker) { damageDealt = damageDealt + takeDamage(fakeAttacker, defender) }
        return damageDealt
    }

    /// Unciv Battle.getExtraRangedAttackFakeUnits: one stand-in per "Before engaging in combat performs an extra
    /// ranged attack with [n]% of melee combat strength", with (strength × n / 100).toInt() ranged strength
    func getExtraRangedAttackFakeUnits(_ attacker: Combatant) -> [Combatant] {
        guard attacker.isMapUnitCombatant, let u = cUnit(attacker) else { return [] }
        return unitMatchingUniques(u, "Before engaging in combat performs an extra ranged attack with []% of melee combat strength").map { unique in
            .fakeRanged(unitId: u.id, baseRangedStrength: Int(Float(u.def.strength) * Float(unique.double(0)) / 100))
        }
    }

    // MARK: - notifications

    /// Unciv `notifications.remove(notifications.firstOrNull { it.text == text })`
    func removeFirstNotification(civId: Int, text: String) {
        guard let ci = civIndex(civId), let idx = civs[ci].notifications.firstIndex(of: text) else { return }
        civs[ci].notifications.remove(at: idx)
        if idx < civs[ci].notificationCoords.count { civs[ci].notificationCoords.remove(at: idx) }
        if idx < civs[ci].notificationMeta.count { civs[ci].notificationMeta.remove(at: idx) }
    }
    /// Unciv `notifications.removeAll { it.text == text }`
    func removeAllNotifications(civId: Int, text: String) {
        while let ci = civIndex(civId), civs[ci].notifications.contains(text) { removeFirstNotification(civId: civId, text: text) }
    }
}
