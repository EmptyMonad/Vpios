// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/map/mapunit/movement/MovementCost.kt`: what one step costs a unit, and whether it may take it at all.
extension GameState {
    /// Unciv Constants.minimumMovementEpsilon
    static let minimumMovementEpsilon = 0.05

    /// Can a land unit of this civ step onto the given water tile (embarked)?
    func canEmbark(_ civId: Int, onto tile: Tile) -> Bool {
        guard tile.isWater, civHasEmbarkation(civId) else { return false }
        if tile.baseTerrain == "Ocean" && !oceanEnabledForEmbarked(civId) { return false }
        return true
    }

    /// Unciv TechManager.unitsCanEmbark
    func civHasEmbarkation(_ civId: Int) -> Bool { civUniques(civId).contains { $0.pattern == "Enables embarkation for land units" } }

    func isEmbarked(_ unit: Unit) -> Bool { unit.def.isLand && (map[unit.coord]?.isWater ?? false) && !unit.promotionUniques.contains(where: { $0.pattern == "May travel on Water tiles without embarking" }) }

    func bridgesKnown(_ civId: Int) -> Bool {
        civ(civId)?.transientTechs.contains { rs.techs[$0]?.uniques.contains("Roads connect tiles across rivers") == true } ?? false   // Unciv TechManager.roadsConnectAcrossRivers (transient)
    }

    /// Unciv TechManager.movementSpeedOnRoads: RoadStatus.Road.movement (0.5f), or movementImproved (1/3f) once the
    /// civ knows a road-speed tech. The costs are Kotlin Floats, so 1/3 is the Float third, not the Double one.
    func roadStep(for civId: Int) -> Double {
        guard let civ = civ(civId) else { return 0.5 }
        return civ.transientTechs.contains { rs.techs[$0]?.uniques.contains("Improves movement speed on roads") == true } ? Double(Float(1) / Float(3)) : 0.5
    }
    /// Unciv RoadStatus.Railroad.movement = 0.1f
    static let railroadMovement = Double(Float(0.1))

    /// Unciv DiplomacyFunctions.canPassThroughTiles
    func canPassThroughTiles(_ civId: Int, _ other: Int) -> Bool {
        if other == civId { return true }
        guard let oc = civ(other), let me = civ(civId) else { return true }
        if oc.isBarbarian { return true }
        // Barbarians have no diplomacy: only the difficulty's turn lets them into other civs' tiles
        if me.isBarbarian { return uncivTurns >= difficulty.turnBarbariansCanEnterPlayerTiles }   // Unciv gameInfo.turns
        if hasOpenBorders(civId, in: other) || areAtWar(civId, other) { return true }
        // Players can always pass through city-state tiles
        return !isAIOrAutoPlaying(me.id) && oc.isCityState
    }

    /// Unciv MapUnitCache.canEnterForeignTerrain / canEnterCityStates on top of Tile.canCivPassThrough.
    func bordersAllow(_ unit: Unit, _ tile: Tile) -> Bool {
        if unit.promotionUniques.contains(where: { $0.pattern.hasPrefix("May enter foreign tiles without open borders") }) { return true }
        if let o = tile.ownerCivId, civ(o)?.isCityState == true, unit.promotionUniques.contains(where: { $0.pattern.hasPrefix("Can undertake a trade mission with City-State") }) { return true }
        return canCivPassThrough(tile, civId: unit.civId)
    }

    enum DoubleMovementTarget { case feature, base, hill, filter }

    /// Everything about a unit's movement that does not depend on the tile — Unciv MapUnitCache.
    struct MoveContext {
        var isWater = false, isLand = false, isAir = false
        var canEmbarkCoast = false, canEmbarkOcean = false
        var cannotMove = false, ignoresTerrainCost = false, ignoresZOC = false, allTilesCost1 = false, canMoveOnWater = false
        var roughPenalty = false, ignoreHills = false, forestRoads = false, bridges = false
        var disembark: Double? = nil
        var embark: Double? = nil
        var road = 0.5
        var hostileExtra: [Int: Double] = [:]
        var doubleMovement: [(name: String, target: DoubleMovementTarget, unique: Unique)] = []
        /// Tiles exerting a zone of control against this unit (enemy cities at war, qualifying enemy military units)
        var zocExerters: Set<HexCoord> = []
        var noTerrainMovementUniques: Bool { doubleMovement.isEmpty && !roughPenalty && !ignoreHills }
    }

    func moveContext(for unit: Unit) -> MoveContext {
        var c = MoveContext()
        let uniques = unit.promotionUniques
        c.isWater = unit.def.isWater; c.isLand = unit.def.isLand; c.isAir = unit.def.isAir
        c.cannotMove = unitCannotMove(unit)
        c.ignoresTerrainCost = uniques.contains { $0.pattern == "Ignores terrain cost" || $0.pattern == "Ignore terrain cost" }
        c.ignoresZOC = uniques.contains { $0.pattern == "Ignores Zone of Control" }
        c.allTilesCost1 = uniques.contains { $0.pattern == "All tiles cost 1 movement" }
        c.canMoveOnWater = uniques.contains { $0.pattern == "May travel on Water tiles without embarking" }
        c.roughPenalty = uniques.contains { $0.pattern == "Rough terrain penalty" }
        c.ignoreHills = ignoresHillCost(unit.civId)
        c.forestRoads = forestsAreRoads(unit.civId)
        c.bridges = bridgesKnown(unit.civId)
        c.road = roadStep(for: unit.civId)
        c.disembark = disembarkCost(for: unit)
        c.embark = embarkCost(for: unit)
        c.hostileExtra = hostileTerritoryExtraCost(for: unit)
        // Unciv doubleMovementInTerrain: keyed by the parameter, classified by the terrain it names
        for u in uniques + civUniques(unit.civId) where u.pattern == "Double movement in []" {
            let name = u.param(0)
            let target: DoubleMovementTarget
            if let t = rs.terrains[name] { target = name == "Hill" ? .hill : t.type == .terrainFeature ? .feature : (t.type == .land || t.type == .water) ? .base : .filter }
            else { target = .filter }
            if let i = c.doubleMovement.firstIndex(where: { $0.name == name }) { c.doubleMovement[i] = (name, target, u) } else { c.doubleMovement.append((name, target, u)) }
        }
        c.canEmbarkCoast = c.isLand && civHasEmbarkation(unit.civId) && !uniques.contains { $0.pattern == "Cannot embark" }
        c.canEmbarkOcean = c.canEmbarkCoast && oceanEnabledForEmbarked(unit.civId)
        // Unciv MovementCost.anyTilesExertingZoneOfControl: cities at war, sea units against everyone, land units against land units unless embarked
        if !c.ignoresZOC && !c.isAir {
            let cityTiles = Set(cities.map { $0.coord })
            for city in cities where city.civId != unit.civId && areAtWar(unit.civId, city.civId) { c.zocExerters.insert(city.coord) }
            for e in units where e.isMilitary && !e.def.isAir && e.civId != unit.civId && !cityTiles.contains(e.coord) && areAtWar(unit.civId, e.civId) {
                if e.def.isWater || (unit.def.isLand && !isEmbarked(e)) { c.zocExerters.insert(e.coord) }
            }
        }
        return c
    }

    /// Unciv MapUnitCache.updateUniques, for the flag ours stores: `cannotEnterOceanTiles =
    /// mapUnit.hasUnique(CannotEnterOcean, state)` - the unit's own uniques in its GameContext, evaluated then and
    /// kept until the next updateUniques: putInTile (and so every tile entered), the end of moveToTile, healBy,
    /// takeDamage, a promotion or status gained or lost, assignOwner and the unit's turn start. Learning a tech does
    /// not refresh it, so a Work Boat ("<before discovering [Astronomy]>") whose civ gets Astronomy mid-turn stays
    /// out of the ocean until one of those happens to it.
    func updateUnitUniquesCache(_ unitId: Int) {
        guard let u = unit(unitId) else { return }
        unitCannotEnterOceanTiles[unitId] = unitHasUnique(u, "Cannot enter ocean tiles")
    }

    /// Unciv `unit.cache.cannotEnterOceanTiles`: the stored flag. A unit whose cache was never filled (a loaded game,
    /// a unit being placed) computes it as its setTransients would; a unit not in the game is never stored.
    func cannotEnterOceanTiles(_ unit: Unit) -> Bool {
        if let stored = unitCannotEnterOceanTiles[unit.id] { return stored }
        let v = unitHasUnique(unit, "Cannot enter ocean tiles")
        if self.unit(unit.id) != nil { unitCannotEnterOceanTiles[unit.id] = v }
        return v
    }

    /// Unciv MapUnitCache.cannotMove
    func unitCannotMove(_ unit: Unit) -> Bool { unit.def.movement == 0 || unit.promotionUniques.contains { $0.pattern == "Cannot move" } }

    /// Unciv Tile.hasConnection: an unpillaged road, or friendly forest and jungle for civs whose forests are roads
    func tileHasConnection(_ t: Tile, civId: Int, forestRoads: Bool) -> Bool {
        if (t.roads || t.railroad) && !t.roadPillaged { return true }
        return forestRoads && t.hasForestOrJungle && isFriendlyTerritory(t.coord, for: civId)
    }

    /// Unciv Tile.lastTerrain.movementCost: the last feature, else the natural wonder, else the base terrain
    func lastTerrainMovementCost(_ t: Tile) -> Int {
        rs.terrains[t.features.last ?? t.naturalWonder ?? t.baseTerrain]?.movementCost ?? 1
    }

    /// Unciv MovementCost.getMovementCostBetweenAdjacentTiles (100 = every remaining movement point)
    func movementCost(_ unit: Unit, _ ctx: MoveContext, from: HexCoord, to: HexCoord, considerZOC: Bool = true) -> Double {
        guard let ft = map[from], let tt = map[to] else { return 100 }
        if ctx.cannotMove { return 100 }
        if ft.isLand != tt.isLand && ctx.isLand && !ctx.canMoveOnWater {
            return ft.isWater && tt.isLand ? (ctx.disembark ?? 100) : (ctx.embark ?? 100)
        }
        // A zone of control exerted on both tiles expends all movement points
        if considerZOC && !ctx.ignoresZOC && !ctx.zocExerters.isEmpty {
            let aroundTo = map.neighbors(of: to)
            for n in map.neighbors(of: from) where ctx.zocExerters.contains(n) && aroundTo.contains(n) { return 100 }
        }
        // land units will still spend all movement points to embark even with this unique
        if ctx.allTilesCost1 { return 1 }
        let extra = tt.ownerCivId.flatMap { ctx.hostileExtra[$0] } ?? 0
        if ft.railroad && !ft.roadPillaged && tt.railroad && !tt.roadPillaged { return Double(Float(GameState.railroadMovement) + Float(extra)) }
        let connectedByRiver = map.hasRiver(between: from, to)
        if tileHasConnection(ft, civId: unit.civId, forestRoads: ctx.forestRoads) && tileHasConnection(tt, civId: unit.civId, forestRoads: ctx.forestRoads) && (!connectedByRiver || ctx.bridges) {
            return Double(Float(ctx.road) + Float(extra))   // Unciv: Float + Float
        }
        if ctx.ignoresTerrainCost { return 1 + extra }
        if connectedByRiver { return 100 }   // Rivers take the entire turn to cross
        // Cities reduce terrain cost to 1
        let terrainCost = tt.isCityCenter ? 1.0 : Double(lastTerrainMovementCost(tt))
        if ctx.noTerrainMovementUniques { return terrainCost + extra }
        let uctx = UniqueContext(civId: unit.civId, unit: unit, tile: tt)
        func doubled(_ target: DoubleMovementTarget, _ matches: (String) -> Bool) -> Bool {
            ctx.doubleMovement.contains { $0.target == target && matches($0.name) && ($0.unique.conditionals.isEmpty || conditionalsHold($0.unique, uctx)) }
        }
        if doubled(.feature, { tt.features.contains($0) }) { return terrainCost * 0.5 + extra }
        // Unciv Tile.isRoughTerrain(): allTerrains.any { it.isRough } — base + dogal harika + feature
        if ctx.roughPenalty && (tt.isRough || (tt.naturalWonder.map { rs.terrains[$0]?.isRough == true } ?? false)) { return 100 }
        if ctx.ignoreHills && tt.isHill { return 1 + extra }
        if doubled(.base, { tt.baseTerrain == $0 }) { return terrainCost * 0.5 + extra }
        if tt.isHill && doubled(.hill, { $0 == "Hill" }) { return terrainCost * 0.5 + extra }
        if doubled(.filter, { self.tileMatches(tt, $0, civId: unit.civId) }) { return terrainCost * 0.5 + extra }
        return terrainCost + extra
    }

    /// Great Wall: "Enemy [Land] units must spend [1] extra movement points when inside your territory" per enemy owner.
    func hostileTerritoryExtraCost(for unit: Unit) -> [Int: Double] {
        var out: [Int: Double] = [:]
        // Unciv MovementCost: `toOwner.hasActiveEnemyMovementPenalty && civ.isAtWarWith(toOwner)` - the owner's STORED
        // flag first (updateHasActiveEnemyMovementPenalty), then its uniques as they stand.
        for other in civs where other.id != unit.civId && other.isAlive && areAtWar(unit.civId, other.id) && activeEnemyMovementPenalty(other.id) {
            // Unciv reads these through Civilization.getMatchingUniques, so the conditionals are evaluated:
            // the Great Wall's penalty carries <before discovering [Dynamite]> and stops there.
            let ctx = UniqueContext(civId: other.id)
            for u in civUniques(other.id) where u.pattern == "Enemy [] units must spend [] extra movement points when inside your territory" && unitMatches(unit, u.param(0)) && conditionalsHold(u, ctx) {
                out[other.id, default: 0] += Double(u.int(1))
            }
        }
        return out
    }

    // MARK: - passing and entering tiles

    /// Unciv TechManager.allUnitsCanEnterOcean / embarkedUnitsCanEnterOcean and UnitMovement.unitSpecificAllowOcean
    private func oceanPermissions(_ unit: Unit) -> (all: Bool, embarked: Bool, specific: Bool) {
        let ctx = UniqueContext(civId: unit.civId, unit: unit)
        var all = false, embarked = false, specific = false
        for u in civUniques(unit.civId) {
            if u.pattern == "Enables embarked units to enter ocean tiles" { embarked = true; continue }
            guard u.pattern == "Enables [] units to enter ocean tiles", conditionalsHold(u, ctx) else { continue }
            let f = u.param(0)
            if f == "All" { all = true; embarked = true }
            else if f == "Embarked" { embarked = true }
            else if unitMatches(unit, f) { specific = true }
        }
        return (all, embarked, specific)
    }

    /// Unciv UnitMovement.cannotPassThroughReason == null. `ignoreBorders` stands in for getPathBetweenTiles' canEnterForeignTerrain trick.
    func canPassThrough(_ unit: Unit, _ c: HexCoord, includeEscort: Bool = true, ignoreBorders: Bool = false) -> Bool {
        guard let tile = map[c] else { return false }
        if tile.isImpassable && !unit.def.passesImpassable && !impassableOverride(unit, tile) { return false }
        if tile.isLand && unit.def.isWater && !tile.isCityCenter { return false }
        let uniques = unit.promotionUniques
        let canMoveOnWater = uniques.contains { $0.pattern == "May travel on Water tiles without embarking" }
        let isOcean = tile.baseTerrain == "Ocean"
        if tile.isWater && unit.def.isLand && !canMoveOnWater {
            if !civHasEmbarkation(unit.civId) || uniques.contains(where: { $0.pattern == "Cannot embark" }) { return false }
            if isOcean { let p = oceanPermissions(unit); if !p.embarked && !p.specific { return false } }
        }
        // Unciv MapUnitCache reads this unique *with* its conditionals: Work Boats say "Cannot enter ocean tiles
        // <before discovering [Astronomy]>", and matching on the pattern alone made the ban permanent for them.
        // UnitMovement reads the STORED `cache.cannotEnterOceanTiles`, refreshed only by updateUniques.
        if isOcean && cannotEnterOceanTiles(unit) {
            let p = oceanPermissions(unit)
            if !p.all && !p.specific { return false }
        }
        if let o = tile.ownerCivId, civ(o)?.isCityState == true, uniques.contains(where: { $0.pattern.hasPrefix("Can undertake a trade mission with City-State") }) { return true }
        if !ignoreBorders && !uniques.contains(where: { $0.pattern.hasPrefix("May enter foreign tiles without open borders") }) && !canCivPassThrough(tile, civId: unit.civId) { return false }
        // The first unit is the military unit, else the civilian, else an air unit
        let here = units(at: c)
        if let first = here.first(where: { $0.isMilitary && !$0.def.isAir }) ?? here.first(where: { $0.isCivilian }) ?? here.first, first.civId != unit.civId {
            // Allow movement through an unguarded civilian we are at war with, capturing it on the way — but not while embarked
            if !(unit.def.isLand && tile.isWater && !canMoveOnWater) && first.isCivilian && areAtWar(unit.civId, first.civId) { return true }
            if areAtWar(unit.civId, first.civId) { return false }
        }
        if includeEscort && isEscorting(unit), let e = otherEscortUnit(unit), !canPassThrough(e, c, includeEscort: false, ignoreBorders: ignoreBorders) { return false }
        return true
    }

    /// Unciv UnitMovement.getCannotMoveToReason == null: may the unit end its move on the tile (without attacking)?
    func canMoveTo(_ unit: Unit, _ c: HexCoord, assumeCanPassThrough: Bool = false, allowSwap: Bool = false, includeEscort: Bool = true) -> Bool {
        guard let tile = map[c] else { return false }
        if unit.def.isAir {
            // Unciv getAirUnitCannotMoveToReason: our city with room for untransported air units, or a unit that can transport us
            if tile.isCityCenter, let ct = city(at: c), ct.civId == unit.civId, units.filter({ $0.coord == c && $0.def.isAir && !$0.isTransported && $0.id != unit.id }).count < maxAirUnits(ct) { return true }
            return units(at: c).contains { $0.civId == unit.civId && !$0.def.isAir && canBeCarried(unit, by: $0) && carrierAvailableCapacity($0, for: unit) > 0 }
        }
        if !assumeCanPassThrough && !canPassThrough(unit, c) { return false }
        // even if they'll let us pass through, we can't enter their city - unless we just captured it (isCityCenterCannotEnter)
        if let city = city(at: c), city.civId != unit.civId, !city.hasJustBeenConquered { return false }
        if includeEscort && isEscorting(unit), let e = otherEscortUnit(unit), !canMoveTo(e, c, assumeCanPassThrough: assumeCanPassThrough, allowSwap: allowSwap, includeEscort: false) { return false }
        // Unciv getCannotMoveToReason reads tile.civilianUnit / tile.militaryUnit and does NOT skip the asking
        // unit, so canMoveTo is false for the tile it is already standing on. Skipping it made the answer true,
        // and tryExplore's second stage - which walks getTilesInDistance(5) from distance 0 up - then took the
        // unit's own tile as a target every turn and the unit never moved again. The call sites that legitimately
        // mean "here or somewhere I can go" already spell that out as `unit.coord == c || canUnitEnter(...)`,
        // exactly as Unciv does.
        let here = units(at: c).filter { !$0.def.isAir }
        let military = here.first { $0.isMilitary }, civilian = here.first { $0.isCivilian }
        if unit.isCivilian {
            return (civilian == nil || (allowSwap && civilian!.civId == unit.civId)) && (military == nil || military!.civId == unit.civId)
        }
        return (military == nil || (allowSwap && military!.civId == unit.civId)) && (civilian == nil || civilian!.civId == unit.civId || areAtWar(unit.civId, civilian!.civId))
    }

    /// Epochs call sites: may the unit end on the tile, or — with `allowAttack` — does it hold something it may attack
    func canUnitEnter(_ unit: Unit, _ c: HexCoord, allowAttack: Bool = false) -> Bool {
        if allowAttack && unit.isMilitary {
            if units(at: c).contains(where: { $0.civId != unit.civId && areAtWar(unit.civId, $0.civId) }) || (city(at: c).map { $0.civId != unit.civId && areAtWar(unit.civId, $0.civId) } ?? false) { return true }
        }
        return canMoveTo(unit, c)
    }

    // MARK: - paths

    /// Unciv PathsToTilesWithinTurn: insertion-ordered tile → parent and total movement
    struct TurnPaths {
        var order: [HexCoord] = []
        var nodes: [HexCoord: (parent: HexCoord, total: Double)] = [:]
        mutating func set(_ c: HexCoord, parent: HexCoord, total: Double) {
            if nodes[c] == nil { order.append(c) }
            nodes[c] = (parent, total)
        }
        func contains(_ c: HexCoord) -> Bool { nodes[c] != nil }
        /// Unciv getPathToTile: the tiles after the start, up to and including `c`
        func path(to c: HexCoord) -> [HexCoord] {
            var out: [HexCoord] = []
            var cur = c
            while let n = nodes[cur], n.parent != cur { out.append(cur); cur = n.parent }
            return out.reversed()
        }
    }
    /// Unciv getShortestPath's canPassThroughCache and movementCostCache
    struct MoveCaches {
        var passThrough: [HexCoord: Bool] = [:]
        var cost: [Int: Double] = [:]
    }
}
