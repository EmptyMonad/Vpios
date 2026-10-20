// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/AirInterception.kt`: interception of an air attack, and the air sweep that clears the way for one.
extension GameState {
    /// Unciv MapUnit.interceptChance: the unit's "[]% chance to intercept air attacks" summed (getMatchingUniques:
    /// conditionals judged in the unit's own state - we summed them unconditionally)
    func interceptChance(_ u: Unit) -> Double { Double(unitMatchingUniques(u, "[]% chance to intercept air attacks").reduce(0) { $0 + $1.int(0) }) }

    /// Unciv MapUnit.canIntercept(): a chance above zero, an air unit needs movement, and interceptions left this
    /// turn - attacksThisTurn < 1 + "[] extra interceptions may be made per turn"
    func canInterceptAtAll(_ u: Unit) -> Bool {
        guard interceptChance(u) > 0 else { return false }
        if u.def.isAir && !u.hasMovement { return false }
        let maxAttacks = 1 + unitMatchingUniques(u, "[] extra interceptions may be made per turn").reduce(0) { $0 + $1.int(0) }
        return u.attacksThisTurn < maxAttacks
    }

    /// Unciv MapUnit.canIntercept(tile): canIntercept(), then the tile within getInterceptionRange() - interceptRange
    /// plus "[] Air Interception Range" (checkCivInfoUniques = true)
    func canIntercept(_ u: Unit, _ target: HexCoord) -> Bool {
        guard u.health > 0, canInterceptAtAll(u) else { return false }
        return u.coord.distance(to: target) <= interceptionRange(u)
    }
    /// Unciv MapUnit.getInterceptionRange
    func interceptionRange(_ u: Unit) -> Int {
        u.def.interceptRange + unitMatchingUniques(u, "[] Air Interception Range", checkCivInfoUniques: true).reduce(0) { $0 + $1.int(0) }
    }

    /// Units of civs at war with the attacker able to intercept an attack on `target`.
    func interceptors(against attacker: Unit, at target: HexCoord) -> [Unit] {
        units.filter { $0.civId != attacker.civId && areAtWar(attacker.civId, $0.civId) && canIntercept($0, target) }
    }

    /// Unciv AirInterception.tryInterceptAirAttack: the interceptor of `interceptingCiv` with the best chance - the
    /// first of equals in the civ's unit order, not the defender itself, not barred from intercepting this attacker -
    /// takes its shot (which counts even on a miss); a hit deals a normal battle hit to the attacker, scaled by the
    /// interception uniques, and earns 2 XP.
    func tryInterceptAirAttack(_ attacker: Combatant, attackedTile: HexCoord, interceptingCiv: Int, defender: Combatant?) -> DamageDealt {
        guard let au = cUnit(attacker), let aid = attacker.unitId else { return .none }
        let attackContext = combatContext(attacker, defender, attackedTile: attackedTile, action: "Intercept")
        if unitHasUnique(au, "Cannot be intercepted", attackContext) || au.def.cannotBeIntercepted { return .none }
        var rng = stateBasedRandom("AirInterception.tryInterceptAirAttack", attackContext)
        let candidates = units(of: interceptingCiv).filter { canIntercept($0, attackedTile) }
            .enumerated()   // sortedByDescending is stable: equal chances keep the civ's unit order
            .sorted { interceptChance($0.element) != interceptChance($1.element) ? interceptChance($0.element) > interceptChance($1.element) : $0.offset < $1.offset }
            .map { $0.element }
        let interceptor = candidates.first { u in
            // Can't intercept if we have a unique preventing it
            let state = UniqueContext(civId: interceptingCiv, unit: u, attackedTile: map[attackedTile], opponentUnit: au, combatAction: "Intercept")
            let barred = unitMatchingUniques(u, "Cannot intercept [] units", state).contains { cMatchesFilter(attacker, $0.param(0)) }
            // Defender can't intercept either
            return !barred && u.id != defender?.unitId
        }
        guard let interceptor, let ii = unitIndex(interceptor.id) else { return .none }
        units[ii].attacksThisTurn += 1   // even if you miss, you took the shot (Unciv counts interceptions in attacksThisTurn)
        // Does Intercept happen? If not, exit
        let roll = rng.nextFloat()
        if epochsBtlDbg {
            let ip = uncivPosition(interceptor.coord)
            print("BTL t=\(uncivTurns) ICPT \(civ(interceptor.civId)?.nation ?? "-"):\(interceptor.name)@\(ip.x),\(ip.y):\(interceptor.health) chance=\(Float(interceptChance(interceptor))) roll=\(roll) cands=" + units(of: interceptingCiv).filter { canIntercept($0, attackedTile) }.map { "\($0.name)@\(uncivPosition($0.coord).x),\(uncivPosition($0.coord).y)" }.joined(separator: ","))
        }
        if roll > Float(interceptChance(interceptor)) / 100 { return .none }

        var damage = calculateDamageToDefender(.unit(interceptor.id), attacker)
        // Unciv interceptDamagePercentBonus / receivedInterceptDamageFactor: getMatchingUniques / forEachMatchingUnique
        var damageFactor = 1 + Float(unitMatchingUniques(interceptor, "[]% Damage when intercepting").reduce(0) { $0 + $1.int(0) }) / 100
        var received: Float = 1
        for u in unitMatchingUniques(au, "Damage taken from interception reduced by []%") { received *= 1 - Float(u.double(0)) / 100 }
        damageFactor *= max(0, received)
        damage = min(Int(Float(damage) * damageFactor), au.health)
        if epochsBtlDbg { print("BTL t=\(uncivTurns) ICPTDMG \(damage) factor=\(damageFactor)") }
        cTakeDamage(attacker, damage)
        if damage > 0 { addXp(.unit(interceptor.id), 2, attacker) }
        addInterceptionNotifications(attacker, interceptor, damage: damage)
        _ = aid
        return DamageDealt(attackerDealt: 0, defenderDealt: damage)
    }

    /// The nuke's interception (Nuke.declareWarOnHitCivs): no defender. Returns the damage dealt to the attacker.
    @discardableResult
    func tryInterceptAirAttack(attackerId: Int, target: HexCoord, interceptingCiv: Int, defenderId: Int? = nil) -> Int {
        tryInterceptAirAttack(.unit(attackerId), attackedTile: target, interceptingCiv: interceptingCiv, defender: defenderId.map { .unit($0) }).defenderDealt
    }

    /// Unciv AirInterception.addInterceptionNotifications
    private func addInterceptionNotifications(_ attacker: Combatant, _ interceptor: Unit, damage: Int) {
        let attackerName = cName(attacker), interceptorName = interceptor.name
        let attackerCiv = cCivId(attacker)
        let attackerText: String
        if !cIsDefeated(attacker) { attackerText = "Our [\(attackerName)] ([-\(damage)] HP) was attacked by an intercepting [\(interceptorName)] ([-0] HP)" }
        else if visibleTiles(for: attackerCiv).contains(interceptor.coord) { attackerText = "Our [\(attackerName)] ([-\(damage)] HP) was destroyed by an intercepting [\(interceptorName)] ([-0] HP)" }
        else { attackerText = "Our [\(attackerName)] ([-\(damage)] HP) was destroyed by an unknown interceptor" }
        notify(attackerCiv, attackerText, category: .War, icons: [attackerName, "War", interceptorName], coord: interceptor.coord)
        let interceptorText = cIsDefeated(attacker)
            ? "Our [\(interceptorName)] ([-0] HP) intercepted and destroyed an enemy [\(attackerName)] ([-\(damage)] HP)"
            : "Our [\(interceptorName)] ([-0] HP) intercepted and attacked an enemy [\(attackerName)] ([-\(damage)] HP)"
        notify(interceptor.civId, interceptorText, category: .War, icons: [interceptorName, "War", attackerName], actions: [.location(interceptor.coord), .location(cCoord(attacker))])
    }

    /// Air Sweep: a fighter provokes interceptors over a tile and fights them in the air, clearing the way for bombers.
    func canAirSweep(_ unit: Unit, _ target: HexCoord) -> Bool {
        unit.def.isAir && unit.def.canAirSweep && unit.movementLeft > 0 && unit.attacksThisTurn < 1 + extraAttacks(of: unit) && unit.coord.distance(to: target) <= airRange(unit)
    }

    /// Unciv AirInterception.airSweep: counts as an attack; every interceptor of a civ at war draws out (air units
    /// first, a random civ, the best chance); a ground interceptor only takes its shot, an air interceptor fights a
    /// full Battle.takeDamage exchange, 5 XP to both.
    /// `preparing`: the unit's action is AirSweep (Unciv MapUnit.isPreparingAirSweep) - set only by the player's Air
    /// Sweep button. The AI calls AirInterception.airSweep straight from AirUnitAutomation.tryAirSweep without it, so
    /// its sweeps fight without the "[]% Strength when performing Air Sweep" bonus (BattleDamage.getAttackModifiers).
    @discardableResult
    func airSweep(unitId: Int, target: HexCoord, preparing: Bool = false) -> String {
        guard let ai = unitIndex(unitId), canAirSweep(units[ai], target) else { return "" }
        let attacker: Combatant = .unit(unitId)
        if epochsBtlDbg { print("BTL t=\(uncivTurns) SWEEP \(btlC(attacker)) -> \(uncivPosition(target).x),\(uncivPosition(target).y)") }
        // Air Sweep counts as an attack, even if nothing else happens
        units[ai].attacksThisTurn += 1
        let sweeper = units[ai]
        if unitHasUnique(sweeper, "Can move after attacking") || 1 + extraAttacks(of: sweeper) > sweeper.attacksThisTurn {
            if !sweeper.def.isAir { useMovementPoints(unitId, 1) }
        } else { units[ai].movementLeft = 0 }
        let attackerName = sweeper.name
        // Every civ at war with us, in the game's order, and its units that can intercept here
        var potentialInterceptors: [Unit] = []
        for other in civs where areAtWar(sweeper.civId, other.id) {
            potentialInterceptors += units(of: other.id).filter { canIntercept($0, target) }
        }
        // first priority, only Air Units
        if potentialInterceptors.contains(where: { $0.def.isAir }) { potentialInterceptors = potentialInterceptors.filter { $0.def.isAir } }
        // Pick highest chance interceptor. Unciv shuffles the Sequence with an UNSEEDED Random (its own game is not
        // repeatable there); the measurement build seeds it like BattleUnitCapture's prize ships -
        // `Random((gameInfo.turns * attackedTile.position.toVector2().hashCode()).toLong())`, Int product then toLong -
        // and so does this. Kotlin's Sequence.shuffled(random) draws `j = nextInt(size)` and swaps in the last element,
        // yielding one element per draw (not List.shuffle's Fisher-Yates from the end).
        // NOSHUFFLE (hunting only): skip the shuffle entirely.
        var sweepRng = SeededRandom(kotlinSeedLong: Int64(Int32(truncatingIfNeeded: uncivTurns) &* uncivPositionVector2Hash(target)))
        func kotlinSequenceShuffled(_ a: [Unit]) -> [Unit] {
            var buffer = a; var out: [Unit] = []
            while !buffer.isEmpty {
                let j = Int(sweepRng.nextInt(until: Int32(buffer.count)))
                let last = buffer.removeLast()
                if j < buffer.count { out.append(buffer[j]); buffer[j] = last } else { out.append(last) }
            }
            return out
        }
        let shuffledOrder = epochsNoShuffle ? potentialInterceptors : kotlinSequenceShuffled(potentialInterceptors)
        if epochsBtlDbg {
            func names(_ l: [Unit]) -> String { l.map { "\($0.name)@\(uncivPosition($0.coord).x),\(uncivPosition($0.coord).y)" }.joined(separator: ",") }
            print("BTL t=\(uncivTurns) SWEEPORDER seed=\(Int64(Int32(truncatingIfNeeded: uncivTurns) &* uncivPositionVector2Hash(target))) in=\(names(potentialInterceptors)) out=\(names(shuffledOrder))")
        }
        let ordered = shuffledOrder.enumerated()
            .sorted { interceptChance($0.element) != interceptChance($1.element) ? interceptChance($0.element) > interceptChance($1.element) : $0.offset < $1.offset }
            .map { $0.element }
        guard let interceptor = ordered.first, let di = unitIndex(interceptor.id) else {
            notify(sweeper.civId, "Nothing tried to intercept our [\(attackerName)]", category: .War, icons: [attackerName])
            // Unciv: `attacker.unit.action = null` - MapUnit.automated (our .automate) stays
            if let a2 = unitIndex(unitId), units[a2].order != .automate { units[a2].order = .none }
            return "Air sweep found no interceptors."
        }
        let locations: [NotificationAction] = [.location(interceptor.coord), .location(sweeper.coord)]
        units[di].attacksThisTurn += 1   // even if you miss, you took the shot
        let interceptorName = interceptor.name
        if !interceptor.def.isAir {
            // Deal no damage (moddable in future?) and no XP
            notify(sweeper.civId, "Our [\(attackerName)] ([-0] HP) was attacked by an intercepting [\(interceptorName)] ([-0] HP)", category: .War, icons: [attackerName, "War", interceptorName], actions: locations)
            notify(interceptor.civId, "Our [\(interceptorName)] ([-0] HP) intercepted and attacked an enemy [\(attackerName)] ([-0] HP)", category: .War, icons: [interceptorName, "War", attackerName], actions: locations)
            if let a2 = unitIndex(unitId), units[a2].order != .automate { units[a2].order = .none }   // action = null; automated stays
            return "\(interceptorName) took a shot at \(attackerName)."
        }
        // Damage if Air v Air should work similar to Melee
        battleGraveyard = [:]
        airSweepingUnitId = preparing ? unitId : nil
        let damageDealt = takeDamage(attacker, .unit(interceptor.id))
        airSweepingUnitId = nil
        // 5 XP to both
        addXp(.unit(interceptor.id), 5, attacker)
        addXp(attacker, 5, .unit(interceptor.id))
        let sweeperDead = cIsDefeated(attacker), interceptorDead = cIsDefeated(.unit(interceptor.id))
        let attackerText: String
        if sweeperDead {
            attackerText = visibleTiles(for: sweeper.civId).contains(interceptor.coord)
                ? "Our [\(attackerName)] ([-\(damageDealt.defenderDealt)] HP) was destroyed by an intercepting [\(interceptorName)] ([-\(damageDealt.attackerDealt)] HP)"
                : "Our [\(attackerName)] ([-\(damageDealt.defenderDealt)] HP) was destroyed by an unknown interceptor"
        } else if interceptorDead {
            attackerText = "Our [\(attackerName)] ([-\(damageDealt.defenderDealt)] HP) destroyed an intercepting [\(interceptorName)] ([-\(damageDealt.attackerDealt)] HP)"
        } else {
            attackerText = "Our [\(attackerName)] ([-\(damageDealt.defenderDealt)] HP) was attacked by an intercepting [\(interceptorName)] ([-\(damageDealt.attackerDealt)] HP)"
        }
        notify(sweeper.civId, attackerText, category: .War, icons: [attackerName, "War", "Question"], actions: [.location(target), .location(sweeper.coord)])
        let interceptorText: String
        if sweeperDead {
            interceptorText = "Our [\(interceptorName)] ([-\(damageDealt.attackerDealt)] HP) intercepted and destroyed an enemy [\(attackerName)] ([-\(damageDealt.defenderDealt)] HP)"
        } else if interceptorDead {
            interceptorText = visibleTiles(for: interceptor.civId).contains(sweeper.coord)
                ? "Our [\(interceptorName)] ([-\(damageDealt.attackerDealt)] HP) intercepted and was destroyed by an enemy [\(attackerName)] ([-\(damageDealt.defenderDealt)] HP)"
                : "Our [\(interceptorName)] ([-\(damageDealt.attackerDealt)] HP) intercepted and was destroyed by an unknown enemy"
        } else {
            interceptorText = "Our [\(interceptorName)] ([-\(damageDealt.attackerDealt)] HP) intercepted and attacked an enemy [\(attackerName)] ([-\(damageDealt.defenderDealt)] HP)"
        }
        notify(interceptor.civId, interceptorText, category: .War, icons: [interceptorName, "War", attackerName], actions: locations)
        if let a2 = unitIndex(unitId), units[a2].order != .automate { units[a2].order = .none }   // action = null; automated stays
        return "\(attackerName) swept \(interceptorName): dealt \(damageDealt.attackerDealt), took \(damageDealt.defenderDealt)"
    }

    /// Unciv Battle.attackOrNuke for an aircraft from the UI: a nuke detonates, anything else attacks.
    @discardableResult
    func airStrike(unitId: Int, target: HexCoord) -> String {
        guard let ai = unitIndex(unitId), airTargets(for: units[ai]).contains(target) else { return "" }
        let attacker = units[ai]
        if let nuke = unitMatchingUniques(attacker, "Nuclear weapon of Strength []").first {
            return detonate(unitId: unitId, at: target, strength: nuke.int(0))
        }
        guard let defender = getMapCombatantOfTile(target), cCivId(defender) != attacker.civId else { return "" }
        let dealt = attack(.unit(unitId), defender)
        var summary = "\(attacker.name) dealt \(dealt.attackerDealt), took \(dealt.defenderDealt)"
        if unit(unitId) == nil { summary += ". \(attacker.name) was lost." }
        return summary
    }
}
