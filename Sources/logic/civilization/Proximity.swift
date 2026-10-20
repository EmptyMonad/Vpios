// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv Proximity: how close two civilizations' cities are (CivInfoTransientCache.updateProximity).
enum Proximity: Int, Comparable {
    case none = 0, neighbors, close, far, distant
    static func < (a: Proximity, b: Proximity) -> Bool { a.rawValue < b.rawValue }
}

extension GameState {
    /// Unciv Civilization.getProximity: `proximity[civID] ?: Proximity.None` - a STORED map, written by
    /// updateProximity when a city is founded, destroyed or changes hands, and saved with the game. Ours was
    /// recomputed on demand (once a turn), so it moved when nothing in Unciv had moved it: a third civ's standing
    /// towards a conqueror, or the "few majors left" clamp after a civ died.
    func proximity(_ civId: Int, _ otherId: Int) -> Proximity {
        if civId == otherId { return .none }
        return civ(civId)?.proximityTo[otherId].flatMap { Proximity(rawValue: $0) } ?? .none
    }

    /// Unciv CivInfoTransientCache.updateProximity: with `preCalculated` (the other side's answer, "this function
    /// *should* be symmetrical") it is simply stored; otherwise computed from this civ's cities and capital.
    @discardableResult
    func updateProximity(_ civId: Int, _ otherId: Int, preCalculated: Proximity? = nil) -> Proximity {
        if civId == otherId { return .none }
        guard let ci = civIndex(civId) else { return .none }
        if let pre = preCalculated { civs[ci].proximityTo[otherId] = pre.rawValue; return pre }
        let ours = cities(of: civId), theirs = cities(of: otherId)
        if ours.isEmpty || theirs.isEmpty { civs[ci].proximityTo[otherId] = Proximity.none.rawValue; return .none }
        var minDistance = 100_000, total = 0, connections = 0
        var result = Proximity.none
        for a in ours { for b in theirs { let d = a.coord.distance(to: b.coord); total += d; connections += 1; if minDistance > d { minDistance = d } } }
        if minDistance <= 7 { result = .neighbors }
        else if connections > 0 {
            let average = total / connections
            // Unciv CivInfoTransientCache: mapParameters.mapSize - (height + width) / 2 on a rectangular map, (radius * 3) / 2
            // otherwise (a game saved before the map kept its size measures the grid)
            let mapFactor: Int = map.uncivSize.map { $0.isHexagonal ? ($0.radius * 3) / 2 : ($0.height + $0.width) / 2 }
                ?? map.hexRadius.map { ($0 * 3) / 2 } ?? ((map.width + map.height) / 2)
            let closeDistance = min(20, max(10, mapFactor * 25 / 100))
            let farDistance = min(50, max(20, mapFactor * 45 / 100))
            result = minDistance <= 11 && average <= closeDistance ? .close : average <= farDistance ? .far : .distant
        }
        // Different continents - increase separation by one step (unless already max distance, or water map)
        // Unciv: `capital.getCenterTile().getContinent() != otherCapital.getCenterTile().getContinent()` - the stored ids
        if connections > 0, result != .distant, !isWaterMap(), let capA = capital(of: civId), let capB = capital(of: otherId), continentId(of: capA.coord) != continentId(of: capB.coord) {
            switch result { case .far: result = .distant; case .close: result = .far; case .neighbors: result = .close; default: break }
        }
        // If there aren't many players (left) we can't be that far
        let numMajors = majorCivs.count
        if numMajors <= 2 && result > .close { result = .close }
        if numMajors <= 4 && result > .far { result = .far }
        civs[ci].proximityTo[otherId] = result.rawValue
        return result
    }

    /// Unciv CityFounder: every living major, then every living city-state, that is not already our neighbour -
    /// `civInfo.cache.updateProximity(otherCiv, otherCiv.cache.updateProximity(civInfo))`.
    func updateProximityAfterFounding(_ civId: Int) {
        for other in majorCivs where proximity(civId, other.id) != .neighbors { updateProximity(civId, other.id, preCalculated: updateProximity(other.id, civId)) }
        for other in cityStates where proximity(civId, other.id) != .neighbors { updateProximity(civId, other.id, preCalculated: updateProximity(other.id, civId)) }
    }

    /// Unciv City.destroyCity: every living major and city-state, unconditionally.
    func updateProximityAfterDestroying(_ civId: Int) {
        for other in majorCivs { updateProximity(civId, other.id, preCalculated: updateProximity(other.id, civId)) }
        for other in cityStates { updateProximity(civId, other.id, preCalculated: updateProximity(other.id, civId)) }
    }

    /// Unciv TileMap.isWaterMap: `assignContinents(Ensure)`, then as many big islands (more than 20 tiles) as there
    /// are players, or more. The sizes count the stored continent ids, so mountains are in no island.
    func isWaterMap() -> Bool {
        if map.continentSizes.isEmpty { map.assignContinents(.ensure) }   // Unciv assignContinents(Ensure): returns at once when the sizes are there
        let bigIslands = map.continentSizes.values.filter { $0 > 20 }.count
        return bigIslands >= settings.players.count
    }
}
