// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `models/ruleset/unique/UniqueMap.kt` and the unique-gathering functions that read it
/// (Civilization.getMatchingUniques / forEachTriggeredUnique, City.getMatchingUniques, MapUnit.getMatchingUniques).
///
/// Our pools are flat lists that consumers filter by `pattern` (Unciv's placeholderText). Filtering keeps the list
/// order, so a pool built in Unciv's source order hands every consumer the uniques of one type in the order Unciv's
/// `typedUniqueMap[type]` list holds them.
extension GameState {
    /// Unciv `UniqueMap.getAllUniques()`: `tagUniqueMap.values.flatten()` - the uniques grouped by placeholder text,
    /// the groups in the walk order of a Java `HashMap<String, _>` (keys inserted in first-appearance order), each
    /// group in insertion order.
    func uniqueMapAllUniques(_ uniques: [Unique]) -> [Unique] {
        guard uniques.count > 1 else { return uniques }
        var keys: [String] = []
        var groups: [String: [Unique]] = [:]
        for u in uniques {
            if groups[u.pattern] == nil { keys.append(u.pattern) }
            groups[u.pattern, default: []].append(u)
        }
        return javaHashMapOrder(keys).flatMap { groups[$0] ?? [] }
    }

    /// Unciv PolicyManager.policyUniques: every adopted Policy - and a PolicyBranch IS a Policy there - adds its
    /// uniques in adoption order.
    func policyUniquesInOrder(_ civ: Civilization) -> [Unique] {
        var out: [Unique] = []
        // A branch opened without being recorded as adopted (a starting policy's branch) still carries its uniques.
        for b in rs.policyBranches where civ.openBranches.contains(b.name) && !civ.policies.contains(b.name) { out += b.uniqueObjects.from(.policy, b.name) }
        for name in civ.orderedPolicies {
            if let p = rs.policies[name] { out += p.uniqueObjects.from(.policy, name) }
            else if civ.openBranches.contains(name), let b = rs.policyBranches.first(where: { $0.name == name }) { out += b.uniqueObjects.from(.policy, name) }
        }
        return out
    }

    /// Unciv TechManager.techUniques: researched techs' uniques in research order.
    func techUniquesInOrder(_ civ: Civilization) -> [Unique] {
        civ.transientTechs.flatMap { t in (rs.techs[t]?.uniqueObjects ?? []).from(.tech, t) }
    }

    /// Unciv City.getMatchingUniquesWithNonLocalEffects source: `cityConstructions.builtBuildingUniqueMap`, filled by
    /// `updateUniques` from the built buildings in the order they were built.
    func builtBuildingUniques(_ city: City) -> [Unique] {
        city.builtBuildingObjects.flatMap { b -> [Unique] in   // getBuiltBuildings(), a second copy included
            guard let def = rs.buildings[b] else { return [] }
            return def.uniqueObjects.from(def.isAnyWonder ? .wonder : .building, b)
        }
    }

    /// Unciv Civilization.forEachTriggeredUnique: nation, (every city's built buildings - ALL their uniques), the
    /// religion's founder beliefs, policies, techs, era and global uniques - each source walked as a UniqueMap
    /// (`getAllUniques`). No temporary uniques, no city-state bonuses, no resource uniques.
    func civTriggerPool(_ civId: Int, includeCities: Bool) -> [Unique] {
        guard let civ = civ(civId) else { return [] }
        var out: [Unique] = []
        if let nation = civ.nationDef { out += uniqueMapAllUniques(nation.uniqueObjects.from(.nation, nation.name)) }
        if includeCities { for city in cities(of: civId) { out += uniqueMapAllUniques(builtBuildingUniques(city)) } }
        out += uniqueMapAllUniques(founderUniques(for: civId))
        out += uniqueMapAllUniques(policyUniquesInOrder(civ))
        out += uniqueMapAllUniques(techUniquesInOrder(civ))
        out += uniqueMapAllUniques((rs.era(named: civ.eraName)?.uniques ?? []).map { Unique($0).from(.era, civ.eraName) })
        out += uniqueMapAllUniques(rs.globalUniques.from(.globalUniques, "Global Uniques"))
        return out
    }

    /// Civ uniques without the city-state contributions (used while computing those contributions), in
    /// Civilization.getMatchingUniques order.
    func civUniquesWithoutCityStates(_ civId: Int) -> [Unique] {
        guard let civ = civ(civId) else { return [] }
        var out: [Unique] = []
        if let nation = civ.nationDef { out += nation.uniqueObjects.from(.nation, nation.name) }
        out += policyUniquesInOrder(civ)
        out += rs.globalUniques.from(.globalUniques, "Global Uniques")
        return out
    }

    /// Builds the empire-wide unique pool that `civUniques` memoises, in the order Unciv's
    /// Civilization.getMatchingUniques yields: nation, each city's non-local building uniques (the civ's cities in
    /// order), policies, techs, temporary uniques, era, city-state bonuses, founder beliefs, (resource uniques - see
    /// `heldResourceUniques`), global uniques.
    func computeCivUniques(_ civId: Int) -> [Unique] {
        guard let civ = civ(civId) else { return [] }
        var out: [Unique] = []
        if let nation = civ.nationDef { out += nation.uniqueObjects.from(.nation, nation.name) }
        for city in cities(of: civId) {
            // Buildings only broadcast uniques that are not scoped to their own city.
            out += builtBuildingUniques(city).filter { !$0.isLocalEffect }
        }
        out += policyUniquesInOrder(civ)
        out += techUniquesInOrder(civ)
        out += civ.temporaryUniques.map { $0.uniqueObject }
        out += (rs.era(named: civ.eraName)?.uniques ?? []).map { Unique($0).from(.era, civ.eraName) }
        if !civ.isCityState { out += cityStateBonusUniques(for: civId) }   // Unciv getUniquesProvidedByCityStates
        out += founderUniques(for: civId)
        out += rs.globalUniques.from(.globalUniques, "Global Uniques")
        // Unciv UniqueMap drops a unique carrying "<for [n] turns>" from every static lookup: it is not a standing
        // unique at all but a triggerable, fired on adoption and stored as a temporary copy with the timing
        // stripped. Reading it here applied Autocracy Complete's +25% for ever, and doubled it for the first 50
        // turns, on top of the temporary copy that was already doing the job.
        return multiplied(out.filter { $0.timedTurns == nil }, UniqueContext(civId: civId))
    }

    func multiplied(_ uniques: [Unique], _ ctx: UniqueContext) -> [Unique] {
        let metas: Set<String> = ["for every []", "for every [] []", "for every adjacent []"]
        guard !expandingMultipliers, uniques.contains(where: { u in u.conditionals.contains { metas.contains($0.pattern) } }) else { return uniques }
        expandingMultipliers = true
        defer { expandingMultipliers = false }
        var out: [Unique] = []
        for u in uniques {
            // Unciv Unique.getUniqueMultiplier: the countable multipliers first, then - only with a relevant tile -
            // the adjacent-tile ones; an invalid countable counts as 0, and the result is at least 0. `amount` is a
            // Kotlin Int: the products wrap at 32 bits (two countables held at Int.MAX_VALUE make 1), where a 64-bit
            // product of three of them overflowed and stopped the app.
            var amount: Int32 = 1
            for c in u.conditionals where c.pattern == "for every []" { amount = amount &* Int32(truncatingIfNeeded: countable(c.param(0), ctx) ?? 0) }
            for c in u.conditionals where c.pattern == "for every [] []" {
                // (Unciv's Int `multiplier / perEvery` throws ArithmeticException on 0; Int.MIN_VALUE / -1 is itself)
                let per = Int32(truncatingIfNeeded: c.int(0)), multiplier = Int32(truncatingIfNeeded: countable(c.param(1), ctx) ?? 0)
                amount = per == 0 ? 0 : amount &* multiplier.dividedReportingOverflow(by: per).partialValue
            }
            if let t = relevantTile(ctx) {
                for c in u.conditionals where c.pattern == "for every adjacent []" {
                    amount = amount &* Int32(truncatingIfNeeded: map.neighbors(of: t.coord).filter { map[$0].map { tileMatches($0, c.param(0), civId: ctx.civId) } ?? false }.count)
                }
            }
            if amount > 0 { out += Array(repeating: u, count: min(Int(amount), 1000)) }
        }
        return out
    }

    /// Unciv Unique.getGameProgressModifier: "(modified by game progress up to [x]%)" scales with max(tech share, policy share).
    func gameProgressModifier(_ u: Unique, civId: Int) -> Double {
        let mods = u.conditionals.filter { $0.pattern == "(modified by game progress up to []%)" }
        guard !mods.isEmpty, let civ = civ(civId) else { return 1 }
        let tech = rs.techs.isEmpty ? Float(0) : Float(researchedTechnologiesSize(civ)) / Float(rs.techs.count)   // Unciv researchedTechnologies.size
        // Unciv ruleset.policies holds the branches too (a PolicyBranch is a Policy); ours keeps them apart.
        let rulesetPolicies = rs.policies.count + rs.policyBranches.count
        let policy = rulesetPolicies == 0 ? Float(0) : Float(civ.policies.count) / Float(rulesetPolicies)
        let progress = max(tech, policy)
        var modifier: Float = 1
        for m in mods { modifier *= 1 + (Float(m.double(0)) / 100 - 1) * progress }
        return Double(modifier)
    }

    /// Unciv City.getMatchingUniques / City.forEachMatchingUnique: `civ.getMatchingUniques` FIRST, then
    /// getLocalMatchingUniques (the buildings' local uniques, then the religion's). `cityUniques` below is the other
    /// order, LocalUniqueCache.forCityGetMatchingUniques (local first). The order matters where the uniques are
    /// multiplied in Float one after the other; there the reader must use the pool its Unciv caller uses.
    func cityUniquesCivFirst(_ city: City) -> [Unique] {
        civUniques(city.civId).filter { !$0.isLocalEffect } + cityLocalUniques(city)
    }

    /// Uniques that act inside a city: its own buildings plus the empire-wide ones whose scope includes it.
    func cityUniques(_ city: City) -> [Unique] {
        var out: [Unique] = []
        // Unciv Unique.isLocalEffect: only the `in this city` uniques are local; the rest arrive through civUniques below.
        out += builtBuildingUniques(city).filter { $0.isLocalEffect }
        out += religionUniques(for: city)
        out = multiplied(out, UniqueContext(civId: city.civId, city: city))   // civ uniques below are already multiplied
        out += civUniques(city.civId).filter { !$0.isLocalEffect }
        return out
    }

    /// Unciv CivInfoTransientCache.updateCivResources: a resource the civ holds contributes its own uniques.
    /// It cannot live in cityUniques, because counting the resources reads that pool - so the places that need
    /// it ask for it directly. Marble's wonder bonus is the only one the shipped ruleset uses.
    func heldResourceUniques(_ civId: Int) -> [Unique] {
        var out: [Unique] = []
        for (name, amount) in resourceCounts(civId).sorted(by: { $0.key < $1.key }) where amount > 0 {
            out += (rs.resources[name]?.uniqueObjects ?? []).from(.resource, name)
        }
        return out
    }

    /// Does the unique's scope param include this city?
    func scopeIncludes(_ u: Unique, city: City, source: String? = nil) -> Bool { cityMatchesFilter(u.scope, city: city, viewer: city.civId) }
}
