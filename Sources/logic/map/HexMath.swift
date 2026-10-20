// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CoreGraphics

/// Axial hex coordinate on a FLAT-TOP grid (the layout Unciv and the FantasyHex art use).
/// Directions, in order: SE, NE, N, NW, SW, S.
struct HexCoord: Hashable, Codable, CustomStringConvertible {
    var q: Int
    var r: Int

    init(_ q: Int, _ r: Int) { self.q = q; self.r = r }

    var s: Int { -q - r }
    var description: String { "(\(q),\(r))" }

    static let directions: [HexCoord] = [
        HexCoord(1, 0), HexCoord(1, -1), HexCoord(0, -1),
        HexCoord(-1, 0), HexCoord(-1, 1), HexCoord(0, 1)
    ]
    static let dirSE = 0, dirNE = 1, dirN = 2, dirNW = 3, dirSW = 4, dirS = 5

    /// Unciv Tile.neighbors is getTilesAtDistance(1), whose ring starts at the south tile and pairs every tile
    /// with its mirror: S, N, SW, NE, NW, SE. The direction indices themselves keep their order, because the
    /// river edges are stored against them.
    static let uncivNeighborOrder = [dirS, dirN, dirSW, dirNE, dirNW, dirSE]
    var neighbors: [HexCoord] { HexCoord.uncivNeighborOrder.map { let d = HexCoord.directions[$0]; return HexCoord(q + d.q, r + d.r) } }
    func neighbor(_ dir: Int) -> HexCoord { let d = HexCoord.directions[dir]; return HexCoord(q + d.q, r + d.r) }
    static func opposite(_ dir: Int) -> Int { (dir + 3) % 6 }
    /// Direction index from self to an adjacent hex, or nil.
    func direction(to o: HexCoord) -> Int? { HexCoord.directions.firstIndex { HexCoord(q + $0.q, r + $0.r) == o } }

    /// When a game with a wrapping map is active, distances take the shorter way around the globe.
    nonisolated(unsafe) static var wrapWidth: Int? = nil

    func distance(to o: HexCoord) -> Int {
        let direct = (abs(q - o.q) + abs(r - o.r) + abs(s - o.s)) / 2
        guard let w = HexCoord.wrapWidth else { return direct }
        var best = direct
        for k in [w, -w] {
            let shifted = HexCoord.fromOffset(col: o.offsetCol + k, row: o.offsetRow)
            let d = (abs(q - shifted.q) + abs(r - shifted.r) + abs(s - shifted.s)) / 2
            if d < best { best = d }
        }
        return best
    }
    /// Direction to an adjacent hex, also across the seam of a wrapping map.
    func wrappedDirection(to o: HexCoord) -> Int? {
        if let d = direction(to: o) { return d }
        guard let w = HexCoord.wrapWidth else { return nil }
        for k in [w, -w] { if let d = direction(to: HexCoord.fromOffset(col: o.offsetCol + k, row: o.offsetRow)) { return d } }
        return nil
    }

    /// All hexes within `radius` (inclusive), including self.
    func ring(radius: Int) -> [HexCoord] {
        var out: [HexCoord] = []
        for dq in -radius...radius {
            for dr in max(-radius, -dq - radius)...min(radius, -dq + radius) {
                out.append(HexCoord(q + dq, r + dr))
            }
        }
        return out
    }

    // MARK: offset ("odd-q", columns shoved down) storage conversions
    static func fromOffset(col: Int, row: Int) -> HexCoord {
        HexCoord(col, row - (col - (col & 1)) / 2)
    }
    var offsetCol: Int { q }
    var offsetRow: Int { r + (q - (q & 1)) / 2 }

    // MARK: pixel conversion — flat-top hexes, circumradius 16 (32px wide art), 28px tall
    static let hexRadius: CGFloat = 16
    static let imageWidth: CGFloat = 32
    static let imageHeight: CGFloat = 28
    static let colStep: CGFloat = 24                       // 1.5 * R
    static let rowStep: CGFloat = 27.7128                  // sqrt(3) * R
    static let tileWidth: CGFloat = 24                     // kept for camera math
    static let tileHeight: CGFloat = 28

    /// Center of the hex in scene units (y up).
    var pixelCenter: CGPoint {
        let x = HexCoord.colStep * CGFloat(q)
        let y = -HexCoord.rowStep * (CGFloat(r) + CGFloat(q) / 2)
        return CGPoint(x: x, y: y)
    }

    static func fromPixel(_ p: CGPoint) -> HexCoord {
        let x = p.x, y = -p.y
        let qf = (2.0 / 3.0 * x) / hexRadius
        let rf = (-1.0 / 3.0 * x + sqrt(3) / 3.0 * y) / hexRadius
        return cubeRound(qf, rf)
    }

    private static func cubeRound(_ qf: CGFloat, _ rf: CGFloat) -> HexCoord {
        let sf = -qf - rf
        var q = Int(qf.rounded()), r = Int(rf.rounded()), s = Int(sf.rounded())
        let dq = abs(CGFloat(q) - qf), dr = abs(CGFloat(r) - rf), ds = abs(CGFloat(s) - sf)
        if dq > dr && dq > ds { q = -r - s } else if dr > ds { r = -q - s } else { s = -q - r }
        return HexCoord(q, r)
    }

    /// Corner positions relative to the centre: E, NE, NW, W, SW, SE. Edge `d` spans corners d-1 and d.
    static let corners: [CGPoint] = [
        CGPoint(x: 16, y: 0), CGPoint(x: 8, y: 14), CGPoint(x: -8, y: 14),
        CGPoint(x: -16, y: 0), CGPoint(x: -8, y: -14), CGPoint(x: 8, y: -14)
    ]
    static func edgeCorners(_ d: Int) -> (CGPoint, CGPoint) { (corners[(d + 5) % 6], corners[d]) }
}

/// Unciv HexMath (logic/map/HexMath.kt) on Unciv's own hex positions: x is the 10 o'clock axis, y the 2 o'clock one,
/// column = y - x, latitude = x + y. `UncivSave.Frame` maps these to and from our offset grid.
enum HexMath {
    typealias Position = (x: Int, y: Int)

    /// HexMath.getNumberOfTilesInHexagon
    static func numberOfTilesInHexagon(_ size: Int) -> Int { size < 0 ? 0 : 1 + 6 * size * (size + 1) / 2 }
    /// HexMath.getHexagonalRadiusForArea - Float, as Unciv computes it
    static func hexagonalRadiusForArea(_ numberOfTiles: Int) -> Float {
        numberOfTiles < 1 ? 0 : ((12 * Float(numberOfTiles) - 3).squareRoot() - 3) / 6
    }
    /// Kotlin Float.roundToInt (Math.round)
    static func roundToInt(_ f: Float) -> Int {
        if f.isNaN { return 0 }
        if f >= Float(Int32.max) { return Int(Int32.max) }
        if f <= Float(Int32.min) { return Int(Int32.min) }
        return Int((f + 0.5).rounded(.down))
    }
    /// HexMath.getEquivalentRectangularSize(size, ratio = 0.65f)
    static func equivalentRectangularSize(_ size: Int, ratio: Float = 0.65) -> (width: Int, height: Int) {
        if size < 0 { return (0, 0) }
        let nTiles = numberOfTilesInHexagon(size)
        let width = roundToInt((Float(nTiles) / ratio).squareRoot())
        let height = roundToInt(Float(width) * ratio)
        return (width, height)
    }
    /// HexMath.getEquivalentHexagonalRadius
    static func equivalentHexagonalRadius(width: Int, height: Int) -> Int { roundToInt(hexagonalRadiusForArea(width * height)) }

    /// HexMath.getLatitude / getLongitude
    static func latitude(_ p: Position) -> Int { p.x + p.y }
    static func longitude(_ p: Position) -> Int { p.x - p.y }
    /// HexMath.getColumn
    static func column(_ p: Position) -> Int { p.y - p.x }

    /// HexMath.getTileCoordsFromColumnRow: odd columns sit half a row up
    static func tileCoordsFromColumnRow(_ column: Int, _ row: Int) -> Position {
        var twoRows = row * 2
        if abs(column) % 2 == 1 { twoRows += 1 }
        return ((twoRows - column) / 2, (twoRows + column) / 2)
    }

    /// HexMath.getDistance (without world wrap)
    static func distance(_ a: Position, _ b: Position) -> Int {
        let relativeX = a.x - b.x, relativeY = a.y - b.y
        return relativeX * relativeY >= 0 ? max(abs(relativeX), abs(relativeY)) : abs(relativeX) + abs(relativeY)
    }

    /// HexMath.getHexCoordsAtDistance: from 6 o'clock, every position followed by its mirror through the origin; on a
    /// wrapping map the outermost ring skips the mirrors that would land on the seam twice.
    static func hexCoordsAtDistance(origin: Position, distance: Int, maxDistance: Int, worldWrap: Bool) -> [Position] {
        if distance == 0 { return [origin] }
        var vectors: [Position] = []
        func otherSideOfClock(_ v: Position) -> Position { (origin.x * 2 - v.x, origin.y * 2 - v.y) }
        var current: Position = (origin.x - distance, origin.y - distance)   // start at 6 o'clock
        for _ in 0..<distance {   // from 6 to 8
            vectors.append(current)
            vectors.append(otherSideOfClock(current))
            current = (current.x + 1, current.y)
        }
        for _ in 0..<distance {   // 8 to 10
            vectors.append(current)
            if !worldWrap || distance != maxDistance { vectors.append(otherSideOfClock(current)) }
            current = (current.x + 1, current.y + 1)
        }
        for i in 0..<distance {   // 10 to 12
            vectors.append(current)
            if !worldWrap || distance != maxDistance || i != 0 { vectors.append(otherSideOfClock(current)) }
            current = (current.x, current.y + 1)
        }
        return vectors
    }
    /// HexMath.getHexCoordsInDistance: ring 0, 1, … distance
    static func hexCoordsInDistance(origin: Position, distance: Int, worldWrap: Bool) -> [Position] {
        guard distance >= 0 else { return [] }
        return (0...distance).flatMap { hexCoordsAtDistance(origin: origin, distance: $0, maxDistance: distance, worldWrap: worldWrap) }
    }

    /// Unciv TileMap(width, height, ruleset, worldWrap): `for (column …) for (row …)` - a wrapping map rounds an odd
    /// width down (wrapAdjustedWidth), and an even width runs -w/2 … w/2-1.
    static func rectangularPositions(width: Int, height: Int, worldWrap: Bool) -> [Position] {
        let wrapAdjustedWidth = worldWrap && width % 2 != 0 ? width - 1 : width
        var out: [Position] = []
        out.reserveCapacity(max(0, wrapAdjustedWidth * height))
        for column in stride(from: -wrapAdjustedWidth / 2, through: (wrapAdjustedWidth - 1) / 2, by: 1) {
            for row in stride(from: -height / 2, through: (height - 1) / 2, by: 1) {
                out.append(tileCoordsFromColumnRow(column, row))
            }
        }
        return out
    }

    /// HexMath.getVectorByClockHour: `getVectorForAngle((2 * PI * (hour / 12f)).toFloat())`, a Float vector
    private static func vectorByClockHour(_ hour: Int) -> (x: Float, y: Float) {
        let angle = Float(2 * Double.pi * Double(Float(hour) / 12))
        return (Float(sin(Double(angle))), Float(cos(Double(angle))))
    }
    private static let clockHour10 = vectorByClockHour(10), clockHour2 = vectorByClockHour(2)
    /// HexMath.hex2WorldCoords: the 10 and 2 o'clock unit vectors scaled by sqrt(3) and summed, all in Float
    static func hex2WorldCoords(_ p: Position) -> (x: Float, y: Float) {
        let s3 = Float(3.0.squareRoot())
        let xScale = s3 * Float(p.x), yScale = s3 * Float(p.y)
        let xVectorX = clockHour10.x * xScale, xVectorY = clockHour10.y * xScale   // xVector.scl(...)
        let yVectorX = clockHour2.x * yScale, yVectorY = clockHour2.y * yScale     // yVector.scl(...)
        return (xVectorX + yVectorX, xVectorY + yVectorY)                           // xVector.add(yVector)
    }

    /// HexMath.getDistanceFromEdge(position, mapParameters): measured against the map's shape and mapSize, with Kotlin's
    /// truncating Int division (Swift's is the same)
    static func distanceFromEdge(_ p: Position, mapSize: UncivMapSize, worldWrap: Bool) -> Int {
        let x = p.x, y = p.y
        if !mapSize.isHexagonal {
            let height = mapSize.height, width = mapSize.width
            let left = worldWrap ? Int.max : width / 2 - (x - y)
            let right = worldWrap ? Int.max : (width - 1) / 2 - (y - x)
            let top = height / 2 - (x + y) / 2
            // kotlin's Int division rounds in different directions depending on sign! Thus 1 extra `-1`
            let bottom = (x + y - 1) / 2 + (height - 1) / 2
            return min(left, right, top, bottom)
        }
        let radius = mapSize.radius
        if !worldWrap { return radius - distance(p, (0, 0)) }
        // The non-wrapping method holds in the upper two and lower two 'triangles' of the hexagon, but the left and
        // right 'wedges' only count the distance from the 'choke points' at (radius, 0) and (0, -radius)
        if x.signum() == y.signum() { return radius - distance(p, (0, 0)) }
        // left wedge - the 'choke points' are not wrapped relative to us
        if x > 0 { return min(distance(p, (radius, 0)), distance(p, (0, -radius))) }
        // right wedge - compensate wrap by using a hex 1 off along the edge - same result
        return min(distance(p, (1, radius)), distance(p, (-radius, -1)))
    }
}
