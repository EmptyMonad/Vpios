// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/GreatGeneralImplementation.kt`: the aura a Great General projects, and
/// where it should stand to project it over as many troops as possible.
extension GameState {
    /// Unciv GreatGeneralImplementation.getGreatGeneralBonus: every unit of our civ carrying "[]% Strength bonus for
    /// [] units within [] tiles" - its uniques judged in `GameContext(unit.civ, ourCombatant, theirCombatant,
    /// combatAction)` - in range of our unit and matching its filter; the strongest one wins (the first of equals),
    /// doubled for a "Great Person - [War]" when we have "Great General provides double combat bonus".
    /// A Great General is in its own candidate list, so it strengthens itself as well.
    func getGreatGeneralBonus(_ ourUnitCombatant: Combatant, _ enemy: Combatant, action: String) -> (String, Int) {
        guard let unit = cUnit(ourUnitCombatant) else { return ("", 0) }
        let ctx = UniqueContext(civId: unit.civId, unit: unit, opponentUnit: enemy.isCity ? nil : cUnit(enemy), opponentIsCity: enemy.isCity,
                                opponentCivId: cCivId(enemy), combatAction: action)
        var best: (general: Unit, bonus: Int)? = nil
        for general in units(of: unit.civId) {
            for u in general.promotionUniques where u.pattern == "[]% Strength bonus for [] units within [] tiles" && conditionalsHold(u, ctx) {
                let radius = u.int(2), filter = u.param(1), bonus = u.int(0)
                guard general.coord.distance(to: unit.coord) <= radius, filter == "Military" || unitMatches(unit, filter) else { continue }
                if best == nil || bonus > best!.bonus { best = (general, bonus) }
            }
        }
        guard let g = best else { return ("", 0) }
        if unitHasUnique(unit, "Great General provides double combat bonus", nil, checkCivInfoUniques: true) && g.general.def.uniques.contains("Great Person - [War]") {
            return (g.general.name, g.bonus * 2)
        }
        return (g.general.name, g.bonus)
    }

    /// The same aura for the battle table's estimate, which has no opponent.
    func greatGeneralBonus(_ unit: Unit, unitUniques: [Unique]) -> (name: String, bonus: Double)? {
        let (name, bonus) = getGreatGeneralBonus(.probe(unit), .probe(unit), action: "Attack")
        return bonus == 0 ? nil : (name, Double(bonus))
    }

    /// Unciv GreatGeneralImplementation.getBestAffectedTroopsTile: the reachable tile where the aura covers
    /// the most of our troops, pulled toward the enemy city our units are heading for. Aircraft are not a tile's
    /// military unit, so they neither hold a tile nor count for or against one.
    func bestAffectedTroopsTile(_ general: Unit) -> HexCoord? {
        let militaryTiles = ([general.coord] + reachableTilesInOrder(general)).filter { c in
            guard let m = militaryUnitOn(c), m.civId == general.civId else { return false }
            let civilian = civilianUnitOn(c)
            return civilian == nil || civilian!.id == general.id
        }
        let closestEnemyCity = enemyCitiesByPriority(general).first { canReach(general, $0.coord) }
        return militaryTiles.max { a, b in
            func score(_ t: HexCoord) -> Int {
                let near = map.tilesWithin(t, radius: 2)
                var s = 2 * near.filter { militaryUnitOn($0)?.civId == general.civId }.count
                s -= near.filter { militaryUnitOn($0)?.civId != general.civId }.count   // Unciv: militaryUnit?.civ != general.civ counts empty tiles too
                if let c = closestEnemyCity { s -= 3 * t.distance(to: c.coord) }
                return s
            }
            return score(a) < score(b)
        }
    }
}
