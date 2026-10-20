// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv `Counter<String>`: a LinkedHashMap of named percentages. Adding to a key keeps its place, a key whose
/// value reaches 0 is dropped (and goes to the end if it comes back), `put` overwrites.
struct ModifierCounter {
    private(set) var keys: [String] = []
    private var values: [String: Int] = [:]
    subscript(_ k: String) -> Int { values[k] ?? 0 }
    mutating func put(_ k: String, _ v: Int) {
        if v == 0 {
            if values.removeValue(forKey: k) != nil { keys.removeAll { $0 == k } }
            return
        }
        if values[k] == nil { keys.append(k) }
        values[k] = v
    }
    mutating func add(_ k: String, _ v: Int) { put(k, self[k] + v) }
    mutating func add(_ other: ModifierCounter) { for k in other.keys { add(k, other[k]) } }
    var entries: [(String, Int)] { keys.map { ($0, values[$0]!) } }
    var isEmpty: Bool { keys.isEmpty }
}

/// Mirror of Unciv `logic/battle/BattleDamage.kt`: the modifiers that go into a fight and the damage they produce,
/// in Unciv's number types - the modifiers are Ints summed into a Float bonus, strengths and the damage ratio are
/// Floats, `Float.pow` goes through Double, and the damage is `roundToInt()`.
extension GameState {
    /// Unciv BattleDamage.getModifierStringFromUnique: the name a modifier is filed under (uniques from the same
    /// source add up under one name).
    func modifierString(_ u: Unique) -> String {
        if u.sourceObjectType == nil && u.sourceObjectName == nil { return u.text }
        let source: String
        switch u.sourceObjectType {
        case .unit?: source = "Unit ability"
        case .nation?: source = "National ability"
        case .global?, .globalUniques?: source = u.sourceNameForUser
        default: source = "[\(u.sourceObjectName ?? "")] ([\(u.sourceNameForUser)])"
        }
        // Unciv: `}.tr()` on the source, and `unique.modifiers.joinToString { it.text.tr() }` - each part is
        // translated on its own before "$source - $conditionalsText" is built, so the key is already translated
        // (the battle table's second tr() leaves it as it is).
        let translatedSource = Translations.shared.tr(source)
        if u.conditionals.isEmpty { return translatedSource }
        return translatedSource + " - " + u.conditionals.map { Translations.shared.tr($0.text) }.joined(separator: ", ")
    }

    /// Unciv BattleDamage.getGameContext: `GameContext(civ, city, ourCombatant, theirCombatant, attackedTile,
    /// combatAction)` - the attacked tile is the enemy's when attacking and our own when defending; no unit, no tile.
    func damageContext(_ action: String, _ combatant: Combatant, _ enemy: Combatant) -> UniqueContext {
        let attackedTile = action == "Attack" ? cCoord(enemy) : cCoord(combatant)
        var ctx = combatContext(combatant, enemy, attackedTile: attackedTile, action: action)
        ctx.tile = nil
        return ctx
    }

    /// Unciv BattleDamage.getGeneralModifiers
    func getGeneralModifiers(_ combatant: Combatant, _ enemy: Combatant, action: String, tileToAttackFrom: HexCoord) -> ModifierCounter {
        var modifiers = ModifierCounter()
        let conditionalState = damageContext(action, combatant, enemy)
        let civInfo = civ(cCivId(combatant))
        if combatant.isMapUnitCombatant, let u = cUnit(combatant) {
            modifiers.add(getUnitUniqueModifiers(combatant, u, enemy, conditionalState, tileToAttackFrom: tileToAttackFrom))
            let civResources = resourceCounts(u.civId)
            let requirements = resourceRequirementsPerTurn(requiredResource: u.def.requiredResource, uniques: u.def.uniqueObjects, ctx: UniqueContext(civId: u.civId, unit: u, tile: map[u.coord]))
            for resource in requirements.keys where (civResources[resource] ?? 0) < 0 && civInfo?.isBarbarian != true {
                modifiers.put("Missing resource", Int(BattleConstants.missingResourcesMalus))
            }
            let (greatGeneralName, greatGeneralBonus) = getGreatGeneralBonus(combatant, enemy, action: action)
            if greatGeneralBonus != 0 { modifiers.put(greatGeneralName, greatGeneralBonus) }
        } else if let city = cCity(combatant) {
            for u in cityUniques(city) where u.pattern == "[]% Strength for cities" && conditionalsHold(u, conditionalState) {
                modifiers.add(modifierString(u), u.int(0))
            }
        }
        if civ(cCivId(enemy))?.isBarbarian == true {
            modifiers.put("Difficulty", Int(Float(difficulty.barbarianBonus) * 100))
        }
        return modifiers
    }

    /// Unciv BattleDamage.getUnitUniqueModifiers
    private func getUnitUniqueModifiers(_ combatant: Combatant, _ u: Unit, _ enemy: Combatant, _ conditionalState: UniqueContext, tileToAttackFrom: HexCoord) -> ModifierCounter {
        var modifiers = ModifierCounter()
        for unique in unitMatchingUniques(u, "[]% Strength", conditionalState, checkCivInfoUniques: true) {
            modifiers.add(modifierString(unique), unique.int(0))
        }
        // e.g., Mehal Sefari
        for unique in unitMatchingUniques(u, "[]% Strength decreasing with distance from the capital", conditionalState, checkCivInfoUniques: true) {
            guard !cities(of: u.civId).isEmpty, let capital = cities(of: u.civId).first(where: { $0.isCapital }) else { break }
            let effect = unique.int(0) - 3 * u.coord.distance(to: capital.coord)
            if effect > 0 { modifiers.add(modifierString(unique), effect) }
        }
        let ownTile = u.coord
        let ring = map.neighbors(of: ownTile)
        var adjacentUnits = ring.flatMap { units(at: $0) }
        if !ring.contains(cCoord(enemy)) && ring.contains(tileToAttackFrom) && enemy.isMapUnitCombatant, let eu = cUnit(enemy) { adjacentUnits.append(eu) }
        // e.g., Maori Warrior: the strongest malus by its written parameter (a String comparison), the first of equals
        var strengthMalus: Unique? = nil
        for other in adjacentUnits where areAtWar(other.civId, u.civId) {
            for m in unitMatchingUniques(other, "[]% Strength for enemy [] units in adjacent [] tiles")
            where cMatchesFilter(combatant, m.param(1)) && (map[ownTile].map { tileMatches($0, m.param(2), civId: u.civId) } ?? false) {
                if strengthMalus == nil || m.param(0) > strengthMalus!.param(0) { strengthMalus = m }
            }
        }
        if let malus = strengthMalus { modifiers.add("Adjacent enemy units", malus.int(0)) }
        return modifiers
    }

    /// Unciv BattleDamage.getAttackModifiers
    func getAttackModifiers(_ attacker: Combatant, _ defender: Combatant, tileToAttackFrom: HexCoord) -> ModifierCounter {
        var modifiers = getGeneralModifiers(attacker, defender, action: "Attack", tileToAttackFrom: tileToAttackFrom)
        if attacker.isMapUnitCombatant, let u = cUnit(attacker) {
            modifiers.add(getTerrainAttackModifiers(attacker, u, defender, tileToAttackFrom: tileToAttackFrom))
            // Air unit attacking with Air Sweep
            if airSweepingUnitId == u.id { modifiers.add(getAirSweepAttackModifiers(attacker)) }
            if cIsMelee(attacker) {
                let numberOfOtherAttackersSurroundingDefender = map.neighbors(of: cCoord(defender)).filter { c in
                    guard let m = militaryUnitOn(c) else { return false }
                    return m.id != u.id && m.civId == u.civId && !m.def.isRanged
                }.count
                if numberOfOtherAttackersSurroundingDefender > 0 {
                    var flankingBonus = Float(BattleConstants.baseFlankingBonus)
                    // e.g., Discipline policy
                    for unique in unitMatchingUniques(u, "[]% to Flank Attack bonuses", damageContext("Attack", attacker, defender), checkCivInfoUniques: true) {
                        flankingBonus *= Float(Stats.toPercent(unique.double(0)))
                    }
                    modifiers.put("Flanking", Int(flankingBonus * Float(numberOfOtherAttackersSurroundingDefender)))
                }
            }
        }
        return modifiers
    }

    /// Unciv BattleDamage.getTerrainAttackModifiers
    private func getTerrainAttackModifiers(_ attacker: Combatant, _ u: Unit, _ defender: Combatant, tileToAttackFrom: HexCoord) -> ModifierCounter {
        var modifiers = ModifierCounter()
        guard let attackerTile = map[u.coord], let defenderTile = map[cCoord(defender)] else { return modifiers }
        let acrossCoast = unitHasUnique(u, "Eliminates combat penalty for attacking across a coast")
        if isEmbarked(u) && defenderTile.isLand && !acrossCoast { modifiers.put("Landing", Int(BattleConstants.landingMalus)) }
        // Land Melee Unit attacking to Water
        if u.def.isLand && !attackerTile.isWater && cIsMelee(attacker) && defenderTile.isWater && !acrossCoast {
            modifiers.put("Boarding", Int(BattleConstants.boardingMalus))
        }
        // Melee Unit on water attacking to Land (not City) unit
        if !u.def.isAir && cIsMelee(attacker) && attackerTile.isWater && !defenderTile.isWater && !acrossCoast && !defender.isCity {
            modifiers.put("Landing", Int(BattleConstants.landingMalus))
        }
        if isMeleeAttackingAcrossRiverWithNoBridge(attacker, u, tileToAttackFrom: tileToAttackFrom, defender) {
            modifiers.put("Across river", Int(BattleConstants.attackingAcrossRiverMalus))
        }
        return modifiers
    }

    /// Unciv BattleDamage.isMeleeAttackingAcrossRiverWithNoBridge. The tile the attack comes from is whatever the
    /// caller passed - Battle.takeDamage passes none, so it is the defender's own tile and the test never holds.
    private func isMeleeAttackingAcrossRiverWithNoBridge(_ attacker: Combatant, _ u: Unit, tileToAttackFrom: HexCoord, _ defender: Combatant) -> Bool {
        let defenderTile = cCoord(defender)
        guard cIsMelee(attacker), tileToAttackFrom.distance(to: defenderTile) == 1, map.hasRiver(between: tileToAttackFrom, defenderTile),
              !unitHasUnique(u, "Eliminates combat penalty for attacking over a river"),
              let from = map[tileToAttackFrom], let to = map[defenderTile] else { return false }
        let forestRoads = forestsAreRoads(u.civId)
        return !tileHasConnection(from, civId: u.civId, forestRoads: forestRoads) || !tileHasConnection(to, civId: u.civId, forestRoads: forestRoads) || !bridgesKnown(u.civId)
    }

    /// Unciv BattleDamage.getAirSweepAttackModifiers
    func getAirSweepAttackModifiers(_ attacker: Combatant) -> ModifierCounter {
        var modifiers = ModifierCounter()
        guard attacker.isMapUnitCombatant, let u = cUnit(attacker) else { return modifiers }
        for unique in unitMatchingUniques(u, "[]% Strength when performing Air Sweep") { modifiers.add(modifierString(unique), unique.int(0)) }
        return modifiers
    }

    /// Unciv BattleDamage.getDefenceModifiers
    func getDefenceModifiers(_ attacker: Combatant, _ defender: Combatant, tileToAttackFrom: HexCoord) -> ModifierCounter {
        var modifiers = getGeneralModifiers(defender, attacker, action: "Defend", tileToAttackFrom: tileToAttackFrom)
        if defender.isMapUnitCombatant, let d = cUnit(defender), !isEmbarked(d), let tile = map[d.coord] {   // Embarked units get no terrain defensive bonuses
            let tileDefenceBonus = tileDefensiveBonus(tile)
            if (!unitHasUnique(d, "No defensive terrain bonus", nil, checkCivInfoUniques: true) && tileDefenceBonus > 0)
                || (!unitHasUnique(d, "No defensive terrain penalty", nil, checkCivInfoUniques: true) && tileDefenceBonus < 0) {
                modifiers.put("Tile", Int(tileDefenceBonus * 100))
            }
            if d.order == .fortify || d.order == .fortifyUntilHealed || d.order == .guardPost {
                modifiers.put("Fortification", Int(BattleConstants.fortificationBonus) * d.turnsFortified)
            }
        }
        return modifiers
    }

    /// Unciv Tile.getDefensiveBonus(includeImprovementBonus = true), a Float: the base terrain, replaced by the
    /// strongest nonzero feature, plus the natural wonder and the unpillaged improvement's defensive bonus.
    func tileDefensiveBonus(_ t: Tile) -> Float {
        var bonus = Float(rs.terrains[t.baseTerrain]?.defenceBonus ?? 0)
        if !t.features.isEmpty {
            let otherTerrainBonus = t.features.map { Float(rs.terrains[$0]?.defenceBonus ?? 0) }.max() ?? 0
            if otherTerrainBonus != 0 { bonus = otherTerrainBonus }   // replaces baseTerrainObject
        }
        if let w = t.naturalWonder { bonus += Float(rs.terrains[w]?.defenceBonus ?? 0) }
        if let imp = t.improvement, !t.pillaged, let def = rs.improvements[imp] {
            for u in def.uniqueObjects where u.pattern == "Gives a defensive bonus of []%" { bonus += Float(u.double(0)) / 100 }
        }
        return bonus
    }

    /// Unciv BattleDamage.modifiersToFinalBonus: 1 plus each modifier / 100, summed in Float in the counter's order
    func modifiersToFinalBonus(_ modifiers: ModifierCounter) -> Float {
        var finalModifier: Float = 1
        for (_, value) in modifiers.entries { finalModifier += Float(value) / 100 }
        return finalModifier
    }

    /// Unciv BattleDamage.getHealthDependantDamageRatio: each 3 missing HP take 1% off the damage dealt
    func getHealthDependantDamageRatio(_ combatant: Combatant) -> Float {
        guard combatant.isMapUnitCombatant, let u = cUnit(combatant) else { return 1 }
        if unitHasUnique(u, "No damage penalty for wounded units", nil, checkCivInfoUniques: true) { return 1 }
        return 1 - Float(100 - u.health) / Float(BattleConstants.damageReductionWoundedUnitRatioPercentage)
    }

    /// Unciv ICombatant.getAttackingStrength(defender): the combatant's own strength, before percentages
    func combatantAttackingStrength(_ c: Combatant, defender: Combatant?) -> Int {
        switch c {
        case .city:
            guard let city = cCity(c) else { return 1 }
            return cityAttackingStrength(city, defender: defender)
        case .fakeRanged(_, let baseRangedStrength):
            // Battle.FakeUnitForExtraRangedAttack.getAttackingStrength
            guard let u = cUnit(c) else { return baseRangedStrength }
            let state = combatContext(c, defender, attackedTile: u.coord, action: "Attack")
            return baseRangedStrength + unitMatchingUniques(u, "[] Strength", state).reduce(0) { $0 + $1.int(0) }
        case .unit, .probe:
            // MapUnitCombatant.getAttackingStrength: GameContext(this, defender, this.getTile(), Attack)
            guard let u = cUnit(c) else { return 0 }
            let state = combatContext(c, defender, attackedTile: u.coord, action: "Attack")
            let extraStrength = unitMatchingUniques(u, "[] Strength", state).reduce(0) { $0 + $1.int(0) }
            return (cIsRanged(c) ? u.def.rangedStrength : u.def.strength) + extraStrength
        }
    }

    /// Unciv ICombatant.getDefendingStrength(attacker)
    func combatantDefendingStrength(_ c: Combatant, attacker: Combatant?) -> Int {
        if let city = cCity(c) { return cityDefendingStrengthBase(city, attacker: attacker) }
        guard let u = cUnit(c) else { return 0 }
        // MapUnitCombatant.getDefendingStrength: GameContext(this, attacker, this.getTile(), Defend)
        let attackedByRanged = attacker.map { cIsRanged($0) } ?? false
        let state = combatContext(c, attacker, attackedTile: u.coord, action: "Defend")
        let extraStrength = unitMatchingUniques(u, "[] Strength", state).reduce(0) { $0 + $1.int(0) }
        if isEmbarked(u) && !u.isCivilian { return rs.era(named: civ(u.civId)?.eraName ?? "")?.embarkDefense ?? 3 }
        if u.def.isRanged && attackedByRanged { return u.def.rangedStrength + extraStrength }
        return u.def.strength + extraStrength
    }

    /// Unciv BattleDamage.getAttackingStrength: includes the attack modifiers, at least 1
    func getAttackingStrength(_ attacker: Combatant, _ defender: Combatant, tileToAttackFrom: HexCoord) -> Float {
        let attackModifier = modifiersToFinalBonus(getAttackModifiers(attacker, defender, tileToAttackFrom: tileToAttackFrom))
        return max(1, Float(combatantAttackingStrength(attacker, defender: defender)) * attackModifier)
    }

    /// Unciv BattleDamage.getDefendingStrength: includes the defence modifiers, at least 1
    func getDefendingStrength(_ attacker: Combatant, _ defender: Combatant, tileToAttackFrom: HexCoord) -> Float {
        let defenceModifier = modifiersToFinalBonus(getDefenceModifiers(attacker, defender, tileToAttackFrom: tileToAttackFrom))
        return max(1, Float(combatantDefendingStrength(defender, attacker: attacker)) * defenceModifier)
    }

    /// Unciv BattleDamage.getRandomness: `Random(gameInfo.turns * tile.position.toVector2().hashCode().toLong()).nextFloat()`
    /// - Int times Long is a Long, so this is Random(Long). `turn` runs one ahead of gameInfo.turns except during the
    /// barbarian phase, where they are equal - the same correction StateBasedRandom makes.
    func getRandomness(_ combatant: Combatant) -> Float { randomness(at: cCoord(combatant)) }
    func randomness(at c: HexCoord) -> Float {
        var g = SeededRandom(kotlinSeedLong: Int64(turn - (barbarianPhase ? 0 : 1)) &* Int64(uncivPositionVector2Hash(c)))
        return g.nextFloat()
    }

    /// Unciv BattleDamage.calculateDamageToAttacker. `tileToAttackFrom` defaults to the defender's tile and the
    /// randomness to the ATTACKER's tile, as there.
    func calculateDamageToAttacker(_ attacker: Combatant, _ defender: Combatant, tileToAttackFrom: HexCoord? = nil, randomnessFactor: Float? = nil) -> Int {
        if cIsRanged(attacker) && !cIsAirUnit(attacker) { return 0 }
        if cIsCivilian(defender) { return 0 }
        let from = tileToAttackFrom ?? cCoord(defender)
        let ratio = getAttackingStrength(attacker, defender, tileToAttackFrom: from) / getDefendingStrength(attacker, defender, tileToAttackFrom: from)
        let r = randomnessFactor ?? getRandomness(attacker)
        return Stats.roundToInt(Double(uncivDamageModifier(ratio, damageToAttacker: true, randomnessFactor: r) * getHealthDependantDamageRatio(defender)))
    }

    /// Unciv BattleDamage.calculateDamageToDefender. The randomness defaults to the DEFENDER's tile.
    func calculateDamageToDefender(_ attacker: Combatant, _ defender: Combatant, tileToAttackFrom: HexCoord? = nil, randomnessFactor: Float? = nil) -> Int {
        if cIsCivilian(defender) { return BattleConstants.damageToCivilianUnit }
        let from = tileToAttackFrom ?? cCoord(defender)
        let ratio = getAttackingStrength(attacker, defender, tileToAttackFrom: from) / getDefendingStrength(attacker, defender, tileToAttackFrom: from)
        let r = randomnessFactor ?? getRandomness(defender)
        return Stats.roundToInt(Double(uncivDamageModifier(ratio, damageToAttacker: false, randomnessFactor: r) * getHealthDependantDamageRatio(attacker)))
    }

    /// Unciv BattleDamage.getExtraRangedAttackBonusDamage: (max, min) extra damage of the ExtraRangedAttack stand-ins
    func getExtraRangedAttackBonusDamage(_ attacker: Combatant, _ defender: Combatant, tileToAttackFrom: HexCoord) -> (Int, Int) {
        var maxExtra = 0, minExtra = 0
        for fake in getExtraRangedAttackFakeUnits(attacker) {
            maxExtra += calculateDamageToDefender(fake, defender, tileToAttackFrom: tileToAttackFrom, randomnessFactor: 1)
            minExtra += calculateDamageToDefender(fake, defender, tileToAttackFrom: tileToAttackFrom, randomnessFactor: 0)
        }
        return (maxExtra, minExtra)
    }

    /// Unciv BattleDamage.damageModifier, in Float: `Float.pow` is Math.pow on the widened value, narrowed again.
    func uncivDamageModifier(_ attackerToDefenderRatio: Float, damageToAttacker: Bool, randomnessFactor: Float) -> Float {
        let strongerToWeakerRatio = Float(pow(Double(attackerToDefenderRatio), attackerToDefenderRatio < 1 ? -1 : 1))
        var ratioModifier = (Float(pow(Double((strongerToWeakerRatio + 3) / 4), 4)) + 1) / 2
        // damage ratio from the weaker party is inverted
        if (damageToAttacker && attackerToDefenderRatio > 1) || (!damageToAttacker && attackerToDefenderRatio < 1) {
            ratioModifier = Float(pow(Double(ratioModifier), -1))
        }
        let randomCenteredAround30 = 24 + 12 * randomnessFactor
        return randomCenteredAround30 * ratioModifier
    }

    // MARK: - older entry points (battle table, bombard ranking)

    /// Unciv BattleDamage.getAttackModifiers / getDefenceModifiers as the battle table lists them.
    func combatModifiers(_ unit: Unit, attacking: Bool, ranged: Bool, opponent: Unit? = nil, opponentIsCity: Bool = false) -> [(String, Int)] {
        combatTrace = []
        _ = effectiveStrength(unit, attacking: attacking, ranged: ranged, opponent: opponent, opponentIsCity: opponentIsCity)
        let out = (combatTrace ?? []).filter { $0.1 != 0 }.map { ($0.0, Int($0.1.rounded())) }
        combatTrace = nil
        return out
    }

    private func trace(_ label: String, _ value: Double) { if combatTrace != nil { combatTrace!.append((label, value)) } }

    /// The battle table's unit strength: the Combatant computation above when the opponent is a unit on the map;
    /// the older estimate when the opponent is only "a city" (the bombard preview, which does not name it).
    func effectiveStrength(_ unit: Unit, attacking: Bool, ranged: Bool, opponent: Unit? = nil, opponentIsCity: Bool = false, at tile: Tile? = nil, targetTile: HexCoord? = nil, extraPercent: Double = 0, previewFrom: HexCoord? = nil) -> Double {
        if let o = opponent, extraPercent == 0, tile == nil {
            let me: Combatant = .probe(unit), them: Combatant = .probe(o)
            if attacking {
                let from = previewFrom ?? (targetTile ?? o.coord)
                let mods = getAttackModifiers(me, them, tileToAttackFrom: from)
                for (k, v) in mods.entries { trace(k, Double(v)) }
                return Double(max(1, Float(combatantAttackingStrength(me, defender: them)) * modifiersToFinalBonus(mods)))
            }
            let mods = getDefenceModifiers(them, me, tileToAttackFrom: unit.coord)
            for (k, v) in mods.entries { trace(k, Double(v)) }
            return Double(max(1, Float(combatantDefendingStrength(me, attacker: them)) * modifiersToFinalBonus(mods)))
        }
        let fightTile = tile ?? map[unit.coord]
        let attacked = attacking ? (targetTile.flatMap { map[$0] } ?? opponent.flatMap { map[$0.coord] }) : fightTile
        let opponentCivId = opponent?.civId ?? (opponentIsCity ? attacked.flatMap { city(at: $0.coord)?.civId } : nil)
        let ctx = UniqueContext(civId: unit.civId, unit: unit, tile: fightTile, attackedTile: attacked, attacking: attacking, opponentUnit: opponent, opponentIsCity: opponentIsCity, opponentCivId: opponentCivId)
        let unitUniques = unit.promotionUniques + civUniques(unit.civId)
        var s = attacking ? unitAttackingStrength(unit, ranged: ranged, uniques: unit.promotionUniques, ctx: ctx)
                          : unitDefendingStrength(unit, attackedByRanged: ranged, uniques: unit.promotionUniques, ctx: ctx)
        var pct = extraPercent
        for u in unitUniques where u.pattern == "[]% Strength" && conditionalsHold(u, ctx) { pct += Double(u.int(0)); trace(u.text, Double(u.int(0))) }
        if civ(unit.civId)?.isBarbarian != true {
            let counts = resourceCounts(unit.civId)
            if resourceRequirementsPerTurn(requiredResource: unit.def.requiredResource, uniques: unit.def.uniqueObjects, ctx: ctx).keys.contains(where: { (counts[$0] ?? 0) < 0 }) { pct += BattleConstants.missingResourcesMalus; trace("Missing resource", BattleConstants.missingResourcesMalus) }
        }
        if let g = greatGeneralBonus(unit, unitUniques: unitUniques) { pct += g.bonus; trace(g.name, g.bonus) }
        if let o = opponent, civ(o.civId)?.isBarbarian == true { let v = Double(Int(Float(difficulty.barbarianBonus) * 100)); pct += v; trace("Difficulty", v) }
        if !attacking, let t = fightTile, !isEmbarked(unit) {
            let bonus = Double(tileDefensiveBonus(t))
            if (bonus > 0 && !unitUniques.contains(where: { $0.pattern == "No defensive terrain bonus" })) || (bonus < 0 && !unitUniques.contains(where: { $0.pattern == "No defensive terrain penalty" })) {
                let v = Double(Int(bonus * 100)); pct += v; trace("Tile", v)
            }
            if unit.order == .fortify || unit.order == .fortifyUntilHealed || unit.order == .guardPost {
                let v = BattleConstants.fortificationBonus * Double(unit.turnsFortified); if v > 0 { pct += v; trace("Fortification", v) }
            }
        }
        s *= 1 + pct / 100
        return max(1, s)
    }

    /// Unciv BattleDamage.getGeneralModifiers for a city combatant: "[]% Strength for cities" and the barbarian difficulty bonus, summed
    func cityCombatPercent(_ city: City, attacking: Bool, opponent: Unit?) -> Double {
        let ctx = UniqueContext(civId: city.civId, city: city, attacking: attacking, opponentUnit: opponent)
        var pct = cityUniques(city).filter { $0.pattern == "[]% Strength for cities" && conditionalsHold($0, ctx) }.reduce(0.0) { $0 + Double($1.int(0)) }
        if let o = opponent, civ(o.civId)?.isBarbarian == true { pct += Double(Int(Float(difficulty.barbarianBonus) * 100)) }
        return pct
    }

    func cityDefendingStrength(_ city: City, attacker: Unit?) -> Double { max(1, cityStrength(city) * (1 + cityCombatPercent(city, attacking: false, opponent: attacker) / 100)) }

    /// Unciv BattleDamage.getRandomness at a tile, as a Double
    func combatRandomness(at c: HexCoord) -> Double { Double(randomness(at: c)) }
}
