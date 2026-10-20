// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct Tile: Codable {
    let coord: HexCoord
    var baseTerrain: String
    var features: [String] = []          // e.g. Hill, Forest, Jungle, Marsh, Oasis, Flood plains
    var resource: String? = nil
    @Lenient var resourceAmount: Int = 0     // Unciv Tile.resourceAmount (strategic deposits)
    var improvement: String? = nil
    var improvementInProgress: String? = nil
    var improvementTurnsLeft: Int = 0
    @Lenient var queuedImprovement: String? = nil      // Unciv Tile.improvementQueue[1]
    @Lenient var queuedImprovementTurns: Int = 0
    var roads: Bool = false
    @Lenient var railroad: Bool = false
    var ownerCivId: Int? = nil
    var cityId: Int? = nil               // set on the city-center tile
    var workingCityId: Int? = nil        // city currently working this tile
    var pillaged: Bool = false               // Unciv improvementIsPillaged
    @Lenient var roadPillaged: Bool = false  // Unciv roadIsPillaged: roads are pillaged separately from the improvement
    @Lenient var roadOwner: Int? = nil   // Unciv Tile.roadOwner: who built the road (getRoadOwner falls back to the tile owner)
    var naturalWonder: String? = nil
    var riverEdges: Set<Int> = []          // directions SE(0), SW(4), S(5) owned by this tile
    var riverAdjacent: Bool = false        // precomputed: any of the six edges carries a river
    @Lenient var history: [Int: TileHistoryEntry] = [:]   // Unciv TileHistory: turn -> owner / city-centre state
    /// Unciv Tile.continent: written once by TileMap.assignContinents during map generation (after the ice, before
    /// rivers and natural wonders) and saved with the tile. Optional so that saves from before it load as -1.
    @Lenient var storedContinent: Int? = nil
    /// Unciv Tile.getContinent(): -1 for water and for land that was impassable when continents were assigned.
    var continent: Int {
        get { storedContinent ?? -1 }
        set { storedContinent = newValue == -1 ? nil : newValue }
    }

    var isWater: Bool { Ruleset.shared.terrains[baseTerrain]?.type == .water }
    var isLand: Bool { !isWater }
    var isHill: Bool { features.contains("Hill") }
    var isMountain: Bool { baseTerrain == "Mountain" }
    var hasForestOrJungle: Bool { features.contains("Forest") || features.contains("Jungle") }
    var isCityCenter: Bool { cityId != nil }

    /// Unciv Tile.canPillageTileImprovement / canPillageRoad / getImprovementToPillage
    var canPillageImprovement: Bool {
        guard let imp = improvement, !pillaged, let def = Ruleset.shared.improvements[imp] else { return false }
        return !def.uniques.contains("Unpillagable") && !def.uniques.contains("Irremovable")
    }
    var canPillageRoad: Bool {
        guard roads || railroad, !roadPillaged else { return false }
        let def = Ruleset.shared.improvements[railroad ? "Railroad" : "Road"]
        return !(def?.uniques.contains("Unpillagable") ?? false) && !(def?.uniques.contains("Irremovable") ?? false)
    }
    var improvementToPillage: String? { canPillageImprovement ? improvement : canPillageRoad ? (railroad ? "Railroad" : "Road") : nil }
    var canPillageTile: Bool { canPillageImprovement || canPillageRoad }
    var isImpassable: Bool {
        let rs = Ruleset.shared
        if rs.terrains[baseTerrain]?.impassable == true { return true }
        if naturalWonder != nil { return true }
        return features.contains { rs.terrains[$0]?.impassable == true }
    }
    /// Unciv Tile.isRough: baseTerrainObject.isRough || terrainFeatureObjects.any { it.isRough } — the ruleset's "Rough terrain" unique decides
    var isRough: Bool {
        let rs = Ruleset.shared
        return terrainNames.contains { rs.terrains[$0]?.isRough ?? false }
    }
    var isCoastal: Bool { baseTerrain == "Coast" }
    /// Land tile next to a Coast tile (set by the caller-side helper below; GameMap knows the neighbours).
    var coastalLand: Bool { GameMap.coastalLandLookup?(coord) ?? false }
    var hasBarbarianCamp: Bool { improvement == Names.barbarianCamp || (improvement.flatMap { Ruleset.shared.improvements[$0]?.uniques.contains("Marks a barbarian camp") } ?? false) }
    var hasRuins: Bool { improvement == Names.ancientRuins || (improvement.flatMap { Ruleset.shared.improvements[$0]?.uniques.contains("Provides a random bonus when entered") } ?? false) }

    /// Unciv Tile.getDefensiveBonus(includeImprovementBonus = false): the base terrain, replaced by the strongest nonzero
    /// feature, plus the natural wonder - in Float, as Unciv's `defenceBonus: Float` (Marsh's -0.15 is not the Double).
    var defenceBonusWithoutImprovement: Double { Double(defensiveBonusF(includeImprovementBonus: false)) }
    /// Unciv Tile.getDefensiveBonus(): with the unpillaged improvement's "Gives a defensive bonus of []%".
    var defenceBonus: Double { Double(defensiveBonusF(includeImprovementBonus: true)) }
    func defensiveBonusF(includeImprovementBonus: Bool) -> Float {
        let rs = Ruleset.shared
        var bonus = Float(rs.terrains[baseTerrain]?.defenceBonus ?? 0)
        if !features.isEmpty {
            let other = features.map { Float(rs.terrains[$0]?.defenceBonus ?? 0) }.max() ?? 0
            if other != 0 { bonus = other }   // replaces the base terrain's
        }
        if let w = naturalWonder { bonus += Float(rs.terrains[w]?.defenceBonus ?? 0) }
        if includeImprovementBonus, let imp = improvement, !pillaged, let def = rs.improvements[imp] {
            for u in def.uniqueObjects where u.pattern == "Gives a defensive bonus of []%" { bonus += Float(u.double(0)) / 100 }
        }
        return bonus
    }

    /// Terrain names (base + features) used for "can build on" checks.
    var terrainNames: [String] { [baseTerrain] + features }
    /// Unciv Tile.lastTerrain.name: the last feature, else the natural wonder, else the base terrain
    var lastTerrainName: String { features.last ?? naturalWonder ?? baseTerrain }

    /// Combined base yield: base terrain, then features (overriding or adding), then resource, then improvement.
    func yields(knownTechs: Set<String>) -> Stats {
        let rs = Ruleset.shared
        var stats = rs.terrains[baseTerrain]?.stats ?? .zero
        if let nw = naturalWonder, let t = rs.terrains[nw] { stats = t.stats }
        if riverAdjacent, isLand, let river = rs.terrains["River"] { stats += river.stats }
        for f in features {
            guard let t = rs.terrains[f] else { continue }
            if t.overrideStats { stats = t.stats } else { stats += t.stats }
        }
        if let res = resource, let r = rs.resources[res] {
            if r.revealedBy == nil || knownTechs.contains(r.revealedBy!) { stats += r.stats }
        }
        if let imp = improvement, let i = rs.improvements[imp], !pillaged {
            stats += i.stats
            if let res = resource, let r = rs.resources[res], rs.resourceImprovements[res]?.contains(imp) == true { stats += r.improvementStats }
            // "[+1 Food] from [Fresh water] tiles <after discovering [Chancery]>" style tech-gated bonuses
            for u in i.uniqueObjects where u.pattern == "[]" || u.pattern == "[] from [] tiles" {
                if let after = u.conditional("after discovering []"), !knownTechs.contains(after.param(0)) { continue }
                if u.pattern == "[]", u.conditionals.contains(where: { $0.pattern == "after discovering []" }), let st = u.stats { stats += st }
            }
        }
        // "Nullifies all other stats this tile provides" (e.g. Fallout-like wonders)
        for f in features where rs.terrains[f]?.uniques.contains("Nullifies all other stats this tile provides") == true { stats = rs.terrains[f]!.stats }
        if let imp = improvement, let i = rs.improvements[imp], !pillaged {
            // "Ensures a minimum tile yield of [+2 Food, +1 Production]"
            for u in i.uniqueObjects where u.pattern == "Ensures a minimum tile yield of []" {
                guard let m = u.stats else { continue }
                stats.food = max(stats.food, m.food); stats.production = max(stats.production, m.production); stats.gold = max(stats.gold, m.gold)
                stats.science = max(stats.science, m.science); stats.culture = max(stats.culture, m.culture); stats.faith = max(stats.faith, m.faith)
            }
        }
        if isCityCenter {
            stats.food = max(stats.food, 2); stats.production = max(stats.production, 1)
        }
        return stats
    }

    /// Improvements a worker could build here, judged without a civ beyond its techs and nation - for the
    /// improvement picker's "what if I researched it" probe only. Game logic asks GameState.buildableImprovements /
    /// canBuildImprovement (TileImprovementFunctions.swift), Unciv's getImprovementBuildingProblems.
    func buildableImprovements(knownTechs: Set<String>, nation: String? = nil, freshWater: Bool? = nil) -> [ImprovementDef] {
        let rs = Ruleset.shared
        // Water belongs here too: Fishing Boats lists Coast, Offshore Platform is water-only, and Unciv's
        // canBuildImprovement makes no such distinction. Excluding water meant this returned an empty list for
        // every sea tile, which made hasWorkableSeaResource unable to ever answer yes - so a Work Boats never
        // found the whales beside its own city and wandered off instead of improving them.
        guard !isCityCenter, !isMountain, naturalWonder == nil else { return [] }
        /// Unciv tileFilter for improvement uniques: a terrain name, Land / Water / Coastal / Hill, or a resource type
        func matchesImprovementFilter(_ f: String) -> Bool {
            switch f {
            case "Water": return isWater
            case "Land": return isLand
            case "Coastal": return isLand && coastalLand
            case "Hill": return isHill
            default: break
            }
            if f.hasSuffix(" resource") { return resource.flatMap { rs.resources[$0]?.resourceType } == String(f.dropLast(9)) }
            return terrainNames.contains(f)
        }
        return rs.improvements.values.filter { imp in
            guard imp.isWorkerBuildable else { return false }
            // Unciv ImprovementBuildingProblem.WrongCiv: Moai is Polynesia's, the Terrace farm the Inca's.
            if let owner = imp.uniqueTo, owner != nation { return false }
            if let tech = imp.techRequired, !knownTechs.contains(tech) { return false }
            if imp.name == improvement { return false }   // Unciv canImprovementBeBuiltHere: `improvement.name == tile.improvement -> false`, pillaged or not
            if let cur = improvement, cur != imp.name, rs.improvements[cur]?.uniques.contains("Irremovable") == true, !imp.name.hasPrefix("Remove ") { return false }
            if imp.isGreatImprovement { return false }
            if imp.name == "Road" { return !roads }
            if imp.name == "Railroad" { return !railroad }
            if imp.name == "Remove Road" { return roads && !railroad }
            if imp.name == "Remove Railroad" { return railroad }
            if imp.name.hasPrefix("Remove ") { return features.contains(String(imp.name.dropFirst(7))) }
            // Unciv CanOnlyBeBuiltOnTile
            for u in imp.uniqueObjects where u.pattern == "Can only be built on [] tiles" {
                if !matchesImprovementFilter(u.param(0)) { return false }
            }
            // Resource-specific improvements (Camp/Plantation/Quarry/Pasture) must match the tile resource. This
            // used to return true on the spot, which skipped every rule below it - so a Plantation went up on
            // jungle, where Unciv requires the jungle cleared first and a worker without Bronze Working has no
            // work to do at all. Matching the resource excuses the improvement from needing the terrain listed,
            // and nothing else.
            // Unciv ImprovementFunctions: canImprovementBeBuiltHere(improvement, civInfo.canSeeResource(tile.tileResource)) -
            // a resource the civ has not revealed yet (Coal before Industrialization) excuses nothing: no Mine goes on
            // a flat Grassland because Coal lies hidden under it.
            let resourceIsVisible = resource.flatMap { rs.resources[$0] }.map { $0.revealedBy == nil || knownTechs.contains($0.revealedBy!) } ?? false
            let improvesThisResource = resourceIsVisible && (resource.flatMap { rs.resourceImprovements[$0]?.contains(imp.name) } ?? false)
            // Unciv CanOnlyImproveResource: a visible resource this improvement improves, or nothing
            if imp.uniques.contains("Can only be built to improve a resource") && !improvesThisResource { return false }
            // Unciv canBeBuiltOnThisUnbuildableTerrain / isAllowedOnFeature: an unbuildable top terrain blocks
            // anything the improvement is not explicitly allowed on - its own removal, a terrain it lists, or a
            // "Does not need removal of []" that names it.
            if let last = terrainNames.last, rs.terrains[last]?.unbuildable == true,
               imp.name != "Remove " + last, !imp.terrainsCanBeBuiltOn.contains(last),
               !imp.uniqueObjects.contains(where: { $0.pattern == "Does not need removal of []" && $0.param(0) == last }),
               !imp.uniqueObjects.contains(where: { $0.pattern == "Can only be built on [] tiles" && $0.param(0) == last }) { return false }
            // Unciv RestrictedBuildableImprovements: "Only [x] improvements may be built on this tile"
            for t in terrainNames {
                for u in rs.terrains[t]?.uniqueObjects ?? [] where u.pattern == "Only [] improvements may be built on this tile" {
                    let allowed = u.param(0)
                    if !(allowed == "All Road" ? (imp.name == "Road" || imp.name == "Railroad") : imp.name == allowed) { return false }
                }
            }
            // Unciv canImprovementBeBuiltHere ends with these branches, in this order:
            //   isAllowedOnFeature(lastTerrain) | Land | Water | "adjacent to fresh water" | improves the resource
            // `lastTerrain` is the TOP terrain - the last feature, else the natural wonder, else the base - not any
            // of them. Matching any of them let a Farm onto a forested grassland by naming the grassland, and the
            // two guards bolted on to stop that ("not a hill", and a hard-coded "no Farm on a hill") then blocked
            // the case Unciv actually allows: a hill farm next to fresh water. Neither guard exists in Unciv.
            let lastTerrain = lastTerrainName
            var matches = imp.terrainsCanBeBuiltOn.contains(lastTerrain)
            if !matches, isLand, imp.terrainsCanBeBuiltOn.contains("Land") { matches = true }
            if !matches, isWater, imp.terrainsCanBeBuiltOn.contains("Water") { matches = true }
            // Unciv ImprovementBuildableByFreshWater + Tile.isAdjacentTo(freshWater): the tile's own river edges OR
            // a neighbouring lake or oasis. The neighbours need the map, so callers that have one pass the answer in;
            // without it a hill beside a lake refused the Farm that Unciv builds there and took a Mine instead.
            if !matches, freshWater ?? riverAdjacent, imp.uniques.contains("Can also be built on tiles adjacent to fresh water") { matches = true }
            if !matches, improvesThisResource { matches = true }
            for u in imp.uniqueObjects where u.pattern == "Cannot be built on [] tiles" { if matchesImprovementFilter(u.param(0)) { return false } }   // Unciv CannotBuildOnTile
            if !matches { return false }
            // Features block generic improvements unless the improvement can sit on them or does not need their removal.
            let tolerates = imp.uniqueObjects.contains { u in u.pattern == "Does not need removal of []" && features.contains(u.param(0)) }
            if hasForestOrJungle && !tolerates && !imp.terrainsCanBeBuiltOn.contains(where: { $0 == "Forest" || $0 == "Jungle" }) { return false }
            return true
        }.sorted { $0.name < $1.name }
    }
}

struct GameMap: Codable {
    /// Tile.coastalLand needs neighbours; the active map registers itself here.
    nonisolated(unsafe) static var coastalLandLookup: ((HexCoord) -> Bool)? = nil
    let width: Int
    let height: Int
    var tiles: [Tile]                    // odd-q offset order, row-major
    var wrapX: Bool = false              // world wrap: the east edge joins the west edge
    var hexRadius: Int? = nil            // Unciv MapShape.hexagonal: the map's radius (the grid cells outside it are `missing`; old saves kept them as padding)
    /// Cells of the rectangle that are not tiles of the real map.
    ///
    /// Unciv's tileMap is a map from position to tile and a hexagonal map simply has no entry outside its radius.
    /// Ours is a rectangle, and importing a hexagonal save filled the corners with Ocean tiles that then answered
    /// `contains` with yes. A settler scoring where to explore counted five unexplored tiles around a coastal hex
    /// where Unciv counted one, because four of them were off the edge of Unciv's world.
    var missing: Set<Int> = []
    /// Indices into `tiles` in Unciv's `tileList` order - the order a save file lists them in, which is the
    /// order `tileMap.values` iterates. Several rules read the map through that sequence and take the first
    /// occurrence of something (`mapNotNull { it.tileResource }.distinct()`), so the order is the answer, not
    /// a detail. A generated map gets the order its TileMap constructor builds (`init(uncivPositions:)`); it is
    /// empty only on maps saved before it was kept, and `tilesInUncivOrder` then falls back to our own order.
    var uncivOrder: [Int] = []
    /// Unciv TileMap.continentSizes (continent id -> tile count). @Transient there and here: not saved, filled by
    /// `assignContinents` - at generation by Assign, after a load by the first Ensure.
    var continentSizes: [Int: Int] = [:]
    /// Unciv TileMap.mapParameters' mapSize and shape (nil on maps saved before it was kept).
    var uncivSize: UncivMapSize? = nil
    /// Unciv tileMap.values: the tile list in file order.
    func tilesInUncivOrder() -> [Tile] { uncivOrder.isEmpty ? tiles : uncivOrder.map { tiles[$0] } }

    /// Unciv Tile._isAdjacentToCoast: `by lazy { neighbors.any { it.getBaseTerrain().isCoast } }` - worked out on a
    /// tile's first read and kept, so a coast a natural wonder makes afterwards is not seen. Unciv only starts over with
    /// fresh Tile objects: a loaded game (this cache is not saved) and the clone WorldScreen.nextTurn plays each turn on
    /// (`resetCoastAdjacency`). A class, so every copy of this map value shares it, as the one tileMap does.
    final class CoastAdjacencyCache { var values: [Int8] = [] }
    private var coastAdjacency = CoastAdjacencyCache()
    /// Unciv Tile.isAdjacentToCoast(): `isLand && _isAdjacentToCoast` - a water tile never fills its lazy
    func isAdjacentToCoast(_ c: HexCoord) -> Bool {
        guard let i = index(of: c), tiles[i].isLand else { return false }
        if coastAdjacency.values.count != tiles.count { coastAdjacency.values = Array(repeating: -1, count: tiles.count) }
        if coastAdjacency.values[i] >= 0 { return coastAdjacency.values[i] == 1 }
        let rs = Ruleset.shared
        let value = neighbors(of: c).contains { self[$0].flatMap { rs.terrains[$0.baseTerrain] }?.isCoast ?? false }
        coastAdjacency.values[i] = value ? 1 : 0
        return value
    }
    /// Unciv WorldScreen.nextTurn plays the turn on `gameInfo.clone()`, whose fresh tiles work their lazies out again.
    func resetCoastAdjacency() { coastAdjacency.values = [] }
    /// Unciv tileMap.values.size: a hexagonal map has getNumberOfTilesInHexagon(radius) tiles
    var realTileCount: Int { missing.isEmpty ? (hexRadius.map { 1 + 3 * $0 * ($0 + 1) } ?? tiles.count) : tiles.count - missing.count }

    /// Unciv Tile.neighbors is a list built once per tile and kept. Ours rebuilt it on every lookup -
    /// three array allocations and eighteen coordinate conversions deep - and the pathfinding inner
    /// loop asks for it once per visited tile.
    private var neighborTable: [[HexCoord]] = []

    init(width: Int, height: Int, tiles: [Tile], wrapX: Bool = false) {
        self.width = width; self.height = height; self.tiles = tiles; self.wrapX = wrapX
        buildNeighborTable()
    }

    /// Unciv TileMap(radius, …) / TileMap(width, height, …): exactly the tiles at these Unciv positions, `uncivOrder`
    /// being their tileList order. They are laid into our offset grid the way an imported save's are
    /// (UncivSave.frame(for:)), so `Frame.forExport(width:height:)` of the grid gives every position back; a grid cell no
    /// position lands on is `missing`. A wrapping map keeps its even column count: when the import frame would add an
    /// empty column to keep the column shift even, that column is dropped and the last Unciv column wraps into column 0
    /// (every other place already reads such a grid through `forExport` and `normalize`).
    init(uncivPositions positions: [HexMath.Position], wrapX: Bool, baseTerrain: String = "Ocean") {
        let fitted = UncivSave.frame(for: positions.map { ($0.x, $0.y) }) ?? (UncivSave.Frame(), 1, 1)
        let width = wrapX && fitted.0.extraColumn == 1 ? fitted.1 - 1 : fitted.1, height = fitted.2
        var tiles: [Tile] = []
        tiles.reserveCapacity(width * height)
        for row in 0..<height { for col in 0..<width { tiles.append(Tile(coord: HexCoord.fromOffset(col: col, row: row), baseTerrain: baseTerrain)) } }
        self.init(width: width, height: height, tiles: tiles, wrapX: wrapX)
        let frame = UncivSave.Frame.forExport(width: width, height: height)
        uncivOrder = positions.map { p in
            let o = frame.ours(x: p.x, y: p.y)
            return o.row * width + (wrapX ? ((o.col % width) + width) % width : o.col)
        }
        missing = Set(tiles.indices).subtracting(uncivOrder)
        buildNeighborTable()   // `missing` just changed what `contains` answers
    }

    /// Unciv's own position of a tile of this grid (UncivSave.Frame.forExport). A wrapping grid that holds Unciv's last
    /// column in its column 0 (see `init(uncivPositions:)`) gives that column its Unciv number.
    func uncivPosition(_ c: HexCoord) -> HexMath.Position {
        var p = UncivSave.Frame.forExport(width: width, height: height).unciv(col: c.offsetCol, row: c.offsetRow)
        let column = HexMath.column(p)
        if wrapX && column < -(width / 2) { let twoRows = p.x + p.y, wrapped = column + width; p = ((twoRows - wrapped) / 2, (twoRows + wrapped) / 2) }
        return p
    }
    /// Unciv TileMap.tileMatrix.size: how many x values (the 10 o'clock axis) the map's tiles span
    var uncivTileMatrixSize: Int {
        let xs = tiles.indices.filter { !missing.contains($0) }.map { uncivPosition(tiles[$0].coord).x }
        guard let lo = xs.min(), let hi = xs.max() else { return 0 }
        return hi - lo + 1
    }

    /// Rebuild the per-tile neighbour lists. Call after anything that changes what `contains` answers.
    mutating func buildNeighborTable() {
        var table: [[HexCoord]] = []
        table.reserveCapacity(tiles.count)
        for i in 0..<tiles.count { table.append(computeNeighbors(of: HexCoord.fromOffset(col: i % width, row: i / width))) }
        neighborTable = table
    }

    private enum CodingKeys: String, CodingKey { case width, height, tiles, wrapX, hexRadius, missing, uncivOrder, uncivSize }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width); height = try c.decode(Int.self, forKey: .height)
        tiles = try c.decode([Tile].self, forKey: .tiles)
        wrapX = try c.decodeIfPresent(Bool.self, forKey: .wrapX) ?? false
        hexRadius = try c.decodeIfPresent(Int.self, forKey: .hexRadius)
        missing = try c.decodeIfPresent(Set<Int>.self, forKey: .missing) ?? []
        // Unciv serializes tileList in its order, so a save, an autosave, an undo snapshot or a map file keeps it
        uncivOrder = (try? c.decodeIfPresent([Int].self, forKey: .uncivOrder)) ?? []
        if uncivOrder.contains(where: { $0 < 0 || $0 >= tiles.count }) { uncivOrder = [] }
        uncivSize = try? c.decodeIfPresent(UncivMapSize.self, forKey: .uncivSize)
        buildNeighborTable()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width); try c.encode(height, forKey: .height); try c.encode(tiles, forKey: .tiles); try c.encode(wrapX, forKey: .wrapX); try c.encodeIfPresent(hexRadius, forKey: .hexRadius); if !missing.isEmpty { try c.encode(missing, forKey: .missing) }
        if !uncivOrder.isEmpty { try c.encode(uncivOrder, forKey: .uncivOrder) }
        try c.encodeIfPresent(uncivSize, forKey: .uncivSize)
    }

    /// Canonical coordinate: on a wrapping map the column is taken modulo the width.
    func normalize(_ c: HexCoord) -> HexCoord {
        guard wrapX else { return c }
        let col = ((c.offsetCol % width) + width) % width
        return col == c.offsetCol ? c : HexCoord.fromOffset(col: col, row: c.offsetRow)
    }

    func index(of raw: HexCoord) -> Int? {
        let c = normalize(raw)
        let col = c.offsetCol, row = c.offsetRow
        guard col >= 0, col < width, row >= 0, row < height else { return nil }
        let i = row * width + col
        return missing.contains(i) ? nil : i
    }
    func contains(_ c: HexCoord) -> Bool { index(of: c) != nil }

    subscript(c: HexCoord) -> Tile? {
        get { index(of: c).map { tiles[$0] } }
        set { if let i = index(of: c), let v = newValue { if EvLog.on { EvLog.tileWrite(old: tiles[i], new: v) }; tiles[i] = v } }
    }
    /// `map[c]?.a = x; map[c]?.b = y` as ONE write: the same tile in the end, but the EVLOG hook in the setter sees
    /// the whole change (an improvement set and unpillaged together) instead of a half-way tile Unciv never has.
    mutating func update(_ c: HexCoord, _ body: (inout Tile) -> Void) { if var t = self[c] { body(&t); self[c] = t } }

    private func computeNeighbors(of c: HexCoord) -> [HexCoord] { c.neighbors.map { normalize($0) }.filter { contains($0) } }
    func neighbors(of c: HexCoord) -> [HexCoord] {
        guard neighborTable.count == tiles.count else { return computeNeighbors(of: c) }
        let n = normalize(c)
        let col = n.offsetCol, row = n.offsetRow
        // A coordinate off the rectangle falls back; one of the hexagonal map's corner holes does not -
        // `missing` says the cell is not a tile, not that nothing is next to it, and the table holds
        // the same list `contains` would have filtered.
        guard col >= 0, col < width, row >= 0, row < height else { return computeNeighbors(of: c) }
        return neighborTable[row * width + col]
    }

    /// Is there a river on the edge between two adjacent tiles?
    func hasRiver(between a: HexCoord, _ b: HexCoord) -> Bool {
        guard let d = a.wrappedDirection(to: b) else { return false }
        if [HexCoord.dirSE, HexCoord.dirSW, HexCoord.dirS].contains(d) { return self[a]?.riverEdges.contains(d) ?? false }
        return self[b]?.riverEdges.contains(HexCoord.opposite(d)) ?? false
    }
    mutating func setRiver(_ a: HexCoord, dir d: Int) { setRiver(a, dir: d, true) }
    /// Unciv Tile.setConnectedByRiver: set or clear the river on one of the six edges around a tile.
    mutating func setRiver(_ a: HexCoord, dir d: Int, _ value: Bool) {
        if [HexCoord.dirSE, HexCoord.dirSW, HexCoord.dirS].contains(d) {
            if value { self[a]?.riverEdges.insert(d) } else { self[a]?.riverEdges.remove(d) }
        } else {
            let b = normalize(a.neighbor(d))
            guard contains(b) else { return }
            if value { self[b]?.riverEdges.insert(HexCoord.opposite(d)) } else { self[b]?.riverEdges.remove(HexCoord.opposite(d)) }
        }
    }
    /// Unciv TileMap.getTilesInDistance order: ring 0…radius, each ring from the south tile, every tile followed by its mirror
    func tilesInDistanceUncivOrder(_ c: HexCoord, radius: Int) -> [HexCoord] {
        var raw: [HexCoord] = [c]
        if radius > 0 {
            for d in 1...radius {
                var q = 0, r = d
                for (dq, dr) in [(-1, 0), (0, -1), (1, -1)] {
                    for _ in 0..<d {
                        raw.append(HexCoord(c.q + q, c.r + r)); raw.append(HexCoord(c.q - q, c.r - r))
                        q += dq; r += dr
                    }
                }
            }
        }
        var seen: Set<HexCoord> = []; var out: [HexCoord] = []
        for t in raw { let n = wrapX ? normalize(t) : t; if contains(n) && seen.insert(n).inserted { out.append(n) } }
        return out
    }
    /// Unciv TileMap.getTilesInDistance: the centre first, then ring by ring outward. Several callers take the
    /// first match, so the order is part of the behaviour, not a detail.
    func tilesWithin(_ c: HexCoord, radius: Int) -> [HexCoord] {
        tilesInDistanceUncivOrder(c, radius: radius)
    }

}

// MARK: - continents (Unciv TileMap.assignContinents / continentSizes / continentsSortedBySize)

extension GameMap {
    /// Unciv TileMap.AssignContinentsMode
    enum AssignContinentsMode { case assign, reassign, ensure, clear }

    /// Unciv `tileMap.values` - the tileList order. A save or a map file lists its tiles in that order
    /// (`uncivOrder`). A map we generated has none, so it is rebuilt the way Unciv's TileMap constructors fill
    /// tileList: a rectangular map column by column from the west, each column from Unciv's row -height/2 upward
    /// (our row axis runs the other way, see UncivSave.Frame); a hexagonal map ring by ring from its centre, each
    /// ring in HexMath.getHexCoordsAtDistance order.
    func uncivTileListOrder() -> [Int] {
        if !uncivOrder.isEmpty { return uncivOrder }
        if let radius = hexRadius {
            let frame = UncivSave.Frame.forExport(width: width, height: height)
            let origin = frame.unciv(col: width / 2, row: height / 2)
            var out: [Int] = []
            func add(_ x: Int, _ y: Int) {
                let o = frame.ours(x: x, y: y)
                if let i = index(of: HexCoord.fromOffset(col: o.col, row: o.row)) { out.append(i) }
            }
            add(origin.x, origin.y)
            if radius > 0 {
                for d in 1...radius {
                    // HexMath.getHexCoordsAtDistance (worldWrap false): from 6 o'clock, each tile followed by its mirror
                    var cx = origin.x - d, cy = origin.y - d
                    for (dx, dy) in [(1, 0), (1, 1), (0, 1)] {
                        for _ in 0..<d {
                            add(cx, cy); add(2 * origin.x - cx, 2 * origin.y - cy)
                            cx += dx; cy += dy
                        }
                    }
                }
            }
            return out
        }
        return (0..<width).flatMap { col in (0..<height).reversed().map { row in row * width + col } }.filter { !missing.contains($0) }
    }

    /// Unciv Tile.isImpassible(): `lastTerrain.impassable` - the last feature, else the natural wonder, else the base.
    private func isImpassibleForContinents(_ t: Tile) -> Bool {
        let rs = Ruleset.shared
        let last = t.features.last.flatMap { rs.terrains[$0] } ?? t.naturalWonder.flatMap { rs.terrains[$0] } ?? rs.terrains[t.baseTerrain]
        return last?.impassable == true
    }

    /// Unciv TileMap.assignContinents(mode)
    mutating func assignContinents(_ mode: AssignContinentsMode) {
        if mode == .clear {
            for i in tiles.indices { tiles[i].continent = -1 }
            continentSizes = [:]
            return
        }
        let order = uncivTileListOrder()
        if mode == .ensure {
            if !continentSizes.isEmpty { return }
            for i in order {
                let continent = tiles[i].continent
                if continent == -1 { continue }
                continentSizes[continent, default: 0] += 1
            }
            if !continentSizes.isEmpty { return }
        }
        func inContinent(_ i: Int) -> Bool { tiles[i].isLand && !isImpassibleForContinents(tiles[i]) }
        var landTiles = order.filter(inContinent)
        var currentContinent = 0
        continentSizes = [:]
        if mode == .reassign { for i in tiles.indices { tiles[i].continent = -1 } }
        var reached = Array(repeating: false, count: tiles.count)
        while !landTiles.isEmpty {
            // BFS(landTiles[landTiles.size / 2]) { it.isLand && !it.isImpassible() }
            let start = landTiles[landTiles.count / 2]
            var frontier = [start]; reached[start] = true
            var size = 0
            while let cur = frontier.popLast() {
                tiles[cur].continent = currentContinent
                size += 1
                for n in neighbors(of: tiles[cur].coord) {
                    guard let j = index(of: n), !reached[j], inContinent(j) else { continue }
                    reached[j] = true; frontier.append(j)
                }
            }
            continentSizes[currentContinent] = size
            currentContinent += 1
            landTiles.removeAll { reached[$0] }
        }
    }

    /// Unciv TileMap.continentsSortedBySize: `continentSizes.entries.sortedByDescending { it.value }`, a stable sort
    /// over a HashMap<Int, Int> - whose small ids walk in ascending order - so a tie keeps the lower id first.
    var continentsSortedBySize: [Int] {
        continentSizes.keys.sorted { a, b in continentSizes[a]! != continentSizes[b]! ? continentSizes[a]! > continentSizes[b]! : a < b }
    }
}

// MARK: - Unciv Civilization.neutralRoads: who pays for the roads on unowned tiles

extension GameState {
    /// Unciv TileMap.setNeutralTransients -> Tile.setOwnerTransients, run by GameInfo.setTransients once the owners are
    /// set: every tile no city owns whose roadOwner is not "" goes into that civ's neutralRoads - with or without a
    /// road on it (the upkeep loop skips a tile whose getUnpillagedRoad() is None).
    func setNeutralTransients() {
        neutralRoads = [:]
        for t in map.tiles where t.ownerCivId == nil {
            if let roadOwner = t.roadOwner { neutralRoads[roadOwner, default: []].insert(t.coord) }
        }
    }

    /// Unciv TileMap.setNeutralTransients on a set taken over from the game cloned (a Next Turn clone, an undo restore:
    /// Civilization.clone shares neutralRoads): each tile no city owns is added to its road owner's again, nothing taken out.
    func addNeutralTransients() {
        for t in map.tiles where t.ownerCivId == nil { if let roadOwner = t.roadOwner { neutralRoads[roadOwner, default: []].insert(t.coord) } }
    }

    /// Unciv City.setTransients → CityExpansionManager.setTransients: `for (tile in city.getTiles()) tile.setOwningCity(city)`,
    /// which GameInfo.setTransients runs for every city before setNeutralTransients - on a load (the decoder, the Unciv
    /// import), on WorldScreen.nextTurn's clone (uncivNextTurnTransients), on an undo restore (restoreUndoCheckpoint
    /// sharing the live set). Every tile a city owns has that city's civ as its road owner from then on, and a road on it
    /// leaves the neutralRoads of the road owner it was saved with (the clone's and the restored checkpoint's set being
    /// the very set of the live game; the decoder leaves the saved road owners alone for those two). A tile a city took over in the turn (a conquest's tiles: moveToCiv sets no owner) keeps its old road owner
    /// only until then; ours kept it for good, so when a razed conquest's last citizen left, its road-less tiles went
    /// back to the civ it was taken from instead of the conqueror, and a city later founded on one charged its centre's
    /// road to the conqueror in Unciv only (deity under a human Greece: France's Transportation upkeep -8 from t=68,
    /// ours -7).
    func setOwningCityTransients() {
        for city in cities { for c in city.tiles { setOwningCityRoadOwner(at: c, civId: city.civId) } }
    }

    /// Unciv Tile.setOwningCity(city) with a city, its road half: "remove previous neutral tile owner" - when the tile
    /// has a road and a stored roadOwner, THAT civ's neutralRoads loses it (not whoever else still lists the tile) -
    /// then the road belongs to the city's civ, "only when taking control, otherwise last owner".
    func setOwningCityRoadOwner(at c: HexCoord, civId: Int) {
        guard let t = map[c] else { return }
        if t.roads, let previous = t.roadOwner { neutralRoads[previous]?.remove(c) }
        map[c]?.roadOwner = civId
    }
}

extension GameState {
    /// Unciv Tile.getContinent(): the id stored on the tile at map generation, never a fresh flood fill - a
    /// mountain is -1 and splits land, and a natural wonder keeps the id its tile had before the wonder.
    func continentId(of coord: HexCoord) -> Int { map[coord]?.continent ?? -1 }
}
