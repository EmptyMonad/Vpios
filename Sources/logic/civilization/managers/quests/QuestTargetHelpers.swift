// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/managers/quests/QuestTargetHelpers.kt`: finding what a quest can point at.
extension GameState {
    /// Unciv getCityStateTarget: a known city-state at the closest proximity level (not Distant) that the challenger also knows
    func cityStateQuestTarget(_ cs: Civilization, _ m: Civilization) -> Civilization? {
        let levels = cityStates.filter { $0.id != cs.id }.map { proximity(cs.id, $0.id) }.filter { $0 != .none }
        guard let closest = levels.min(), closest != .distant else { return nil }
        // Unciv QuestTargetHelpers.kt:153 `validTargets.toList().randomOrNull(getRandom(challenger))`
        var g = stateBasedRandom("QuestManager", civId: cs.id, otherCivId: m.id)
        // Unciv `getKnownCivs()` of the quest giver - its diplomacy map order, not the civ list's
        return g.pick(knownCivs(cs.id).filter { $0.isCityState && m.metCivs.contains($0.id) && proximity(cs.id, $0.id) == closest })
    }

    /// Unciv getMostRecentBully: the civ whose Bullied flag has the most turns left
    func mostRecentBully(_ cs: Civilization) -> Int? {
        // Unciv `diplomacy.values` order; Swift max(by:) keeps the first maximum like maxByOrNull
        diplomacyOrder(cs.id).compactMap { o in cs.diploFlags[o]?["Bullied"].map { (o, $0) } }.max { $0.1 < $1.1 }?.0
    }

    /// Unciv Civilization.hasMetCivTerritory: any tile of the other civ explored
    func hasMetCivTerritory(_ civId: Int, _ other: Int) -> Bool {
        guard let c = civ(civId) else { return false }
        return cities(of: other).contains { city in city.tiles.contains { c.explored.contains($0) } }
    }

    /// Unciv DiplomacyFlags.Denunciation (30 turns)
    func isDenouncing(_ a: Int, _ b: Int) -> Bool { hasFlag(a, b, "Denunciation") }   // Unciv DiplomacyFlags.Denunciation (30 turns)

    /// Road (or harbour) connection from the civ's capital to a tile.
    func connectedTo(coord: HexCoord, civId: Int) -> Bool {
        guard let cap = capital(of: civId) else { return false }
        var seen: Set<HexCoord> = [cap.coord]; var frontier = [cap.coord]
        while let cur = frontier.popLast() {
            if cur == coord { return true }
            for n in map.neighbors(of: cur) where !seen.contains(n) {
                guard let t = map[n], t.roads || t.isCityCenter else { continue }
                seen.insert(n); frontier.append(n)
            }
        }
        return false
    }
}
