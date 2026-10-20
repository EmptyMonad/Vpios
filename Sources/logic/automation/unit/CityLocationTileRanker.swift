// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's unit/CityLocationTileRanker.kt.
//
// Every rank there is a Float, built one `+=` at a time, compared with the others (stable sorts, the minimum
// value, `bestTileRank - 2`) and averaged into the prior for unexplored tiles. So the arithmetic below is Float
// too; the ranks are handed out as Doubles holding those Floats exactly.

extension GameState {
    /// `iterationOrder` is the walk of Unciv's `HashMap<Tile, Float>` under identity hash 1 (see JavaHash1Set).
    struct BestTilesToFoundCity { var tileRankMap: [HexCoord: Double] = [:]; var iterationOrder: [HexCoord] = []; var bestTile: HexCoord? = nil; var bestTileRank: Double = 0 }
    /// Unciv CityLocationTileRanker.getBestTilesToFoundCity
    func bestTilesToFoundCity(_ unit: Unit, distanceToSearch: Int?, minimumValue: Double) -> BestTilesToFoundCity {
        guard let civ = civ(unit.civId) else { return BestTilesToFoundCity() }
        let distanceModifier: Float = 3 // percentage penalty per aerial distance from unit (Settler)
        let range: Int
        if let d = distanceToSearch { range = d } else {
            let fromHome = cities(of: unit.civId).map { $0.coord.distance(to: unit.coord) }.min() ?? 0
            range = min(5, max(1, 8 - fromHome)) // Restrict vision when far from home to avoid death marches
        }
        // Unciv `gameInfo.getCities()`: civilization by civilization, each in its own order
        let nearbyCities = civs.flatMap { cities(of: $0.id) }.filter { $0.coord.distance(to: unit.coord) <= 7 + range }
        // Unciv: only tiles where a FoundCity / FoundPuppetCity unique of the unit has its conditionals met
        let foundUniques = unit.promotionUniques.filter { $0.pattern == "Founds a new city" || $0.pattern == "Founds a new puppet city" }
        let possible = map.tilesWithin(unit.coord, radius: range)
            .filter { c in foundUniques.isEmpty || map[c].map { t in foundUniques.contains { conditionalsHold($0, UniqueContext(civId: unit.civId, unit: unit, tile: t)) } } == true }
            .filter { civ.explored.contains($0) }
            .filter { canSettleTile($0, civId: unit.civId, nearbyCities: nearbyCities) && (unit.coord == $0 || canMoveTo(unit, $0)) }
        var result = BestTilesToFoundCity()
        var base = BaseTileMap()   // Unciv: a fresh map per call

        // Assume unexplored tiles are worth the average of the explored tiles around us
        var throwaway: Set<String> = []
        // onCoast doesn't matter here, it does not change baseTileMap
        for c in map.tilesWithin(unit.coord, radius: range + 2) where civ.explored.contains(c) {
            _ = rankTileForSettling(c, civId: unit.civId, onCoast: false, newLuxuries: &throwaway, base: &base, unexploredPrior: 0)
        }
        // Unciv `baseTileMap.values.average().toFloat()`: the HashMap's own walk, each Float widened and summed as a Double
        var unexploredPrior: Float = 0
        if !base.values.isEmpty {
            let walk = JavaHash1Set.iterationOrder(base.order)
            var sum = 0.0
            for c in walk { sum += Double(base.values[c]!) }
            unexploredPrior = Float(sum / Double(walk.count))
        }

        var ranked: [(tile: HexCoord, value: Float)] = []
        for c in possible {
            var value = rankTileToSettle(c, civId: unit.civId, nearbyCities: nearbyCities, base: &base, unexploredPrior: unexploredPrior)
            let distanceScore = min(99, max(0, Float(unit.coord.distance(to: c)) * distanceModifier))
            value *= (100 - distanceScore) / 100
            if value >= Float(minimumValue) { result.tileRankMap[c] = Double(value); ranked.append((c, value)) }
        }
        result.iterationOrder = JavaHash1Set.iterationOrder(ranked.map { $0.tile })   // HashMap() filled in getTilesInDistance order
        // Unciv `sortedByDescending { it.second }` is stable: equal ranks keep getTilesInDistance order
        ranked = ranked.enumerated().sorted { a, b in a.element.value != b.element.value ? a.element.value > b.element.value : a.offset < b.offset }.map { $0.element }
        if epochsDebug && ranked.isEmpty && turn % 10 == 0 {
            let inRange = map.tilesWithin(unit.coord, radius: range)
            let explored = inRange.filter { civ.explored.contains($0) }
            let settleable = explored.filter { canSettleTile($0, civId: unit.civId, nearbyCities: nearbyCities) }
            let enterable = settleable.filter { unit.coord == $0 || canUnitEnter(unit, $0) }
            let maxV = possible.map { c -> Float in var m = base; return rankTileToSettle(c, civId: unit.civId, nearbyCities: nearbyCities, base: &m, unexploredPrior: unexploredPrior) }.max() ?? -1
            var reasons: [String: Int] = [:]
            for c in inRange {
                guard let t = map[c] else { reasons["nil", default: 0] += 1; continue }
                if !t.isLand { reasons["water", default: 0] += 1; continue }
                if t.isImpassable { reasons["impassable", default: 0] += 1; continue }
                if let o = t.ownerCivId, o != unit.civId { reasons["foreign", default: 0] += 1; continue }
                if nearbyCities.contains(where: { $0.coord.distance(to: c) <= 3 }) { reasons["nearCity", default: 0] += 1; continue }
                if nearbyCities.contains(where: { $0.coord.distance(to: c) <= 6 && hasFlag($0.civId, unit.civId, "AgreedToNotSettleNearUs") }) { reasons["flag", default: 0] += 1; continue }
                reasons["ok", default: 0] += 1
            }
            print("AIDBG settlerReasons \(reasons) nearby=\(nearbyCities.count) unitAt=\(unit.coord)")
            print("AIDBG settlerRank \(civ.nation) range=\(range) inRange=\(inRange.count) explored=\(explored.count) settleable=\(settleable.count) enterable=\(enterable.count) possible=\(possible.count) maxValue=\(Int(maxV)) baseAvg=\(Int(unexploredPrior))")
        }
        if let best = ranked.first(where: { canReach(unit, $0.tile) }) { result.bestTile = best.tile; result.bestTileRank = Double(best.value) }
        return result
    }

    /// Unciv's `baseTileMap: HashMap<Tile, Float>`, with the order entries went in (its walk is JavaHash1Set's over that)
    private struct BaseTileMap { var values: [HexCoord: Float] = [:]; var order: [HexCoord] = [] }

    private func canSettleTile(_ c: HexCoord, civId: Int, nearbyCities: [City]) -> Bool {
        guard let t = map[c], t.isLand, !t.isImpassable, let civ = civ(civId) else { return false }
        if let o = t.ownerCivId, o != civId { return false }
        let continent = continentId(of: c)
        for city in nearbyCities {
            let d = city.coord.distance(to: c)
            // AgreedToNotSettleNearUs is hardcoded for now: the CITY OWNER knows the UNIT OWNER agreed not to settle near them
            if d <= 6 && civ.metCivs.contains(city.civId) && !areAtWar(civId, city.civId) && hasFlag(city.civId, civId, "AgreedToNotSettleNearUs") { return false }
            if d <= (continentId(of: city.coord) == continent ? rs.constants.minimalCityDistance : rs.constants.minimalCityDistanceOnDifferentContinents) { return false }
        }
        return true
    }
    private func rankTileToSettle(_ c: HexCoord, civId: Int, nearbyCities: [City], base: inout BaseTileMap, unexploredPrior: Float) -> Float {
        guard let t = map[c] else { return 0 }
        var value: Float = 0
        value += distanceToCityModifier(c, nearbyCities: nearbyCities, civId: civId)
        // Unciv Tile.isAdjacentToCoast(): a land tile with a neighbour whose base terrain is coast (a lazy, see GameMap)
        let onCoast = map.isAdjacentToCoast(c)
        let onHill = t.isHill
        let nextToMountain = map.neighbors(of: c).contains { map[$0]?.isMountain == true }
        // Unciv `getTerrainMatchingUniques(RestrictedBuildableImprovements).any { it.params[0] == "All Road" }` over all
        // the tile's terrains - the Oasis in this ruleset, by its unique rather than its name
        let unImprovable = (t.terrainNames + (t.naturalWonder.map { [$0] } ?? [])).compactMap { rs.terrains[$0] }.flatMap { $0.uniqueObjects }
            .contains { $0.pattern == "Only [] improvements may be built on this tile" && $0.param(0) == "All Road" }
        // Only count a luxury resource that we don't have yet as unique once
        var newLuxuries: Set<String> = []
        if onCoast { value += 3 }
        // Hills are free production and defence
        if onHill { value += 14 }
        // Observatories are good, but current implementation not mod-friendly
        if nextToMountain { value += 5 }
        // This bonus for settling on river is a bit outsized for the importance, but otherwise they have a habit of settling 1 tile away
        if t.riverAdjacent { value += 20 }
        // We want to found the city on an oasis because it can't be improved otherwise
        if unImprovable { value += 3 }
        if canSeeResource(t.resource, civId: civId), let r = t.resource.flatMap({ rs.resources[$0] }) {
            value -= 4
            // Settling on bonus resources tends to waste a food
            if r.resourceType == "Bonus" { value -= 8 }
            // Build on jungle luxuries for tempo: vegetation that gives no production when removed (Jungle, Marsh)
            if r.resourceType == "Luxury", let last = t.features.last.flatMap({ rs.terrains[$0] }), last.uniques.contains("Vegetation"), !last.uniqueObjects.contains(where: { $0.pattern == "Provides a one-time bonus of [] to the closest city when cut down" }) { value += 10 }
        }
        var tiles = 0
        for i in 0...2 {
            // Unciv forEachTileAtDistance(i): the tile, then Tile.neighbors, then the ring from 6 o'clock - the order
            // the Floats are added in, and the order the first tile of a new luxury is met in
            for n in tilesAtDistanceUncivOrder(c, i) {
                tiles += 1
                // Tiles close to the city can be worked more quickly, and thus should gain higher weight.
                value += rankTileForSettling(n, civId: civId, onCoast: onCoast, newLuxuries: &newLuxuries, base: &base, unexploredPrior: unexploredPrior) * (3 / Float(i + 1))
            }
        }
        // Placing cities on the edge of the map is bad, we can't even build improvements on them!
        value -= Float(19 - tiles) * 2.4   // HexMath.getNumberOfTilesInHexagon(2) = 19
        return value
    }
    private func distanceToCityModifier(_ c: HexCoord, nearbyCities: [City], civId: Int) -> Float {
        var modifier: Float = 0
        for city in nearbyCities {
            let d = c.distance(to: city.coord)
            var m: Float
            switch d {
            case 7: m = 2
            case 6: m = 4
            case 5: m = 8 // Settling further away sacrifices tempo
            case 4: m = 6
            case 3: m = -25
            case ..<3: m = -30 // Even if it is a mod that lets us settle closer, lets still not do it
            default: m = 0
            }
            // We want a defensive ring around our capital
            if city.civId == civId { m *= city.isCapital ? 2 : 1; modifier += m }
        }
        return modifier
    }
    private func rankTileForSettling(_ c: HexCoord, civId: Int, onCoast: Bool, newLuxuries: inout Set<String>, base: inout BaseTileMap, unexploredPrior: Float) -> Float {
        guard let civ = civ(civId), let t = map[c] else { return 0 }
        // Unexplored tiles are unknown - estimate them as an average tile instead of reading the actual map
        if !civ.explored.contains(c) { return unexploredPrior }
        if t.ownerCivId != nil { return -1 }   // Unciv: rankTile.getCity() != null
        var specific: Float = 0
        // Don't settle near but not on the coast
        if t.isWater && !onCoast { specific -= 1 }
        // Check if there are any new unique luxury resources. Unciv `civ.hasResource(resource)` reads the stored
        // summarizedCivResourceSupply, as updateCivResources last left it.
        if canSeeResource(t.resource, civId: civId), let r = t.resource, rs.resources[r]?.resourceType == "Luxury",
           (civResourceSupply(civId)[r] ?? 0) <= 0, !newLuxuries.contains(r) {
            specific += 10; newLuxuries.insert(r)
        }
        // Check if everything else has been calculated, if so return it
        if let b = base.values[c] { return specific + b }
        if let o = t.ownerCivId, o != civId { return 0 }
        var rank = Float(rankStatsValue(tileStats(t, civId: civId, city: nil), civId: civId))   // Unciv `getTileStats(null, civ)`
        if canSeeResource(t.resource, civId: civId), let r = t.resource.flatMap({ rs.resources[$0] }) {
            switch r.resourceType { case "Bonus": rank += 1; case "Strategic": rank += 2; default: rank += 10 } // Luxury: very important for humans who might want to conquer the AI
        }
        // Taking into account freshwater farm food (Unciv terrainHasUnique(FreshWater), over all the tile's terrains)
        if (t.terrainNames + (t.naturalWonder.map { [$0] } ?? [])).contains(where: { rs.terrains[$0]?.uniques.contains("Fresh water") == true }) { rank += 0.5 }
        // Taking into account yields from forest chopping
        if let last = t.features.last.flatMap({ rs.terrains[$0] }), last.uniqueObjects.contains(where: { $0.pattern == "Provides a one-time bonus of [] to the closest city when cut down" }) { rank += 0.7 }
        if t.naturalWonder != nil { rank += 4 }
        base.values[c] = rank; base.order.append(c)
        return rank + specific
    }
}
