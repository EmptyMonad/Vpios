// Vox Populi 4.22 resource monopolies for the VPiOS engine (MPL-2.0).
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// CvPlayer::SetHasGlobalMonopoly / SetHasStrategicMonopoly: a civ holding more than 50% (GLOBAL_RESOURCE_MONOPOLY_
// THRESHOLD) of the world's copies of a monopoly resource has a Global Monopoly on it, more than 25% of a strategic one
// a Strategic Monopoly. Global: the resource's tiles yield Resource_YieldChangeFromMonopoly, every city gets
// Resource_CityYieldModFromMonopoly %, MonopolyHappiness is added to the luxury happiness (VPNeeds), MonopolyGALength
// lengthens golden ages. Strategic: MonopolyAttack/Defense/Heal/XP/Movement bonuses for military units.
// Copies are counted from the map (a strategic deposit counts its amount), owned = on the civ's tiles.

import Foundation

struct VPMonopolyState {
    var global: Set<String> = []
    var strategic: Set<String> = []
}

enum VPMonopolyCache {
    struct Key: Hashable { let game: ObjectIdentifier; let turn: Int; let tiles: Int }
    nonisolated(unsafe) private static var values: [Key: [Int: VPMonopolyState]] = [:]
    private static let lock = NSLock()
    static func get(_ k: Key) -> [Int: VPMonopolyState]? { lock.lock(); defer { lock.unlock() }; return values[k] }
    static func set(_ k: Key, _ v: [Int: VPMonopolyState]) { lock.lock(); defer { lock.unlock() }; if values.count > 64 { values.removeAll() }; values[k] = v }
}

extension GameState {
    /// Every major civ's monopolies, recomputed once per turn (and when the number of owned tiles changes).
    func vpMonopolies() -> [Int: VPMonopolyState] {
        guard let d = vpData else { return [:] }
        let owned = cities.reduce(0) { $0 + $1.tiles.count }
        let key = VPMonopolyCache.Key(game: ObjectIdentifier(self), turn: turn, tiles: owned)
        if let hit = VPMonopolyCache.get(key) { return hit }
        var total: [String: Int] = [:]
        var mine: [Int: [String: Int]] = [:]
        for t in map.tiles {
            guard let r = t.resource, VPData.column(d.resources[r], "IsMonopoly") != 0 else { continue }
            let n = max(1, t.resourceAmount)
            total[r, default: 0] += n
            if let owner = t.ownerCivId { mine[owner, default: [:]][r, default: 0] += n }
        }
        let globalPct = Int(vpNeeds?.define("GLOBAL_RESOURCE_MONOPOLY_THRESHOLD", 50) ?? 50)
        let strategicPct = Int(vpNeeds?.define("STRATEGIC_RESOURCE_MONOPOLY_THRESHOLD", 25) ?? 25)
        var out: [Int: VPMonopolyState] = [:]
        let banned = vpBannedLuxuries   // World Congress: Ban Luxury
        for (civId, counts) in mine where civ(civId)?.isMajor == true {
            var s = VPMonopolyState()
            for (r, n) in counts {
                guard let all = total[r], all > 0 else { continue }
                let pct = n * 100 / all
                if pct > globalPct && !banned.contains(r) { s.global.insert(r) }
                if rs.resources[r]?.resourceType == "Strategic" && pct > strategicPct { s.strategic.insert(r) }
            }
            if !s.global.isEmpty || !s.strategic.isEmpty { out[civId] = s }
        }
        VPMonopolyCache.set(key, out)
        return out
    }

    /// Resource_YieldChangeFromMonopoly on a tile of the monopolist.
    func vpMonopolyTileYield(_ tile: Tile, civId: Int) -> Stats? {
        guard let d = vpData, let r = tile.resource, tile.ownerCivId == civId, vpMonopolies()[civId]?.global.contains(r) == true else { return nil }
        var s = Stats()
        for row in VPData.rows(d.resources[r], "Resource_YieldChangeFromMonopoly") {
            if let stat = row.str("YieldType"), GameState.statNames.contains(stat) { s[stat] += Double(row.int("Yield")) }
        }
        return s.isEmpty ? nil : s
    }

    /// Resource_CityYieldModFromMonopoly: % in every city of the monopolist.
    func vpMonopolyCityPercent(_ civId: Int) -> Stats {
        guard let d = vpData, let m = vpMonopolies()[civId] else { return Stats() }
        var s = Stats()
        for r in m.global {
            for row in VPData.rows(d.resources[r], "Resource_CityYieldModFromMonopoly") {
                if let stat = row.str("YieldType"), GameState.statNames.contains(stat) { s[stat] += Double(row.int("Yield")) }
            }
        }
        return s
    }

    /// MonopolyHappiness of every global monopoly (added to VP's luxury happiness).
    func vpMonopolyHappiness(_ civId: Int) -> Int {
        guard let d = vpData, let m = vpMonopolies()[civId] else { return 0 }
        return m.global.reduce(0) { $0 + Int(VPData.column(d.resources[$1], "MonopolyHappiness")) }
    }

    /// MonopolyGALength: % longer golden ages.
    func vpMonopolyGoldenAgePercent(_ civId: Int) -> Int {
        guard let d = vpData, let m = vpMonopolies()[civId] else { return 0 }
        return m.global.reduce(0) { $0 + Int(VPData.column(d.resources[$1], "MonopolyGALength")) }
    }

    /// Strategic monopoly combat bonuses (%), for a military unit attacking or defending.
    func vpMonopolyCombat(_ civId: Int, attacking: Bool) -> Int {
        guard let d = vpData, let m = vpMonopolies()[civId] else { return 0 }
        let col = attacking ? "MonopolyAttackBonus" : "MonopolyDefenseBonus"
        return m.strategic.union(m.global).reduce(0) { $0 + Int(VPData.column(d.resources[$1], col)) }
    }
}
