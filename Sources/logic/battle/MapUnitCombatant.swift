// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/MapUnitCombatant.kt`: a unit's own strength in a fight, before any
/// percentage modifiers (those live in BattleDamage).
extension GameState {
    /// Unciv MapUnitCombatant.getAttackingStrength: base (or ranged) strength plus the flat "[] Strength" uniques.
    func unitAttackingStrength(_ unit: Unit, ranged: Bool, uniques: [Unique], ctx: UniqueContext) -> Double {
        Double(ranged ? unit.def.rangedStrength : unit.def.strength) + flatStrengthBonus(uniques, ctx)
    }

    /// Unciv MapUnitCombatant.getDefendingStrength: the era's embark defence for a non-civilian at sea,
    /// ranged strength against a ranged attacker, otherwise melee strength - plus the flat "[] Strength" uniques.
    func unitDefendingStrength(_ unit: Unit, attackedByRanged: Bool, uniques: [Unique], ctx: UniqueContext) -> Double {
        if isEmbarked(unit) && !unit.isCivilian { return Double(rs.era(named: civ(unit.civId)?.eraName ?? "")?.embarkDefense ?? 3) }
        if unit.def.isRanged && attackedByRanged { return Double(unit.def.rangedStrength) + flatStrengthBonus(uniques, ctx) }
        return Double(unit.def.strength) + flatStrengthBonus(uniques, ctx)
    }

    /// Unciv MapUnitCombatant: the flat "[amount] Strength" uniques that apply to this fight.
    func flatStrengthBonus(_ uniques: [Unique], _ ctx: UniqueContext) -> Double {
        Double(uniques.filter { $0.pattern == "[] Strength" && conditionalsHold($0, ctx) }.reduce(0) { $0 + $1.int(0) })
    }
}
