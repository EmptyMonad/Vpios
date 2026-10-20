// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
extension GameState {
    // Unciv Unique.getMultiplied: "for every [countable]", "for every [amount] [countable]" and "for every adjacent [tileFilter]"
    // repeat the unique (0 drops it). Counting may itself collect uniques, so nested expansion is skipped - the guard is
    // the game's own `expandingMultipliers` (GameInfo.swift).

    /// Mirror of Unciv `GameContext`. Unciv's fields and our counterparts:
    ///   civInfo        -> `civId` (always set here; Unciv falls back to the city's / unit's civ, which is the same civ)
    ///   city           -> `city`
    ///   unit           -> `unit`
    ///   tile           -> `tile`
    ///   ourCombatant   -> `unit`, or `city` when there is no unit, in a combat context (`isCombat`)
    ///   theirCombatant -> `opponentUnit`, or `opponentCity` (a CityCombatant)
    ///   attackedTile   -> `attackedTile`
    ///   combatAction   -> `combatAction` ("Attack" / "Defend" / "Intercept"), or derived from `attacking`
    ///   otherCiv       -> `opponentCivId`
    ///   region         -> none (only the map generator has regions, and it keeps its own context)
    struct UniqueContext {
        var civId: Int
        var city: City? = nil
        var unit: Unit? = nil
        var tile: Tile? = nil
        var attackedTile: Tile? = nil   // Unciv GameContext.attackedTile: the tile the fight is about
        var attacking: Bool? = nil
        var opponentUnit: Unit? = nil
        var opponentIsCity = false
        var opponentCivId: Int? = nil   // Unciv resolves "vs [filter]" against the combatant, and a city combatant answers for its civ
        var production: Production? = nil
        var sourceTech: String? = nil     // Unciv Unique.sourceObjectType == Tech (ConditionalFirstCivToResearch)
        var sourcePolicy: String? = nil   // Unciv Unique.sourceObjectType == Policy (ConditionalFirstCivToAdopt)
        /// Unciv GameContext.combatAction: "Attack" | "Defend" | "Intercept".
        /// stateBasedRandom tohumuna girer, bu yuzden saldiri/savunma/onleme akislari ayrisir.
        var combatAction: String? = nil
        /// Unciv GameContext.theirCombatant when it is a CityCombatant: the city on the other side of the fight.
        /// Without it a unit defending against a city's bombard had no opponent at all - "vs [filter]" read nothing
        /// and the context hash put 0 where Unciv puts the city's name and tile.
        var opponentCity: City? = nil

        /// Unciv `theirCombatant != null`: the context was built from two combatants.
        var hasTheirCombatant: Bool { opponentUnit != nil || opponentCity != nil || opponentIsCity }
        /// Unciv `ourCombatant != null`: only the combatant constructor sets it, and every fight context says
        /// who acts (`combatAction`) or has another side.
        var isCombat: Bool { attacking != nil || combatAction != nil || hasTheirCombatant }
        /// Unciv `combatAction`: set explicitly, or read off `attacking` for the older call sites.
        var resolvedCombatAction: String? { combatAction ?? attacking.map { $0 ? "Attack" : "Defend" } }
        /// Unciv `theirCombatant.getCivInfo()`.
        var theirCombatantCivId: Int? {
            if let o = opponentUnit { return o.civId }
            if let c = opponentCity { return c.civId }
            return opponentIsCity ? opponentCivId : nil
        }
    }

    /// Unciv `gameInfo.turns`. Our `turn` runs one ahead of it except while the barbarians act (see `barbarianPhase`).
    var uncivTurns: Int { turn - (barbarianPhase ? 0 : 1) }
}
