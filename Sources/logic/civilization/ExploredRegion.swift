// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CoreGraphics

/// Unciv ExploredRegion: the part of the world a human player has explored, kept as two corners in (longitude;
/// latitude) from the centre of the map - HexMath.getLongitude = x - y (it grows westwards), getLatitude = x + y (it
/// grows northwards). Each explored tile widens it (checkTilePosition). On a world-wrap map the corners swap once the
/// exploration crosses the map edge (topLeft.x < bottomRight.x): the region is then the two strips along the edge and
/// not the unexplored middle. topLeft / bottomRight are saved with the civ; Unciv's other fields are @Transient: the map
/// facts (MapParameters here) and the stage coordinates and flags its minimap and WorldMapHolder cache.
struct ExploredRegion: Codable, Equatable, DefaultProvidable {
    /// libGDX Vector2
    struct Point: Codable, Equatable { var x: Float = 0; var y: Float = 0 }
    /// Top left point of the explored region in hex (long;lat) from the center of the map
    var topLeft = Point()
    /// Bottom right point of the explored region in hex (long;lat) from the center of the map
    var bottomRight = Point()
    static var defaultValue: ExploredRegion { ExploredRegion() }

    /// Unciv ExploredRegion.setMapParameters: the @Transient worldWrap / evenMapWidth / rectangularMap / mapRadius.
    struct MapParameters {
        var worldWrap = false
        var evenMapWidth = false
        var rectangularMap = false
        var mapRadius: Float = 0
        /// Unciv mapParameters.mapSize.width (rectangular) / radius (otherwise) - Minimap.createMinimapTiles' pad reads them
        var mapWidth = 0
        var mapSizeRadius = 0
    }

    /// Unciv `topLeft == Vector2.Zero && bottomRight == Vector2.Zero`: nothing explored yet - the next tile starts the region.
    var isZero: Bool { topLeft == Point() && bottomRight == Point() }

    /// Unciv ExploredRegion.checkTilePosition: widen the region to hold the tile. `explorerLongitude` is
    /// getLongitude(explorerPosition), nil when the tile was explored by no unit (e.g. a revealed capital).
    /// Returns Unciv's mapExplored.
    @discardableResult
    mutating func checkTilePosition(longitude tileLongitude: Int, latitude tileLatitude: Int, explorerLongitude: Int?, _ p: MapParameters) -> Bool {
        var mapExplored = false
        var longitude = Float(tileLongitude)
        let latitude = Float(tileLatitude)

        // First time call
        if isZero {
            topLeft = Point(x: longitude, y: latitude)
            bottomRight = Point(x: longitude, y: latitude)
            return false
        }

        // Check X coord
        if topLeft.x >= bottomRight.x {
            if longitude > topLeft.x {
                // For world wrap maps when the maximumX is reached, we move to a minimumX - 1f
                if p.worldWrap && longitude == p.mapRadius { longitude = p.mapRadius * -1 }
                topLeft.x = longitude
                mapExplored = true
            } else if longitude < bottomRight.x {
                // For world wrap maps when the minimumX is reached, we move to a maximumX + 1f
                if p.worldWrap && longitude == (p.mapRadius * -1 + 1) { longitude = p.mapRadius + 1 }
                bottomRight.x = longitude
                mapExplored = true
            }
        } else {
            // When we cross the map edge with world wrap, the vectors are swapped along the x-axis
            if longitude < bottomRight.x && longitude > topLeft.x {
                let rightSideDistance: Float
                let leftSideDistance: Float
                // If we have explorerPosition, get distance to explorer
                // This solves situations when a newly explored cell is in the middle of an unexplored area
                if let explorerLongitude {
                    let e = Float(explorerLongitude)
                    rightSideDistance = e < 0 && bottomRight.x > 0
                        // The explorer is still on the right edge of the map, but has explored over the edge
                        ? p.mapRadius * 2 + e - bottomRight.x
                        : abs(e - bottomRight.x)
                    leftSideDistance = e > 0 && topLeft.x < 0
                        // The explorer is still on the left edge of the map, but has explored over the edge
                        ? p.mapRadius * 2 - e + topLeft.x
                        : abs(topLeft.x - e)
                } else {
                    // If we don't have explorerPosition, we calculate the distance to the edges of the explored region
                    // e.g. when capitals are revealed
                    rightSideDistance = bottomRight.x - longitude
                    leftSideDistance = longitude - topLeft.x
                }
                // Expand region from the nearest edge
                if rightSideDistance > leftSideDistance { topLeft.x = longitude } else { bottomRight.x = longitude }
                mapExplored = true
            }
        }

        // Check Y coord
        if latitude > topLeft.y {
            topLeft.y = latitude
            mapExplored = true
        } else if latitude < bottomRight.y {
            bottomRight.y = latitude
            mapExplored = true
        }
        return mapExplored
    }

    /// Whether checkTilePosition would change the region for this tile - a tile it leaves alone now it leaves alone
    /// for good, since the region only ever grows.
    func wouldChange(longitude tileLongitude: Int, latitude tileLatitude: Int) -> Bool {
        if isZero { return true }
        let longitude = Float(tileLongitude), latitude = Float(tileLatitude)
        if topLeft.x >= bottomRight.x { if longitude > topLeft.x || longitude < bottomRight.x { return true } }
        else if longitude < bottomRight.x && longitude > topLeft.x { return true }
        return latitude > topLeft.y || latitude < bottomRight.y
    }

    /// Unciv ExploredRegion.isPositionInRegion
    func isPositionInRegion(longitude long: Int, latitude lat: Int) -> Bool {
        let long = Float(long), lat = Float(lat)
        return topLeft.x > bottomRight.x
            ? (long <= topLeft.x && long >= bottomRight.x && lat <= topLeft.y && lat >= bottomRight.y)
            : (((long >= topLeft.x && long >= bottomRight.x) || (long <= topLeft.x && long <= bottomRight.x)) && lat <= topLeft.y && lat >= bottomRight.y)
    }

    /// Unciv ExploredRegion.getWidth: in columns, the width of both strips when the region is swapped
    func getWidth(_ p: MapParameters) -> Int {
        let result: Float = topLeft.x > bottomRight.x ? topLeft.x - bottomRight.x : p.mapRadius * 2 - (bottomRight.x - topLeft.x)
        return Int(result) + 1
    }

    /// Unciv ExploredRegion.getHeight: in latitude steps (half rows)
    func getHeight() -> Int { Int(topLeft.y - bottomRight.y) + 1 }

    /// Unciv ExploredRegion.getMinimapLeft: `(topLeft.x + 1f) * tileSize * -0.75f` - a minimap tile left of it belongs to
    /// the strip across the map edge and is moved right by the map's width
    func minimapLeft(tileSize: Float) -> Float { (topLeft.x + 1) * tileSize * -0.75 }

    /// Unciv ExploredRegion.calculateStageCoords' shouldRestrictX: false once a world-wrap map is explored all the way round
    var shouldRestrictX: Bool { bottomRight.x - topLeft.x != 1 }
}

extension GameMap {
    /// Unciv ExploredRegion.setMapParameters(tileMap.mapParameters): world wrap, and for a rectangular map
    /// `mapRadius = mapSize.width / 2` with an even width (or world wrap) noted, otherwise `mapSize.radius`.
    var exploredRegionParameters: ExploredRegion.MapParameters {
        var p = ExploredRegion.MapParameters()
        p.worldWrap = wrapX
        p.evenMapWidth = wrapX
        let rectangular = uncivSize.map { $0.shape == "Rectangular" } ?? (hexRadius == nil)
        p.mapWidth = uncivSize.map { $0.width } ?? width
        p.mapSizeRadius = uncivSize.map { $0.radius } ?? (hexRadius ?? 0)
        if rectangular {
            p.mapRadius = Float(p.mapWidth / 2)
            p.evenMapWidth = p.mapWidth % 2 == 0 || p.evenMapWidth
            p.rectangularMap = true
        } else {
            p.mapRadius = Float(p.mapSizeRadius)
        }
        return p
    }
    /// Unciv HexMath.getLongitude / getLatitude of a tile's position
    func longitudeLatitude(_ c: HexCoord) -> (longitude: Int, latitude: Int) {
        let p = uncivPosition(c)
        return (p.x - p.y, p.x + p.y)
    }
}

extension GameState {
    /// Unciv Tile.setExplored(player, true, explorerPosition): `if (player.playerType == PlayerType.Human)
    /// player.exploredRegion.checkTilePosition(position, explorerPosition)` - for each tile, in the caller's order.
    func checkExploredRegion(_ ci: Int, _ tiles: [HexCoord], explorer: HexCoord?) {
        guard civs.indices.contains(ci), civs[ci].isPlayer, !tiles.isEmpty else { return }
        let p = map.exploredRegionParameters
        let explorerLongitude = explorer.map { map.longitudeLatitude($0).longitude }
        var region = civs[ci].exploredRegion
        for c in tiles {
            let ll = map.longitudeLatitude(c)
            region.checkTilePosition(longitude: ll.longitude, latitude: ll.latitude, explorerLongitude: explorerLongitude, p)
        }
        if region != civs[ci].exploredRegion { civs[ci].exploredRegion = region }
    }

    /// Unciv `tileMap.values.forEach { it.setExplored(civ, true) }` (revealMapWhenDefeated, OneTimeRevealEntireMap, the
    /// console): the region walks every tile of the map in tileList order.
    func checkExploredRegionForWholeMap(_ ci: Int) {
        let order = map.uncivOrder.isEmpty ? Array(map.tiles.indices) : map.uncivOrder
        checkExploredRegion(ci, order.filter { !map.missing.contains($0) }.map { map.tiles[$0].coord }, explorer: nil)
    }

    /// Saves written before the region was kept have none: build it from the explored tiles, in tileList order.
    func seedMissingExploredRegions() {
        for i in civs.indices where civs[i].isPlayer && civs[i].exploredRegion.isZero && civs[i].explored.count > 1 {
            let order = map.uncivOrder.isEmpty ? Array(map.tiles.indices) : map.uncivOrder
            checkExploredRegion(i, order.map { map.tiles[$0].coord }.filter { civs[i].explored.contains($0) }, explorer: nil)
        }
    }
}

/// The bounding box of a civ's explored tiles in offset coordinates and in map pixels (cached per civ until more tiles
/// get explored) - the replay map's frame.
struct ExploredBounds: Equatable {
    var minCol: Int, maxCol: Int, minRow: Int, maxRow: Int
    var minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat
    var width: Int { maxCol - minCol + 1 }
    var height: Int { maxRow - minRow + 1 }
}

extension GameState {
    /// Bounds of the explored tiles in offset coordinates and in map pixels (cached per civ until more tiles get explored).
    func exploredBounds(for civId: Int) -> ExploredBounds? {
        guard let civ = civ(civId), !civ.explored.isEmpty else { return nil }
        if let cached = exploredBoundsCache[civId], cached.0 == civ.explored.count { return cached.1 }
        var b = ExploredBounds(minCol: Int.max, maxCol: Int.min, minRow: Int.max, maxRow: Int.min, minX: .greatestFiniteMagnitude, maxX: -.greatestFiniteMagnitude, minY: .greatestFiniteMagnitude, maxY: -.greatestFiniteMagnitude)
        for c in civ.explored {
            b.minCol = min(b.minCol, c.offsetCol); b.maxCol = max(b.maxCol, c.offsetCol)
            b.minRow = min(b.minRow, c.offsetRow); b.maxRow = max(b.maxRow, c.offsetRow)
            let p = c.pixelCenter
            b.minX = min(b.minX, p.x); b.maxX = max(b.maxX, p.x); b.minY = min(b.minY, p.y); b.maxY = max(b.maxY, p.y)
        }
        exploredBoundsCache[civId] = (civ.explored.count, b)
        return b
    }
}
