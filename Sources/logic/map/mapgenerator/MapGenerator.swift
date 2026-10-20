// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// MARK: - Unciv Perlin (rosettacode version, as used by Unciv)

enum Perlin {
    private static let permutation: [Int] = [
        151, 160, 137,  91,  90,  15, 131,  13, 201,  95,  96,  53, 194, 233,   7, 225,
        140,  36, 103,  30,  69, 142,   8,  99,  37, 240,  21,  10,  23, 190,   6, 148,
        247, 120, 234,  75,   0,  26, 197,  62,  94, 252, 219, 203, 117,  35,  11,  32,
        57 , 177,  33,  88, 237, 149,  56,  87, 174,  20, 125, 136, 171, 168,  68, 175,
        74 , 165,  71, 134, 139,  48,  27, 166,  77, 146, 158, 231,  83, 111, 229, 122,
        60 , 211, 133, 230, 220, 105,  92,  41,  55,  46, 245,  40, 244, 102, 143,  54,
        65 ,  25,  63, 161,   1, 216,  80,  73, 209,  76, 132, 187, 208,  89,  18, 169,
        200, 196, 135, 130, 116, 188, 159,  86, 164, 100, 109, 198, 173, 186,   3,  64,
        52 , 217, 226, 250, 124, 123,   5, 202,  38, 147, 118, 126, 255,  82,  85, 212,
        207, 206,  59, 227,  47,  16,  58,  17, 182, 189,  28,  42, 223, 183, 170, 213,
        119, 248, 152,   2,  44, 154, 163,  70, 221, 153, 101, 155, 167,  43, 172,   9,
        129,  22,  39, 253,  19,  98, 108, 110,  79, 113, 224, 232, 178, 185, 112, 104,
        218, 246,  97, 228, 251,  34, 242, 193, 238, 210, 144,  12, 191, 179, 162, 241,
        81 ,  51, 145, 235, 249,  14, 239, 107,  49, 192, 214,  31, 181, 199, 106, 157,
        184,  84, 204, 176, 115, 121,  50,  45, 127,   4, 150, 254, 138, 236, 205,  93,
        222, 114,  67,  29,  24,  72, 243, 141, 128, 195,  78,  66, 215,  61, 156, 180]
    private static let grad3: [[Double]] = [[1,1,0],[-1,1,0],[1,-1,0],[-1,-1,0],[1,0,1],[-1,0,1],[1,0,-1],[-1,0,-1],[0,1,1],[0,-1,1],[0,1,-1],[0,-1,-1],[1,0,-1],[-1,0,-1],[0,-1,1],[0,1,1]]
    private static let p: [Int] = (0..<512).map { permutation[$0 % 256] }

    static func noise3d(_ x: Double, _ y: Double, _ z: Double, nOctaves: Int = 3, persistence: Double = 0.5, lacunarity: Double = 2.0, scale: Double = 10.0) -> Double {
        var freq = 1.0, amp = 1.0, mx = 0.0, total = 0.0
        for _ in 0..<nOctaves {
            total += amp * noise(x * freq / scale, y * freq / scale, z * freq / scale)
            mx += amp; freq *= lacunarity; amp *= persistence
        }
        return total / mx
    }
    static func ridgedNoise3d(_ x: Double, _ y: Double, _ z: Double, nOctaves: Int = 3, persistence: Double = 0.5, lacunarity: Double = 2.0, scale: Double = 10.0) -> Double {
        var freq = 1.0, amp = 1.0, mx = 0.0, total = 0.0
        for _ in 0..<nOctaves {
            total += amp * abs(noise(x * freq / scale, y * freq / scale, z * freq / scale))
            mx += amp; freq *= lacunarity; amp *= persistence
        }
        return total / mx
    }
    /// Kotlin `Double.toInt()` is JVM d2i: NaN is 0 and anything past the Int range sticks at Int.MAX_VALUE / MIN_VALUE.
    /// The z of a high octave is the elevation seed times 2^k, well past 2^31 for most seeds - Unciv's `and 255` then
    /// sees 255 (or 0), where Swift's exact 64-bit Int kept the real low byte.
    private static func jvmToInt(_ d: Double) -> Int {
        if d.isNaN { return 0 }
        if d >= 2147483647.0 { return 2147483647 }
        if d <= -2147483648.0 { return -2147483648 }
        return Int(d)
    }
    static func noise(_ x: Double, _ y: Double, _ z: Double) -> Double {
        // Unciv Perlin.noise: `floor(x).toInt() and 255`
        let xi = jvmToInt(floor(x)) & 255, yi = jvmToInt(floor(y)) & 255, zi = jvmToInt(floor(z)) & 255
        let xx = x - floor(x), yy = y - floor(y), zz = z - floor(z)
        let u = fade(xx), v = fade(yy), w = fade(zz)
        let a = p[xi] + yi, aa = p[a] + zi, ab = p[a + 1] + zi
        let b = p[xi + 1] + yi, ba = p[b] + zi, bb = p[b + 1] + zi
        return lerp(w, lerp(v, lerp(u, grad(p[aa], xx, yy, zz), grad(p[ba], xx - 1, yy, zz)),
                               lerp(u, grad(p[ab], xx, yy - 1, zz), grad(p[bb], xx - 1, yy - 1, zz))),
                       lerp(v, lerp(u, grad(p[aa + 1], xx, yy, zz - 1), grad(p[ba + 1], xx - 1, yy, zz - 1)),
                               lerp(u, grad(p[ab + 1], xx, yy - 1, zz - 1), grad(p[bb + 1], xx - 1, yy - 1, zz - 1))))
    }
    private static func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
    private static func lerp(_ t: Double, _ a: Double, _ b: Double) -> Double { a + t * (b - a) }
    private static func grad(_ hash: Int, _ x: Double, _ y: Double, _ z: Double) -> Double { let g = grad3[hash & 15]; return x * g[0] + y * g[1] + z * g[2] }
}

// MARK: - Unciv MapGenerator (1:1 port of logic/map/mapgenerator)

/// Unciv MapGenerator.TerrainOccursRange: a terrain plus one temperature/humidity window.
struct TerrainOccursRange {
    let terrain: Terrain
    let tempFrom: Double, tempTo: Double, humidFrom: Double, humidTo: Double
    let isConstrained: Bool
    var name: String { terrain.name }
    var occursInChains: Bool { terrain.uniques.contains("Occurs in chains at high elevations") }
    var occursInGroups: Bool { terrain.uniques.contains("Occurs in groups around high elevations") }
    var hasVegetation: Bool { terrain.uniques.contains("Vegetation") }
    var isRough: Bool { terrain.isRough }
    var isFreshwater: Bool { terrain.uniques.contains("Fresh water") }
    var isCoast: Bool { terrain.uniques.contains("Coastal Water") }
    var isOcean: Bool { terrain.isOcean }
    var rareFeature: Bool { terrain.uniques.contains("Rare feature") }

    init(_ terrain: Terrain, unique: Unique) {
        self.terrain = terrain
        // Unciv: Float bounds (`toFloatMakeInclusive(limit)`: the Float, less one ulp when it equals the limit), compared
        // with the tile's Double temperature and humidity after widening
        func inclusive(_ s: String, _ limit: Float) -> Double { let v = Float(s) ?? 0; return Double(v != limit ? v : v - v.ulp) }
        tempFrom = inclusive(unique.params[0], -1); tempTo = Double(Float(unique.params[1]) ?? 1)
        humidFrom = inclusive(unique.params[2], 0); humidTo = Double(Float(unique.params[3]) ?? 1)
        isConstrained = true
    }
    init(_ terrain: Terrain) {
        self.terrain = terrain
        tempFrom = -Double(Float.greatestFiniteMagnitude); tempTo = Double(Float.greatestFiniteMagnitude)   // Unciv ±Float.MAX_VALUE
        humidFrom = -Double(Float.greatestFiniteMagnitude); humidTo = Double(Float.greatestFiniteMagnitude)
        isConstrained = false
    }
    func matchesHumidity(temp: Double, humidity: Double) -> Bool { tempFrom < temp && temp <= tempTo && humidFrom < humidity && humidity <= humidTo }
    func maybeSnow() -> Bool { terrain.type == .land && tempFrom <= -1 && tempTo <= -0.5 && humidFrom >= -0.1 && humidTo >= 1 && !rareFeature }
}

struct MapGenerator {
    var rng: SeededRandom
    let rs: Ruleset
    init(seed: UInt64) {
        rng = SeededRandom(seed: seed); rs = Ruleset.shared; buildTerrainConditions()
        // Unciv MapLandmassGenerator.getInitializationTerrain: the first naturally generating terrain of each type
        let natural = rs.terrainOrder.compactMap { rs.terrains[$0] }.filter { !$0.uniques.contains("Doesn't generate naturally") }
        landTerrainName = natural.first { $0.type == .land }?.name ?? "Grassland"
        waterTerrainName = natural.first { $0.type == .water }?.name ?? landTerrainName
    }
    private var landTerrainName = "Grassland", waterTerrainName = "Ocean"

    var mapType: String = "Pangaea"
    var wrapX: Bool = false
    var placeRuinsEnabled = true
    var placeWondersEnabled = true
    /// Editor fallback resource layout (Unciv spreadResources); new games use MapRegions.
    var placeResourcesEnabled = true
    var hexagonal = false
    var flatEarth = false   // Unciv MapShape.flatEarth ("Flat Earth Hexagonal"): hexagonal, north at the edges, ice walls
    var seaLevel = "Normal", temperature = "Normal", rainfall = "Normal", resourceSetting = "Default"
    // Unciv MapParameters
    // Unciv MapParameters keeps these as Float (0.4f, ...) and the generator widens them to Double where it compares or
    // adds (vegetationRichness + 0.10, nextDouble() <= rareFeaturesRichness): kept here as that widened Float
    var elevationExponent = MapGenerator.uncivFloat(0.7), temperatureIntensity = MapGenerator.uncivFloat(0.6), temperatureShift = 0.0,
        vegetationRichness = MapGenerator.uncivFloat(0.4), rareFeaturesRichness = MapGenerator.uncivFloat(0.05), waterThreshold = 0.0
    var maxCoastExtension = 3, tilesPerBiomeArea = 6   // Unciv MapParameters defaults
    var resourceRichness: Float = 0.1   // Unciv MapParameters.resourceRichness, used in Float arithmetic (count * resourceRichness)
    /// a Double setting as Unciv's Float MapParameters field holds it, widened back to Double
    static func uncivFloat(_ v: Double) -> Double { Double(Float(v)) }
    /// Unciv MapParameters.mirroring (MirroringType): "None", "Left-right", "Top-bottom", "Four-way", "Around center tile".
    var mirroring = "None"

    mutating func configure(_ s: GameSettings) {
        placeRuinsEnabled = s.ancientRuins; placeWondersEnabled = s.naturalWonders
        hexagonal = s.mapShape == "Hexagonal" || s.mapShape == "Flat Earth Hexagonal"
        flatEarth = s.mapShape == "Flat Earth Hexagonal"
        seaLevel = s.seaLevel; temperature = s.temperature; rainfall = s.rainfall; resourceSetting = s.resourceSetting
        elevationExponent = MapGenerator.uncivFloat(s.elevationExponent); temperatureIntensity = MapGenerator.uncivFloat(s.temperatureIntensity)
        temperatureShift = MapGenerator.uncivFloat(s.temperatureShift)
        vegetationRichness = MapGenerator.uncivFloat(s.vegetationRichness); rareFeaturesRichness = MapGenerator.uncivFloat(s.rareFeaturesRichness)
        waterThreshold = MapGenerator.uncivFloat(s.waterThreshold)
        maxCoastExtension = s.maxCoastExtension; tilesPerBiomeArea = s.tilesPerBiomeArea
        resourceRichness = 0.1   // Unciv MapParameters.resourceRichness default; Unciv has no legacy climate presets
        mapType = MapGenerator.canonicalType(mapType)
    }
    static func canonicalType(_ t: String) -> String {
        switch t {
        case "Inland Sea": return "Inner Sea"
        case "Continents": return "Two Continents"
        case "Smoothed Random", "Default": return "Perlin"
        default: return t
        }
    }

    // MARK: terrain conditions (Unciv terrainConditions / baseTerrainPicker / terrainFeaturePicker)
    private var terrainConditions: [TerrainOccursRange] = []
    private var baseTerrainPicker: [TerrainOccursRange] { terrainConditions.filter { $0.terrain.type == .land || $0.terrain.type == .water } }
    private var terrainFeaturePicker: [TerrainOccursRange] { terrainConditions.filter { $0.terrain.type == .terrainFeature } }
    private mutating func buildTerrainConditions() {
        var out: [TerrainOccursRange] = []
        // Unciv MapGenerator.terrainConditions: ruleset terrain order, then sortedBy isConstrained
        for t in rs.terrainOrder.compactMap({ rs.terrains[$0] }) where !t.uniques.contains("Doesn't generate naturally") && t.type != .naturalWonder {
            let conds = t.uniqueObjects.filter { $0.pattern == "Occurs at temperature between [] and [] and humidity between [] and []" }
            if conds.isEmpty { out.append(TerrainOccursRange(t)) } else { out += conds.map { TerrainOccursRange(t, unique: $0) } }
        }
        // Unciv: sortedBy isConstrained (unconstrained first, stable)
        terrainConditions = out.filter { !$0.isConstrained } + out.filter { $0.isConstrained }
    }

    // MARK: per-map working state
    private var W = 0, H = 0                 // our grid (see GameMap.init(uncivPositions:)), not Unciv's map size
    private var nbr: [[Int]] = []            // neighbour indices per tile
    /// Per tile: Unciv's own position (x, y), HexMath.getLatitude (x + y) and getLongitude (x - y), and
    /// HexMath.hex2WorldCoords - the Float point every Perlin sample is taken at.
    private var pos: [HexMath.Position] = []
    private var lat: [Double] = [], lon: [Double] = [], wx: [Double] = [], wy: [Double] = []
    /// Unciv TileMap.maxLatitude / maxLongitude: Int maxima over the map's tiles
    private var maxLat = 0.0, maxLon = 0.0
    private var temp: [Double] = [], humid: [Double] = []
    /// Unciv mapParameters.mapSize (radius, width, height)
    private var mapRadius = 20, sizeWidth = 44, sizeHeight = 29
    /// Unciv TileMap.width: the number of columns the tiles span
    private var columnCount = 44
    /// Unciv tileMap.values: the map's tileList, in the order its TileMap constructor built it - column by column,
    /// then row by row, on a rectangular map; ring by ring from the centre (HexMath.getHexCoordsInDistance) on a
    /// hexagonal one. Only real tiles: a grid cell that is not a tile of the map is never visited. Every per-tile RNG
    /// draw depends on this order, so every loop walks it.
    private var uncivOrder: [Int] = []
    /// Unciv MapParameters.mapSize: set by the caller (a new game's Auto size resolves all three values); otherwise
    /// `generate(width:height:)` reads its arguments as a custom size.
    var mapSize: UncivMapSize? = nil
    /// Unciv MapGenerator.generateMap normalizes every tile (TileNormalizer.normalizeToRuleset) once, at the very end.
    /// A new game places regions, natural wonders, resources and ruins after `generate` returns, so it turns this off
    /// and normalizes after all of them; the map editor's generate keeps it.
    var normalizeAtEnd = true
    /// --gen-maps STEPS: called after each step with every tile in Unciv's tile order, "baseTerrain features"
    var stepDump: ((String, [String]) -> Void)? = nil
    private func dumpStep(_ name: String, _ map: GameMap) {
        guard let f = stepDump else { return }
        f(name, uncivOrder.map { "\(map.tiles[$0].baseTerrain) \(map.tiles[$0].features.joined(separator: "+"))" })
    }

    private mutating func prepare(_ map: GameMap) {
        W = map.width; H = map.height
        // A map saved before its tileList order was kept walks the grid the way Unciv's rectangular constructor lists
        // it: column by column, each column from Unciv's lowest row (our bottom row) up.
        uncivOrder = !map.uncivOrder.isEmpty ? map.uncivOrder
            : (0..<W).flatMap { col in (0..<H).reversed().map { row in row * W + col } }.filter { !map.missing.contains($0) }
        nbr = map.tiles.map { t in map.neighbors(of: t.coord).compactMap { map.index(of: $0) } }
        pos = []; lat = []; lon = []; wx = []; wy = []
        for t in map.tiles {
            let p = map.uncivPosition(t.coord)
            pos.append(p)
            lat.append(Double(HexMath.latitude(p))); lon.append(Double(HexMath.longitude(p)))
            let world = HexMath.hex2WorldCoords(p)
            wx.append(Double(world.x)); wy.append(Double(world.y))
        }
        maxLat = uncivOrder.map { abs(lat[$0]) }.max() ?? 0; maxLon = uncivOrder.map { abs(lon[$0]) }.max() ?? 0
        let columns = uncivOrder.map { HexMath.column(pos[$0]) }
        columnCount = (columns.max() ?? 0) - (columns.min() ?? 0) + 1
        temp = Array(repeating: 0, count: map.tiles.count); humid = Array(repeating: 0, count: map.tiles.count)
        let size = map.uncivSize ?? (map.hexRadius.map { UncivMapSize(radius: $0, shape: "Hexagonal") } ?? UncivMapSize(width: W, height: H, shape: "Rectangular"))
        mapRadius = size.radius; sizeWidth = size.width; sizeHeight = size.height
    }
    /// Unciv HexMath.getEquivalentHexagonalRadius
    static func equivalentRadius(tiles: Int) -> Int { max(1, Int(((sqrt(12.0 * Double(tiles) - 3) - 3) / 6).rounded())) }
    /// Unciv HexMath.getHexagonalRadiusForArea, a Float: `(sqrt(12f * numberOfTiles - 3) - 3) / 6`
    static func hexagonalRadiusForAreaF(_ n: Int) -> Float { n < 1 ? 0 : ((Float(12) * Float(n) - 3).squareRoot() - 3) / 6 }

    // MARK: Unciv MapGenerationRandomness
    private mutating func seedValue() -> Double { Double(rng.nextInt()) }
    private func getNoise(_ i: Int, _ seed: Double, nOctaves: Int, persistence: Double, lacunarity: Double, scale: Double, ridged: Bool) -> Double {
        let f: (Double, Double, Double, Int, Double, Double, Double) -> Double = ridged ? { Perlin.ridgedNoise3d($0, $1, $2, nOctaves: $3, persistence: $4, lacunarity: $5, scale: $6) } : { Perlin.noise3d($0, $1, $2, nOctaves: $3, persistence: $4, lacunarity: $5, scale: $6) }
        if !wrapX { return f(wx[i], wy[i], seed, nOctaves, persistence, lacunarity, scale) }
        // Unciv: wrap the plane onto a cylinder so the seam is seamless. The cylinder is as wide as the map: half the
        // even-adjusted mapSize.width on a rectangular map, mapSize.radius otherwise.
        let radius = hexagonal ? Double(mapRadius) : Double(sizeWidth % 2 != 0 ? sizeWidth - 1 : sizeWidth) / 2.0
        let wrapPeriod = 3.0 * radius
        let angle = (wx[i] / wrapPeriod) * 2 * .pi
        let cylinderRadius = wrapPeriod / (2 * .pi)
        let maxOffset = 256.0 * scale
        let seedLong = UInt64(bitPattern: Int64(seed))
        func off(_ k: UInt64) -> Double { Double((seedLong &* k) >> 32) / 4294967296.0 * maxOffset }
        let nx = cylinderRadius * cos(angle) + off(0x9E3779B97F4A7C15)
        let ny = cylinderRadius * sin(angle) + off(0xBF58476D1CE4E5B9)
        let nz = wy[i] + off(0x94D049BB133111EB)
        return f(nx, ny, nz, nOctaves, persistence, lacunarity, scale)
    }
    private func perlin(_ i: Int, _ seed: Double, nOctaves: Int = 6, persistence: Double = 0.5, lacunarity: Double = 2.0, scale: Double = 30.0) -> Double {
        getNoise(i, seed, nOctaves: nOctaves, persistence: persistence, lacunarity: lacunarity, scale: scale, ridged: false)
    }
    private func ridged(_ i: Int, _ seed: Double, nOctaves: Int = 10, persistence: Double = 0.5, lacunarity: Double = 2.0, scale: Double = 10.0) -> Double {
        getNoise(i, seed, nOctaves: nOctaves, persistence: persistence, lacunarity: lacunarity, scale: scale, ridged: true)
    }

    /// Kotlin'in `baseTerrainsToChosenTiles` alani bir java.util.HashMap: anahtar sirasi ekleme
    /// sirasi degil, kova sirasidir ve `sortedBy` kararli oldugu icin her esitlikte bu sira belirler.
    /// 16 kova (varsayilan kapasite, <= 12 anahtar icin buyume yok), kova icinde ekleme sirasi.
    private static func javaHashMapKeyOrder(_ keys: [String]) -> [String] {
        var buckets = [[String]](repeating: [], count: 16)
        for k in keys {
            var h: Int32 = 0
            for u in k.utf16 { h = 31 &* h &+ Int32(u) }
            let spread = h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 16)
            buckets[Int(spread & 15)].append(k)
        }
        return buckets.flatMap { $0 }
    }

    /// Unciv MapGenerationRandomness.chooseSpreadOutLocations
    mutating func chooseSpreadOutLocations(_ number: Int, suitable: [Int], map: GameMap) -> [Int] {
        guard number > 0, !suitable.isEmpty else { return [] }
        // Unciv: Float arithmetic throughout (getHexagonalRadiusForArea is a Float, Float.pow and Float.roundToInt)
        func fpow(_ a: Float, _ b: Float) -> Float { Float(Foundation.pow(Double(a), Double(b))) }
        let sparsityFactor = fpow(MapGenerator.hexagonalRadiusForAreaF(suitable.count) / Float(mapRadius), 0.333)
        let initialDistance = (number == 1 || number * 5 >= suitable.count * 3) ? 1
            : max(1, Int((Float(mapRadius) * 0.666 / fpow(MapGenerator.hexagonalRadiusForAreaF(number), 0.9) * sparsityFactor).rounded()))
        var grouped: [String: [Int]] = [:]
        var order: [String] = []
        for i in suitable { let t = map.tiles[i].baseTerrain; if grouped[t] == nil { order.append(t); grouped[t] = [] }; grouped[t]!.append(i) }
        let hashOrder = MapGenerator.javaHashMapKeyOrder(order)
        var distance = initialDistance
        while distance >= 1 {
            var available = grouped.mapValues { Set($0) }
            var chosen: [Int] = []
            var counts: [String: Int] = [:]
            for k in order { counts[k] = 0 }
            for _ in 0..<number {
                // Kotlin: entries.sortedBy { it.value } - kararli siralama, esitlikte hash sirasi kalir
                let keys = hashOrder.enumerated().sorted { a, b in
                    let ca = counts[a.element] ?? 0, cb = counts[b.element] ?? 0
                    return ca != cb ? ca < cb : a.offset < b.offset
                }.map { $0.element }
                guard let key = keys.first(where: { !(available[$0]?.isEmpty ?? true) }) else { break }
                // Kotlin: mutableSetOf() = LinkedHashSet, random(RNG) ekleme sirasindan secer
                let pool = (grouped[key] ?? []).filter { available[key]!.contains($0) }
                let pick = pool[rng.int(0...(pool.count - 1))]
                let close = Set(map.tilesWithin(map.tiles[pick].coord, radius: distance).compactMap { map.index(of: $0) })
                for k in available.keys { available[k]!.subtract(close) }
                chosen.append(pick); counts[key, default: 0] += 1
            }
            if chosen.count == number || distance == 1 { return chosen }
            distance -= 1
        }
        return []
    }

    // MARK: - generateMap
    mutating func generate(width rawWidth: Int, height rawHeight: Int) throws -> GameMap {
        let shape = flatEarth ? "Flat Earth Hexagonal" : hexagonal ? "Hexagonal" : "Rectangular"
        let size = mapSize ?? (hexagonal ? UncivMapSize(radius: min(rawWidth, rawHeight) / 2, shape: shape) : UncivMapSize(width: rawWidth, height: rawHeight, shape: shape))
        // Unciv MapGenerator.generateMap: `TileMap(mapSize.width, mapSize.height, …)` for a rectangular map (an odd
        // width rounded down when it wraps - wrapAdjustedWidth), `TileMap(mapSize.radius, …)` otherwise.
        let positions = hexagonal ? HexMath.hexCoordsInDistance(origin: (0, 0), distance: size.radius, worldWrap: wrapX)
            : HexMath.rectangularPositions(width: size.width, height: size.height, worldWrap: wrapX)
        var map = GameMap(uncivPositions: positions, wrapX: wrapX)
        map.uncivSize = size
        if hexagonal { map.hexRadius = size.radius }
        // Unciv MapGenerator.generateMap: the Empty map type is all ocean
        if mapType == "Empty" { for i in map.tiles.indices { map.tiles[i].baseTerrain = "Ocean" }; return map }
        HexCoord.wrapWidth = wrapX ? map.width : nil
        prepare(map)
        generateLand(&map); dumpStep("land", map)
        applyHumidityAndTemperature(&map); dumpStep("humid", map)
        raiseMountainsAndHills(&map); dumpStep("elev", map)
        spawnLakesAndCoasts(&map); dumpStep("lakes", map)
        try spawnVegetation(&map); dumpStep("veg", map)
        try spawnRareFeatures(&map); dumpStep("rare", map)
        try spawnIce(&map); dumpStep("ice", map)
        map.assignContinents(.assign)   // Unciv MapGenerator.generateMap: assignContinents(Assign), stored on the tiles
        var noCollection: [HexCoord]? = nil
        spawnRivers(&map, resultingTiles: &noCollection)
        convertTerrains(&map)
        // Map editor / legacy path: everything in one go. New games call the steps below from Setup after regions are assigned.
        if placeWondersEnabled { try spawnNaturalWonders(&map, startLocations: []) }
        if placeResourcesEnabled { spreadResources(&map) }
        if placeRuinsEnabled { spreadAncientRuins(&map) }
        mirror(&map)   // Unciv: only the map editor sets a mirroring type
        if normalizeAtEnd { normalizeToRuleset(&map) }
        return map
    }

    /// Unciv MapGenerator.mirror: copies terrain, natural wonder, features, resource (+amount) and improvement from the source half/quarter.
    /// Epochs mirrors offset rows/columns around the map centre (odd-row half-tile shifts make it approximate); rivers are left as generated.
    /// Unciv MapGenerator.mirror, on Unciv hex coordinates (the export frame of this map):
    /// flipTopBottom (x, y) → (-y, -x), flipLeftRight (x, y) → (y, x); rows = (x + y) / 2, columns = y - x.
    /// Tiles are copied in place in Unciv's tileList order (column, then row), rivers edge by edge.
    mutating func mirror(_ map: inout GameMap) {
        guard mirroring != "None" else { return }
        let frame = UncivSave.Frame.forExport(width: map.width, height: map.height)
        func unciv(_ c: HexCoord) -> (x: Int, y: Int) { frame.unciv(col: c.offsetCol, row: c.offsetRow) }
        func tileAt(_ x: Int, _ y: Int) -> HexCoord? {   // Unciv TileMap.getIfTileExistsOrNull (wrapping handled by GameMap.normalize)
            let o = frame.ours(x: x, y: y)
            let c = map.normalize(HexCoord.fromOffset(col: o.col, row: o.row))
            return map.contains(c) ? c : nil
        }
        func mirrorTile(_ c: HexCoord) -> HexCoord? {
            let (x, y) = unciv(c)
            let row = (x + y) / 2, column = y - x   // HexMath.getRow / getColumn (Kotlin integer division)
            switch mirroring {
            case "Top-bottom": return row <= 0 ? nil : tileAt(-y, -x)
            case "Left-right": return column <= 0 ? nil : tileAt(y, x)
            case "Around center tile": return row <= 0 ? nil : tileAt(-x, -y)
            case "Four-way":
                if row < 0 && column < 0 { return nil }
                if row < 0 { return tileAt(y, x) }
                if column < 0 { return tileAt(-y, -x) }
                return tileAt(-x, -y)
            default: return nil
            }
        }
        func river(_ a: HexCoord, _ b: HexCoord) -> Bool { map.hasRiver(between: a, b) }
        func setRiver(_ a: HexCoord, _ b: HexCoord, _ value: Bool) {   // Unciv Tile.setConnectedByRiver
            guard let d = a.wrappedDirection(to: b) else { return }
            if [HexCoord.dirSE, HexCoord.dirSW, HexCoord.dirS].contains(d) {
                if value { map[a]?.riverEdges.insert(d) } else { map[a]?.riverEdges.remove(d) }
            } else {
                let od = HexCoord.opposite(d)
                if value { map[b]?.riverEdges.insert(od) } else { map[b]?.riverEdges.remove(od) }
            }
        }
        // Unciv `for (tile in map.values)`: the tileList order
        if nbr.count != map.tiles.count { prepare(map) }
        let order = uncivOrder.map { map.tiles[$0].coord }
        for c in order {
            guard let m = mirrorTile(c), let src = map[m] else { continue }
            map[c]?.baseTerrain = src.baseTerrain
            map[c]?.naturalWonder = src.naturalWonder
            map[c]?.features = src.features
            map[c]?.resource = src.resource
            map[c]?.resourceAmount = src.resourceAmount
            map[c]?.improvement = src.improvement
            for n in map.neighbors(of: c) {
                guard let nm = mirrorTile(n) else { continue }
                guard map.neighbors(of: m).contains(nm) else { continue }   // we landed on the edge here
                setRiver(c, n, river(m, nm))
            }
        }
        for i in map.tiles.indices { map.tiles[i].riverAdjacent = map.neighbors(of: map.tiles[i].coord).contains { map.hasRiver(between: map.tiles[i].coord, $0) } }
    }

    // MARK: - MapLandmassGenerator
    private mutating func generateLand(_ map: inout GameMap) {
        // Unciv MapLandmassGenerator.landOnlyMod: rulesets without water terrains get an all-land map
        if waterTerrainName == landTerrainName { for i in uncivOrder { map.tiles[i].baseTerrain = landTerrainName }; return }
        switch mapType {
        case "Pangaea": createPangaea(&map)
        case "Inner Sea": createInnerSea(&map)
        case "Continent and Islands": createContinentAndIslands(&map)
        case "Two Continents": createTwoContinents(&map)
        case "Three Continents": createThreeContinents(&map)
        case "Four Corners": createFourCorners(&map)
        case "Archipelago": createArchipelago(&map)
        case "Fractal": createFractal(&map)
        case "Lakes": createLakes(&map)
        case "Boreal": createBoreal(&map)
        case "Small Continents": createSmallContinents(&map)
        case "Spiral": createSpiral(&map)
        default: createPerlin(&map)
        }
        if flatEarth { generateFlatEarthExtraWater(&map) }
    }
    private func spawnLandOrWater(_ map: inout GameMap, _ i: Int, _ elevation: Double, _ threshold: Double) {
        map.tiles[i].baseTerrain = elevation < threshold ? waterTerrainName : landTerrainName
    }
    /// Unciv MapLandmassGenerator.retryLoweringWaterLevel: `count { baseTerrain == waterTerrainName }.toFloat() / values.size`
    private func waterPercent(_ map: GameMap) -> Float {
        let water = uncivOrder.filter { map.tiles[$0].baseTerrain == waterTerrainName }.count
        return Float(water) / Float(uncivOrder.count)
    }
    /// Unciv tileMap.values.size
    private var realTileCount: Int { uncivOrder.count }
    /// Unciv NaturalWonderGenerator: `forEachTileInDistance(mapParameters.mapSize.height / 5)`
    private var naturalWonderBlockRadius: Int { sizeHeight / 5 }
    /// Kotlin `Float.pow(Float)`: `Math.pow` on the widened values, rounded back to Float
    private static func kpow(_ a: Float, _ b: Float) -> Float { Float(pow(Double(a), Double(b))) }
    private mutating func retryLoweringWaterLevel(_ map: inout GameMap, threshold: inout Double, predicate: (Float, GameMap) -> Bool = { p, _ in p <= 0.7 }, _ function: (inout GameMap, Double) -> Void) {
        var retries = 0
        while true {
            retries += 1
            if retries > 30 { break }
            function(&map, threshold)
            let wp = waterPercent(map)
            if threshold < -1 || predicate(wp, map) { break }
            // Unciv: `0.02 * (waterPercent / 0.7f).coerceAtLeast(1f) * retries.toFloat().pow(0.5f)` - Float factors
            threshold -= 0.02 * Double(max(wp / 0.7, 1)) * Double(MapGenerator.kpow(Float(retries), 0.5))
        }
    }
    private func tileRadius(_ i: Int) -> Double { sqrt(pow(abs(lat[i]) / maxLat, 2) + pow(abs(lon[i]) / maxLon, 2)) }

    private mutating func createPerlin(_ map: inout GameMap) {
        let seed = seedValue()
        for i in uncivOrder { spawnLandOrWater(&map, i, perlin(i, seed), waterThreshold) }
    }
    private mutating func createFractal(_ map: inout GameMap) {
        var th = waterThreshold
        var gen = self
        retryLoweringWaterLevel(&map, threshold: &th) { m, t in
            let seed = gen.seedValue()
            for i in gen.uncivOrder {
                let maxdim = max(gen.maxLat, gen.maxLon)   // Unciv max(tileMap.maxLatitude, tileMap.maxLongitude)
                var ratio = maxdim / 32.0
                if gen.hexagonal { ratio *= 0.5 }
                var e = gen.perlin(i, seed, persistence: 0.8, lacunarity: 1.5, scale: ratio * 30.0)
                e += gen.oceanEdgesTransform(i)
                gen.spawnLandOrWater(&m, i, e, t)
            }
        }
        rng = gen.rng
    }
    private mutating func createBoreal(_ map: inout GameMap) {
        let lakesSeed = seedValue(), broadSeed = seedValue()
        let lakesScale = 5.0, broadScale = 3.0 * sqrt(Double(mapRadius))
        for i in uncivOrder {
            let latitude = flatEarth ? 2 * tileRadius(i) - 1 : lat[i] / maxLat   // Unciv: north is at the edges on flat earth
            let southElevation = 0.15, northElevation = -0.4, b = 4.0
            var e = southElevation + (northElevation - southElevation) * pow(M_E, b * latitude - b)
            if ridged(i, lakesSeed, scale: lakesScale) > 0.43 { e -= 0.5 }
            e += 0.55 * perlin(i, broadSeed, scale: broadScale)
            spawnLandOrWater(&map, i, e, waterThreshold)
        }
    }
    private mutating func createSpiral(_ map: inout GameMap) {
        let seed = seedValue()
        let radius = Double(mapRadius)
        let flipX: Float = rng.nextBoolean() ? -1 : 1, flipY: Float = rng.nextBoolean() ? -1 : 1
        let coordinateDivisor = Float(columnCount)   // Unciv tileMap.width: prevent stretching of spiral
        let spinFactor = 4.5 * sqrt(radius), noiseScale = 0.5 * sqrt(radius)
        for i in uncivOrder {
            // Unciv: hex2WorldCoords is a Float vector centred on the map; x and y stay Float through atan2 and hypot
            let x = Float(wx[i]) / coordinateDivisor * flipX, y = Float(wy[i]) / coordinateDivisor * flipY
            let angle = Float(atan2(Double(y), Double(x))), distance = Float(hypot(Double(x), Double(y)))
            var e = sin(Double(angle) - spinFactor * Double(distance))
            e *= 0.25; e += 0.15
            e += 0.18 * perlin(i, seed, scale: noiseScale)
            spawnLandOrWater(&map, i, e, waterThreshold)
        }
    }
    private mutating func createLakes(_ map: inout GameMap) {
        let seed = seedValue()
        for i in uncivOrder { spawnLandOrWater(&map, i, 0.3 - ridged(i, seed, persistence: 0.7, lacunarity: 1.5), waterThreshold) }
    }
    private mutating func createSmallContinents(_ map: inout GameMap) {
        let seed = seedValue()
        var th = waterThreshold + 0.25
        let gen = self
        retryLoweringWaterLevel(&map, threshold: &th) { m, t in
            for i in gen.uncivOrder {
                var e = gen.ridged(i, seed, scale: 22.0)
                e += gen.oceanEdgesTransform(i)
                gen.spawnLandOrWater(&m, i, e, t)
            }
        }
    }
    private mutating func createArchipelago(_ map: inout GameMap) {
        let seed = seedValue()
        let th = waterThreshold + 0.25
        for i in uncivOrder { spawnLandOrWater(&map, i, ridged(i, seed), th) }
    }
    private mutating func createPangaea(_ map: inout GameMap) {
        // Unciv: `25.coerceAtMost(values.size / 4).coerceAtLeast(values.size.toFloat().pow(0.333f).toInt())`
        let largeContinentThreshold = max(Int(MapGenerator.kpow(Float(realTileCount), 0.333)), min(25, realTileCount / 4))
        var th = waterThreshold
        var gen = self
        retryLoweringWaterLevel(&map, threshold: &th, predicate: { wp, m in
            let sizes = MapGenerator.continentSizes(m)
            return sizes.values.filter { $0 > largeContinentThreshold }.count == 1 && wp <= 0.7
        }) { m, t in
            let seed = gen.seedValue()
            for i in gen.uncivOrder {
                var e = gen.perlin(i, seed)
                e = e * (3.0 / 4.0) + gen.ellipticContinent(i) / 4
                gen.spawnLandOrWater(&m, i, e, t)
            }
        }
        rng = gen.rng
    }
    private mutating func createInnerSea(_ map: inout GameMap) {
        let seed = seedValue()
        for i in uncivOrder {
            var e = perlin(i, seed)
            e -= ellipticContinent(i, percentOfMap: 0.6) * 0.3
            spawnLandOrWater(&map, i, e, waterThreshold)
        }
    }
    private mutating func createContinentAndIslands(_ map: inout GameMap) {
        let isNorth = rng.double() < 0.5
        // Unciv compares mapParameters.mapSize.height and width
        let isLatitude: Bool = hexagonal ? rng.double() > 0.5 : (sizeHeight > sizeWidth ? true : (sizeWidth > sizeHeight ? false : rng.double() > 0.5))
        let seed = seedValue()
        for i in uncivOrder {
            var e = perlin(i, seed)
            e = (e + continentAndIslandsTransform(i, isNorth: isNorth, isLatitude: isLatitude)) / 2.0
            spawnLandOrWater(&map, i, e, waterThreshold)
        }
    }
    private mutating func createTwoContinents(_ map: inout GameMap) {
        let isLatitude: Bool = hexagonal ? rng.double() > 0.5 : (sizeHeight > sizeWidth ? true : (sizeWidth > sizeHeight ? false : rng.double() > 0.5))
        let seed = seedValue()
        for i in uncivOrder {
            var e = perlin(i, seed)
            e = (e + twoContinentsTransform(i, isLatitude: isLatitude)) / 2.0
            spawnLandOrWater(&map, i, e, waterThreshold)
        }
    }
    private mutating func createThreeContinents(_ map: inout GameMap) {
        let isNorth = rng.double() < 0.5
        // Unciv: only a flat-earth map may run east to west, and the draw is short-circuited otherwise
        let isEastWest = flatEarth ? rng.double() > 0.5 : false
        let seed = seedValue()
        for i in uncivOrder {
            var e = perlin(i, seed)
            e = (e + threeContinentsTransform(i, isNorth: isNorth, isEastWest: isEastWest)) / 2.0
            spawnLandOrWater(&map, i, e, waterThreshold)
        }
    }
    private mutating func createFourCorners(_ map: inout GameMap) {
        let seed = seedValue()
        for i in uncivOrder {
            var e = perlin(i, seed)
            e = e / 2 + fourCornersTransform(i) / 2
            spawnLandOrWater(&map, i, e, waterThreshold)
        }
    }

    // shaping helpers
    private mutating func ellipticContinent(_ i: Int, percentOfMap: Double = 0.85) -> Double {
        let randomScale = rng.double()
        let ratio = percentOfMap + 0.1 * rng.double()
        let a = ratio * maxLon, b = ratio * maxLat
        let x = lon[i], y = lat[i]   // Unciv tile.longitude / latitude (x - y, x + y)
        let distanceFactor = x * x / (a * a) + y * y / (b * b) + pow(x + y, 2) / pow(a + b, 2)
        return min(0.3, 1.0 - (5.0 * distanceFactor * distanceFactor + randomScale) / 3.0)
    }
    private func lonLatFactors(_ i: Int) -> (Double, Double) { (abs(lon[i]) / maxLon, abs(lat[i]) / maxLat) }
    private func reverseLongitudeFactor(_ longitude: Double) -> Double { 1 - abs(longitude) / maxLon }
    private mutating func continentAndIslandsTransform(_ i: Int, isNorth: Bool, isLatitude: Bool) -> Double {
        let randomScale = rng.double()
        var (lonF, latF) = lonLatFactors(i)
        if isLatitude { if (isNorth && lat[i] < 0) || (!isNorth && lat[i] > 0) { latF = 0.2 } }
        else { if (isNorth && lon[i] < 0) || (!isNorth && lon[i] > 0) { lonF = 0.2 } }
        var factor = isLatitude ? latF : lonF
        if wrapX { factor = min(factor, reverseLongitudeFactor(lon[i])) * 1.1 }
        return min(0.2, -1.0 + (5.0 * pow(factor, 0.6) + randomScale) / 3.0)
    }
    private mutating func twoContinentsTransform(_ i: Int, isLatitude: Bool) -> Double {
        let randomScale = rng.double()
        let (lonF, latF) = lonLatFactors(i)
        var factor = isLatitude ? latF : lonF
        if wrapX { factor = min(lonF, reverseLongitudeFactor(lon[i])) * 1.5 }
        return min(0.2, -1.0 + (5.0 * pow(factor, 0.6) + randomScale) / 3.0)
    }
    private mutating func threeContinentsTransform(_ i: Int, isNorth: Bool, isEastWest: Bool) -> Double {
        let randomScale = rng.double()
        var (lonF, latF) = lonLatFactors(i)
        let sizeReductionFactor = flatEarth ? 3.0 : 2.0   // Unciv: a flat earth shrinks the third continent further
        if isEastWest {
            // Unciv: max(0, maxLatitude - abs(latitude * f)) / maxLatitude - maxLongitude'a degil maxLatitude'a bolunur
            if (isNorth && lon[i] < 0) || (!isNorth && lon[i] > 0) { latF = max(0, (maxLat - abs(lat[i] * sizeReductionFactor)) / maxLat) }
        } else if (isNorth && lat[i] < 0) || (!isNorth && lat[i] > 0) {
            // Unciv: getReverseLongitudeFactor(abs(longitude * f).toInt()) - Kotlin tam sayiya kirpar
            lonF = max(0, reverseLongitudeFactor(Double(Int(abs(lon[i] * sizeReductionFactor)))))
        }
        var factor = min(lonF, latF)
        if wrapX { factor = min(factor, reverseLongitudeFactor(lon[i])) * 1.5 }
        return min(0.2, -1.0 + (5.0 * pow(factor, 0.5) + randomScale) / 3.0)
    }
    private mutating func fourCornersTransform(_ i: Int) -> Double {
        let randomScale = rng.double()
        let (lonF, latF) = lonLatFactors(i)
        var factor = sqrt(lonF * latF) / 1.5
        if wrapX { factor = min(factor, reverseLongitudeFactor(lon[i])) * 1.5 }
        let shouldBeWater = 1 - factor
        return 1.0 - (5.0 * shouldBeWater * shouldBeWater + randomScale) / 3.0
    }
    private func oceanEdgesTransform(_ i: Int) -> Double {
        let xr = abs(lon[i]) / maxLon, yr = abs(lat[i]) / maxLat
        var offset = 0.0
        if hexagonal {
            let start = 0.8
            // Unciv: only a wrapping MapShape.hexagonal map ignores the east-west ratio (not a flat earth)
            let d = (wrapX && !flatEarth ? yr : sqrt(xr * xr + yr * yr))
            var distanceOffset = 0.0
            if d > start { distanceOffset = (d - start) / (1.0 - start) }
            offset -= distanceOffset * 0.35
        } else {
            var xo = 0.0
            if !wrapX && xr > 0.8 { xo = (xr - 0.8) / 0.2 }
            var yo = 0.0
            if yr > 0.76 { yo = (yr - 0.76) / 0.24 }
            offset -= xo * 0.33; offset -= yo * 0.35
        }
        return max(offset, -0.35)
    }

    // MARK: continents (Unciv TileMap.assignContinents)
    static func continentSizes(_ map: GameMap) -> [Int: Int] {
        var seen = Array(repeating: false, count: map.tiles.count)
        var sizes: [Int: Int] = [:]
        var id = 0
        for i in map.tiles.indices where !seen[i] && map.tiles[i].isLand {
            var stack = [i]; seen[i] = true; var n = 0
            while let cur = stack.popLast() {
                n += 1
                for c in map.neighbors(of: map.tiles[cur].coord) { if let j = map.index(of: c), !seen[j], map.tiles[j].isLand { seen[j] = true; stack.append(j) } }
            }
            sizes[id] = n; id += 1
        }
        return sizes
    }
    // The continent ids themselves are GameMap.assignContinents (Tile.swift): stored per tile, like Unciv's.

    // MARK: - applyHumidityAndTemperature
    private func lastTerrain(_ t: Tile) -> Terrain? { rs.terrains[t.features.last ?? t.baseTerrain] }
    /// Unciv MapElevationGenerator.raiseMountainsAndHills: `tileMap.setTransients` fills every tile's baseTerrainObject once,
    /// then applyTerrain only writes the `baseTerrain` string until the closing setTerrainTransients loop. Everything that
    /// asks `getBaseTerrain()` in between - TerrainOccursRange.matchesBaseTerrain, and lastTerrain on a tile without
    /// features - still sees the flat the tile had when the phase began. Nil outside that phase.
    private var staleBase: [String]? = nil
    /// Unciv TerrainOccursRange.matchesBaseTerrain: the tile's base terrain object (see `staleBase`) and its lastTerrain.
    private func matchesBaseTerrain(_ r: TerrainOccursRange, _ t: Tile, _ i: Int) -> Bool {
        let baseName = staleBase?[i] ?? t.baseTerrain
        guard let base = rs.terrains[baseName] else { return false }
        switch r.terrain.type {
        case .water: return base.type == .water && base.uniques.contains("Fresh water") == r.isFreshwater && base.uniques.contains("Coastal Water") == r.isCoast
        case .land: return base.type == .land && base.uniques.contains("Occurs in chains at high elevations") == r.occursInChains
        default:
            // Unciv Tile.lastTerrain: the last feature, else the base terrain object (no natural wonder exists yet)
            let last = t.features.last.flatMap { rs.terrains[$0] != nil ? $0 : nil } ?? baseName
            return r.terrain.occursOn.contains(last)
        }
    }
    private func matchesTempAndTerrain(_ r: TerrainOccursRange, _ t: Tile, _ i: Int, tempOverride: Double? = nil) -> Bool {
        matchesBaseTerrain(r, t, i) && r.matchesHumidity(temp: tempOverride ?? temp[i], humidity: humid[i])
    }
    private mutating func applyHumidityAndTemperature(_ map: inout GameMap) {
        let humiditySeed = seedValue(), temperatureSeed = seedValue()
        let scale = Double(tilesPerBiomeArea)
        let humidityShift = temperatureShift > 0 ? -temperatureShift / 2 : 0
        let landTerrains = baseTerrainPicker.filter { $0.terrain.type == .land && !$0.terrain.impassable && !$0.isRough && !$0.rareFeature }
        let coastTerrains = baseTerrainPicker.filter { $0.isCoast && !$0.rareFeature }
        let oceanTerrains = baseTerrainPicker.filter { $0.isOcean && !$0.rareFeature }
        let noTerrainUniques = !landTerrains.contains { $0.isConstrained }
        let elevationTerrains = Set(baseTerrainPicker.filter { $0.occursInChains }.map { $0.name })
        for i in uncivOrder {
            let t = map.tiles[i]
            if elevationTerrains.contains(t.baseTerrain) { continue }
            let humidityRandom = perlin(i, humiditySeed, nOctaves: 1, scale: scale)
            humid[i] = min(1, max(0, (humidityRandom + 1.0) / 2.0 + humidityShift))
            // Unciv getExpectedTemperature: flat earth latitude from the centre, stretched so ±0.9 is already -1.0
            let normalizedLatitude = flatEarth ? 2 * tileRadius(i) - 1 : lat[i] / maxLat
            let adjustedLatitude = flatEarth ? normalizedLatitude * 10.0 / 9.0 : normalizedLatitude
            let expected: Double = mapType == "Boreal" ? -0.4 - 0.6 * pow(M_E, 5 * adjustedLatitude - 5) : 1.0 - 2.0 * abs(adjustedLatitude)
            let randomTemperature = perlin(i, temperatureSeed, nOctaves: 1, scale: scale)
            var temperature = (5.0 * expected + randomTemperature) / 6.0
            temperature = pow(abs(temperature), 1.0 - temperatureIntensity) * (temperature < 0 ? -1 : (temperature > 0 ? 1 : 0))
            temperature = min(1, max(-1, temperature + temperatureShift))
            temp[i] = temperature
            if noTerrainUniques {
                let auto: String = temperature < -0.4 ? (humid[i] < 0.5 ? "Snow" : "Tundra") : temperature < 0.8 ? (humid[i] < 0.5 ? "Plains" : "Grassland") : (humid[i] < 0.7 ? "Desert" : "Plains")
                if rs.terrains[auto] != nil { map.tiles[i].baseTerrain = auto }   // Unciv: water included
                continue
            }
            let terrains = t.isLand ? landTerrains : (rs.terrains[t.baseTerrain]?.uniques.contains("Coastal Water") == true ? coastTerrains : oceanTerrains)
            let matching = terrains.filter { matchesTempAndTerrain($0, t, i) }
            if let pick = rng.pick(matching.isEmpty ? terrains : matching) { map.tiles[i].baseTerrain = pick.name }
        }
    }

    // MARK: - MapElevationGenerator
    private func isMountainTerrain(_ t: Tile) -> Bool { t.terrainNames.contains { rs.terrains[$0]?.uniques.contains("Occurs in chains at high elevations") == true } }
    private func isHillTerrain(_ t: Tile) -> Bool { t.terrainNames.contains { rs.terrains[$0]?.uniques.contains("Occurs in groups around high elevations") == true } }
    private mutating func applyTerrain(_ map: inout GameMap, _ i: Int, _ terrains: [TerrainOccursRange], flats: [TerrainOccursRange]) {
        let t = map.tiles[i]
        let matching = terrains.filter { matchesTempAndTerrain($0, t, i) }
        guard let desired = rng.pick(matching.isEmpty ? terrains : matching) else { return }
        // dropElevatedFeatures
        if let idx = map.tiles[i].features.firstIndex(where: { f in rs.terrains[f].map { $0.uniques.contains("Occurs in chains at high elevations") || $0.uniques.contains("Occurs in groups around high elevations") } ?? false }) { map.tiles[i].features.remove(at: idx) }
        if desired.terrain.type == .land { map.tiles[i].baseTerrain = desired.name }
        else {
            var bases = flats.filter { desired.terrain.occursOn.contains($0.name) && $0.matchesHumidity(temp: temp[i], humidity: humid[i]) }
            if bases.isEmpty { bases = flats.filter { desired.terrain.occursOn.contains($0.name) } }
            guard let base = rng.pick(bases) else { return }
            map.tiles[i].baseTerrain = base.name
            if !map.tiles[i].features.contains(desired.name) { map.tiles[i].features.append(desired.name) }
        }
    }
    private mutating func raiseMountainsAndHills(_ map: inout GameMap) {
        let flats = terrainConditions.filter { !$0.terrain.impassable && $0.terrain.type == .land && !$0.rareFeature && !$0.isRough }
        let hills = terrainConditions.filter { ($0.terrain.type == .land || $0.terrain.type == .terrainFeature) && $0.occursInGroups && !$0.rareFeature }
        let mountains = terrainConditions.filter { ($0.terrain.type == .land || $0.terrain.type == .terrainFeature) && $0.occursInChains && !$0.rareFeature }
        guard !flats.isEmpty else { return }
        let seed = seedValue()
        let offset = mapType == "Boreal" ? 0.03 : 0.0
        let exponent = 1.0 - elevationExponent - offset
        staleBase = map.tiles.map { $0.baseTerrain }   // Unciv: tileMap.setTransients(ruleset)
        defer { staleBase = nil }   // Unciv: the closing `for (tile in tileMap.values) tile.setTerrainTransients()`
        for i in uncivOrder where map.tiles[i].isLand {
            let n = perlin(i, seed, scale: 2.0)
            // Unciv powSigned: abs(this).pow(exponent) * sign(this), Kotlin's sign being 0 at 0 (and NaN at NaN) - the
            // noise is 0 on the lattice (the map's origin), where an elevationExponent of 1 or more gives 1 * 0 or
            // Infinity * 0 = NaN, a flat tile, not a mountain
            let e = pow(abs(n), exponent) * (n > 0 ? 1 : n < 0 ? -1 : n.isNaN ? .nan : 0)
            if e > 0.7 && !mountains.isEmpty { applyTerrain(&map, i, mountains, flats: flats) }
            else if e > 0.5 && !hills.isEmpty { applyTerrain(&map, i, hills, flats: flats) }
            else { applyTerrain(&map, i, flats, flats: flats) }
        }
        cellularMountainRanges(&map, mountains: mountains, flats: flats)
        cellularHills(&map, hills: hills, mountains: mountains, flats: flats)
    }
    private mutating func cellularMountainRanges(_ map: inout GameMap, mountains: [TerrainOccursRange], flats: [TerrainOccursRange]) {
        guard !mountains.isEmpty else { return }
        let targetMountains = map.tiles.filter { isMountainTerrain($0) }.count * 2
        let impassable = Set(rs.terrains.values.filter { $0.impassable }.map { $0.name })   // Unciv: every impassable terrain
        for _ in 1...5 {
            var totalMountains = map.tiles.filter { isMountainTerrain($0) }.count * 2
            var rising = Set<Int>(), lowering = Set<Int>()
            for i in uncivOrder where map.tiles[i].isLand {
                let t = map.tiles[i]
                let isMountain = isMountainTerrain(t)
                let adjacentMountains = nbr[i].filter { isMountainTerrain(map.tiles[$0]) }.count
                let adjacentImpassable = nbr[i].filter { impassable.contains(map.tiles[$0].baseTerrain) }.count
                if adjacentMountains == 0 { if isMountain && rng.int(0...3) == 0 { lowering.insert(i) } }
                else if adjacentMountains == 1 { if !isMountain && rng.int(0...9) == 0 { rising.insert(i) } }
                else if adjacentImpassable == 3 { if isMountain && rng.int(0...1) == 0 { lowering.insert(i) } }
                else if isMountain && adjacentImpassable > 3 { lowering.insert(i) }
            }
            for i in uncivOrder where map.tiles[i].isLand {
                if rising.contains(i) {
                    if totalMountains >= targetMountains { continue }
                    totalMountains += 1; applyTerrain(&map, i, mountains, flats: flats)
                }
                if lowering.contains(i) {
                    if totalMountains * 2 <= targetMountains { continue }
                    totalMountains -= 1; applyTerrain(&map, i, flats, flats: flats)
                }
            }
        }
    }
    private mutating func cellularHills(_ map: inout GameMap, hills: [TerrainOccursRange], mountains: [TerrainOccursRange], flats: [TerrainOccursRange]) {
        guard !hills.isEmpty else { return }
        let targetHills = map.tiles.filter { isHillTerrain($0) }.count
        for pass in 1...5 {
            var totalHills = map.tiles.filter { isHillTerrain($0) }.count
            var rising = Set<Int>(), lowering = Set<Int>()
            for i in uncivOrder {
                let t = map.tiles[i]
                let isMountain = mountains.contains { m in m.terrain.type == .land ? t.baseTerrain == m.name : t.features.contains(m.name) }
                if t.isWater || isMountain { continue }
                let isHill = isHillTerrain(t)
                let adjacentMountains = nbr[i].filter { isMountainTerrain(map.tiles[$0]) }.count
                let adjacentHills = nbr[i].filter { isHillTerrain(map.tiles[$0]) }.count
                if adjacentHills <= 1 && adjacentMountains == 0 && isHill && rng.int(0...1) == 0 { lowering.insert(i) }
                else if adjacentHills > 3 && adjacentMountains == 0 && isHill && rng.int(0...1) == 0 { lowering.insert(i) }
                else if (2...3).contains(adjacentHills + adjacentMountains) && !isHill && rng.int(0...1) == 0 { rising.insert(i) }
            }
            for i in uncivOrder {
                if rising.contains(i) {
                    if totalHills > targetHills && pass != 1 { continue }
                    totalHills += 1; applyTerrain(&map, i, hills, flats: flats)
                }
                if lowering.contains(i) {
                    if Double(totalHills) >= Double(targetHills) * 0.9 || pass == 1 { totalHills -= 1; applyTerrain(&map, i, flats, flats: flats) }
                }
            }
        }
    }

    // MARK: - spawnLakesAndCoasts
    private mutating func spawnLakesAndCoasts(_ map: inout GameMap) {
        let lakeTerrains = terrainConditions.filter { $0.isFreshwater && !$0.rareFeature && $0.terrain.type == .water }
        if !lakeTerrains.isEmpty {
            var waterTiles = Set(uncivOrder.filter { map.tiles[$0].isWater })   // Unciv map.values.filter { it.isWater }
            let maxLakeSize = rs.constants.maxLakeSize
            while let first = waterTiles.min() {
                waterTiles.remove(first)
                var area: Set<Int> = [first]; var queue = [first]
                while !queue.isEmpty {
                    let cur = queue.removeFirst()
                    for j in nbr[cur] where !area.contains(j) && waterTiles.contains(j) { area.insert(j); queue.append(j); waterTiles.remove(j) }
                }
                let matching = lakeTerrains.filter { $0.matchesHumidity(temp: temp[first], humidity: humid[first]) }
                if let lake = rng.pick(matching.isEmpty ? lakeTerrains : matching), area.count <= maxLakeSize {
                    for i in area { map.tiles[i].baseTerrain = lake.name }
                }
            }
        }
        let coasts = terrainConditions.filter { $0.isCoast && !$0.rareFeature }
        if !coasts.isEmpty { spreadCoast(&map, coasts: coasts) }
    }
    private mutating func spreadCoast(_ map: inout GameMap, coasts: [TerrainOccursRange]) {
        guard maxCoastExtension > 0 else { return }   // Unciv: an extension of zero spreads nothing
        for _ in 1...maxCoastExtension {
            var toCoast: [Int] = []
            for i in uncivOrder where rs.terrains[map.tiles[i].baseTerrain]?.isOcean == true {
                let ringOrder = map.tilesInDistanceUncivOrder(map.tiles[i].coord, radius: 1).compactMap { c in map.tiles.firstIndex(where: { $0.coord == c }) }.filter { $0 != i }
                for j in ringOrder {
                    let n = map.tiles[j]
                    if n.isLand { toCoast.append(i); break }
                    else if rs.terrains[n.baseTerrain]?.uniques.contains("Coastal Water") == true { if rng.nextBoolean() { toCoast.append(i) }; break }
                }
            }
            for i in toCoast {
                let matching = coasts.filter { $0.matchesHumidity(temp: temp[i], humidity: humid[i]) }
                if let c = rng.pick(matching.isEmpty ? coasts : matching) { map.tiles[i].baseTerrain = c.name }
            }
        }
    }

    // MARK: - vegetation / rare features / ice
    private mutating func spawnVegetation(_ map: inout GameMap) throws {
        let seed = seedValue()
        var vegetationTerrains = terrainFeaturePicker.filter { $0.hasVegetation && !$0.rareFeature }
        if vegetationTerrains.isEmpty { vegetationTerrains = terrainFeaturePicker.filter { ["Forest", "Jungle"].contains($0.name) } }
        let candidateTerrains = Set(vegetationTerrains.flatMap { $0.terrain.occursOn })
        let richness = vegetationRichness + (mapType == "Boreal" ? 0.10 : 0.0)
        for i in uncivOrder {
            let t = map.tiles[i]
            guard candidateTerrains.contains(t.baseTerrain), candidateTerrains.contains(lastTerrain(t)?.name ?? t.baseTerrain) else { continue }
            let vegetation = (perlin(i, seed, nOctaves: 1, scale: 3.0) + 1.0) / 2.0
            if vegetation <= richness {
                let possible = try vegetationTerrains.filter { try matchesTempAndTerrain($0, t, i) && fitsTerrainUniques($0.terrain, i, map) }
                if let pick = rng.pick(possible) { map.tiles[i].features.append(pick.name) }
            }
        }
    }
    private mutating func spawnRareFeatures(_ map: inout GameMap) throws {
        let rare = terrainFeaturePicker.filter { $0.rareFeature }
        for i in uncivOrder where map.tiles[i].features.isEmpty {
            if rng.double() <= rareFeaturesRichness {
                let t = map.tiles[i]
                let hillFeature = t.features.first { rs.terrains[$0]?.uniques.contains("Occurs in groups around high elevations") == true }
                let possible = try rare.filter { try matchesTempAndTerrain($0, t, i) && (hillFeature == nil || $0.terrain.occursOn.contains(hillFeature!)) && fitsTerrainUniques($0.terrain, i, map) }
                if let pick = rng.pick(possible) { map.tiles[i].features.append(pick.name) }
            }
        }
    }
    private mutating func spawnIce(_ map: inout GameMap) throws {
        var oceanTerrains = baseTerrainPicker.filter { $0.terrain.isOcean && $0.tempFrom <= -1 }
        if oceanTerrains.isEmpty { oceanTerrains = terrainFeaturePicker.filter { $0.terrain.isOcean } }
        let iceTerrains = terrainFeaturePicker.filter { $0.terrain.isIce }   // Unciv Terrain.isIce: an impassable feature that occurs on ocean
        guard !iceTerrains.isEmpty else { return }
        if flatEarth { spawnFlatEarthIceWalls(&map, iceTerrains) }
        let seed = seedValue()
        for i in uncivOrder {
            let t = map.tiles[i]
            guard oceanTerrains.contains(where: { $0.name == t.baseTerrain }), t.features.isEmpty else { continue }
            let randomTemperature = perlin(i, seed, nOctaves: 1, scale: Double(tilesPerBiomeArea))
            let latitudeTemperature = 1.0 - 2.0 * abs(lat[i]) / maxLat
            var iceTemp = (latitudeTemperature + randomTemperature) / 2.0
            iceTemp = pow(abs(iceTemp), 1.0 - temperatureIntensity) * (iceTemp < 0 ? -1 : (iceTemp > 0 ? 1 : 0))
            iceTemp = min(1, max(-1, iceTemp + temperatureShift))
            let possible = try iceTerrains.filter { try matchesTempAndTerrain($0, t, i, tempOverride: iceTemp) && fitsTerrainUniques($0.terrain, i, map) }
            if let pick = rng.pick(possible) { map.tiles[i].features.append(pick.name) }
        }
    }

    // MARK: - Flat earth (Unciv MapLandmassGenerator.generateFlatEarthExtraWater, MapGenerator.spawnFlatEarthIceWalls)
    /// Unciv Tile.neighbors: the map's tiles next to this one (a hexagonal map has none past its edge, so an edge tile has fewer than six)
    private func insideNeighbors(_ map: GameMap, _ i: Int) -> [Int] { nbr[i] }
    /// Unciv `tile.latitude == 0 && tile.longitude == 0`
    private func isCenterTile(_ i: Int) -> Bool { lat[i] == 0 && lon[i] == 0 }
    /// A 3 tile wide water perimeter and a 4 tile radius water centre, so nothing important is placed where the ice walls go
    private func generateFlatEarthExtraWater(_ map: inout GameMap) {
        for i in uncivOrder {
            let centerTile = isCenterTile(i)
            let isEdgeTile = insideNeighbors(map, i).count < 6
            if !centerTile && !isEdgeTile { continue }
            map.tiles[i].baseTerrain = waterTerrainName
            for n in insideNeighbors(map, i) {
                map.tiles[n].baseTerrain = waterTerrainName
                for n2 in insideNeighbors(map, n) {
                    map.tiles[n2].baseTerrain = waterTerrainName
                    if !centerTile { continue }
                    for n3 in insideNeighbors(map, n2) { map.tiles[n3].baseTerrain = waterTerrainName }
                }
            }
        }
    }
    /// A 1 tile wide perimeter of ice / snow / mountains and a 2 radius cluster of ice in the centre
    private mutating func spawnFlatEarthIceWalls(_ map: inout GameMap, _ iceTerrains: [TerrainOccursRange]) {
        let oceanTerrains = baseTerrainPicker.filter { $0.isOcean && !$0.rareFeature }
        let snowTerrains = baseTerrainPicker.filter { $0.maybeSnow() }
        let mountainTerrains = baseTerrainPicker.filter { $0.terrain.impassable && $0.occursInChains && !$0.rareFeature }
        let arcticTerrains = iceTerrains + snowTerrains + mountainTerrains
        if arcticTerrains.isEmpty { return }
        for i in uncivOrder {
            if isCenterTile(i) {
                spawnBestIce(&map, i, iceTerrains, mountainTerrains, oceanTerrains)
                for n in insideNeighbors(map, i) {
                    spawnBestIce(&map, n, iceTerrains, mountainTerrains, oceanTerrains)
                    for n2 in insideNeighbors(map, n) where rng.double() > 0.75 { spawnBestIce(&map, n2, iceTerrains, mountainTerrains, oceanTerrains) }
                }
            }
            if insideNeighbors(map, i).count < 6 {
                let t = map.tiles[i]
                guard let arctic = rng.pick(arcticTerrains.filter { matchesTempAndTerrain($0, t, i, tempOverride: -1.0) })
                        ?? rng.pick(arcticTerrains.filter { $0.matchesHumidity(temp: -1.0, humidity: humid[i]) })
                        ?? rng.pick(arcticTerrains) else { continue }
                spawnRandomIce(&map, i, arctic, iceTerrains)
                // Unciv spawnFlatEarthEdgeIceWall: the partial circle re-spawns on the edge tile itself
                for n in insideNeighbors(map, i) where insideNeighbors(map, n).count >= 6 && rng.double() >= 0.75 { spawnRandomIce(&map, i, arctic, iceTerrains) }
            }
        }
    }
    private mutating func spawnBestIce(_ map: inout GameMap, _ i: Int, _ ice: [TerrainOccursRange], _ mountains: [TerrainOccursRange], _ oceans: [TerrainOccursRange]) {
        let t = map.tiles[i]
        if let chosen = rng.pick(ice.filter { matchesTempAndTerrain($0, t, i, tempOverride: -1.0) }) ?? rng.pick(ice) {
            if !matchesTempAndTerrain(chosen, t, i, tempOverride: -1.0) {
                var bases = oceans.filter { chosen.terrain.occursOn.contains($0.name) }
                if bases.isEmpty { bases = oceans.filter { $0.isOcean } }
                if let b = rng.pick(bases) { map.tiles[i].baseTerrain = b.name }
            }
            map.tiles[i].features = [chosen.name]
        } else if let mountain = rng.pick(mountains.filter { $0.matchesHumidity(temp: -1.0, humidity: humid[i]) }) ?? rng.pick(mountains) {
            map.tiles[i].baseTerrain = mountain.name
            map.tiles[i].features = []
        }
    }
    private mutating func spawnRandomIce(_ map: inout GameMap, _ i: Int, _ arctic: TerrainOccursRange, _ ice: [TerrainOccursRange]) {
        map.tiles[i].features = []
        if arctic.terrain.type == .land && arctic.terrain.impassable {
            map.tiles[i].baseTerrain = arctic.name
        } else if arctic.terrain.type == .land {
            map.tiles[i].baseTerrain = arctic.name   // legacy: ice forced on snow
            if let x = rng.pick(ice) { map.tiles[i].features.append(x.name) }
        } else if arctic.terrain.type == .terrainFeature && matchesTempAndTerrain(arctic, map.tiles[i], i) {
            map.tiles[i].features.append(arctic.name)
        } else {
            map.tiles[i].baseTerrain = "Ocean"   // legacy: ice forced on ocean
            map.tiles[i].features.append(arctic.name)
        }
    }

    // MARK: - Unciv TileNormalizer.normalizeToRuleset
    /// Map generation may produce incompatible terrain / feature / resource combinations: fix every tile against the ruleset
    func normalizeToRuleset(_ map: inout GameMap) {
        let firstLand = rs.terrainOrder.compactMap { rs.terrains[$0] }.first { $0.type == .land && !$0.impassable }?.name ?? "Grassland"
        for i in map.tiles.indices {
            var t = map.tiles[i]
            if let nw = t.naturalWonder, rs.terrains[nw] == nil { t.naturalWonder = nil }
            if let nw = t.naturalWonder, let wonder = rs.terrains[nw] {
                if let into = wonder.turnsInto { t.baseTerrain = into; t.features = [] }
                else { t.features = t.features.filter { wonder.occursOn.contains($0) } }
                t.resource = nil; t.resourceAmount = 0; t.improvement = nil; t.improvementInProgress = nil
            }
            if rs.terrains[t.baseTerrain] == nil { t.baseTerrain = firstLand }
            let base = t.baseTerrain
            t.features = t.features.filter { f in guard let feature = rs.terrains[f] else { return false }; return feature.occursOn.isEmpty || feature.occursOn.contains(base) }
            if let r = t.resource, rs.resources[r] == nil { t.resource = nil; t.resourceAmount = 0 }
            if let r = t.resource.flatMap({ rs.resources[$0] }), !r.terrainsCanBeFoundOn.contains(where: { $0 == t.baseTerrain || t.features.contains($0) }) { t.resource = nil; t.resourceAmount = 0 }
            if let imp = t.improvement, rs.improvements[imp] == nil { t.improvement = nil; t.improvementInProgress = nil }
            if t.isWater || t.isImpassable { t.roads = false; t.railroad = false }
            map.tiles[i] = t
        }
    }

    // MARK: - RiverGenerator
    private func isFarEnoughFromWater(_ i: Int, _ map: GameMap) -> Bool {
        let c = map.tiles[i].coord
        for d in 1..<max(2, rs.constants.minRiverLength) {
            if c.ring(radius: d).contains(where: { map[$0]?.isWater == true }) { return false }
        }
        return true
    }
    /// Unciv RiverGenerator.spawnRivers(resultingTiles): the map editor's "Let the rivers flow" step collects every tile
    /// a river touched (`resultingTiles` non-nil), map generation does not.
    private mutating func spawnRivers(_ map: inout GameMap, resultingTiles: inout [HexCoord]?) {
        guard rs.constants.maxRiverLength > 0 else { return }   // Unciv `if (maxRiverLength <= 0) return`
        guard uncivOrder.contains(where: { map.tiles[$0].isWater }) else { return }   // Unciv `tileMap.values.none { it.isWater }`
        // Unciv: `(values.count { it.isLand } * riverCountMultiplier).roundToInt()` - an Int times a Float is a Float
        // (650 land tiles give 6.5f and 7 rivers, where the Double product 6.4999998 gave 6)
        let landCount = uncivOrder.filter { map.tiles[$0].isLand }.count
        let numberOfRivers = Stats.roundToInt(Double(Float(landCount) * Float(rs.constants.riverCountMultiplier)))
        var optional = uncivOrder.filter { map.tiles[$0].isMountain && isFarEnoughFromWater($0, map) }
        if optional.count < numberOfRivers { optional += uncivOrder.filter { map.tiles[$0].isHill && isFarEnoughFromWater($0, map) } }
        if optional.count < numberOfRivers { optional = uncivOrder.filter { map.tiles[$0].isLand && isFarEnoughFromWater($0, map) } }
        let starts = chooseSpreadOutLocations(numberOfRivers, suitable: optional, map: map)
        for s in starts { spawnRiver(&map, from: map.tiles[s].coord, resultingTiles: &resultingTiles) }
        for i in map.tiles.indices {
            let c = map.tiles[i].coord
            map.tiles[i].riverAdjacent = (0..<6).contains { d in map.hasRiver(between: c, c.neighbor(d)) }
        }
    }
    private mutating func closestWaterTile(_ map: GameMap, _ c: HexCoord) -> HexCoord? {
        for d in 1...max(1, rs.constants.maxRiverLength) {
            // Unciv RiverGenerator.getClosestWaterTile: getTilesAtDistance(d) - halka, Unciv'in kendi sirasiyla.
            // HexCoord.ring(radius:) yaricap icindeki TUM diski donduruyor ve sirasi Unciv'inkiyle ortusmuyor.
            let water = map.tilesInDistanceUncivOrder(c, radius: d).filter { $0.distance(to: c) == d && map[$0]?.isWater == true }
            if !water.isEmpty { return rng.pick(water) }
            if d > max(W, H) { break }
        }
        return nil
    }
    /// Unciv RiverCoordinate: a vertex described by its anchor hex and whether it is the bottom-left (7 o'clock) or bottom-right (5 o'clock) corner.
    private struct RiverVertex: Equatable { let pos: HexCoord; let left: Bool }
    private func adjacentTiles(_ v: RiverVertex, _ map: GameMap) -> [HexCoord] {
        var out = [v.pos]
        let s = map.normalize(v.pos.neighbor(HexCoord.dirS)); if map.contains(s) { out.append(s) }
        let side = map.normalize(v.pos.neighbor(v.left ? HexCoord.dirSW : HexCoord.dirSE)); if map.contains(side) { out.append(side) }
        return out
    }
    private func adjacentVertices(_ v: RiverVertex, _ map: GameMap) -> [RiverVertex] {
        var out = [RiverVertex(pos: v.pos, left: !v.left)]
        if v.left {
            let nw = map.normalize(v.pos.neighbor(HexCoord.dirNW)); if map.contains(nw) { out.append(RiverVertex(pos: nw, left: false)) }
            let sw = map.normalize(v.pos.neighbor(HexCoord.dirSW)); if map.contains(sw) { out.append(RiverVertex(pos: sw, left: false)) }
        } else {
            let ne = map.normalize(v.pos.neighbor(HexCoord.dirNE)); if map.contains(ne) { out.append(RiverVertex(pos: ne, left: true)) }
            let se = map.normalize(v.pos.neighbor(HexCoord.dirSE)); if map.contains(se) { out.append(RiverVertex(pos: se, left: true)) }
        }
        return out
    }
    /// Unciv RiverCoordinate.paintTo: one river edge; paintBottom / paintBottomLeft / paintBottomRight add the tile that
    /// owns the edge, then the tile across it, to `resultingTiles` (a LinkedHashSet there: the first insertion keeps its place).
    private func paint(_ map: inout GameMap, from v: RiverVertex, to n: RiverVertex, resultingTiles: inout [HexCoord]?) {
        func paintEdge(_ owner: HexCoord, _ d: Int) {
            map.setRiver(owner, dir: d)
            guard resultingTiles != nil else { return }
            if !resultingTiles!.contains(owner) { resultingTiles!.append(owner) }
            let across = map.normalize(owner.neighbor(d))
            if map.contains(across) && !resultingTiles!.contains(across) { resultingTiles!.append(across) }
        }
        if n.pos == v.pos { paintEdge(v.pos, HexCoord.dirS) }
        else if !v.left {
            if adjacentTiles(n, map).contains(v.pos) { paintEdge(v.pos, HexCoord.dirSE) } else { paintEdge(n.pos, HexCoord.dirSW) }
        } else {
            if adjacentTiles(n, map).contains(v.pos) { paintEdge(v.pos, HexCoord.dirSW) } else { paintEdge(n.pos, HexCoord.dirSE) }
        }
    }
    private mutating func spawnRiver(_ map: inout GameMap, from start: HexCoord, resultingTiles: inout [HexCoord]?) {
        guard let end = closestWaterTile(map, start) else { return }
        spawnRiver(&map, from: start, to: end, collecting: &resultingTiles)
    }
    /// Unciv RiverGenerator.getClosestWaterTile, for the map editor's "Spawn river from/to".
    mutating func closestWater(_ map: GameMap, from c: HexCoord) -> HexCoord? {
        W = map.width; H = map.height   // a generator made only for the editor never ran generate()
        return closestWaterTile(map, c)
    }
    /// Unciv RiverGenerator.spawnRiver(initialPosition, endPosition, resultingTiles): a river running from one tile to
    /// another - for the map editor's "Spawn river from/to", which gets back every tile the river touched.
    mutating func spawnRiver(_ map: inout GameMap, from start: HexCoord, to end: HexCoord, resultingTiles: inout [HexCoord]) {
        var collected: [HexCoord]? = resultingTiles
        spawnRiver(&map, from: start, to: end, collecting: &collected)
        resultingTiles = collected ?? []
    }
    private mutating func spawnRiver(_ map: inout GameMap, from start: HexCoord, to end: HexCoord, collecting resultingTiles: inout [HexCoord]?) {
        var v = RiverVertex(pos: start, left: rng.nextInt(until: 2) == 0)
        for _ in 0..<max(1, rs.constants.maxRiverLength) {
            if adjacentTiles(v, map).contains(where: { map[$0]?.isWater == true }) { return }
            let options = adjacentVertices(v, map)
            if options.isEmpty { return }
            let scored = options.map { o in (o, adjacentTiles(o, map).map { $0.distance(to: end) }.min() ?? 999) }
            let best = scored.map { $0.1 }.min() ?? 0
            guard let next = rng.pick(scored.filter { $0.1 == best }.map { $0.0 }) else { return }
            paint(&map, from: v, to: next, resultingTiles: &resultingTiles)
            v = next
        }
    }

    // MARK: - convertTerrains ("Becomes [] when adjacent to []")
    private func isAdjacentTo(_ map: GameMap, _ i: Int, _ filter: String) -> Bool {
        let t = map.tiles[i]
        if filter == "River" { return (0..<6).contains { d in map.hasRiver(between: t.coord, t.coord.neighbor(d)) } }
        if filter == "Fresh water" { return isAdjacentTo(map, i, "River") || nbr[i].contains { map.tiles[$0].terrainNames.contains { rs.terrains[$0]?.uniques.contains("Fresh water") == true } } }
        return nbr[i].contains { map.tiles[$0].terrainNames.contains(filter) || (filter == "Water" && map.tiles[$0].isWater) || (filter == "Land" && map.tiles[$0].isLand) }
    }
    private func convertTerrains(_ map: inout GameMap) { convertTerrains(&map, indices: uncivOrder) }
    /// Unciv MapGenerator.convertTerrains(tiles) over the tiles new rivers touched, in the order they touched them
    /// (MapEditorEditTab.paintRiverFromTo, MapGenerator.generateSingleStep's Rivers step).
    mutating func convertTerrains(_ map: inout GameMap, tiles: [HexCoord]) {
        if nbr.count != map.tiles.count || uncivOrder.count != map.realTileCount { prepare(map) }
        convertTerrains(&map, indices: tiles.compactMap { map.index(of: $0) })
    }
    /// Unciv MapGenerator.Helpers.convertTerrains
    private func convertTerrains(_ map: inout GameMap, indices: [Int]) {
        for i in indices {
            guard let base = rs.terrains[map.tiles[i].baseTerrain] else { continue }
            guard let u = base.uniqueObjects.first(where: { $0.pattern == "Becomes [] when adjacent to []" && isAdjacentTo(map, i, $0.params[1]) }) else { continue }
            guard let terrain = rs.terrains[u.params[0]] else { continue }
            if terrain.type != .terrainFeature { map.tiles[i].baseTerrain = terrain.name }
            else if terrain.occursOn.contains(lastTerrain(map.tiles[i])?.name ?? "") && !map.tiles[i].features.contains(terrain.name) { map.tiles[i].features.append(terrain.name) }
        }
    }

    // MARK: - NaturalWonderGenerator
    private func matchesWonderFilter(_ t: Tile, _ filter: String) -> Bool {
        switch filter {
        case "Elevated": return t.isMountain || t.isHill
        case "Water": return t.isWater
        case "Land": return t.isLand
        case "Hill": return t.isHill
        default: return t.naturalWonder == filter || (lastTerrain(t)?.name == filter) || t.baseTerrain == filter
        }
    }
    /// Kotlin `count in from..to` (NaturalWonderGenerator.fitsTerrainUniques, NaturalWonderNeighborsRange): a range
    /// whose start is past its end is empty, where Swift's `from...to` stops the app - a mod's "Must be adjacent to [6]
    /// to [1] [Coast] tiles" fits no tile.
    static func countIn(_ count: Int, _ from: Int, _ to: Int) -> Bool { from <= count && count <= to }
    /// What Unciv's NaturalWonderGenerator throws out of the map generation, which NewGameScreen.startNewGame and the
    /// map editor's Generate tab catch to show "It looks like we can't make a map with the parameters you requested!":
    /// a mod's number that is not one (`Unique.getIntParam`: `params[index].toInt()`, NumberFormatException), a
    /// negative count of largest landmasses (`sortedContinents.take(n)`, IllegalArgumentException), a group size range
    /// whose start is past its end (`(min..max).random()`, NoSuchElementException) - where ours stopped the app
    /// (`prefix(-1)`, `min...max`) or took a default.
    struct MapGenerationError: Error, CustomStringConvertible { let description: String }
    /// Unciv `Unique.getIntParam(index) = params[index].toInt()` - Kotlin's String.toInt, a 32-bit Int.
    static func intParam(_ u: Unique, _ index: Int) throws -> Int {
        guard let v = Int32(u.params[index]) else { throw MapGenerationError(description: "For input string: \"\(u.params[index])\"") }
        return Int(v)
    }
    /// Kotlin `List.take(n)`: `require(n >= 0) { "Requested element count $n is less than zero." }`.
    static func take<T>(_ list: [T], _ n: Int) throws -> ArraySlice<T> {
        guard n >= 0 else { throw MapGenerationError(description: "Requested element count \(n) is less than zero.") }
        return list.prefix(n)
    }
    func fitsTerrainUniques(_ terrain: Terrain, _ i: Int, _ map: GameMap) throws -> Bool {
        let t = map.tiles[i]
        // Unciv NaturalWonderGenerator.fitsTerrainUniques: tileMap.continentsSortedBySize and the tile's stored
        // continent - empty and -1 before the ids are assigned, so "Must be on" fails and "Must not be on" passes
        let continentsRelevant = terrain.uniqueObjects.contains { $0.pattern == "Must not be on [] largest landmasses" || $0.pattern == "Must be on [] largest landmasses" }
        let sorted = continentsRelevant ? map.continentsSortedBySize : []
        for u in terrain.uniqueObjects {
            switch u.pattern {
            case "Must be adjacent to [] [] tiles":
                let count = nbr[i].filter { matchesWonderFilter(map.tiles[$0], u.params[1]) }.count
                if count != (try MapGenerator.intParam(u, 0)) { return false }
            case "Must be adjacent to [] to [] [] tiles":
                let count = nbr[i].filter { matchesWonderFilter(map.tiles[$0], u.params[2]) }.count
                if !MapGenerator.countIn(count, try MapGenerator.intParam(u, 0), try MapGenerator.intParam(u, 1)) { return false }
            case "Must not be on [] largest landmasses":
                if try MapGenerator.take(sorted, MapGenerator.intParam(u, 0)).contains(t.continent) { return false }
            case "Must be on [] largest landmasses":
                if !(try MapGenerator.take(sorted, MapGenerator.intParam(u, 0)).contains(t.continent)) { return false }
            case "Occurs on latitudes from [] to [] percent of distance equator to pole":
                // Unciv: `maxLatitude * getIntParam(0) * 0.01f` - an Int product (32 bits, wrapping) times a Float, compared in Float
                func bound(_ k: Int) throws -> Float {
                    Float(Int32(truncatingIfNeeded: Int(maxLat)) &* Int32(truncatingIfNeeded: try MapGenerator.intParam(u, k))) * 0.01
                }
                let lower = try bound(0), upper = try bound(1)
                if !(lower <= upper && (lower...upper).contains(Float(abs(lat[i])))) { return false }
            default: break
            }
        }
        return true
    }
    private var blockedTiles: Set<Int> = []
    /// Unciv MapGeneratorSteps.generateSingleStep: one stage of generation, run over the existing map.
    mutating func runStep(_ step: String, _ map: inout GameMap) throws {
        if nbr.count != map.tiles.count || uncivOrder.count != map.realTileCount { prepare(map) }
        switch step {
        case "Generate landmass": generateLand(&map)
        case "Humidity and temperature": applyHumidityAndTemperature(&map)
        case "Raise mountains and hills": raiseMountainsAndHills(&map)
        case "Lakes and coastline": spawnLakesAndCoasts(&map)
        case "Sprout vegetation": try spawnVegetation(&map)
        case "Spawn rare features": try spawnRareFeatures(&map)
        case "Distribute ice": try spawnIce(&map)
        case "Assign continent IDs": map.assignContinents(.reassign)   // Unciv MapGeneratorSteps.Continents
        case "Place Natural Wonders": try spawnNaturalWonders(&map, startLocations: [])
        case "Let the rivers flow":
            // Unciv: `spawnRivers(resultingTiles); convertTerrains(resultingTiles)` - only the tiles the new rivers touched
            var resultingTiles: [HexCoord]? = []
            spawnRivers(&map, resultingTiles: &resultingTiles)
            convertTerrains(&map, indices: (resultingTiles ?? []).compactMap { map.index(of: $0) })
        case "Spread Resources": spreadResources(&map)
        case "Create ancient ruins": spreadAncientRuins(&map)
        default: break
        }
        // Unciv generateSingleStep does not normalize the map afterwards (only generateMap does, once, at its end)
    }
    static let steps = ["Generate landmass", "Humidity and temperature", "Raise mountains and hills", "Lakes and coastline",
                        "Sprout vegetation", "Spawn rare features", "Distribute ice", "Assign continent IDs",
                        "Place Natural Wonders", "Let the rivers flow", "Spread Resources", "Create ancient ruins"]

    mutating func spawnNaturalWonders(_ map: inout GameMap, startLocations: [HexCoord]) throws {
        if nbr.count != map.tiles.count { prepare(map) }
        // Unciv NaturalWonderGenerator reads the continents assigned before the rivers; nothing re-assigns them here
        blockedTiles = []
        let numberToSpawn = Int((Double(mapRadius) * rs.constants.naturalWonderCountMultiplier + rs.constants.naturalWonderCountAddedConstant).rounded())
        var all = rs.naturalWonders
        var chosen: [Terrain] = []
        while !all.isEmpty && chosen.count < numberToSpawn {
            let total = all.reduce(0.0) { $0 + Double($1.weight) }
            let random = rng.double()
            var sum = 0.0
            for w in all { sum += Double(w.weight) / total; if random <= sum { chosen.append(w); all.removeAll { $0.name == w.name }; break } }
            if all.count == rs.naturalWonders.count - chosen.count && sum < random { chosen.append(all.removeLast()) }
        }
        let tooClose = Set(startLocations.flatMap { map.tilesWithin($0, radius: 5) }.compactMap { map.index(of: $0) })
        func candidates(_ w: Terrain) throws -> [Int] {
            try uncivOrder.filter { i in
                let t = map.tiles[i]
                return try t.resource == nil && !tooClose.contains(i) && w.occursOn.contains(lastTerrain(t)?.name ?? t.baseTerrain) && fitsTerrainUniques(w, i, map)
            }
        }
        var spawned = 0
        var cand: [String: [Int]] = [:]
        for w in chosen { cand[w.name] = try candidates(w) }
        chosen.sort { (cand[$0.name]?.count ?? 0) < (cand[$1.name]?.count ?? 0) }
        for w in chosen { if try trySpawn(&map, (cand[w.name] ?? []).filter { !blockedTiles.contains($0) }, w) { spawned += 1 } }
        if spawned < numberToSpawn {
            for w in all { cand[w.name] = try candidates(w) }
            all.sort { (cand[$0.name]?.count ?? 0) < (cand[$1.name]?.count ?? 0) }
            for w in all {
                if try trySpawn(&map, (cand[w.name] ?? []).filter { !blockedTiles.contains($0) }, w) { spawned += 1 }
                if spawned >= numberToSpawn { break }
            }
        }
    }
    private mutating func trySpawn(_ map: inout GameMap, _ suitable: [Int], _ wonder: Terrain) throws -> Bool {
        var minGroup = 1, maxGroup = 1
        if let g = wonder.uniqueObjects.first(where: { $0.pattern == "Occurs in groups of [] to [] tiles" }) { minGroup = try MapGenerator.intParam(g, 0); maxGroup = try MapGenerator.intParam(g, 1) }
        // Kotlin `(minGroupSize..maxGroupSize).random(RNG)` throws on an empty range; `suitableLocations.random(RNG)` on an empty list
        guard minGroup == maxGroup || minGroup <= maxGroup else { throw MapGenerationError(description: "Cannot get random in empty range: \(minGroup)..\(maxGroup)") }
        let target = minGroup == maxGroup ? maxGroup : rng.int(minGroup...maxGroup)
        guard suitable.count >= minGroup else { return false }
        guard let location = rng.pick(suitable) else { throw MapGenerationError(description: "Collection is empty.") }
        var list = [location]
        while list.count < target {
            let allNeighbors = Set(list.flatMap { nbr[$0] }).subtracting(list)
            let cands = suitable.filter { allNeighbors.contains($0) }
            guard let pick = rng.pick(cands) else { break }
            list.append(pick)
        }
        guard list.count >= minGroup else { return false }
        for i in list {
            placeNaturalWonder(&map, wonder, i)
            blockedTiles.formUnion(map.tilesWithin(map.tiles[i].coord, radius: naturalWonderBlockRadius).compactMap { map.index(of: $0) })
        }
        return true
    }
    private func clearTile(_ map: inout GameMap, _ i: Int, except: [String] = []) {
        if !map.tiles[i].features.isEmpty && except != map.tiles[i].features { map.tiles[i].features = map.tiles[i].features.filter { except.contains($0) } }
        map.tiles[i].resource = nil; map.tiles[i].improvement = nil
    }
    private func placeNaturalWonder(_ map: inout GameMap, _ wonder: Terrain, _ i: Int) {
        map.tiles[i].naturalWonder = wonder.name
        if let into = wonder.turnsInto, rs.terrains[into] != nil { clearTile(&map, i); map.tiles[i].baseTerrain = into }
        else { clearTile(&map, i, except: wonder.occursOn) }
        let conversions = wonder.uniqueObjects.filter { $0.pattern == "Neighboring tiles will convert to []" }
        guard !conversions.isEmpty else { return }
        for j in nbr[i] {
            for u in conversions {
                if let cond = u.conditionals.first(where: { $0.pattern == "in tiles without []" }), map.tiles[j].terrainNames.contains(cond.params[0]) { continue }
                if let cond = u.conditionals.first(where: { $0.pattern == "in tiles with []" }), !map.tiles[j].terrainNames.contains(cond.params[0]) { continue }
                let convertTo = u.params[0]
                if map.tiles[j].baseTerrain == convertTo || map.tiles[j].features.contains(convertTo) { continue }
                guard let terrain = rs.terrains[convertTo] else { continue }
                if terrain.uniques.contains("Fresh water") && map.isAdjacentToCoast(map.tiles[j].coord) { continue }   // Unciv tile.isAdjacentToCoast() (a lazy)
                if terrain.type == .terrainFeature && !terrain.occursOn.contains(map.tiles[j].baseTerrain) { continue }
                if terrain.uniques.contains("Coastal Water") { removeLakesNextToFutureCoast(&map, j, coast: terrain) }
                if terrain.type == .land || terrain.type == .water { clearTile(&map, j); map.tiles[j].baseTerrain = terrain.name }
                if terrain.type == .terrainFeature { clearTile(&map, j, except: map.tiles[j].features); map.tiles[j].features.append(convertTo) }
            }
        }
    }
    private func removeLakesNextToFutureCoast(_ map: inout GameMap, _ i: Int, coast: Terrain) {
        var future: Set<Int> = [i]; var check = [i]; var idx = 0
        while idx < check.count {
            for j in nbr[check[idx]] where rs.terrains[map.tiles[j].baseTerrain]?.uniques.contains("Fresh water") == true { if future.insert(j).inserted { check.append(j) } }
            idx += 1
        }
        for lake in future.subtracting([i]) { clearTile(&map, lake); map.tiles[lake].baseTerrain = coast.name }
        for f in future { map.tiles[f].riverEdges = []; for j in nbr[f] { map.tiles[j].riverEdges.remove(HexCoord.opposite(map.tiles[j].coord.wrappedDirection(to: map.tiles[f].coord).map { HexCoord.opposite($0) } ?? -1)) } }
        // Unciv Tile.setConnectedByRiver: a changed edge resets both tiles' adjacent-to-river transient
        // (resetAdjacentToRiverTransient), and isAdjacentToRiver recounts the edges left on its next read
        var touched = Set<Int>()
        for f in future { touched.insert(f); touched.formUnion(nbr[f]) }
        for t in touched {
            let c = map.tiles[t].coord
            map.tiles[t].riverAdjacent = (0..<6).contains { d in map.hasRiver(between: c, c.neighbor(d)) }
        }
    }

    // MARK: - ancient ruins / editor resources
    mutating func spreadAncientRuins(_ map: inout GameMap) {
        if nbr.count != map.tiles.count { prepare(map) }
        // Unciv MapGenerator.spreadAncientRuins: a random ruins-equivalent improvement on each spread-out location
        let equivalents = rs.improvementOrder.filter { $0 == Names.ancientRuins || rs.improvements[$0]?.uniques.contains("Provides a random bonus when entered") == true }.compactMap { rs.improvements[$0] }
        guard !equivalents.isEmpty else { return }
        // Unciv isPlaceable: `tile.improvementFunctions.canImprovementBeBuiltHere(improvement, gameContext = GameContext.IgnoreConditionals)`.
        // Our port of it is a GameState extension, so a throwaway state holds the map while the tiles are judged (it
        // registers itself as the coastal lookup; the active game's is put back afterwards).
        let savedCoastalLookup = GameMap.coastalLandLookup
        let judge = GameState(settings: GameSettings(), map: map, rng: SeededRandom(seed: 1))
        defer { GameMap.coastalLandLookup = savedCoastalLookup }
        func isPlaceable(_ improvement: ImprovementDef, _ i: Int) -> Bool {
            judge.canImprovementBeBuiltHere(judge.map.tiles[i], improvement, ignoreConditionals: true)
        }
        let suitable = uncivOrder.filter { i in let t = map.tiles[i]; return t.isLand && !t.isImpassable && equivalents.contains { isPlaceable($0, i) } }
        // Unciv: `(suitableTiles.size * ancientRuinCountMultiplier).roundToInt()` - an Int times a Float is a Float
        let count = Stats.roundToInt(Double(Float(suitable.count) * Float(rs.constants.ancientRuinCountMultiplier)))
        // Unciv MapGenerator.kt:458-459 —
        //   val rng = GameContext(tile = tile).stateBasedRandom("MapGenerator.spreadAncientRuins")
        //   val ruins = ruinsEquivalents.values.filter { isPlaceable(it, tile) }.random(rng)
        // Konum listesi paylaşılan akıştan (chooseSpreadOutLocations) gelir, kalıntı seçimi gelmez.
        let frame = UncivSave.Frame.forExport(width: map.width, height: map.height)
        for i in chooseSpreadOutLocations(count, suitable: suitable, map: map) {
            let c = map.tiles[i].coord
            let p = frame.unciv(col: c.offsetCol, row: c.offsetRow)
            var tileRng = mapGenTileRandom("MapGenerator.spreadAncientRuins", x: p.x, y: p.y)
            guard let ruins = tileRng.pick(equivalents.filter { isPlaceable($0, i) }) else { continue }
            map.tiles[i].improvement = ruins.name   // Unciv setImprovementBasic
            judge.map.tiles[i].improvement = ruins.name
        }
    }
    /// Unciv MapGenerator.spreadResources (map editor fallback).
    mutating func spreadResources(_ map: inout GameMap) {
        if nbr.count != map.tiles.count { prepare(map) }
        for i in map.tiles.indices { map.tiles[i].resource = nil }
        let snow = Set(terrainConditions.filter { $0.maybeSnow() }.map { $0.name })
        // Unciv TileResource.generatesNaturallyOn with its conditionals read on the tile ("Doesn't generate naturally
        // <in [Grassland] tiles> <in tiles without [Fresh Water]>", "Never receives any resources <in [Hill] tiles>") -
        // MapRegions' own; ours matched only an unconditional "Doesn't generate naturally", so Sugar went on dry Grassland
        let natural = MapRegions(map: map, rng: rng, ruleset: rs, resourceSetting: resourceSetting)
        func generatesNaturallyOn(_ r: ResourceDef, _ t: Tile) -> Bool { natural.generatesNaturallyOn(r, t) }
        let strategic = rs.resourcesInOrder.filter { $0.resourceType == "Strategic" }
        let candidate = uncivOrder.filter { i in let t = map.tiles[i]; return t.resource == nil && !t.isImpassable && !nbr[i].contains { map.tiles[$0].naturalWonder != nil } }
        let total = Float(candidate.filter { map.tiles[$0].isLand }.count) * resourceRichness   // Unciv: Int * Float
        let perType = strategic.isEmpty ? 0 : Int(total / Float(strategic.count))
        for r in strategic {
            let suitable = candidate.filter { i in let t = map.tiles[i]; return !(snow.contains(t.baseTerrain) && t.isHill) && t.resource == nil && generatesNaturallyOn(r, t) }
            for i in chooseSpreadOutLocations(perType, suitable: suitable, map: map) { setTileResource(&map, i, r) }
        }
        for type in ["Luxury", "Bonus"] {
            let ofType = rs.resourcesInOrder.filter { $0.resourceType == type }
            let suitable = uncivOrder.filter { i in let t = map.tiles[i]; return !(snow.contains(t.baseTerrain) && t.isHill) && t.resource == nil && !nbr[i].contains { map.tiles[$0].naturalWonder != nil } && ofType.contains { generatesNaturallyOn($0, t) } }
            let number = Int(Float(map.tiles.filter { $0.isLand && !$0.isImpassable }.count) * resourceRichness)
            var counts: [String: Int] = [:]
            for i in chooseSpreadOutLocations(number, suitable: suitable, map: map) {
                let possible = ofType.filter { generatesNaturallyOn($0, map.tiles[i]) }
                guard let least = possible.min(by: { (counts[$0.name] ?? 0) < (counts[$1.name] ?? 0) }) else { continue }
                counts[least.name, default: 0] += 1
                setTileResource(&map, i, least)
            }
        }
    }
    /// Unciv Tile.setTileResource(newResource, majorDeposit = null, rng = randomness.RNG): a strategic deposit takes the
    /// "Deposits in [] tiles always provide [] resources" amount without a draw, otherwise one nextDouble of the map's
    /// RNG decides major or minor; any other resource carries no amount.
    private mutating func setTileResource(_ map: inout GameMap, _ i: Int, _ resource: ResourceDef) {
        map.tiles[i].resource = resource.name
        guard resource.resourceType == "Strategic" else { map.tiles[i].resourceAmount = 0; return }
        let tile = map.tiles[i]
        if let u = resource.uniqueObjects.first(where: { $0.pattern == "Deposits in [] tiles always provide [] resources" && tile.matchesTerrainFilterForDeposits($0.param(0)) }) {
            map.tiles[i].resourceAmount = u.int(1)
            return
        }
        let major = rng.nextDouble() < tile.approximateMajorDepositDistribution(rs)
        map.tiles[i].resourceAmount = Tile.depositAmount(resource, on: tile, major: major, setting: resourceSetting)
    }
}

// MARK: - Helpers

/// Kotlin's `Random(seed)` (XorWowRandom) – the same generator Unciv uses, so identical seeds give identical draws.
struct SeededRandom: Codable {
    private var x: Int32, y: Int32, z: Int32, w: Int32, v: Int32, addend: Int32
    init(seed: UInt64) {
        let s = Int64(bitPattern: seed == 0 ? 42 : seed)
        let seed1 = Int32(truncatingIfNeeded: s), seed2 = Int32(truncatingIfNeeded: s >> 32)
        x = seed1; y = seed2; z = 0; w = 0; v = ~seed1
        addend = (seed1 << 10) ^ Int32(bitPattern: UInt32(bitPattern: seed2) >> 4)
        if (x | y | z | w | v) == 0 { v = 1 }
        for _ in 0..<64 { _ = nextInt() }
    }
    /// Kotlin `Random(seed: Int)` = `XorWowRandom(seed, seed shr 31)`.
    /// Unciv `stateBasedRandom` tohumlari Int oldugu icin tam bu yol kullanilir;
    /// `init(seed: UInt64)`'in 0 -> 42 esleme kestirmesi burada YOK (Kotlin'de de yok).
    init(kotlinSeed s: Int32) {
        let seed1 = s, seed2 = s >> 31
        x = seed1; y = seed2; z = 0; w = 0; v = ~seed1
        addend = (seed1 << 10) ^ Int32(bitPattern: UInt32(bitPattern: seed2) >> 4)
        for _ in 0..<64 { _ = nextInt() }   // Kotlin XorWowRandom.init: ilk 64 degeri at
    }
    /// Kotlin `Random(seed: Long)` = `XorWowRandom(seed.toInt(), seed.shr(32).toInt())`.
    /// `Random(Int)`ten FARKLI tohumlar: orada ikinci kelime isaret uzantisi (`s shr 31`),
    /// burada Long'un ust 32 biti. `init(seed: UInt64)`'in `0 -> 42` kestirmesi burada YOK.
    init(kotlinSeedLong s: Int64) {
        let seed1 = Int32(truncatingIfNeeded: s), seed2 = Int32(truncatingIfNeeded: s >> 32)
        x = seed1; y = seed2; z = 0; w = 0; v = ~seed1
        addend = (seed1 << 10) ^ Int32(bitPattern: UInt32(bitPattern: seed2) >> 4)
        for _ in 0..<64 { _ = nextInt() }   // Kotlin XorWowRandom.init: ilk 64 degeri at
    }
    /// Kotlin XorWowRandom.nextInt()
    mutating func nextInt() -> Int32 {
        var t = x
        t ^= Int32(bitPattern: UInt32(bitPattern: t) >> 2)
        x = y; y = z; z = w
        let v0 = v
        w = v0
        t = (t ^ (t << 1)) ^ v0 ^ (v0 << 4)
        v = t
        addend = addend &+ 362437
        return t &+ addend
    }
    mutating func nextBits(_ bitCount: Int) -> Int32 {
        let r = UInt32(bitPattern: nextInt()) >> UInt32(32 - bitCount)
        return Int32(bitPattern: r & (bitCount == 0 ? 0 : 0xFFFFFFFF))
    }
    /// Kotlin nextInt(until): uniform in 0..<until
    mutating func nextInt(until n: Int32) -> Int32 {
        guard n > 0 else { return 0 }
        if n & (0 &- n) == n {
            let bitCount = 31 - n.leadingZeroBitCount
            return nextBits(bitCount)
        }
        while true {
            let bits = Int32(bitPattern: UInt32(bitPattern: nextInt()) >> 1)
            let v = bits % n
            if bits &- v &+ (n &- 1) >= 0 { return v }
        }
    }
    mutating func nextDouble() -> Double {
        let hi = Int64(nextBits(26)), lo = Int64(nextBits(27))
        return Double((hi << 27) + lo) / Double(1 << 53)
    }
    mutating func nextBoolean() -> Bool { nextBits(1) != 0 }
    mutating func nextFloat() -> Float { Float(nextBits(24)) / Float(1 << 24) }
    mutating func nextLong() -> Int64 { (Int64(nextInt()) << 32) &+ Int64(nextInt()) }
    // Epochs API
    mutating func next() -> UInt64 { UInt64(bitPattern: nextLong()) }
    mutating func double() -> Double { nextDouble() }
    mutating func chance(_ p: Double) -> Bool { nextDouble() < p }
    mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(nextInt(until: Int32(clamping: range.count))) }
    mutating func pick<T>(_ a: [T]) -> T? { a.isEmpty ? nil : a[Int(nextInt(until: Int32(a.count)))] }
    /// Kotlin shuffle(random): Fisher–Yates from the end
    mutating func shuffled<T>(_ a: [T]) -> [T] {
        var arr = a
        for i in stride(from: arr.count - 1, to: 0, by: -1) { arr.swapAt(i, Int(nextInt(until: Int32(i + 1)))) }
        return arr
    }
}

/// Smooth value noise in [0,1] with two octaves.
struct Noise {
    let seed: UInt64
    let scale: Double

    private func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15 ^ UInt64(bitPattern: Int64(y)) &* 0xC2B2AE3D27D4EB4F ^ seed
        h = (h ^ (h >> 29)) &* 0xBF58476D1CE4E5B9
        h ^= h >> 32
        return Double(h & 0xFFFFFF) / Double(0xFFFFFF)
    }
    private func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    private func octave(_ x: Double, _ y: Double, _ s: Double) -> Double {
        let fx = x / s, fy = y / s
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = smooth(fx - Double(x0)), ty = smooth(fy - Double(y0))
        let a = hash(x0, y0), b = hash(x0 + 1, y0), c = hash(x0, y0 + 1), d = hash(x0 + 1, y0 + 1)
        return (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty
    }
    func value(_ x: Double, _ y: Double) -> Double {
        (octave(x, y, scale) * 0.65 + octave(x, y, scale / 2.3) * 0.35)
    }
}
