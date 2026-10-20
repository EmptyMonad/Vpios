// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's unit/WorkerAutomation.kt and unit/RoadBetweenCitiesAutomation.kt (and MapPathing.kt).
//
// Unciv keeps one WorkerAutomation per civilization (Civilization.getWorkerAutomation), recreated when
// gameInfo.turns moves on. Its caches - tile rankings, workers per city, the road plans and the best road
// available - live for that civ's turn, and ANOTHER civ may read them in the meantime (the citadel placer asks
// the tile owner's automation for getBasePriority). So they are kept here per civ, keyed by the turn they were
// made for, never reset from outside.

struct TileImprovementRank {
    var tilePriority: Double                 // Float in Unciv
    var improvementPriority: Double? = nil   // Float in Unciv
    var bestImprovement: String? = nil       // improvement name, "Remove X", "Road", "Railroad"
    var repairImprovement: Bool? = nil
}
/// Unciv RoadBetweenCitiesAutomation.RoadPlan
struct RoadPlan {
    let tiles: [HexCoord]
    let priority: Double   // Float in Unciv
    let fromCity: Int
    let toCity: Int
}

/// Unciv WorkerAutomation + its RoadBetweenCitiesAutomation and RoadToAutomation: the per-civ, per-turn instance.
final class WorkerAutomationState {
    let civId: Int
    let cachedForTurn: Int
    /// Unciv WorkerAutomation.tileRankings
    var tileRankings: [HexCoord: TileImprovementRank] = [:]
    /// Unciv WorkerAutomation.workersPerCity - a Counter: a key whose count reaches 0 is removed
    var workersPerCity: [Int: Int] = [:]
    /// Unciv RoadBetweenCitiesAutomation.bestRoadAvailable, fixed when the instance is made
    let bestRoadAvailable: String?
    /// Unciv RoadToAutomation.actualBestRoadAvailable, fixed when the instance is made
    let actualBestRoadAvailable: String?
    /// Unciv RoadBetweenCitiesAutomation.roadsToBuildByCitiesCache
    var roadsToBuildByCitiesCache: [Int: [RoadPlan]] = [:]
    /// Unciv RoadBetweenCitiesAutomation.tilesOfRoadsMap
    var tilesOfRoadsMap: [HexCoord: RoadPlan] = [:]
    /// Unciv RoadBetweenCitiesAutomation.tilesOfConnectedCities (`by lazy`)
    var tilesOfConnectedCities: [HexCoord]? = nil
    init(civId: Int, cachedForTurn: Int, bestRoadAvailable: String?, actualBestRoadAvailable: String?) {
        self.civId = civId; self.cachedForTurn = cachedForTurn
        self.bestRoadAvailable = bestRoadAvailable; self.actualBestRoadAvailable = actualBestRoadAvailable
    }
    func workers(_ cityId: Int?) -> Int { cityId.flatMap { workersPerCity[$0] } ?? 0 }
    /// Unciv Counter.add: put(key, get(key) + value), and a zero removes the key
    func addWorkers(_ cityId: Int?, _ n: Int) {
        guard let id = cityId else { return }
        let v = (workersPerCity[id] ?? 0) + n
        if v == 0 { workersPerCity[id] = nil } else { workersPerCity[id] = v }
    }
}

private let cutDownPattern = "Provides a one-time bonus of [] to the closest city when cut down"   // Unciv ProductionBonusWhenRemoved
private let nullifyYields = "Nullifies all other stats this tile provides"
private let canBuildOutsideBorders = "Can be built outside your borders"
private let canBuildJustOutsideBorders = "Can be built just outside your borders"
@inline(__always) private func f(_ x: Double) -> Double { Stats.f32(x) }
/// WDBG=<nation>: trace each worker decision (matches the WDBGU prints of a patched Unciv build)
private let wdbgCiv: String? = ProcessInfo.processInfo.environment["WDBG"]

extension GameState {
    /// Unciv Civilization.getWorkerAutomation: the instance valid for the current turn, made on first use.
    func getWorkerAutomation(_ civId: Int) -> WorkerAutomationState {
        if let wa = workerAutomationCaches[civId], wa.cachedForTurn == turn { return wa }
        let actual = techBestRoad(civId)
        // Unciv RoadBetweenCitiesAutomation.bestRoadAvailable: none for humans with "Auto-build roads" off unless autoplaying
        let best: String? = (civ(civId)?.isPlayer == true && !UserSettings.autoBuildRoads && !autoPlayingFullAI) ? nil : actual
        if best == nil && actual != nil && GameState.evlogOn { hbr("S4.noAutoRoads", civId) }
        let wa = WorkerAutomationState(civId: civId, cachedForTurn: turn, bestRoadAvailable: best, actualBestRoadAvailable: actual)
        workerAutomationCaches[civId] = wa
        return wa
    }

    /// Unciv TechManager.getBestRoadAvailable: Railroad, else Road, when researched and without building problems
    func techBestRoad(_ civId: Int) -> String? {
        guard let civ = civ(civId) else { return nil }
        for name in ["Railroad", "Road"] {
            if let imp = rs.improvements[name], imp.techRequired.map({ civ.techs.contains($0) }) ?? true, improvementResourcesAvailable(imp, civId: civId) { return name }
        }
        return nil
    }
    /// Unciv RoadStatus ordinal: None 0, Road 1, Railroad 2
    private func roadLevel(name: String?) -> Int { name == "Railroad" ? 2 : name == "Road" ? 1 : 0 }
    /// Unciv Tile.getUnpillagedRoad. A city centre carries a real road since tryUpdateRoadStatus, so no special case.
    private func roadLevel(_ c: HexCoord) -> Int {
        guard let t = map[c], !t.roadPillaged else { return 0 }
        return t.railroad ? 2 : t.roads ? 1 : 0
    }
    private func isRoad(_ name: String) -> Bool { name == "Road" || name == "Railroad" }
    /// Unciv Tile.owningCity
    func owningCity(_ c: HexCoord) -> City? {
        guard let owner = map[c]?.ownerCivId else { return nil }
        return cities.first { $0.civId == owner && $0.tiles.contains(c) }
    }
    /// Unciv Tile.isMarkedForCreatesOneImprovement: Unciv marks the tile itself (improvementInProgress with negative
    /// turns); ours keeps the claim on the city that made it.
    func isMarkedForCreatesOneImprovement(_ c: HexCoord) -> Bool { cities.contains { $0.reservedImprovementTile == c } }
    /// Unciv MapUnit.cache.hasUniqueToBuildImprovements: any "Can build [] improvements on tiles" (a Legion has it too)
    func hasUniqueToBuildImprovements(_ u: Unit) -> Bool { !u.def.improvementFilters.isEmpty }
    /// Unciv Tile.hasFalloutEquivalent
    func hasFalloutEquivalent(_ t: Tile) -> Bool { t.features.contains { rs.terrains[$0]?.uniques.contains(nullifyYields) == true } }
    /// Unciv Tile.terrainHasUnique(FreshWater)
    func terrainHasFreshWater(_ t: Tile) -> Bool { t.terrainNames.contains { rs.terrains[$0]?.uniques.contains("Fresh water") == true } }
    /// Unciv Tile.providesYield
    func tileProvidesYield(_ t: Tile) -> Bool {
        guard t.ownerCivId != nil else { return false }
        if t.isCityCenter || t.workingCityId != nil { return true }
        if let imp = t.improvement, !t.pillaged, rs.improvements[imp]?.uniques.contains("Tile provides yield without assigned population") == true { return true }
        // Unciv terrainHasUnique reads cachedTerrainData, built from allTerrains: the natural wonder counts
        // (Fountain of Youth carries this unique), not only the base terrain and the features.
        return allTerrainsOf(t).contains { $0.uniques.contains("Tile provides yield without assigned population") }
    }
    /// Unciv Tile.providesResources
    func tileProvidesResources(_ t: Tile, civId: Int) -> Bool {
        guard let res = t.resource, canSeeResource(res, civId: civId), let r = rs.resources[res], let civ = civ(civId) else { return false }
        let imps = rs.resourceImprovements[res] ?? []
        if t.isCityCenter { return imps.isEmpty || imps.contains { name in rs.improvements[name].map { $0.turnsToBuild != -1 && ($0.techRequired.map { civ.techs.contains($0) } ?? true) } ?? false } }
        if let imp = t.improvement, !t.pillaged, imps.contains(imp), rs.improvements[imp]?.techRequired.map({ civ.techs.contains($0) }) ?? true { return true }
        return r.resourceType == "Strategic" && !t.pillaged && (t.improvement.flatMap { rs.improvements[$0]?.isGreatImprovement } ?? false)
    }
    /// Unciv TileResource.getImprovements, in its order: `improvement`, then `improvedBy`, then every ruleset
    /// improvement (in ruleset order) that improves the resource by unique or replaces one already listed.
    func resourceImprovementsInOrder(_ res: String?) -> [String] {
        guard let res, let r = rs.resources[res] else { return [] }
        var out: [String] = []
        func add(_ n: String) { if !out.contains(n) { out.append(n) } }
        if let i = r.improvement { add(i) }
        r.improvedBy.forEach(add)
        let set = rs.resourceImprovements[res] ?? []
        for name in rs.improvementOrder {
            guard let imp = rs.improvements[name] else { continue }
            if set.contains(name) && !out.contains(name) { add(name) }
            else if let rep = imp.replaces, out.contains(rep) { add(name) }
        }
        return out
    }
    /// Unciv Tile.getImprovementToRepair
    func improvementToRepair(_ t: Tile) -> String? {
        if let imp = t.improvement, t.pillaged { return imp }
        if t.roads && t.roadPillaged { return t.railroad ? "Railroad" : "Road" }
        return nil
    }
    /// Unciv UnitActionsFromUniques.getRepairTurns: measured on the unit's current tile
    func repairTurns(_ unit: Unit) -> Int {
        guard let t = map[unit.coord], t.pillaged || t.roadPillaged else { return 0 }
        if t.improvementInProgress == "Repair" { return t.improvementTurnsLeft }
        guard let toRepair = improvementToRepair(t) else { return 0 }
        return min(improvementBuildTurns("Repair", unit: unit), improvementBuildTurns(toRepair, unit: unit))
    }
    /// Unciv MapUnit.canBuildImprovement
    func unitCanBuildImprovement(_ unit: Unit, _ imp: String, _ tile: Tile) -> Bool {
        if civ(unit.civId)?.isBarbarian == true { return false }
        guard let def = rs.improvements[imp] else { return false }
        // Workers never construct instant improvements, but may keep working one in progress
        if def.turnsToBuild == -1 && imp != "Cancel improvement order" && tile.improvementInProgress != imp { return false }
        let filters = unit.def.improvementFilters
        if tile.improvementInProgress == "Repair" {
            if let o = tile.ownerCivId, areAtWar(unit.civId, o) { return false }   // Tile.isEnemyTerritory
            return !filters.isEmpty
        }
        let ctx = UniqueContext(civId: unit.civId, unit: unit, tile: map[unit.coord])
        if def.uniqueObjects.contains(where: { $0.pattern == "Only available" && !conditionalsHold($0, ctx) })
            || def.uniqueObjects.contains(where: { $0.pattern == "Unavailable" && conditionalsHold($0, ctx) }) { return false }
        return filters.contains { unitFilterAllows($0, imp, tile, civId: unit.civId) }
    }
    /// Unciv MapUnit.canBuildImprovement / getRepairAction: `MultiFilter.multiFilter(params[0]) { improvement.matchesFilter(it)
    /// || tile.matchesTerrainFilter(it, civ) }` - the TERRAIN filter, not the whole tile filter. The whole one also
    /// matches the tile's road, so a Legion ("Can build [Road] improvements") on a road worked the Farm in progress
    /// under it, and the Farm finished twice as fast.
    func unitFilterAllows(_ filter: String, _ imp: String, _ tile: Tile, civId: Int) -> Bool {
        MultiFilter.multiFilter(filter) { f in
            improvementMatches(imp, f) || MultiFilter.multiFilter(f) { tileMatchesSingleTerrainFilter(tile, $0.trimmingCharacters(in: .whitespaces), civId: civId) }
        }
    }
    /// Unciv Tile.startWorkingOnImprovement: nothing on a marked tile; stockpiled costs paid; the queue is cleared
    /// and the improvement queued with its build time. The unit keeps its orders - an automated worker stays
    /// automated, and UnitTurnManager.endTurn works whatever is in progress under a unit that can build it.
    func startWorkingOnImprovement(at c: HexCoord, _ imp: String, unit: Unit) {
        if isMarkedForCreatesOneImprovement(c) { return }
        if let d = rs.improvements[imp], !stockpiledResourceRequirements(d.uniqueObjects, ctx: UniqueContext(civId: unit.civId, unit: unit, tile: map[c])).isEmpty {
            payImprovementStockpileCosts(imp, unit: unit)
        }
        guard var t = map[c] else { return }
        t.improvementInProgress = imp
        t.queuedImprovement = nil; t.queuedImprovementTurns = 0
        t.improvementTurnsLeft = improvementBuildTurns(imp, unit: unit)   // Unciv queueImprovement: god mode = 1 turn
        map[c] = t
    }
    /// Unciv Tile.stopWorkingOnImprovement: a marked tile keeps its mark
    private func stopWorkingOnImprovementUnlessMarked(at c: HexCoord) {
        if isMarkedForCreatesOneImprovement(c) { return }
        stopWorkingOnImprovement(at: c)
    }
    /// Unciv MapUnit.doAction, as called by the automation after a move: an AI unit has neither an action nor the
    /// automated flag and does nothing; an automated (human) unit with movement left is automated again.
    private func doActionAfterMove(_ unitId: Int) {
        guard let u = unit(unitId), u.isAutomated, u.hasMovement else { return }
        if isEscorting(u), let e = otherEscortUnit(u), !e.hasMovement { return }
        automateUnitMoves(unitId)
    }

    /// Unciv tile.clone(); setImprovement(name) with no civ - what the tile would be with the improvement in place
    /// (TileImprovementFunctions.setImprovement / activateRemovalImprovement / setRoadStatus / setRepaired).
    private func tileWithImprovement(_ t: Tile, _ name: String) -> Tile {
        var n = t
        guard let def = rs.improvements[name] else { n.pillaged = false; n.improvement = nil; return n }
        if name.hasPrefix("Remove ") {
            let removed = String(name.dropFirst(7))
            // A removed feature takes the improvement that needs it with it (a Lumber mill with its forest)
            if let cur = n.improvement, let cd = rs.improvements[cur],
               n.features.contains(where: { cd.terrainsCanBeBuiltOn.contains($0) && $0 == removed }),
               !cd.terrainsCanBeBuiltOn.contains(n.baseTerrain) { n.improvement = nil; n.pillaged = false }
            if name == "Remove Road" || name == "Remove Railroad" { n.roads = false; n.railroad = false; n.roadPillaged = false }
            else if n.improvement == removed { n.improvement = nil; n.pillaged = false }
            else if let i = n.features.firstIndex(of: removed) { n.features.remove(at: i) }
        } else if name == "Road" { n.roads = true; n.railroad = false; n.roadPillaged = false }
        else if name == "Railroad" { n.roads = true; n.railroad = true; n.roadPillaged = false }
        else if name == "Repair" { if n.pillaged { n.pillaged = false } else { n.roadPillaged = false } }
        else { n.pillaged = false; n.improvement = name }
        if def.uniques.contains("Removes removable features when built") {
            // as setImprovement does it: removable (a "Remove X" exists) and not allowed under the improvement
            // (isAllowedOnFeature: the terrain filters of terrainsCanBeBuiltOn and "Does not need removal of []")
            n.features.removeAll { feature in
                guard let fd = rs.terrains[feature] else { return false }
                return rs.improvements["Remove \(feature)"] != nil && !def.isAllowedOnFeature(fd)
            }
        }
        return n
    }
    /// Unciv TileStatFunctions.getStatDiffForImprovement: the tile's stats with the improvement minus without (Float)
    func statDiffForImprovement(_ t: Tile, _ name: String, civId: Int, currentTileStats: Stats? = nil) -> Stats {
        let city = owningCity(t.coord)
        let current = currentTileStats ?? tileStats(t, civId: civId, city: city).f32
        let future = tileStats(tileWithImprovement(t, name), civId: civId, city: city).f32
        return (future - current).f32
    }

    // MARK: - WorkerAutomation.automateWorkerAction

    func automateWorkerAction(_ unitId: Int, dangerousTiles: Set<HexCoord>) {
        guard let unit = unit(unitId) else { return }
        _ = getWorkerAutomation(unit.civId)
        let current = unit.coord
        let currentTileIsCreatesOneImprovementMarker = isMarkedForCreatesOneImprovement(current)
        // Must be called before any getPriority checks to guarantee the local road cache is processed
        var citiesToConnect: [City] = []
        AI.timed("w.connectList") { citiesToConnect = nearbyCitiesToConnect(unit) }
        let wdbg = wdbgCiv != nil && wdbgCiv == civ(unit.civId)?.nation
        if wdbg { let p = uncivPosition(current); print("WDBGE t=\(uncivTurns) \(unit.name) at \(p.x),\(p.y) mv=\(unit.movementLeft) inProg=\(map[current]?.improvementInProgress ?? "null") connect=\(citiesToConnect.map { $0.name }.joined(separator: "+"))") }
        // Shortcut: we are working a suitable tile - finish everything here
        if !currentTileIsCreatesOneImprovementMarker, map[current]?.improvementInProgress != nil, !dangerousTiles.contains(current), fullPriority(current, unit) >= 2 { return }
        var tileToWork: HexCoord? = nil
        AI.timed("w.find") { tileToWork = findTileToWork(unit, tilesToAvoid: dangerousTiles) }
        if epochsDebug, epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)" {
            let wa = getWorkerAutomation(unit.civId)
            let u0 = uncivPosition(current)
            let tgt = tileToWork.map { c -> String in let u = uncivPosition(c); let t = map[c]!; return "(\(u.x),\(u.y))\(t.baseTerrain)/\(t.resource ?? "-")" } ?? "-"
            let bi = tileToWork.flatMap { wa.tileRankings[$0]?.bestImprovement } ?? "-"
            let bp = tileToWork.map { improvementPriority($0, unit) } ?? 0
            print("WRKE t=\(turn) at (\(u0.x),\(u0.y)) inProgress=\(map[current]?.improvementInProgress ?? "nil") target=\(tgt) imp=\(bi) prio=\(bp)")
            if ProcessInfo.processInfo.environment["WRKCAND"] != nil {
                let cands = map.tilesWithin(current, radius: 3).filter { c in
                    let owner = map[c]?.ownerCivId
                    return (owner == nil || owner == unit.civId) && isAutomationWorkableTile(c, tilesToAvoid: dangerousTiles, current: current, unit: unit) && basePriority(c, unit) >= 0
                }.map { c -> (Double, Double, String) in
                    let p = uncivPosition(c)
                    return (basePriority(c, unit), fullPriority(c, unit), "\(p.x),\(p.y)w\(tileHasWorkToDo(c, unit) ? 1 : 0)r\(canReach(unit, c) ? 1 : 0)")
                }.sorted { ($0.0, $0.1) > ($1.0, $1.1) }
                print("WRKC t=\(turn) at (\(u0.x),\(u0.y)) " + cands.map { "\($0.2)b\($0.0)f\($0.1)" }.joined(separator: " "))
                if let pt = ProcessInfo.processInfo.environment["PROBE_TILE"] {
                    let xy = pt.split(separator: ",").compactMap { Int($0) }
                    if xy.count == 2, let c = map.tiles.first(where: { let p = uncivPosition($0.coord); return p.x == xy[0] && p.y == xy[1] })?.coord {
                        let t = map[c]!
                        print("WRKD t=\(turn) at (\(u0.x),\(u0.y)) probe=\(pt) own=\(t.ownerCivId.flatMap { civ($0)?.nation } ?? "-") avoid=\(dangerousTiles.contains(c)) wk=\(isAutomationWorkableTile(c, tilesToAvoid: dangerousTiles, current: current, unit: unit)) base=\(basePriority(c, unit)) full=\(fullPriority(c, unit)) best=\(getWorkerAutomation(unit.civId).tileRankings[c]?.bestImprovement ?? "nil") impPrio=\(improvementPriority(c, unit)) feats=\(t.features) dangerN=\(dangerousTiles.count)")
                    }
                }
            }
        }
        if wdbg { let p = tileToWork.map { uncivPosition($0) }; print("WDBGE   tileToWork=\(p.map { "\($0.x)" } ?? "null"),\(p.map { "\($0.y)" } ?? "null")") }
        if let t = tileToWork, t != current { headTowardsTileToWork(unitId, t); return }
        if !currentTileIsCreatesOneImprovementMarker && map[current]?.improvementInProgress != nil { return }   // we're working!
        if tileToWork == current && tileHasWorkToDo(current, unit) { startWorkOnCurrentTile(unitId); return }
        let wtrace = epochsDebug && epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)"
        func wsay(_ branch: String) { if wtrace, let u = self.unit(unitId) { let p = uncivPosition(u.coord); print("WRKB t=\(turn) \(u.name) branch=\(branch) now=\(p.x),\(p.y)") } }
        // Support Alpha Frontier-Style Workers that _also_ have the "May create improvements on water resources" unique
        if unit.def.createsWaterImprovements && automateWorkBoats(unitId) { wsay("workBoats"); return }
        if AI.timedBool("w.undeveloped", { tryHeadTowardsUndevelopedCity(unitId, current) }) { wsay("undevelopedCity"); if wdbg { print("WDBGE   undeveloped") }; return }
        if wdbg { print("WDBGE   tryConnect") }
        // Nothing to do, try again to connect cities
        if AI.timedBool("w.connect", { tryConnectingCities(unitId, citiesToConnect) }) { wsay("connectCities"); return }
        // Unciv: every automated worker that found nothing says so (the AI's notification is dropped by addNotification)
        if let u = self.unit(unitId) { notify(u.civId, "\(u.shortDisplayName) has no work to do.", category: .Units, icons: [u.name, "OtherIcons/Sleep"], actions: [.unit(u.coord, u.id)]) }
        // Idle CS units should wander so they don't obstruct players so much
        if civ(unit.civId)?.isCityState == true { wander(unitId, stayInTerritory: true, tilesToAvoid: dangerousTiles) }
    }
    /// Unciv MapUnit.closestCity: the owning city of the current tile (any civ's), else the nearest city of our own
    private func closestCity(_ unit: Unit) -> Int? {
        if let c = owningCity(unit.coord) { return c.id }
        return cities(of: unit.civId).min { $0.coord.distance(to: unit.coord) < $1.coord.distance(to: unit.coord) }?.id
    }
    private func fillWorkersPerCity(_ wa: WorkerAutomationState) {
        if !wa.workersPerCity.isEmpty { return }
        for u in units(of: wa.civId) where hasUniqueToBuildImprovements(u) { wa.addWorkers(closestCity(u), 1) }
    }
    /// Unciv WorkerAutomation.tryHeadTowardsUndevelopedCity
    private func tryHeadTowardsUndevelopedCity(_ unitId: Int, _ current: HexCoord) -> Bool {
        guard let unit = unit(unitId), !cities(of: unit.civId).isEmpty else { return false }
        let wa = getWorkerAutomation(unit.civId)
        fillWorkersPerCity(wa)
        let owning = owningCity(current)?.id
        // Note, however, that the closest city to a tile isn't necessarily the owning city
        // Only move to cities with fewer workers nearby. `sortedBy` is stable: ties keep the civ's city order.
        let target = cities(of: unit.civId).enumerated().sorted { ($0.element.coord.distance(to: current), $0.offset) < ($1.element.coord.distance(to: current), $1.offset) }.map { $0.element }.first { city in
            city.id != owning && wa.workers(city.id) < wa.workers(closestCity(unit))
                // Unciv `it.getTiles().any { ... }` walks the city's HashSet and stops at the first hit; the tiles it
                // asks tileHasWorkToDo about are ranked and cached for the whole civ, so the walk order matters.
                && uncivTileWalk(city).contains { t in
                    guard let tile = map[t], tile.isLand, !units(at: t).contains(where: { hasUniqueToBuildImprovements($0) }) else { return false }
                    return tile.pillaged || tile.roadPillaged || tileHasWorkToDo(t, unit)
                }
                && canReach(unit, city.coord)
        }
        if wdbgCiv != nil && wdbgCiv == civ(unit.civId)?.nation { print("WDBGE   wpc=" + cities(of: unit.civId).map { "\($0.name):\(wa.workers($0.id))" }.joined(separator: " ") + " closest=\(closestCity(unit).flatMap { id in cities.first { $0.id == id }?.name } ?? "-") -> \(target?.name ?? "null")") }
        guard let city = target else { return false }
        wa.addWorkers(closestCity(unit), -1)
        wa.addWorkers(city.id, +1)
        let reached = headTowards(unitId, city.coord) ?? current
        if reached != current { doActionAfterMove(unitId) }   // since we've moved, maybe we can do something here - automate
        return true
    }
    /// Unciv WorkerAutomation.startWorkOnCurrentTile
    private func startWorkOnCurrentTile(_ unitId: Int) {
        guard let unit = unit(unitId), let rank = getWorkerAutomation(unit.civId).tileRankings[unit.coord] else { return }
        if rank.repairImprovement == true { invokeRepairAction(unitId); return }
        if let imp = rank.bestImprovement { startWorkingOnImprovement(at: unit.coord, imp, unit: unit) }
    }
    /// Unciv UnitActionsFromUniques.getRepairAction(unit)?.action?.invoke(): the same action the player's Repair button
    /// takes, only when it could be taken now.
    private func invokeRepairAction(_ unitId: Int) {
        guard let repair = repairAction(unitId), repair.couldConstruct else { return }
        queueRepair(unitId)
    }
    /// Unciv UnitActionsFromUniques.getRepairAction: nil when the unit is offered no Repair here (no Repair in the ruleset,
    /// no unique to build improvements, embarked, a city centre, nothing pillaged, or no BuildImprovements filter
    /// matching the improvement to repair or the terrain); otherwise that improvement, and whether the action could be
    /// taken now: `couldConstruct = hasMovement && !isCityCenter && improvementInProgress != repair &&
    /// !isEnemyTerritory && getImprovementBuildingProblems(improvementToRepair).none { it == OutsideBorders }`.
    func repairAction(_ unitId: Int) -> (toRepair: String, couldConstruct: Bool)? {
        guard let unit = unit(unitId), rs.improvements["Repair"] != nil, hasUniqueToBuildImprovements(unit), !isEmbarked(unit),
              let t = map[unit.coord], !t.isCityCenter, t.pillaged || t.roadPillaged, let toRepair = improvementToRepair(t) else { return nil }
        guard unit.def.improvementFilters.contains(where: { unitFilterAllows($0, toRepair, t, civId: unit.civId) }) else { return nil }
        let enemyTerritory = t.ownerCivId.map { areAtWar(unit.civId, $0) } ?? false
        let outsideBorders = t.ownerCivId != unit.civId && !(rs.improvements[toRepair]?.uniques.contains(canBuildOutsideBorders) ?? false)
            && (!(rs.improvements[toRepair]?.uniques.contains(canBuildJustOutsideBorders) ?? false) || !map.neighbors(of: t.coord).contains { map[$0]?.ownerCivId == unit.civId })
        return (toRepair, unit.hasMovement && t.improvementInProgress != "Repair" && !enemyTerritory && !outsideBorders)
    }
    /// Unciv getRepairAction's action: `tile.queueImprovement(Constants.repair, turnsToBuild)` - appended after anything
    /// already in progress, never replacing it - then `unit.action = null`. Unciv's `automated` is a flag of its own that
    /// survives that: an automated worker stays automated, and a road-connecting one (action ConnectRoad, automated)
    /// is left automated with no action.
    func queueRepair(_ unitId: Int) {
        guard let ui = unitIndex(unitId), let t = map[units[ui].coord] else { return }
        let turns = repairTurns(units[ui])
        var nt = t
        if nt.improvementInProgress == nil { nt.improvementInProgress = "Repair"; nt.improvementTurnsLeft = turns }
        else if nt.queuedImprovement == nil { nt.queuedImprovement = "Repair"; nt.queuedImprovementTurns = turns }
        map[t.coord] = nt
        switch units[ui].order {
        case .automate: break
        default: units[ui].order = .none   // `unit.action = null` - `automated` (a road-connecting worker's too) stays
        }
    }
    /// Unciv WorkerAutomation.headTowardsTileToWork
    private func headTowardsTileToWork(_ unitId: Int, _ target: HexCoord) {
        guard let unit = unit(unitId) else { return }
        let current = unit.coord
        let reached = headTowards(unitId, target) ?? current
        if let u = self.unit(unitId), map.neighbors(of: reached).contains(target),
           canMoveTo(u, target, allowSwap: true), !canMoveTo(u, target, allowSwap: false), canUnitSwapTo(u, target) {
            // There must be a unit on the target tile! Let's swap with it.
            swapMoveToTile(unitId, target)
        }
        if reached != current { doActionAfterMove(unitId) }
        // If we have reached a fort tile that is in progress and shouldn't be there, cancel it.
        if reached == target, map[reached]?.improvementInProgress == "Fort" { stopWorkingOnImprovementUnlessMarked(at: reached) }
        guard let u = self.unit(unitId), u.hasMovement, reached == target else { return }
        if tileHasWorkToDo(u.coord, u) { startWorkOnCurrentTile(unitId) }
    }
    /// Unciv WorkerAutomation.findTileToWork
    private func findTileToWork(_ unit: Unit, tilesToAvoid: Set<HexCoord>) -> HexCoord? {
        let current = unit.coord
        if isAutomationWorkableTile(current, tilesToAvoid: tilesToAvoid, current: current, unit: unit) && basePriority(current, unit) >= 3,
           let t = map[current], t.pillaged || t.roadPillaged || hasFalloutEquivalent(t) || tileHasWorkToDo(current, unit) { return current }
        var prio: [HexCoord: Double] = [:]
        let workable = map.tilesWithin(current, radius: 3).filter { c in
            let owner = map[c]?.ownerCivId
            guard owner == nil || owner == unit.civId || civ(owner!)?.isCityState == true, isAutomationWorkableTile(c, tilesToAvoid: tilesToAvoid, current: current, unit: unit) else { return false }
            let p = basePriority(c, unit); prio[c] = p
            return p >= 0
        }
        // groupBy keeps the first-seen order inside a group; the keys are distinct, so sorting them is safe
        var groupOrder: [Double] = []
        var groups: [Double: [HexCoord]] = [:]
        for c in workable { let k = prio[c]!; if groups[k] == nil { groupOrder.append(k) }; groups[k, default: []].append(c) }
        for key in groupOrder.sorted(by: >) {
            var best: HexCoord? = nil
            // Kotlin's sortedBy is stable: two candidates the same distance away keep getTilesInDistance's order.
            for t in groups[key]!.enumerated().sorted(by: { a, b in
                let da = a.element.distance(to: current), db = b.element.distance(to: current)
                return da != db ? da < db : a.offset < b.offset
            }).map({ $0.element }) {
                // These are the expensive calculations (tileCanBeImproved, canReach), so we only apply these filters after everything else it done.
                if !tileHasWorkToDo(t, unit) { continue }
                if t == current { return current }
                if !canReach(unit, t) { continue }
                if best == nil || fullPriority(t, unit) > fullPriority(best!, unit) { best = t }
            }
            if let b = best { return b }
        }
        return nil
    }
    /// Unciv WorkerAutomation.isAutomationWorkableTile
    private func isAutomationWorkableTile(_ c: HexCoord, tilesToAvoid: Set<HexCoord>, current: HexCoord, unit: Unit) -> Bool {
        guard let t = map[c] else { return false }
        let wa = getWorkerAutomation(unit.civId)
        if tilesToAvoid.contains(c) { return false }
        if isMarkedForCreatesOneImprovement(c) { return false }
        // Another improvement-building unit of the same layer (civilian / military) occupies the tile
        if !(c == current || !units(at: c).contains(where: { $0.isMilitary == unit.isMilitary && hasUniqueToBuildImprovements($0) })) { return false }
        if let o = t.ownerCivId, o != wa.civId { return false }
        if t.isCityCenter { return false }
        if wa.tilesOfRoadsMap[c] != nil { return true }
        // Don't try to improve tiles we can't benefit from at all
        if !canSeeResource(t.resource, civId: wa.civId) && !map.tilesWithin(c, radius: rs.constants.cityWorkRange).contains(where: { city(at: $0)?.civId == wa.civId }) { return false }
        if let imp = t.improvement, rs.improvements[imp]?.uniques.contains("Will not be replaced by automated units") == true, !(t.pillaged || t.roadPillaged) { return false }
        return true
    }
    /// Unciv WorkerAutomation.getBasePriority, on the automation of `asCiv` (the tile owner, for the citadel placer)
    /// or of the unit's civ. Float throughout, as there.
    func basePriority(_ c: HexCoord, _ unit: Unit, asCiv: Int? = nil) -> Double {
        let civId = asCiv ?? unit.civId
        let wa = getWorkerAutomation(civId)
        let unitSpecific = f(2 - min(2, max(0, Double(c.distance(to: unit.coord)) / 2)) * 3)
        if let r = wa.tileRankings[c] { return f(r.tilePriority + unitSpecific) }
        guard let t = map[c] else { return -100 }
        var priority = 0.0
        if t.ownerCivId == civId {
            priority = f(priority + 1)   // the fact it's inside our borders means we can do something
            if tileProvidesYield(t) { priority = f(priority + 2) }
            if hasFalloutEquivalent(t) { priority = f(priority + 1) }
            if let lastName = t.features.last, let last = rs.terrains[lastName] {
                if last.uniqueObjects.contains(where: { $0.pattern == cutDownPattern }) { priority = f(priority + f(0.5)) }
                else if last.uniques.contains("Vegetation") { priority = f(priority - f(0.3)) }
            }   // Removing our forests is good for tempo, jungles not as much
            if terrainHasFreshWater(t) { priority = f(priority + 1) }
        }
        if canSeeResource(t.resource, civId: civId) {
            priority = f(priority + 1)
            if t.resource.flatMap({ rs.resources[$0]?.resourceType }) == "Luxury" { priority = f(priority + 5) }
        }
        wa.tileRankings[c] = TileImprovementRank(tilePriority: priority)
        return f(priority + unitSpecific)
    }
    /// Unciv WorkerAutomation.getImprovementPriority
    private func improvementPriority(_ c: HexCoord, _ unit: Unit) -> Double {
        _ = basePriority(c, unit)
        let wa = getWorkerAutomation(unit.civId)
        guard var rank = wa.tileRankings[c], let t = map[c] else { return -100 }
        if rank.improvementPriority == nil {
            // All values of rank have to be initialized
            rank.improvementPriority = -100; rank.bestImprovement = nil; rank.repairImprovement = false
            if let best = chooseImprovement(unit, tile: t, at: c) {
                rank.bestImprovement = best
                // Increased priority if the improvement has been worked on longer
                let timeSpent: Double = t.improvementInProgress == best ? Double(improvementBuildTurns(best, unit: unit) - t.improvementTurnsLeft) : 0
                rank.improvementPriority = f(improvementRanking(t, at: c, unit, best) + timeSpent)
            }
            if let cur = t.improvement, rs.improvements[cur] != nil, t.pillaged || t.roadPillaged, owningCity(c) != nil, let toRepair = improvementToRepair(t) {
                // Value repairing higher when it is quicker and is in progress
                var repairBonus = improvementBuildTurns(toRepair, unit: unit) - repairTurns(unit)
                if t.improvementInProgress == "Repair" { repairBonus += repairTurns(unit) - t.improvementTurnsLeft }
                let repairPriority = f(Double(repairBonus) + rankStatsValue(statDiffForImprovement(t, cur, civId: unit.civId), civId: unit.civId))
                if repairPriority > rank.improvementPriority! { rank.improvementPriority = repairPriority; rank.bestImprovement = nil; rank.repairImprovement = true }
            }
            wa.tileRankings[c] = rank
        }
        // A better tile than this unit can build might have been stored in the cache
        if rank.repairImprovement != true && (rank.bestImprovement == nil || !unitCanBuildImprovement(unit, rank.bestImprovement!, t)) { return -100 }
        return rank.improvementPriority!
    }
    /// Unciv WorkerAutomation.getFullPriority
    private func fullPriority(_ c: HexCoord, _ unit: Unit) -> Double { f(basePriority(c, unit) + improvementPriority(c, unit)) }
    /// Unciv WorkerAutomation.tileHasWorkToDo
    private func tileHasWorkToDo(_ c: HexCoord, _ unit: Unit) -> Bool { improvementPriority(c, unit) > 0 }

    /// Unciv WorkerAutomation.chooseImprovement. `hypothetical`: `t` stands for Unciv's `tile.clone()` of the
    /// Remove-feature look-ahead, not the map's own tile (see improvementRanking).
    private func chooseImprovement(_ unit: Unit, tile t: Tile, at c: HexCoord, ignore: Set<String> = [], hypothetical: Bool = false) -> String? {
        guard let civ = civ(unit.civId) else { return nil }
        if isMarkedForCreatesOneImprovement(c) { return nil }
        // You can keep working on half-built improvements, even if they're unique to another civ
        if let inProgress = t.improvementInProgress { return rs.improvements[inProgress] != nil ? inProgress : nil }
        let stopRemovingVegetation = civ.isPlayer && !UserSettings.automatedWorkersRemoveVegetation && t.terrainNames.contains { rs.terrains[$0]?.uniques.contains("Vegetation") == true }
        let buildable = Set(buildableImprovements(t, civId: civ.id).map { $0.name })   // Unciv tile.improvementFunctions.canBuildImprovement(it, gameContext)
        let potentialNames = rs.improvementOrder.filter { name in
            guard buildable.contains(name), !ignore.contains(name), let imp = rs.improvements[name] else { return false }
            // Unciv canImprovementBeBuiltHere: never the improvement already on the tile, pillaged or not (that is repaired)
            if name == t.improvement { return false }
            if let to = imp.uniqueTo, to != civ.nation { return false }
            // Unciv ImprovementBuildingProblem.OutsideBorders
            if t.ownerCivId != civ.id && !imp.uniques.contains(canBuildOutsideBorders)
                && (!imp.uniques.contains(canBuildJustOutsideBorders) || !map.neighbors(of: c).contains { map[$0]?.ownerCivId == civ.id }) { return false }
            return unitCanBuildImprovement(unit, name, t) && improvementResourcesAvailable(imp, civId: civ.id) && !(stopRemovingVegetation && name.hasPrefix("Remove "))
        }
        if potentialNames.isEmpty { return nil }
        let potential = Set(potentialNames)
        let ignoreNext = ignore.union(potential)
        let currentStats = tileStats(t, civId: unit.civId, city: owningCity(c)).f32
        var bestBuildable: String? = nil
        var bestValue = 0.0
        for name in potentialNames {
            let v = improvementRanking(t, at: c, unit, name, currentTileStats: currentStats, ignore: ignoreNext, hypothetical: hypothetical)
            if v > 0 && (bestBuildable == nil || v > bestValue) { bestBuildable = name; bestValue = v }   // maxByOrNull: the first maximum
        }
        if t.improvement != nil && civ.isPlayer && !UserSettings.automatedWorkersReplaceImprovements && !autoPlayingFullAI { bestBuildable = nil; if GameState.evlogOn { hbr("S2.noReplace", civ.id) } }   // WorkerAutomation.kt:413-414
        // Unciv Tile.lastTerrain: the last feature, else the natural wonder, else the base terrain
        let lastTerrain = t.features.last.flatMap { rs.terrains[$0] } ?? t.naturalWonder.flatMap { rs.terrains[$0] } ?? rs.terrains[t.baseTerrain]
        func isRemovable(_ name: String) -> Bool { potential.contains("Remove \(name)") }
        let resource = t.resource.flatMap { rs.resources[$0] }
        let canSee = canSeeResource(t.resource, civId: unit.civId)
        let resourceImps = resourceImprovementsInOrder(t.resource)
        var improvementForResource: String? = nil
        if canSee && resource != nil {
            if !t.features.isEmpty, let lt = lastTerrain, lt.unbuildable, isRemovable(lt.name), !tileProvidesResources(t, civId: unit.civId), !resourceImprovementAllowedOnFeature(t, potential: potential) {
                improvementForResource = "Remove \(lt.name)"
            } else {
                var best = -Double.infinity
                for name in resourceImps where potential.contains(name) {
                    let v = improvementRanking(t, at: c, unit, name, ignore: ignoreNext, hypothetical: hypothetical)
                    if improvementForResource == nil || v > best { improvementForResource = name; best = v }
                }
            }
        }
        // After gathering all the data, we conduct the hierarchy in one place
        if let b = bestBuildable, isRoad(b) { return b }
        // For bonus resources we just want the highest-yield improvement, not necessarily the resource-yielding improvement
        if let ifr = improvementForResource, let r = resource, r.resourceType != "Bonus" { return ifr == t.improvement ? nil : ifr }
        // If this is a resource that HAS an improvement that we can see, but this unit can't build it, don't waste your time
        if canSee, let r = resource, r.resourceType != "Bonus", !resourceImps.isEmpty { return nil }
        guard let best = bestBuildable else { return nil }
        // What we have is better, even if it's pillaged we should repair it
        if let cur = t.improvement, rs.improvements[cur] != nil, improvementRanking(t, at: c, unit, cur, ignore: ignoreNext, hypothetical: hypothetical) > improvementRanking(t, at: c, unit, best, ignore: ignoreNext, hypothetical: hypothetical) { return nil }
        if let lt = lastTerrain, isRemovable(lt.name), rankStatsValue(lt.stats, civId: unit.civId) < 0 || lt.uniques.contains(nullifyYields) { return "Remove \(lt.name)" }
        return best
    }
    /// Unciv WorkerAutomation.isResourceImprovementAllowedOnFeature
    private func resourceImprovementAllowedOnFeature(_ t: Tile, potential: Set<String>) -> Bool {
        return resourceImprovementsInOrder(t.resource).contains { name in
            guard potential.contains(name), let imp = rs.improvements[name] else { return false }
            return t.features.contains { f in imp.terrainsCanBeBuiltOn.contains(f) || imp.uniqueObjects.contains { $0.pattern == "Does not need removal of []" && $0.param(0) == f } }
        }
    }
    /// Unciv WorkerAutomation.getImprovementRanking (Float)
    private func improvementRanking(_ t: Tile, at c: HexCoord, _ unit: Unit, _ name: String, currentTileStats: Stats? = nil, ignore: Set<String> = [], hypothetical: Bool = false) -> Double {
        let wa = getWorkerAutomation(unit.civId)
        // Add the value of roads if we want to build it here.
        // Unciv's `tile in roadBetweenCitiesAutomation.tilesOfRoadsMap` is a HashMap<Tile, RoadPlan> lookup, and Tile
        // overrides neither equals nor hashCode: the Remove-feature look-ahead's `tile.clone()` is never in it, so the
        // clone's Road is ranked by its stat diff like any other improvement. Our map is keyed by coordinate, and the
        // clone found the real tile's plan - Road won the look-ahead and "Remove Forest" lost the Farm's yields.
        if !hypothetical && isRoad(name) && name == wa.bestRoadAvailable, let plan = wa.tilesOfRoadsMap[c] {
            return f(plan.priority - 9)   // We want some forest chopping and farm building first if the road doesn't have high priority
        }
        guard let def = rs.improvements[name] else { return 0 }
        // If this tile is not in our territory or neighboring it, it has no value
        if t.ownerCivId != unit.civId {
            if !def.uniques.contains(canBuildOutsideBorders) || !map.neighbors(of: c).contains(where: { n in map[n]?.ownerCivId == unit.civId && (owningCity(n).map { c.distance(to: $0.coord) <= rs.constants.cityWorkRange } ?? false) }) { return 0 }
        }
        var stats = statDiffForImprovement(t, name, civId: unit.civId, currentTileStats: currentTileStats)
        // For Moai-like improvements, add the yields of future self-adjacencies
        for u in def.uniqueObjects where u.pattern == "[] for each adjacent []" && u.param(1) == name {
            guard let st = u.stats, let civ = civ(unit.civId) else { continue }
            let n = map.neighbors(of: c).filter { n in map[n].map { $0.improvement != name && canBuildImprovement(def, on: $0, civId: civ.id) } ?? false }.count
            stats = (stats + st * Double(n)).f32
        }
        var improvedByNew = canSeeResource(t.resource, civId: unit.civId) && resourceImprovementsInOrder(t.resource).contains(name)
        if name.hasPrefix("Remove ") {
            // We need to look beyond what we are doing right now and at the final improvement that will be on this tile
            let removalObject = String(name.dropFirst(7))
            let removedFeature = t.features.contains(removalObject)
            let removalImprovement = removalObject == t.improvement
            if removedFeature || removalImprovement {
                var newTile = t
                if removedFeature, let i = newTile.features.firstIndex(of: removalObject) { newTile.features.remove(at: i) }
                if removalImprovement { newTile.improvement = nil; newTile.pillaged = false }
                if let wanted = chooseImprovement(unit, tile: newTile, at: c, ignore: ignore, hypothetical: true) {   // Unciv: on `tile.clone(addUnits = false)`
                    stats = (stats + statDiffForImprovement(newTile, wanted, civId: unit.civId)).f32
                    // Take into account that the resource might be improved by the *final* improvement
                    improvedByNew = resourceImprovementsInOrder(newTile.resource).contains(wanted)
                    if let last = t.features.last.flatMap({ rs.terrains[$0] }), last.uniqueObjects.contains(where: { $0.pattern == cutDownPattern }) { stats.production = f(stats.production + 0.5) }   // We're gaining tempo by chopping the forest
                }
            }
        }
        // Unciv: "If the tile is a neighboring tile it has a lower value" - `if (tile.getOwner() != unit.civ) stats.div(3f)`.
        // Stats.div is NON-mutating (it returns a new Stats), and the result is dropped: a neighbouring tile keeps its
        // full value. Ours divided, and an Aztec worker valued a Marsh outside its borders at 0.4 against Unciv's 1.2.
        var value = rankStatsValue(stats, civId: unit.civId)
        // Calculate the bonus from gaining the resources, this isn't included in the stats above
        if let r = t.resource.flatMap({ rs.resources[$0] }) {
            let unlocks = resourceImprovementsInOrder(r.name)
            if r.resourceType != "Bonus" {
                // Always build the resource-specific improvement for luxuries and strategics
                if let cur = t.improvement, unlocks.contains(cur) { value = f(value - 2) }
                if improvedByNew { value = f(value + 2) }
            } else {
                // For bonus resources, we want to build just enough resource-specific improvements
                if let cur = t.improvement, unlocks.contains(cur) { value = f(value - f(0.3)) }
                if improvedByNew && !map.tilesWithin(c, radius: 4).contains(where: { map[$0]?.improvement == name }) { value = f(value + f(0.3)) }
            }
        }
        // Replace/build improvements on other tiles before this one (isImprovementProbablyAFort)
        if let cur = t.improvement, rs.improvements[cur]?.uniqueObjects.contains(where: { $0.pattern == "Gives a defensive bonus of []%" }) == true { value = f(value / 2) }
        return value
    }

    /// Unciv WorkerAutomation.automateWorkBoats
    func automateWorkBoats(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId) else { return false }
        // Unciv: unit.civ.cities.flatMap { it.getTiles() } - the civ's cities in order, each walked as the
        // Kotlin HashSet it is. Two sea resources the same distance from the boat, one of them a luxury, and the
        // walk decides which one gets the fishing boats. See uncivTileWalk.
        let candidates = cities(of: unit.civId).flatMap { uncivTileWalk($0) }
        let targets = candidates.filter { c in hasWorkableSeaResourceTile(c, civId: unit.civId) && (unit.coord == c || canUnitEnter(unit, c)) }
            .enumerated().sorted { a, b in
                let da = a.element.distance(to: unit.coord), db = b.element.distance(to: unit.coord)
                return da != db ? da < db : a.offset < b.offset
            }.map { $0.element }
        let range = rs.constants.cityWorkRange
        if epochsDebug, epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)" {
            // Unciv's own BOAT probe prints the same list: every candidate with its aerial distance, in the
            // order the sort left them, so the two can be read side by side.
            let at = uncivPosition(unit.coord)
            let cand = targets.map { c -> String in
                let p = uncivPosition(c)
                return "(\(p.x),\(p.y))\(map[c]?.resource ?? "-")@\(c.distance(to: unit.coord))"
            }.joined(separator: ",")
            print("BOATE t=\(turn) civ=\(civ(unit.civId)?.nation ?? "?") at=\(at.x),\(at.y) cand=[\(cand)]")
        }
        // isNotBonusResourceOrWorkable: improve Oil even if no city reaps the yields, Fish only if one of our cities does
        guard let target = targets.first(where: { c in canReach(unit, c) && (rs.resources[map[c]!.resource!]?.resourceType != "Bonus" || cities(of: unit.civId).contains { $0.coord.distance(to: c) <= range }) }) else { return false }
        moveUnit(unitId, toward: target)
        guard let u = self.unit(unitId), u.coord == target else { return true }   // moving counts as progress
        if let a = greatPersonActions(u).first(where: { $0.1 == .improvement }) { performGreatPersonAction(unitId: unitId, a.1); return true }
        return false
    }
    /// Unciv WorkerAutomation.hasWorkableSeaResource: any of the resource's improvements can be built
    func hasWorkableSeaResourceTile(_ c: HexCoord, civId: Int) -> Bool {
        guard let t = map[c], t.isWater, let res = t.resource, canSeeResource(res, civId: civId), let civ = civ(civId) else { return false }
        let imps = resourceImprovementsInOrder(res)
        if let cur = t.improvement, imps.contains(cur) { return false }
        // Unciv: `resource.getImprovements().any { tile.improvementFunctions.canBuildImprovement(it, civInfo.state) }`
        return imps.contains { name in rs.improvements[name].map { canBuildImprovement($0, on: t, civId: civ.id) } ?? false }
    }

    // MARK: - MapPathing

    /// Unciv Tile.canCivPassThrough
    func canCivPassThrough(_ t: Tile, civId: Int) -> Bool {
        guard let owner = t.ownerCivId, owner != civId else { return true }
        if t.isCityCenter && areAtWar(civId, owner) && city(at: t.coord)?.hasJustBeenConquered != true { return false }   // Unciv: `&& !getCity()!!.hasJustBeenConquered`
        return canPassThroughTiles(civId, owner)
    }
    /// Unciv Tile.forestOrJungleAreRoads
    private func forestOrJungleAreRoads(_ t: Tile, civId: Int) -> Bool { forestsAreRoads(civId) && t.hasForestOrJungle && isFriendlyTerritory(t.coord, for: civId) }
    /// Unciv MapPathing.isValidRoadPathTile
    func isValidRoadPathTile(_ c: HexCoord, civId: Int) -> Bool {
        guard let t = map[c], let civ = civ(civId) else { return false }
        if t.isWater { return false }
        if t.isImpassable { return false }
        if !civ.explored.contains(c) { return false }
        if !canCivPassThrough(t, civId: civId) { return false }
        // hasRoadConnection(civ, false) || hasRailroadConnection(false): any road, pillaged or not
        if t.roads || t.railroad || forestOrJungleAreRoads(t, civId: civId) { return true }
        // canBuildImprovement(road / railroad): canImprovementBeBuiltHere refuses a city centre outright
        if t.isCityCenter { return false }
        return ["Road", "Railroad"].contains { name in rs.improvements[name].map { canBuildImprovement($0, on: t, civId: civ.id) } ?? false }
    }
    /// Unciv MapPathing.getRoadPath: AStar over valid road tiles, half cost onto existing road connections, no
    /// heuristic. Java's PriorityQueue is a binary heap, which MinHeap mirrors.
    func roadPath(civId: Int, from: HexCoord, to: HexCoord) -> [HexCoord]? {
        var open = MinHeap(); open.push(from, 0)
        var cost: [HexCoord: Double] = [from: 0]; var prev: [HexCoord: HexCoord] = [:]; var closed: Set<HexCoord> = []
        while let (cur, _) = open.pop() {
            if cur == to { var path = [to]; var c = to; while let p = prev[c] { path.append(p); c = p }; return path.reversed() }
            if closed.contains(cur) { continue }
            closed.insert(cur)
            for raw in cur.neighbors {
                let n = map.normalize(raw)
                guard map.contains(n), !closed.contains(n), isValidRoadPathTile(n, civId: civId), let t = map[n] else { continue }
                // roadPreferredMovementCost: hasRoadConnection(civ, false) || hasRailroadConnection(false)
                let step = (t.roads || t.railroad || forestOrJungleAreRoads(t, civId: civId)) ? 0.5 : 1.0
                let g = cost[cur]! + step
                if g < (cost[n] ?? .infinity) {
                    cost[n] = g; prev[n] = cur; open.push(n, g)
                    // Unciv AStar: the path is taken the first time the destination is touched, not when it is popped
                    if n == to { var path = [to]; var c = to; while let p = prev[c] { path.append(p); c = p }; return path.reversed() }
                }
            }
        }
        return nil
    }

    // MARK: - RoadBetweenCitiesAutomation

    /// Unciv City.isConnectedToCapital: the city is a key of the cached citiesConnectedToCapitalToMediums
    private func cityIsConnectedToCapital(_ city: City) -> Bool { city.isCapital || city.connectedToCapital }
    /// Unciv CityStats.isConnectedToCapital(roadType)
    private func cityIsConnectedToCapital(_ city: City, roadLevel level: Int) -> Bool {
        if cities(of: city.civId).count < 2 { return false }   // first city!
        if level == 2 { return railroadConnectedCityIds(city.civId).contains(city.id) }
        return cityIsConnectedToCapital(city)
    }
    /// Unciv RoadBetweenCitiesAutomation.tilesOfConnectedCities: `by lazy`, fixed at first use for the turn
    private func tilesOfConnectedCities(_ wa: WorkerAutomationState) -> [HexCoord] {
        if let t = wa.tilesOfConnectedCities { return t }
        let bestLevel = roadLevel(name: wa.bestRoadAvailable)
        let result = cities(of: wa.civId).filter { $0.isCapital || cityIsConnectedToCapital($0, roadLevel: bestLevel) }.map { $0.coord }
        wa.tilesOfConnectedCities = result
        return result
    }
    /// Unciv RoadBetweenCitiesAutomation.getWorstRoadTypeInPath
    private func worstRoadLevel(_ path: [HexCoord]) -> Int { path.map { roadLevel($0) }.min() ?? 2 }
    /// Unciv RoadBetweenCitiesAutomation.getRoadsToBuildFromCity
    private func roadsToBuild(from city: City, _ wa: WorkerAutomationState) -> [RoadPlan] {
        if let cached = wa.roadsToBuildByCitiesCache[city.id] { return cached }
        let bestLevel = roadLevel(name: wa.bestRoadAvailable)
        let toCapital = roadTypeOfConnectionToCapital(city)
        /// Rank 0, 1 or 2 of how important it is to build best available road to capital
        func rankCapitalPriority(_ level: Int) -> Double { level == 0 ? (bestLevel != 0 ? 2 : 0) : level == 1 ? (bestLevel != 1 ? 1 : 0) : 0 }
        let basePriority = rankCapitalPriority(toCapital)
        let myCities = cities(of: wa.civId)
        var plans: [RoadPlan] = []
        // Unciv `city.neighboringCities.filter { it.civ == civInfo && ... <= 8 }`: neighboringCities is `by lazy`, so
        // a city founded after this one first asked is never a road target from here (Kyoto never plans to Satsuma).
        let closeCities = neighboringCities(of: city).filter { $0.civId == wa.civId && $0.coord.distance(to: city.coord) <= 8 }
        let rdbg = wdbgCiv != nil && wdbgCiv == civ(wa.civId)?.nation
        let lvlName = ["None", "Road", "Railroad"]
        if rdbg { print("RDBGE t=\(uncivTurns) city=\(city.name) toCap=\(lvlName[toCapital]) best=\(lvlName[bestLevel]) conn=\(cityIsConnectedToCapital(city)) neigh=\(neighboringCities(of: city).map { $0.name }.joined(separator: "+"))") }
        for close in closeCities {
            // Try to find if the other city has planned to build a road to this city
            if let theirs = wa.roadsToBuildByCitiesCache[close.id], let existing = theirs.first(where: { $0.fromCity == city.id || $0.toCity == city.id }) { plans.append(existing); continue }
            if toCapital == bestLevel { continue }   // Avoid invoking MapPathing.getRoadPath
            // Kotlin indexOf: -1 for a city no longer in the list (a razed one the lazy neighbour list still holds)
            let ci = myCities.firstIndex { $0.id == city.id } ?? -1, cj = myCities.firstIndex { $0.id == close.id } ?? -1
            guard let path = ci < cj ? roadPath(civId: wa.civId, from: city.coord, to: close.coord) : roadPath(civId: wa.civId, from: close.coord, to: city.coord) else { continue }
            let worst = worstRoadLevel(path)
            if rdbg { print("RDBGE   to=\(close.name) worst=\(lvlName[worst]) path=" + path.map { let p = uncivPosition($0); return "\(p.x),\(p.y):\(lvlName[roadLevel($0)])" }.joined(separator: " ")) }
            if worst == bestLevel { continue }
            // Make sure that we are taking in to account the other cities needs
            let closeToCapital = roadTypeOfConnectionToCapital(close)
            var priority = max(basePriority, rankCapitalPriority(closeToCapital))
            if worst == 0 { priority += 2 } else if worst == 1 && bestLevel == 2 { priority += 1 }
            if closeToCapital > toCapital { priority += 1 }
            plans.append(RoadPlan(tiles: path, priority: f(priority + f(Double(city.population + close.population) / 4)), fromCity: city.id, toCity: close.id))
        }
        var bestPlan = chooseBestPlan(plans, bestLevel: bestLevel)
        if let b = bestPlan { plans = [b] }
        // If and only if we have no roads to build to close-by cities then we check for a road to build to the capital
        else if plans.isEmpty && toCapital < bestLevel && !cityIsConnectedToCapital(city), let (toCity, path) = roadToConnectCityToCapital(city, wa) {
            let worst = worstRoadLevel(path)
            let priority = basePriority + (worst == 0 ? 2 : 1)
            bestPlan = RoadPlan(tiles: path, priority: f(priority + f(Double(city.population) / 2)), fromCity: city.id, toCity: toCity.id)
            plans.append(bestPlan!)
        }
        if let b = bestPlan { for t in b.tiles where wa.tilesOfRoadsMap[t] == nil || wa.tilesOfRoadsMap[t]!.priority < b.priority { wa.tilesOfRoadsMap[t] = b } }
        if rdbg { print("RDBGE   plans=" + plans.map { p in "\(self.city(p.fromCity)?.name ?? "?")>\(self.city(p.toCity)?.name ?? "?"):\(p.priority)" }.joined(separator: " ")) }
        wa.roadsToBuildByCitiesCache[city.id] = plans
        return plans
    }
    /// Unciv RoadBetweenCitiesAutomation.getRoadToConnectCityToCapital: BFS over valid road tiles to the nearest connected city
    private func roadToConnectCityToCapital(_ city: City, _ wa: WorkerAutomationState) -> (City, [HexCoord])? {
        let connected = tilesOfConnectedCities(wa)
        guard let minDistance = connected.map({ $0.distance(to: city.coord) }).min() else { return nil }   // In mods with no capital city indicator, there are no connected cities
        let targets = Set(connected)
        let r = 2 + minDistance   // WorkerAutomationConst.maxBfsReachPadding
        let maxSize = 1 + 6 * r * (r + 1) / 2   // HexMath.getNumberOfTilesInHexagon
        var parent: [HexCoord: HexCoord] = [:]
        var reached: Set<HexCoord> = [city.coord]
        var queue = [city.coord]
        var head = 0
        // Unciv BFS.nextStep: stop once maxSize tiles are reached, else expand the head of the queue and return it
        while head < queue.count && reached.count < maxSize {
            let cur = queue[head]; head += 1
            for raw in cur.neighbors {
                let n = map.normalize(raw)
                guard map.contains(n), !reached.contains(n), isValidRoadPathTile(n, civId: city.civId) else { continue }
                reached.insert(n); parent[n] = cur; queue.append(n)
            }
            if targets.contains(cur), let target = self.city(at: cur) {
                // We have a winner!
                var path = [cur]; var c = cur
                while let p = parent[c] { path.append(p); c = p }
                return (target, path)
            }
        }
        return nil
    }
    /// Unciv RoadBetweenCitiesAutomation.chooseBestPlan
    private func chooseBestPlan(_ plans: [RoadPlan], bestLevel: Int) -> RoadPlan? {
        if plans.count < 2 { return plans.first }
        // RoadPlan.numberOfRoadsToBuild: tiles whose unpillaged road is not the best road
        func toBuild(_ p: RoadPlan) -> Int { p.tiles.filter { roadLevel($0) != bestLevel }.count }
        func shortest(_ list: [RoadPlan]) -> RoadPlan? { list.min { toBuild($0) < toBuild($1) } }
        // a plan's city may be one razed since (still held by a lazy neighbour list): its centre tile is still where it was
        func coordOf(_ id: Int) -> HexCoord? { city(id)?.coord ?? destroyedCitySnapshots[id]?.coord }
        func span(_ p: RoadPlan) -> Int { coordOf(p.fromCity).flatMap { a in coordOf(p.toCity).map { a.distance(to: $0) } } ?? 0 }
        // Unciv: `planList.sortBy { ... }` - stable, and the whole point of the sort is to break the ties in
        // the minByOrNull that follows ("If there are multiple shortest distance road plans make minByOrNull
        // prioritize ones with closer cities"), so an unstable sort undoes exactly what it is for.
        let sorted = plans.enumerated().sorted { (span($0.element), $0.offset) < (span($1.element), $1.offset) }.map { $0.element }
        if bestLevel != 2 { return shortest(sorted) }
        // `roadStatus > None || roadIsPillaged`
        let existing = sorted.filter { p in p.tiles.allSatisfy { map[$0].map { $0.roads || $0.railroad || $0.roadPillaged } ?? false } }
        return existing.isEmpty ? shortest(sorted) : shortest(existing)
    }
    /// Unciv RoadBetweenCitiesAutomation.getNearbyCitiesToConnect: builds the road cache chooseImprovement reads
    func nearbyCitiesToConnect(_ unit: Unit) -> [City] {
        let wa = getWorkerAutomation(unit.civId)
        guard wa.bestRoadAvailable != nil else { return [] }
        // Cities that are too far away make the canReach() calculations devastatingly long
        return cities(of: unit.civId).filter { $0.coord.distance(to: unit.coord) < 20 && !roadsToBuild(from: $0, wa).isEmpty }
    }
    /// Unciv RoadBetweenCitiesAutomation.tryConnectingCities
    func tryConnectingCities(_ unitId: Int, _ candidates: [City]) -> Bool {
        guard let unit = unit(unitId) else { return false }
        let wa = getWorkerAutomation(unit.civId)
        guard let best = wa.bestRoadAvailable, !candidates.isEmpty else { return false }
        let start = unit.coord
        let bestLevel = roadLevel(name: best)
        // Search through ALL candidate cities for the closest tile to build a road on. Kotlin's sortedBy is
        // stable: two cities the same number of tiles away keep the order `candidates` handed us.
        for city in candidates.enumerated().sorted(by: { ($0.element.coord.distance(to: start), $0.offset) < ($1.element.coord.distance(to: start), $1.offset) }).map({ $0.element }) {
            var tiles: [(HexCoord, Double)] = []
            for plan in roadsToBuild(from: city, wa) { for c in plan.tiles where !isMarkedForCreatesOneImprovement(c) && roadLevel(c) < bestLevel { tiles.append((c, plan.priority)) } }
            // Unciv: `.sortedBy { it.first.aerialDistanceTo(unitStartingTile) - (it.second / 10f) }` - stable,
            // and in Float. Ties here are the rule, not the exception: every tile of one road plan shares a
            // priority, and distance is an integer.
            func key(_ e: (HexCoord, Double)) -> Double { f(Double(e.0.distance(to: start)) - f(f(e.1) / 10)) }
            tiles = tiles.enumerated().sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }.map { $0.element }
            guard let target = tiles.first(where: { e in start == e.0 || (canUnitEnter(unit, e.0) && canReach(unit, e.0)) })?.0 else { continue }   // Apparently we can't reach any of these tiles at all
            if ProcessInfo.processInfo.environment["ROAD_DBG"] != nil {
                let s0 = uncivPosition(start), t0 = uncivPosition(target)
                let top = tiles.prefix(5).map { e -> String in let p = uncivPosition(e.0); return "\(p.x),\(p.y)p\(e.1)" }.joined(separator: ",")
                let path = shortestPath(unit, to: target).map { c -> String in let p = uncivPosition(c); return "\(p.x),\(p.y)" }.joined(separator: ">")
                var roads: [String] = []
                for c in map.tilesWithin(start, radius: 3) {
                    guard let t = map[c], t.roads || t.railroad else { continue }
                    let p = uncivPosition(c); roads.append("\(p.x),\(p.y)=\(t.railroad ? "RR" : "R")\(t.roadPillaged ? "!" : "")")
                }
                print("ROADE t=\(turn) \(unit.name) from=\(s0.x),\(s0.y) city=\(city.name) cand=\(tiles.count) best=\(t0.x),\(t0.y) mp=\(unit.movementLeft) path=\(path) roads=[\(roads.sorted().joined(separator: " "))] top=\(top)")
            }
            if target != start, unit.hasMovement { _ = headTowards(unitId, target) }
            if ProcessInfo.processInfo.environment["ROAD_DBG"] != nil, let u = self.unit(unitId) {
                let p = uncivPosition(u.coord); print("ROADE2 t=\(turn) \(u.name) now=\(p.x),\(p.y) mp=\(u.movementLeft)")
            }
            if let u = self.unit(unitId), u.hasMovement, u.coord == target, map[target]?.improvementInProgress != best { startWorkingOnImprovement(at: target, best, unit: u) }
            return true
        }
        return false
    }
}
