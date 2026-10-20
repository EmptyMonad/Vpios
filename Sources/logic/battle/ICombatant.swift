// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/ICombatant.kt`, `MapUnitCombatant` and `CityCombatant` as the parties to a fight.
///
/// Unciv hands `Battle` objects: a destroyed unit is still a `MapUnit` with health 0 and its last tile, a captured
/// civilian answers with its new owner, a conquered city with its new civ. Ours are ids into value arrays, so a
/// combatant is an id that is looked up LIVE on every question - and a unit that `destroyUnit` removed is answered
/// from `battleGraveyard`, frozen as it was when it died.
enum Combatant {
    /// Unciv MapUnitCombatant(unit)
    case unit(Int)
    /// A MapUnitCombatant for a unit VALUE - the damage previews of the AI and the battle table ask about a unit
    /// as it would stand somewhere; nothing is ever written to it.
    case probe(Unit)
    /// Unciv CityCombatant(city)
    case city(Int)
    /// Unciv Battle.FakeUnitForExtraRangedAttack: the unit, except that it is ranged and attacks with its own
    /// strength. It is NOT a MapUnitCombatant, so every `is MapUnitCombatant` test is false for it.
    case fakeRanged(unitId: Int, baseRangedStrength: Int)

    var unitId: Int? {
        switch self {
        case .unit(let id), .fakeRanged(let id, _): return id
        case .probe(let u): return u.id
        case .city: return nil
        }
    }
    var cityId: Int? { if case .city(let id) = self { return id }; return nil }
    /// Unciv `is MapUnitCombatant`
    var isMapUnitCombatant: Bool { switch self { case .unit, .probe: return true; default: return false } }
    /// Unciv `is CityCombatant` / ICombatant.isCity()
    var isCity: Bool { cityId != nil }
}

extension GameState {
    // MARK: - resolving a combatant

    /// The unit behind a combatant: alive, or as `destroyUnit` left it.
    func cUnit(_ c: Combatant) -> Unit? {
        switch c {
        case .unit(let id), .fakeRanged(let id, _): return unit(id) ?? battleGraveyard[id]
        case .probe(let u): return u
        case .city: return nil
        }
    }
    func cCity(_ c: Combatant) -> City? {
        guard let id = c.cityId else { return nil }
        return city(id) ?? destroyedCitySnapshots[id]
    }
    /// ICombatant.getHealth
    func cHealth(_ c: Combatant) -> Int { cUnit(c)?.health ?? cCity(c)?.health ?? 0 }
    /// ICombatant.getCivInfo
    func cCivId(_ c: Combatant) -> Int { cUnit(c)?.civId ?? cCity(c)?.civId ?? -1 }
    /// ICombatant.getTile
    func cCoord(_ c: Combatant) -> HexCoord { cUnit(c)?.coord ?? cCity(c)?.coord ?? HexCoord(0, 0) }
    /// ICombatant.getName
    func cName(_ c: Combatant) -> String { cUnit(c)?.name ?? cCity(c)?.name ?? "" }
    /// MapUnitCombatant.isDefeated: health <= 0 / CityCombatant.isDefeated: health == 1
    func cIsDefeated(_ c: Combatant) -> Bool {
        if c.isCity { return cHealth(c) == 1 }
        return cHealth(c) <= 0
    }
    /// ICombatant.isRanged: a city always, the extra-ranged-attack stand-in always, a unit when its base unit is
    func cIsRanged(_ c: Combatant) -> Bool {
        switch c {
        case .city, .fakeRanged: return true
        default: return cUnit(c)?.def.isRanged ?? false
        }
    }
    func cIsMelee(_ c: Combatant) -> Bool { !cIsRanged(c) }
    func cIsAirUnit(_ c: Combatant) -> Bool { c.isCity ? false : (cUnit(c)?.def.isAir ?? false) }
    func cIsLandUnit(_ c: Combatant) -> Bool { c.isCity ? false : (cUnit(c)?.def.isLand ?? false) }
    func cIsWaterUnit(_ c: Combatant) -> Bool { c.isCity ? false : (cUnit(c)?.def.isWater ?? false) }
    /// ICombatant.isCivilian: `this is MapUnitCombatant && unit.isCivilian()`
    func cIsCivilian(_ c: Combatant) -> Bool { c.isMapUnitCombatant && (cUnit(c)?.isCivilian ?? false) }

    /// ICombatant.getNotificationDisplay: a unit by its own name when it has one, else "our [Warrior]"; a city ""
    func cNotificationDisplay(_ c: Combatant, _ leading: String = "") -> String {
        guard c.isMapUnitCombatant, let u = cUnit(c) else { return "" }
        if let n = u.customName, !n.isEmpty { return "[\(n)]" }
        return "\(leading)[\(u.name)]"
    }

    /// ICombatant.matchesFilter: a unit by its unit filter, a city by "City", "All"/"all" or its city filter
    func cMatchesFilter(_ c: Combatant, _ filter: String) -> Bool {
        if let city = cCity(c) {
            return MultiFilter.multiFilter(filter) { f in f == "City" || f == "All" || f == "all" || cityMatchesFilter(f, city: city, viewer: city.civId) }
        }
        guard let u = cUnit(c) else { return false }
        return unitMatches(u, filter)
    }

    /// ICombatant.takeDamage: a unit through MapUnit.takeDamage (destroyed at 0), a city never below 1
    func cTakeDamage(_ c: Combatant, _ damage: Int) {
        if let id = c.cityId {
            guard let ci = cityIndex(id) else { return }
            cities[ci].health -= damage
            if cities[ci].health < 1 { cities[ci].health = 1 }   // min health is 1
            return
        }
        guard let id = c.unitId else { return }
        unitTakeDamage(id, damage)
    }

    /// Unciv MapUnit.takeDamage
    func unitTakeDamage(_ unitId: Int, _ amount: Int) {
        guard let i = unitIndex(unitId) else { return }
        units[i].health -= amount
        if units[i].health > 100 { units[i].health = 100 }   // For cheating modders, e.g. negative tile damage
        if units[i].health < 0 { units[i].health = 0 }
        if units[i].health == 0 { destroyUnit(unitId) }
        else { updateUnitUniquesCache(unitId) }   // Unciv: `else cache.updateUniques()`
    }

    /// Unciv MapUnit.healBy: doubled by "All healing effects doubled", never above 100
    func unitHealBy(_ unitId: Int, _ amount: Int) {
        guard let i = unitIndex(unitId) else { return }
        let doubled = (units[i].promotionUniques + civUniques(units[i].civId)).contains { $0.pattern == "All healing effects doubled" }
        units[i].health += amount * (doubled ? 2 : 1)
        if units[i].health > 100 { units[i].health = 100 }
        updateUnitUniquesCache(unitId)   // Unciv healBy: cache.updateUniques()
    }

    /// Unciv MapUnit.destroy(destroyTransportedUnit = true): stop escorting, no movement left, out of the civ's
    /// list (UnitManager.removeUnit and its updates), off the tile, the civ's view refreshed, and whatever it
    /// carried destroyed with it. The unit stays answerable through `battleGraveyard`.
    func destroyUnit(_ unitId: Int, destroyTransportedUnit: Bool = true) {
        guard let i = unitIndex(unitId) else { return }
        stopEscorting(unitId: unitId)
        units[i].movementLeft = 0
        let dead = units[i]
        battleGraveyard[unitId] = dead
        let carried = destroyTransportedUnit && carrierCapacity(dead) > 0
            ? units.filter { $0.id != unitId && $0.coord == dead.coord && $0.civId == dead.civId && $0.isTransported && canBeCarried($0, by: dead) }.map { $0.id }
            : []
        removeUnit(unitId)
        // Unciv MapUnit.destroy, between removeUnit and removeFromTile: the unit's attacks since its turn start move to
        // its civ's list as HistoricalAttackMemory(name, currentPosition, target), so their arrows outlive it
        if let ci = civIndex(dead.civId) {
            civs[ci].attacksSinceTurnStart += dead.attacksSinceTurnStart.map { HistoricalAttackMemory(attackingUnit: dead.name, source: dead.coord, target: $0) }
        }
        unitViewCache[unitId] = nil
        // civ.cache.updateViewableTiles(), a barbarian's too: its view is stored and explored, and it meets no one
        // (updateExploration's `if (!civInfo.isBarbarian)`)
        updateExploration(for: dead.civId)
        for id in carried { destroyUnit(id) }
    }

    // MARK: - the tile's combatant

    /// Unciv Tile.militaryUnit: the land or sea military unit on the tile (aircraft are kept apart)
    func militaryUnitOn(_ c: HexCoord) -> Unit? { units(at: c).first { $0.isMilitary && !$0.def.isAir } }
    /// Unciv Tile.civilianUnit
    func civilianUnitOn(_ c: HexCoord) -> Unit? { units(at: c).first { $0.isCivilian } }

    /// Unciv Battle.getMapCombatantOfTile: a city centre is the city whatever stands on it, then the military
    /// unit, then the civilian.
    func getMapCombatantOfTile(_ c: HexCoord) -> Combatant? {
        if let city = city(at: c) { return .city(city.id) }
        if let m = militaryUnitOn(c) { return .unit(m.id) }
        if let v = civilianUnitOn(c) { return .unit(v.id) }
        return nil
    }

    // MARK: - GameContext

    /// Unciv `GameContext(ourCombatant, theirCombatant, attackedTile, combatAction)`: our civ, city or unit and
    /// tile, the other side, the attacked tile and the action ("Attack" / "Defend" / "Intercept").
    func combatContext(_ our: Combatant, _ their: Combatant?, attackedTile: HexCoord?, action: String?) -> UniqueContext {
        UniqueContext(
            civId: cCivId(our),
            city: cCity(our),
            unit: our.isMapUnitCombatant ? cUnit(our) : nil,
            tile: map[cCoord(our)],
            attackedTile: attackedTile.flatMap { map[$0] },
            attacking: action == "Attack" ? true : action == "Defend" ? false : nil,
            opponentUnit: their.flatMap { $0.isCity ? nil : cUnit($0) },
            opponentIsCity: their?.isCity ?? false,
            opponentCivId: their.map { cCivId($0) },
            combatAction: action,
            opponentCity: their.flatMap { $0.isCity ? cCity($0) : nil }   // theirCombatant as a CityCombatant (context hash, "vs [filter]")
        )
    }

    // MARK: - uniques of a unit combatant

    /// Unciv MapUnit.getMatchingUniques(type, state, checkCivInfoUniques): the unit's own uniques (base unit,
    /// type, promotions, statuses), then the civ's, whose conditionals hold in `ctx`.
    func unitMatchingUniques(_ u: Unit, _ pattern: String, _ ctx: UniqueContext? = nil, checkCivInfoUniques: Bool = false) -> [Unique] {
        let state = ctx ?? UniqueContext(civId: u.civId, unit: u, tile: map[u.coord])
        let pool = checkCivInfoUniques ? u.promotionUniques + civUniques(u.civId) : u.promotionUniques
        return pool.filter { $0.pattern == pattern && conditionalsHold($0, state) }
    }
    func unitHasUnique(_ u: Unit, _ pattern: String, _ ctx: UniqueContext? = nil, checkCivInfoUniques: Bool = false) -> Bool {
        !unitMatchingUniques(u, pattern, ctx, checkCivInfoUniques: checkCivInfoUniques).isEmpty
    }

    // MARK: - Civilization.addGameResource

    /// Unciv Ruleset.getGameResource: a stat, a sub-stat or a tile resource; nil for anything else
    func isGameResource(_ name: String) -> Bool {
        ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith", "Golden Age points", "Stored Food"].contains(name) || rs.resources[name] != nil
    }
    func isStatName(_ name: String) -> Bool { ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith"].contains(name) }

    /// Unciv Civilization.addGameResource (and addStat, which is the same for the stats): a stockpiled resource is
    /// banked, culture / science / gold / faith / golden age points go to the civ, food and production nowhere.
    func addGameResource(_ civId: Int, _ name: String, _ amount: Int) {
        guard let ci = civIndex(civId) else { return }
        if let r = rs.resources[name], r.isStockpiled { civs[ci].resourceStockpiles[name, default: 0] += amount }
        switch name {
        case "Culture":
            addCulture(ci, Double(amount)); civs[ci].totalCulture += Double(amount)
            if amount > 0 { civs[ci].totalCultureForContests += amount }
        case "Science": addScience(civId: civId, amount)
        case "Gold": civs[ci].gold += Double(amount); goldTrace(civId, Double(amount))
        case "Faith":
            civs[ci].faithStored += Double(amount)
            if amount > 0 { civs[ci].totalFaithForContests += amount }
        case "Golden Age points": civs[ci].goldenAgePoints += Double(amount)
        default: break
        }
    }

    /// Unciv Civilization.addGold
    func addGold(_ civId: Int, _ delta: Int) {
        guard let ci = civIndex(civId) else { return }
        civs[ci].gold += Double(delta); goldTrace(civId, Double(delta))
    }
}
