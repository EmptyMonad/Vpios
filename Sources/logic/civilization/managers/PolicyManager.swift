// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/managers/PolicyManager.kt`: adopting social policies and paying for them.
extension GameState {
    /// Unciv PolicyManager.getCultureNeededForNextPolicy: getPolicyCultureCost(numberOfAdoptedPolicies)
    func policyCost(_ civ: Civilization) -> Double { policyCost(civ, adoptedPolicies: civ.paidPolicyCount) }

    /// Unciv PolicyManager.getPolicyCultureCost(numberOfAdoptedPolicies)
    /// Kotlin types, as there: `policyCultureCost` is a Double (`25 + (n * 3).toDouble().pow(2.01)`), the
    /// per-city `cityModifier` is a FLOAT (the map size's Float modifier times an Int, then `*= 1 - p / 100`
    /// in Float), and every multiplier - `toPercent()`, the difficulty's policyCostModifier, the speed's
    /// cultureCostModifier - is a Float widened into the Double. Ours did it all in Double, so 0.1 was not
    /// Unciv's 0.1f and the rounded cost could land on the other side of a multiple of five.
    func policyCost(_ civ: Civilization, adoptedPolicies: Int) -> Double {
        var policyCultureCost = 25 + pow(Double(adoptedPolicies * 3), 2.01)
        var cityModifier = Float(mapSizePreset.policyCostPerCityModifier) * Float(cities(of: civ.id).filter { !$0.isPuppet }.count - 1)
        let ctx = UniqueContext(civId: civ.id)
        for u in civUniques(civ.id) where u.pattern == "Each city founded increases culture cost of policies []% less than normal" && conditionalsHold(u, ctx) { cityModifier *= 1 - Float(u.double(0)) / 100 }
        for u in civUniques(civ.id) where u.pattern == "[]% Culture cost of adopting new Policies" && conditionalsHold(u, ctx) { policyCultureCost *= Double(1 + Float(u.double(0)) / 100) }
        if civ.isPlayer { policyCultureCost *= Double(Float(difficulty(for: civ.id).policyCostModifier)) }
        policyCultureCost *= Double(Float(speed.cultureCostModifier))
        let cost = Stats.roundToInt(policyCultureCost * Double(1 + cityModifier))   // Kotlin Double.roundToInt()
        return Double(cost - cost % 5)
    }

    /// Unciv PolicyManager.endTurn(culture): addCulture, then addCurrentCultureToCultureOfLast8Turns.
    func policyEndTurn(civId: Int, culture: Int) {
        guard let ci = civIndex(civId) else { return }
        addCulture(ci, Double(culture))
        // Unciv `cultureOfLast8Turns[gameInfo.turns % 8]`; our `turn` is Unciv's `turns + 1`, so `turn % 8`
        // wrote one slot ahead of Unciv's and a loaded save's ring was overwritten in the wrong place.
        if civs[ci].cultureOfLast8Turns.count != 8 { civs[ci].cultureOfLast8Turns = Array(repeating: 0, count: 8) }
        civs[ci].cultureOfLast8Turns[(turn - 1) % 8] = culture
    }

    /// Unciv PolicyManager.getCultureFromGreatWriter: `(cultureOfLast8Turns.sum() * speed.cultureCostModifier).toInt()`,
    /// an Int times a Float.
    func cultureFromGreatWriter(_ civ: Civilization) -> Int {
        Int(Float(civ.cultureOfLast8Turns.reduce(0, +)) * Float(speed.cultureCostModifier))
    }

    func canAdopt(_ civ: Civilization, policy: PolicyDef) -> Bool {
        guard !civ.policies.contains(policy.name), let branchName = rs.policyBranchOf[policy.name], let branch = rs.policyBranches.first(where: { $0.name == branchName }) else { return false }
        guard civ.openBranches.contains(branchName) else { return false }
        if policy.isBranchCompletion { return false }
        if !policy.requires.allSatisfy({ civ.policies.contains($0) }) { return false }
        _ = branch
        // Unciv PolicyManager.isAdoptable: "Only available" conditionals and "Unavailable"
        let ctx = UniqueContext(civId: civ.id)
        if policy.uniqueObjects.contains(where: { $0.pattern == "Only available" && !conditionalsHold($0, ctx) }) { return false }
        if policy.uniqueObjects.contains(where: { $0.pattern == "Unavailable" && conditionalsHold($0, ctx) }) { return false }
        return true
    }

    func canOpenBranch(_ civ: Civilization, _ branch: PolicyBranch) -> Bool {
        guard !civ.openBranches.contains(branch.name) else { return false }
        // Unciv PolicyManager.isAdoptable(checkEra): `eras[branch.era].eraNumber > civInfo.getEraNumber()`, where a civ
        // with no researched tech still has TechManager's blank Era() (eraNumber -1: updateEra returns at once while
        // researchedTechnologies is empty) - so a major popping a culture ruin while its starting units are placed,
        // before addCivTechs, cannot adopt anything and the culture does not raise shouldOpenPolicyPicker
        let known = civ.isBarbarian ? Set(civ.transientTechs) : civ.techs
        if (known.isEmpty ? -1 : rs.eraIndex(civ.eraName)) < rs.eraIndex(branch.era) { return false }
        // "Only available <before adopting [X]>" exclusive branches
        let ctx = UniqueContext(civId: civ.id)
        for u in branch.uniqueObjects where u.pattern == "Only available" { if !conditionalsHold(u, ctx) { return false } }
        if branch.uniqueObjects.contains(where: { $0.pattern == "Unavailable" && conditionalsHold($0, ctx) }) { return false }
        return true
    }

    func canAffordPolicy(_ civ: Civilization) -> Bool {
        if epochsTradeDbg && civ.isMajor {
            let bon = cityStateBonusUniques(for: civ.id).map { $0.text }.joined(separator: ";")
            let csRel = cityStates.map { cs in "\(cs.nation)=\(Int(influence(of: civ.id, with: cs.id)))/\(relationshipLevel(civ.id, cs.id))/\(cs.cityStateType ?? "-")" }.joined(separator: " ")
            print("POLE t=\(turn) \(civ.nation) stored=\(civ.cultureStored) cost=\(policyCost(civ)) paid=\(civ.paidPolicyCount) free=\(civ.freePolicies) csBonus=[\(bon)] cs=[\(csRel)]")
        }
        return civ.freePolicies > 0 || civ.cultureStored >= policyCost(civ)
    }

    /// Unciv PolicyManager.canAdoptPolicy: not a spectator, affordable, and not allPoliciesAdopted(checkEra = true)
    func canAdoptPolicyNow(_ civ: Civilization) -> Bool {
        !civ.isSpectator && canAffordPolicy(civ) && (rs.policyBranches.contains { canOpenBranch(civ, $0) } || rs.policies.values.contains { canAdopt(civ, policy: $0) })
    }

    /// Unciv PolicyManager.addCulture: the policy picker should open once culture makes a policy adoptable
    func addCulture(_ ci: Int, _ amount: Double) {
        let couldAdoptPolicyBefore = canAdoptPolicyNow(civs[ci])
        civs[ci].cultureStored += amount
        if !couldAdoptPolicyBefore && canAdoptPolicyNow(civs[ci]) { civs[ci].shouldOpenPolicyPicker = true }
    }

    /// Spend culture (or a free policy) to open a branch or adopt a policy.
    @discardableResult
    /// `branchCompletion` is Unciv's own parameter: the branch's free completion policy is adopted by
    /// calling this function again, so the completion runs the WHOLE body - its triggers, its
    /// `updateCivResources`, and its own pass over every city - before the policy that finished the branch
    /// fires its uniques. Ours did the completion inline, which is one pass over the cities instead of two.
    /// `ignoringRequirements`: Unciv's adopt itself checks nothing but the price - the developer console's `civ addpolicy`
    /// calls it straight; the picker only offers what PolicyManager.isAdoptable allows.
    func adopt(civId: Int, branch: String? = nil, policy: String? = nil, branchCompletion: Bool = false, ignoringRequirements: Bool = false) -> Bool {
        // Unciv PolicyManager.adopt ends in `for (city in civInfo.cities) city.cityStats.update()` - AFTER the
        // policy is in the list and its uniques have fired. Registered first so it runs last.
        // Unciv: `for (city in civInfo.cities) { city.cityStats.update(); city.reassignPopulationDeferred() }`
        // with update's DEFAULT updateCivStats = true - its own comment says "This ALSO has the side-effect of
        // updating the CivInfo statForNextTurn so we don't need to call it explicitly". So the empire's stats,
        // and with them the happiness field, are rewritten after EVERY city, not once when the loop is done.
        // Only an adoption that happens runs it: Unciv throws before touching anything when the policy cannot be
        // paid for, and ours used to refresh every city's stats on the refusals too - which is not harmless when
        // the stats are a stored value that other code reads stale on purpose.
        var adopted = false
        defer {
            if adopted {
                for c in cities(of: civId) { updateCityStats(c.id, reason: "PolicyManager:5258"); reassignPopulationDeferred(cityIndex(c.id) ?? 0) }
                if let j = civIndex(civId), !canAdoptPolicyNow(civs[j]) { civs[j].shouldOpenPolicyPicker = false }   // Unciv PolicyManager.adopt: after the city pass
            }
        }
        guard let i = civIndex(civId) else { return false }
        let civ = civs[i]
        guard branchCompletion || canAffordPolicy(civ) else { return false }   // Unciv pays only when !branchCompletion, so the completion cannot be priced out
        if let b = branch, let def = rs.policyBranches.first(where: { $0.name == b }) {
            guard ignoringRequirements || canOpenBranch(civ, def) else { return false }
            adopted = true
            civs[i].openBranches.insert(b)
            // Opening a branch counts as a policy and also carries the branch's own uniques (already applied via openBranches).
            payForPolicy(i)
            civs[i].policies.insert(b)          // marks "adopted branch" for counting/prereqs
            if GameState.evlogOn { ev(civId, "POLICY", EvLog.name(b)) }   // EVLOG: Unciv adoptedPolicies.add(branch)
            triggerUniques(def.uniqueObjects, civId: civId, cityId: nil, triggerText: "due to adopting [\(b)]", sourcePolicy: b)
            triggerConditionalUniques(civId: civId, triggerText: "due to adopting [\(b)]") { $0.pattern == "upon adopting []" && $0.param(0) == b }
            updateCivResources(civId)   // Unciv PolicyManager.kt:279 - a PolicyBranch IS a Policy there, so opening one runs this too
            return true
        }
        if let p = policy, let def = rs.policies[p] {
            guard branchCompletion || ignoringRequirements || canAdopt(civ, policy: def) else { return false }
            adopted = true
            if !branchCompletion { payForPolicy(i) }
            civs[i].policies.insert(p)
            if GameState.evlogOn { ev(civId, "POLICY", EvLog.name(p)) }   // EVLOG: Unciv adoptedPolicies.add(policy)
            // Unciv PolicyManager.adopt: `adopt(branch.policies.last(), true)` - a real call, not an inline
            // block, so the completion's own updateCivResources and city pass happen here and the outer
            // policy's happen again below.
            if !branchCompletion, let bn = rs.policyBranchOf[p], let b = rs.policyBranches.first(where: { $0.name == bn }), let done = b.completion,
               b.regularPolicies.allSatisfy({ civs[i].policies.contains($0.name) }), !civs[i].policies.contains(done.name) {
                adopt(civId: civId, policy: done.name, branchCompletion: true)
            }
            triggerUniques(def.uniqueObjects, civId: civId, cityId: nil, triggerText: "due to adopting [\(p)]", sourcePolicy: p)
            triggerConditionalUniques(civId: civId, triggerText: "due to adopting [\(p)]") { $0.pattern == "upon adopting []" && $0.param(0) == p }   // Unciv PolicyManager.adopt
            vpInstantYield(.policy, civId: civId, cityId: nil)   // VP
            updateCivResources(civId)   // Unciv PolicyManager.kt:279 - AFTER both trigger passes, not before them
            return true
        }
        return false
    }

    private func payForPolicy(_ i: Int) {
        // Unciv PolicyManager.adopt: numberOfAdoptedPolicies only grows when the policy is paid for with culture
        let paid = civs[i].paidPolicyCount
        civs[i].numberOfAdoptedPolicies = paid
        if civs[i].freePolicies > 0 { civs[i].freePolicies -= 1 } else if !settings.godMode { civs[i].cultureStored -= policyCost(civs[i]); civs[i].numberOfAdoptedPolicies = paid + 1 }
        invalidateHappiness(civs[i].id)
    }

    // MARK: great people
}
