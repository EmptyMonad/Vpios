// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/city/managers/CityEspionageManager.kt`: what a spy can reach inside one city.
extension GameState {
    /// Reduction of enemy spy effectiveness in a city from its buildings (Watch House etc.).
    func spyDefence(_ city: City) -> Double {
        var pct = 0.0
        for u in cityUniques(city) where u.pattern == "[]% enemy spy effectiveness []" && scopeIncludes(u, city: city) { pct += u.double(0) }
        return max(-0.99, pct / 100)
    }

    func counterSpy(in city: City) -> Spy? { civ(city.civId)?.spies.first { $0.cityId == city.id && $0.action != "Dead" } }

    /// Unciv EspionageManager.getTechsToSteal
    func techsStealable(by civId: Int, from other: Int) -> [String] {
        guard let a = civ(civId), let b = civ(other) else { return [] }
        // Unciv EspionageManager.getTechsToSteal walks `otherCiv.tech.techsResearched`, a HashSet<String>: bucket
        // order, and within a bucket the order the techs went in - which orderedTechs keeps (techUniqueOrder, re-bucketed
        // on every load and Next Turn clone by reapplyJavaHashSetOrders, this turn's techs appended), so the stable
        // bucket sort gives the set's walk. Ours put each bucket in (column, row) order, and Spy.stealTech's
        // `randomOrNull(Random(randomSeed))` then picked by index from a different list.
        let canResearch = Set(researchableTechs(for: a).map { $0.name })
        let theirs = b.orderedTechs
        return javaHashMapOrder(theirs).filter { !a.techs.contains($0) && canResearch.contains($0) }
    }

    /// Unciv Spy.canStealTech
    func canStealTech(civId: Int, city: City) -> CanStealTech {
        if techsStealable(by: civId, from: city.civId).isEmpty { return .noTechsToSteal }
        if currentCityStats(city.id).total.science <= 0 { return .noScienceInCity }
        return .yes
    }
}
