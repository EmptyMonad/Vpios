// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Part of the mirror of Unciv `logic/map/mapgenerator/RiverGenerator.kt` that works on a game's map: the companion's
/// continueRiverOn, "In-game new rivers work on edges" (the developer console's `tile addfeature River`). The map
/// generation half lives in MapGenerator.
extension GameState {
    /// Unciv TileMap.getNeighborTileClockPosition / getClockPositionNeighborTile: the six neighbours by the clock -
    /// 12 north, 2 north-east, 4 south-east, 6 south, 8 south-west, 10 north-west.
    private static let riverClockToDirection: [Int: Int] = [12: HexCoord.dirN, 2: HexCoord.dirNE, 4: HexCoord.dirSE, 6: HexCoord.dirS, 8: HexCoord.dirSW, 10: HexCoord.dirNW]

    /// Unciv RiverGenerator.continueRiverOn(tile): one more river edge on a land tile, towards the land neighbour whose
    /// edge scores best - an edge towards the sea (unless the tile already has one), then one joining open river ends -
    /// a tie drawn with `GameContext(tile = tile).stateBasedRandom("RiverGenerator.continueRiverOn")`; the two tiles
    /// then convert as "Becomes [] when adjacent to [River]" asks (setConnectedByRiver(convertTerrains = true)).
    @discardableResult
    func continueRiverOn(_ c: HexCoord) -> Bool {
        guard let tile = map[c], tile.isLand else { return false }
        func clockNeighbor(_ clockPosition: Int) -> HexCoord? {
            // HexMath.getClockPositionToHexcoord knows only the six even hours: Kotlin's `(2 - 2) % 12` is 0, no tile
            guard let d = GameState.riverClockToDirection[clockPosition] else { return nil }
            let n = map.normalize(c.neighbor(d))
            return map.contains(n) ? n : nil
        }
        func connected(_ a: HexCoord?, _ b: HexCoord) -> Bool? { a.map { map.hasRiver(between: $0, b) } }
        struct NeighborData {
            let otherTile: HexCoord
            let isConnectedByRiver: Bool
            let edgeLeadsToSea: Bool
            let connectedRiverCount: Int
            let verticesFormYCount: Int
            func getPriority(_ edgeToSeaPriority: Int) -> Int {
                if isConnectedByRiver { return -9 }   // "ensures this isn't chosen"
                if edgeLeadsToSea { return edgeToSeaPriority + connectedRiverCount - 3 * verticesFormYCount }
                if verticesFormYCount == 2 { return -2 }
                if verticesFormYCount == 1 { return connectedRiverCount * 2 - 5 }
                return connectedRiverCount * 2
            }
        }
        // Collect data (includes tiles we already have a river edge with - need the stats)
        var viableNeighbors: [NeighborData] = []
        for other in map.neighbors(of: c) where map[other]?.isLand == true {   // tile.neighbors.filter { it.isLand }
            guard let d = c.wrappedDirection(to: other),
                  let clockPosition = GameState.riverClockToDirection.first(where: { $0.value == d })?.key else { continue }
            let left = clockNeighbor((clockPosition - 2) % 12), right = clockNeighbor((clockPosition + 2) % 12)
            let edgeLeadsToSea = (left.flatMap { map[$0]?.isWater } ?? false) || (right.flatMap { map[$0]?.isWater } ?? false)
            let connectedRiverCount = [connected(left, c), connected(left, other), connected(right, c), connected(right, other)].filter { $0 == true }.count
            let verticesFormYCount = [left, right].filter { n in n.map { map.hasRiver(between: $0, c) && map.hasRiver(between: $0, other) } ?? false }.count
            viableNeighbors.append(NeighborData(otherTile: other, isConnectedByRiver: map.hasRiver(between: c, other), edgeLeadsToSea: edgeLeadsToSea,
                                                connectedRiverCount: connectedRiverCount, verticesFormYCount: verticesFormYCount))
        }
        if viableNeighbors.allSatisfy({ $0.isConnectedByRiver }) { return false }   // cannot place another river
        // Greatly encourage connecting to sea unless the tile already has a river to sea, in which case slightly discourage another one
        let edgeToSeaPriority = viableNeighbors.contains { $0.isConnectedByRiver && $0.edgeLeadsToSea } ? -1 : 9
        // GameContext(tile = tile): no civ, no city, no gameInfo - only the tile's position enters the hash
        let contextHash = hashOf(0, 0, 0, 0, 0, uncivPositionHash(c), 0, 0, 0, 0, 0, 0, javaBoolHash(false))
        var rng = SeededRandom(kotlinSeed: hashOf(javaStringHash("RiverGenerator.continueRiverOn"), 31, contextHash))
        // groupBy { priority } (first-seen key order) .maxBy { key } (the first highest) .value.random(rng)
        var groups: [(key: Int, value: [NeighborData])] = []
        for n in viableNeighbors {
            let key = n.getPriority(edgeToSeaPriority)
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].value.append(n) } else { groups.append((key, [n])) }
        }
        guard var best = groups.first else { return false }
        for g in groups.dropFirst() where g.key > best.key { best = g }
        let choice = best.value[Int(rng.nextInt(until: Int32(best.value.count)))]
        // Tile.setConnectedByRiver(choice.otherTile, newValue = true, convertTerrains = true)
        guard let d = c.wrappedDirection(to: choice.otherTile), !map.hasRiver(between: c, choice.otherTile) else { return false }
        map.setRiver(c, dir: d, true)
        for t in [c, choice.otherTile] {
            let adjacent = (0..<6).contains { map.hasRiver(between: t, t.neighbor($0)) }
            map.update(t) { $0.riverAdjacent = adjacent }
        }
        var gen = MapGenerator(seed: 42)   // MapGenerator.Helpers.convertTerrains(ruleset, affectedTiles): no draws
        gen.convertTerrains(&map, tiles: [c, choice.otherTile])
        return true
    }
}
