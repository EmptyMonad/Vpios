// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's map-generation regions: MapRegions, Region, MapGenTileData, RegionStartFinder, StartNormalizer,
// MinorCivPlacer, LuxuryResourcePlacementLogic, StrategicBonusResourcePlacementLogic and MapRegionResources.
// Divides the map into fertility-balanced regions, picks and normalises start positions for major civs, places
// city-states and every resource.

/// Unciv MapResourceSetting
struct MapResourceSetting {
    let randomLuxuriesPercent: Int, regionalLuxuriesDelta: Int, specialLuxuriesTargetFactor: Double, bonusFrequencyMultiplier: Double
    static func named(_ label: String) -> MapResourceSetting {
        switch label {
        case "Sparse": return MapResourceSetting(randomLuxuriesPercent: 80, regionalLuxuriesDelta: -1, specialLuxuriesTargetFactor: 0.5, bonusFrequencyMultiplier: 1.5)
        case "Abundant": return MapResourceSetting(randomLuxuriesPercent: 133, regionalLuxuriesDelta: 1, specialLuxuriesTargetFactor: 0.9, bonusFrequencyMultiplier: 0.6667)
        default: return MapResourceSetting(randomLuxuriesPercent: 100, regionalLuxuriesDelta: 0, specialLuxuriesTargetFactor: 0.75, bonusFrequencyMultiplier: 1)
        }
    }
}

final class MapRegions {
    struct Rect { var x: Double; var y: Double; var width: Double; var height: Double }
    enum ImpactType: Int { case strategic, luxury, bonus, minorCiv }

    /// Unciv Region
    final class Region {
        var rect: Rect
        let continentID: Int
        /// Unciv `val tiles = HashSet<Tile>()`, in the order it walks: Tile hashes to 1 under the reference's
        /// -XX:hashCode=2, so the walk is JavaHash1Set's over the inserts (tile indices)
        var tiles: [Int] = []
        var tileSet: Set<Int> = []
        /// The length of that HashSet's table: `tiles.clear()` in updateTiles keeps it, nil before the first fill
        var hashTableLength: Int? = nil
        var terrainCounts: [String: Int] = [:]
        /// Unciv `terrainCounts` is a HashMap<String, Int>: the keys in the order they first went in (javaHashMapOrder)
        var terrainCountOrder: [String] = []
        var totalFertility = 0
        var type = "Hybrid"
        var luxury: String? = nil
        var startPosition: HexCoord? = nil
        var assignedMinorCivs: [String] = []
        var affectedByWorldWrap = false
        init(rect: Rect, continentID: Int) { self.rect = rect; self.continentID = continentID }
    }
    /// Unciv MapGenTileData
    struct TileData {
        var closeStartPenalty = 0
        var impacts: [ImpactType: Int] = [:]
        var isFood = false, isProd = false, isGood = false, isJunk = false, isTwoFromCoast = false
        var isGoodStart = true
        var startScore = 0
        mutating func addCloseStartPenalty(_ penalty: Int) {
            if closeStartPenalty == 0 { closeStartPenalty = penalty }
            else { closeStartPenalty = min(97, Int(Double(max(closeStartPenalty, penalty)) * 1.2)) }
        }
    }

    static let minimumFoodForRing = [1: 1, 2: 4, 3: 4]
    static let minimumProdForRing = [1: 0, 2: 0, 3: 2]
    static let minimumGoodForRing = [1: 3, 2: 6, 3: 8]
    static let maximumJunk = 9
    static let firstRingFoodScores = [0, 8, 14, 19, 22, 24, 25]
    static let firstRingProdScores = [0, 10, 16, 20, 20, 12, 0]
    static let secondRingFoodScores = [0, 2, 5, 10, 20, 25, 28, 30, 32, 34, 35]
    static let secondRingProdScores = [0, 10, 20, 25, 30, 35]
    /// Unciv's `mapOf(0 to 99, ...)` is a LinkedHashMap that setRegionStart walks ring 0 to 13 in turn; the order
    /// counts, as addCloseStartPenalty takes the larger penalty and adds 20 % to it, so pairs in a list, not a
    /// Swift Dictionary whose walk changes with every launch.
    static let closeStartPenaltyForRing: [(ring: Int, penalty: Int)] = [(0, 99), (1, 97), (2, 95), (3, 92), (4, 89), (5, 69), (6, 57), (7, 24), (8, 20), (9, 16), (10, 12), (11, 8), (12, 6), (13, 4)]
    static let randomLuxuryRatios: [Int: [Double]] = [1: [1], 2: [0.55, 0.45], 3: [0.40, 0.33, 0.27], 4: [0.35, 0.25, 0.25, 0.15], 5: [0.25, 0.25, 0.20, 0.15, 0.15], 6: [0.20, 0.20, 0.20, 0.15, 0.15, 0.10], 7: [0.20, 0.20, 0.15, 0.15, 0.10, 0.10, 0.10], 8: [0.20, 0.15, 0.15, 0.10, 0.10, 0.10, 0.10, 0.10]]
    static let baseMinorDepositFrequency = 30

    let rs: Ruleset
    var map: GameMap
    var rng: SeededRandom
    let resourceSetting: MapResourceSetting
    /// Unciv `GameContext(gameInfo = tileMap.gameInfo).hashCode()`'un 1. alanı:
    /// `settings.gameId` (çevrimiçi oyun) yoksa harita tohumu. Bkz. `uncivMapGenGameHash`.
    let gameHash: Int32
    let resourceSettingName: String
    let strategicBalance: Bool
    let legendaryStart: Bool
    var regions: [Region] = []
    var tileData: [TileData] = []
    /// Unciv `private lateinit var tileData`: assignRegions builds it whenever it has civilizations - an empty region
    /// list too, where ours leaves the list empty - and reading it before that throws
    /// UninitializedPropertyAccessException, which NewGameScreen.startNewGame catches (a lone Spectator: no major civ)
    private var tileDataInitialized = false
    struct TileDataUninitialized: Error, CustomStringConvertible { var description: String { "lateinit property tileData has not been initialized" } }
    /// Start positions by nation name (majors and city-states alike).
    var startingLocations: [String: HexCoord] = [:]
    /// Unciv TileMap.startingLocationsByNation is a HashMap<String, HashSet<Tile>>: the nations in the order
    /// addStartingLocation first saw them - majors in assignCivToRegion order, then city-states as they are placed.
    private var startingLocationOrder: [String] = []
    private var regionOfTile: [Int] = []
    /// The indices of the map's real tiles (Unciv tileMap.values): a grid cell in `map.missing` is not a tile - a
    /// rectangular map's odd columns stick out half a row past our grid's, a hexagonal map leaves the corners empty.
    let realIndices: [Int]

    init(map: GameMap, rng: SeededRandom, ruleset: Ruleset, resourceSetting: String, strategicBalance: Bool = false, legendaryStart: Bool = false, gameHash: Int32 = 0) {
        self.map = map; self.rng = rng; self.rs = ruleset
        self.realIndices = map.tiles.indices.filter { !map.missing.contains($0) }
        self.gameHash = gameHash
        self.resourceSetting = MapResourceSetting.named(resourceSetting)
        self.resourceSettingName = resourceSetting
        self.strategicBalance = resourceSetting == "Strategic Balance" || strategicBalance
        self.legendaryStart = legendaryStart
        // Unciv MapRegions reads the continents MapGenerator stored on the tiles (TileMap.assignContinents(Assign),
        // after the ice); a map that has none is given them the way GameStarter's Ensure would
        self.map.assignContinents(.ensure)
    }

    // MARK: - tile helpers

    private func tile(_ i: Int) -> Tile { map.tiles[i] }
    private func index(_ c: HexCoord) -> Int? { map.index(of: c) }
    private func lastTerrain(_ t: Tile) -> Terrain? { rs.terrains[t.features.last ?? t.baseTerrain] }
    private func allTerrains(_ t: Tile) -> [Terrain] { t.terrainNames.compactMap { rs.terrains[$0] } }
    /// Unciv MapRegions: a land tile next to coastal water (the terrain's own unique, not the name "Coast")
    /// Unciv Tile.isAdjacentToCoast is a lazy: filled on a tile's first read (generateRegions reads every land tile's)
    /// and kept after a natural wonder turns its neighbours to Coast - see GameMap.isAdjacentToCoast
    private func isCoastal(_ t: Tile) -> Bool { map.isAdjacentToCoast(t.coord) }
    private func hasFreshWaterTerrain(_ t: Tile) -> Bool { allTerrains(t).contains { $0.uniques.contains("Fresh water") } }
    /// Unciv Tile.isAdjacentTo(fresh water): an adjacent river counts, as does a neighbouring lake or oasis.
    private func adjacentToFreshWater(_ t: Tile) -> Bool { t.riverAdjacent || map.neighbors(of: t.coord).contains { map[$0].map(hasFreshWaterTerrain) ?? false } }
    private func neighborIndices(_ i: Int) -> [Int] { map.neighbors(of: tile(i).coord).compactMap { index($0) } }
    /// Unciv TileMap.getTilesAtDistance / forEachTileAtDistance (ring 1 is Tile.neighbors, the same walk): from 6
    /// o'clock (x - d, y - d), each coordinate followed by its mirror through the origin, every one read through
    /// getIfTileExistsOrNull - so on a wrapping map a coordinate off the map is shifted 2 * radius columns and kept
    /// as it lands, with no check of its distance and no removal of a tile met twice. A hexagonal wrapped map's
    /// corners off the hexagon land on tiles across the map, some of them on the same ring again, and Unciv's
    /// setRegionStart penalises those twice (addCloseStartPenalty's 20 % more).
    private func tilesAtDistance(_ c: HexCoord, _ d: Int) -> [Int] {
        guard d > 0 else { return index(c).map { [$0] } ?? [] }
        let o = UncivSave.Frame.forExport(width: map.width, height: map.height).unciv(col: c.offsetCol, row: c.offsetRow)
        var out: [Int] = []
        out.reserveCapacity(6 * d)
        var x = o.x - d, y = o.y - d
        for (dx, dy) in [(1, 0), (1, 1), (0, 1)] {
            for _ in 0..<d {
                if let i = uncivTileIndex(x, y) { out.append(i) }
                if let i = uncivTileIndex(2 * o.x - x, 2 * o.y - y) { out.append(i) }
                x += dx; y += dy
            }
        }
        return out
    }
    private func tilesInRange(_ c: HexCoord, _ range: ClosedRange<Int>) -> [Int] { range.flatMap { tilesAtDistance(c, $0) } }
    private func isImpassable(_ t: Tile) -> Bool { t.isImpassable }
    /// Unciv Tile.matchesTerrainFilter for the map-generation subset of filters.
    func terrainMatches(_ t: Tile, _ filter: String) -> Bool {
        let f = filter.trimmingCharacters(in: .whitespaces)
        if f.hasPrefix("{") { return f.split(separator: "}").map { $0.replacingOccurrences(of: "{", with: "").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.allSatisfy { terrainMatches(t, $0) } }
        switch f {
        case "Featureless": return t.features.isEmpty
        case "Land": return t.isLand
        case "Water": return t.isWater
        case "Coastal": return isCoastal(t)
        case "Fresh Water", "Fresh water": return t.riverAdjacent || hasFreshWaterTerrain(t) || adjacentToFreshWater(t)
        case "River": return t.riverAdjacent
        default: return t.baseTerrain == f || t.features.contains(f) || t.naturalWonder == f || t.resource == f
        }
    }
    /// Evaluates the conditionals used by map-generation uniques.
    private func conditionalsApply(_ u: Unique, tile t: Tile?, region: Region?) -> Bool {
        for c in u.conditionals {
            switch c.pattern {
            case "in [] tiles": guard let t = t, terrainMatches(t, c.param(0)) else { return false }
            case "in tiles without []": guard let t = t, !terrainMatches(t, c.param(0)) else { return false }
            case "in [] Regions": if region?.type != c.param(0) { return false }
            case "in all except [] Regions": if region?.type == c.param(0) { return false }
            case "on water maps": if !usingArchipelagoRegions { return false }
            // Unciv Conditionals.kt ends in `else -> false`: a modifier it does not recognise fails. That matters
            // here because getTerrainRule builds a deliberately unmatchable "<in [Featureless] [Terrain] tiles>",
            // which Unciv therefore never matches - treating it as "no condition" put every tile on the list.
            default: return false
            }
        }
        return true
    }
    private func regionOf(_ i: Int) -> Region? { let r = regionOfTile.isEmpty ? -1 : regionOfTile[i]; return r >= 0 ? regions[r] : nil }
    /// Unciv TileResource.generatesNaturallyOn
    func generatesNaturallyOn(_ res: ResourceDef, _ t: Tile) -> Bool {
        guard let last = lastTerrain(t), res.terrainsCanBeFoundOn.contains(last.name) else { return false }
        if res.uniqueObjects.contains(where: { $0.pattern == "Doesn't generate naturally" && conditionalsApply($0, tile: t, region: nil) }) { return false }
        if allTerrains(t).contains(where: { tr in tr.uniqueObjects.contains { $0.pattern == "Never receives any resources" && conditionalsApply($0, tile: t, region: nil) } }) { return false }
        if t.naturalWonder != nil || t.isCityCenter { return false }
        return true
    }
    private func isWaterOnly(_ res: ResourceDef) -> Bool { res.terrainsCanBeFoundOn.allSatisfy { rs.terrains[$0]?.type == .water } }   // Unciv: vacuously true for an empty list
    /// Unciv `utils/CollectionExtensions.randomWeighted(weights, random)` — birebir:
    ///   `totalWeight = weights.sum()` (Float), `randDouble = random.nextDouble()`,
    ///   `sum += weights[i] / totalWeight` (Float), `if (randDouble <= sum) return this[i]`,
    ///   aksi hâlde `return last()`.
    /// Üç davranış kritik:
    ///   * `nextDouble()` **her zaman** bir kez çekilir — tek öğede de, toplam 0'da da.
    ///   * Toplam 0 ise `w / 0f` NaN (ya da ±Inf) verir, karşılaştırma hep false kalır ve
    ///     **ek çekim yapmadan** son öğe döner. Eski `rng.pick(items)` dalı hem farklı öğe
    ///     seçiyor hem de akıştan fazladan bir `nextInt` tüketiyordu.
    ///   * Ağırlıklar Float; toplam da Float olarak birikir (Double ile sınırda farklı öğe çıkar).
    /// Unciv boş listede `NoSuchElementException` atar; biz hiç çekim yapmadan nil döneriz.
    private static func randomWeighted<T>(_ items: [T], _ rng: inout SeededRandom, _ weight: (T) -> Double) -> T? {
        if items.isEmpty { return nil }
        let ws = items.map { Float(weight($0)) }
        var total: Float = 0
        for w in ws { total += w }
        let randDouble = rng.nextDouble()
        var sum: Float = 0
        for (i, w) in ws.enumerated() {
            sum += w / total
            if randDouble <= Double(sum) { return items[i] }
        }
        return items.last
    }
    /// Karonun Unciv (x, y) konumu — harita üretimi `stateBasedRandom` tohumları bundan türer.
    /// `Frame.forExport` yalnızca harita boyutlarına bakar, süreçler arası kararlıdır.
    private func uncivPosition(_ i: Int) -> (x: Int, y: Int) {
        let c = map.tiles[i].coord
        return UncivSave.Frame.forExport(width: map.width, height: map.height).unciv(col: c.offsetCol, row: c.offsetRow)
    }
    /// Unciv `GameContext.hashCode()` içindeki `Region?.hash() = rect.hashCode()` — libGDX
    /// `Rectangle.hashCode()`. Yalnızca `rect` girer; bölgenin karoları, tipi, lüksü girmez.
    private func regionRectHash(_ r: Region) -> Int32 {
        gdxRectangleHash(x: r.rect.x, y: r.rect.y, width: r.rect.width, height: r.rect.height)
    }

    // MARK: - continents (Unciv Tile.getContinent / TileMap.continentSizes)

    /// Unciv Tile.getContinent(): the id stored on the tile by TileMap.assignContinents - numbered over tileList,
    /// never recomputed here
    private func continentOf(_ i: Int) -> Int { map.tiles[i].continent }
    /// Unciv TileMap.continentSizes
    var continentSizes: [Int: Int] { map.continentSizes }
    var usingArchipelagoRegions: Bool {
        let total = Double(continentSizes.values.reduce(0, +)), largest = Double(continentSizes.values.max() ?? 0)
        return total > 0 && largest / total < 0.25
    }

    // MARK: - fertility and rectangles

    /// Unciv Tile.getTileFertility
    func fertility(_ t: Tile, checkCoasts: Bool) -> Int {
        var f = 0
        for terrain in allTerrains(t) {
            if let o = terrain.uniqueObjects.first(where: { $0.pattern == "Always Fertility [] for Map Generation" }) { return o.int(0) }
            f += terrain.uniqueObjects.filter { $0.pattern == "[] to Fertility for Map Generation" }.reduce(0) { $0 + $1.int(0) }
        }
        if t.riverAdjacent { f += 1 }
        if adjacentToFreshWater(t) { f += 1 }
        if checkCoasts && isCoastal(t) { f += 2 }
        return f
    }
    /// Unciv HexMath.getColumn / getRow: a tile's place in Unciv's own hex space. getRow is `(x + y) / 2`, which
    /// truncates towards zero - one row too high for an odd column below row 0. Only the trimming reads it.
    private func uncivColRow(_ t: Tile) -> (col: Double, row: Double) {
        let p = UncivSave.Frame.forExport(width: map.width, height: map.height).unciv(col: t.coord.offsetCol, row: t.coord.offsetRow)
        return (Double(p.y - p.x), Double((p.x + p.y) / 2))
    }
    /// Unciv measures every region rectangle in its own column and row space, whatever the map's shape.
    private func rectCoords(_ t: Tile) -> (col: Double, row: Double) { uncivColRow(t) }
    /// Unciv MapRegions.generateRegions: the map's radius, or half its larger side when it is not hexagonal.
    private var regionRadius: Int {
        // Unciv reads mapParameters: mapSize.radius on a hexagonal map, else max(mapSize.width / 2, mapSize.height / 2)
        if let size = map.uncivSize { return size.isHexagonal ? size.radius : max(size.width / 2, size.height / 2) }
        return map.hexRadius ?? max(map.width / 2, map.height / 2)
    }
    /// Unciv HexMath.getTileCoordsFromColumnRow: an odd column's rows sit half a row up
    private static func tileCoordsFromColumnRow(_ column: Int, _ row: Int) -> (x: Int, y: Int) {
        var twoRows = row * 2
        if abs(column) % 2 == 1 { twoRows += 1 }
        return ((twoRows - column) / 2, (twoRows + column) / 2)
    }
    /// Unciv TileMap.getIfTileExistsOrNull(x, y): the tile at Unciv's (x, y); on a wrapping map else the one at
    /// (x + radius, y - radius), else (x - radius, y + radius) - `2 * radius` columns west or east on the same row,
    /// radius being mapSize.width / 2 on a rectangular map.
    private func uncivTileIndex(_ x: Int, _ y: Int) -> Int? {
        let o = UncivSave.Frame.forExport(width: map.width, height: map.height).ours(x: x, y: y)
        func at(_ col: Int) -> Int? {
            guard col >= 0, col < map.width, o.row >= 0, o.row < map.height else { return nil }
            let i = o.row * map.width + col
            return map.missing.contains(i) ? nil : i
        }
        if let i = at(o.col) { return i }
        guard map.wrapX else { return nil }
        let shift = 2 * (map.width / 2)
        return at(o.col - shift) ?? at(o.col + shift)
    }
    /// Unciv TileMap.getTilesInRectangle: world columns x until x + width outside, rows y until y + height inside
    /// (Float.toInt() truncates), each (column, row) read through getTileCoordsFromColumnRow - so a tile is in by its
    /// true row, not getRow's truncated one - and getIfTileExistsOrNull. A rectangle wider than a wrapping map yields
    /// the seam's tiles twice, as Unciv's sequence does.
    private func tilesInRectangle(_ r: Rect) -> [Int] {
        let x = Int(r.x), y = Int(r.y)
        var out: [Int] = []
        for column in stride(from: x, to: x + Int(r.width), by: 1) {
            for row in stride(from: y, to: y + Int(r.height), by: 1) {
                let hex = MapRegions.tileCoordsFromColumnRow(column, row)
                if let i = uncivTileIndex(hex.x, hex.y) { out.append(i) }
            }
        }
        return out
    }
    /// Unciv HexMath.getDistance: the hex distance without world wrap's shortcut across the seam
    private func rawDistance(_ a: HexCoord, _ b: HexCoord) -> Int { (abs(a.q - b.q) + abs(a.r - b.r) + abs(a.s - b.s)) / 2 }
    /// Unciv Region.updateTiles. `tiles.clear()` keeps the HashSet's table; the tiles go in in getTilesInRectangle
    /// order and walk in JavaHash1Set order of those inserts. Fertility is summed per tile the rectangle yields.
    private func updateTiles(_ region: Region, trim: Bool = true) {
        region.totalFertility = 0
        var minCol = 99999.0, maxCol = -99999.0, minRow = 99999.0, maxRow = -99999.0
        var columnHasTile: Set<Int> = []
        var inserts: [Int] = []
        for i in tilesInRectangle(region.rect) where region.continentID == -1 || continentOf(i) == region.continentID {
            let t = map.tiles[i]
            let tileFertility = fertility(t, checkCoasts: region.continentID != -1)
            inserts.append(i)
            region.totalFertility += tileFertility
            let rc = rectCoords(t)   // tile.getColumn() / tile.getRow()
            // Unciv adds getColumn() - Unciv's column, the space rect.x lives in - not our storage column
            if region.affectedByWorldWrap { columnHasTile.insert(Int(rc.col)) }
            if trim {
                minCol = min(minCol, rc.col); maxCol = max(maxCol, rc.col)
                minRow = min(minRow, rc.row); maxRow = max(maxRow, rc.row)
            }
        }
        let walk = JavaHash1Set.iterationOrderAndTableLength(inserts, initialCapacity: region.hashTableLength)
        region.tiles = walk.order
        if walk.tableLength > 0 { region.hashTableLength = walk.tableLength }
        region.tileSet = Set(region.tiles)
        if trim && !region.tiles.isEmpty {
            if region.affectedByWorldWrap { region.rect.x = Double(columnHasTile.filter { !columnHasTile.contains($0 - 1) }.max() ?? Int(minCol)) }
            else { region.rect.x = minCol }
            region.rect.y = minRow
            region.rect.height = maxRow - minRow + 1
            if region.affectedByWorldWrap && minCol < region.rect.x { region.rect.width = Double(columnHasTile.count) }
            else { region.rect.width = maxCol - minCol + 1; region.affectedByWorldWrap = false }
        }
    }
    /// Unciv Region.countTerrains, walking `tiles` in its HashSet order; `terrainCountOrder` keeps each key's first insert
    private func countTerrains(_ region: Region) {
        region.terrainCounts = [:]
        region.terrainCountOrder = []
        func count(_ n: String) {
            if region.terrainCounts[n] == nil { region.terrainCountOrder.append(n) }
            region.terrainCounts[n, default: 0] += 1
        }
        for i in region.tiles {
            let t = map.tiles[i]
            let ignoreBase = allTerrains(t).contains { $0.uniques.contains("Base Terrain on this tile is not counted for Region determination") }
            let names = ignoreBase ? t.features : t.terrainNames
            for n in names { count(n) }
            if isCoastal(t) { count("Coastal") }
        }
    }

    // MARK: - region generation (Unciv MapRegions.generateRegions)

    nonisolated(unsafe) static var debugRegionDump: ((String) -> Void)? = nil
    func generateRegions(numRegions: Int) {
        defer { if let f = MapRegions.debugRegionDump { for (i, r) in regions.enumerated() { f("REG \(i) rect=\(Float(r.rect.x)),\(Float(r.rect.y)),\(Float(r.rect.width)),\(Float(r.rect.height)) cont=\(r.continentID) tiles=\(r.tiles.count) fert=\(r.totalFertility) wrap=\(r.affectedByWorldWrap)\n") } } }
        guard numRegions > 0, !continentSizes.isEmpty else { return }
        // Unciv MapRegions.generateRegions: on a hexagonal map the whole world is the box (-radius, -radius, 2r+1, 2r+1)
        let r = regionRadius
        let mapRect = Rect(x: Double(-r), y: Double(-r), width: Double(2 * r + 1), height: Double(2 * r + 1))
        if usingArchipelagoRegions {
            let huge = Region(rect: mapRect, continentID: -1)
            huge.affectedByWorldWrap = false   // Unciv: might as well start at the seam
            updateTiles(huge)
            divideRegion(huge, numRegions)
            return
        }
        var continentFertility: [Int: Int] = [:]
        var continentColumns: [Int: Set<Int>] = [:]
        for i in map.tiles.indices where continentOf(i) != -1 {
            continentFertility[continentOf(i), default: 0] += fertility(map.tiles[i], checkCoasts: true)
            continentColumns[continentOf(i), default: []].insert(Int(rectCoords(map.tiles[i]).col))
        }
        var civsAdded: [Int: Int] = [:]
        var civsAddedOrder: [Int] = []   // the keys in the order they went into Unciv's HashMap<Int, Int>
        for _ in 0..<numRegions {
            // `continentSizes.keys.toMutableList().maxByOrNull`: the ids in ascending order, the first best kept
            guard let best = continentSizes.keys.sorted().max(by: { (continentFertility[$0] ?? 0) / (1 + (civsAdded[$0] ?? 0)) < (continentFertility[$1] ?? 0) / (1 + (civsAdded[$1] ?? 0)) }) else { break }
            if civsAdded[best] == nil { civsAddedOrder.append(best) }
            civsAdded[best, default: 0] += 1
        }
        // Unciv `for (continent in civsAddedToContinent.keys)`: java.util.HashMap's bucket walk, not ascending ids
        for continent in MapRegions.javaIntHashMapOrder(civsAddedOrder) {
            let count = civsAdded[continent]!
            let region = Region(rect: mapRect, continentID: continent)
            let cols = continentColumns[continent] ?? []
            region.rect.x = Double(cols.filter { !cols.contains($0 - 1) }.max() ?? 0)
            region.rect.width = Double(cols.count)
            if map.wrapX, let minC = cols.min(), Double(minC) < region.rect.x { region.affectedByWorldWrap = true }
            updateTiles(region)
            divideRegion(region, count)
        }
    }
    /// java.util.HashMap<Int, _> key walk: Integer.hashCode() is the value, spread by `h ^ (h >>> 16)`; buckets in
    /// index order, insertion order within one (a resize splits a bin without reordering it)
    private static func javaIntHashMapOrder(_ keys: [Int]) -> [Int] {
        var capacity = 16
        while keys.count > capacity * 3 / 4 { capacity <<= 1 }
        func bucket(_ k: Int) -> Int32 {
            let h = Int32(truncatingIfNeeded: k)
            return (h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 16)) & Int32(capacity - 1)
        }
        return keys.enumerated().sorted { a, b in
            let ba = bucket(a.element), bb = bucket(b.element)
            return ba != bb ? ba < bb : a.offset < b.offset
        }.map { $0.element }
    }
    private func divideRegion(_ region: Region, _ numDivisions: Int) {
        if numDivisions <= 1 { regions.append(region); return }
        let first = numDivisions / 2
        let (a, b) = splitRegion(region, firstPercent: (100 * first) / numDivisions)
        divideRegion(a, first)
        divideRegion(b, numDivisions - first)
    }
    private func splitRegion(_ region: Region, firstPercent: Int) -> (Region, Region) {
        let targetFertility = (region.totalFertility * firstPercent) / 100
        let splitOff = Region(rect: region.rect, continentID: region.continentID)   // Unciv: a fresh region, so no world-wrap flag
        let widerThanTall = region.rect.width > region.rect.height
        var bestSplit = 1, closest = 0, cumulative = 0
        let highest = Int(widerThanTall ? region.rect.width : region.rect.height)
        let halfway = highest / 2
        for split in 1...max(1, highest) {
            let strip: Rect = widerThanTall ? Rect(x: splitOff.rect.x + Double(split - 1), y: splitOff.rect.y, width: 1, height: splitOff.rect.height)
                                            : Rect(x: splitOff.rect.x, y: splitOff.rect.y + Double(split - 1), width: splitOff.rect.width, height: 1)
            for i in tilesInRectangle(strip) {   // `nextRect.sumOf`, a repeat from the seam counted again
                if splitOff.continentID == -1 { cumulative += fertility(map.tiles[i], checkCoasts: false) }
                else if continentOf(i) == splitOff.continentID { cumulative += fertility(map.tiles[i], checkCoasts: true) }
            }
            let bestDelta = abs(closest - targetFertility), curDelta = abs(cumulative - targetFertility)
            if curDelta < bestDelta || (curDelta == bestDelta && abs(halfway - split) < abs(halfway - bestSplit)) { bestSplit = split; closest = cumulative }
        }
        if widerThanTall {
            splitOff.rect.width = Double(bestSplit)
            region.rect.x = splitOff.rect.x + splitOff.rect.width
            region.rect.width -= Double(bestSplit)
        } else {
            splitOff.rect.height = Double(bestSplit)
            region.rect.y = splitOff.rect.y + splitOff.rect.height
            region.rect.height -= Double(bestSplit)
        }
        updateTiles(splitOff); updateTiles(region)
        return (splitOff, region)
    }

    // MARK: - region types & tile data

    private func regionPriority(_ terrain: Terrain?) -> Int? {
        guard let t = terrain else { return 99999 }
        if let u = t.uniqueObjects.first(where: { $0.pattern == "A Region is formed with at least []% [] tiles, with priority []" }) { return u.int(2) }
        if let u = t.uniqueObjects.first(where: { $0.pattern == "A Region is formed with at least []% [] tiles and [] tiles, with priority []" }) { return u.int(3) }
        return nil
    }
    private func assignRegionTypes() {
        let types = rs.terrains.values.filter { regionPriority($0) != nil }.sorted { (regionPriority($0) ?? 0, $0.name) < (regionPriority($1) ?? 0, $1.name) }
        for region in regions {
            countTerrains(region)
            for type in types {
                if type.uniqueObjects.contains(where: { $0.pattern == "A Region can not contain more [] tiles than [] tiles" && (region.terrainCounts[$0.param(0)] ?? 0) >= (region.terrainCounts[$0.param(1)] ?? 0) }) { continue }
                let single = type.uniqueObjects.contains { $0.pattern == "A Region is formed with at least []% [] tiles, with priority []" && (region.terrainCounts[$0.param(1)] ?? 0) >= ($0.int(0) * region.tiles.count) / 100 }
                let two = type.uniqueObjects.contains { $0.pattern == "A Region is formed with at least []% [] tiles and [] tiles, with priority []" && (region.terrainCounts[$0.param(1)] ?? 0) + (region.terrainCounts[$0.param(2)] ?? 0) >= ($0.int(0) * region.tiles.count) / 100 }
                if single || two { region.type = type.name; break }
            }
        }
    }
    /// Unciv MapGenTileData.evaluate
    private func evaluateTileData(_ i: Int) -> TileData {
        var d = TileData()
        let t = map.tiles[i]
        if !isCoastal(t) && neighborIndices(i).contains(where: { isCoastal(map.tiles[$0]) }) { d.isTwoFromCoast = true }
        let region = regionOf(i)
        let features = t.features.compactMap { rs.terrains[$0] }
        let toCheck: Terrain? = features.isEmpty ? rs.terrains[t.baseTerrain] : (features.first { $0.unbuildable } ?? features.first)
        guard let terrain = toCheck else { return d }
        let qualities = terrain.uniqueObjects.filter { $0.pattern == "Considered [] when determining start locations" }
        for u in qualities where conditionalsApply(u, tile: t, region: region) {
            switch u.param(0) { case "Food": d.isFood = true; case "Desirable": d.isGood = true; case "Production": d.isProd = true; case "Undesirable": d.isJunk = true; default: break }
        }
        if qualities.isEmpty {
            if t.isWater { return d }
            if terrain.impassable { d.isJunk = true; return d }
            let improvements = rs.improvements.values.filter { $0.terrainsCanBeBuiltOn.contains(terrain.name) && !$0.isGreatImprovement && $0.uniqueTo == nil }
            let maxFood = terrain.stats.food + (improvements.map { $0.stats.food }.max() ?? 0)
            let maxProd = terrain.stats.production + (improvements.map { $0.stats.production }.max() ?? 0)
            let bestImp = improvements.map { $0.stats.sum }.max() ?? 0
            if maxFood >= 2 { d.isFood = true }
            if maxProd >= 2 { d.isProd = true }
            if terrain.stats.sum + bestImp >= 3 { d.isGood = true }
        }
        return d
    }
    private func placeImpact(_ type: ImpactType, _ i: Int, radius: Int) {
        tileData[i].impacts[type] = 99
        guard radius > 0 else { return }
        for ring in 1...radius {
            let ringValue = radius - ring + 1
            for o in tilesAtDistance(map.tiles[i].coord, ring) {
                if let existing = tileData[o].impacts[type] { tileData[o].impacts[type] = min(50, max(ringValue, existing) + 2) } else { tileData[o].impacts[type] = ringValue }
            }
        }
    }

    // MARK: - assign regions to civs (Unciv MapRegions.assignRegions)

    /// `civs` are nation names; returns nothing – see `startingLocations`.
    func assignRegions(civs: [String], noStartBias: Bool = false) {
        guard !civs.isEmpty else { return }
        tileDataInitialized = true
        guard !regions.isEmpty else { return }
        assignRegionTypes()
        regionOfTile = Array(repeating: -1, count: map.tiles.count)
        // Unciv `regions.firstOrNull { it.tiles.contains(tile) }`: the first region holding the tile
        for (ri, r) in regions.enumerated() { for i in r.tiles where regionOfTile[i] == -1 { regionOfTile[i] = ri } }
        tileData = (0..<map.tiles.count).map { evaluateTileData($0) }
        let dbgF = UncivSave.Frame.forExport(width: map.width, height: map.height)
        func dbgP(_ i: Int) -> String { let p = dbgF.unciv(col: map.tiles[i].coord.offsetCol, row: map.tiles[i].coord.offsetRow); return "\(p.x),\(p.y)" }
        if let f = MapRegions.debugRegionDump { for i in map.uncivTileListOrder() { let d = tileData[i]; f("TF \(dbgP(i)) j=\(d.isJunk) f=\(d.isFood) p=\(d.isProd) g=\(d.isGood) two=\(d.isTwoFromCoast) coast=\(isCoastal(map.tiles[i])) riv=\(map.tiles[i].riverAdjacent)\n") } }
        for region in regions.sorted(by: { $0.totalFertility < $1.totalFertility }) { findStart(region)
            if let f = MapRegions.debugRegionDump { let k = regions.firstIndex { $0 === region } ?? -1; for i in map.uncivTileListOrder() { let d = tileData[i]; if d.startScore != 0 || d.closeStartPenalty != 0 { f("TD \(k) \(dbgP(i)) s=\(d.startScore) g=\(d.isGoodStart) pen=\(d.closeStartPenalty)\n") } } } }
        if let f = MapRegions.debugRegionDump { for (k, r) in regions.enumerated() { let p = r.startPosition.map { UncivSave.Frame.forExport(width: map.width, height: map.height).unciv(col: $0.offsetCol, row: $0.offsetRow) }; f("START \(k) type=\(r.type) pos=HexCoord(x=\(p?.x ?? 999), y=\(p?.y ?? 999))\n") } }
        for region in regions { if let s = region.startPosition, let i = index(s) { normalizeStart(i, isMinorCiv: false) } }
        var biases: [String: [String]] = [:]
        for civ in civs { biases[civ] = noStartBias ? [] : startBias(nation: civ) }
        var coastCivs: [String] = [], positiveCivs: [String] = [], negativeCivs: [String] = [], randomCivs: [String] = []
        for civ in civs {
            let b = biases[civ] ?? []
            if b.contains(where: { $0.hasPrefix("Avoid [") }) { negativeCivs.append(civ) }
            else if b.contains("Coast") { coastCivs.append(civ) }
            else if !b.isEmpty { positiveCivs.append(civ) }
            else { randomCivs.append(civ) }
        }
        positiveCivs.sort { (biases[$0]?.count ?? 0) < (biases[$1]?.count ?? 0) }
        negativeCivs.sort { (biases[$0]?.count ?? 0) > (biases[$1]?.count ?? 0) }
        var unpicked = regions
        var fallbackCivs: [String] = []
        func take(_ civ: String, _ region: Region) { assignCivToRegion(civ, region); unpicked.removeAll { $0 === region } }
        func startTile(_ r: Region) -> Tile? { r.startPosition.flatMap { map[$0] } }
        for civ in coastCivs {
            let coastal = { (r: Region) -> Int in r.terrainCounts["Coastal"] ?? 0 }
            if let r = unpicked.filter({ startTile($0).map(isCoastal) ?? false }).max(by: { coastal($0) < coastal($1) }) { take(civ, r); continue }
            // Unciv MapRegions.assignRegions: a neighbour whose base terrain has "Fresh water" (lakes)
            if let r = unpicked.filter({ startTile($0).map { t in map.neighbors(of: t.coord).contains { map[$0].flatMap { rs.terrains[$0.baseTerrain] }?.uniques.contains("Fresh water") == true } } ?? false }).max(by: { coastal($0) < coastal($1) }) { take(civ, r); continue }
            if let r = unpicked.filter({ startTile($0)?.riverAdjacent ?? false }).max(by: { coastal($0) < coastal($1) }) { take(civ, r); continue }
            if let r = unpicked.filter({ r in startTile(r).map { t in map.neighbors(of: t.coord).contains { map[$0]?.riverAdjacent ?? false } } ?? false }).max(by: { coastal($0) < coastal($1) }) { take(civ, r); continue }
            randomCivs.append(civ)
        }
        for civ in positiveCivs {
            let preferred = biases[civ] ?? []
            if let r = unpicked.filter({ preferred.contains($0.type) }).max(by: { a, b in a.terrainCounts.filter { preferred.contains($0.key) }.values.reduce(0, +) < b.terrainCounts.filter { preferred.contains($0.key) }.values.reduce(0, +) }) { take(civ, r) }
            else if preferred.count == 1 { fallbackCivs.append(civ) }
            else { randomCivs.append(civ) }
        }
        for civ in fallbackCivs {
            let type = biases[civ]?.first ?? ""
            if let r = unpicked.max(by: { ($0.terrainCounts[type] ?? 0) < ($1.terrainCounts[type] ?? 0) }) { take(civ, r) } else { randomCivs.append(civ) }
        }
        for civ in negativeCivs {
            let b = biases[civ] ?? []
            let avoided = b.filter { $0.hasPrefix("Avoid [") }.map { String($0.dropFirst(7).dropLast()) }
            let preferred = b.filter { !$0.hasPrefix("Avoid [") }
            // Unciv MapRegions.kt:364-367 writes the score over two lines, `2 * <avoided sum>` and then `- <preferred sum>`
            // on the next: Kotlin ends the lambda's first statement at the line break, so the selector is only the
            // unary `-<preferred sum>` (0 for a civ that avoids only) and minByOrNull takes the first region not of an
            // avoided type, not the one with the least avoided terrain
            func score(_ r: Region) -> Int { -r.terrainCounts.filter { preferred.contains($0.key) }.values.reduce(0, +) }
            if let r = unpicked.filter({ !avoided.contains($0.type) }).min(by: { score($0) < score($1) }) { take(civ, r) } else { randomCivs.append(civ) }
        }
        for civ in randomCivs {
            // Unciv MapRegions.kt:382 `civ.state.stateBasedRandom("MapRegions.assignRegions")`.
            // Harita üretimi sırasında `civ.state` hâlâ `GameContext.EmptyState`'tir (hash 1237),
            // yani her civ AYNI tohumu alır. Unciv'de de öyle — birebir kopyalandı.
            var civRng = mapGenCivStateRandom("MapRegions.assignRegions")
            guard let r = civRng.pick(unpicked) else { break }
            take(civ, r)
        }
    }
    /// Unciv Nation.getStartBias: nation field + city-state type "Start bias []" uniques.
    func startBias(nation name: String) -> [String] {
        guard let n = rs.nations[name] else { return [] }
        return rs.startBias(of: n)
    }
    private func assignCivToRegion(_ civ: String, _ region: Region) {
        guard let s = region.startPosition, let i = index(s) else { return }
        if startingLocations[civ] == nil { startingLocationOrder.append(civ) }   // Unciv tileMap.addStartingLocation
        startingLocations[civ] = s
        placeImpact(.minorCiv, i, radius: 6); placeImpact(.luxury, i, radius: 3); placeImpact(.strategic, i, radius: 0); placeImpact(.bonus, i, radius: 3)
    }

    // MARK: - start finder (Unciv RegionStartFinder)

    private func centralRect(_ r: Rect, _ proportion: Double) -> Rect {
        var s = r
        func roundHalfUp(_ v: Double) -> Double { (v + 0.5).rounded(.down) }   // Unciv Kotlin roundToInt
        let w = r.width * proportion, h = r.height * proportion
        s.x = roundHalfUp(r.x + (r.width - w) / 2); s.y = roundHalfUp(r.y + (r.height - h) / 2)
        s.width = roundHalfUp(w); s.height = roundHalfUp(h)
        return s
    }
    /// Unciv `Sequence.toSet()`: a LinkedHashSet - the sequence's order, a repeat dropped
    private func linkedSet(_ tiles: [Int]) -> [Int] {
        var seen: Set<Int> = []
        return tiles.filter { seen.insert($0).inserted }
    }
    private func findStart(_ region: Region) {
        // Unciv's fallbackTiles is a HashSet<Tile>: at most one tile from each of seven disjoint lists, so a single
        // list bin that keeps insertion order
        var fallback: [Int] = []
        let centerTiles = linkedSet(tilesInRectangle(centralRect(region.rect, 0.33)))
        let center = Set(centerTiles)
        if findGoodPosition(centerTiles, region, &fallback) { return }
        let middleDonut = linkedSet(tilesInRectangle(centralRect(region.rect, 0.67)).filter { !center.contains($0) })
        let middle = Set(middleDonut)
        if findGoodPosition(middleDonut, region, &fallback) { return }
        // a lazy Sequence in Unciv: the rectangle's order, repeats and all
        let outer = tilesInRectangle(region.rect).filter { !center.contains($0) && !middle.contains($0) }
        if findEdgePosition(outer, region, &fallback) { return }
        findFallbackPosition(fallback, region)
    }
    private func findGoodPosition(_ candidates: [Int], _ region: Region, _ fallback: inout [Int]) -> Bool {
        var river: [Int] = [], wet: [Int] = [], dry: [Int] = []
        for i in candidates {
            if tileData[i].isTwoFromCoast { continue }
            if region.continentID != -1 && region.continentID != continentOf(i) { continue }
            let t = map.tiles[i]
            if t.isLand && !t.isImpassable {
                evaluateTileForStart(i)
                if t.riverAdjacent { river.append(i) } else if isCoastal(t) || adjacentToFreshWater(t) { wet.append(i) } else { dry.append(i) }
            }
        }
        // riverTiles / wetTiles / dryTiles are HashSet<Tile>(): each walks in JavaHash1Set order of its inserts, and
        // maxByOrNull keeps the first best in that walk
        for list in [JavaHash1Set.iterationOrder(river), JavaHash1Set.iterationOrder(wet), JavaHash1Set.iterationOrder(dry)] {
            let good = list.filter { tileData[$0].isGoodStart }
            if let best = good.max(by: { tileData[$0].startScore < tileData[$1].startScore }) { setRegionStart(region, best); return true }
            if let best = list.max(by: { tileData[$0].startScore < tileData[$1].startScore }) { fallback.append(best) }
        }
        return false
    }
    private func findEdgePosition(_ outer: [Int], _ region: Region, _ fallback: inout [Int]) -> Bool {
        var inserts: [Int] = []
        for i in outer {
            if region.continentID != -1 && region.continentID != continentOf(i) { continue }
            let t = map.tiles[i]
            if t.isLand && !t.isImpassable { evaluateTileForStart(i); inserts.append(i) }
        }
        let dry = JavaHash1Set.iterationOrder(inserts)   // HashSet<Tile>(): a repeat goes in once, the walk is hash-1 order
        let good = dry.filter { tileData[$0].isGoodStart }
        if !good.isEmpty {
            // rect.getCenter() in Float, then Kotlin roundToInt - floor(v + 0.5), so -13.5 is -13, not Swift's -14
            let cx = Stats.roundToInt(region.rect.x + region.rect.width / 2), cy = Stats.roundToInt(region.rect.y + region.rect.height / 2)
            // Unciv getIfTileExistsOrNull(x, y): the centre numbers are read as hex coordinates, not as a column and a
            // row; `?: region.tileMap.values.first()` - tileList's first tile
            let ref = map.tiles[uncivTileIndex(cx, cy) ?? map.uncivTileListOrder()[0]].coord
            if let best = good.min(by: { map.tiles[$0].coord.distance(to: ref) < map.tiles[$1].coord.distance(to: ref) }) { setRegionStart(region, best); return true }
        }
        if let best = dry.max(by: { tileData[$0].startScore < tileData[$1].startScore }) { fallback.append(best) }
        return false
    }
    private func findFallbackPosition(_ fallback: [Int], _ region: Region) {
        if let best = fallback.max(by: { tileData[$0].startScore < tileData[$1].startScore }) { setRegionStart(region, best); return }
        // Panic: turn the rectangle origin into land.
        let c = map.normalize(HexCoord.fromOffset(col: Int(region.rect.x), row: Int(region.rect.y)))
        guard let i = index(c) ?? region.tiles.first ?? map.tiles.indices.first else { return }
        map.tiles[i].baseTerrain = rs.terrains.values.first { $0.type == .land }?.name ?? "Grassland"
        map.tiles[i].features = []
        setRegionStart(region, i)
    }
    private func evaluateTileForStart(_ i: Int) {
        let t = map.tiles[i]
        var totalFood = 0, totalProd = 0, totalGood = 0, totalJunk = 0, totalRivers = 0, totalScore = 0
        var good = true
        if isCoastal(t) { totalScore += 40 }
        for ring in 1...3 {
            for o in tilesAtDistance(t.coord, ring) {
                let d = tileData[o]
                if d.isJunk { totalJunk += 1 }
                else {
                    if d.isFood { totalFood += 1 }
                    if d.isProd { totalProd += 1 }
                    if d.isGood { totalGood += 1 }
                    if map.tiles[o].riverAdjacent { totalRivers += 1 }
                }
            }
            if totalFood < MapRegions.minimumFoodForRing[ring]! || totalProd < MapRegions.minimumProdForRing[ring]! || totalGood < MapRegions.minimumGoodForRing[ring]! { good = false }
            switch ring {
            case 1:
                let f = MapRegions.firstRingFoodScores[min(totalFood, 6)], p = MapRegions.firstRingProdScores[min(totalProd, 6)]
                totalScore += f + p + totalRivers + totalGood * 2 - totalJunk * 3
            case 2:
                let f = totalFood > 10 ? MapRegions.secondRingFoodScores.last! : MapRegions.secondRingFoodScores[totalFood]
                let effProd = totalProd >= totalFood * 2 ? totalProd : (totalFood + 1) / 2
                let p = effProd > 5 ? MapRegions.secondRingProdScores.last! : MapRegions.secondRingProdScores[effProd]
                totalScore += f + p + totalRivers + totalGood * 2 - totalJunk * 3
            default:
                totalScore += totalFood + totalProd + totalGood + totalRivers - totalJunk * 2
            }
        }
        if totalJunk > MapRegions.maximumJunk { good = false }
        if tileData[i].closeStartPenalty > 0 { good = false; totalScore -= (totalScore * tileData[i].closeStartPenalty) / 100 }
        tileData[i].isGoodStart = good
        tileData[i].startScore = totalScore
    }
    private func setRegionStart(_ region: Region, _ i: Int) {
        region.startPosition = map.tiles[i].coord
        for (ring, penalty) in MapRegions.closeStartPenaltyForRing {
            for o in tilesAtDistance(map.tiles[i].coord, ring) { tileData[o].addCloseStartPenalty(penalty) }
        }
    }

    // MARK: - start normaliser (Unciv StartNormalizer)

    /// Unciv TileStatFunctions.getTileStats(null) as StartNormalizer asks it during map generation: no city, no
    /// observing civ - so no resource yield at all, no percentages - just getTerrainStatsBreakdown (base, natural
    /// wonder, then features; a nullifying terrain alone, an overriding one replacing what came before), the river
    /// (on any tile beside one), an unpillaged road's and improvement's own stats, and the city-centre minimum.
    private func startNormalizerTileStats(_ t: Tile) -> Stats {
        func singleTerrainStats(_ terrain: Terrain) -> Stats {
            var st = terrain.stats
            for u in terrain.uniqueObjects where u.pattern == "[]" && conditionalsApply(u, tile: t, region: nil) { if let extra = u.stats { st += extra } }
            return st
        }
        var list = Stats()
        var nullified = false
        for name in [t.baseTerrain] + (t.naturalWonder.map { [$0] } ?? []) + t.features {
            guard let terrain = rs.terrains[name] else { continue }
            if terrain.uniqueObjects.contains(where: { $0.pattern == "Nullifies all other stats this tile provides" && conditionalsApply($0, tile: t, region: nil) }) {
                list = singleTerrainStats(terrain); nullified = true; break
            }
            if terrain.overrideStats { list = singleTerrainStats(terrain) } else { list += singleTerrainStats(terrain) }
        }
        if t.riverAdjacent { list += rs.terrains["River"].map(singleTerrainStats) ?? Stats(gold: 1) }
        if !nullified {
            if (t.roads || t.railroad) && !t.roadPillaged, let road = rs.improvements[t.railroad ? "Railroad" : "Road"] { list += road.stats }
            if let imp = t.improvement, !t.pillaged, let def = rs.improvements[imp] { list += def.stats }
        }
        if t.isCityCenter { list.food = max(list.food, 2); list.production = max(list.production, 1) }   // Stats.DefaultCityCenterMinimum
        return list
    }
    /// Unciv StartNormalizer.getPotentialYield
    private func potentialYield(_ i: Int, _ stat: String, unimproved: Bool = false) -> Double {
        let t = map.tiles[i]
        let base = startNormalizerTileStats(t)[stat]
        if unimproved { return base }
        let lastName = t.features.last ?? t.naturalWonder ?? t.baseTerrain   // Unciv tile.lastTerrain
        let best = rs.improvements.values.filter { !$0.isGreatImprovement && $0.uniqueTo == nil && $0.terrainsCanBeBuiltOn.contains(lastName) }.map { $0.stats[stat] }.max() ?? 0
        return base + best
    }
    private func normalizeStart(_ i: Int, isMinorCiv: Bool) {
        let c = map.tiles[i].coord
        for n in neighborIndices(i) {
            // Unciv StartNormalizer: the last impassable (ice-like) feature of each neighbour is removed
            if let idx = map.tiles[n].features.lastIndex(where: { rs.terrains[$0]?.impassable == true }) { map.tiles[n].features.remove(at: idx) }
        }
        if !isMinorCiv && strategicBalance { placeStrategicBalanceResources(i) }
        normalizeProduction(i, isMinorCiv: isMinorCiv)
        let needed = calculateFoodBonusesNeeded(i, isMinorCiv: isMinorCiv)
        placeFoodBonuses(i, isMinorCiv: isMinorCiv, needed: needed)
        if isMinorCiv { return }
        addProductionBonuses(i)
        _ = c
    }
    private func normalizeProduction(_ i: Int, isMinorCiv: Bool) {
        let c = map.tiles[i].coord
        let inner = neighborIndices(i).reduce(0) { $0 + Int(potentialYield($1, "Production")) }
        let outer = tilesAtDistance(c, 2).reduce(0) { $0 + Int(potentialYield($1, "Production")) }
        let early = tilesInRange(c, 1...2).reduce(0) { $0 + (potentialYield($1, "Food", unimproved: true) > 0 ? Int(potentialYield($1, "Production", unimproved: true)) : 0) }
        if inner == 0 || (inner < 2 && outer < 8) || (isMinorCiv && inner < 4) {
            let spots = neighborIndices(i).filter { let t = map.tiles[$0]; return t.isLand && t.features.isEmpty && !adjacentToFreshWater(t) && !t.isImpassable }
            let hill = rs.terrains.values.filter { $0.type == .terrainFeature && $0.stats.production >= 2 && !$0.uniques.contains("Rare feature") }.sorted { $0.name < $1.name }.first?.name
            // Unciv StartNormalizer.kt:52 `GameContext(civInfo = startTile.getOwner(), tile = startTile)`.
            // Harita üretiminde karo sahipsizdir (`Tile.getOwner() = getCity()?.civ`, şehir yok), yani
            // bağlam `GameContext(tile = startTile)` ile AYNI hash'i verir — Unciv.jar'da ölçüldü.
            // Aşağıdaki iki `rng.shuffled` Unciv'de tohumsuz `shuffled()`; paylaşılan akışta bırakıldı.
            let prodPos = uncivPosition(i)
            var prodRng = mapGenTileRandom("StartNormalizer.normalizeProduction", x: prodPos.x, y: prodPos.y)
            if let s = prodRng.pick(spots), let h = hill { map.tiles[s].features.append(h) }
        }
        if !isMinorCiv && inner < 3 && early < 6 {
            let lastEra = rs.eras.count - 1
            let earlyEras = Set(rs.eras.enumerated().filter { $0.offset <= lastEra / 3 }.map { $0.element.name })
            let valid = rng.shuffled(rs.resourcesInOrder.filter { r in r.resourceType == "Strategic" && (r.revealedBy == nil || earlyEras.contains(rs.techs[r.revealedBy!]?.era ?? "")) })
            let candidates = rng.shuffled(tilesAtDistance(c, 2))
            for r in valid { if tryAddingResource(r, amount: 1, tiles: candidates) > 0 { break } }
        }
    }
    private func placeStrategicBalanceResources(_ i: Int) {
        let c = map.tiles[i].coord
        let candidates = rng.shuffled(tilesInRange(c, 1...2)) + rng.shuffled(tilesAtDistance(c, 3))
        for r in rs.resourcesInOrder.filter({ $0.uniques.contains("Guaranteed with Strategic Balance resource option") }) {
            if tryAddingResource(r, amount: 1, tiles: candidates, majorDeposit: true) == 0 {
                let tiles = isWaterOnly(r) ? candidates.filter { map.tiles[$0].isWater && !map.tiles[$0].isImpassable } : candidates.filter { map.tiles[$0].isLand && !map.tiles[$0].isImpassable }
                _ = placeResourcesInTiles(frequency: 999, tiles: tiles, options: [r], baseImpact: 0, randomImpact: 0, majorDeposit: true)
            }
        }
    }
    private func addProductionBonuses(_ i: Int) {
        let c = map.tiles[i].coord
        var grass = tilesInRange(c, 1...2).filter { map.tiles[$0].isLand && potentialYield($0, "Food", unimproved: true) >= 2 && potentialYield($0, "Production") == 0 }
        let plains = tilesInRange(c, 1...2).filter { map.tiles[$0].isLand && potentialYield($0, "Food") >= 2 && potentialYield($0, "Production", unimproved: true) >= 1 }
        var needed = grass.count >= 9 && plains.isEmpty ? 2 : (grass.count >= 6 && plains.count <= 4 ? 1 : 0)
        let bonuses = rs.resourcesInOrder.filter { $0.resourceType == "Bonus" && $0.stats.production > 0 }
        guard !bonuses.isEmpty else { return }
        // Unciv StartNormalizer.kt:140 `GameContext(gameInfo = startTile.tileMap.gameInfo)` — karo
        // DEĞİL, oyun bağlamı: tohum yalnızca gameId/harita tohumuna bağlı, her start için aynı akış.
        var bonusRng = mapGenGameRandom("StartNormalizer.addProductionBonuses", gameHash: gameHash)
        while needed > 0, !grass.isEmpty {
            let plot = bonusRng.pick(grass)!
            grass.removeAll { $0 == plot }
            if map.tiles[plot].resource != nil { continue }
            if let b = bonusRng.pick(bonuses.filter { generatesNaturallyOn($0, map.tiles[plot]) }) { map.tiles[plot].resource = b.name; needed -= 1 }
        }
    }
    private func calculateFoodBonusesNeeded(_ i: Int, isMinorCiv: Bool) -> Int {
        let c = map.tiles[i].coord
        let inner = neighborIndices(i).reduce(0) { $0 + Int(pow(potentialYield($1, "Food"), 2) / 4) }
        let outer = tilesAtDistance(c, 2).reduce(0) { $0 + Int(pow(potentialYield($1, "Food"), 2) / 4) }
        let total = inner + outer
        let innerTwo = neighborIndices(i).filter { potentialYield($0, "Food", unimproved: true) >= 2 }.count
        let outerTwo = tilesAtDistance(c, 2).filter { potentialYield($0, "Food", unimproved: true) >= 2 }.count
        let totalTwo = innerTwo + outerTwo
        var needed: Int
        if isMinorCiv { needed = (total < 12 || inner < 4) ? 2 : (total < 16 || inner < 9) ? 1 : 0 }
        else {
            if inner == 0 && total < 4 { needed = 5 }
            else if total < 6 { needed = 4 }
            else if total < 8 || (total < 12 && inner < 5) { needed = 3 }
            else if (total < 17 && inner < 9) || totalTwo < 2 { needed = 2 }
            else if (total < 24 && inner < 11) || totalTwo == 2 || innerTwo == 0 || total < 20 { needed = 1 }
            else { needed = 0 }
        }
        if legendaryStart { needed += 2 }
        if !isMinorCiv && needed < 3 && totalTwo == 0 {
            let twoFood = rs.terrains.values.filter { $0.type == .land && $0.stats.food >= 2 }.sorted { $0.name < $1.name }.first?.name
            let innerSpots = neighborIndices(i).filter { let t = map.tiles[$0]; return t.isLand && !t.isImpassable && t.features.isEmpty && t.resource == nil }
            let outerSpots = tilesAtDistance(c, 2).filter { let t = map.tiles[$0]; return t.isLand && !t.isImpassable && t.features.isEmpty && t.resource == nil }
            if let terrain = twoFood, let spot = rng.pick(innerSpots) ?? rng.pick(outerSpots) { map.tiles[spot].baseTerrain = terrain } else { needed = 3 }
        }
        return needed
    }
    private func placeFoodBonuses(_ i: Int, isMinorCiv: Bool, needed: Int) {
        let c = map.tiles[i].coord
        // Unciv StartNormalizer.kt:249 `GameContext(tile = startTile).stateBasedRandom("StartNormalizer.placeFoodBonuses")`
        // — üreteç fonksiyon başında bir kez kurulur. Aday listesinin `shuffled()`'ı Unciv'de
        // tohumsuzdur; paylaşılan akışta bırakıldı.
        let foodPos = uncivPosition(i)
        var foodRng = mapGenTileRandom("StartNormalizer.placeFoodBonuses", x: foodPos.x, y: foodPos.y)
        var still = needed
        let oasis = rs.terrains.values.filter { t in t.type == .terrainFeature && t.uniques.contains("Rare feature") && t.stats.food >= 2 && t.stats.food + t.stats.production + t.stats.gold >= 3 && t.occursOn.contains { rs.terrains[$0]?.type == .land } }.sorted { $0.name < $1.name }.first
        var canPlaceOasis = oasis != nil
        var placedFirst = 0, placedSecond = 0
        let range = isMinorCiv ? 2 : 3
        var candidates = rng.shuffled(tilesInRange(c, 1...range).filter { i in map.tiles[i].resource == nil && !(oasis.map { map.tiles[i].features.contains($0.name) } ?? false) })
        candidates.sort { map.tiles[$0].coord.distance(to: c) < map.tiles[$1].coord.distance(to: c) }
        while still > 0, !candidates.isEmpty {
            let plot = candidates.removeFirst()
            let t = map.tiles[plot]
            if rs.terrains[t.baseTerrain]?.uniqueObjects.contains(where: { $0.pattern == "Never receives any resources" && conditionalsApply($0, tile: t, region: nil) }) == true { continue }
            let valid = rs.resourcesInOrder.filter { $0.resourceType == "Bonus" && $0.stats.food >= 1 && generatesNaturallyOn($0, t) }
            let goodForOasis = canPlaceOasis && (oasis!.occursOn.contains(t.features.last ?? t.baseTerrain))
            if !valid.isEmpty || goodForOasis {
                if goodForOasis { map.tiles[plot].features.append(oasis!.name); canPlaceOasis = false }
                else if let r = foodRng.pick(valid) { map.tiles[plot].resource = r.name }
                let d = t.coord.distance(to: c)
                if d == 1 { placedFirst += 1; if placedFirst == 2 { candidates.sort { abs(map.tiles[$0].coord.distance(to: c) * 10 - 22) < abs(map.tiles[$1].coord.distance(to: c) * 10 - 22) } } }
                else if d == 2 { placedSecond += 1; if placedSecond == 3 { candidates.sort { abs(map.tiles[$0].coord.distance(to: c) * 10 - 17) > abs(map.tiles[$1].coord.distance(to: c) * 10 - 17) } } }
                still -= 1
            }
        }
    }

    // MARK: - resources & minor civs (Unciv placeResourcesAndMinorCivs)

    /// `minorCivs` are city-state nation names; those that could not be placed are left out of `startingLocations`.
    func placeResourcesAndMinorCivs(minorCivs: [String]) throws {
        // Unciv reads tileData first thing (placeNaturalWonderImpacts, else assignLuxuries' argument); ours indexed the
        // empty list and stopped the app
        guard tileDataInitialized else { throw TileDataUninitialized() }
        // Unciv placeNaturalWonderImpacts: `tileMap.values.filter { it.isNaturalWonder() }` - tileList order, which
        // matters where two wonder tiles touch (the later epicentre's 99 or the earlier one's ring wins)
        for i in map.uncivTileListOrder() where map.tiles[i].naturalWonder != nil { for type in [ImpactType.bonus, .strategic, .luxury, .minorCiv] { placeImpact(type, i, radius: 1) } }
        let (cityStateLuxuries, randomLuxuries) = assignLuxuries()
        placeMinorCivs(minorCivs)
        placeLuxuries(cityStateLuxuries: cityStateLuxuries, randomLuxuries: randomLuxuries)
        placeStrategicAndBonuses()
    }

    // MARK: luxuries (Unciv LuxuryResourcePlacementLogic)

    private func assignLuxuries() -> ([String], [String]) {
        let fallbackWeightings = !rs.resources.values.contains { r in r.resourceType == "Luxury" && r.uniqueObjects.contains { $0.pattern == "Generated with weight []" || $0.pattern == "Generated near City States with weight []" } }
        let maxRegionsWithLuxury = regions.count > 14 ? 3 : regions.count > 10 ? 2 : 1
        let assignable = rs.resourcesInOrder.filter { r in r.resourceType == "Luxury" && !r.uniques.contains("Special placement during map generation") && !r.uniques.contains("Can only be created by Mercantile City-States") }
        var amount: [String: Int] = [:]
        for r in rs.resources.values { amount[r.name] = 0 }
        // Unciv LuxuryResourcePlacementLogic.kt:29 `GameContext(gameInfo = regions[0].tileMap.gameInfo)`
        // — dört şehir devleti lüksü boyunca TEK akış (`assignCityStateLuxuries(..., globalRng)`).
        var globalRng = mapGenGameRandom("LuxuryResourcePlacementLogic.assignLuxuries", gameHash: gameHash)
        for region in regions.sorted(by: { (regionPriority(rs.terrains[$0.type]) ?? 99999) < (regionPriority(rs.terrains[$1.type]) ?? 99999) }) {
            let candidates = candidateLuxuries(assignable, amount, maxRegionsWithLuxury, fallbackWeightings, region)
            if candidates.isEmpty { continue }
            // Unciv LuxuryResourcePlacementLogic.kt:52 `GameContext(gameInfo = ..., region = region)`
            // — bölge başına YENİ akış; bölgenin katkısı yalnızca `rect.hashCode()`'udur.
            var regionRng = mapGenGameRandom("LuxuryResourcePlacementLogic.assignLuxuries", gameHash: gameHash, regionRectHash: regionRectHash(region))
            guard let picked = MapRegions.randomWeighted(candidates, &regionRng, { r in
                let w = r.uniqueObjects.first { $0.pattern == "Generated with weight []" && conditionalsApply($0, tile: nil, region: region) }?.double(0) ?? 1
                return w / Double(1 + (amount[r.name] ?? 0))
            }) else { continue }
            region.luxury = picked.name
            amount[picked.name, default: 0] += 1
        }
        var cityStateLuxuries: [String] = []
        for _ in 0..<4 {
            let candidates = assignable.filter { r in amount[r.name] == 0 && (fallbackWeightings || r.uniqueObjects.contains { $0.pattern == "Generated near City States with weight []" }) }
            guard let picked = MapRegions.randomWeighted(candidates, &globalRng, { r in r.uniqueObjects.first { $0.pattern == "Generated near City States with weight []" }?.double(0) ?? 1 }) else { break }
            cityStateLuxuries.append(picked.name); amount[picked.name] = 1
        }
        let remaining = rng.shuffled(assignable.filter { amount[$0.name] == 0 }.map { $0.name })
        let disabledPercent = 100 - Int(min(pow(Double(map.realTileCount), 0.2) * 16, 100))
        let disabled = (remaining.count * disabledPercent) / 100
        return (cityStateLuxuries, Array(remaining.dropFirst(disabled)))
    }
    private func candidateLuxuries(_ assignable: [ResourceDef], _ amount: [String: Int], _ maxRegions: Int, _ fallback: Bool, _ region: Region) -> [ResourceDef] {
        let coastalStart = region.startPosition.flatMap { map[$0] }.map(isCoastal) ?? false
        var c = assignable.filter { r in (amount[r.name] ?? 0) < maxRegions && (fallback || r.uniqueObjects.contains { $0.pattern == "Generated with weight []" && conditionalsApply($0, tile: nil, region: region) }) && (((region.terrainCounts["Coastal"] ?? 0) >= 12 && coastalStart) || !isWaterOnly(r)) }
        if c.isEmpty { c = assignable.filter { r in (amount[r.name] ?? 0) < maxRegions && ((region.terrainCounts["Coastal"] ?? 0) >= 12 || r.terrainsCanBeFoundOn.contains { n in rs.terrains[n]?.type != .water }) } }
        if c.isEmpty { c = assignable.filter { (amount[$0.name] ?? 0) < maxRegions } }
        return c
    }
    private func placeLuxuries(cityStateLuxuries: [String], randomLuxuries: [String]) {
        placeLuxuriesAtMajorStarts(randomLuxuries)
        placeLuxuriesAtMinorStarts(randomLuxuries: randomLuxuries, cityStateLuxuries: cityStateLuxuries)
        addRegionalLuxuries()
        addRandomLuxuries(randomLuxuries)
        let specials = rs.resourcesInOrder.filter { $0.resourceType == "Luxury" && $0.uniques.contains("Special placement during map generation") }
        var placedSpecials: [String: Int] = [:]
        for s in specials { placedSpecials[s.name] = 0 }
        addExtraLuxuryToStarts(randomLuxuries: randomLuxuries, specials: specials, cityStateLuxuries: cityStateLuxuries, placedSpecials: &placedSpecials)
        for s in specials {
            let target = Int(Double(regions.count) * resourceSetting.specialLuxuriesTargetFactor)
            let n = max(2, target - (placedSpecials[s.name] ?? 0))
            _ = tryAddingResource(s, amount: n, tiles: rng.shuffled(realIndices), ratio: 1, respectImpacts: true, baseImpact: 6, randomImpact: 0)
        }
    }
    private func placeLuxuriesAtMajorStarts(_ randomLuxuries: [String]) {
        let totalTiles = regions.reduce(0) { $0 + $1.tiles.count }
        // Unciv: `sumOf { totalFertility } / sumOf { tiles.size }.toFloat()` - a Float
        let avgDensity: Float = totalTiles > 0 ? Float(regions.reduce(0) { $0 + $1.totalFertility }) / Float(totalTiles) : 0
        /// Kotlin `sortedBy { it.getTileFertility(false) }`: a stable sort
        func byFertility(_ tiles: [Int]) -> [Int] {
            let f = tiles.map { fertility(map.tiles[$0], checkCoasts: false) }
            return tiles.indices.sorted { f[$0] != f[$1] ? f[$0] < f[$1] : $0 < $1 }.map { tiles[$0] }
        }
        for region in regions {
            guard let s = region.startPosition else { continue }
            var target = 2
            if legendaryStart { target += 1 }
            if !region.tiles.isEmpty && Float(region.totalFertility) / Float(region.tiles.count) < avgDensity { target += 1 }
            guard let lux = region.luxury.flatMap({ rs.resources[$0] }) else { continue }
            // `getTilesInDistanceRange(1..2).shuffled().sortedBy {}` is a lazy Sequence (Sequence.shuffled builds a
            // `sequence {}`): every pass over it shuffles and sorts afresh - the first pass, the second pass's head
            // and each compensation try
            func firstPass() -> [Int] { byFertility(rng.shuffled(tilesInRange(s, 1...2))) }
            target -= tryAddingResource(lux, amount: target, tiles: firstPass(), ratio: 0.5)
            if target > 0 {
                let head = firstPass()
                let second = head + byFertility(rng.shuffled(tilesAtDistance(s, 3)))
                target -= tryAddingResource(lux, amount: target, tiles: second)
            }
            if target > 0 { for name in randomLuxuries { if let r = rs.resources[name], tryAddingResource(r, amount: 1, tiles: firstPass()) > 0 { break } } }
        }
    }
    private func placeLuxuriesAtMinorStarts(randomLuxuries: [String], cityStateLuxuries: [String]) {
        // Unciv LuxuryResourcePlacementLogic.kt:354 — üreteç döngüden ÖNCE bir kez kurulur ve
        // yalnızca `rng.nextInt(100)` ondan çekilir; listelerin `shuffled()`'ı Unciv'de tohumsuzdur.
        var minorLuxRng = mapGenGameRandom("LuxuryResourcePlacementLogic.placeLuxuriesAtMinorCivStartLocations", gameHash: gameHash)
        // `startingLocationsByNation.filterKeys { isCityState }`: the HashMap's bucket order over ALL its keys
        // (the capacity counts the majors too), filtered afterwards
        for nation in javaHashMapOrder(startingLocationOrder) where rs.nations[nation]?.isCityState == true {
            guard let s = startingLocations[nation], let i = index(s) else { continue }
            let region = regionOf(i)
            let tiles = tilesInRange(s, 1...2)
            let global = region?.luxury != nil ? randomLuxuries + [region!.luxury!] : randomLuxuries
            let candidates = minorLuxRng.nextInt(below: 100) >= 25 ? rng.shuffled(cityStateLuxuries) + rng.shuffled(global) : rng.shuffled(global) + rng.shuffled(cityStateLuxuries)
            for name in candidates { if let r = rs.resources[name], tryAddingResource(r, amount: 1, tiles: tiles) > 0 { break } }
        }
    }
    private func addRegionalLuxuries() {
        // Unciv LuxuryResourcePlacementLogic.kt:309 — tek akış, bütün bölgeler boyunca sürüyor.
        // Çekim `nextFloat()`, `nextDouble()` DEĞİL (aynı tohumdan farklı sayı dizisi verirler).
        var regionalRng = mapGenGameRandom("LuxuryResourcePlacementLogic.addRegionalLuxuries", gameHash: gameHash)
        let size = map.realTileCount
        let ideal = max(2, size / 500)
        var target = size / 600 - Int(0.3 * Double(abs(regions.count - ideal)))
        target += resourceSetting.regionalLuxuriesDelta
        target = max(1, target)
        target = min(regions.count - 3, target)
        for region in regions {
            guard let name = region.luxury, let r = rs.resources[name], let s = region.startPosition else { continue }
            // water-only: getTilesInRectangle(rect) in its column-major order, `isShoreOfContinent`; otherwise
            // `region.tiles` in its HashSet order
            let candidates: [Int] = isWaterOnly(r)
                ? tilesInRectangle(region.rect).filter { i in map.tiles[i].isWater && neighborIndices(i).contains { continentOf($0) == region.continentID } }
                : region.tiles
            // `getDistance(position, startPosition) + rng.nextFloat() * 20f`: one draw per candidate in that order, an
            // Int (no world-wrap shortcut) plus a Float, in Float; then the stable sortedBy
            let keys = candidates.map { Float(rawDistance(map.tiles[$0].coord, s)) + regionalRng.nextFloat() * 20 }
            let sorted = candidates.indices.sorted { keys[$0] != keys[$1] ? keys[$0] < keys[$1] : $0 < $1 }.map { candidates[$0] }
            _ = tryAddingResource(r, amount: target, tiles: sorted, ratio: 0.4, respectImpacts: true, baseImpact: 4, randomImpact: 2)
        }
    }
    private func addRandomLuxuries(_ randomLuxuries: [String]) {
        guard !randomLuxuries.isEmpty else { return }
        // Unciv LuxuryResourcePlacementLogic.kt:274 — tek çekim: `rng.nextInt(regions.size)`.
        var randomLuxRng = mapGenGameRandom("LuxuryResourcePlacementLogic.addRandomLuxuries", gameHash: gameHash)
        var target = Int(pow(Double(map.realTileCount), 0.45))
        target = target * resourceSetting.randomLuxuriesPercent / 100
        target += randomLuxRng.nextInt(below: regions.count)
        let minimum = Int(pow(Double(map.realTileCount), 0.2))
        // `tileMap.values.asSequence().shuffled()` is a lazy Sequence: each luxury's pass over it is a new permutation
        for (idx, name) in rng.shuffled(randomLuxuries).enumerated() {
            guard let r = rs.resources[name] else { continue }
            let forThis: Int
            if randomLuxuries.count > 8 { forThis = target / 10 }
            else { forThis = max(max(3, minimum - idx), Int(Double(target) * (MapRegions.randomLuxuryRatios[randomLuxuries.count]?[idx] ?? 0.1) + 0.5)) }
            _ = tryAddingResource(r, amount: forThis, tiles: rng.shuffled(map.uncivTileListOrder()), ratio: 0.25, respectImpacts: true, baseImpact: 4, randomImpact: 2)
        }
    }
    private func addExtraLuxuryToStarts(randomLuxuries: [String], specials: [ResourceDef], cityStateLuxuries: [String], placedSpecials: inout [String: Int]) {
        if resourceSetting.randomLuxuriesPercent == 80 { return }   // Sparse
        for region in regions {
            guard let s = region.startPosition else { continue }
            let tiles = tilesInRange(s, 1...2)
            var candidates = rng.shuffled(randomLuxuries)
            if !strategicBalance { candidates += rng.shuffled(specials.map { $0.name }) }
            candidates += rng.shuffled(cityStateLuxuries)
            candidates += rng.shuffled(regions.compactMap { $0.luxury })
            for name in candidates {
                if let r = rs.resources[name], tryAddingResource(r, amount: 1, tiles: tiles) > 0 {
                    if placedSpecials[name] != nil { placedSpecials[name]! += 1 }
                    break
                }
            }
        }
    }

    // MARK: minor civs (Unciv MinorCivPlacer)

    private func placeMinorCivs(_ civs: [String]) {
        guard !civs.isEmpty else { return }
        var unassigned = assignMinorCivsDirectlyToRegions(civs)
        var uninhabitedCoastal: [Int] = [], uninhabitedHinterland: [Int] = [], toUninhabited: [String] = []
        if !usingArchipelagoRegions {
            let uninhabited = Set(continentSizes.filter { entry in entry.value >= 4 && !regions.contains { r in r.continentID == entry.key } }.keys)
            var inhabited = 0, unin = 0
            // Unciv `for (tile in tileMap.values)`: tileList order, which the pools keep and `pool.random(rng)` indexes
            for i in map.uncivTileListOrder() where canPlaceMinorCiv(i) {
                if uninhabited.contains(continentOf(i)) { if isCoastal(map.tiles[i]) { uninhabitedCoastal.append(i) } else { uninhabitedHinterland.append(i) }; unin += 1 } else { inhabited += 1 }
            }
            let maxByUninhabited = inhabited + unin > 0 ? (3 * civs.count * unin) / (inhabited + unin) : 0
            let maxByRatio = (civs.count + 1) / 2
            let target = min(maxByRatio, maxByUninhabited)
            let ordered = unassigned.filter { prefersCoast($0) } + unassigned.filter { !prefersCoast($0) }
            let chosen = Array(ordered.prefix(target))
            unassigned.removeAll { chosen.contains($0) }
            toUninhabited = chosen
        }
        if !unassigned.isEmpty {
            let common = regions.filter { r in regions.filter { $0.luxury == r.luxury }.count >= 3 }
            if !common.isEmpty && common.count <= unassigned.count { for r in common { r.assignedMinorCivs.append(unassigned.removeFirst()) } }
        }
        while !unassigned.isEmpty && unassigned.count >= regions.count && !regions.isEmpty { for r in regions { r.assignedMinorCivs.append(unassigned.removeFirst()) } }
        if !unassigned.isEmpty { for r in regions.sorted(by: { $0.totalFertility < $1.totalFertility }).prefix(unassigned.count) { r.assignedMinorCivs.append(unassigned.removeFirst()) } }
        tryPlaceMinorCivs(&toUninhabited, in: uninhabitedCoastal)
        tryPlaceMinorCivs(&toUninhabited, in: uninhabitedHinterland)
        // Unciv MinorCivPlacer.kt:179 `unplacedCiv.state.stateBasedRandom("MinorCivPlacer.placeAssignedMinorCivs")`.
        // `civ.state` harita üretiminde `GameContext.EmptyState` olduğu için her civ aynı tohumu ve
        // (liste değişmediğinden) aynı bölgeyi alır. Unciv'de de böyle.
        for civ in toUninhabited {
            var civRng = mapGenCivStateRandom("MinorCivPlacer.placeAssignedMinorCivs")
            civRng.pick(regions)?.assignedMinorCivs.append(civ)
        }
        // `region.tiles.toMutableList()`: the HashSet's walk
        for r in regions { var list = r.assignedMinorCivs; tryPlaceMinorCivs(&list, in: r.tiles); r.assignedMinorCivs = list }
    }
    private func assignMinorCivsDirectlyToRegions(_ civs: [String]) -> [String] {
        let ratio = Double(civs.count) / Double(max(1, regions.count))
        let perRegion = ratio > 14 ? 10 : ratio > 11 ? 8 : ratio > 8 ? 6 : ratio > 5.7 ? 4 : ratio > 4.35 ? 3 : ratio > 2.7 ? 2 : ratio > 1.35 ? 1 : 0
        var unassigned = rng.shuffled(civs)
        if perRegion > 0 { for r in regions { let take = Array(unassigned.prefix(perRegion)); r.assignedMinorCivs += take; unassigned.removeFirst(take.count) } }
        return unassigned
    }
    private func prefersCoast(_ nation: String) -> Bool { startBias(nation: nation).contains("Coast") }
    private func canPlaceMinorCiv(_ i: Int) -> Bool {
        let t = map.tiles[i]
        return !t.isWater && !t.isImpassable && !tileData[i].isJunk && !(rs.terrains[t.baseTerrain]?.uniqueObjects.contains { u in u.pattern == "Considered [] when determining start locations" && u.param(0) == "Undesirable" } ?? false) && map.neighbors(of: t.coord).count == 6
    }
    private func tryPlaceMinorCivs(_ civs: inout [String], in tiles: [Int]) {
        var pool = tiles
        civs.sort { (startBias(nation: $0).count, prefersCoast($0) ? 1 : 0) > (startBias(nation: $1).count, prefersCoast($1) ? 1 : 0) }
        while !pool.isEmpty, let civ = civs.first {
            let preferred = filterTilesByStartBias(pool, startBias(nation: civ))
            // Unciv MinorCivPlacer.kt:242 `GameContext(gameInfo = tileMap.gameInfo)` — üreteç while
            // döngüsünün İÇİNDE kuruluyor, yani her turda aynı tohumla sıfırlanıyor; havuz küçüldükçe
            // seçilen indeks değişiyor. Caller dizesindeki yazım hatası ("MinorCivPlcer") Unciv'in
            // kendi kaynağında böyle ve TOHUMA GİRİYOR — düzeltilmedi.
            var poolRng = mapGenGameRandom("MinorCivPlcer.tryPlaceMinorCivsInTiles", gameHash: gameHash)
            guard let chosen = poolRng.pick(preferred.isEmpty ? pool : preferred) else { break }
            pool.removeAll { $0 == chosen }
            if tileData[chosen].impacts[.minorCiv] != nil { continue }
            civs.removeFirst()
            if startingLocations[civ] == nil { startingLocationOrder.append(civ) }   // Unciv tileMap.addStartingLocation
            startingLocations[civ] = map.tiles[chosen].coord
            placeImpact(.minorCiv, chosen, radius: 4); placeImpact(.luxury, chosen, radius: 3); placeImpact(.strategic, chosen, radius: 0); placeImpact(.bonus, chosen, radius: 3)
            normalizeStart(chosen, isMinorCiv: true)
        }
    }
    private func filterTilesByStartBias(_ tiles: [Int], _ biases: [String]) -> [Int] {
        var preferred = tiles
        for bias in biases {
            if bias.hasPrefix("Avoid [") {
                let avoid = String(bias.dropFirst(7).dropLast())
                preferred = preferred.filter { i in !([i] + neighborIndices(i)).contains { terrainMatches(map.tiles[$0], avoid) } }
            } else {
                preferred = preferred.filter { i in ([i] + neighborIndices(i)).contains { terrainMatches(map.tiles[$0], bias) } }
            }
        }
        return preferred
    }

    // MARK: strategic & bonus (Unciv StrategicBonusResourcePlacementLogic)

    private func anonymized(_ u: Unique) -> String { "RULE " + u.conditionals.map { $0.text }.sorted().map { "<\($0)>" }.joined(separator: " ") }
    private func terrainRule(_ terrain: Terrain) -> String {
        if terrain.type == .terrainFeature {
            if terrain.uniqueObjects.contains(where: { $0.pattern == "Has an elevation of [] for visibility calculations" }) { return "RULE <in [\(terrain.name)] tiles>" }
            let elevated = rs.terrains.values.filter { t in t.type == .terrainFeature && t.uniqueObjects.contains { $0.pattern == "Has an elevation of [] for visibility calculations" } }.map { $0.name }.sorted()
            return anonymized(Unique("RULE <in [\(terrain.name)] tiles> " + elevated.map { "<in tiles without [\($0)]>" }.joined(separator: " ")))
        }
        return anonymized(Unique("RULE <in [Featureless] [\(terrain.name)] tiles>"))
    }
    private func placeStrategicAndBonuses() {
        let strategic = rs.resourcesInOrder.filter { $0.resourceType == "Strategic" }
        // Unciv asks hasUnique with an empty game state, which evaluates the modifiers - and every placement
        // unique in the shipped ruleset carries an <in [...] tiles> modifier, which answers false without a tile.
        // So Unciv concludes the ruleset defines no placement rules and takes its fallback path, though the
        // ruleset plainly does define them. Mirrored, quirk and all: this is what Unciv's maps are made of.
        let fallbackStrategic = !rs.resources.values.contains { r in (r.resourceType == "Strategic" && r.uniqueObjects.contains { $0.pattern == "Generated with weight []" && $0.conditionals.isEmpty }) || r.uniqueObjects.contains { $0.pattern == "Minor deposits generated with weight []" && $0.conditionals.isEmpty } }
        let bonusMultiplier = resourceSetting.bonusFrequencyMultiplier
        var landList: [Int] = []
        var ruleLists: [String: [Int]] = [:]
        var ruleUniques: [String: Unique] = [:]
        for r in rs.resources.values where r.resourceType == "Strategic" || r.resourceType == "Bonus" {
            for u in r.uniqueObjects where ["Generated on every [] tiles", "Generated with weight []", "Minor deposits generated with weight []"].contains(u.pattern) {
                if u.conditionals.contains(where: { c in (c.pattern == "on water maps" && !usingArchipelagoRegions) || (c.pattern == "in [] Regions" && !regions.contains { $0.type == c.param(0) }) || (c.pattern == "in all except [] Regions" && regions.allSatisfy { $0.type == c.param(0) }) }) { continue }
                let key = anonymized(u)
                if ruleLists[key] == nil { ruleLists[key] = []; ruleUniques[key] = u }
            }
        }
        if fallbackStrategic {
            for terrain in Set(strategic.flatMap { $0.terrainsCanBeFoundOn }).compactMap({ rs.terrains[$0] }) {
                let key = terrain.type == .terrainFeature ? anonymized(Unique("RULE <in [\(terrain.name)] tiles>")) : anonymized(Unique("RULE <in [Featureless] [\(terrain.name)] tiles>"))
                if ruleLists[key] == nil { ruleLists[key] = []; ruleUniques[key] = Unique(key) }
            }
        }
        for i in rng.shuffled(realIndices) {
            let t = map.tiles[i]
            if rs.terrains[t.baseTerrain]?.uniqueObjects.contains(where: { $0.pattern == "Never receives any resources" && conditionalsApply($0, tile: t, region: nil) }) == true { continue }
            if t.isLand { landList.append(i) }
            let region = regionOf(i)
            for (key, u) in ruleUniques where conditionalsApply(u, tile: t, region: region) { ruleLists[key]!.append(i) }
        }
        var totalPlaced: [String: Int] = [:]
        for r in strategic { totalPlaced[r.name] = 0 }
        // Major deposits on land
        for terrain in rs.terrainOrder.compactMap({ rs.terrains[$0] }).filter({ $0.type != .water && $0.type != .naturalWonder }) {   // Unciv: ruleset terrain order
            guard let list = ruleLists[terrainRule(terrain)] else { continue }
            // Unciv `totalPlaced += placeMajorDeposits(...)` on a HashMap is MutableMap.plusAssign = putAll: every
            // option's count (zeros included) REPLACES what an earlier terrain left
            for (k, v) in placeMajorDeposits(list, terrain: terrain, fallback: fallbackStrategic, baseImpact: 2, randomImpact: 2) { totalPlaced[k] = v }
        }
        // Small deposits of modern strategics near city-states
        let lastEra = rs.eras.count - 1
        let modern = strategic.filter { r in r.revealedBy != nil && rs.eraIndex(rs.techs[r.revealedBy!]?.era ?? "") >= lastEra / 2 }
        if !modern.isEmpty {
            // Unciv StrategicBonusResourcePlacementLogic.kt:265 — tek akış, bütün şehir devletleri boyunca.
            var modernRng = mapGenGameRandom("StrategicBonusResourcePlacementLogic.placeSmallDepositsOfModernStrategicResourcesOnCityStates", gameHash: gameHash)
            // `startingLocationsByNation.filterKeys { isCityState }`: HashMap bucket order over all the nations
            for nation in javaHashMapOrder(startingLocationOrder) where rs.nations[nation]?.isCityState == true {
                guard let s = startingLocations[nation], let r = modernRng.pick(modern) else { continue }
                totalPlaced[r.name, default: 0] += tryAddingResource(r, amount: 1, tiles: tilesInRange(s, 1...3))
            }
        }
        // Minor deposits on land
        // Unciv StrategicBonusResourcePlacementLogic.kt:227 `GameContext(gameInfo = landList[0].tileMap.gameInfo)`
        // — tek akış; hem ağırlıklı seçim hem de etki yarıçapı ondan çekiliyor.
        var minorRng = mapGenGameRandom("StrategicBonusResourcePlacementLogic.placeMinorDepositsOnLand", gameHash: gameHash)
        let frequency = max(1, Int(Double(MapRegions.baseMinorDepositFrequency) * bonusMultiplier))
        let minorToAdd = landList.count / frequency + 1
        var minorAdded = 0
        for i in landList {
            if minorAdded >= minorToAdd { break }
            let t = map.tiles[i]
            if t.resource != nil || tileData[i].impacts[.strategic] != nil { continue }
            let weights = strategic.map { r -> Double in
                if fallbackStrategic { return generatesNaturallyOn(r, t) ? 1 : 0 }
                return r.uniqueObjects.filter { $0.pattern == "Minor deposits generated with weight []" && conditionalsApply($0, tile: t, region: regionOf(i)) }.reduce(0.0) { $0 + $1.double(0) }
            }
            if weights.reduce(0, +) <= 0 { continue }
            // Unciv: `strategicResources.randomWeighted(weightings, rng)` — Float toplam, tek `nextDouble()`,
            // `randDouble <= sum` karşılaştırması. Elle yazılmış `roll -= w` sürümü sınırda başka öğe seçiyordu.
            guard let k = MapRegions.randomWeighted(Array(weights.indices), &minorRng, { weights[$0] }) else { continue }
            let picked = strategic[k]
            map.tiles[i].resource = picked.name
            map.tiles[i].resourceAmount = Tile.depositAmount(picked, on: map.tiles[i], major: false, setting: resourceSettingName)   // Unciv StrategicBonusResourcePlacementLogic: minor deposits
            placeImpact(.strategic, i, radius: minorRng.nextInt(below: 2) + minorRng.nextInt(below: 2))
            totalPlaced[picked.name, default: 0] += 1
            minorAdded += 1
        }
        // Major deposits on water
        for terrain in rs.terrainOrder.compactMap({ rs.terrains[$0] }).filter({ $0.type == .water }) {   // Unciv: ruleset terrain order
            guard let list = ruleLists[terrainRule(terrain)] else { continue }
            for (k, v) in placeMajorDeposits(list, terrain: terrain, fallback: fallbackStrategic, baseImpact: 4, randomImpact: 3) { totalPlaced[k] = v }   // putAll, as on land
        }
        // Ensure a minimum per civ
        for r in strategic {
            let extra = min(2, regions.count - (totalPlaced[r.name] ?? 0))
            if extra > 0 {
                let tiles = isWaterOnly(r) ? rng.shuffled(realIndices.filter { map.tiles[$0].isWater }) : landList
                _ = tryAddingResource(r, amount: extra, tiles: tiles, respectImpacts: true)
            }
        }
        // Bonus resources
        // Same quirk: with every "Generated on every [N] tiles" carrying a conditional, Unciv runs the rule-based
        // pass *and* a second fallback pass over the whole map, roughly doubling the bonus resources.
        let useFallbackBonuses = !rs.resources.values.contains { $0.uniqueObjects.contains { $0.pattern == "Generated on every [] tiles" && $0.conditionals.isEmpty } }
        for r in (rs.resourcesInOrder.filter { !isWaterOnly($0) } + rs.resourcesInOrder.filter { isWaterOnly($0) }) {
            let extra = isWaterOnly(r) ? 1 : 0
            for rule in r.uniqueObjects where rule.pattern == "Generated on every [] tiles" {
                guard let list = ruleLists[anonymized(rule)] else { continue }
                _ = placeResourcesInTiles(frequency: Int(rule.double(0) * bonusMultiplier), tiles: list, options: [r], baseImpact: extra, randomImpact: 2 + extra, majorDeposit: false)
            }
            if useFallbackBonuses && r.resourceType == "Bonus" {
                let list = rng.shuffled(realIndices.filter { r.terrainsCanBeFoundOn.contains(map.tiles[$0].features.last ?? map.tiles[$0].baseTerrain) })
                _ = placeResourcesInTiles(frequency: Int(20 * bonusMultiplier), tiles: list, options: [r], baseImpact: 2 + extra, randomImpact: 2 + extra, majorDeposit: false)
            }
        }
        // Bonus in the third ring of every start
        // Unciv StrategicBonusResourcePlacementLogic.kt:86 — tek akış, bütün bölgeler boyunca.
        // `tilesAtDistance(s, 3).shuffled()` Unciv'de tohumsuz; paylaşılan akışta bırakıldı.
        var thirdRingRng = mapGenGameRandom("StrategicBonusResourcePlacementLogic.placeBonusInThirdRingOfStart", gameHash: gameHash)
        for region in regions {
            guard let s = region.startPosition else { continue }
            // `terrainCounts.filterNot { it.key == "Coastal" }.maxByOrNull { it.value }!!.key`: the HashMap<String, Int>'s
            // bucket order (capacity from every key, Coastal included), the first highest count
            let terrain: String
            if region.type == "Hybrid" {
                var best: String? = nil, bestCount = Int.min
                for k in javaHashMapOrder(region.terrainCountOrder) where k != "Coastal" {
                    let v = region.terrainCounts[k]!
                    if v > bestCount { bestCount = v; best = k }
                }
                guard let b = best else { continue }   // Unciv's `!!` would throw here
                terrain = b
            } else { terrain = region.type }
            let extraUnique = rs.terrains[terrain]?.uniqueObjects.first { $0.pattern == "Starts in regions of this type receive an extra []" }
            let resource: ResourceDef
            if let u = extraUnique, let r = rs.resources[u.param(0)] { resource = r }
            else {
                let possible = rs.resourcesInOrder.filter { $0.resourceType == "Bonus" && $0.terrainsCanBeFoundOn.contains(terrain) }
                guard let r = thirdRingRng.pick(possible) else { continue }
                resource = r
            }
            let candidates = rng.shuffled(tilesAtDistance(s, 3))
            if tryAddingResource(resource, amount: extraUnique != nil ? 2 : 1, tiles: candidates) == 0 {
                let fishy = rs.resourcesInOrder.filter { r in r.resourceType == "Bonus" && r.terrainsCanBeFoundOn.contains { rs.terrains[$0]?.type == .water } }
                if let f = thirdRingRng.pick(fishy) { _ = tryAddingResource(f, amount: 1, tiles: candidates) }
            }
        }
    }
    private func placeMajorDeposits(_ tiles: [Int], terrain: Terrain, fallback: Bool, baseImpact: Int, randomImpact: Int) -> [String: Int] {
        guard !tiles.isEmpty else { return [:] }
        let frequency = terrain.uniqueObjects.first { $0.pattern == "Every [] tiles with this terrain will receive a major deposit of a strategic resource." }?.int(0) ?? 25
        let rule = terrainRule(terrain)
        let options = rs.resourcesInOrder.filter { r in r.resourceType == "Strategic" && ((fallback && r.terrainsCanBeFoundOn.contains(terrain.name)) || r.uniqueObjects.contains { u in u.pattern == "Generated with weight []" && anonymized(u) == rule }) }
        guard !options.isEmpty else { return [:] }
        return placeResourcesInTiles(frequency: frequency, tiles: tiles, options: options, baseImpact: baseImpact, randomImpact: randomImpact, majorDeposit: true)
    }
    private func impactType(_ r: ResourceDef) -> ImpactType { r.resourceType == "Strategic" ? .strategic : r.resourceType == "Bonus" ? .bonus : .luxury }
    /// Unciv MapRegionResources.placeResourcesInTiles
    @discardableResult
    private func placeResourcesInTiles(frequency: Int, tiles: [Int], options: [ResourceDef], baseImpact: Int, randomImpact: Int, majorDeposit: Bool) -> [String: Int] {
        guard !tiles.isEmpty, !options.isEmpty, frequency > 0 else { return [:] }
        let type = impactType(options[0])
        let sample = map.tiles[tiles[0]]
        var weights: [String: Double] = [:]
        for o in options { weights[o.name] = o.uniqueObjects.first { $0.pattern == "Generated with weight []" && conditionalsApply($0, tile: sample, region: nil) }?.double(0) ?? 1 }
        let amountToPlace = tiles.count / frequency + 1
        var placed = 0
        var detailed: [String: Int] = [:]
        for o in options { detailed[o.name] = 0 }
        var fallbackTiles: [Int] = []
        func put(_ i: Int) {
            // Unciv MapRegionResources.kt:57 ve :73 —
            //   val rng = GameContext(tile = tile).stateBasedRandom("MapRegionResources.placeResourcesInTiles")
            // Hem ağırlıklı seçim hem de `baseImpact + rng.nextInt(randomImpact + 1)` bu akıştan gelir;
            // paylaşılan `rng` akışından tek bir sayı bile tüketilmez.
            let p = uncivPosition(i)
            var tileRng = mapGenTileRandom("MapRegionResources.placeResourcesInTiles", x: p.x, y: p.y)
            let possible = options.filter { generatesNaturallyOn($0, map.tiles[i]) }
            guard let r = MapRegions.randomWeighted(possible, &tileRng, { weights[$0.name] ?? 0 }) else { return }
            map.tiles[i].resource = r.name
            map.tiles[i].resourceAmount = Tile.depositAmount(r, on: map.tiles[i], major: majorDeposit, setting: resourceSettingName)
            placeImpact(type, i, radius: baseImpact + tileRng.int(0...randomImpact))
            placed += 1; detailed[r.name, default: 0] += 1
        }
        for i in tiles {
            if map.tiles[i].resource != nil { continue }
            if !options.contains(where: { generatesNaturallyOn($0, map.tiles[i]) }) { continue }
            if tileData[i].impacts[type] != nil { fallbackTiles.append(i) }
            else { put(i); if placed >= amountToPlace { return detailed } }
        }
        while placed < amountToPlace, !fallbackTiles.isEmpty {
            let best = fallbackTiles.min { (tileData[$0].impacts[type] ?? 0) < (tileData[$1].impacts[type] ?? 0) }!
            fallbackTiles.removeAll { $0 == best }
            put(best)
        }
        return detailed
    }
    /// Unciv MapRegionResources.tryAddingResourceToTiles
    @discardableResult
    private func tryAddingResource(_ r: ResourceDef, amount: Int, tiles: [Int], ratio: Double = 1, respectImpacts: Bool = false, baseImpact: Int = -1, randomImpact: Int = 0, majorDeposit: Bool = false) -> Int {
        guard amount > 0 else { return 0 }
        var added = 0, progress = 1.0
        let type = impactType(r)
        for i in tiles {
            guard map.tiles[i].resource == nil, generatesNaturallyOn(r, map.tiles[i]) else { continue }
            if progress >= 1 && !(respectImpacts && tileData[i].impacts[type] != nil) {
                map.tiles[i].resource = r.name
                map.tiles[i].resourceAmount = Tile.depositAmount(r, on: map.tiles[i], major: majorDeposit, setting: resourceSettingName)
                progress -= 1; added += 1
                if baseImpact + randomImpact >= 0 {
                    // Unciv MapRegionResources.kt:108 —
                    //   val rng = GameContext(tile = tile).stateBasedRandom("MapRegionResources.tryAddingResourceToTiles")
                    let p = uncivPosition(i)
                    var tileRng = mapGenTileRandom("MapRegionResources.tryAddingResourceToTiles", x: p.x, y: p.y)
                    placeImpact(type, i, radius: baseImpact + tileRng.int(0...randomImpact))
                }
                if added >= amount { break }
            }
            progress += ratio
        }
        return added
    }
}
