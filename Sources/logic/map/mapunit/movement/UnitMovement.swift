// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv PathfindingCache: the last shortest path this unit computed, trusted for as long as the unit has neither
/// moved nor spent movement since the cache was last cleared - even if the world around it changed.
struct UnitPathfindingCache {
    var movement: Float = -1
    var tile: HexCoord? = nil
    var destination: HexCoord? = nil
    var path: [HexCoord] = []
}

extension GameState {
    /// Unciv UnitMovement.clearPathfindingCache → PathfindingCache.clear: remember the movement and the tile the unit
    /// has NOW; the cache is valid only while both stay the same. A unit that never had it cleared (new, upgraded,
    /// just loaded) has movement -1 and caches nothing.
    func clearPathfindingCache(_ unitId: Int) {
        guard let u = unit(unitId) else { pathfindingCache[unitId] = nil; return }
        pathfindingCache[unitId] = UnitPathfindingCache(movement: Float(u.movementLeft), tile: u.coord, destination: nil, path: [])
    }

    /// Unciv Tile.clearAllPathfindingCaches (a road pillaged): every living civ's units.
    func clearAllPathfindingCaches() {
        for u in units where civ(u.civId)?.isAlive == true { clearPathfindingCache(u.id) }
    }

    private func pathfindingCacheIsValid(_ u: Unit) -> Bool {
        guard let c = pathfindingCache[u.id] else { return false }
        // Unciv asks the live MapUnit; a Swift caller holding an older copy (or a what-if copy) must not use or fill it
        guard let live = unit(u.id), live.coord == u.coord, live.movementLeft == u.movementLeft, live.civId == u.civId else { return false }
        return c.movement == Float(u.movementLeft) && c.tile == u.coord
    }

    /// Unciv PathfindingCache.getShortestPathCache: never for a human civ.
    private func getShortestPathCache(_ u: Unit, _ destination: HexCoord) -> [HexCoord] {
        if civ(u.civId)?.isPlayer == true { return [] }
        if pathfindingCacheIsValid(u), pathfindingCache[u.id]?.destination == destination { return pathfindingCache[u.id]?.path ?? [] }
        return []
    }

    /// Unciv PathfindingCache.setShortestPathCache: stored only while the cache is valid.
    private func setShortestPathCache(_ u: Unit, _ destination: HexCoord, _ path: [HexCoord]) {
        if civ(u.civId)?.isPlayer == true { return }
        if pathfindingCacheIsValid(u) {
            pathfindingCache[u.id]?.path = path
            pathfindingCache[u.id]?.destination = destination
        }
    }

    /// Unciv UnitMovement.getMovementToTilesAtPosition
    func movementToTiles(_ unit: Unit, _ ctx: MoveContext, at position: HexCoord, movement unitMovement: Double, considerZOC: Bool = true, ignore: Set<HexCoord>? = nil, includeEscort: Bool = true, caches: inout MoveCaches) -> TurnPaths {
        var paths = TurnPaths()
        paths.set(position, parent: position, total: 0)
        // If I can't move my only option is to stay...
        if unitMovement == 0 || ctx.cannotMove { return paths }
        let escort = includeEscort && isEscorting(unit) ? otherEscortUnit(unit) : nil
        if let e = escort, e.movementLeft == 0 { return paths }
        let escortCtx = escort.map { moveContext(for: $0) }
        let usableMovement = escort.map { min(unitMovement, $0.movementLeft) } ?? unitMovement
        let explored = civ(unit.civId)?.explored ?? []
        let tileCount = map.tiles.count
        var tilesToCheck = [position]
        while !tilesToCheck.isEmpty {
            var updated: [HexCoord] = []
            for tileToCheck in tilesToCheck {
                let base = paths.nodes[tileToCheck]!.total
                let fromIndex = map.index(of: tileToCheck) ?? 0
                for neighbor in map.neighbors(of: tileToCheck) {
                    if let ig = ignore, ig.contains(neighbor) { continue }
                    var total: Double
                    if !explored.contains(neighbor) {
                        total = Double(Float(base) + 1)   // If we don't know then we just guess it to be 1. (Unciv Float birikimi)
                    } else {
                        let pass: Bool
                        if let p = caches.passThrough[neighbor] { pass = p } else { pass = canPassThrough(unit, neighbor); caches.passThrough[neighbor] = pass }
                        if !pass {
                            total = unitMovement   // Can't go here, but keep it so enemy units and cities stay reachable targets
                        } else {
                            let key = fromIndex * tileCount + (map.index(of: neighbor) ?? 0)
                            let cost: Double
                            if let k = caches.cost[key] { cost = k } else {
                                var value = movementCost(unit, ctx, from: tileToCheck, to: neighbor, considerZOC: considerZOC)
                                if let e = escort, let ec = escortCtx { value = max(value, movementCost(e, ec, from: tileToCheck, to: neighbor, considerZOC: considerZOC)) }
                                caches.cost[key] = value
                                cost = value
                            }
                            total = Double(Float(base) + Float(cost))   // Unciv: Float toplami
                        }
                    }
                    if let best = paths.nodes[neighbor], best.total <= total { continue }
                    // In Civ V you can always travel between adjacent tiles, even without enough movement points
                    // Unciv: `totalDistanceToTile < usableMovement - Constants.minimumMovementEpsilon`, all Float
                    if Float(total) < Float(usableMovement) - Float(GameState.minimumMovementEpsilon) { updated.append(neighbor) } else { total = usableMovement }
                    paths.set(neighbor, parent: tileToCheck, total: total)
                }
            }
            tilesToCheck = updated
        }
        return paths
    }

    /// Unciv UnitMovement.getDistanceToTiles
    func turnPaths(_ unit: Unit, considerZOC: Bool = true, includeEscort: Bool = true) -> TurnPaths {
        var caches = MoveCaches()
        return movementToTiles(unit, moveContext(for: unit), at: unit.coord, movement: unit.movementLeft, considerZOC: considerZOC, includeEscort: includeEscort, caches: &caches)
    }

    /// Unciv Civilization.passThroughImpassableUnlocked
    func passThroughImpassableUnlocked(_ civId: Int) -> Bool {
        guard let c = civ(civId) else { return false }
        return civUniques(civId).contains { $0.pattern == "Land units may cross [] tiles after the first [] is earned" && c.everEarnedUnits.contains($0.param(1)) }
    }

    /// Unciv UnitMovement.getShortestPath: the tile the unit stands on at the end of each turn, the destination last; empty when there is no way
    func shortestPath(_ unit: Unit, to destination: HexCoord, avoidDamagingTerrain: Bool = false) -> [HexCoord] {
        let ctx = moveContext(for: unit)
        if ctx.cannotMove { return [] }
        // Unciv: for an air unit the range decides, not a walked path
        if unit.def.isAir { return canFlyTo(unit, destination) ? [destination] : [] }
        // First try and find a path without damaging terrain
        if !avoidDamagingTerrain && unit.def.isLand && passThroughImpassableUnlocked(unit.civId) {
            let damageFree = shortestPath(unit, to: destination, avoidDamagingTerrain: true)
            if !damageFree.isEmpty { return damageFree }
        }
        guard let mover = self.civ(unit.civId) else { return [] }
        let explored = mover.explored
        // every explored tile around the destination is known to be impassable: no path exists
        if !map.neighbors(of: destination).contains(where: { !explored.contains($0) || canPassThrough(unit, $0) }) {
            setShortestPathCache(unit, destination, [])
            return []
        }
        // Unciv: a path cached since the unit last moved is returned as it was, whatever moved around it since
        let cachedPath = getShortestPathCache(unit, destination)
        if !cachedPath.isEmpty { return cachedPath }
        let current = unit.coord
        if current == destination {
            // edge case that's needed, so that workers will know that they can reach their own tile
            setShortestPathCache(unit, destination, [current])
            return [current]
        }
        var tilesToCheck = [current]
        var parents: [HexCoord: HexCoord] = [:]
        var visited: Set<HexCoord> = [current]
        var distance = 1
        let maxMove = maxMovement(of: unit)
        var caches = MoveCaches()
        var canMoveCache: [HexCoord: Bool] = [:]
        // Unciv `unit.isCivilian() && unit.isAutomated()`: MapUnit.automated is set by the Automate action and by the
        // ConnectRoad button (OverlayButtonData.kt:141), and cleared when the road is done (RoadToAutomation.kt:126-128)
        let automatedCivilian = unit.isCivilian && unit.isAutomated
        let isLandUnit = unit.def.isLand
        while true {
            var newTiles: [HexCoord] = []
            // By order of preference: 1. land tiles 2. aerial distance 3. not unfriendly city-states.
            // Unciv: `tilesToCheck.sortedWith(compareBy({!it.isLand}, {it.aerialDistanceTo(destination)},
            // ::isUnfriendlyCityState))` (no isLand key for a non-land unit). The third key asks the city-state's
            // `isRelationshipLevelLT(Friend)`, i.e. relationshipLevel(), whose Neutral/Afraid split computes
            // getTributeWillingness and with it every major's Force (cached for the turn) - only for the pairs Java's
            // TimSort compares whose first keys tie, so the sort is the JVM's own (kotlinSortedWith).
            func isUnfriendlyCityState(_ c: HexCoord) -> Int {
                // Unciv: `getDiplomacyManager(unit.civ)?.isRelationshipLevelLT(Friend) == true` - a city-state we
                // have not met has no diplomacy manager with us and counts as NOT unfriendly
                guard let o = self.map[c]?.ownerCivId, o != unit.civId, self.civ(o)?.isCityState == true, mover.metCivs.contains(o)
                else { return 0 }
                return self.relationshipLevel(o, unit.civId) < .friend ? 1 : 0
            }
            var keys: [(HexCoord) -> Int] = []
            if isLandUnit { keys.append { self.map[$0]?.isLand == true ? 0 : 1 } }
            keys.append { $0.distance(to: destination) }
            keys.append(isUnfriendlyCityState)
            let byPreference = kotlinSortedWith(tilesToCheck) { kotlinCompareBy($0, $1, keys) }
            for tileToCheck in byPreference {
                let reachable = distance == 1
                    ? movementToTiles(unit, ctx, at: current, movement: unit.movementLeft, considerZOC: true, caches: &caches)
                    : movementToTiles(unit, ctx, at: tileToCheck, movement: maxMove, considerZOC: false, ignore: visited, caches: &caches)
                for r in reachable.order {
                    if avoidDamagingTerrain && damageFromTerrain(unit, at: r) > 0 { continue }
                    // Avoid enemy territory if civilian and automated
                    if automatedCivilian, let o = map[r]?.ownerCivId, areAtWar(unit.civId, o) { continue }
                    if r == destination {
                        var path = [destination]
                        var intermediate = tileToCheck
                        while intermediate != current {
                            path.append(intermediate)
                            guard let p = parents[intermediate] else { break }
                            intermediate = p
                        }
                        let result = Array(path.reversed())
                        setShortestPathCache(unit, destination, result)
                        return result
                    }
                    if r == current || parents[r] != nil { continue }   // We cannot be faster than anything existing...
                    if explored.contains(r) {
                        let ok: Bool
                        if let k = canMoveCache[r] { ok = k } else { ok = canMoveTo(unit, r); canMoveCache[r] = ok }
                        if !ok { continue }   // an intermediary tile holding our unit, or an enemy unit or city
                    }
                    parents[r] = tileToCheck
                    newTiles.append(r)
                }
            }
            if newTiles.isEmpty { setShortestPathCache(unit, destination, []); return [] }   // there is NO PATH (eg blocked by enemy units)
            for t in newTiles { visited.insert(t) }
            // only the edgemost tiles need checking
            tilesToCheck = newTiles.filter { t in !map.neighbors(of: t).allSatisfy { visited.contains($0) } }
            distance += 1
        }
    }

    func path(for unit: Unit, to target: HexCoord) -> [HexCoord]? {
        let p = shortestPath(unit, to: target)
        return p.isEmpty ? nil : p
    }

    /// Unciv UnitMovement: an air unit reaches any tile it may land on within twice its range.
    func canFlyTo(_ unit: Unit, _ destination: HexCoord) -> Bool {
        guard unit.def.isAir, unit.movementLeft > 0 else { return false }
        return unit.coord.distance(to: destination) <= airRange(unit) * 2 && canMoveTo(unit, destination)
    }

    /// Unciv UnitMovement.canReachInCurrentTurn
    func canReachInCurrentTurn(_ unit: Unit, _ c: HexCoord) -> Bool {
        if unitCannotMove(unit) { return c == unit.coord }
        // Unciv canReachCommon: `aerialDistanceTo(destination) <= getMaxMovementForAirUnits()` - the range alone, no
        // canMoveTo and no movement check, so a bomber "reaches" an enemy worker's tile (BattleHelper values it 50)
        if unit.def.isAir { return unit.coord.distance(to: c) <= airRange(unit) * 2 }
        return turnPaths(unit).contains(c)
    }

    /// Unciv UnitMovement.getReachableTilesInCurrentTurn
    func reachableTilesInCurrentTurn(_ unit: Unit, includeEscort: Bool = true) -> [HexCoord] {
        if unitCannotMove(unit) { return [unit.coord] }
        if includeEscort && isEscorting(unit), let e = otherEscortUnit(unit) {
            let other = Set(reachableTilesInCurrentTurn(e, includeEscort: false))
            return turnPaths(unit).order.filter { other.contains($0) }
        }
        return turnPaths(unit).order
    }

    /// Unciv WorldMapTileUpdater's move highlight (Z-1) for a unit that is not an air unit: of getReachableTilesInCurrentTurn
    /// the tiles it canMoveTo, and every tile its civ has not explored (UnitMovement.isUnknownTileWeShouldAssumeToBePassable =
    /// `!unit.civ.hasExplored(tile)`) - reached on the path finder's estimate of 1 movement point, not on what is really
    /// there, so the highlight gives nothing hidden away. Its own tile is never one (canMoveTo is false there).
    func moveHighlightTiles(_ unit: Unit) -> Set<HexCoord> {
        guard unit.movementLeft > 0, !unit.def.isAir, let owner = civ(unit.civId) else { return [] }
        return Set(reachableTilesInCurrentTurn(unit).filter { $0 != unit.coord && (!owner.explored.contains($0) || canMoveTo(unit, $0)) })
    }

    // MARK: - moving

    /// Unciv MapUnit.useMovementPoints
    func useMovementPoints(_ unitId: Int, _ amount: Double) {
        guard let i = unitIndex(unitId) else { return }
        units[i].turnsFortified = 0
        units[i].movementLeft -= amount
        if units[i].movementLeft < 0 { units[i].movementLeft = 0 }
        if amount < 0 { let m = maxMovement(of: units[i]); if units[i].movementLeft > m { units[i].movementLeft = m } }
    }

    /// Unciv UnitMovement.getTileToMoveToThisTurn (nil stands for UnreachableDestinationException).
    /// `preparingParadrop` is Unciv's unit.isPreparingParadrop(): our Paradrop action lives on the controller, not the unit.
    func tileToMoveToThisTurn(_ unit: Unit, _ destination: HexCoord, preparingParadrop: Bool = false) -> HexCoord? {
        if unit.coord == destination { return destination }
        // If we can fly (or drop), head there directly - otherwise the normal-movement fallback below picks the tile
        if (unit.def.isAir || preparingParadrop) && canMoveTo(unit, destination) { return destination }
        let dist = turnPaths(unit)
        // If the tile is far away, build a path there and take the first step
        if !dist.contains(destination) {
            guard let first = shortestPath(unit, to: destination).first else { return nil }
            if !dist.contains(first) { return dist.order.min { $0.distance(to: destination) < $1.distance(to: destination) } }
            return first
        }
        if canMoveTo(unit, destination) { return destination }
        // Someone is blocking the path to the final tile...
        let around = map.neighbors(of: destination)
        if around.contains(unit.coord) { return unit.coord }
        return around.filter { dist.contains($0) && canMoveTo(unit, $0) }.min { dist.nodes[$0]!.total < dist.nodes[$1]!.total } ?? unit.coord
    }

    /// Unciv UnitMovement.headTowards: returns the tile reached
    @discardableResult
    func headTowards(_ unitId: Int, _ destination: HexCoord) -> HexCoord? {
        guard let u = unit(unitId) else { return nil }
        guard let step = tileToMoveToThisTurn(u, destination) else { return u.coord }
        moveToTile(unitId, step)
        return unit(unitId)?.coord
    }

    /// Automation entry point (Unciv headTowards). Returns whether the unit arrived.
    @discardableResult
    func moveUnit(_ unitId: Int, toward target: HexCoord) -> Bool {
        guard let u = unit(unitId) else { return false }
        if u.coord != target { headTowards(unitId, target) }
        return unit(unitId)?.coord == target
    }

    /// Unciv WorldMapHolder.moveUnitToTargetTile: move to this turn's tile towards the target, then keep a move order if not there yet
    @discardableResult
    func playerMove(_ unitId: Int, to target: HexCoord) -> Bool {
        guard let u = unit(unitId), let tileToMoveTo = tileToMoveToThisTurn(u, target) else { return false }
        let previous = u.coord
        moveToTile(unitId, tileToMoveTo)
        guard let i = unitIndex(unitId) else { return false }
        // sending a unit to a tile it can't even get nearer to is a dud
        if units[i].coord == previous { return false }
        switch units[i].order { case .explore, .moveTo: units[i].order = .none; default: break }
        if units[i].coord != target { units[i].order = .moveTo(target) }
        return units[i].coord == target
    }

    /// Unciv MapUnit.doAction for a unit with a move order
    func doMoveAction(_ unitId: Int) {
        guard let u = unit(unitId), case .moveTo(let destination) = u.order, u.hasMovement else { return }
        if isEscorting(u), let e = otherEscortUnit(u), !e.hasMovement { return }
        // stop on enemy in sight
        let enemyInWalkingDistance = turnPaths(u).order.contains { c in units(at: c).contains { $0.isMilitary && !$0.def.isAir && areAtWar(u.civId, $0.civId) } }
        if enemyInWalkingDistance {
            if let i = unitIndex(unitId) { units[i].order = .none }
            // `if (!(isExploring() || isAutomated())) return` - an automated unit goes on to its automation
            if let v = unit(unitId), v.isAutomated { automateUnitMoves(unitId) }
            return
        }
        let canReach = unitCannotMove(u) ? destination == u.coord : !shortestPath(u, to: destination).isEmpty
        if !canReach { if let i = unitIndex(unitId) { units[i].order = .none }; return }
        let start = u.coord
        let gotTo = headTowards(unitId, destination) ?? start
        guard let i = unitIndex(unitId) else { return }
        if gotTo == start {
            // pathway blocked? Are we still at the same spot as start of turn?
            if units[i].movementMemories.last?.coord == start { units[i].order = .none }
            return
        }
        if gotTo == destination { units[i].order = .none }
        // `if (hasMovement()) doAction()` - the whole doAction: arrived, an automated unit automates on
        if units[i].hasMovement { doAction(unitId, helper: AI(state: self, civId: units[i].civId)) }
    }

    /// Unciv UnitMovement.moveToTile
    func moveToTile(_ unitId: Int, _ destination: HexCoord, considerZOC: Bool = true, carryPayload: Bool = true) {
        guard let u = unit(unitId), destination != u.coord else { return }
        let escortId = isEscorting(u) ? otherEscortUnit(u)?.id : nil
        if u.def.isAir {   // air units move differently from all other units
            guard let i = unitIndex(unitId) else { return }
            if units[i].order != .automate { units[i].order = .none }
            let evFrom = units[i].coord
            units[i].coord = destination
            if GameState.evlogOn { evUnitMove(unitId, from: evFrom) }   // EVLOG: UNIT_MOVE (putInTile)
            units[i].isTransported = false   // it has left the carrier by own means
            updateTransportedState(unitIndex: i)
            moveThroughTile(unitId, destination)   // Unciv putInTile ends in moveThroughTile
            guard let j = unitIndex(unitId) else { return }
            units[j].movementLeft = 0
            units[j].mostRecentMoveType = "UnitTeleported"
            clearPathfindingCache(unitId)
            return
        }
        let ctx = moveContext(for: u)
        let dist = turnPaths(u, considerZOC: considerZOC)
        guard dist.contains(destination) else { return }
        var movableTiles: [HexCoord] = []
        for t in dist.path(to: destination) { guard canPassThrough(u, t) else { break }; movableTiles.append(t) }
        guard let lastReachable = movableTiles.last(where: { canMoveTo(u, $0) }) else { return }
        let pathToLastReachable = dist.path(to: lastReachable)
        guard let i0 = unitIndex(unitId) else { return }
        units[i0].mostRecentMoveType = "UnitMoved"
        // un-fortify / un-setup / un-sleep after moving
        if [UnitOrder.fortify, .fortifyUntilHealed, .guardPost, .sleep, .sleepUntilHealed].contains(units[i0].order) { units[i0].order = .none }
        units[i0].isSetUp = false
        let origin = u.coord
        var needToFindNewRoute = false
        var previous = origin
        var passingMovementSpent = 0.0   // Movement points spent since the last tile we could end our turn on
        for tile in pathToLastReachable {
            guard let cur = unit(unitId) else { break }
            if !canPassThrough(cur, tile) { needToFindNewRoute = true; break }   // something made our path invalid
            if !settings.godMode { passingMovementSpent = Stats.f32(passingMovementSpent + Stats.f32(movementCost(cur, ctx, from: previous, to: tile))) }
            if canMoveTo(cur, tile, assumeCanPassThrough: true) {
                useMovementPoints(unitId, passingMovementSpent)
                if let i = unitIndex(unitId) { let evFrom = units[i].coord; units[i].coord = tile; if GameState.evlogOn { evUnitMove(unitId, from: evFrom) } }   // EVLOG: UNIT_MOVE, one putInTile per step
                moveThroughTile(unitId, tile)
                if let e = escortId {
                    moveToTile(e, tile)
                    startEscorting(unitId: unitId)   // Need to re-apply this
                }
                passingMovementSpent = 0
            }
            previous = tile
            // We can't continue, stop here.
            guard let now = unit(unitId) else { break }
            if Float(now.movementLeft) - Float(passingMovementSpent) < Float(GameState.minimumMovementEpsilon) { break }
        }
        if let i = unitIndex(unitId), Float(units[i].movementLeft) < Float(GameState.minimumMovementEpsilon) { units[i].movementLeft = 0 }
        // bring along the payloads
        // Unciv: `origin.getUnits().filter { it.isTransported && unit.canTransport(it) }.toList()`, built AFTER the carrier
        // moved (canTransport's capacity is counted on the carrier's tile now) and before any payload moves. Each payload
        // walks the WHOLE pathToLastReachableTile up to finalTileReached - the pass-through tiles too, where the carrier
        // itself never ran moveThroughTile - and then putInTile(finalTileReached) runs moveThroughTile once more. A carrier
        // that got nowhere still walks its payload down the path (the loop never meets finalTileReached) and back.
        if carryPayload, let carrier = unit(unitId) {
            let final = carrier.coord   // finalTileReached
            let payload = units(at: origin).filter { $0.isTransported && canTransport(carrier, $0) }.map { $0.id }
            for pid in payload {
                let evFrom = unit(pid)?.coord   // EVLOG: the payload's one putInTile(finalTileReached), from where it started
                for tile in pathToLastReachable {
                    guard let pi = unitIndex(pid) else { break }
                    units[pi].coord = tile
                    moveThroughTile(pid, tile, putInTile: false)   // Unciv payload.moveThroughTile(tile): no updateUniques
                    if tile == final { break }   // this is the final tile the transport reached
                }
                guard unitIndex(pid) != nil else { continue }
                putPayloadInTile(pid, final, evFrom: evFrom)
                if let pi = unitIndex(pid) {
                    units[pi].isTransported = true   // restore the flag to not leave the payload in the city
                    units[pi].mostRecentMoveType = "UnitMoved"
                }
            }
        }
        // Unciv UnitMovement.moveToTile, right after the payloads and before the new-route retry: "Unit
        // maintenance changed". A garrisoned land unit costs nothing under "Units in cities cost no
        // Maintenance", so stepping into or out of a city centre changes the empire's gold that instant.
        if let now = unit(unitId), now.isMilitary, now.def.isLand,
           map[origin]?.isCityCenter == true || map[now.coord]?.isCityCenter == true,
           civUniques(u.civId).contains(where: { $0.pattern == "Units in cities cost no Maintenance" }) {
            updateStatsForNextTurn(u.civId)
        }
        // Unciv moveToTile updates no civ-wide view itself: each tile entered ran putInTile's updateVisibleTiles,
        // which stores the civ's view only when the unit's own view changed past ourTilesAndNeighboringTiles
        if needToFindNewRoute, let now = unit(unitId), now.coord != origin { moveToTile(unitId, destination, considerZOC: considerZOC, carryPayload: carryPayload) }
        // Unciv: `if (unit.currentTile != origin) { clearPathfindingCache(); getOtherEscortUnit()?.clearPathfindingCache() }`
        if let now = unit(unitId), now.coord != origin {
            clearPathfindingCache(unitId)
            if let e = otherEscortUnit(now) { clearPathfindingCache(e.id) }
        }
        updateUnitUniquesCache(unitId)   // Unciv moveToTile ends in `unit.updateUniques()`
    }

    /// Unciv MapUnit.isTransportTypeOf: only air units, and only those matching a "Can carry [n] [filter] units" filter
    func isTransportTypeOf(_ carrier: Unit, _ p: Unit) -> Bool {
        guard p.def.isAir else { return false }
        return unitMatchingUniques(carrier, "Can carry [] [] units").contains { unitMatches(p, $0.param(1)) }
    }

    /// Unciv MapUnit.canTransport: same owner, isTransportTypeOf, not "Cannot be carried by [filter]" (cannotCarry), and
    /// checkCarryCapacity > 0 - counted against `currentTile.airUnits.filter { it.isTransported }`, the carrier's tile as it
    /// is NOW, with the unit itself among them when it is there.
    func canTransport(_ carrier: Unit, _ p: Unit) -> Bool {
        if carrier.civId != p.civId { return false }
        if !isTransportTypeOf(carrier, p) { return false }
        if unitMatchingUniques(p, "Cannot be carried by [] units").contains(where: { unitMatches(carrier, $0.param(0)) }) { return false }
        let carried = units(at: carrier.coord).filter { $0.def.isAir && $0.isTransported }
        return carrierAvailableCapacity(carrier, for: p, carried: carried) > 0
    }

    /// Unciv MapUnit.putInTile for a carried air unit: onto the tile, the transported flag recomputed (carried outside a
    /// city; in one only while the city's untransported air units exceed getMaxAirUnits - and the unit, still flagged as
    /// transported, is not one of them), then moveThroughTile. Callers restore `isTransported = true` afterwards.
    func putPayloadInTile(_ pid: Int, _ c: HexCoord, evFrom: HexCoord?) {
        guard let pi = unitIndex(pid) else { return }
        units[pi].coord = c
        if GameState.evlogOn, let evFrom { evUnitMove(pid, from: evFrom) }   // EVLOG: UNIT_MOVE (putInTile)
        if let city = city(at: c) {
            units[pi].isTransported = units.filter { $0.coord == c && $0.def.isAir && !$0.isTransported }.count > maxAirUnits(city)
        } else {
            units[pi].isTransported = true
        }
        moveThroughTile(pid, c)
    }

    /// Unciv MapUnit.moveThroughTile: TriggerUponEnteringTile first (so camps and ruins can trigger), then the tile's
    /// effects (encampment, ruins, capture, terrain promotions), and LAST `updateVisibleTiles(true)` - what the unit
    /// sees from here, and through the civ's viewable tiles the natural wonders in sight. We revealed before the
    /// camp and the ruins.
    /// `putInTile` (true for every caller but a payload following its carrier's path, which Unciv walks with the bare
    /// moveThroughTile) adds what Unciv's putInTile does after it: `cache.updateUniques()`.
    func moveThroughTile(_ unitId: Int, _ c: HexCoord, putInTile: Bool = true) {
        if let mu = unit(unitId), let t = map[c] {
            triggerUnitConditionalUniques(unit: mu) { $0.pattern == "upon entering a [] tile" && self.tileMatches(t, $0.param(0), civId: mu.civId) }
        }
        unitViewFrozen.insert(unitId)
        onUnitArrived(unitId: unitId)
        unitViewFrozen.remove(unitId); visGen &+= 1   // a view computed in the window is stale from here on
        guard unit(unitId) != nil else { return }
        // Unciv updateVisibleTiles → (only when the civ-wide view has to change) civ.cache.updateViewableTiles →
        // discoverNaturalWonders: revealFromCurrentTile makes the same call, and updateExploration ends in the
        // discovery. Ours discovered here on every tile, with the unit as the trigger's context, which Unciv's
        // `GameContext(civInfo, tile = tile)` does not have.
        revealFromCurrentTile(unitId, explorer: unit(unitId)?.coord)   // `updateVisibleTiles(true, currentTile.position)`
        if putInTile { updateUnitUniquesCache(unitId) }   // Unciv putInTile: `moveThroughTile(tile); cache.updateUniques()`
    }

    /// Unciv MapUnit.assignOwner: the unit leaves the old owner's list and is APPENDED to the new one, so it
    /// is the last of that civilization's units to move. Ours changed `civId` in place and left the unit where
    /// it had always been in the global array, which is the order `units(of:)` reports. Unit priority breaks
    /// ties by that order, and the tie decides which of two workers claims a tile first.
    func moveUnitToEndOfList(_ unitId: Int) {
        guard let i = unitIndex(unitId) else { return }
        let u = units.remove(at: i)
        rotateCivUnitsToNextDue(u.civId)   // UnitManager.addUnit: the new owner's list, without the unit, starts at nextPotentiallyDueAt
        units.append(u)
    }

    // MARK: - swapping

    /// Unciv UnitMovement.canUnitSwapTo
    func canUnitSwapTo(_ unit: Unit, _ destination: HexCoord) -> Bool {
        canReachInCurrentTurn(unit, destination) && canUnitSwapToReachableTile(unit, destination)
    }

    private func canUnitSwapToReachableTile(_ unit: Unit, _ tile: HexCoord, checkEscorted: Bool = true) -> Bool {
        if unit.def.isAir || tile == unit.coord || unitCannotMove(unit) || !unit.hasMovement { return false }
        let escorted = checkEscorted && isEscorting(unit) ? otherEscortUnit(unit) : nil
        let here = units(at: tile).filter { !$0.def.isAir }
        func match(_ x: Unit) -> Unit? { here.first { $0.isCivilian == x.isCivilian } }
        guard let other = match(unit) ?? escorted.flatMap({ match($0) }) else { return false }
        if other.civId != unit.civId || unitCannotMove(other) || !other.hasMovement || !canReachInCurrentTurn(other, unit.coord) { return false }
        if !canMoveTo(unit, tile, allowSwap: true) { return false }
        if !canMoveTo(other, unit.coord, allowSwap: true) { return false }
        guard let e = escorted else { return true }
        // Check whether the escorted unit can move OR swap too
        if canMoveTo(e, tile, allowSwap: false, includeEscort: false) { return true }
        return canUnitSwapToReachableTile(e, tile, checkEscorted: false)
    }

    func canSwap(_ a: Unit, with b: Unit) -> Bool { a.id != b.id && a.civId == b.civId && canUnitSwapTo(a, b.coord) }

    func swapUnits(_ aId: Int, _ bId: Int) {
        guard let a = unit(aId), let b = unit(bId), canSwap(a, with: b) else { return }
        swapMoveToTile(aId, b.coord)
    }

    func stopEscortingPair(_ unitId: Int) { stopEscorting(unitId: unitId) }   // Unciv MapUnit.stopEscorting

    /// Unciv UnitMovement.swapMoveToTile(keepEscorting = true), as the map's swap button calls it: an escorting unit takes
    /// its partner along (swapMoveEscortPair) - each swaps or simply moves, then the escorts start again.
    func swapMoveToTileKeepingEscort(_ unitId: Int, _ destination: HexCoord) {
        guard let u = unit(unitId), isEscorting(u), let escorted = otherEscortUnit(u) else { swapMoveToTile(unitId, destination); return }
        let destinationWasEscorting = units(at: destination).first { !$0.def.isAir && !$0.isCivilian && isEscorting($0) }?.id
        stopEscortingPair(unitId)
        for id in [unitId, escorted.id] {
            guard let x = unit(id) else { continue }
            let needsSwap = units(at: destination).contains { !$0.def.isAir && $0.isCivilian == x.isCivilian && $0.id != x.id }
            if needsSwap { swapMoveToTile(id, destination) } else { moveToTile(id, destination) }
        }
        startEscorting(unitId: unitId)
        if let d = destinationWasEscorting { startEscorting(unitId: d) }
    }

    /// Unciv UnitMovement.swapMoveToTile: each unit moves (and pays) with the other lifted off its tile
    func swapMoveToTile(_ unitId: Int, _ destination: HexCoord) {
        guard let u = unit(unitId) else { return }
        stopEscortingPair(unitId)
        guard let other = units(at: destination).first(where: { !$0.def.isAir && $0.isCivilian == u.isCivilian && $0.id != unitId }) else { return }
        stopEscortingPair(other.id)
        let ourOld = u.coord, theirOld = other.coord
        // Unciv: `ourOldPosition.getUnits().filter { it.isTransported && unit.isTransportTypeOf(it) }`, and theirs likewise
        let ourPayload = units(at: ourOld).filter { $0.isTransported && isTransportTypeOf(u, $0) }.map { $0.id }
        let theirPayload = units(at: theirOld).filter { $0.isTransported && isTransportTypeOf(other, $0) }.map { $0.id }
        let lifted = HexCoord(-100_000, -100_000)
        func place(_ ids: [Int], _ c: HexCoord) { for id in ids { if let i = unitIndex(id) { units[i].coord = c } } }
        // Unciv `payload.putInTile(tile); payload.isTransported = true` - putInTile ends in moveThroughTile
        func putPayloadsIn(_ ids: [Int], _ c: HexCoord) {
            for id in ids {
                putPayloadInTile(id, c, evFrom: nil)
                if let i = unitIndex(id) { units[i].isTransported = true }   // restore the flag to not leave the payload in the city
            }
        }
        place([other.id] + theirPayload, lifted)            // Step 1: release the destination tile
        moveToTile(unitId, destination)                     // Step 2: perform the movement - moveToTile carries our payload along
        place([unitId] + ourPayload, lifted)                // Step 3: release the newly taken tile
        place([other.id], theirOld)                         // Step 4: restore the initial position after step 1
        updateUnitUniquesCache(other.id)                    // putInTile → cache.updateUniques
        putPayloadsIn(theirPayload, theirOld)
        moveToTile(other.id, ourOld)                        // Step 5: perform the other movement, carrying its payload
        place([unitId], theirOld)                           // Step 6: restore the position in the new tile after step 3
        updateUnitUniquesCache(unitId)                      // putInTile → cache.updateUniques
        putPayloadsIn(ourPayload, theirOld)
        for id in [unitId, other.id] { if let i = unitIndex(id) { units[i].mostRecentMoveType = "UnitMoved" } }
        // steps 4 and 6 put each unit back on the tile it already saw from: their updateVisibleTiles find the view
        // unchanged and store no civ view (MapUnit.kt:842), and swapMoveToTile has no update of its own
        clearPathfindingCache(unitId)
        if let now = unit(unitId), let e = otherEscortUnit(now) { clearPathfindingCache(e.id) }
    }

    // MARK: - displacement

    /// Unciv UnitMovement.getPathBetweenTiles: BFS over tiles the unit can pass through, ignoring borders
    private func pathBetweenTiles(_ unit: Unit, from: HexCoord, to: HexCoord) -> Bool {
        var seen: Set<HexCoord> = [from]
        var queue = [from]
        var head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            if cur == to { return true }
            for n in map.neighbors(of: cur) where !seen.contains(n) && canPassThrough(unit, n, ignoreBorders: true) { seen.insert(n); queue.append(n) }
        }
        return false
    }

    /// Unciv UnitMovement.teleportToClosestMoveableTile: displaces the unit without spending movement. CAN DESTROY THE UNIT.
    func teleportToClosestMoveableTile(_ unitId: Int) {
        guard unit(unitId) != nil else { return }
        stopEscortingPair(unitId)
        guard let u = unit(unitId) else { return }   // read after stopEscorting: no escort takes part in what follows
        if u.isTransported { return }   // Unciv: a transported unit moves with its carrier, never on its own
        // This unit can stay here - e.g. it has "May enter foreign tiles without open borders"
        if canPassThrough(u, u.coord) && !(city(at: u.coord).map { $0.civId != u.civId && !$0.hasJustBeenConquered } ?? false) { return }   // !isCityCenterCannotEnter
        var allowed: HexCoord? = nil
        var distance = 0
        while allowed == nil && distance < 5 {
            distance += 1
            // Unciv getTilesAtDistance sirasi: guneyden baslayan halka, her karo aynasiyla esli.
            // .first{} ile ilk uygun karo secildigi icin sira sonucun parcasi.
            allowed = map.tilesInDistanceUncivOrder(u.coord, radius: distance).filter { $0.distance(to: u.coord) == distance }
                .filter { c in canMoveTo(u, c) && !(map[c]?.ownerCivId.map { areAtWar($0, u.civId) } ?? false) }
                .first { c in pathBetweenTiles(u, from: u.coord, to: c) }
        }
        // No tile within 4 spaces? move him to a city.
        // Unciv `civ.cities.flatMap { it.getTiles() }.sortedBy { aerialDistance }`: each city's HashSet walk, in
        // city order, then a stable sort. `City.tiles` is a Swift Set here, so it has to be walked Unciv's way.
        if allowed == nil {
            allowed = cities(of: u.civId).flatMap { uncivTileWalk($0) }.enumerated()
                .sorted { ($0.element.distance(to: u.coord), $0.offset) < ($1.element.distance(to: u.coord), $1.offset) }   // Kotlin sortedBy kararlidir
                .map { $0.element }.first { canMoveTo(u, $0) }
        }
        guard let destination = allowed, let i = unitIndex(unitId) else {
            if allowed == nil { destroyUnit(unitId) }   // no close tile and every city is full: Unciv `unit.destroy()`
            return
        }
        let origin = units[i].coord
        // Unciv: removeFromTile + putInTile(allowedTile) - and putInTile ends in moveThroughTile, so the unit sees
        // from where it lands (Greece's settler pushed off the tile Orleans was founded on saw the sites it then
        // settled toward) - and only THEN are sleep, fortification and guard cancelled and the move type set.
        units[i].coord = destination
        if GameState.evlogOn { evUnitMove(unitId, from: origin) }   // EVLOG: UNIT_MOVE (removeFromTile + putInTile)
        moveThroughTile(unitId, destination)
        guard let k = unitIndex(unitId) else { return }
        if [UnitOrder.sleep, .sleepUntilHealed, .fortify, .fortifyUntilHealed, .guardPost].contains(units[k].order) { units[k].order = .none }
        units[k].mostRecentMoveType = "UnitTeleported"
        // teleportTransportedUnitsTo(origin, allowedTile): each payload is put in the tile too
        if carrierCapacity(u) > 0 {
            for p in units where p.coord == origin && p.def.isAir && p.isTransported && p.civId == u.civId && canBeCarried(p, by: u) {
                guard let pj = unitIndex(p.id) else { continue }
                let evFrom = units[pj].coord
                units[pj].coord = destination
                if GameState.evlogOn { evUnitMove(p.id, from: evFrom) }   // EVLOG: UNIT_MOVE (payload putInTile)
                moveThroughTile(p.id, destination)
                if let pk = unitIndex(p.id) { units[pk].isTransported = true; units[pk].mostRecentMoveType = "UnitTeleported" }
            }
        }
    }
}

/// Tiny binary min-heap keyed by path cost.
struct MinHeap {
    private var items: [(HexCoord, Double)] = []
    mutating func push(_ c: HexCoord, _ k: Double) {
        items.append((c, k))
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if items[p].1 <= items[i].1 { break }
            items.swapAt(p, i); i = p
        }
    }
    mutating func pop() -> (HexCoord, Double)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && items[l].1 < items[m].1 { m = l }
                if r < items.count && items[r].1 < items[m].1 { m = r }
                if m == i { break }
                items.swapAt(m, i); i = m
            }
        }
        return top
    }
}
