// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv Tile.setTileResource: strategic tiles carry a deposit amount (major/minor deposit × map resource setting).
extension Tile {
    /// Unciv Tile.matchesTerrainFilter for the deposit unique: any of the tile's terrains, its type, or the usual keywords.
    func matchesTerrainFilterForDeposits(_ filter: String) -> Bool {
        let rs = Ruleset.shared
        switch filter {
        case "All", "all", "Terrain": return true
        case "Water", "water": return isWater
        case "Land", "land": return isLand
        case "Hill": return isHill
        case "Natural Wonder": return naturalWonder != nil
        case "Terrain Feature": return !features.isEmpty
        default: break
        }
        if terrainNames.contains(filter) || naturalWonder == filter { return true }
        // a terrain type name, or a unique the tile's terrains carry
        return ([baseTerrain] + features + [naturalWonder].compactMap { $0 }).contains { name in
            guard let t = rs.terrains[name] else { return false }
            return t.type.rawValue == filter || t.uniques.contains(filter)
        }
    }

    static func depositAmount(_ r: ResourceDef, on tile: Tile, major: Bool, setting: String) -> Int {
        guard r.resourceType == "Strategic" else { return 0 }
        // ResourceAmountOnTiles: "Deposits in [tileFilter] tiles always provide [amount] resources"
        for u in r.uniqueObjects where u.pattern == "Deposits in [] tiles always provide [] resources" {
            if tile.matchesTerrainFilterForDeposits(u.param(0)) { return u.int(1) }
        }
        return (major ? r.majorDepositAmount : r.minorDepositAmount).amount(for: setting)
    }

    /// Unciv Tile.approximateMajorDepositDistribution: sum of 1/N over "Every [N] tiles with this terrain will receive a major deposit…", else 1 in 25.
    func approximateMajorDepositDistribution(_ rs: Ruleset) -> Double {
        var p = 0.0
        for name in ([baseTerrain] + features + [naturalWonder].compactMap { $0 }) {   // Unciv allTerrains: the natural wonder counts
            for u in rs.terrains[name]?.uniqueObjects ?? [] where u.pattern == "Every [] tiles with this terrain will receive a major deposit of a strategic resource." {
                if let f = Int(u.param(0)), f > 0 { p += 1.0 / Double(f) }
            }
        }
        return p == 0 ? 0.04 : p
    }
}

extension GameMap {
    /// Strategic tiles placed without an amount (map editor, custom maps, spread fallback) get one as in Unciv setTileResource(majorDeposit = null).
    mutating func assignMissingDepositAmounts(_ rs: Ruleset, setting: String, seed: UInt64) {
        var rng = SeededRandom(seed: seed ^ 0xDE9051)
        for i in tiles.indices {
            guard let name = tiles[i].resource, let r = rs.resources[name], r.resourceType == "Strategic" else { tiles[i].resourceAmount = 0; continue }
            if tiles[i].resourceAmount > 0 { continue }
            let major = rng.double() < tiles[i].approximateMajorDepositDistribution(rs)
            tiles[i].resourceAmount = Tile.depositAmount(r, on: tiles[i], major: major, setting: setting)
        }
    }
}
