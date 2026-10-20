// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's unit/SpecificUnitAutomation.kt.

extension GameState {
    // MARK: - SpecificUnitAutomation

    /// Unciv SpecificUnitAutomation.automateGreatGeneral (GreatGeneralImplementation.getBestAffectedTroopsTile)
    func automateGreatGeneral(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId), let t = bestAffectedTroopsTile(unit) else { return false }
        moveUnit(unitId, toward: t)
        return true
    }
    /// Unciv SpecificUnitAutomation.automateCitadelPlacer: steal territory back from civs that stole ours.
    func automateCitadelPlacer(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId), civ(unit.civId) != nil else { return false }
        if unit.def.hasStrengthBonusInRadius && units(of: unit.civId).filter({ $0.def.hasStrengthBonusInRadius }).count < 3 { return false }
        let thieves = knownCivs(unit.civId).filter { hasModifier(unit.civId, $0.id, .StealingTerritory) }
        let vis = visibleTiles(for: unit.civId)
        // The neighbour step duplicates most border tiles, so sortKey ties are the rule rather than the
        // exception and the walk order of City.tiles is what settles them. See uncivTileWalk.
        let candidates = thieves.flatMap { cities(of: $0.id) }.flatMap { uncivTileWalk($0) }
            .filter { t in map.neighbors(of: t).contains { map[$0]?.ownerCivId != unit.civId } }
            .flatMap { map.neighbors(of: $0) }
            .filter { c in vis.contains(c) && map.neighbors(of: c).contains { map[$0]?.ownerCivId == unit.civId } }
        // Unciv: distance minus the owner's worker base priority for owned tiles
        // Unciv SpecificUnitAutomation: the priority is taken through the *owner's* worker automation, so the
        // ownership bonuses apply and the resources are judged with the owner's technology - a citadel is placed
        // where it hurts them most, not where it would have suited us.
        // Kotlin roundToInt() is Math.round - floor(x + 0.5) - not Swift's half-away-from-zero `.rounded()`
        func sortKey(_ c: HexCoord) -> Int { c.distance(to: unit.coord) - ((map[c]?.ownerCivId).map { Stats.roundToInt(Double(basePriority(c, unit, asCiv: $0))) } ?? 0) }
        // Unciv does not dedup, and sortedBy is stable, so equal keys keep the order they arrived in.
        let sorted = candidates.enumerated().map { (offset: $0.offset, tile: $0.element, key: sortKey($0.element)) }
            .sorted { $0.key != $1.key ? $0.key < $1.key : $0.offset < $1.offset }.map { $0.tile }
        guard let target = sorted.first(where: { canReach(unit, $0) }) else { return false }
        moveUnit(unitId, toward: target)
        if let u = self.unit(unitId), u.coord == target, u.hasMovement, let a = greatPersonActions(u).first(where: { $0.1 == .improvement || $0.1 == .citadel }) { performGreatPersonAction(unitId: unitId, a.1) }
        return true
    }

    /// Unciv SpecificUnitAutomation.automateSettlerActions
    func automateSettlerActions(_ unitId: Int, dangerousTiles: Set<HexCoord>) {
        guard let unit = unit(unitId), let civ = civ(unit.civId) else { return }
        let myCities = cities(of: unit.civId)
        if civ.isCityState && myCities.isEmpty && canFoundCity(at: unit.coord, civId: unit.civId) && unit.hasMovement { _ = foundCity(with: unitId); return }
        let turns = turn - 1   // Unciv gameInfo.turns starts at 0
        let rangeToSearch: Int? = (myCities.isEmpty && turns < 4) ? max(1, 3 - turns) : nil
        let minimumTileValue = rs.constants.minimumCityLocationTileValue   // Unciv modOptions.constants.minimumCityLocationTileValue (53)
        var best = bestTilesToFoundCity(unit, distanceToSearch: rangeToSearch, minimumValue: minimumTileValue)
        var bestCityLocation: HexCoord? = nil
        if turns == 0 && myCities.isEmpty, best.tileRankMap[unit.coord] != nil {
            let settlers = units(of: unit.civId).filter { $0.hasMovement && $0.name == unit.name }
            let bestSettler = settlers.max { (best.tileRankMap[$0.coord] ?? -1) < (best.tileRankMap[$1.coord] ?? -1) }
            if bestSettler?.id == unit.id && unit.hasMovement && canFoundCity(at: unit.coord, civId: unit.civId) { _ = foundCity(with: unitId); return }
            if let bs = bestSettler {
                best.tileRankMap = best.tileRankMap.filter { $0.key.distance(to: bs.coord) > 4 }
                // Unciv `HashMap(map.filter { .. })`: rebuilt from the old walk, sized for its entries
                let kept = best.iterationOrder.filter { best.tileRankMap[$0] != nil }
                best.iterationOrder = JavaHash1Set.iterationOrder(kept, initialCapacity: Int(Float(kept.count) / 0.75 + 1))
            }
        }
        // The ranks are Floats in Unciv, and `bestTileRank - 2` is a Float subtraction
        if let here = best.tileRankMap[unit.coord], best.bestTile == nil || Float(here) >= Float(best.bestTileRank) - 2 { bestCityLocation = unit.coord }
        if bestCityLocation == nil, let bt = best.bestTile, let p = path(for: unit, to: bt), (1...3).contains(p.count) { bestCityLocation = bt }
        if bestCityLocation == nil {
            // Unciv `tileRankMap.entries.asSequence().filter { .. }.sortedByDescending { it.value }`: the HashMap's own
            // walk, which under identity hash 1 is the insertion walk of JavaHash1Set, then a stable sort.
            let candidates = best.iterationOrder.filter { best.tileRankMap[$0] != nil && (best.bestTile == nil || Float(best.tileRankMap[$0] ?? 0) >= Float(best.bestTileRank) - 5) }
                .enumerated().sorted { a, b in
                    let va = best.tileRankMap[a.element] ?? 0, vb = best.tileRankMap[b.element] ?? 0
                    return va != vb ? va > vb : a.offset < b.offset
                }.map { $0.element }
            for c in candidates {
                if dangerousTiles.contains(c) && c != unit.coord { continue }
                if let p = path(for: unit, to: c), (1...3).contains(p.count) { bestCityLocation = c; break }
            }
        }
        if bestCityLocation == nil, let bt = best.bestTile, let p = path(for: unit, to: bt), (1...8).contains(p.count) { bestCityLocation = bt }
        // The settler's whole decision in one line, for putting beside Unciv's: which tile it ranked best and
        // how high, what its own tile scores, how many candidates survived the minimum, and where it decided to
        // go. A settler that ends up two tiles from Unciv's has either a different best tile or a different path.
        if epochsDebug, epochsTraceUnit == "\(civ.nation)/\(unit.name)" {
            let b = best.bestTile.map { uncivPosition($0) }
            let t = bestCityLocation.map { uncivPosition($0) }
            let me = uncivPosition(unit.coord)
            print("TRACES t=\(uncivTurns) at=\(me.x),\(me.y) best=\(b.map { "\($0.x),\($0.y)" } ?? "-") rank=\(String(format: "%.2f", best.bestTileRank)) here=\(String(format: "%.2f", best.tileRankMap[unit.coord] ?? -1)) cands=\(best.tileRankMap.count) range=\(rangeToSearch.map(String.init) ?? "-") target=\(t.map { "\($0.x),\($0.y)" } ?? "-")")
        }
        guard let target = bestCityLocation else {
            if epochsDebug && turn % 10 == 0 { print("AIDBG settler t\(turn) \(civ.nation) at \(unit.coord) no target: best=\(String(describing: best.bestTile)) rank=\(Int(best.bestTileRank)) candidates=\(best.tileRankMap.count) range=\(String(describing: rangeToSearch)) cities=\(myCities.count)") }
            // All tiles within reach are taken: head for the frontier, explore, or wander.
            let frontierDistance = rs.constants.minimalCityDistance + 1
            func frontierScore(_ city: City) -> Int { city.coord.ring(radius: frontierDistance).filter { $0.distance(to: city.coord) == frontierDistance }.map { map.normalize($0) }.filter { map.contains($0) && canFoundCity(at: $0, civId: unit.civId) }.count }
            let trace = epochsDebug && epochsTraceUnit == "\(civ.nation)/\(unit.name)"
            if trace {
                let fc = myCities.max(by: { frontierScore($0) < frontierScore($1) })
                print("FRONTE t=\(uncivTurns) scores=\(myCities.map { "\($0.name):\(frontierScore($0))" }.joined(separator: ",")) city=\(fc?.name ?? "null") reach=\(fc.map { String(canReach(unit, $0.coord)) } ?? "null")")
            }
            if let frontier = myCities.max(by: { frontierScore($0) < frontierScore($1) }), frontierScore(frontier) > 0, canReach(unit, frontier.coord) { moveUnit(unitId, toward: frontier.coord) }
            if trace, let u = self.unit(unitId) { let p = uncivPosition(u.coord); print("FRONT2E t=\(uncivTurns) at=\(p.x),\(p.y) mv=\(Float(u.movementLeft))") }
            if tryExplore(unitId) { if trace, let u = self.unit(unitId) { let p = uncivPosition(u.coord); print("EXPLE t=\(uncivTurns) at=\(p.x),\(p.y)") }; return }
            wander(unitId, tilesToAvoid: dangerousTiles)
            return
        }
        // Unciv: no found-city action (no movement, or the target cannot be settled) -> do nothing this turn
        guard unit.hasMovement, canFoundCity(at: target, civId: unit.civId) else { return }
        if unit.coord == target { _ = foundCity(with: unitId); return }
        if tryRunAwayIfNecessary(unitId) { return }
        moveUnit(unitId, toward: target)
        if let u = self.unit(unitId), u.coord == target, u.hasMovement, canFoundCity(at: target, civId: unit.civId) { _ = foundCity(with: unitId) }
    }

    /// Unciv SpecificUnitAutomation.automateImprovementPlacer (great improvements)
    func automateImprovementPlacer(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId), let impName = unit.def.instantImprovement, let imp = rs.improvements[impName] else { return false }
        // Unciv `improvement.maxByOrNull { it.value }?.key ?: Stat.Culture`: Stats iterate their NON-ZERO values in
        // Stat order (Production, Food, Gold, Science, Culture, Happiness, Faith), first of equal values wins
        let relatedStat: String = ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith"].filter { imp.stats[$0] != 0 }
            .max { Float(imp.stats[$0]) < Float(imp.stats[$1]) } ?? "Culture"
        // Unciv: cities by statPercentBonusTree total for the related stat
        let boost = Dictionary(uniqueKeysWithValues: cities(of: unit.civId).map { ($0.id, currentCityStats($0.id).percentBonus[relatedStat]) })
        // Unciv `sortedByDescending` is STABLE: cities with the same percentage bonus keep `civ.cities` order.
        // Swift's `sorted(by:)` is not, and a tie here is the normal case - every city of an empire that has
        // no science buildings yet reads the same bonus - so the winner was whatever the sort happened to do.
        let citiesByBoost = cities(of: unit.civId).enumerated()
            .sorted { a, b in
                let x = boost[a.element.id]!, y = boost[b.element.id]!
                return x == y ? a.offset < b.offset : x > y
            }.map { $0.element }
        // Unciv `ruleset.terrains.values.asSequence().filter { Land }.map { rankStatsValue }.average()`: the Floats
        // summed as Doubles in the ruleset's order
        let landTerrains = rs.terrainOrder.compactMap { rs.terrains[$0] }.filter { $0.type == .land }
        let averageTerrain = landTerrains.isEmpty ? 0 : landTerrains.map { rankStatsValue($0.stats, civId: unit.civId) }.reduce(0, +) / Double(landTerrains.count)
        let enemyNearby = map.tilesWithin(unit.coord, radius: 5).flatMap { units(at: $0) }.contains { $0.isMilitary && areAtWar(unit.civId, $0.civId) }
        for city in citiesByBoost {
            // Unciv City.getWorkableTiles: `tilesInRange.asSequence().filter { it.getOwner() == civ }`, and tilesInRange
            // is `getTilesInDistance(workRange).toHashSet()` - its HashSet walk, which the stable rank sort keeps for ties
            let tilesInRange = JavaHash1Set.iterationOrder(map.tilesWithin(city.coord, radius: rs.constants.cityWorkRange))
            // Unciv's && chain in its order. The terrain question is canBuildImprovement's: an unbuildable top
            // feature (Forest, Jungle, Marsh) only takes a feature-removing great improvement once the civ knows
            // every matching Remove - we had tested terrainsCanBeBuiltOn by hand, and [Land] let every land tile in.
            let applicable = tilesInRange.filter { map[$0]?.ownerCivId == unit.civId }.filter { c in
                guard let t = map[c], t.isLand else { return false }
                if let res = t.resource, !(rs.resourceImprovements[res]?.contains(impName) ?? false) { return false }   // Unciv tileResource?.isImprovedBy(name) != false
                guard !t.isCityCenter, unit.coord == c || canUnitEnter(unit, c) else { return false }
                if let cur = t.improvement, rs.improvements[cur]?.isGreatImprovement == true { return false }
                guard canBuildImprovement(imp, on: t, civId: unit.civId, unit: unit) else { return false }   // Unciv improvementFunctions.canBuildImprovement(improvement, unit.cache.state)
                if imp.isGreatImprovement, let base = rs.terrains[t.baseTerrain], rankStatsValue(base.stats, civId: unit.civId) <= averageTerrain { return false }
                return true
            }
            if applicable.isEmpty { continue }
            guard let pathToCity = path(for: unit, to: city.coord) else { continue }
            if pathToCity.count > 2 && owningCity(unit.coord)?.id != city.id {
                if militaryUnitOn(unit.coord) == nil && enemyNearby { return true }   // Unciv `unit.getTile().militaryUnit == null`
                moveUnit(unitId, toward: city.coord); return true
            }
            // Unciv `applicableTiles.sortedByDescending { rankTile(it) }` - stable again, so tiles of equal
            // rank stay in getWorkableTiles order, which is the ring order the tiles were listed in.
            let chosen = applicable.enumerated()
                .sorted { a, b in
                    let x = rankTileAI(a.element, civId: unit.civId), y = rankTileAI(b.element, civId: unit.civId)
                    return x == y ? a.offset < b.offset : x > y
                }.map { $0.element }.first { canReach(unit, $0) }
            guard let target = chosen else { continue }
            if epochsDebug, epochsTraceUnit == "\(civ(unit.civId)?.nation ?? "")/\(unit.name)" {
                let u = uncivPosition(target), cu = uncivPosition(city.coord)
                let top = applicable.map { c -> (String, Double) in
                    let p = uncivPosition(c); return ("(\(p.x),\(p.y))", rankTileAI(c, civId: unit.civId))
                }.sorted { $0.1 > $1.1 }.prefix(6)
                print("GPPLACE t=\(turn) \(unit.name) at=\(uncivPosition(unit.coord).x),\(uncivPosition(unit.coord).y) city=\(city.name)(\(cu.x),\(cu.y)) boost=\(boost[city.id] ?? -1) target=\(u.x),\(u.y) pathToCity=\(pathToCity.count) | " + top.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
            }
            let before = unit.coord
            moveUnit(unitId, toward: target)
            guard let after = self.unit(unitId) else { return true }
            if after.coord == target {
                // Unciv: a pillaged tile gets the Repair action (only for units that build improvements), otherwise CreateImprovement
                if map[target].map({ $0.pillaged || $0.roadPillaged }) != true, let a = greatPersonActions(after).first(where: { $0.1 == .improvement || $0.1 == .citadel }) { performGreatPersonAction(unitId: unitId, a.1) }
                return true
            }
            return before != after.coord
        }
        return false
    }
    /// Unciv SpecificUnitAutomation.conductTradeMission
    func conductTradeMission(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId), let civ = civ(unit.civId) else { return false }
        if let a = greatPersonActions(unit).first(where: { $0.1 == .tradeMission }) { performGreatPersonAction(unitId: unitId, a.1); return true }
        // A city's tile ring holds several tiles at the same distance, so the walk order of City.tiles decides
        // which one the merchant heads for. See uncivTileWalk.
        let tiles = civs.filter { $0.id != unit.civId && !areAtWar(unit.civId, $0.id) && $0.isCityState }.compactMap { cities(of: $0.id).first }.flatMap { uncivTileWalk($0) }
            .filter { civ.explored.contains($0) }
            .enumerated().sorted { a, b in
                let da = a.element.distance(to: unit.coord), db = b.element.distance(to: unit.coord)
                return da != db ? da < db : a.offset < b.offset
            }.map { $0.element }
        guard let target = tiles.first(where: { c in canPassThrough(unit, c) && (path(for: unit, to: c).map { (1...10).contains($0.count) } ?? false) }) else { return false }
        let before = unit.coord
        moveUnit(unitId, toward: target)
        return self.unit(unitId)?.coord != before
    }
    /// Unciv SpecificUnitAutomation.speedupWonderConstruction
    func speedupWonderConstruction(_ unitId: Int) -> Bool {
        guard let unit = unit(unitId) else { return false }
        // Unciv getWonderThatWouldBenefitFromBeingSpedUp: turnsToConstruction(name) >= 5 - the city's production for
        // that wonder, after its overflow - and the most remaining work first, where the work already done on a
        // wonder that is not the current construction is the one parked in inProgressConstructions.
        func wonderToHurry(_ city: City) -> BuildingDef? {
            func remaining(_ b: BuildingDef) -> Int { productionCost(.building(b.name), for: city.civId) - (city.currentProduction == .building(b.name) ? Int(city.productionStored) : city.inProgressConstructions[b.name] ?? 0) }
            return buildableBuildings(for: city).filter { $0.isWonder && !$0.uniques.contains("Cannot be hurried") && (turnsToConstruction(.building($0.name), in: city) ?? Int.max) >= 5 }.max { remaining($0) < remaining($1) }
        }
        // Unciv getShortestPath: the unit's own tile is a path of one tile
        let candidates = cities(of: unit.civId).filter { $0.population >= 3 && (canUnitEnter(unit, $0.coord) || unit.coord == $0.coord) && wonderToHurry($0) != nil }
            .compactMap { c -> (City, Int)? in if c.coord == unit.coord { return (c, 1) }; guard let p = path(for: unit, to: c.coord), !p.isEmpty, p.count <= 5 else { return nil }; return (c, p.count) }
        guard let city = candidates.min(by: { $0.1 < $1.1 })?.0 else { return false }
        if unit.coord == city.coord {
            // Unciv `constructionQueue.add(0, wonderToHurry.name)`: on top of whatever is there - the same wonder too, so a
            // wonder already being built stands in the queue twice, and once it is finished its second entry follows it
            if let w = wonderToHurry(city), let ci = cityIndex(city.id) { if let cur = cities[ci].currentProduction { cities[ci].productionQueue.insert(cur, at: 0) }; cities[ci].currentProduction = .building(w.name) }
            if let a = greatPersonActions(unit).first(where: { $0.1 == .hurryProduction }) { performGreatPersonAction(unitId: unitId, a.1); return true }
            return false
        }
        let before = unit.coord
        moveUnit(unitId, toward: city.coord)
        return self.unit(unitId)?.coord != before
    }
    /// Unciv SpecificUnitAutomation.automateAddInCapital
    func automateAddInCapital(_ unitId: Int) {
        guard let unit = unit(unitId), let cap = capital(of: unit.civId) else { return }
        if canReach(unit, cap.coord) { moveUnit(unitId, toward: cap.coord) }
        // Unciv `if (unit.movement.canUnitSwapTo(capitalTile)) unit.movement.swapMoveToTile(capitalTile)`
        if let u = self.unit(unitId), canUnitSwapTo(u, cap.coord) { swapMoveToTile(unitId, cap.coord) }
        if let u = self.unit(unitId), u.coord == cap.coord, canAddSpaceshipPart(u) { addSpaceshipPart(unitId: unitId) }
    }
}
