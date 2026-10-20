// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/city/managers/CityExpansionManager.kt`: a city taking more land, by growth or by gold.
extension GameState {
    /// Border growth: claim the best unowned tile within radius 3 once enough culture accumulated.
    /// Tiles beyond the centre and its first ring (Unciv CityExpansionManager.tilesClaimed).
    func tilesClaimed(_ city: City) -> Int { let ring = Set(map.neighbors(of: city.coord)); return city.tiles.filter { $0 != city.coord && !ring.contains($0) }.count }

    /// Unciv: 6 × (tilesClaimed + 1.4813)^1.3 × culture cost modifier, ×1.5 for city-states.
    func expansionCost(for city: City) -> Double {
        // Unciv getCultureToNextTile: a Double, multiplied by Float factors (speed.cultureCostModifier, 1.5f,
        // toPercent()) that are widened as Floats, then roundToInt.
        var cost = 6 * pow(Double(tilesClaimed(city)) + 1.4813, 1.3)
        cost *= Double(Float(speed.cultureCostModifier))
        if civ(city.civId)?.isCityState == true { cost *= 1.5 }
        // each "[x]% Culture cost of natural border growth [cityFilter]" multiplies
        let ctx = UniqueContext(civId: city.civId, city: city)
        for u in cityUniquesCivFirst(city) where u.pattern == "[]% Culture cost of natural border growth []" && cityMatchesFilter(u.param(1), city: city, viewer: city.civId) && conditionalsHold(u, ctx) { cost *= Double(1 + Float(u.double(0)) / 100) }
        return Double(Stats.roundToInt(cost))
    }

    /// Unciv Automation.rankTileForExpansion: lower is better (distance ×100, resources / wonders / yields / neighbours subtract, non-adjacent +1000).
    func rankTileForExpansion(_ c: HexCoord, city: City) -> Int {
        guard let tile = map[c], let civ = civ(city.civId) else { return Int.max }
        let distance = c.distance(to: city.coord)
        let workRange = rs.constants.cityWorkRange
        var score = distance * 100
        func visible(_ r: String?) -> ResourceDef? { guard let r, let def = rs.resources[r] else { return nil }; if let rev = def.revealedBy, !civ.techs.contains(rev) { return nil }; return def }
        if let res = visible(tile.resource) {
            if res.resourceType != "Bonus" { score -= 105 } else if distance <= workRange { score -= 104 }
        } else {
            if tile.isWater { score += 3 }
            if distance > workRange { score += 100 }
        }
        if tile.naturalWonder != nil { score -= 105 }
        // Unciv ranks the candidate with getTileStats(city, civ) - the expanding city, not the tile's owner.
        // The candidates are unowned by definition, so asking the tile for its owner drops every city-scoped unique.
        let y = tileStats(tile, civId: city.civId, city: city)
        // Unciv: `score -= tile.stats.getTileStats(city, city.civ).sum().toInt()` - `Stats.sum()` folds the
        // seven Float values in DECLARATION order (food, production, gold, science, culture, happiness,
        // faith) and only then truncates. Ours summed Doubles, and with happiness and faith swapped, so the
        // truncation could land a point either side of the reference's.
        score -= Int(y.sum)
        var adjacentNaturalWonder = false, isContested = false
        for n in map.neighbors(of: c) {
            guard let nt = map[n], civ.explored.contains(n), nt.ownerCivId != city.civId else { continue }
            if nt.ownerCivId != nil { isContested = true; continue }
            let nd = n.distance(to: city.coord)
            if let r = visible(nt.resource), nd <= workRange || r.resourceType != "Bonus" { score -= 1 }
            if nt.naturalWonder != nil { if nd <= workRange { adjacentNaturalWonder = true }; score -= 1 }
        }
        if adjacentNaturalWonder { score -= 1 }
        if isContested { score -= 1 }
        if !map.neighbors(of: c).contains(where: { city.tiles.contains($0) }) { score += 1000 }
        return score
    }

    /// Unciv CityExpansionManager.chooseNewTileToOwn: any unowned tile within the expand range, ranked by rankTileForExpansion.
    func chooseNewTileToOwn(_ city: City) -> HexCoord? {
        let umT = UIMeasure.start(); defer { UIMeasure.stop("chooseNewTileToOwn", umT) }
        let choosable = map.tilesInDistanceUncivOrder(city.coord, radius: rs.constants.cityExpandRange).filter { map[$0]?.ownerCivId == nil }
        if epochsDebug, let want = epochsRankCity, city.name == want {
            let scored = choosable.map { c -> (String, Int) in
                let t = map[c]!, u = uncivPosition(c)
                let y = tileStats(t, civId: city.civId, city: city)
                return ("(\(u.x),\(u.y))\(t.baseTerrain)/\(t.resource ?? "-")\(t.riverAdjacent ? "+river" : "")[sum \(Int(y.food + y.production + y.gold + y.science + y.culture + y.faith + y.happiness))]", rankTileForExpansion(c, city: city))
            }.sorted { $0.1 < $1.1 }.prefix(8)
            print("EXPE t=\(turn) \(city.name) techs=\(civ(city.civId)?.techs.count ?? 0) iron=\(civ(city.civId)?.techs.contains("Iron Working") ?? false) | " + scored.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
        }
        return choosable.min { rankTileForExpansion($0, city: city) < rankTileForExpansion($1, city: city) }   // first minimum in Unciv getTilesInDistance order
    }

    /// Unciv CityExpansionManager.takeOwnership: claim the tile (from nobody or another city), clear encampments, evict units that may not stay.
    func takeOwnership(cityId: Int, _ c: HexCoord) {
        if epochsDebug, let n = city(cityId)?.name, n == "Constantinople" || n == "Paris" {
            let u = uncivPosition(c); print("TAKEE t=\(turn) \(n) (\(u.x),\(u.y))")
        }
        // Unciv's takeOwnership ends in a full cityStats.update(), and that reads the city's CURRENT
        // construction - so a Settler queued earlier this turn begins converting food the moment the border
        // grows, even though the turn's own yields were taken from the cache filled before it. Our snapshot of
        // the construction has to be dropped here for the same reason.
        guard let ci = cityIndex(cityId), map[c] != nil, map[c]?.isCityCenter != true else { return }
        let civId = cities[ci].civId
        // Unciv: `if (tile.getCity() != null) tile.getCity()!!.expansion.relinquishOwnership(tile)` - the losing
        // city gives the tile up through the normal path, so every city of its civ that worked the tile stops
        // working it and reassigns the freed citizen, and a "Creates one improvement" claim on the tile is
        // released. Unciv's `tile.getCity()` is the owning city object; ours is the owner civ's city holding it.
        // relinquishOwnership clears the tile's owner and working city, which the take below sets again.
        if let prev = map[c]?.ownerCivId, let pc = cities.first(where: { $0.civId == prev && $0.tiles.contains(c) })?.id {
            relinquishOwnership(cityId: pc, c)
        }
        if map[c]?.hasBarbarianCamp == true {   // the BarbarianManager notices the missing camp next turn
            map[c]?.improvement = nil
            for cs in cityStates { handleObsoleteQuests(cityState: cs.id) }   // Unciv takeOwnership → removeImprovement → handleObsoleteGlobalQuests
        }
        cities[ci].tilesWithItem(c, walk: uncivTileWalk(cities[ci]))   // Unciv `city.tiles = city.tiles.withItem(tile.position)`
        map[c]?.ownerCivId = civId
        map[c]?.workingCityId = nil
        setOwningCityRoadOwner(at: c, civId: civId)   // Unciv Tile.setOwningCity(city): "remove previous neutral tile owner", then roadOwner
        // Unciv order: autoAssignPopulation and updateOurTiles/cityStats.update run BEFORE the units are
        // displaced, so a tile an enemy unit still stands on still counts as blockaded while it is assigned.
        assignWorkers(cityId: cityId, onlyFreePopulation: true, why: "CityExpansionManager:6920")   // Unciv takeOwnership: population.autoAssignPopulation()
        // Unciv takeOwnership: `city.civ.cache.updateOurTiles()`, and updateOurTiles ENDS in updateCivResources -
        // which, when the resources changed, runs updateStatsForNextTurn and so writes the happiness FIELD, and
        // on a level crossing refreshes every city's stored stats. Clearing the derived caches was not enough:
        // measured on `t_45` turn 41, Kyoto's own border grew onto the Silk before it banked its food, and with
        // only invalidateHappiness the field still read -1, so the city ate at -75% growth for a turn Unciv
        // spent at 0% (stored 2 against Unciv's 3, and the two engines never met again).
        // updateOurTiles first refreshes the viewable tiles (and so the explored ones): a tile bought this turn and
        // its ring are seen at once. Greece's settler found its sites across a tile it had just bought; ours saw
        // them only at the end of the turn.
        updateExploration(for: civId)
        updateCivResources(civId)
        invalidateHappiness(civId)                                // a city-state's own tiles: updateCivResources skips it
        updateCityStats(cityId, reason: "CityExpansionManager:5459")   // takeOwnership: cityStats.update(), BEFORE the units are moved
        // Unciv: `if (!unit.civ.diplomacyFunctions.canPassThroughTiles(city.civ)) teleportToClosestMoveableTile()` -
        // open borders or WAR let a unit stay (DiplomacyFunctions.canPassThroughTiles), a barbarian only once
        // it may enter player tiles, a human inside a city-state's borders always; otherwise a sleeping worker
        // of ours wakes up.
        for u in units(at: c) {
            if !canPassThroughTiles(u.civId, civId) { teleportToClosestMoveableTile(u.id) }
            // Unciv: a sleeping unit (either sleep order) with hasUniqueToBuildImprovements or
            // hasUniqueToCreateWaterImprovements is woken: `due = true; action = null`
            else if u.civId == civId && isSleeping(u) && (hasUniqueToBuildImprovements(u) || u.def.createsWaterImprovements), let ui = unitIndex(u.id) { units[ui].order = .none; units[ui].due = true }
        }
    }

    /// Unciv CityExpansionManager.nextTurn → addNewTileWithCulture.
    func expandBorders(cityId: Int) {
        guard let ci = cityIndex(cityId), let tile = chooseNewTileToOwn(cities[ci]) else { return }
        cities[ci].expansionCulture -= expansionCost(for: cities[ci])
        takeOwnership(cityId: cityId, tile)
        vpInstantYield(.borders, civId: cities[ci].civId, cityId: cityId)   // VP
        notify(cities[ci].civId, "[\(cities[ci].name)] has expanded its borders!", category: .Cities, icons: ["Culture"], actions: [.location(tile), .location(cities[ci].coord)])   // LocationAction(location, city.location)
    }
}

extension GameState {

    @discardableResult
    /// Unciv CityExpansionManager.relinquishOwnership: the tile leaves the city and belongs to nobody again.
    func relinquishOwnership(cityId: Int, _ c: HexCoord, evenIfNotOwned: Bool = false) {
        guard let ci = cityIndex(cityId), c != cities[ci].coord else { return }
        let civId = cities[ci].civId
        if !cities[ci].tiles.contains(c) {
            // Unciv's relinquishOwnership has no guard: on a tile the city never owned (UseGoldAutomation reverting a
            // path it could not finish buying) only the marker removal and the closing refresh do anything.
            guard evenIfNotOwned, map[c]?.ownerCivId == nil else { return }
            // `city.tiles.withoutItem(tile.position)` still copies the set: the city's tiles move into the table their
            // size implies, a larger one left by an earlier withoutItem dropped
            cities[ci].tilesWithoutItem(c, walk: uncivTileWalk(cities[ci]))
            removeCreatesOneImprovementMarker(at: c)
            updateOurTiles(civId)
            invalidateHappiness(civId)
            updateCityStats(cityId, reason: "CityExpansionManager.relinquishUnowned")
            return
        }
        cities[ci].tilesWithoutItem(c, walk: uncivTileWalk(cities[ci]))   // Unciv `city.tiles = city.tiles.withoutItem(tile.position)`
        cities[ci].lockedTiles.remove(c)
        // Unciv: `for (city in city.civ.cities) if (city.isWorked(tile)) { stopWorkingTile; autoAssignPopulation() }`
        // - any city of this civilization that worked the tile drops it and places the freed citizen again,
        // not only the city that owned it. The tile's owner is cleared only AFTER this loop, so it is still one of
        // the civ's workable tiles (getWorkableTiles: owner == civ) and the city may well pick it straight back up:
        // it then keeps working a tile it no longer owns, yields included, until its next reassignment. Ours cleared
        // the owner first (a documented deviation): t_45 turn 171, Byzantium's Citadel took two tiles Osaka worked,
        // Unciv's Osaka kept both for the turn and ours moved the two citizens elsewhere.
        for other in cities(of: civId) where other.workedTiles.contains(c) {
            stopWorkingTile(cityId: other.id, c)
            assignWorkers(cityId: other.id, onlyFreePopulation: true, why: "CityExpansionManager:10082")   // Unciv population.autoAssignPopulation()
        }
        removeCreatesOneImprovementMarker(at: c)   // Unciv tile.improvementFunctions.removeCreatesOneImprovementMarker()
        // Unciv tile.setOwningCity(null): no owner, so Tile.getWorkingCity() is null whoever still lists the tile.
        map[c]?.ownerCivId = nil
        map[c]?.workingCityId = nil
        if map[c]?.roads == true { map[c]?.roadOwner = nil }   // Unciv Tile.setOwningCity(null): "Razing City! Remove owner"
        // Unciv relinquishOwnership ends in `city.civ.cache.updateOurTiles()` and `city.cityStats.update()`,
        // the same pair takeOwnership ends in - a city that just lost a tile is worth as much of a refresh as
        // one that just gained one, and the empire's resources can change either way.
        updateOurTiles(civId)   // viewable tiles, then updateCivResources
        invalidateHappiness(civId)
        updateCityStats(cityId, reason: "CityExpansionManager:10665")
    }

    /// Unciv TileImprovementFunctions.removeCreatesOneImprovementMarker: a tile that a
    /// "Creates a [] improvement on a specific tile" construction had claimed loses that claim. Our marker is
    /// the claiming city's `reservedImprovementTile` (Unciv keeps it on the tile as a negative-turn
    /// improvementQueue entry), and TurnManager re-picks a tile for the construction next turn.
    func removeCreatesOneImprovementMarker(at c: HexCoord) {
        for i in cities.indices where cities[i].reservedImprovementTile == c {
            cities[i].reservedImprovementTile = nil
            cities[i].reservedImprovement = ""
        }
    }

    /// Buy an unowned tile adjacent to the city's territory.
    /// Unciv getGoldCostOfTile: 50 × (distance − 1) + tilesClaimed × 5, × gold cost modifier and tile-cost uniques.
    func tilePurchaseCost(_ city: City, tile: HexCoord? = nil, extraTiles: Int = 0) -> Int {
        // Unciv getGoldCostOfTile: 50 × (distance − 1) + (tilesClaimed + extraTiles) × 5, × gold cost modifier, × each "[x]% Gold cost of acquiring tiles [cityFilter]"
        let distance = tile.map { $0.distance(to: city.coord) } ?? 2
        var cost = 50.0 * Double(distance - 1) + Double(tilesClaimed(city) + extraTiles) * 5
        cost *= Double(Float(speed.goldCostModifier))   // Unciv: Double *= Float
        let ctx = UniqueContext(civId: city.civId, city: city)
        for u in cityUniquesCivFirst(city) where u.pattern == "[]% Gold cost of acquiring tiles []" && cityMatchesFilter(u.param(1), city: city, viewer: city.civId) && conditionalsHold(u, ctx) { cost *= Double(1 + Float(u.double(0)) / 100) }
        return Stats.roundToInt(cost)
    }

    func purchasableTiles(_ city: City) -> [HexCoord] {
        guard !city.isPuppet, !city.razing, city.resistanceTurns == 0 else { return [] }   // Unciv canBuyTile: not puppet, not being razed, not in resistance
        return map.tilesWithin(city.coord, radius: rs.constants.cityWorkRange).filter { c in   // Unciv tilesInRange
            guard let t = map[c], t.ownerCivId == nil else { return false }
            return map.neighbors(of: c).contains { city.tiles.contains($0) }
        }
    }

    /// Unciv getRing: every unowned tile the owner has seen within `ring` of the centre - the rings are
    /// cumulative, and unlike a single purchase this list is not limited to tiles next to our own.
    func purchasableTiles(_ city: City, inRing ring: Int) -> [HexCoord] {
        guard !city.isPuppet, !city.razing, city.resistanceTurns == 0 else { return [] }
        let seen = civ(city.civId)?.explored ?? []
        return map.tilesWithin(city.coord, radius: ring)
            .filter { map[$0]?.ownerCivId == nil && seen.contains($0) }
            .sorted { ($0.distance(to: city.coord), $0.q, $0.r) < ($1.distance(to: city.coord), $1.q, $1.r) }
    }

    /// Unciv getRingCost: each further tile in the batch is priced as though the ones before it were already claimed.
    func ringPurchaseCost(_ city: City, ring: Int) -> Int {
        purchasableTiles(city, inRing: ring).enumerated().reduce(0) { $0 + tilePurchaseCost(city, tile: $1.element, extraTiles: $1.offset) }
    }

    func buyTilesInRing(cityId: Int, ring: Int) {
        guard let city = self.city(cityId) else { return }
        // Unciv buyRing: `if (!tryBuyTile(tile)) break` - the first refusal ends the batch.
        for c in purchasableTiles(city, inRing: ring) { guard buyTile(cityId: cityId, c) else { break } }
    }

    func buyTile(cityId: Int, _ c: HexCoord) -> Bool {
        guard let ci = cityIndex(cityId), let civIdx = civIndex(cities[ci].civId), purchasableTiles(cities[ci]).contains(c) else { return false }
        let cost = tilePurchaseCost(cities[ci], tile: c)
        guard settings.godMode || civs[civIdx].gold >= Double(cost) else { return false }   // Unciv CityExpansionManager.buyTile: god mode skips the check, gold is still paid
        civs[civIdx].gold -= Double(cost); goldTrace(civs[civIdx].id, -Double(cost))
        takeOwnership(cityId: cityId, c)   // Unciv buyTile → takeOwnership (evicts units, wakes workers)
        if let ci = cityIndex(cityId) { reassignPopulationDeferred(ci) }   // Unciv: reapply the city focus
        return true
    }
}
