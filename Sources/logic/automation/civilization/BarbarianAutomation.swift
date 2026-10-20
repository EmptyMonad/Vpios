// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's civilization/BarbarianAutomation.kt.
extension GameState {
    func barbarianAutomate(_ civId: Int) {
        // ranged go first, after melee and then everyone else
        for u in units(of: civId) where u.def.isRanged { automateBarbarianUnit(u.id) }
        for u in units(of: civId) where u.def.isMelee { automateBarbarianUnit(u.id) }
        for u in units(of: civId) where !u.def.isRanged && !u.def.isMelee { automateBarbarianUnit(u.id) }
    }
    private func automateBarbarianUnit(_ unitId: Int) {
        guard let unit = unit(unitId) else { return }
        if unit.isCivilian { automateCapturedCivilian(unitId) }
        else if map[unit.coord]?.hasBarbarianCamp == true { automateUnitOnEncampment(unitId) }
        else { automateBarbarianCombatUnit(unitId) }
    }
    private func automateCapturedCivilian(_ unitId: Int) {
        guard let unit = unit(unitId) else { return }
        if map[unit.coord]?.hasBarbarianCamp == true { return }
        // Unciv getEncampmentTiles (ghost camps included) `.sortBy { aerialDistanceTo }` - a stable sort
        let camps = encampments.map { $0.position }.enumerated().sorted { a, b in
            let da = a.element.distance(to: unit.coord), db = b.element.distance(to: unit.coord)
            return da != db ? da < db : a.offset < b.offset
        }.map { $0.element }
        if let best = camps.first(where: { !units(at: $0).contains { $0.isCivilian } && canReach(unit, $0) }) { _ = headTowards(unitId, best) }
        else { wander(unitId) }
    }
    private func automateUnitOnEncampment(_ unitId: Int) {
        if tryUpgradeUnit(unitId) { return }
        if tryAttackNearbyEnemy(unitId, stayOnTile: true) { return }
        fortifyIfCan(unitId)
    }
    private func automateBarbarianCombatUnit(_ unitId: Int) {
        guard let unit = unit(unitId) else { return }
        if unit.health < 50 && tryPillageImprovement(unitId, onlyPillageToHeal: true) && !(self.unit(unitId)?.hasMovement ?? false) { return }
        if tryUpgradeUnit(unitId) { return }
        if tryDisembarkUnitToAttackPosition(unitId) { return }
        if !unit.isCivilian && tryAttackNearbyEnemy(unitId) { return }
        while tryPillageImprovement(unitId) { if !(self.unit(unitId)?.hasMovement ?? false) { return } }
        wander(unitId)
    }
}
