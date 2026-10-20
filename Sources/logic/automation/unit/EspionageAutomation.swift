// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's unit/EspionageAutomation.kt.

extension GameState {
    /// Unciv EspionageAutomation.automateSpies
    func automateSpies(_ civId: Int) {
        guard let civ = civ(civId) else { return }
        let civsToStealFrom = knownCivs(civId).filter { o in o.isMajor && cities(of: o.id).contains { c in civ.explored.contains(c.coord) && !civ.spies.contains { $0.cityId == c.id && $0.alive } } && !techsStealable(by: civId, from: o.id).isEmpty }
            // Unciv `civsToStealFrom.sortedBy { spyList.count { ... } }` - stable, and the count is 0 for
            // every candidate until spies are actually placed, so this sort is one long tie and the order
            // the known civs came in is the whole answer.
            .enumerated().sorted { a, b in
                let x = civ.spies.filter { s in spyIsDoingWork(s, civId: civId) && s.cityId.flatMap { self.city($0) }?.civId == a.element.id }.count
                let y = civ.spies.filter { s in spyIsDoingWork(s, civId: civId) && s.cityId.flatMap { self.city($0) }?.civId == b.element.id }.count
                return (x, a.offset) < (y, b.offset)
            }.map { $0.element }
        // Unciv `civInfo.getKnownCivs().filter { isMinorCiv() && knows(civInfo) && !atWar }` - known-civ order, which
        // `rigElection`'s maxByOrNull falls back on for equal influence
        let cityStatesToRig = knownCivs(civId).filter { $0.isCityState && $0.metCivs.contains(civId) && !areAtWar(civId, $0.id) }
        let allSpies = civ.spies
        for (idx, original) in allSpies.enumerated() where original.alive && !spyIsDoingWork(original, civId: civId) {
            guard self.civ(civId)?.spies.contains(where: { $0.id == original.id }) == true else { continue }
            // The spy as it stands NOW: an earlier step may have moved it (Unciv holds the one Spy object).
            func spyNow() -> Spy? { self.civ(civId)?.spies.first(where: { $0.id == original.id }) }
            let live = self.civ(civId)?.spies ?? []
            // Unciv `Random(spies.size + spies.indexOf(spy) + civInfo.gameInfo.turns).nextInt(10)` - Kotlin's Random(Int)
            var rng = SeededRandom(kotlinSeed: Int32(truncatingIfNeeded: allSpies.count + idx + uncivTurns))
            let roll = Int(rng.nextInt(until: 10))
            if let cap = capital(of: civId), !live.contains(where: { $0.cityId == cap.id }) { assignSpy(civId: civId, spyId: original.id, to: cap.id); continue }
            // Unciv automateSpyStealTech / automateSpyRigElection call `spy.moveTo(cityToMoveTo)` whether or not a
            // city was found: none sends the spy to the hideout (action None) before the next option is tried.
            func stealTech() -> Bool {
                guard let target = civsToStealFrom.first else { return false }
                guard let spy = spyNow() else { return false }
                let c = cities(of: target.id).filter({ spyCanMoveTo(spy, $0, civId: civId) }).max(by: { $0.population < $1.population })
                assignSpy(civId: civId, spyId: spy.id, to: c?.id); return c != nil
            }
            func rigElection() -> Bool {
                guard let spy = spyNow() else { return false }
                let c = cityStatesToRig.flatMap({ cities(of: $0.id) }).filter({ !$0.razing && spyCanMoveTo(spy, $0, civId: civId) && ((self.civ($0.civId)?.influence[civId] ?? 0) < 150 || ally(of: $0.civId) != civId) })
                    .max(by: { (self.civ($0.civId)?.influence[civId] ?? 0) < (self.civ($1.civId)?.influence[civId] ?? 0) })
                assignSpy(civId: civId, spyId: spy.id, to: c?.id); return c != nil
            }
            func counterIntelligence() -> Bool {
                guard let spy = spyNow(), let c = cities(of: civId).filter({ spyCanMoveTo(spy, $0, civId: civId) }).max(by: { currentCityStats($0.id).total.science < currentCityStats($1.id).total.science }) else { return false }
                assignSpy(civId: civId, spyId: spy.id, to: c.id); return true
            }
            if roll <= 7 && stealTech() { continue }
            if roll <= 9 && rigElection() { continue }
            if counterIntelligence() { continue }
            if let now = spyNow(), spyIsDoingWork(now, civId: civId) { continue }
            if stealTech() { continue }
            if rigElection() { continue }
            // Nothing to do: the highest-science city we may move to, or the hideout. Unciv `gameInfo.getCities()` - civ by civ.
            guard let spy = spyNow() else { continue }
            let c = civs.flatMap({ cities(of: $0.id) }).filter({ spyCanMoveTo(spy, $0, civId: civId) }).max(by: { currentCityStats($0.id).total.science < currentCityStats($1.id).total.science })
            assignSpy(civId: civId, spyId: spy.id, to: c?.id)
        }
        let spiesNow = self.civ(civId)?.spies ?? []
        for (idx, spy) in spiesNow.enumerated() where spy.alive { checkIfShouldStageCoup(civId, spy, index: idx, spyCount: spiesNow.count) }
    }
    func checkIfShouldStageCoup(_ civId: Int, _ spy: Spy, index: Int, spyCount: Int) {
        // Unciv EspionageAutomation: judged without the defending spy, which the AI has no way of seeing
        guard let chance = coupChance(civId: civId, spy: spy, includeUnknownFactors: false), chance >= 0.7, let cid = spy.cityId, let city = city(cid) else { return }
        if let a = ally(of: city.civId), relationshipLevel(civId, a) >= .friend { return }
        // Unciv `Random(spies.size + spies.indexOf(spy) + civInfo.gameInfo.turns).nextInt(100) < 20`
        var rng = SeededRandom(kotlinSeed: Int32(truncatingIfNeeded: spyCount + index + uncivTurns))
        if rng.nextInt(until: 100) < 20 { attemptCoup(civId: civId, spyId: spy.id) }
    }
}
