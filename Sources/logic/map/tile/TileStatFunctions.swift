// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/map/tile/TileStatFunctions.kt`: what one tile is worth to the city working it.
///
/// Unciv's `Stats` are Float. Every sum and product below is rounded to Float after each operation (`Stats.f32`),
/// entry by entry in Unciv's order, so a percentage that is not a power of two lands on the same value.
extension GameState {
    // MARK: tile yields with owner's tech knowledge
    /// Unciv TileStatFunctions.getTileStats(observingCiv) = getTileStats(tile.getCity(), observingCiv)
    func yields(of tile: Tile, for civId: Int) -> Stats { tileStats(tile, civId: civId, city: owningCity(tile.coord)) }

    /// City uniques that change tile yields, in scope and with their conditionals holding for the city (no tile).
    /// Used as a cheap "can any unique here yield happiness" test; the stats themselves are `tileStats`.
    func cityTileUniques(_ city: City) -> [Unique] {
        let ctx = UniqueContext(civId: city.civId, city: city)
        let patterns: Set<String> = ["[] from [] tiles []", "[] from every []", "[] from [] tiles without [] []", "[]% [] from every []", "[]% Yield from every []"]
        return cityUniques(city).filter { patterns.contains($0.pattern) && scopeIncludes($0, city: city) && conditionalsHold($0, ctx) }
    }

    /// Unciv City.forEachMatchingUnique(type, gameContext): the civ's uniques first, then the city's own
    /// (local building uniques and religion), each with its conditionals judged in `ctx`.
    private func cityMatchingUniques(_ city: City, _ pattern: String, _ ctx: UniqueContext) -> [Unique] {
        // cityUniques(city) holds the same two pools the other way round (local first); Unciv walks the civ's first.
        var local: [Unique] = []
        for b in city.buildings { local += (rs.buildings[b]?.uniqueObjects ?? []).filter { $0.isLocalEffect }.from(rs.buildings[b]?.isAnyWonder == true ? .wonder : .building, b) }
        local += religionUniques(for: city)
        local = multiplied(local, UniqueContext(civId: city.civId, city: city))
        let civ = civUniques(city.civId).filter { !$0.isLocalEffect }
        return (civ + local).filter { $0.pattern == pattern && conditionalsHold($0, ctx) }
    }

    // MARK: Float helpers (Unciv Stats.add / times)
    private static func addF(_ a: Stats, _ b: Stats) -> Stats {
        Stats(food: Stats.f32(a.food + b.food), production: Stats.f32(a.production + b.production), gold: Stats.f32(a.gold + b.gold),
              science: Stats.f32(a.science + b.science), culture: Stats.f32(a.culture + b.culture),
              happiness: Stats.f32(a.happiness + b.happiness), faith: Stats.f32(a.faith + b.faith))
    }
    private static func timesF(_ a: Stats, _ k: Double) -> Stats {
        let k = Stats.f32(k)
        return Stats(food: Stats.f32(a.food * k), production: Stats.f32(a.production * k), gold: Stats.f32(a.gold * k),
                     science: Stats.f32(a.science * k), culture: Stats.f32(a.culture * k),
                     happiness: Stats.f32(a.happiness * k), faith: Stats.f32(a.faith * k))
    }
    /// Unciv `List<Pair<String, Stats>>.toStats()`: a fresh Stats, each entry added in order.
    private static func toStats(_ list: [(String, Stats)]) -> Stats { list.reduce(Stats()) { addF($0, $1.1) } }
    private static let tileStatOrder = ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith"]   // Unciv Stat.entries

    /// Unciv TileStatFunctions.getTileStats(city, observingCiv): the breakdown, each entry multiplied by the
    /// percentage of its category - the improvement's, the road's, or the terrain's for everything else - then summed.
    func tileStats(_ tile: Tile, civId: Int, city: City?) -> Stats {
        let umT = UIMeasure.start(); defer { UIMeasure.stop("tileStats", umT) }
        let breakdown = tileStatsBreakdown(tile, civId: civId, city: city)
        let improvement = tile.pillaged ? nil : tile.improvement   // Unciv tile.getUnpillagedImprovement()
        let road = tile.roadPillaged || !(tile.roads || tile.railroad) ? "None" : tile.railroad ? "Railroad" : "Road"   // getUnpillagedRoad().name
        let pct = tilePercentageStats(tile, civId: civId, city: city)
        var total = Stats()
        for (cause, stats) in breakdown {
            let p = cause == improvement ? pct.improvement : cause == road ? pct.road : pct.terrain
            var s = stats
            for stat in GameState.tileStatOrder where p[stat] != 0 {   // Unciv iterates the non-zero percentages
                s[stat] = Stats.f32(s[stat] * Stats.toPercent(p[stat]))
            }
            total = GameState.addF(total, s)
        }
        return total
    }

    /// Unciv TileStatFunctions.getTileStatsBreakdown
    func tileStatsBreakdown(_ tile: Tile, civId: Int, city: City?) -> [(String, Stats)] {
        let observing = civ(civId)
        let ctx = UniqueContext(civId: civId, city: city, tile: tile)
        var list = terrainStatsBreakdown(tile, ctx)

        let otherYieldsIgnored = allTerrainsOf(tile).contains { t in t.uniqueObjects.contains { $0.pattern == "Nullifies all other stats this tile provides" && conditionalsHold($0, ctx) } }
        let improvement: ImprovementDef? = otherYieldsIgnored || tile.pillaged ? nil : tile.improvement.flatMap { rs.improvements[$0] }
        var improvementStats = improvement?.stats.f32 ?? Stats()
        let road: ImprovementDef? = otherYieldsIgnored || tile.roadPillaged || !(tile.roads || tile.railroad) ? nil : rs.improvements[tile.railroad ? "Railroad" : "Road"]
        var roadStats = road?.stats.f32 ?? Stats()

        if let city {
            func addStats(_ unique: Unique) {
                guard let st = unique.stats else { return }
                let tileType = unique.param(1)
                if let improvement, improvement.matchesFilter(tileType) { improvementStats = GameState.addF(improvementStats, st) }
                else if tileMatches(tile, tileType, civId: civId) { list.append(("{\(unique.sourceObjectName ?? "")} ({\(unique.text)})", st.f32)) }
                else if let road, road.matchesFilter(tileType) { roadStats = GameState.addF(roadStats, st) }
            }
            for u in cityMatchingUniques(city, "[] from [] tiles []", ctx) where cityMatchesFilter(u.param(2), city: city, viewer: city.civId) { addStats(u) }
            for u in cityMatchingUniques(city, "[] from every []", ctx) { addStats(u) }
            for u in cityMatchingUniques(city, "[] from [] tiles without [] []", ctx)
                where cityMatchesFilter(u.param(3), city: city, viewer: city.civId) && !tileMatches(tile, u.param(2), civId: -1) { addStats(u) }
        }

        if tile.riverAdjacent {
            if let river = rs.terrains["River"] { list += singleTerrainStats(river, ctx) }
            else { list.append(("River", Stats(gold: 1))) }   // Fallback for legacy mods
        }

        var minimumStats = tile.isCityCenter ? Stats(food: 2, production: 1) : Stats()   // Unciv Stats.DefaultCityCenterMinimum
        if observing != nil {
            // resource base
            if canSeeResource(tile.resource, civId: civId), let r = tile.resource.flatMap({ rs.resources[$0] }) { list.append((r.name, r.stats.f32)) }
            if let improvement { improvementStats = GameState.addF(improvementStats, extraImprovementStats(tile, improvement, civId: civId, city: city)) }
            if let road { roadStats = GameState.addF(roadStats, extraImprovementStats(tile, road, civId: civId, city: city)) }
            if let improvement, let ensure = improvement.uniqueObjects.first(where: { $0.pattern == "Ensures a minimum tile yield of []" && conditionalsHold($0, ctx) }), let m = ensure.stats {
                minimumStats = m
            }
        }

        if let road { list.append((road.name, roadStats)) }
        if let improvement { list.append((improvement.name, improvementStats)) }

        let current = GameState.toStats(list)
        var missing = Stats()   // Unciv missingFromMinimum: every stat, zeros included
        for stat in GameState.tileStatOrder where current[stat] < minimumStats[stat] { missing[stat] = Stats.f32(minimumStats[stat] - current[stat]) }
        list.append(("Minimum", missing))

        if let c = observing, GameState.toStats(list).gold != 0, c.isInGoldenAge { list.append(("Golden Age", Stats(gold: 1))) }

        return list.filter { !$0.1.isEmpty }
    }

    /// Unciv TileStatFunctions.getSingleTerrainStats: the terrain's own stats, then each of its Stats uniques.
    private func singleTerrainStats(_ terrain: Terrain, _ ctx: UniqueContext) -> [(String, Stats)] {
        var out: [(String, Stats)] = [(terrain.name, terrain.stats.f32)]
        for u in terrain.uniqueObjects where u.pattern == "[]" && conditionalsHold(u, ctx) {
            if let st = u.stats { out.append((terrain.name + ": " + u.text, st.f32)) }
        }
        return out
    }

    /// Unciv TileStatFunctions.getTerrainStatsBreakdown: base, natural wonder, features - a nullifying terrain
    /// alone, an overriding one replacing everything before it.
    func terrainStatsBreakdown(_ tile: Tile, _ ctx: UniqueContext) -> [(String, Stats)] {
        var list: [(String, Stats)] = []
        for terrain in allTerrainsOf(tile) {
            let terrainStats = singleTerrainStats(terrain, ctx)
            if terrain.uniqueObjects.contains(where: { $0.pattern == "Nullifies all other stats this tile provides" && conditionalsHold($0, ctx) }) { return terrainStats }
            if terrain.overrideStats { list = terrainStats } else { list += terrainStats }
        }
        return list
    }

    /// Unciv TileStatFunctions.getTilePercentageStats: StatPercentFromObject / AllStatsPercentFromObject, each
    /// filed under the improvement if it matches, else the tile, else the road. The city's uniques when there is a
    /// city, otherwise the observing civ's.
    func tilePercentageStats(_ tile: Tile, civId: Int, city: City?) -> (terrain: Stats, improvement: Stats, road: Stats) {
        var terrainStats = Stats(), improvementStats = Stats(), roadStats = Stats()
        let ctx = UniqueContext(civId: civId, city: city, tile: tile)
        let improvement: ImprovementDef? = tile.pillaged ? nil : tile.improvement.flatMap { rs.improvements[$0] }
        let road: ImprovementDef? = tile.roadPillaged || !(tile.roads || tile.railroad) ? nil : rs.improvements[tile.railroad ? "Railroad" : "Road"]
        func addStats(_ filter: String, _ stat: String, _ amount: Double) {
            if let improvement, improvement.matchesFilter(filter) { improvementStats[stat] = Stats.f32(improvementStats[stat] + amount) }
            else if tileMatches(tile, filter, civId: civId) { terrainStats[stat] = Stats.f32(terrainStats[stat] + amount) }
            else if let road, road.matchesFilter(filter) { roadStats[stat] = Stats.f32(roadStats[stat] + amount) }
        }
        let statPercent: [Unique], allPercent: [Unique]
        if let city {
            statPercent = cityMatchingUniques(city, "[]% [] from every []", ctx)
            allPercent = cityMatchingUniques(city, "[]% Yield from every []", ctx)
        } else if civ(civId) != nil {
            statPercent = civUniques(civId).filter { $0.pattern == "[]% [] from every []" && conditionalsHold($0, ctx) }
            allPercent = civUniques(civId).filter { $0.pattern == "[]% Yield from every []" && conditionalsHold($0, ctx) }
        } else { statPercent = []; allPercent = [] }
        for u in statPercent where GameState.tileStatOrder.contains(u.param(1)) { addStats(u.param(2), u.param(1), Stats.f32(u.double(0))) }
        for u in allPercent { for stat in GameState.tileStatOrder { addStats(u.param(1), stat, Stats.f32(u.double(0))) } }
        return (terrainStats, improvementStats, roadStats)
    }

    /// Unciv TileStatFunctions.getExtraImprovementStats: the resource's improvement bonus, the improvement's Stats
    /// uniques, "[] for each adjacent []" and "[] from [] tiles" (fresh water spelled out).
    private func extraImprovementStats(_ tile: Tile, _ improvement: ImprovementDef, civId: Int, city: City?) -> Stats {
        var stats = Stats()
        if canSeeResource(tile.resource, civId: civId), let res = tile.resource, let r = rs.resources[res],
           rs.resourceImprovements[res]?.contains(improvement.name) == true {
            stats = GameState.addF(stats, r.improvementStats)   // resource-specific improvement
        }
        let ctx = UniqueContext(civId: civId, city: city, tile: tile)
        for u in improvement.uniqueObjects where u.pattern == "[]" && conditionalsHold(u, ctx) {
            if let st = u.stats { stats = GameState.addF(stats, st) }
        }
        for u in improvement.uniqueObjects where u.pattern == "[] for each adjacent []" && conditionalsHold(u, ctx) {
            guard let st = u.stats else { continue }
            let adjacent = u.param(1)
            let n = map.neighbors(of: tile.coord).filter { c in
                guard let nt = map[c] else { return false }
                let roadName = nt.roadPillaged || !(nt.roads || nt.railroad) ? "None" : nt.railroad ? "Railroad" : "Road"   // getUnpillagedRoad().name
                return tileMatches(nt, adjacent, civId: civId) || roadName == adjacent
            }.count
            stats = GameState.addF(stats, GameState.timesF(st, Double(n)))
        }
        for u in improvement.uniqueObjects where u.pattern == "[] from [] tiles" && conditionalsHold(u, ctx) {
            guard let st = u.stats else { continue }
            let f = u.param(1)
            if tileMatches(tile, f, civId: -1)
                || (f == "Fresh water" && isAdjacentTo(tile, "Fresh water"))
                || (f == "non-fresh water" && !isAdjacentTo(tile, "Fresh water")) {
                stats = GameState.addF(stats, st)
            }
        }
        return stats
    }
}
