// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Part of the mirror of Unciv `logic/map/mapunit/MapUnit.kt`: the air-unit state it keeps - range, targets, carriers and rebasing.
extension GameState {
    /// Unciv MapUnit.destroy: a unit being removed first stops escorting, so its partner does not keep a flag
    /// that would silently re-bind to whatever steps onto its tile next.
    func removeUnit(_ unitId: Int) {
        stopEscorting(unitId: unitId)
        let removed = units.first { $0.id == unitId }
        if let removed { rotateCivUnitsToNextDue(removed.civId) }   // Unciv UnitManager.removeUnit: the list starts at nextPotentiallyDueAt
        freezeSavedUnitPromotions(unitId: unitId)   // a city's saved default promotions keep this unit's object as it dies
        units.removeAll { $0.id == unitId }
        if GameState.evlogOn, let removed { evUnitDie(removed) }   // EVLOG: UNIT_DIE
        pathfindingCache[unitId] = nil   // the MapUnit object, and the movement cache it owns, are gone
        // Unciv UnitManager.removeUnit: unit upkeep, the resources it used, and "upon losing a [] unit"
        if let removed { unitManagerRemoved(removed) }
    }

    /// Unciv MapUnit.getResourceRequirementsPerTurn().isNotEmpty()
    func unitEatsResources(_ u: Unit) -> Bool {
        !resourceRequirementsPerTurn(requiredResource: u.def.requiredResource, uniques: u.def.uniqueObjects, ctx: UniqueContext(civId: u.civId, unit: u)).isEmpty
    }

    /// Unciv MapUnit.consume: the "<upon expending a [] unit>" triggers, then destroy().
    func consumeUnit(_ unitId: Int) {
        guard let u = unit(unitId) else { return }
        triggerUponExpending(u)
        destroyUnit(unitId)
    }

    /// Unciv MapUnit.hasUnitMovedThisTurn: `currentMovement < max - max.ulp`, in Float.
    func hasUnitMovedThisTurn(_ u: Unit) -> Bool {
        let max = Float(maxMovement(of: u))
        return Float(u.movementLeft) < max - max.ulp
    }

    /// Unciv MapUnit.healBy: doubled by "All healing effects doubled" (unit and civ), capped at 100.
    func healBy(unitId: Int, _ amount: Int) {
        guard let i = unitIndex(unitId) else { return }
        let u = units[i]
        let ctx = UniqueContext(civId: u.civId, unit: u, tile: map[u.coord])
        let doubled = (u.promotionUniques + civUniques(u.civId)).contains { $0.pattern == "All healing effects doubled" && conditionalsHold($0, ctx) }
        units[i].health += amount * (doubled ? 2 : 1)
        if units[i].health > 100 { units[i].health = 100 }
        updateUnitUniquesCache(unitId)   // Unciv healBy: cache.updateUniques()
    }

    /// Unciv MapUnit.takeDamage: health clamped to 0...100, destroyed at 0. Returns whether the unit was destroyed.
    @discardableResult
    func takeDamage(unitId: Int, _ amount: Int) -> Bool {
        guard let i = unitIndex(unitId) else { return true }
        units[i].health -= amount
        if units[i].health > 100 { units[i].health = 100 }
        if units[i].health < 0 { units[i].health = 0 }
        if units[i].health == 0 { destroyUnit(unitId); return true }
        updateUnitUniquesCache(unitId)   // Unciv: `else cache.updateUniques()`
        return false
    }

    /// Unciv MapUnit.consume: every "<upon expending a [filter] unit>" trigger fires, whatever it pays, wherever
    /// the unit is spent. Reliquary pays faith and the Mausoleum of Halicarnassus gold; only gold was being paid,
    /// and only from the great-person action, so founding a religion never triggered either.
    func triggerUponExpending(_ unit: Unit) {
        if unit.def.isGreatPerson { vpInstantYield(.gpExpended(unit.name), civId: unit.civId, cityId: nil) }   // VP
        // `matches` is handed each CONDITIONAL of a unique, not the unique: asking it for its own conditional found
        // nothing, so no "<upon expending a [..] unit>" ever fired (the Mausoleum's 100 gold per great person).
        triggerConditionalUniques(civId: unit.civId, unitId: unit.id, triggerText: "due to expending our [\(unit.name)]") { c in
            c.pattern == "upon expending a [] unit" && self.unitMatches(unit, c.param(0))
        }
    }

    func isAircraft(_ unit: Unit) -> Bool { unit.def.isAir }

    /// Unciv MapUnit.getRange: base range plus "[] Range" uniques of the unit and the civ
    func airRange(_ unit: Unit) -> Int { unit.def.range + (unit.promotionUniques + civUniques(unit.civId)).filter { $0.pattern == "[] Range" }.reduce(0) { $0 + $1.int(0) } }

    /// Targets an aircraft in this city can strike: enemy units and cities within range.
    func airTargets(for unit: Unit) -> [HexCoord] {
        guard unit.def.isAir, unit.movementLeft > 0, unit.attacksThisTurn < 1 + extraAttacks(of: unit) else { return [] }   // Unciv canAttack: attacksThisTurn < maxAttacksPerTurn
        if unit.def.uniqueObjects.contains(where: { $0.pattern == "Nuclear weapon of Strength []" }) {
            // Unciv: a nuke may target any explored tile in range where every hit civ can be attacked (BattleTable.simulateNuke + mayUseNuke).
            return map.tilesWithin(unit.coord, radius: airRange(unit)).filter { mayUseNuke(unit, target: $0) }
        }
        let visible = visibleTiles(for: unit.civId)   // Unciv TargetHelper: only tiles the civ can see
        return map.tilesWithin(unit.coord, radius: airRange(unit)).filter { c in
            guard visible.contains(c) else { return false }
            if let city = city(at: c), city.civId != unit.civId, areAtWar(unit.civId, city.civId) { return true }
            return units(at: c).contains { $0.civId != unit.civId && areAtWar(unit.civId, $0.civId) }
        }
    }

    /// Unciv City.getMaxAirUnits: cityAirUnitCapacity plus the city's "Can carry [n] extra [Air] units" uniques
    func maxAirUnits(_ city: City) -> Int {
        rs.constants.cityAirUnitCapacity + cityUniques(city).filter { $0.pattern == "Can carry [] extra [] units" && $0.param(1) == "Air" && scopeIncludes($0, city: city) }.reduce(0) { $0 + $1.int(0) }
    }

    /// Unciv MapUnit.putInTile for air units: transported away from a city, or when the city has no room left for untransported air units
    func updateTransportedState(unitIndex ui: Int) {
        guard units[ui].def.isAir else { return }
        let c = units[ui].coord, selfId = units[ui].id
        guard let city = city(at: c) else { units[ui].isTransported = true; return }
        let untransported = units.filter { $0.coord == c && $0.def.isAir && (!$0.isTransported || $0.id == selfId) }.count
        units[ui].isTransported = untransported > maxAirUnits(city)
    }

    /// Carrier capacity: "Can carry [3] [Aircraft] units".
    func carrierCapacity(_ unit: Unit) -> Int {
        let base = unit.def.uniqueObjects.first { $0.pattern == "Can carry [] [] units" }?.int(0) ?? 0
        return base == 0 ? 0 : base + unit.promotionUniques.filter { $0.pattern == "Can carry [] extra [] units" }.reduce(0) { $0 + $1.int(0) }
    }

    func carriedCount(at c: HexCoord, civId: Int) -> Int { units.filter { $0.coord == c && $0.civId == civId && $0.def.isAir }.count }

    /// Tiles this aircraft could rebase to: own cities and carriers with room, within twice its range.
    func rebaseTargets(for unit: Unit) -> [HexCoord] {
        guard unit.def.isAir, unit.movementLeft > 0 else { return [] }
        let range = airRange(unit) * 2
        var out = cities(of: unit.civId).filter { c in
            guard c.coord != unit.coord, c.coord.distance(to: unit.coord) <= range else { return false }
            // Unciv: the city must still have room for one more untransported air unit
            return units.filter { $0.coord == c.coord && $0.def.isAir && !$0.isTransported && $0.id != unit.id }.count < maxAirUnits(c)
        }.map { $0.coord }
        let isMissile = unit.def.unitType == "Missile"
        for carrier in units(of: unit.civId) where carrierCapacity(carrier) > 0 && carrier.coord != unit.coord && carrier.coord.distance(to: unit.coord) <= range {
            // Unciv CarrierSlotMatcher: typed slots ("Can carry [2] [Aircraft] units" + "[1] extra [Missile]") instead of one pooled count.
            if canBeCarried(unit, by: carrier) && carrierAvailableCapacity(carrier, for: unit) > 0 { out.append(carrier.coord) }
        }
        _ = isMissile
        return out
    }

    func rebase(unitId: Int, to target: HexCoord) {
        guard let i = unitIndex(unitId), rebaseTargets(for: units[i]).contains(target) else { return }
        let evFrom = units[i].coord
        units[i].coord = target
        if GameState.evlogOn { evUnitMove(unitId, from: evFrom) }   // EVLOG: UNIT_MOVE (putInTile)
        units[i].movementLeft = 0
        // Unciv putInTile: a plane that lands on a carrier is carried, one that lands in a city is only carried when the city is full
        units[i].isTransported = city(at: target) == nil
        updateTransportedState(unitIndex: i)
        // moveThroughTile: `updateVisibleTiles(true, currentTile.position)`, which stores the civ's view only when the
        // plane's own view changed past ourTilesAndNeighboringTiles (MapUnit.kt:842)
        revealFromCurrentTile(unitId, explorer: target)
        updateUnitUniquesCache(unitId)   // Unciv putInTile: cache.updateUniques()
    }

    var nuclearBlastRadiusDefault: Int { 2 }

    /// Unciv MapUnit.getMaxMovement: 2 while embarked, "[] Movement" from the unit and its civ, at least 1, then "Transfer Movement to []" from units sharing the tile
    func maxMovement(of unit: Unit, ignoreOtherUnit: Bool = false) -> Double {
        var m = isEmbarked(unit) ? 2 : unit.def.movement
        let ctx = UniqueContext(civId: unit.civId, unit: unit, tile: map[unit.coord])
        for u in unit.promotionUniques + civUniques(unit.civId) where u.pattern == "[] Movement" && conditionalsHold(u, ctx) { m += u.int(0) }
        if m < 1 { m = 1 }
        if !ignoreOtherUnit {
            for b in units(at: unit.coord) where b.id != unit.id && b.promotionUniques.contains(where: { $0.pattern == "Transfer Movement to []" && unitMatches(unit, $0.param(0)) }) {
                m = max(m, Int(maxMovement(of: b, ignoreOtherUnit: true)))
            }
        }
        return Double(m)
    }

    /// Extra attacks a unit may make per turn ("[1] additional attacks per turn").
    func extraAttacks(of unit: Unit) -> Int {
        (unit.promotionUniques + civUniques(unit.civId)).filter { $0.pattern == "[] additional attacks per turn" }.reduce(0) { $0 + $1.int(0) }   // Unciv checkCivInfoUniques
    }

    // MARK: experience & promotions

    // MARK: paradrop ("May Paradrop to [Land] tiles up to [5] tiles away <in [{Friendly} {Land}] tiles>")
    /// Unciv UnitMovement.canReach for a unit preparing a paradrop (canReachCommon → canParadropOn), over the
    /// getReachableTilesInCurrentTurn range. It asks nothing about the units, borders or city on the tile - that is
    /// canMoveTo's job, which the tap, the highlight and getTileToMoveToThisTurn add on top of this set.
    func paradropTargets(_ unit: Unit) -> [HexCoord] {
        guard unit.movementLeft >= maxMovement(of: unit) - 0.001, let here = map[unit.coord] else { return [] }
        if unitCannotMove(unit) { return [] }   // Unciv canParadropOn: `if (unit.cache.cannotMove) return false`
        let vis = visibleTiles(for: unit.civId)   // Unciv canParadropOn: the destination must be visible now, not remembered
        var out: [HexCoord] = []
        for u in unit.def.uniqueObjects where u.pattern == "May Paradrop to [] tiles up to [] tiles away" {
            if let origin = u.conditional("in [] tiles"), !tileMatches(here, origin.param(0), civId: unit.civId) { continue }
            for c in map.tilesWithin(unit.coord, radius: u.int(1)) where c != unit.coord {
                // Unciv canParadropOn: not impassable, visible now, within range, matches the filter.
                // Ownership is never consulted - dropping behind enemy lines is the point of the unit.
                guard let t = map[c], vis.contains(c), !t.isImpassable, tileMatches(t, u.param(0), civId: unit.civId) else { continue }
                out.append(c)
            }
        }
        return out
    }

    /// Unciv WorldMapHolder.moveUnitToTargetTile for a unit preparing a paradrop: getTileToMoveToThisTurn(target) - the
    /// target itself only when canMoveTo holds, else the normal-movement fallback - then moveToTile's paradrop branch
    /// teleports the unit onto THAT tile. Returns whether the unit moved; a drop that gets nowhere (unreachable, or the
    /// fallback is the unit's own tile) is a dud that leaves the unit, and the paradrop mode, as they were.
    func paradrop(unitId: Int, to c: HexCoord) -> Bool {
        guard let i = unitIndex(unitId), paradropTargets(units[i]).contains(c) else { return false }
        // nil stands for UnreachableDestinationException; the own tile is moveToTile's `destination == unit.getTile()` return
        guard let step = tileToMoveToThisTurn(units[i], c, preparingParadrop: true), step != units[i].coord else { return false }
        // Unciv UnitMovement.moveToTile, paradrop branch: action = null, putInTile (→ moveThroughTile), the move type,
        // then useMovementPoints(1f) and the attack, the maintenance check, and a cleared pathfinding cache
        let civId = units[i].civId
        units[i].order = .none   // Unciv `unit.action = null` - the Paradrop action, which had replaced any earlier order
        let evFrom = units[i].coord
        units[i].coord = step
        if GameState.evlogOn { evUnitMove(unitId, from: evFrom) }   // EVLOG: UNIT_MOVE (putInTile)
        moveThroughTile(unitId, step)
        guard let j = unitIndex(unitId) else { return true }
        units[j].mostRecentMoveType = "UnitTeleported"
        useMovementPoints(unitId, 1)
        units[j].attacksThisTurn += 1   // Unciv: a paradrop uses up the unit's attack for the turn
        // no view update of its own: putInTile's moveThroughTile ran the unit's updateVisibleTiles
        // Unciv, paradrop branch: "Check if unit maintenance changed" - `unit.getTile().isCityCenter() ||
        // destination.isCityCenter()`. putInTile has already made getTile() the destination, so only a drop INTO a
        // city centre refreshes the stats; a drop out of one leaves them until the next refresh, as in Unciv.
        if let now = unit(unitId), now.isMilitary, now.def.isLand,   // Unciv canGarrison()
           map[step]?.isCityCenter == true,
           civUniques(civId).contains(where: { $0.pattern == "Units in cities cost no Maintenance" }) {
            updateStatsForNextTurn(civId)
        }
        clearPathfindingCache(unitId)
        return true
    }

    // MARK: pillage & set up

    /// Unciv UnitActionsPillage.getPillageAction availability: military, movement left, something pillageable, not our own territory, not a peaceful owner.
    /// Unciv asks the unit's own tile only whether there is something to name, and [tile] (the one pillaged) everything else.
    func canPillage(_ unit: Unit, at coord: HexCoord? = nil) -> Bool {
        // Unciv UnitActionsPillage.canPillage opens with `if (unit.isTransported) return false` - a carried aircraft
        // or missile is shown the Pillage button, disabled
        guard !unit.isTransported, unit.isMilitary, unit.movementLeft > 0, map[unit.coord]?.improvementToPillage != nil, let t = map[coord ?? unit.coord], let imp = t.improvementToPillage else { return false }
        if imp == Names.barbarianCamp || imp == Names.ancientRuins { return false }
        if unit.promotionUniques.contains(where: { $0.pattern == "Unable to pillage tiles" }) || unit.def.uniques.contains("Unable to pillage tiles") { return false }
        if t.ownerCivId == unit.civId { return false }
        if let owner = t.ownerCivId, !areAtWar(unit.civId, owner) { return false }
        return true
    }

    /// Unciv UnitActionsPillage: the improvement goes first, then the road; naval improvements are destroyed instead; looting, healing (improvements only),
    /// one movement point unless "No movement cost to pillage", "Destroyed when pillaged".
    /// Unciv getPillageAction(unit, tile) pillages [tile] - a tile the unit passed through on its way to an attack, too
    /// (Battle.movePreparingAttack) - but names the improvement, and decides whether it heals, from the tile the unit stands on.
    func pillage(unitId: Int, tile target: HexCoord? = nil) {
        guard let i = unitIndex(unitId), canPillage(units[i], at: target), let here = map[units[i].coord], let pillaged = here.improvementToPillage,
              let t = map[target ?? units[i].coord], let lootImp = t.improvementToPillage else { return }
        if ProcessInfo.processInfo.environment["GOLDX"] != nil { let p = uncivPosition(units[i].coord); print("PILLE t=\(turn) \(civ(units[i].civId)?.nation ?? "?")/\(units[i].name)@\(p.x),\(p.y) hp=\(units[i].health) mp=\(units[i].movementLeft) imp=\(pillaged)") }
        let unit = units[i]
        let pillagingImprovement = here.canPillageImprovement
        if let owner = t.ownerCivId { notify(owner, "An enemy [\(unit.name)] has pillaged our [\(pillaged)]", category: .War, icons: [pillaged, "War", unit.name], coord: t.coord) }
        // pillageLooting
        // Unciv UnitActionsPillage.kt:89: `Random(gameInfo.turns * tile.position.hashCode().toLong())` — tek uretec, butun yagma pasi icin.
        var pillageRng = SeededRandom(kotlinSeedLong: Int64(uncivTurns) &* Int64(uncivPositionHash(units[i].coord)))
        // Unciv pillageLooting: only the improvement's own "Pillaging this improvement yields [approximately] [stats]"
        // pay anything (a road pays nothing); "approximately X" is two draws of 0..X, the Stat order of the unique;
        // speed and game progress only when the unique carries those modifiers; then the pillager's percentages.
        // Civ-wide stats go to the civ as Int (civ.addStat), the rest to the closest city.
        let order = ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith"]
        var loot: [String: Double] = [:]
        let lootCtx = UniqueContext(civId: unit.civId, unit: unit, tile: t)
        if let def = rs.improvements[lootImp] {
            for u in def.uniqueObjects where u.pattern == "Pillaging this improvement yields approximately []" && conditionalsHold(u, lootCtx) {
                guard let st = u.stats else { continue }
                for stat in order where st[stat] != 0 {
                    let v = Int(st[stat])
                    var add = Double(pillageRng.nextInt(until: Int32(v + 1))) + Double(pillageRng.nextInt(until: Int32(v + 1)))
                    if u.conditionals.contains(where: { $0.pattern == "(modified by game speed)" }) { add = Stats.f32(add * speed.modifier) }
                    if u.conditionals.contains(where: { $0.pattern == "(modified by game progress up to []%)" }) { add = Stats.f32(add * gameProgressModifier(u, civId: unit.civId)) }
                    loot[stat, default: 0] = Stats.f32(loot[stat, default: 0] + add)
                }
            }
            for u in def.uniqueObjects where u.pattern == "Pillaging this improvement yields []" && conditionalsHold(u, lootCtx) {
                guard let st = u.stats else { continue }
                for stat in order where st[stat] != 0 {
                    var add = st[stat]
                    if u.conditionals.contains(where: { $0.pattern == "(modified by game speed)" }) { add = Stats.f32(add * speed.modifier) }
                    if u.conditionals.contains(where: { $0.pattern == "(modified by game progress up to []%)" }) { add = Stats.f32(add * gameProgressModifier(u, civId: unit.civId)) }
                    loot[stat, default: 0] = Stats.f32(loot[stat, default: 0] + add)
                }
            }
        }
        for u in (unit.promotionUniques + civUniques(unit.civId)) where u.pattern == "[]% Yield from pillaging tiles" {
            for k in loot.keys { loot[k] = Stats.f32(loot[k]! * Stats.f32(1 + u.double(0) / 100)) }
        }
        if let ci = civIndex(unit.civId) {
            for stat in order { guard let v = loot[stat], v != 0 else { continue }
                switch stat {
                case "Gold": civs[ci].gold += Double(Int(v)); goldTrace(civs[ci].id, Double(Int(v)))
                case "Science": addScience(civId: civs[ci].id, Int(v))
                case "Culture": civs[ci].cultureStored += Double(Int(v))
                case "Faith": civs[ci].faithStored += Double(Int(v))
                case "Happiness": break
                default:
                    // Unciv closestCity.addStat: food to the granary, production to the current construction
                    if let city = cities(of: unit.civId).min(by: { $0.coord.distance(to: t.coord) < $1.coord.distance(to: t.coord) }), let cx = cityIndex(city.id) {
                        if stat == "Food" { cities[cx].foodStored += Double(Int(v)) } else { addProductionPoints(cityIndex: cx, Int(v)) }
                    }
                }
            }
        }
        // Unciv UnitActionsPillage `Stats.notify(suffix)`: the civ-wide stats (Stat.statsWithCivWideField: Gold, Science,
        // Culture, Faith, Happiness) and the closest city's, each told when not empty, the city's first with " which has
        // been sent to [city]"; Stats.toStringWithoutIcons is "+N Name" joined by ", " in Stat order, the amount by
        // Number.tr and the name translated
        let closestLootCity = cities(of: unit.civId).min(by: { $0.coord.distance(to: t.coord) < $1.coord.distance(to: t.coord) })
        func lootText(_ stats: [String]) -> String {
            stats.map { s in let v = loot[s]!; return (v > 0 ? "+" : "") + Translations.shared.numberTr(Double(Int(v))) + " " + Translations.shared.tr(s) }.joined(separator: ", ")
        }
        let civWide: Set<String> = ["Gold", "Science", "Culture", "Faith", "Happiness"]
        let globalLoot = order.filter { civWide.contains($0) && (loot[$0] ?? 0) != 0 }
        let cityLoot = closestLootCity == nil ? [] : order.filter { !civWide.contains($0) && (loot[$0] ?? 0) != 0 }
        if !cityLoot.isEmpty, let c = closestLootCity {
            notify(unit.civId, "We have looted [\(lootText(cityLoot))] from a [\(lootImp)] which has been sent to [\(c.name)]", category: .War, icons: ["ImprovementIcons/" + lootImp, "War"], coord: t.coord)
        }
        if !globalLoot.isEmpty { notify(unit.civId, "We have looted [\(lootText(globalLoot))] from a [\(lootImp)]", category: .War, icons: ["ImprovementIcons/" + lootImp, "War"], coord: t.coord) }
        // Unciv `tile.setPillaged()  // Also triggers reassignPopulation` (TileImprovementFunctions.swift)
        setPillaged(at: t.coord)
        // Unciv: `if (tile.resource != null) tile.getOwner()?.cache?.updateCivResources()` - right after setPillaged
        if let owner = map[t.coord]?.ownerCivId, map[t.coord]?.resource != nil { updateCivResources(owner) }
        // Unciv: `unit.hasUnique(NoMovementToPillage, checkCivInfoUniques = true)` - Denmark's is a civ unique
        // "<for [Melee] units>" - then useMovementPoints(1f), which also resets the fortification
        let pillageCtx = UniqueContext(civId: unit.civId, unit: unit, tile: map[unit.coord])
        let freePillage = (unit.promotionUniques + civUniques(unit.civId)).contains { $0.pattern == "No movement cost to pillage" && conditionalsHold($0, pillageCtx) }
        if !freePillage { useMovementPoints(unitId, 1) }
        if pillagingImprovement {   // only Improvements heal HP
            // Unciv: `healAmount = 25f`, × toPercent() of each PercentHealthFromPillaging (unit and civ), healBy(toInt())
            var healAmount: Float = 25
            for u in unit.promotionUniques + civUniques(unit.civId) where u.pattern == "[]% Health from pillaging tiles" && conditionalsHold(u, pillageCtx) { healAmount *= Float(100 + u.double(0)) / 100 }
            healBy(unitId: unitId, Int(healAmount))
        }
        // Unciv: `if (tile.getImprovementToPillage()?.hasUnique(DestroyedWhenPillaged) == true) tile.removeImprovement()` -
        // asked AFTER the pillage, of whatever is still left to pillage there.
        if let left = map[t.coord]?.improvementToPillage, rs.improvements[left]?.uniques.contains("Destroyed when pillaged") == true {
            removeImprovement(at: t.coord)
        }
    }

    /// Unciv TileImprovement.getTurnsToBuild: the improvement's own time, scaled by game speed and by the
    /// unit's own build-rate uniques (god mode finishes everything next turn).
    func improvementBuildTurns(_ imp: String, unit: Unit) -> Int {
        if settings.godMode { return 1 }
        let base = Double(rs.improvements[imp]?.turnsToBuild ?? 5)
        return max(1, Int((base * speed.improvementBuildLengthModifier / improvementRateIncrease(unit, imp) * improvementTimeMultiplier(unit, imp)).rounded()))
    }

    func setUp(unitId: Int) {
        guard let i = unitIndex(unitId), units[i].def.mustSetUp, !units[i].isSetUp, units[i].movementLeft > 0 else { return }
        units[i].isSetUp = true
        // Unciv SetUp action: `unit.action = SetUp.value` - being set up is a value of the one `action` field, so it
        // replaces a Sleep / Fortify / Guard / Explore / move order (MapUnit.automated, our .automate, is its own field)
        if units[i].order != .automate { units[i].order = .none }
        useMovementPoints(unitId, 1)   // Unciv SetUp action: `unit.useMovementPoints(1f)`
    }

    // MARK: great people

    enum GreatPersonAction: String, CaseIterable {
        case improvement, hurryTech, hurryProduction, tradeMission, goldenAge, citadel, hurryPolicy
    }

    /// Fishing fleets: "May create improvements on water resources" – the improvement the tile's resource wants.
    /// Unciv getWaterImprovementAction: "May create improvements on water resources" builds the tile resource's improving improvement.
    func waterImprovement(for unit: Unit) -> String? {
        guard unit.def.uniques.contains("May create improvements on water resources"), let t = map[unit.coord], t.isWater, t.ownerCivId == unit.civId,
              let res = t.resource, let r = rs.resources[res] else { return nil }
        if let rev = r.revealedBy, !(civ(unit.civId)?.techs.contains(rev) ?? false) { return nil }
        for imp in (rs.resourceImprovements[res] ?? []).sorted() {
            guard let impDef = rs.improvements[imp], t.improvement != imp else { continue }
            guard impDef.terrainsCanBeBuiltOn.isEmpty || impDef.terrainsCanBeBuiltOn.contains(where: { t.terrainNames.contains($0) }) || impDef.terrainsCanBeBuiltOn.contains("Water") || impDef.uniques.contains("Can only be built on [Water] tiles") else { continue }
            if let tech = impDef.techRequired, !(civ(unit.civId)?.techs.contains(tech) ?? false) { continue }
            return imp
        }
        return nil
    }

    /// Unciv UnitActionModifiers.usagesLeft: nil when the action is not limited.
    func actionUsesLeft(_ unit: Unit, _ unique: Unique) -> Int? {
        let key = unique.text.components(separatedBy: " <").first ?? unique.text
        let limit = unique.conditionals.first(where: { $0.pattern == "[] times" })?.int(0) ?? (unique.conditionals.contains(where: { $0.pattern == "once" }) ? 1 : nil)
        guard let limit else { return nil }
        return limit - (unit.abilityToTimesUsed[key] ?? 0)
    }

    /// Unciv UnitActionModifiers.getMaxUsages: the unique's "[] times" (the largest, or 1 for "once"), plus the
    /// "[] additional time(s)" of every unit unique of the same type whose text without conditionals is the same;
    /// nil when the action is not limited.
    func actionMaxUsages(_ unit: Unit, _ unique: Unique) -> Int? {
        let key = unique.text.components(separatedBy: " <").first ?? unique.text
        let extraTimes = unit.promotionUniques   // unit.getMatchingUniques(actionUnique.type): base unit, type, promotions, statuses
            .filter { $0.pattern == unique.pattern && ($0.text.components(separatedBy: " <").first ?? $0.text) == key }
            .flatMap { $0.conditionals.filter { $0.pattern == "[] additional time(s)" } }
            .reduce(0) { $0 + $1.int(0) }
        if let times = unique.conditionals.filter({ $0.pattern == "[] times" }).map({ $0.int(0) }).max() { return times + extraTimes }
        if unique.conditionals.contains(where: { $0.pattern == "once" }) { return 1 + extraTimes }
        return nil
    }
    /// Unciv UnitActionModifiers.usagesLeft: getMaxUsages minus abilityToTimesUsed[text without conditionals]; nil when
    /// the action is not limited.
    func actionUsagesLeft(_ unit: Unit, _ unique: Unique) -> Int? {
        actionMaxUsages(unit, unique).map { $0 - (unit.abilityToTimesUsed[unique.text.components(separatedBy: " <").first ?? unique.text] ?? 0) }
    }
    /// Unciv UnitActionModifiers.getUsableUnitActionUniques(unit, type).firstOrNull(): the unit's first unique of that
    /// kind that does not merely extend another ("[] additional time(s)") and has uses left (canUse).
    func firstUsableActionUnique(_ unit: Unit, _ pattern: String) -> Unique? {
        unit.promotionUniques.first { u in u.pattern == pattern && u.conditional("[] additional time(s)") == nil && (actionUsagesLeft(unit, u).map { $0 > 0 } ?? true) }
    }

    /// Unciv UnitActionModifiers.getSideEffectString: "(uses left/max, stat cost, stockpile cost, ☠ or movement➡,
    /// -promotion)" - the death mark when the action consumes the unit, or on the last use of one consumed after it;
    /// otherwise the movement it spends (getMovementPointsToUse). Empty when there is nothing to say.
    func actionSideEffectString(_ unit: Unit, _ unique: Unique, defaultAllMovement: Bool = false) -> String {
        var effects: [String] = []
        let maxUsages = actionMaxUsages(unit, unique)
        let usagesLeft = actionUsagesLeft(unit, unique)
        if let maxUsages, let usagesLeft { effects.append("\(usagesLeft)/\(maxUsages)") }
        let statCosts = unique.conditionals.filter { $0.pattern == "costs [] stats" }
        if !statCosts.isEmpty {
            // Stats.toStringOnlyIcons(false): "amount icon" per non-zero stat in Production, Food, Gold, Science, Culture, Happiness, Faith order
            var cost = Stats()
            for c in statCosts { if let st = c.stats { cost += st } }
            var parts: [String] = []
            for (v, icon) in [(cost.production, "⚙"), (cost.food, "⁂"), (cost.gold, "¤"), (cost.science, "⍾"), (cost.culture, "♪"), (cost.happiness, "⌣"), (cost.faith, "☮")] where v != 0 { parts.append("\(Int(v)) \(icon)") }
            effects.append(Translations.mapFontIcons(parts.joined(separator: ", ")))
        }
        let stockpileCosts = unique.conditionals.filter { $0.pattern == "costs [] []" }
        if !stockpileCosts.isEmpty { effects.append(stockpileCosts.map { "\($0.int(0)) \(L($0.param(1)))" }.joined(separator: " ")) }
        if unique.conditionals.contains(where: { $0.pattern == "by consuming this unit" })
            || unique.conditionals.contains(where: { $0.pattern == "after which this unit is consumed" }) && usagesLeft == 1 {
            effects.append("☠")
        } else {
            // Unciv getMovementPointsToUse
            let movement: Int
            if unique.conditionals.contains(where: { $0.pattern == "for all movement" }) { movement = Int(maxMovement(of: unit)) }
            else { movement = unique.conditionals.filter { $0.pattern == "for [] movement" || $0.pattern == "requires [] movement" }.map { $0.int(0) }.max() ?? (defaultAllMovement ? Int(maxMovement(of: unit)) : 1) }
            effects.append("\(movement)➡")
        }
        // Unciv: "-" and the promotion's font icon, for a promotion the ruleset has
        for c in unique.conditionals where c.pattern == "removing the [] promotion/status" && rs.promotions[c.param(0)] != nil { effects.append("-" + L(c.param(0))) }
        return effects.isEmpty ? "" : "(" + effects.joined(separator: ", ") + ")"
    }

    /// Unciv UnitActionModifiers.actionTextWithSideEffects: the translated title, then the side-effect string.
    func actionTextWithSideEffects(_ text: String, _ unique: Unique, _ unit: Unit) -> String {
        let side = actionSideEffectString(unit, unique)
        return side.isEmpty ? L(text) : L(text) + " " + side
    }

    /// Unciv UnitActionModifiers.activateSideEffects: movement cost, limited uses, "by consuming this unit", "after which this unit is consumed",
    /// stat and stockpile costs, removing a promotion/status. Returns true when the unit was consumed.
    @discardableResult
    func activateActionSideEffects(unitId: Int, unique: Unique, defaultAllMovement: Bool = false) -> Bool {
        guard let i = unitIndex(unitId) else { return true }
        let key = unique.text.components(separatedBy: " <").first ?? unique.text
        let civId = units[i].civId
        // Unciv getMovementPointsToUse + unit.useMovementPoints (which also resets turnsFortified)
        let cost: Double
        if unique.conditionals.contains(where: { $0.pattern == "for all movement" }) { cost = maxMovement(of: units[i]) }
        else { cost = unique.conditionals.filter { $0.pattern == "for [] movement" || $0.pattern == "requires [] movement" }.map { Double($0.int(0)) }.max() ?? (defaultAllMovement ? maxMovement(of: units[i]) : 1) }
        useMovementPoints(unitId, cost)
        // Unciv walks every modifier even after `unit.consume()`: a stat cost on a consuming action is still paid.
        var consumed = false
        for c in unique.conditionals {
            switch c.pattern {
            case "by consuming this unit":
                consumeUnit(unitId); consumed = true
            case "[] times", "once":
                guard let ui = unitIndex(unitId) else { continue }
                if actionUsesLeft(units[ui], unique) == 1 && unique.conditionals.contains(where: { $0.pattern == "after which this unit is consumed" }) { consumeUnit(unitId); consumed = true; continue }
                units[ui].abilityToTimesUsed[key, default: 0] += 1
            case "costs [] stats":
                if let st = c.stats, let ci = civIndex(civId) { civs[ci].gold -= st.gold; addScience(civId: civs[ci].id, -Int(st.science)); civs[ci].cultureStored -= st.culture; civs[ci].faithStored -= st.faith }
            case "costs [] []":
                if let r = rs.resources[c.param(1)], r.isStockpiled, let ci = civIndex(civId) { civs[ci].resourceStockpiles[r.name, default: 0] -= c.int(0) }
            case "removing the [] promotion/status":
                guard let ui = unitIndex(unitId) else { continue }
                if units[ui].statuses[c.param(0)] != nil { removeStatus(unitId: unitId, c.param(0)) } else { removePromotion(unitId: unitId, c.param(0)) }   // Unciv promotions.removePromotion
            default: break
            }
        }
        return consumed
    }

    func greatPersonActions(_ unit: Unit) -> [(String, GreatPersonAction)] {
        var out: [(String, GreatPersonAction)] = []
        let def = unit.def
        // Unciv getWaterImprovementAction: `.takeIf { unit.hasMovement() }` - a boat that arrives with no movement builds next turn
        if let imp = waterImprovement(for: unit), unit.movementLeft > 0 { out.append(("Build \(imp)", .improvement)) }
        // Unciv UnitActionsFromUniques.getImprovementConstructionActionsFromGeneralUnique: "Try to skip Improvements we
        // can never build" (a permanent building problem), then the action is usable only when
        // `resourcesAvailable && unit.hasMovement() && canBuildImprovement(improvement, unit.cache.state)
        //  && !tile.isMarkedForCreatesOneImprovement() && canActivateSideEffects`. We had judged ownership, the
        // terrain list and the resource by hand, so a great person built on Forest/Jungle/Marsh without the tech
        // that removes it, and a Samurai made Fishing Boats without Sailing.
        if let imp = def.instantImprovement, let tile = map[unit.coord], let impDef = rs.improvements[imp],
           !improvementBuildingProblems(impDef, civId: unit.civId, tile: tile, unit: unit).contains(where: { $0.permanent }) {
            // Unciv `improvement.getMatchingUniques(ConsumesResources)` - no state, GameContext.EmptyState - against getCivResourcesByName
            let counts = resourceCounts(unit.civId)
            let resourcesAvailable = !impDef.uniqueObjects.contains { $0.pattern == "Consumes [] []" && conditionalsHold($0, UniqueContext(civId: -1)) && (counts[$0.param(1)] ?? 0) < $0.int(0) }
            // Unciv getUsableUnitActionUniques / canActivateSideEffects: conditionals and remaining uses
            let iu = def.uniqueObjects.first { $0.pattern == "Can instantly construct a [] improvement" }
            let usable = iu.map { u in conditionalsHold(u, UniqueContext(civId: unit.civId, unit: unit, tile: tile)) && (actionUsesLeft(unit, u) ?? 1) > 0 } ?? true
            if resourcesAvailable && unit.movementLeft > 0 && canBuildImprovement(impDef, on: tile, civId: unit.civId, unit: unit)
                && !isMarkedForCreatesOneImprovement(unit.coord) && usable { out.append(("Build \(imp)", .improvement)) }
        }
        // Unciv getHurryResearchActions: unusable while there is no current research or it carries "Cannot be hurried"
        if unit.movementLeft > 0, def.uniques.contains("Can hurry technology research"), let t = civ(unit.civId)?.currentTech, rs.techs[t]?.uniques.contains("Cannot be hurried") != true { out.append(("Discover technology", .hurryTech)) }
        if unit.movementLeft > 0, def.uniques.contains("Can generate a large amount of culture") { out.append(("Hurry Policy", .hurryPolicy)) }   // Unciv UnitActionsGreatPerson.getHurryPolicyActions
        let canHurryBuilding = def.uniques.contains("Can speed up construction of a building")
        let canHurryWonder = def.uniques.contains("Can speed up the construction of a wonder")   // Unciv UniqueType.HurryWonder
        if unit.movementLeft > 0, canHurryBuilding || canHurryWonder, city(at: unit.coord)?.civId == unit.civId, case .building(let b)? = city(at: unit.coord)?.currentProduction,
           rs.buildings[b]?.uniques.contains("Cannot be hurried") != true, canHurryBuilding || rs.buildings[b]?.isWonder == true { out.append(("Hurry production", .hurryProduction)) }
        if unit.movementLeft > 0, def.uniqueObjects.contains(where: { $0.pattern == "Can undertake a trade mission with City-State, giving a large sum of gold and [] Influence" }), let t = map[unit.coord], let owner = t.ownerCivId, owner != unit.civId, civ(owner)?.isCityState == true, !areAtWar(unit.civId, owner) { out.append(("Trade mission", .tradeMission)) }   // Unciv: the tile's owning city is a city-state
        if unit.movementLeft > 0, def.uniqueObjects.contains(where: { $0.pattern == "Empire enters a []-turn Golden Age" }) { out.append(("Start Golden Age", .goldenAge)) }
        return out
    }

    /// Unciv UnitActionsGreatPerson: HurryBuilding adds min((300 + 30 × population) × speed, remaining work − 1);
    /// HurryWonder adds the full amount, so a wonder can be finished outright.
    func hurryProductionPoints(for c: City, uncapped: Bool = false) -> Int {
        guard let p = c.currentProduction else { return 0 }
        let amount = Double(300 + 30 * c.population) * speed.productionCostModifier
        if uncapped { return max(0, Int(amount)) }
        let remaining = Double(productionCost(p, for: c.civId)) - c.productionStored
        return max(0, Int(min(amount, remaining - 1)))
    }

    func performGreatPersonAction(unitId: Int, _ action: GreatPersonAction) {
        guard let i = unitIndex(unitId) else { return }
        let unit = units[i]
        guard let ci = civIndex(unit.civId) else { return }
        let viaInstantUnique = unit.def.instantImprovement != nil
        switch action {
        case .improvement, .citadel:
            guard let imp = unit.def.instantImprovement ?? waterImprovement(for: unit), map[unit.coord] != nil else { return }
            // Unciv UnitActionsFromUniques: getImprovementConstructionActionsFromGeneralUnique runs
            // `unitTile.setImprovement(improvement, unit.civ, unit)` then `unit.civ.cache.updateViewableTiles()`;
            // getWaterImprovementAction runs `tile.setImprovement(improvement, unit.civ, unit)`. setImprovement does
            // the rest: the queue keeps its non-road work, "Removes removable features when built" (Fallout too),
            // the owning city's stats, resources and deferred reassignment, and the improvement's own triggers -
            // the Citadel's "Gain control over [] tiles in a []-tile radius" among them. We set the tile fields by
            // hand, dropped Forest/Jungle/Marsh and cleared the whole queue, refreshed a city that is not Unciv's
            // owningCity (or the civ's stats when there was none) and took the tiles over with rules of our own.
            setImprovement(at: unit.coord, imp, civToActivateBroaderEffects: unit.civId, unitId: unitId)
            if viaInstantUnique { updateExploration(for: unit.civId) }
        case .hurryTech:
            // Unciv UnitActionsGreatPerson.getHurryResearchActions: addScience(getScienceFromGreatScientist()) — science of the last 8 turns × speed science cost modifier
            if let t = civs[ci].currentTech, rs.techs[t]?.uniques.contains("Cannot be hurried") != true {
                addScience(civId: civs[ci].id, scienceFromGreatScientist(civs[ci]))   // Unciv TechManager.getScienceFromGreatScientist (Float)
            }
        case .hurryPolicy:
            // Unciv PolicyManager.getCultureFromGreatWriter: culture of the last 8 turns × speed culture cost modifier
            // Unciv: `policies.addCulture(policies.getCultureFromGreatWriter())` - through addCulture, so the
            // policy picker opens when this makes a policy affordable; the amount is an Int times a Float.
            let gained = Double(cultureFromGreatWriter(civs[ci]))
            addCulture(ci, gained); civs[ci].totalCulture += gained
        case .hurryProduction:
            guard let c = city(at: unit.coord), let idx = cityIndex(c.id) else { return }
            // Unciv HurryWonder pays the full amount; HurryBuilding is the capped one
            let uncapped: Bool = {
                guard unit.def.uniques.contains("Can speed up the construction of a wonder") else { return false }
                if case .building(let b)? = c.currentProduction { return rs.buildings[b]?.isWonder == true }
                return false
            }()
            cities[idx].productionStored += Double(hurryProductionPoints(for: c, uncapped: uncapped))
        case .tradeMission:
            // Unciv UnitActionsGreatPerson: (350 + 50 × era number) × speed, scaled by "[]% Gold from Great Merchant trade missions"; influence from the unique.
            guard let t = map[unit.coord], let owner = t.ownerCivId else { return }
            let eraNumber = rs.eras.firstIndex { $0.name == civs[ci].eraName } ?? 0
            var gold = Double(350 + 50 * eraNumber) * speed.goldCostModifier
            for gu in unit.promotionUniques + civUniques(unit.civId) where gu.pattern == "[]% Gold from Great Merchant trade missions" { gold *= 1 + gu.double(0) / 100 }
            let influence = unit.def.uniqueObjects.first { $0.pattern == "Can undertake a trade mission with City-State, giving a large sum of gold and [] Influence" }?.double(0) ?? 30
            civs[ci].gold += gold.rounded(.down); goldTrace(unit.civId, gold.rounded(.down))
            if let oi = civIndex(owner), civs[oi].isCityState { addInfluence(cityState: civs[oi].id, major: unit.civId, influence) }
            // Unciv: `[${goldEarnedInt.tr()}] gold and [${influenceEarned.tr()}] influence` - both through Number.tr(), so a
            // four-figure sum is grouped ("1,005", a test game, t=299); no location
            notify(unit.civId, "Your trade mission to [\(civ(owner)?.nation ?? "?")] has earned you [\(Translations.shared.numberTr(Double(Int(gold))))] gold and [\(Translations.shared.numberTr(influence))] influence!", category: .General, icons: [civ(owner)?.nation ?? "", "Gold", "Culture"])
        case .goldenAge:
            let turns = unit.def.uniqueObjects.first { $0.pattern == "Empire enters a []-turn Golden Age" }?.int(0) ?? 8
            startGoldenAge(unit.civId, turns: turns)
        }
        // Unciv: only `unit.consume()` fires the "<upon expending a [] unit>" triggers - a consuming action modifier
        // goes through consume() too - while a Work Boat's water improvement is a plain `unit.destroy()`. We fired
        // them before every action, a Samurai's Fishing Boats and a boat's own improvement included.
        switch action {
        case .improvement, .citadel:
            // Unciv: "Can instantly construct" follows its action modifiers (Samurai keeps going); water improvements destroy the unit.
            if viaInstantUnique, let iu = unit.def.uniqueObjects.first(where: { $0.pattern == "Can instantly construct a [] improvement" }) { activateActionSideEffects(unitId: unitId, unique: iu) }
            else { destroyUnit(unitId) }
        case .goldenAge:
            // Unciv getTriggerUniqueActions: `UnitActionModifiers.activateSideEffects(unit, unique)`, default movement cost
            if let gu = unit.def.uniqueObjects.first(where: { $0.pattern == "Empire enters a []-turn Golden Age" }) { activateActionSideEffects(unitId: unitId, unique: gu) }
            else { consumeUnit(unitId) }
        default:
            consumeUnit(unitId)   // Unciv hurry research / production and trade missions call unit.consume()
        }
    }

    func nearestCity(to c: HexCoord, civId: Int) -> Int? {
        cities(of: civId).min { $0.coord.distance(to: c) < $1.coord.distance(to: c) }?.id
    }

    // MARK: spaceship

    func canAddSpaceshipPart(_ unit: Unit) -> Bool {
        guard unit.def.isSpaceshipPart, let c = city(at: unit.coord), c.civId == unit.civId, c.isCapital else { return false }
        return true
    }

    func addSpaceshipPart(unitId: Int) {
        guard let i = unitIndex(unitId), canAddSpaceshipPart(units[i]), let ci = civIndex(units[i].civId) else { return }
        let part = units[i].name
        // Unciv currentsSpaceshipParts.add(name, 1): a Counter (LinkedHashMap) - a new key goes last
        if (civs[ci].spaceshipParts[part] ?? 0) == 0 { civs[ci].spaceshipPartOrder.removeAll { $0 == part }; civs[ci].spaceshipPartOrder.append(part) }
        civs[ci].spaceshipParts[part, default: 0] += 1
        destroyUnit(unitId)   // Unciv getAddInCapitalActions: `unit.destroy()`
        // Unciv's action records nothing: the part is counted at the civ's own TurnManager.endTurn (updateWinningCiv, "Maybe
        // we did something this turn to win"), or - a human's own action - by WorldScreen.update's checkForVictory
        // (GameController.addSpaceshipPart). Ours declared the victory here, in the middle of an AI's automation: the
        // GameHasBeenWon alerts came before that civ's end of turn, and GameInfo.nextTurn's `player.victoryManager.hasWon()`
        // check after automateTurn (GameInfo.kt:458) stopped the multi-turn AutoPlay a turn before Unciv's does.
    }

    func spaceshipProgress(_ civ: Civilization) -> (have: Int, needed: Int) {
        let needed = rs.victory("Scientific")?.requiredSpaceshipParts ?? []
        var remaining = needed
        var have = 0
        for (part, count) in civ.spaceshipParts {
            for _ in 0..<count { if let idx = remaining.firstIndex(of: part) { remaining.remove(at: idx); have += 1 } }
        }
        return (have, needed.count)
    }

    // MARK: exploration events
}

struct MovementMemory: Codable, Equatable {
    var coord: HexCoord
    var type: String
}

enum UnitOrder: Codable, Equatable {
    case none
    case sleep
    case fortify
    case build(String)          // improvement being built on the current tile
    case moveTo(HexCoord)       // multi-turn move
    case explore                // auto explore
    case sleepUntilHealed
    case fortifyUntilHealed
    case automate               // worker automation
    case guardPost              // Unciv Guard: holds the post, never withdraws
    case connectRoad(HexCoord)  // Unciv ConnectRoad: build a road from here to the target
}

struct Unit: Codable, Identifiable {
    let id: Int
    var civId: Int
    var name: String
    var coord: HexCoord
    /// Unciv MapUnit.currentMovement is a Float: every change lands on a Float, so 4 - 1/3 - 1/3 - ... leaves
    /// crumbs like 2.4e-7 that still count as movement - enough for Byzantium's pillaging Knight to take one more step.
    var movementLeft: Double { didSet { movementLeft = Double(Float(movementLeft)) } }
    var health: Int = 100
    var order: UnitOrder = .none
    /// Unciv MapUnit.automated: a field of its own beside `action` (our order) - set by Automate and by Connect road,
    /// cleared only by Stop automation, the road's end (RoadToAutomation.stopAndCleanAutomation) and a capture; Fortify,
    /// Sleep, Explore or a move the player orders afterwards leave it set, and the unit's doAction automates it again.
    /// A legacy `.automate` order counts as automated with no action.
    @Lenient var automated: Bool = false
    var isAutomated: Bool { automated || order == .automate || { if case .connectRoad = order { return true }; return false }() }
    @Lenient var originalCiv: Int = -1     // Unciv originalOwner: civ that built the unit (kept through captures)
    /// Unciv has no such field: it asks `attacksThisTurn` (interceptions included). Kept as a read-only alias.
    var hasAttacked: Bool { attacksThisTurn > 0 }
    var turnsFortified: Int = 0
    var xp: Int = 0
    var promotions: [String] = []
    var isSetUp: Bool = false
    /// Unciv MapUnit.movementMemories / mostRecentMoveType: where the unit was at the last turn boundaries, for the "Show unit movement arrows" overlay.
    @Lenient var movementMemories: [MovementMemory] = []
    @Lenient var mostRecentMoveType: String = "UnitMoved"   // UnitMoved | UnitAttacked | UnitWithdrew | UnitTeleported
    mutating func addMovementMemory() {
        movementMemories.append(MovementMemory(coord: coord, type: mostRecentMoveType))
        while movementMemories.count > 2 { movementMemories.removeFirst() }
    }
    /// Unciv MapUnit.attacksSinceTurnStart: every tile this unit attacked since the start of its most recent turn,
    /// for the "UnitHasAttacked" arrows of the movement overlay.
    @Lenient var attacksSinceTurnStart: [HexCoord] = []
    var spentPromotionXP: Int = 0    // legacy: one-shot promotions taken before numberOfPromotions existed
    @Lenient var numberOfPromotions: Int? = nil   // Unciv UnitPromotions.numberOfPromotions; nil = legacy save where xp was lifetime XP
    var religion: String? = nil      // religious units carry a religion
    var charges: Int = 0             // remaining spread/remove charges
    @Lenient var abilityToTimesUsed: [String: Int] = [:]   // Unciv MapUnit.abilityToTimesUsed (unit action "[] times" / "once")
    var customName: String? = nil    // great people get a name from the ruleset groups
    /// Unciv MapUnit.shortDisplayName(): "[instanceName]" or "[name]", the brackets included
    var shortDisplayName: String { "[\(customName ?? name)]" }
    var actedThisTurn: Bool = false  // prophets may only use one "hasn't used other actions" ability
    @Lenient var attacksThisTurn: Int = 0
    @Lenient var escorting: Bool = false   // Unciv MapUnit.escorting: moves together with the other unit on its tile
    @Lenient var due: Bool = true   // Unciv MapUnit.due: false after "Skip turn" until the next turn
    @Lenient var religiousStrengthLost: Int = 0   // Unciv: missionaries in foreign land without open borders lose spread strength
    @Lenient var roadConnectionPath: [HexCoord] = []   // Unciv MapUnit.automatedRoadConnectionPath
    @Lenient var statuses: [String: Int] = [:]    // Unciv MapUnit.statusMap: temporary promotions (name -> turns left, counted down at the start of turn)
    @Lenient var isTransported: Bool = false   // Unciv MapUnit.isTransported: carried by a carrier rather than based in a city

    var def: UnitDef { Ruleset.shared.units[name]! }
    var isCivilian: Bool { def.isCivilian }
    var isMilitary: Bool { !def.isCivilian }
    var maxMovement: Double { Double(def.movement) + Double(promotionUniques.filter { $0.pattern == "[] Movement" && $0.conditionals.isEmpty }.reduce(0) { $0 + $1.int(0) }) }
    var canAct: Bool { movementLeft > 0 }
    /// Unciv MapUnit: promotions and statuses plus BaseUnit.rulesetUniqueObjects, which carries the uniques of the unit's type as well
    /// Unciv MapUnit.updateUniques → tempUniquesMap: `baseUnit.rulesetUniqueObjects` (the unit's own uniques, then its
    /// type's), then the promotions as `promotions.promotions` - a `HashSet<String>` - walks them, then the statuses
    /// as `statusMap` - a `HashMap<String, UnitStatus>` - walks them.
    var promotionUniques: [Unique] {
        let rs = Ruleset.shared
        var out = def.uniqueObjects + (rs.unitTypes[def.unitType]?.uniqueObjects ?? [])
        for p in (promotions.count > 1 ? javaHashMapOrder(promotions) : promotions) { out += rs.promotions[p]?.uniqueObjects ?? [] }
        if !statuses.isEmpty { for st in javaHashMapOrder(statuses.keys.sorted()) { out += rs.promotions[st]?.uniqueObjects ?? [] } }
        return out
    }
    /// Unciv MapUnit.hasStatus
    func hasStatus(_ name: String) -> Bool { statuses[name] != nil }
    /// Unciv numberOfPromotions (legacy saves: the XP-bought promotions and one-shots taken)
    var promotionNumber: Int { numberOfPromotions ?? (promotions.filter { Ruleset.shared.promotions[$0].map { !$0.isOneShot && !$0.uniques.contains("This Promotion is free") } ?? false }.count + spentPromotionXP) }
    /// Unciv UnitPromotions.XP: XP not yet spent (legacy saves stored lifetime XP)
    var currentXP: Int { numberOfPromotions != nil ? xp : max(0, xp - 5 * promotionNumber * (promotionNumber + 1)) }
    /// Unciv UnitPromotions.xpForNextPromotion without the civ's cost modifier (display): 10, 20, 30… per promotion
    var xpForNextPromotion: Int { 10 * (promotionNumber + 1) }
    var promotionsAvailable: Int { var n = promotionNumber, rem = currentXP, k = 0; while rem >= 10 * (n + 1) { rem -= 10 * (n + 1); n += 1; k += 1 }; return k }
    /// Unciv totalXpProduced: XP plus what was spent on promotions
    var totalXpProduced: Int { currentXP + promotionNumber * (promotionNumber + 1) * 5 }
    var isGreatPerson: Bool { def.greatPersonType != nil || def.isGreatPerson }
}


// MARK: - Notifications (Unciv Civilization.addNotification with category / icons / actions)

extension GameState {
    func notify(_ civId: Int, _ text: String, at coord: HexCoord? = nil) {
        notify(civId, text, category: nil, icons: [], actions: coord.map { defaultActions(at: $0) } ?? [], coord: coord)
    }
    func notify(_ civId: Int, _ text: String, category: NotificationCategory?, icons: [String] = [], actions: [NotificationAction] = [], coord: HexCoord? = nil) {
        // Unciv keeps the NotificationIcon constants' values (texture paths) and prefixes a building or an improvement
        // with its folder, since NotificationIcon.getImage only looks bare names up among techs, nations, units,
        // promotions and resources. Ours passed the constants' names ("Growth") and bare building names.
        let icons = icons.map { uncivNotificationIconString($0) }
        // Unciv addNotification(text, location, ...) wraps the location in a LocationAction: a notification given only a
        // place goes there when tapped. Ours kept the coordinate beside an empty action list, and a tap did nothing.
        let actions = actions.isEmpty ? (coord.map { [NotificationAction.location($0)] } ?? []) : actions
        if EvLog.on && EvLog.notif {   // Unciv prints it before addNotification drops an AI civ's notification
            let cat = (category ?? GameState.inferCategory(text)).rawValue
            ev(civId, "NOTIF", cat, EvLog.name(text.replacingOccurrences(of: "\n", with: "\\n")), icons.isEmpty ? "-" : EvLog.name(icons.joined(separator: "|")))
            ev(civId, "NOTIFA", actions.isEmpty ? "-" : EvLog.name(actions.map(evNotificationAction).joined(separator: "|")))
        }
        // Unciv addNotification: `if (playerType == PlayerType.AI) return` - no one reads an AI civ's notifications
        guard let i = civIndex(civId), !civs[i].isBarbarian, civs[i].isPlayer else { return }
        // keep the three parallel arrays aligned even if an older save left them uneven
        while civs[i].notificationCoords.count < civs[i].notifications.count { civs[i].notificationCoords.append(nil) }
        while civs[i].notificationMeta.count < civs[i].notifications.count { civs[i].notificationMeta.append(NotificationMeta()) }
        civs[i].notifications.append(text)
        let loc: HexCoord? = coord ?? actions.compactMap { if case .location(let c) = $0 { return c }; return nil }.first
        civs[i].notificationCoords.append(loc)
        civs[i].notificationMeta.append(NotificationMeta(category: category ?? GameState.inferCategory(text), icons: icons, actions: actions))
    }
    /// NOTIFA: an action as the reference's EvLog prints it - Unciv's class name and serialized fields, the unit id left out.
    func evNotificationAction(_ a: NotificationAction) -> String {
        func p(_ c: HexCoord) -> String { let u = uncivPosition(c); return "\(u.x);\(u.y)" }
        switch a {
        case .location(let c): return "LocationAction(location=\(p(c)))"
        case .city(let c): return "CityAction(city=\(p(c)))"
        case .tech(let t): return "TechAction(techName=\(t))"
        case .diplomacy(let n): return "DiplomacyAction(otherCivName=\(n),showTrade=false)"
        case .diplomacyTrade(let n): return "DiplomacyAction(otherCivName=\(n),showTrade=true)"
        case .unit(let c, _): return "MapUnitAction(location=\(p(c)))"
        case .civilopedia(let l): return "CivilopediaAction(link=\(l))"
        case .overview(let page, let sel): return "OverviewAction(page=\(page),select=\(sel))"
        case .policy(let sel): return "PolicyAction(select=\(sel))"
        case .espionage: return "EspionageAction()"
        case .religion(let r): return "ReligionAction(religionName=\(r))"
        case .link(let u): return "LinkAction(url=\(u))"
        case .promoteUnit(let n, let c, _): return "PromoteUnitAction(name=\(n),location=\(p(c)))"
        case .mayaLongCount: return "MayaLongCountAction()"
        }
    }
    /// Unciv LocationAction + CityAction when the tile is a city centre.
    /// Unciv MapUnit.displayName: "[name]", or "instanceName ([name])" for a named unit, then " ([religion])" for one
    /// that carries a religion.
    func uncivDisplayName(_ u: Unit) -> String {
        let base = u.customName.map { "\($0) ([\(u.name)])" } ?? "[\(u.name)]"
        guard let r = u.religion else { return base }
        return "\(base) ([\(religionDisplayName(r))])"
    }
    func defaultActions(at c: HexCoord) -> [NotificationAction] {
        var out: [NotificationAction] = [.location(c)]
        if map[c]?.isCityCenter == true { out.append(.city(c)) }
        return out
    }
    /// Notifications created without an explicit category get one from their wording (Unciv assigns them at every call site).
    static func inferCategory(_ text: String) -> NotificationCategory {
        let t = text.lowercased()
        if t.contains("war") || t.contains("attack") || t.contains("captured") || t.contains("destroyed") || t.contains("defeated") || t.contains("pillag") || t.contains("bombard") || t.contains("withdrew") || t.contains("intercept") { return .War }
        if t.contains("spy") || t.contains("spies") || t.contains("coup") { return .Espionage }
        if t.contains("religion") || t.contains("pantheon") || t.contains("belief") || t.contains("prophet") || t.contains("faith") || t.contains("heresy") { return .Religion }
        if t.contains("trade") || t.contains("deal") || t.contains("offer") || t.contains("gold per turn") || t.contains("resource") { return .Trade }
        if t.contains("peace") || t.contains("friendship") || t.contains("denounce") || t.contains("embassy") || t.contains("ally") || t.contains("influence") || t.contains("tribute") || t.contains("city-state") || t.contains("protect") || t.contains("demand") || t.contains("met ") || t.contains("borders") { return .Diplomacy }
        if t.contains("has been built") || t.contains("completed") || t.contains("constructed") || t.contains("production") || t.contains("wonder") || t.contains("cannot continue") { return .Production }
        if t.contains("unit") || t.contains("promot") || t.contains("upgraded") || t.contains("joined") || t.contains("appeared") || t.contains("disband") || t.contains("healed") { return .Units }
        if t.contains("city") || t.contains("grown") || t.contains("starv") || t.contains("founded") || t.contains("celebrat") || t.contains("annex") || t.contains("razed") || t.contains("resistance") || t.contains("border") { return .Cities }
        return .General
    }
}

// MARK: - Escort formation (Unciv MapUnit.startEscorting / stopEscorting / getOtherEscortUnit)

extension GameState {
    /// Unciv MapUnit.isIdle: has movement, is not working the improvement in progress on its tile (unless that tile only
    /// carries a CreatesOneImprovement marker), its escort partner is idle too, and it is not fortified, exploring,
    /// sleeping, automated (connecting a road included), moving or guarding
    func isIdle(_ u: Unit, includeOtherEscortUnit: Bool = true) -> Bool {
        guard u.movementLeft > 0, let t = map[u.coord] else { return false }
        if let p = t.improvementInProgress, unitCanBuildImprovement(u, p, t), !isMarkedForCreatesOneImprovement(u.coord) { return false }
        if includeOtherEscortUnit, isEscorting(u), let o = otherEscortUnit(u), !isIdle(o, includeOtherEscortUnit: false) { return false }
        if u.isAutomated { return false }   // Unciv `!(... || isAutomated() || ...)`
        switch u.order {
        case .fortify, .fortifyUntilHealed, .explore, .sleep, .sleepUntilHealed, .automate, .moveTo, .guardPost, .connectRoad: return false
        default: return true
        }
    }
    func otherEscortUnit(_ u: Unit) -> Unit? {
        let others = units.filter { $0.civId == u.civId && $0.coord == u.coord && $0.id != u.id && !$0.def.isAir }
        return u.isCivilian ? others.first { $0.isMilitary } : others.first { $0.isCivilian }
    }
    func isEscorting(_ u: Unit) -> Bool { u.escorting && otherEscortUnit(u) != nil }
    func canEscort(_ u: Unit) -> Bool { !u.def.isAir && otherEscortUnit(u) != nil }
    /// Unciv MapUnit.startEscorting: both flags when there is a partner, otherwise this one is cleared; the unit's
    /// pathfinding cache is reset either way.
    func startEscorting(unitId: Int) {
        guard let i = unitIndex(unitId) else { return }
        if let other = otherEscortUnit(units[i]), let oi = unitIndex(other.id) {
            units[i].escorting = true; units[oi].escorting = true
        } else {
            units[i].escorting = false
        }
        clearPathfindingCache(unitId)
    }
    /// Unciv MapUnit.stopEscorting: the partner's flag, this one's flag, and this unit's pathfinding cache.
    func stopEscorting(unitId: Int) {
        guard let i = unitIndex(unitId) else { return }
        if let other = otherEscortUnit(units[i]), let oi = unitIndex(other.id) { units[oi].escorting = false }
        units[i].escorting = false
        clearPathfindingCache(unitId)
    }
}

// MARK: - Guard (Unciv UnitActionType.Guard: units that withdraw before melee can hold a post instead)

extension GameState {
    func canGuard(_ u: Unit) -> Bool { u.isMilitary && u.promotionUniques.contains { $0.pattern == "Withdraws before melee combat" } }
    func isGuarding(_ u: Unit) -> Bool { u.order == .guardPost }
    /// Unciv MapUnit.canFortify: not water, not civilian, not air, not embarked, no "No defensive terrain bonus"
    /// (unit or civ), and - unless `ignoreAlreadyFortified` - not already fortified.
    func canFortify(_ u: Unit, ignoreAlreadyFortified: Bool = false) -> Bool {
        guard !u.def.isWater, u.isMilitary, !u.def.isAir, !isEmbarked(u) else { return false }
        let ctx = UniqueContext(civId: u.civId, unit: u, tile: map[u.coord])
        if (u.promotionUniques + civUniques(u.civId)).contains(where: { $0.pattern == "No defensive terrain bonus" && conditionalsHold($0, ctx) }) { return false }
        if ignoreAlreadyFortified { return true }
        return !isFortified(u)
    }
    /// Unciv MapUnit.isFortified: the action starts with "Fortify" (Fortify, Fortify until healed)
    func isFortified(_ u: Unit) -> Bool { u.order == .fortify || u.order == .fortifyUntilHealed }
    /// Unciv MapUnit.isSleeping: the action starts with "Sleep"
    func isSleeping(_ u: Unit) -> Bool { u.order == .sleep || u.order == .sleepUntilHealed }
    /// Unciv MapUnit.isActionUntilHealed
    func isActionUntilHealed(_ u: Unit) -> Bool { u.order == .sleepUntilHealed || u.order == .fortifyUntilHealed }
}

// MARK: - Gift unit (Unciv UnitActions.getGiftActions)

extension GameState {
    /// The civ that would receive the unit if gifted here, or nil when gifting is not possible.
    func giftRecipient(_ u: Unit) -> Civilization? {
        guard let tile = map[u.coord], let owner = tile.ownerCivId, owner != u.civId, let recipient = civ(owner) else { return nil }
        if recipient.isCityState {
            if areAtWar(recipient.id, u.civId) { return nil }
            if !u.isMilitary && !giftInfluenceUniques(u).contains(where: { unitMatches(u, $0.param(1)) }) { return nil }
        } else if !isFriendlyTerritory(u.coord, for: u.civId) { return nil }
        if u.isTransported { return nil }   // Unciv getGiftActions: "Transported units can't be gifted"
        return recipient
    }
    private func giftInfluenceUniques(_ u: Unit) -> [Unique] {
        (u.promotionUniques + civUniques(u.civId)).filter { $0.pattern == "Gain [] Influence with a [] gift to a City-State" }
    }
    func areFriends(_ a: Int, _ b: Int) -> Bool { civ(a)?.friendships[b] != nil }
    func giftUnit(unitId: Int) {
        guard let i = unitIndex(unitId), let recipient = giftRecipient(units[i]), units[i].movementLeft > 0 else { return }
        let u = units[i]
        if recipient.isCityState {
            if let uq = giftInfluenceUniques(u).first(where: { unitMatches(u, $0.param(1)) }) { addInfluence(recipient.id, from: u.civId, uq.double(0) - 5) }
            addInfluence(recipient.id, from: u.civId, 5)
        } else {
            addModifier(recipient.id, u.civId, .GaveUsUnits, 5)
        }
        if recipient.isCityState && u.isGreatPerson { destroyUnit(unitId); return }   // City states don't get GPs
        giftUnitTo(unitId, recipient: recipient.id)
    }
    /// Unciv MapUnit.gift: stopEscorting, out of the giver's list (upkeep, resources, the losing trigger), the carried
    /// planes along, then assignOwner - APPENDED to the recipient's list with its upkeep and resources recounted.
    func giftUnitTo(_ unitId: Int, recipient: Int) {
        guard let u = unit(unitId) else { return }
        stopEscorting(unitId: unitId)
        let giver = u.civId, at = u.coord
        rotateCivUnitsToNextDue(giver)   // Unciv gift: `civ.units.removeUnit(this)` - the giver's list starts at nextPotentiallyDueAt
        guard let i = unitIndex(unitId) else { return }
        if GameState.evlogOn { evUnitDie(units[i]) }   // EVLOG: UNIT_DIE for the giver, UNIT_ADD for the recipient below
        units[i].civId = recipient
        updateStatsForNextTurn(giver)
        if unitEatsResources(u) { updateCivResources(giver) }
        triggerConditionalUniques(civId: giver) { $0.pattern == "upon losing a [] unit" && self.unitMatches(u, $0.param(0)) }
        // No updateVisibleTiles here: Unciv's gift and assignOwner keep the unit's stored viewableTiles, computed with the
        // giver's sight, until it moves. Ours recomputed it with the recipient's Sight uniques, and Austria, given Yerevan's
        // units by marriage (nations t=120), saw and explored rim tiles Unciv's Austria only reached at t=123.
        updateExploration(for: giver)   // civ.cache.updateViewableTiles() (MapUnit.kt:969, for every giver)
        if carrierCapacity(u) > 0 {
            // Unciv's first addUnit to the recipient is the first carried aircraft's assignOwner, and the carrier is not in
            // the recipient's list yet then; ours already carries the recipient's civId.
            rotateCivUnitsToNextDue(recipient, excluding: unitId)
            for p in units where p.coord == at && p.civId == giver && p.def.isAir && p.isTransported && canBeCarried(p, by: u) { giftUnitTo(p.id, recipient: recipient) }
        }
        moveUnitToEndOfList(unitId)
        if GameState.evlogOn, let now = unit(unitId) { evUnitAdd(now) }   // EVLOG: UNIT_ADD (gift, assignOwner)
        updateStatsForNextTurn(recipient)
        if let now = unit(unitId), unitEatsResources(now) { updateCivResources(recipient) }
        updateUnitUniquesCache(unitId)   // Unciv assignOwner ends in cache.updateUniques()
        updateExploration(for: recipient)   // recipient.cache.updateViewableTiles() (MapUnit.kt:974)
    }
    func addInfluence(_ cityState: Int, from major: Int, _ amount: Double) {
        guard let ci = civIndex(cityState) else { return }
        // Unciv setInfluence clamps only the lower bound, so a gift can carry influence past 150.
        civs[ci].influence[major, default: 0] = max(-60, (civs[ci].influence[major] ?? 0) + amount)
        updateAllyCivForCityState(cityState)
    }
}

// MARK: - Transform (Unciv "Can transform to [unit]")

extension GameState {
    func transformTargets(_ u: Unit) -> [UnitDef] {
        u.promotionUniques.filter { $0.pattern == "Can transform to []" }.compactMap { rs.units[$0.param(0)] }
    }
    func transform(unitId: Int, to name: String) {
        guard let i = unitIndex(unitId), !isEmbarked(units[i]), rs.units[name] != nil else { return }
        let movement = units[i].movementLeft
        units[i].name = name
        units[i].movementLeft = min(movement, maxMovement(of: units[i]))
        units[i].isSetUp = false
    }
}

// MARK: - Connect road state (Unciv MapUnit.isAutomatingRoadConnection / UnitActionsFromUniques.getConnectRoadAction)

extension GameState {
    func canConnectRoad(_ u: Unit) -> Bool { u.def.isWorker && techBestRoad(u.civId) != nil }
    func isConnectingRoad(_ u: Unit) -> Bool { if case .connectRoad = u.order { return true }; return false }
}

// MARK: - City: sell building / avoid growth / focus (Unciv City.sellBuilding, avoidGrowth, CityFocus)

extension GameState {
    /// `multipliers` are Unciv getStatMultiplier's Float literals (3.05f, 2f, 1.5f): Float(3.05) is not the Double 3.05
    struct CityFocus { let name: String; let label: String; let stat: String?; let multipliers: [String: Float]; let tableEnabled: Bool }
    /// Unciv CityFocus entries in order (HappinessFocus is hidden from the table, like in Unciv).
    static let cityFocuses: [CityFocus] = [
        CityFocus(name: "NoFocus", label: "Default", stat: nil, multipliers: [:], tableEnabled: true),
        CityFocus(name: "Manual", label: "Manual", stat: nil, multipliers: [:], tableEnabled: true),
        CityFocus(name: "FoodFocus", label: "🍎", stat: "Food", multipliers: ["Food": 3.05], tableEnabled: true),
        CityFocus(name: "ProductionFocus", label: "⚙️", stat: "Production", multipliers: ["Production": 3.05], tableEnabled: true),
        CityFocus(name: "GoldFocus", label: "💰", stat: "Gold", multipliers: ["Gold": 3.05], tableEnabled: true),
        CityFocus(name: "ScienceFocus", label: "🔬", stat: "Science", multipliers: ["Science": 3.05], tableEnabled: true),
        CityFocus(name: "CultureFocus", label: "🎵", stat: "Culture", multipliers: ["Culture": 3.05], tableEnabled: true),
        CityFocus(name: "HappinessFocus", label: "😊", stat: "Happiness", multipliers: ["Happiness": 3.05], tableEnabled: false),
        CityFocus(name: "FaithFocus", label: "🕊", stat: "Faith", multipliers: ["Faith": 3.05], tableEnabled: true),
        CityFocus(name: "GoldGrowthFocus", label: "💰 🍎", stat: nil, multipliers: ["Gold": 2, "Food": 1.5], tableEnabled: true),
        CityFocus(name: "ProductionGrowthFocus", label: "⚙️ 🍎", stat: nil, multipliers: ["Production": 2, "Food": 1.5], tableEnabled: true),
    ]
    func focus(of city: City) -> CityFocus { GameState.cityFocuses.first { $0.name == city.cityFocus } ?? GameState.cityFocuses[0] }
    func setCityFocus(cityId: Int, _ name: String) {
        guard let ci = cityIndex(cityId) else { return }
        cities[ci].cityFocus = name
        assignWorkers(cityId: cityId, why: "MapUnit:48828")   // Unciv CityView.trySetCityFocus: reassignPopulation() for every focus, Manual included
    }
    func setAvoidGrowth(cityId: Int, _ on: Bool) {
        guard let ci = cityIndex(cityId) else { return }
        cities[ci].avoidGrowth = on
        assignWorkers(cityId: cityId, why: "MapUnit:49018")
    }

    func isSellable(_ b: BuildingDef) -> Bool { !b.isAnyWonder && !b.uniques.contains("Unsellable") && b.name != Names.palace }
    /// Unciv City.getGoldForSellingBuilding: cost / 10.
    func goldForSellingBuilding(_ name: String) -> Int { (rs.buildings[name].map { rs.cost(of: $0) } ?? 0) / 10 }
    /// Unciv ConstructionInfoTable.showSellButton - the player's Sell button, and only that. The AI's
    /// sellBuildingForResource filters on its own and does sell in a puppet.
    func canSellBuilding(_ city: City, _ name: String) -> Bool {
        // Unciv ConstructionInfoTable.showSellButton: free buildings are not sellable (they come back every turn),
        // and a city being razed is not one of the conditions it checks. God mode ignores the once-a-turn limit.
        guard let b = rs.buildings[name], isSellable(b), city.buildings.contains(name), !hasFreeBuilding(city, name),
              !city.hasSoldBuildingThisTurn || settings.godMode, !city.isPuppet else { return false }
        return true
    }
    /// Unciv City.sellBuilding: no checks of its own - the Sell button (canSellBuilding) or the AI's filter decided.
    func sellBuilding(cityId: Int, _ name: String) {
        guard let ci = cityIndex(cityId), let civi = civIndex(cities[ci].civId) else { return }
        let civId = cities[ci].civId
        // Unciv City.sellBuilding: removeBuilding (updateUniques: connections, the city's stats, the resources), the
        // gold, the flag, unassignExtraPopulation, autoAssignPopulation, and updateCivResources once more. Ours took
        // the building off the list without any of removeBuilding's updates and re-placed EVERY citizen.
        removeBuilding(cityIndex: ci, name)
        civs[civi].gold += Double(goldForSellingBuilding(name)); goldTrace(civId, Double(goldForSellingBuilding(name)))
        if let cx = cityIndex(cityId) { cities[cx].hasSoldBuildingThisTurn = true }
        unassignExtraPopulation(cityId: cityId)
        assignWorkers(cityId: cityId, onlyFreePopulation: true, why: "sellBuilding")   // autoAssignPopulation, "also updates city stats"
        updateCivResources(civId)   // "this building could be a resource-requiring one"
    }
}

// MARK: - Specialists (Unciv SpecialistAllocationTable / CityPopulationManager)
extension GameState {
    func maxSpecialists(_ city: City) -> [String: Int] {
        var slots: [String: Int] = [:]
        for b in city.buildings { for (n, k) in rs.buildings[b]?.specialistSlots ?? [:] where rs.specialists[n] != nil { slots[n, default: 0] += k } }
        return slots
    }
    func freePopulation(_ city: City) -> Int { city.population - city.workedTiles.count - city.specialists.values.reduce(0, +) }
    func setManualSpecialists(cityId: Int, _ on: Bool) {
        guard let ci = cityIndex(cityId) else { return }
        cities[ci].manualSpecialists = on
        if !on { assignWorkers(cityId: cityId, why: "MapUnit:51313") }   // only switching back to automatic reassigns citizens
    }
    /// Unciv CityView.tryAssignSpecialist: an unemployed citizen becomes the specialist (the + button only shows while one is free)
    func tryAssignSpecialist(cityId: Int, _ name: String) {
        guard let ci = cityIndex(cityId), (maxSpecialists(cities[ci])[name] ?? 0) > (cities[ci].specialists[name] ?? 0), freePopulation(cities[ci]) > 0 else { return }
        cities[ci].specialists[name, default: 0] += 1
        cities[ci].manualSpecialists = true
        invalidateHappiness(cities[ci].civId)
        updateCityStats(cityId, reason: "CityView.tryAssignSpecialist")   // Unciv: city.cityStats.update()
    }
    /// Unciv CityView.tryUnassignSpecialist: the citizen becomes unemployed, nothing is reassigned
    func tryUnassignSpecialist(cityId: Int, _ name: String) {
        guard let ci = cityIndex(cityId), (cities[ci].specialists[name] ?? 0) > 0 else { return }
        cities[ci].specialists[name]! -= 1
        cities[ci].manualSpecialists = true
        invalidateHappiness(cities[ci].civId)
        updateCityStats(cityId, reason: "CityView.tryUnassignSpecialist")   // Unciv: city.cityStats.update()
    }
}
