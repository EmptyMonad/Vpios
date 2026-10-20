// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/city/managers/CityPopulationManager.kt`: assigning citizens to tiles and specialists.
extension GameState {
    /// Unciv CityPopulationManager.reassignAllPopulation / autoAssignPopulation: greedy assignment of every citizen
    /// to the best tile or specialist slot by Automation.rankStatsForCityWork; locked tiles are kept.
    /// Unciv City.reassignPopulation (or, with onlyFreePopulation, CityPopulationManager.autoAssignPopulation for unassigned citizens only)
    func assignWorkers(cityId: Int, onlyFreePopulation: Bool = false, resetLocked: Bool = false, why: String = "?") {
        guard let ci = cityIndex(cityId) else { return }
        if epochsDebug { AI.profile["n.assignWorkers", default: 0] += 1; AI.profile["w." + why, default: 0] += 1 }
        if let w = ProcessInfo.processInfo.environment["WT_CITY"], w == cities[ci].name {
            print("AAWHY t=\(uncivTurns) \(cities[ci].name) why=\(why) only=\(onlyFreePopulation) reset=\(resetLocked) pop=\(cities[ci].population) worked=\(cities[ci].workedTiles.count)")
        }   // Unciv: autoAssignPopulation 552 times in 60 turns of `settled`
        // Unciv autoAssignPopulation ends in `city.cityStats.update()`; its OPENING update happens further
        // down, once the citizens are off their tiles - reassignPopulation clears them before calling it.
        var city = cities[ci]
        // Unciv reassignPopulation: with resetLocked the worked tiles go whatever the focus says.
        let manual = city.cityFocus == "Manual" && !resetLocked
        let manualSpec = city.manualSpecialists   // Unciv: only hand-placed specialists are left alone; autoAssignPopulation still fills empty slots
        if !onlyFreePopulation {
            for t in city.workedTiles where map[t]?.workingCityId == cityId { map[t]?.workingCityId = nil }   // a tile another civ took over may be worked by its new owner
            // Unciv reassignPopulation: `if (resetLocked) { workedTiles = hashSetOf(); lockedTiles = hashSetOf() }
            // else if (cityAIFocus != Manual) workedTiles = lockedTiles` - the locked set as it stands, its walk and its
            // table; a Manual city keeps the set it works. Ours emptied the set and put the locked tiles back sorted by
            // coordinate (and a Manual city's worked tiles after them), so its walk was not the set's.
            if resetLocked { city.workedTiles = []; city.workedTilesTable = 0; city.lockedTiles = []; city.lockedTilesTable = 0 }
            else if !manual { city.workedTiles = lockedTilesWalk(city); city.workedTilesTable = city.lockedTilesTable }
            if !city.manualSpecialists { city.specialists = [:] }
            city.shouldReassignPopulation = false
        }
        // Unciv City.getWorkableTiles + CityPopulationManager: our tiles within the work range, not blockaded,
        // `.filterNot { it.providesYield() }` - Tile.providesYield: a city center (a sister city's too), a worked tile, or an
        // unpillaged improvement / any of allTerrains (the natural wonder included) with "Tile provides yield without assigned population"
        let candidates = map.tilesWithin(city.coord, radius: rs.constants.cityWorkRange).filter { c in
            guard c != city.coord, let t = map[c], t.ownerCivId == city.civId, t.workingCityId == nil, !tileProvidesYield(t) else { return false }
            return !isBlockaded(c, for: city.civId)
        }
        if manualSpec { var assigned = city.specialists.values.reduce(0, +); while city.workedTiles.count + assigned > city.population, let k = city.specialists.keys.sorted().first(where: { (city.specialists[$0] ?? 0) > 0 }) { city.specialists[k]! -= 1; assigned -= 1 } }
        var tileStats: [HexCoord: Stats] = [:]
        for c in candidates { tileStats[c] = self.tileStats(map[c]!, civId: city.civId, city: city) }   // Unciv getTileStats(city, civ)
        var slots: [String: Int] = [:]
        var slotOrder: [String] = []   // Unciv Counter order: first building that offers the slot
        for b in city.buildings { for (name, n) in (rs.buildings[b]?.specialistSlots ?? [:]).sorted(by: { $0.key < $1.key }) { if slots[name] == nil { slotOrder.append(name) }; slots[name, default: 0] += n } }
        var free = city.population - city.workedTiles.count - city.specialists.values.reduce(0, +)
        cities[ci] = city
        // Unciv autoAssignPopulation opens with `city.cityStats.update()`, and that call carries
        // updateCivStats = true: the empire's statsForNextTurn is recomputed here, against a city whose
        // citizens have just been taken off their tiles. rankStatsForCityWork reads that sum ("we have a
        // global problem" doubles gold), so refreshing it only after the assignment let every citizen be
        // ranked against the gold the city was earning before it was emptied.
        // Unciv autoAssignPopulation's opening `city.cityStats.update()`, with updateCivStats = true: THE
        // city's stats are stored here, against a city whose citizens have just been taken off their tiles,
        // and every ranking below reads them from there.
        updateCityStats(city.id, reason: "assign.open")
        // That update's updateTileStats stops working a blockaded tile (stopWorkingTile, shouldReassignPopulation),
        // and Unciv counts `getFreePopulation()` only AFTER it: the citizen taken off the tile is free and is placed
        // below. Measured on `settled` EV t=228: Carthage's border grew onto 0,9 at the end of the turn, the opening
        // update dropped the blockaded -4,5, and Unciv put that citizen on an Engineer slot; ours counted free = 0
        // from the copy taken before the update, placed nobody, and wrote the stale copy (still working -4,5) back.
        city = cities[ci]
        free = city.population - city.workedTiles.count - city.specialists.values.reduce(0, +)
        // Unciv autoAssignPopulation: `val freePopulation = getFreePopulation(); if (freePopulation <= 0) return`
        // - a city with nobody to place is updated ONCE, by the opening call, and the closing one never runs.
        // Ours had a `defer` doing the closing update on top of the explicit one at the end, so an ordinary
        // reassignment updated three times where the reference updates twice, and a city with no free citizen
        // updated three times where the reference updates once. Counted on `settled`: 32 of our 41.3 city
        // updates a turn came from here.
        if free <= 0 { return }
        var current = currentCityStats(city.id)   // Unciv updates only the running food total while assigning
        // Unciv: `city.currentGPPBonus = city.getGreatPersonPercentageBonus()  // pre-calculate for use in Automation.rankSpecialist`
        // - GreatPersonPointsBreakdown.getPercentagesApplyingToAllGP, Int. Written on the copy the loop ranks with,
        // which goes back into `cities` at the end.
        let assigning = city
        let gppBonus = Int(civPercent(assigning.civId, pattern: "[]% Great Person generation []", city: assigning, filterParamIndex: 1, filterMatches: { self.cityMatchesFilter($0, city: assigning, viewer: assigning.civId) })) + Int(friendshipGreatPersonBoost(assigning.civId))
        city.currentGPPBonus = gppBonus
        let specialistFoodBonus = 2.0 - cityUniquesCivFirst(city).filter { $0.pattern == "[]% Food consumption by specialists []" && scopeIncludes($0, city: city) }.reduce(2.0) { $0 * (1 + $1.double(0) / 100) }
        // Unciv compareBy(value, longitude, latitude) and takes the maximum, so a tie goes to the largest of those.
        let uncivFrame = UncivSave.Frame.forExport(width: map.width, height: map.height)
        func uncivKey(_ c: HexCoord) -> (Int, Int) {
            let p = uncivFrame.unciv(col: c.offsetCol, row: c.offsetRow)
            return (p.x - p.y, p.x + p.y)   // Unciv HexMath longitude, latitude
        }
        while free > 0 {
            var bestTile: HexCoord? = nil; var bestTileValue = 0.0
            if epochsDebug, let want = epochsRankCity, city.name == want {
                let scored = candidates.filter { !city.workedTiles.contains($0) }
                    .map { c -> (String, Double) in
                        let t = map[c]!
                        let up = uncivFrame.unciv(col: c.offsetCol, row: c.offsetRow)
                        return ("(\(up.x),\(up.y))\(t.baseTerrain)/\(t.resource ?? "-")\(t.riverAdjacent ? "+river" : "")<\(t.improvement ?? "-")>[\(tileStats[c]!.food)f\(tileStats[c]!.gold)g\(tileStats[c]!.production)p]", rankStatsForCityWork(tileStats[c]!, city: city, current: current, specialist: false))
                    }.sorted { $0.1 > $1.1 }.prefix(8)
                let bestJobDbg = slotOrder.filter { !manualSpec && (city.specialists[$0] ?? 0) < (slots[$0] ?? 0) }.map { ($0, rankSpecialist($0, city: city, current: current)) }.max { $0.1 < $1.1 }
                print("RANKE t=\(turn) surplus=\(current.foodSurplus) pop=\(city.population) free=\(free) happy=\(happiness(of: city.civId)) hb=\({ let h = happinessBreakdown(city.civId); return h.rows.map { "\($0.0):\($0.1)" }.sorted().joined(separator: ",") + ",total:\(h.total)" }()) growthPct=\(current.growthPercent) constr=\(city.currentProduction?.name ?? "-") netGold=\(netGoldPerTurn(city.civId)) goldRows=[\(statMapForNextTurn(city.civId).filter { $0.1.gold != 0 }.map { "\($0.0):\($0.1.gold)" }.joined(separator: ","))] goldFloat=\(statMapForNextTurn(city.civId).reduce(Float(0)) { $0 + Float($1.1.gold) }) cityGold=[\(cities(of: city.civId).map { "\($0.name):\(currentCityStats($0.id).total.gold)" }.joined(separator: ","))] job=\(bestJobDbg.map { "\($0.0)=\($0.1)" } ?? "-") | " + scored.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
            }
            for c in candidates where !city.workedTiles.contains(c) {
                let v = rankStatsForCityWork(tileStats[c]!, city: city, current: current, specialist: false)
                if bestTile == nil || v > bestTileValue || (v == bestTileValue && uncivKey(c) > uncivKey(bestTile!)) { bestTile = c; bestTileValue = v }
            }
            var bestJob: String? = nil; var bestJobValue = 0.0
            for name in slotOrder where !manualSpec && (city.specialists[name] ?? 0) < (slots[name] ?? 0) {
                let v = rankSpecialist(name, city: city, current: current)
                if bestJob == nil || v > bestJobValue { bestJob = name; bestJobValue = v }
            }
            if ProcessInfo.processInfo.environment["WT_CITY"] == city.name {
                let bp = bestTile.map { uncivPosition($0) }
                print("AAE t=\(uncivTurns) \(city.name) free=\(free) tile=\(bp.map { "(\($0.x),\($0.y))" } ?? "nil") v=\(Float(bestTileValue)) job=\(bestJob ?? "nil") v=\(Float(bestJobValue)) spec=\(city.specialists) food=\(Float(current.foodSurplus))")
            }
            // Unciv repeat(freePopulation): a round that places nobody does not end the loop.
            // Unciv: `if (valueBestTile > valueBestSpecialist) { if (bestTile != null) ... } else if (bestJob != null)` -
            // a round the tiles win without a tile to offer places nobody, it does not fall through to a specialist.
            if bestTileValue > bestJobValue { if let t = bestTile { city.workedTilesWithItem(t, walk: workedTilesWalk(city)); current.foodSurplus += tileStats[t]!.food } }   // city.workTile
            else if let j = bestJob { city.specialists[j, default: 0] += 1; current.foodSurplus += specialistFoodBonus }
            free -= 1
        }
        cities[ci] = city
        // Unciv Tile.getWorkingCity looks among the tile OWNER's cities only: a tile this city re-picked while its
        // ownership was being relinquished (CityExpansionManager.relinquishOwnership) is in our workedTiles but is
        // nobody's working tile once another civ owns it.
        for t in city.workedTiles where map[t]?.ownerCivId == city.civId { map[t]?.workingCityId = cityId }
        if epochsDebug, let want = epochsRankCity, city.name == want {
            let w = city.workedTiles.map { c -> String in let p = uncivPosition(c); return "\(p.x),\(p.y)" }.sorted().joined(separator: " ")
            print("RANKEND t=\(turn) \(city.name) pop=\(city.population) worked=\(city.workedTiles.count) spec=\(city.specialists.values.reduce(0, +)) [\(w)]")
        }
        updateCityStats(city.id, reason: "assign.close")   // Unciv CityStats.update(updateCivStats = true)
    }

    /// Unciv City.stopWorkingTile: a tile that is no longer worked is unlocked as well.
    @discardableResult
    func stopWorkingTile(cityId: Int, _ c: HexCoord) -> Bool {
        guard let ci = cityIndex(cityId), cities[ci].workedTiles.contains(c) else { return false }
        cities[ci].lockedTiles.remove(c)   // unlockTile
        cities[ci].workedTilesWithoutItem(c, walk: workedTilesWalk(cities[ci]))   // `workedTiles = workedTiles.withoutItem(tile.position)`
        if map[c]?.workingCityId == cityId { map[c]?.workingCityId = nil }
        return true
    }

    /// Unciv CityPopulationManager.unassignExtraPopulation: drop tiles we may no longer work, cap specialists, then remove the worst
    /// tile (locked tiles +10) or specialist until the citizens fit the population
    func unassignExtraPopulation(cityId: Int) {
        guard let ci = cityIndex(cityId) else { return }
        var city = cities[ci]
        // Unciv unassignExtraPopulation tests owner, working city and work range only - a blockaded tile is
        // dropped by CityStats.updateTileStats instead. `city.stopWorkingTile(tile)` unlocks it as well; the tiles go
        // in the walk of `getWorkedTiles().toList()`, each one a new set (withoutItem).
        for t in workedTilesWalk(city) where map[t]?.ownerCivId != city.civId || t.distance(to: city.coord) > rs.constants.cityWorkRange
            || (map[t]?.workingCityId != nil && map[t]?.workingCityId != cityId) {
            city.lockedTiles.remove(t); city.workedTilesWithoutItem(t, walk: workedTilesWalk(city))
            if map[t]?.workingCityId == cityId { map[t]?.workingCityId = nil }
        }
        // Unciv: `for ((name, max) in getMaxSpecialists()) if (allocations[name] > max) allocations[name] = max` -
        // only the kinds some building still offers are capped; the loop below deals with the rest.
        var maxSpecialists: [String: Int] = [:]
        for b in city.buildings { for (name, n) in rs.buildings[b]?.specialistSlots ?? [:] { maxSpecialists[name, default: 0] += n } }
        for (name, n) in city.specialists { if let cap = maxSpecialists[name], n > cap { city.specialists[name] = cap } }
        cities[ci] = city
        // Automation.rankTileForCityWork / rankSpecialist read the STORED city stats (city.cityStats.currentCityStats)
        // and the tile's stats for THIS city (tile.stats.getTileStats(city, civ)).
        let current = currentCityStats(city.id)
        func tileValue(_ t: HexCoord) -> Double { map[t].map { rankStatsForCityWork(tileStats($0, civId: city.civId, city: city), city: city, current: current, specialist: false) } ?? 0 }
        if ProcessInfo.processInfo.environment["UNASSQ"] == city.name, city.workedTiles.count + city.specialists.values.reduce(0, +) > city.population {
            print("UNASSE t=\(uncivTurns) \(city.name) pop=\(city.population) " + workedTilesWalk(city).map { t in let p = uncivPosition(t); return "\(p.x),\(p.y)=\(Float(tileValue(t)))" }.joined(separator: " ") + " spec=\(city.specialists)")
        }
        while city.workedTiles.count + city.specialists.values.reduce(0, +) > city.population {
            // Unciv `city.getWorkedTiles().minByOrNull` walks the workedTiles HashSet<Vector2>: of two tiles worth the same,
            // the one first in hash order goes (a razed Breda kept its Aluminum hill, ours its Stone) - over the table the
            // set sits in: the previous round's withoutItem copy keeps the table of the size before it.
            let worstTile = workedTilesWalk(city).min { tileValue($0) + (city.lockedTiles.contains($0) ? 10 : 0) < tileValue($1) + (city.lockedTiles.contains($1) ? 10 : 0) }
            let valueWorstTile = worstTile.map(tileValue) ?? 0
            // Unciv `specialistAllocations.keys.minByOrNull`: the Counter's order, the first minimum kept
            let jobs = city.orderedSpecialistKeys.filter { (city.specialists[$0] ?? 0) > 0 }
            let worstJob = city.manualSpecialists ? nil : jobs.min { rankSpecialist($0, city: city, current: current) < rankSpecialist($1, city: city, current: current) }
            let valueWorstJob = worstJob.map { rankSpecialist($0, city: city, current: current) } ?? 0
            if let job = worstJob, let tile = worstTile {
                if valueWorstTile < valueWorstJob { city.lockedTiles.remove(tile); city.workedTilesWithoutItem(tile, walk: workedTilesWalk(city)); if map[tile]?.workingCityId == cityId { map[tile]?.workingCityId = nil } } else { city.specialists[job, default: 0] -= 1 }
            } else if let job = worstJob { city.specialists[job, default: 0] -= 1 }
            else if let tile = worstTile { city.lockedTiles.remove(tile); city.workedTilesWithoutItem(tile, walk: workedTilesWalk(city)); if map[tile]?.workingCityId == cityId { map[tile]?.workingCityId = nil } }
            else if let job = jobs.min(by: { rankSpecialist($0, city: city, current: current) < rankSpecialist($1, city: city, current: current) }) { city.specialists[job, default: 0] -= 1 }
            else { break }
        }
        city.specialists = city.specialists.filter { $0.value > 0 }
        cities[ci] = city
    }

    /// Unciv CityTurnManager.chooseCityFocus
    func chooseCityFocus(_ city: City) -> String {
        if city.population <= 3 { return "NoFocus" }
        switch city.currentProduction {
        case .building(let b)?: if rs.buildings[b]?.isWonder == true || rs.buildings[b]?.uniques.contains("Spaceship part") == true { return "ProductionFocus" }
        case .unit(let u)?: if rs.units[u]?.isSpaceshipPart == true { return "ProductionFocus" }
        default: break
        }
        return "NoFocus"
    }

    /// Unciv Automation.getFoodModWeight
    func foodModWeight(_ city: City, surplusFood: Double) -> Double {
        if happiness(of: city.civId) < -8 { return 0 }
        if !(civ(city.civId)?.isPlayer ?? false) { return 1.5 }
        if GameState.evlogOn { hbr("C6.humanFoodWeight", city.civId) }
        if city.cityFocus == "NoFocus" {
            if city.population < 5 { return 2 }
            // `surplusFood > city.population.getFoodToNextPopulation() / (10 * speed)`: Int / (Int * Float) - all in Float, so
            // 67 / (10 * 0.67f) is 10.0f (Quick) and a surplus of 10 is not above it; in Double it was 9.9999997 and was
            if Float(surplusFood) > Float(Int(growthCost(city))) / (Float(10) * Float(speed.modifier)) { return 0.75 }
        }
        return 1
    }

    /// Unciv Automation.rankStatsForCityWork
    func rankStatsForCityWork(_ stats: Stats, city: City, current: CityStats, specialist: Bool) -> Double {
        var y = stats
        let ctx = UniqueContext(civId: city.civId, city: city)
        if specialist {
            // Unciv asks only UniqueType.FoodConsumptionBySpecialists here (and for specialistFoodBonus) - not the newer
            // "[]% Food consumption by [Specialists] []" Civil Society carries, which only calcFoodEaten reads. Counting it
            // made our Scientist worth 112 more (victory t=198, Persepolis took specialists Unciv did not).
            // Unciv computes all of this in Float, and this is the number that decides which tile a citizen
            // works - so a tie broken the wrong way here shows up directly in the dumped `worked[...]` list.
            for u in cityUniquesCivFirst(city) where u.pattern == "[]% Food consumption by specialists []" && scopeIncludes(u, city: city) && conditionalsHold(u, ctx) { y.food = Stats.f32(y.food - Stats.f32(Stats.f32(u.double(0) / 100) * 2)) }
            for u in cityUniquesCivFirst(city) where u.pattern == "[]% Unhappiness from [] []" && u.param(1) == "Specialists" && scopeIncludes(u, city: city) && conditionalsHold(u, ctx) { y.happiness = Stats.f32(y.happiness - Stats.f32(u.double(0) / 100)) }
            if y.science == 3 || y.science >= 5 { y.science = Stats.f32(y.science * Stats.f32(1.3)) }
        }
        let surplusFood = current.foodSurplus
        let starving = surplusFood < 0
        // Unciv CityStats.canConvertFoodToProduction + getProductionFromExcessiveFood (stepped)
        let convertsFood: Bool = {
            switch city.currentProduction {
            case .unit(let n)?: return rs.units[n]?.excessFoodToProduction == true
            case .building(let b)?: return rs.buildings[b]?.uniques.contains("Excess Food converted to Production when under construction") == true
            default: return false
            }
        }()
        if surplusFood > 0 && convertsFood {
            func fromExcess(_ f: Double) -> Double { f >= 4 ? 2 + (f / 4).rounded(.towardZero) : f >= 2 ? 2 : f >= 1 ? 1 : 0 }
            y.production = Stats.f32(y.production + Stats.f32(fromExcess(Stats.f32(surplusFood + y.food)) - fromExcess(surplusFood)))
            y.food = 0
        }
        var feedFood = 0.0
        if starving { feedFood = max(0, min(y.food, -surplusFood)) }
        var growthFood = y.food - feedFood
        if city.avoidGrowth { growthFood = 0 }   // Unciv: only count food that keeps the city from starving
        y.food = 1
        y.applyRankingWeights()
        let foodBaseWeight = y.food
        y.food = Stats.f32(feedFood * Stats.f32(foodBaseWeight * 8))
        if !current.nullifiesGrowth {
            // Unciv builds a fresh `CityStats(city)` here and sums `getGrowthBonus(growthFood)` source by
            // source - each one `(amount / 100f) * totalFood` in Float. Reading the stored total percentage
            // and multiplying once is the same number only until the rounding, which is the whole point.
            var newGrowth = growthFood
            if let gb = Epochs.CityStats(city: city, state: self) {
                for st in gb.getGrowthBonus(growthFood).values { newGrowth = Stats.f32(newGrowth + st.food) }
            }
            if city.isCelebrating && happiness(of: city.civId) >= 0 { newGrowth = Stats.f32(newGrowth + Stats.f32(growthFood / 4)) }
            newGrowth = max(0, newGrowth)
            y.food = Stats.f32(y.food + Stats.f32(Stats.f32(newGrowth * foodBaseWeight) * foodModWeight(city, surplusFood: surplusFood)))
        }
        if city.population < 10 { y.science = Stats.f32(y.science / 2) }
        if netGoldPerTurn(city.civId) < 0 { y.gold = Stats.f32(y.gold * 2) }
        if happiness(of: city.civId) < 0 { y.happiness = Stats.f32(y.happiness * 2) }
        if allTechsResearched(city.civId) { y.science = 0 }
        if city.currentProduction == nil { y.production = Stats.f32(y.production / 6) }   // Unciv PerpetualConstruction (Idle included)
        if specialist, ProcessInfo.processInfo.environment["WT_CITY"] == city.name { print("RANKSE allTechs=\(allTechsResearched(city.civId)) pop=\(city.population) goldNext=\(civ(city.civId)?.statsForNextTurn?.gold ?? -999) happy=\(happiness(of: city.civId)) perpetual=\(city.currentProduction == nil) y=\(y)") }
        // Apply City focus (Unciv CityFocus.getStatMultiplier): `currentStat * statMultiplier` is Float * Float; both are
        // Float values, so the Double product is exact and one f32 rounding gives Kotlin's result
        for (stat, mf) in focus(of: city).multipliers {
            let m = Double(mf)
            switch stat {
            case "Food": y.food = Stats.f32(y.food * m); case "Production": y.production = Stats.f32(y.production * m)
            case "Gold": y.gold = Stats.f32(y.gold * m); case "Science": y.science = Stats.f32(y.science * m)
            case "Culture": y.culture = Stats.f32(y.culture * m); case "Happiness": y.happiness = Stats.f32(y.happiness * m)
            case "Faith": y.faith = Stats.f32(y.faith * m); default: break
            }
        }
        return y.sum
    }

    /// Unciv Automation.rankSpecialist
    func rankSpecialist(_ name: String, city: City, current: CityStats) -> Double {
        guard let sp = rs.specialists[name] else { return 0 }
        // Unciv CityStats.getStatsOfSpecialist: base stats plus "[stats] from every specialist [cityFilter]" bonuses.
        var stats = sp.stats
        for u in cityUniques(city) where (u.pattern == "[] from every specialist []" || u.pattern == "[] from every specialist") && scopeIncludes(u, city: city) { if let st = u.stats { stats += st } }
        for u in cityUniques(city) where u.pattern == "[] from every []" && u.param(1) == name && scopeIncludes(u, city: city) { if let st = u.stats { stats += st } }   // Unciv StatsFromObject
        var rank = rankStatsForCityWork(stats, city: city, current: current, specialist: true)
        if ProcessInfo.processInfo.environment["WT_CITY"] == city.name { print("SPECE \(name) stats=\(stats) rankStats=\(Float(rank))") }
        // Unciv: `gpp = gpp * (100 + city.currentGPPBonus) / 100` then `rank += gpp` - Float at every step. The bonus is
        // the STORED field autoAssignPopulation last wrote; ours recomputed it live on every call, so the unassignment
        // (which never refreshes it) ranked with a Garden, a policy or a friendship Unciv's field did not hold yet.
        var gpp = Double(sp.greatPersonPoints.values.reduce(0, +))
        gpp = Stats.f32(Stats.f32(gpp * Double(100 + city.currentGPPBonus)) / 100)
        rank = Stats.f32(rank + gpp)
        return rank
    }

    /// Unciv City.reassignPopulationDeferred: at once for a human player (`civ.isCurrentPlayer() && civ.isHuman()` - a human
    /// under AutoPlay too: a policy, a tile or a purchase its automation makes reassigns at once), otherwise at the next
    /// turn start; the headless run plays the player as an AI. isCurrentPlayer is `gameInfo.currentPlayerCiv == this`,
    /// which GameInfo.nextTurn sets only when the walk stops at the next human: through the AIs' turns that follow a
    /// human's it is still that human's, and a hot-seat human whose turn it is not waits for its turn start.
    func reassignPopulationDeferred(_ ci: Int) {
        guard cities.indices.contains(ci) else { return }
        if civ(cities[ci].civId)?.isPlayer == true && !epochsAutoplay && cities[ci].civId == currentHumanId { assignWorkers(cityId: cities[ci].id, why: "CityPopulationManager:18100") } else { cities[ci].shouldReassignPopulation = true }
    }

    /// Unciv City.lockTile / unlockTile: only a worked tile can be locked, and citizens are not reassigned
    func toggleLockedTile(cityId: Int, _ c: HexCoord) {
        guard let ci = cityIndex(cityId), c != cities[ci].coord else { return }
        if cities[ci].lockedTiles.contains(c) { cities[ci].lockedTiles.remove(c) }
        else if cities[ci].workedTiles.contains(c) { cities[ci].lockedTiles.insert(c) }
    }

    /// Unciv CityScreen.tileWorkedIconOnClick on a workable tile: work it while a citizen is free and it yields nothing yet,
    /// otherwise stop working it (City.workTile / stopWorkingTile)
    func toggleWorkedTile(cityId: Int, _ c: HexCoord) {
        guard let ci = cityIndex(cityId), !cities[ci].isPuppet, c != cities[ci].coord, let t = map[c], t.ownerCivId == cities[ci].civId,
              map.tilesWithin(cities[ci].coord, radius: rs.constants.cityWorkRange).contains(c), !isBlockaded(c, for: cities[ci].civId),
              // CityTileGroup.update's WORKABLE: not worked by another city, with a yield (getTileStats(viewingCiv, cityView))
              t.workingCityId == nil || t.workingCityId == cityId, !tileStats(t, civId: cities[ci].civId, city: cities[ci]).isEmpty else { return }
        let city = cities[ci]
        let free = city.population - city.workedTiles.count - city.specialists.values.reduce(0, +)
        if !tileProvidesYield(t) && free > 0 {
            cities[ci].workedTilesWithItem(c, walk: workedTilesWalk(cities[ci])); map[c]?.workingCityId = cityId   // city.workTile
        } else if city.workedTiles.contains(c) {
            cities[ci].lockedTiles.remove(c); cities[ci].workedTilesWithoutItem(c, walk: workedTilesWalk(cities[ci])); map[c]?.workingCityId = nil   // city.stopWorkingTile
        }
        invalidateHappiness(city.civId)
        // Unciv tileWorkedIconOnClick: `cityView.updateCityStats()` (CityStats.update()) after either branch
        updateCityStats(cityId, reason: "CityScreen.tileWorkedIconOnClick")
    }
}

// MARK: - Unciv CityScreenTileTable.TileBuyMenu: buy every purchasable tile of a ring at once
extension GameState {
}
