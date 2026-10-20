// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

extension GameState {
    /// Unciv UseGoldAutomation.maybeBuyCityTiles
    func maybeBuyCityTiles(_ civId: Int) {
        if epochsNoTileBuy { return }
        // Unciv: `if (gameInfo.turns < (speed.scienceCostModifier * 20).toInt()) return` - the Float product truncated,
        // on Unciv's zero-based counter (uncivTurns).
        guard let civ = civ(civId), civ.gold > 0, uncivTurns >= Int(Float(speed.scienceCostModifier) * 20) else { return }
        var desirable: [(HexCoord, City)] = []
        for city in cities(of: civId) where !city.isPuppet && !city.razing {
            // Unciv walks the second ring with forEachTileAtDistance(2) and puts what it finds into a sorted map.
            for c in map.tilesInDistanceUncivOrder(city.coord, radius: 2) where c.distance(to: city.coord) == 2 {
                if isHighlyDesirableTile(c, civId: civId, city: city) { desirable.append((c, city)) }
            }
        }
        // Unciv keeps these in a TreeMap ordered by natural wonder, then luxury, then strategic, then Tile.hashCode().
        // The reference runs with every identity hash = 1, so two tiles of the same class compare EQUAL: the map keeps
        // the first one found under that key and `getOrPut(it) { mutableSetOf() }.add(city)` adds every later city to
        // ITS set. One tile per class, in class order; the cities that found any tile of the class, in insertion order.
        func rank(_ c: HexCoord) -> Int { let t = map[c]!; return (t.naturalWonder != nil ? 4 : 0) + (rs.resources[t.resource ?? ""]?.resourceType == "Luxury" ? 2 : 0) + (rs.resources[t.resource ?? ""]?.resourceType == "Strategic" ? 1 : 0) }
        var classes: [(rank: Int, tile: HexCoord, cities: [City])] = []
        for (c, city) in desirable {
            let r = rank(c)
            if let i = classes.firstIndex(where: { $0.rank == r }) {
                if !classes[i].cities.contains(where: { $0.id == city.id }) { classes[i].cities.append(city) }
            } else { classes.append((r, c, [city])) }
        }
        classes.sort { $0.rank > $1.rank }
        if epochsDebug, !classes.isEmpty {
            print("BUYE t=\(turn) civ=\(civ.nation) gold=\(Int(civ.gold)) | " + classes.map { e -> String in
                let u = uncivPosition(e.tile); let t = map[e.tile]!
                return "(\(u.x),\(u.y))\(t.baseTerrain)/\(t.resource ?? "-")@\(e.cities.map { $0.name })"
            }.joined(separator: " "))
        }
        for entry in classes {
            let tile = entry.tile
            // Unciv `value.minBy { it.getCenterTile().aerialDistanceTo(key) }`: the first of the nearest
            var closest: City? = nil
            for c in entry.cities where closest == nil || c.coord.distance(to: tile) < closest!.coord.distance(to: tile) { closest = c }
            guard let best = closest.flatMap({ self.city($0.id) }) else { continue }
            let path = tilePathToBuy(from: best, to: tile)
            guard !path.isEmpty else { continue }
            var spent = 0, bought: [HexCoord] = [], ranOutOfMoney = false
            for step in path {
                guard let now = self.city(best.id), purchasableTiles(now).contains(step) else { ranOutOfMoney = true; break }
                let cost = tilePurchaseCost(now, tile: step)
                guard (self.civ(civId)?.gold ?? 0) >= Double(cost), buyTile(cityId: best.id, step) else { ranOutOfMoney = true; break }
                spent += cost
                bought.append(step)
            }
            // Unciv buys the path and reverts it as a whole, because each purchase makes the next one dearer
            if ranOutOfMoney {
                // Unciv relinquishes EVERY tile of the path, the ones it never got to buy too: each call still ends in
                // updateOurTiles + cityStats.update, so the city's stats are refreshed for its current construction
                // (Athens, having just switched to a building, got Republic's +5% before its production was added).
                for b in path { relinquishOwnership(cityId: best.id, b, evenIfNotOwned: !bought.contains(b)) }
                if let idx = civIndex(civId) { civs[idx].gold += Double(spent); goldTrace(civId, Double(spent)) }
            }
        }
    }
}
