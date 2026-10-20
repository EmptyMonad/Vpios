// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/BattleConstants.kt`: the fixed combat modifiers.
/// https://www.carlsguides.com/strategy/civilization5/war/combatbonuses.php
enum BattleConstants {
    static let landingMalus: Double = -50
    static let boardingMalus: Double = -50
    static let attackingAcrossRiverMalus: Double = -20
    static let baseFlankingBonus: Double = 10
    static let missingResourcesMalus: Double = -25
    static let embarkedDefenceBonus = 100
    static let fortificationBonus: Double = 20
    static let damageReductionWoundedUnitRatioPercentage: Double = 300
    /// What a civilian takes from any attack, whoever makes it.
    static let damageToCivilianUnit = 40
}
