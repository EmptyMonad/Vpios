// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/battle/CityCombatant.kt`: a city as a participant in a fight.
extension GameState {
    /// Unciv CityCombatant.getCityStrength(theirCombatant, combatAction), with Unciv's number types: the running
    /// total is a Double, the share of techs known a Float, the garrison's health a Float and the buildings' sum a
    /// Float scaled by each "[]% City Strength from defensive buildings" in turn; the result is `roundToInt()`.
    func getCityStrength(_ city: City, their: Combatant? = nil, action: String = "Defend") -> Int {
        let k = rs.constants
        var strength = k.cityStrengthBase
        strength += Double(city.population) * k.cityStrengthPerPop   // Each 5 pop gives 2 defence
        if let t = map[city.coord] {
            // Unciv cityTile.allTerrains, GrantsCityStrength with GameContext.EmptyState
            for name in t.terrainNames + (t.naturalWonder.map { [$0] } ?? []) {
                for u in rs.terrains[name]?.uniqueObjects ?? [] where u.pattern == "[] Strength for cities built on this terrain" && u.conditionals.isEmpty { strength += Double(u.int(0)) }
            }
        }
        // as tech progresses so does city strength
        let techCount = rs.techs.count
        let techsPercentKnown: Float = techCount > 0 ? Float(civ(city.civId)?.techs.count ?? 0) / Float(techCount) : 0.5
        strength += pow(Double(techsPercentKnown) * k.cityStrengthFromTechsMultiplier, k.cityStrengthFromTechsExponent) * k.cityStrengthFromTechsFullMultiplier
        // Garrisoned unit gives up to 20% of strength to city, health-dependant
        if let garrison = militaryUnitOn(city.coord) {
            strength += Double(Float(garrison.def.strength) * (Float(garrison.health) / 100)) * k.cityStrengthFromGarrison
        }
        // Unciv City.getStrength: the built buildings' cityStrength summed, as a Float
        var buildingsStrength = Float(city.builtBuildingObjects.reduce(0.0) { $0 + (rs.buildings[$1]?.cityStrength ?? 0) })
        let ctx = combatContext(.city(city.id), their, attackedTile: nil, action: action)
        for u in civUniques(city.civId) where u.pattern == "[]% City Strength from defensive buildings" && conditionalsHold(u, ctx) {
            buildingsStrength *= Float(Stats.toPercent(u.double(0)))
        }
        strength += Double(buildingsStrength)
        var extraStrength = 0
        for u in cityUniques(city) where u.pattern == "[] Strength" && conditionalsHold(u, ctx) { extraStrength += u.int(0) }   // Unciv StrengthAmount
        strength += Double(extraStrength)
        return Stats.roundToInt(strength)
    }

    /// Unciv CityCombatant.getAttackingStrength: three quarters of the city's strength, rounded
    func cityAttackingStrength(_ city: City, defender: Combatant?) -> Int {
        Stats.roundToInt(Double(getCityStrength(city, their: defender, action: "Attack")) * 0.75)
    }

    /// Unciv CityCombatant.getDefendingStrength: a defeated city (1 HP) defends with 1
    func cityDefendingStrengthBase(_ city: City, attacker: Combatant?) -> Int {
        if city.health == 1 { return 1 }
        return getCityStrength(city, their: attacker)
    }

    /// The city's strength as the UI and the diplomacy AI read it: CityCombatant(city).getDefendingStrength() /
    /// getCityStrength(combatAction = Attack) with no opponent.
    func cityStrength(_ city: City, attacking: Bool = false) -> Double {
        if !attacking && city.health <= 1 { return 1 }
        return Double(getCityStrength(city, action: attacking ? "Attack" : "Defend"))
    }
}
