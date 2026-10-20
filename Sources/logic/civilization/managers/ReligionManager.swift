// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

extension GameState {
    var religionEnabled: Bool { settings.religionEnabled && !rs.beliefs.isEmpty && !rs.modOptionUniques.contains(where: { $0.pattern == "Disable religion" }) }   // Unciv GameInfo.isReligionEnabled

    // MARK: costs
    var civsWithPantheon: Int { civs.filter { $0.isMajor && $0.pantheonBelief != nil }.count }

    /// Unciv ReligionManager.faithForPantheon: (pantheonBase + majors with a religion or pantheon × pantheonGrowth) × faith cost modifier
    func pantheonCost(_ civId: Int) -> Double {
        let numCivs = civs.filter { $0.isMajor && ($0.pantheonBelief != nil || $0.religionName != nil) }.count
        return ((Double(rs.constants.pantheonBase) + Double(numCivs) * Double(rs.constants.pantheonGrowth)) * speed.faithCostModifier).rounded()
    }

    func prophetCost(_ civ: Civilization) -> Double {
        // Unciv faithForNextGreatProphet: 200 + 100 × n(n+1)/2, × faith cost modifier.
        let prophet = rs.units.values.first(where: { $0.canFoundReligion }).map { equivalentUnit(civ.id, $0).name } ?? ""
        let n = Double(civ.boughtWithIncreasingPrice[prophet] ?? civ.prophetsEarned)   // legacy saves: prophetsEarned
        var cost = (200 + 100 * n * (n + 1) / 2) * speed.faithCostModifier
        for u in civUniques(civ.id) where u.pattern == "[]% Faith cost of generating Great Prophet equivalents" && conditionalsHold(u, UniqueContext(civId: civ.id)) { cost *= 1 + u.double(0) / 100 }
        return Double(Int(cost))
    }

    /// Unciv ReligionManager.maxNumberOfReligions: min(religion symbols, base + major civs × multiplier)
    var maxReligions: Int { min(rs.religionNames.count, rs.constants.religionLimitBase + Int(Double(civs.filter { $0.isMajor }.count) * rs.constants.religionLimitMultiplier)) }

    var foundedReligions: [String] { civs.compactMap { $0.religionName } }
    /// Unciv ReligionManager.foundedReligionsCount: `religion != null && religionState >= Religion`. A civ still in
    /// FoundingReligion (named, beliefs not yet chosen - our pendingReligion "founding") is not counted; an enhancing
    /// one is. The names in `foundedReligions` stay taken meanwhile, as Unciv's gameInfo.religions holds them.
    var foundedReligionsCount: Int { civs.filter { $0.religionName != nil && $0.pendingReligion != "founding" }.count }

    /// Unciv BeliefType order (None skipped)
    var beliefTypeOrder: [String] { ["Pantheon", "Founder", "Follower", "Enhancer", "Any"] }

    /// Unciv ReligionManager.numberOfBeliefsAvailable: ruleset beliefs of the type minus the distinct ones already held by a pantheon or religion
    func numberOfBeliefsAvailable(_ type: String) -> Int {
        let total = type == "Any" ? rs.beliefs.count : rs.beliefs.values.filter { $0.type == type }.count
        let held = Set(civs.flatMap { ($0.pantheonBelief.map { [$0] } ?? []) + $0.religionBeliefs }).filter { type == "Any" || rs.beliefs[$0]?.type == type }
        return total - held.count
    }

    /// Unciv ReligionManager.canFoundOrExpandPantheon
    func canFoundOrExpandPantheon(_ civ: Civilization) -> Bool {
        guard religionEnabled, civ.religionName == nil, civ.isMajor else { return false }   // religionState <= Pantheon
        if numberOfBeliefsAvailable("Pantheon") == 0 { return false }
        if civs.contains(where: { $0.religionName != nil && $0.religionEnhanced }) && civs.filter({ $0.pantheonBelief != nil || $0.religionName != nil }).count >= maxReligions { return false }
        return (civ.pantheonBelief == nil && civ.faithStored >= pantheonCost(civ.id)) || (civ.freeBeliefsByType["Pantheon"] ?? 0) > 0
    }

    /// Unciv CivView.canFoundPantheon / canExpandPantheon
    func canFoundPantheon(_ civ: Civilization) -> Bool { civ.pantheonBelief == nil && canFoundOrExpandPantheon(civ) }

    func canExpandPantheon(_ civ: Civilization) -> Bool { civ.pantheonBelief != nil && canFoundOrExpandPantheon(civ) }

    /// Unciv ReligionManager.usingFreeBeliefs (for pantheon picks)
    func usingFreeBeliefs(_ civ: Civilization) -> Bool { (civ.pantheonBelief == nil && civ.religionName == nil && civ.faithStored < pantheonCost(civ.id)) || civ.pantheonBelief != nil || civ.religionName != nil }

    /// Unciv ReligionManager.getBeliefsToChooseAtProphetUse
    /// `shouldChoosePantheon` false is the AI's founding: Unciv's ReligionAutomation.foundReligion calls
    /// ReligionManager.foundReligion(name) - which clears shouldChoosePantheonBelief - BEFORE it counts the beliefs,
    /// so an AI founding without a pantheon never gets one (fresh turn 83: France's Christianity has no pantheon
    /// belief there, and Monument to the Gods gave Paris +15% on Circus Maximus here).
    func beliefsToChoose(civId: Int, enhancing: Bool, shouldChoosePantheon: Bool = true) -> [String: Int] {
        guard let civ = civ(civId) else { return [:] }
        let action = enhancing ? "enhancing" : "founding"
        var toChoose: [String: Int] = [:]
        var available: [String: Int] = [:]
        for t in beliefTypeOrder { available[t] = numberOfBeliefsAvailable(t) }
        func chooseBeliefToAdd(_ type: String, _ number: Int) {
            let numberToAdd = min(number, available[type] ?? 0)
            toChoose[type, default: 0] += numberToAdd
            available[type] = (available[type] ?? 0) - numberToAdd
            if type != "Any" { available["Any"] = (available["Any"] ?? 0) - numberToAdd }
        }
        if enhancing { chooseBeliefToAdd("Enhancer", 1) }
        else {
            chooseBeliefToAdd("Founder", 1)
            if civ.pantheonBelief == nil && shouldChoosePantheon { chooseBeliefToAdd("Pantheon", 1) }   // shouldChoosePantheonBelief
        }
        chooseBeliefToAdd("Follower", 1)
        for u in civUniques(civId) where u.pattern == "May choose [] additional [] beliefs when [] a religion" && u.param(2) == action { chooseBeliefToAdd(u.param(1), u.int(0)) }
        for u in civUniques(civId) where u.pattern == "May choose [] additional belief(s) of any type when [] a religion" && u.param(1) == action { chooseBeliefToAdd("Any", u.int(0)) }
        for t in beliefTypeOrder { if let n = civ.freeBeliefsByType[t], n != 0 { chooseBeliefToAdd(t, n) } }
        return toChoose
    }

    /// The chosen beliefs fill the slots of `slots` (typed slots first, then Any) and are not held by anyone yet.
    func beliefsFit(_ beliefs: [String], _ slots: [String: Int], requireAll: Bool) -> Bool {
        guard Set(beliefs).count == beliefs.count else { return false }
        let held = Set(civs.flatMap { ($0.pantheonBelief.map { [$0] } ?? []) + $0.religionBeliefs })
        var remaining = slots.mapValues { max(0, $0) }
        var anyNeeded = 0
        for b in beliefs {
            guard let def = rs.beliefs[b], !held.contains(b) else { return false }
            if (remaining[def.type] ?? 0) > 0 && def.type != "Any" { remaining[def.type]! -= 1 } else { anyNeeded += 1 }
        }
        guard anyNeeded <= (remaining["Any"] ?? 0) else { return false }
        return !requireAll || beliefs.count == slots.values.reduce(0) { $0 + max(0, $1) }
    }

    /// Unciv ReligionManager.chooseBeliefs: TriggerUponAdoptingPolicyOrBelief, then every belief's own triggerable uniques
    private func applyBeliefTriggers(civId: Int, _ beliefs: [String]) {
        for b in beliefs { triggerConditionalUniques(civId: civId, triggerText: "due to adopting [\(b)]") { $0.pattern == "upon adopting []" && $0.param(0) == b } }
        for b in beliefs { if let def = rs.beliefs[b] { triggerUniques(def.uniqueObjects.filter { !$0.conditionals.contains(where: { $0.pattern.hasPrefix("upon ") }) }, civId: civId, cityId: nil, triggerText: nil) } }   // Unciv triggerUnique(unique, civInfo): no city
        updateStatsForNextTurn(civId)   // Unciv ReligionManager.chooseBeliefs: "a belief can have an immediate effect on stats"
    }

    /// Unciv chooseBeliefs(useFreeBeliefs = true) for ReformReligion: spend the free belief counter
    @discardableResult
    func applyFreeBeliefs(civId: Int, beliefs: [String], requireAll: Bool = true) -> Bool {
        guard let i = civIndex(civId), religionEnabled, civs[i].freeBeliefsByType.values.reduce(0, +) > 0, !beliefs.isEmpty,
              beliefsFit(beliefs, civs[i].freeBeliefsByType, requireAll: requireAll) else { return false }
        civs[i].freeBeliefsByType = [:]
        var rest = beliefs
        if civs[i].pantheonBelief == nil && civs[i].religionName == nil, let first = rest.first, rs.beliefs[first]?.type == "Pantheon" {
            civs[i].pantheonBelief = first; rest.removeFirst()   // religionState None → foundPantheon(useFreeBelief = true)
            triggerConditionalUniques(civId: civId) { $0.pattern == "upon founding a Pantheon" }
        }
        civs[i].religionBeliefs += rest
        applyBeliefTriggers(civId: civId, beliefs)
        invalidateHappiness(civId)
        return true
    }

    /// Unciv ReligionManager.mayEnhanceReligionAtAll
    func mayEnhanceReligion(_ civ: Civilization) -> Bool { religionEnabled && civ.religionName != nil && !civ.religionEnhanced && civ.pendingReligion == nil && civ.isMajor && numberOfBeliefsAvailable("Follower") > 0 && numberOfBeliefsAvailable("Enhancer") > 0 }

    /// Unciv ReligionManager.remainingFoundableReligions
    func remainingFoundableReligions() -> Int { min(maxReligions - foundedReligionsCount, min(numberOfBeliefsAvailable("Follower"), numberOfBeliefsAvailable("Founder"))) }

    /// Unciv PantheonPickerScreen.beliefIsAllowed: every "Only available" condition holds and no applicable "Unavailable"
    func beliefIsAllowed(_ civ: Civilization, _ b: BeliefDef) -> Bool {
        let us = b.uniques.map(Unique.init), ctx = UniqueContext(civId: civ.id)
        return !us.contains { $0.pattern == "Only available" && !conditionalsHold($0, ctx) } && !us.contains { $0.pattern == "Unavailable" && conditionalsHold($0, ctx) }
    }

    /// Unciv ReligionManager.getReligionWithBelief: the civ whose pantheon or religion holds the belief
    func beliefOwner(_ name: String) -> Civilization? { civs.first { $0.pantheonBelief == name || $0.religionBeliefs.contains(name) } }

    func availablePantheons() -> [BeliefDef] {
        let taken = Set(civs.compactMap { $0.pantheonBelief } + civs.flatMap { $0.religionBeliefs })
        return rs.beliefs(ofType: "Pantheon").filter { !taken.contains($0.name) }
    }

    func availableBeliefs(ofType t: String) -> [BeliefDef] {
        let taken = Set(civs.flatMap { $0.religionBeliefs } + civs.compactMap { $0.pantheonBelief })
        return rs.beliefs(ofType: t).filter { !taken.contains($0.name) }
    }

    /// Unciv ReligionManager.religionState as ReligionState.toString shows it
    func religionStateText(_ civ: Civilization) -> String {
        if civ.pendingReligion == "founding" { return "Founding religion" }
        if civ.pendingReligion == "enhancing" { return "Enhancing religion" }
        if civ.religionName != nil { return civ.religionEnhanced ? "Enhanced religion" : "Religion" }
        return civ.pantheonBelief != nil ? "Pantheon" : "None"
    }
    /// Unciv ReligionManager.canGenerateProphet(ignoreFaithAmount = true)
    func canGenerateProphetIgnoringFaith(_ civ: Civilization) -> Bool {
        guard religionEnabled, civ.pantheonBelief != nil || civ.religionName != nil || civ.pendingReligion != nil,
              greatProphetEquivalent(civ.id) != nil, civ.isMajor, !eraForbidsProphets(civ.id) else { return false }
        if civ.religionName == nil && civ.pendingReligion == nil && remainingFoundableReligions() == 0 { return false }
        return true
    }
    /// Unciv Civilization.shouldHideCivCount
    func shouldHideCivCount(_ civ: Civilization) -> Bool {
        guard settings.randomNumberOfPlayers else { return false }
        // `1 + getKnownCivs().count { it.isMajorCiv() }`: getKnownCivs drops the defeated (and spectators), so a met
        // major that has since been destroyed no longer counts
        let known = 1 + civs.filter { $0.isMajor && $0.isAlive && $0.id != civ.id && civ.metCivs.contains($0.id) }.count
        if known >= settings.maxNumberOfPlayers { return false }
        if civUniques(civ.id).contains(where: { $0.pattern == "Reveals the entire map" }) { return false }
        return true
    }
    /// Unciv GlobalPoliticsOverviewTable.hideCityStateCount: shouldHideCivCount for the City-States
    func hideCityStateCount(_ civ: Civilization) -> Bool {
        guard settings.randomNumberOfCityStates else { return false }
        // `1 + getKnownCivs().count { it.isCityState }`: the defeated left out, as in shouldHideCivCount
        let known = 1 + civs.filter { $0.isCityState && $0.isAlive && $0.id != civ.id && civ.metCivs.contains($0.id) }.count
        if known >= settings.maxNumberOfCityStates { return false }
        if civUniques(civ.id).contains(where: { $0.pattern == "Reveals the entire map" }) { return false }
        return true
    }

    /// Unciv ReligionManager.mayFoundReligionAtAll
    func canFoundReligion(_ civ: Civilization) -> Bool { religionEnabled && civ.religionName == nil && civ.isMajor && remainingFoundableReligions() > 0 }

    var availableReligionNames: [String] { rs.religionNames.filter { !foundedReligions.contains($0) } }

    /// Unciv AskTextPopup validate: not empty, not "No religion", not already founded.
    func religionNameIsValid(_ name: String) -> Bool { let n = name.trimmingCharacters(in: .whitespaces); return !n.isEmpty && n != noReligionName && !foundedReligions.contains(n) && !civs.contains { $0.religionName == n } }

    func religionOwner(_ name: String) -> Civilization? { civs.first { $0.religionName == name } }

    /// Unciv ReligionManager: Random(gameInfo.turns).nextFloat(), one fixed draw per turn for the whole game.
    func prophetRandom() -> Double {
        // Unciv: `Random(civInfo.gameInfo.turns)` — Random(Int), `init(seed:)`'in 0 -> 42 kestirmesi olmadan
        var g = SeededRandom(kotlinSeed: Int32(truncatingIfNeeded: max(0, turn - 1)))   // Unciv Random(gameInfo.turns), whose counter is zero-based
        return Double(g.nextFloat())
    }

    /// Unciv Religion.getReligionDisplayName
    func religionDisplayName(_ name: String) -> String { civs.first { $0.religionName == name }?.religionDisplayName ?? name }

    /// Unciv ReligiousBeliefsPickerScreen AskTextPopup validate: not No religion, not a ruleset religion, not an existing religion, not empty.
    func religionDisplayNameIsValid(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && n != noReligionName && !rs.religionNames.contains(n) && !civs.contains { $0.religionName == n || $0.pantheonBelief == n }
    }

    // MARK: pantheon & founding
    @discardableResult
    func foundPantheon(civId: Int, belief: String) -> Bool {
        guard let i = civIndex(civId), canFoundOrExpandPantheon(civs[i]), availablePantheons().contains(where: { $0.name == belief }), let bd = rs.beliefs[belief], beliefIsAllowed(civs[i], bd) else { return false }
        // Unciv PantheonPickerScreen → chooseBeliefs([pantheon], useFreeBeliefs = usingFreeBeliefs())
        let useFreeBeliefs = usingFreeBeliefs(civs[i])
        civs[i].freeBeliefsByType = [:]
        guard civs[i].pantheonBelief == nil else {
            civs[i].religionBeliefs.append(belief)   // expanding the pantheon
            applyBeliefTriggers(civId: civId, [belief])
            invalidateHappiness(civId)
            return true
        }
        if !useFreeBeliefs { civs[i].faithStored -= pantheonCost(civId) }
        // Unciv ReligionManager.foundPantheon: the pantheon is a religion of its own with 200 × population pressure in each
        // of our cities, in civInfo.cities order. Each addPressure → updateNumberOfFollowers: adoption, then
        // updateCivResources when the majority changed, then cityStats.update() when the followers changed - all while
        // the new religion holds NO belief yet (chooseBeliefs adds them afterwards), so pantheonBelief is set after the loop.
        // Ours only added the pressure: no city refreshed its stored stats, and the loop walked the global city list.
        for c in cities(of: civId) {
            guard let ci = cityIndex(c.id) else { continue }
            addPressure(cityIndex: ci, belief, 200 * cities[ci].population)
        }
        civs[i].pantheonBelief = belief   // Unciv chooseBeliefs → religion!!.addBeliefs(beliefs)
        // Unciv ReligionManager.foundPantheon: every other human hears "[civ] has founded pantheon [belief]!" (or "[An unknown civilization] …")
        // - `civilizations.filter { it.isHuman() && it != civInfo }`: a defeated human and a spectator too
        for h in civs where h.isPlayer && h.id != civId {
            let who = h.metCivs.contains(civId) ? "[\(civs[i].nation)]" : "[An unknown civilization]"
            notify(h.id, "\(who) has founded pantheon [\(belief)]!", category: .Religion, icons: ["Faith"], actions: [.religion(belief)])
        }
        // Unciv ReligionManager: TriggerUponFoundingPantheon + TriggerUponAdoptingPolicyOrBelief
        triggerConditionalUniques(civId: civId) { $0.pattern == "upon founding a Pantheon" }
        applyBeliefTriggers(civId: civId, [belief])
        invalidateHappiness(civId)
        return true
    }

    /// Prophet in one of our cities founds a religion there (the city becomes holy): the prophet's action and the
    /// choice of name and beliefs at once, as a human picks them.
    @discardableResult
    func foundReligion(unitId: Int, name: String, displayName: String? = nil, beliefs: [String], strict: Bool = true) -> Bool {
        guard let u = unit(unitId), religionNameIsValid(name), displayName.map({ religionDisplayNameIsValid($0) }) ?? true,
              beliefsFit(beliefs, beliefsToChoose(civId: u.civId, enhancing: false), requireAll: strict) else { return false }
        guard useProphetForFoundingReligion(unitId: unitId) else { return false }
        return completeFoundingReligion(civId: u.civId, name: name, displayName: displayName, beliefs: beliefs, strict: strict)
    }

    /// Unciv ReligionManager.foundReligion(prophet) + unit.consume(): the state becomes FoundingReligion in the prophet's
    /// city and the prophet is spent - nothing is founded yet.
    @discardableResult
    func useProphetForFoundingReligion(unitId: Int) -> Bool {
        // Unciv ReligionManager.mayFoundReligionHere: a city centre that is not already a holy city
        guard let ui = unitIndex(unitId), let ci = civIndex(units[ui].civId), let city = city(at: units[ui].coord), !city.isHolyCity else { return false }
        guard units[ui].def.canFoundReligion, units[ui].abilityToTimesUsed.isEmpty, units[ui].movementLeft > 0, canFoundReligion(civs[ci]) else { return false }   // Unciv <if it hasn't used other actions yet>: abilityToTimesUsed.isEmpty()
        civs[ci].pendingReligion = "founding"
        civs[ci].foundingCityId = city.id
        let spentId = units[ui].id
        consumeUnit(spentId)   // Unciv unit.consume(): the "upon expending" triggers, then MapUnit.destroy()
        return true
    }

    /// Unciv ReligionManager.foundReligion(displayName, name) then chooseBeliefs: the religion is founded in the city
    /// the prophet was used in. The human's path: the beliefs were picked on the screen, before the founding.
    @discardableResult
    func completeFoundingReligion(civId: Int, name: String, displayName: String? = nil, beliefs: [String], strict: Bool = true) -> Bool {
        guard let ci = civIndex(civId), civs[ci].pendingReligion == "founding", civs[ci].foundingCityId.flatMap({ cityIndex($0) }) != nil else { return false }
        guard religionNameIsValid(name), displayName.map({ religionDisplayNameIsValid($0) }) ?? true else { return false }
        guard beliefsFit(beliefs, beliefsToChoose(civId: civs[ci].id, enhancing: false), requireAll: strict) else { return false }
        guard foundReligionNamed(civId: civId, name: name, displayName: displayName) else { return false }
        chooseFoundingBeliefs(civId: civId, beliefs: beliefs)
        return true
    }

    /// Unciv ReligionManager.foundReligion(displayName, name): the religion exists (with the pantheon's beliefs only),
    /// the holy city gets its pressure, the religious units switch, the humans hear of it. The state stays
    /// FoundingReligion (our pendingReligion "founding") until chooseBeliefs - the AI rates its beliefs in between
    /// (ReligionAutomation.foundReligion), so it rates them with the holy city already following the new religion.
    @discardableResult
    func foundReligionNamed(civId: Int, name: String, displayName: String? = nil) -> Bool {
        guard let ci = civIndex(civId), civs[ci].pendingReligion == "founding", civs[ci].religionName == nil, let cityIdx = civs[ci].foundingCityId.flatMap({ cityIndex($0) }) else { return false }
        guard religionNameIsValid(name), displayName.map({ religionDisplayNameIsValid($0) }) ?? true else { return false }
        let city = cities[cityIdx]
        civs[ci].religionName = name
        civs[ci].religionDisplayName = displayName.flatMap { $0 == name ? nil : $0.trimmingCharacters(in: .whitespaces) }
        // Unciv foundReligion: newReligion.addBeliefs(religion.getAllBeliefsOrdered()) - only the pantheon's beliefs so far
        var religionBeliefs = civs[ci].religionBeliefs
        if let p = civs[ci].pantheonBelief, !religionBeliefs.contains(p) { religionBeliefs.insert(p, at: 0) }
        civs[ci].religionBeliefs = religionBeliefs
        civs[ci].holyCityId = city.id
        cities[cityIdx].isHolyCity = true
        cities[cityIdx].holyCityOf = name
        // Unciv foundReligion: holyCity.religion.addPressure(name, pop × 500) → updateNumberOfFollowers: adoption,
        // updateCivResources, cityStats.update() - while the religion still holds only the pantheon beliefs, so the
        // holy city never pays a founder belief's "when a city adopts this religion for the first time" (Initiation
        // Rites paid 100 gold here in ours), and the holy city's stored stats are refreshed.
        addPressure(cityIndex: cityIdx, name, cities[cityIdx].population * 500)
        // Unciv: foundingCityId = null; shouldChoosePantheonBelief = false
        civs[ci].foundingCityId = nil
        // Unciv ReligionManager.foundReligion: religious units that take the civ's religion switch to the new one.
        let newReligionOwner = civs[ci].id
        for j in units.indices where units[j].civId == newReligionOwner && units[j].def.isReligious && units[j].def.uniques.contains("Takes your religion over the one in their birth city") { units[j].religion = name }
        invalidateHappiness(civs[ci].id)
        let shownName = civs[ci].religionDisplayName ?? name   // Unciv notifications use the display name
        // Unciv ReligionManager.foundReligion: the other humans (`isHuman() && it != civInfo`, a defeated one and a spectator too)
        // get "[civ] has founded [r] in [city]!" / "… has founded [r]!" / "[An unknown civilization] has founded [r]!"; the
        // founder gets nothing (a human founder is on the religion screen it named the religion on)
        for j in civs.indices where civs[j].isPlayer && civs[j].id != civs[ci].id {
            let known = civs[j].metCivs.contains(civs[ci].id)
            let text = !known ? "[An unknown civilization] has founded [\(shownName)]!" : civs[j].explored.contains(city.coord) ? "[\(civs[ci].nation)] has founded [\(shownName)] in [\(city.name)]!" : "[\(civs[ci].nation)] has founded [\(shownName)]!"
            notify(civs[j].id, text, category: .Religion, icons: ["Faith"], actions: known && civs[j].explored.contains(city.coord) ? [.location(city.coord), .religion(name)] : [.religion(name)])
        }
        return true
    }

    /// Unciv ReligionManager.chooseBeliefs in the FoundingReligion state: freeBeliefs.clear(), religion.addBeliefs,
    /// state → Religion, the "upon founding a Religion" triggers, then the beliefs' own triggers.
    func chooseFoundingBeliefs(civId: Int, beliefs: [String]) {
        guard let ci = civIndex(civId), civs[ci].pendingReligion == "founding", civs[ci].religionName != nil else { return }
        civs[ci].pendingReligion = nil
        // Unciv chooseBeliefs: freeBeliefs.clear(), then religion!!.addBeliefs(beliefs) (updateUniqueMaps at once)
        civs[ci].freeBeliefsByType = [:]
        for b in beliefs { if rs.beliefs[b]?.type == "Pantheon" && civs[ci].pantheonBelief == nil { civs[ci].pantheonBelief = b }; civs[ci].religionBeliefs.append(b) }
        invalidateHappiness(civs[ci].id)   // founder beliefs feed civUniques; Unciv's unique maps update immediately
        let founderId = civs[ci].id, newBeliefs = beliefs
        triggerConditionalUniques(civId: founderId) { $0.pattern == "upon founding a Religion" }
        applyBeliefTriggers(civId: founderId, newBeliefs)
        invalidateHappiness()
    }

    /// The prophet's action and the choice of beliefs at once, as a human picks them.
    @discardableResult
    func enhanceReligion(unitId: Int, beliefs: [String], strict: Bool = true) -> Bool {
        guard let u = unit(unitId), beliefsFit(beliefs, beliefsToChoose(civId: u.civId, enhancing: true), requireAll: strict) else { return false }
        guard useProphetForEnhancingReligion(unitId: unitId) else { return false }
        return completeEnhancingReligion(civId: u.civId, beliefs: beliefs, strict: strict)
    }

    /// Unciv ReligionManager.useProphetForEnhancingReligion + unit.consume(): the state becomes EnhancingReligion, the other
    /// humans hear of it, and the prophet is spent - the beliefs come later.
    @discardableResult
    func useProphetForEnhancingReligion(unitId: Int) -> Bool {
        guard let ui = unitIndex(unitId), let ci = civIndex(units[ui].civId), units[ui].def.canEnhanceReligion, units[ui].abilityToTimesUsed.isEmpty, units[ui].movementLeft > 0, map[units[ui].coord]?.isCityCenter == true else { return false }   // Unciv mayEnhanceReligionHere
        guard mayEnhanceReligion(civs[ci]) else { return false }
        civs[ci].pendingReligion = "enhancing"
        // Unciv useProphetForEnhancingReligion: `isHuman() && it != civInfo`, and the action is ReligionAction(religion.displayName)
        for h in civs where h.isPlayer && h.id != civs[ci].id {
            let who = h.metCivs.contains(civs[ci].id) ? "[\(civs[ci].nation)]" : "[An unknown civilization]"
            let shown = civs[ci].religionDisplayName ?? civs[ci].religionName!
            notify(h.id, "\(who) has enhanced [\(shown)]!", category: .Religion, icons: ["Faith"], actions: [.religion(shown)])
        }
        let spentId = units[ui].id
        consumeUnit(spentId)   // Unciv unit.consume(): the "upon expending" triggers, then MapUnit.destroy()
        return true
    }

    /// Unciv ReligionManager.chooseBeliefs in the EnhancingReligion state
    @discardableResult
    func completeEnhancingReligion(civId: Int, beliefs: [String], strict: Bool = true) -> Bool {
        guard let ci = civIndex(civId), civs[ci].pendingReligion == "enhancing", beliefsFit(beliefs, beliefsToChoose(civId: civId, enhancing: true), requireAll: strict) else { return false }
        civs[ci].pendingReligion = nil
        civs[ci].religionBeliefs += beliefs
        civs[ci].freeBeliefsByType = [:]
        civs[ci].religionEnhanced = true
        let enhancerId = civs[ci].id
        triggerConditionalUniques(civId: enhancerId) { $0.pattern == "upon enhancing a Religion" }
        applyBeliefTriggers(civId: enhancerId, beliefs)
        invalidateHappiness(enhancerId)
        return true
    }

    /// Unciv ReligionManager.remainingFoundableReligionsBreakdown: the caps that limit how many religions may still be founded.
    func remainingFoundableReligionsBreakdown() -> [(String, Int)] {
        let founded = foundedReligionsCount
        func available(_ type: String) -> Int { rs.beliefs.values.filter { $0.type == type }.count - Set(civs.flatMap { $0.religionBeliefs }.filter { rs.beliefs[$0]?.type == type }).count }
        return [("Available religion symbols", rs.religionNames.count),
                ("Number of civilizations * [\(rs.constants.religionLimitMultiplier)] + [\(rs.constants.religionLimitBase)]", rs.constants.religionLimitBase + Int(Double(majorCivs.count) * rs.constants.religionLimitMultiplier)),
                ("Religions already founded", founded),
                ("Available founder beliefs", available("Founder")),
                ("Available follower beliefs", available("Follower"))]
    }

    /// Unciv CityReligionManager.removeUnknownPantheons: a city changing hands keeps only its new owner's pantheon
    func removeUnknownPantheons(cityIndex ci: Int, newOwner: Int) {
        for key in Array(cities[ci].religionPressure.keys) where key != noReligionName && religionOwner(key) == nil {
            if let founder = civs.first(where: { $0.pantheonBelief == key }), founder.id != newOwner { cities[ci].religionPressure[key] = nil }
        }
        updateNumberOfFollowers(cityIndex: ci)   // Unciv removeUnknownPantheons ends with updateNumberOfFollowers()

    }

    /// Founder and enhancer beliefs benefit the founding civ empire-wide.
    func founderUniques(for civId: Int) -> [Unique] {
        guard religionEnabled, let civ = civ(civId), civ.religionName != nil else { return [] }
        var out: [Unique] = []
        for b in civ.religionBeliefs { if let def = rs.beliefs[b], def.type == "Founder" || def.type == "Enhancer" { out += def.uniqueObjects.from(.founderBelief, b) } }
        return out
    }

    // MARK: per-turn
    func religionTurn(for civId: Int, faithIncome: Double) {
        if let c0 = civIndex(civId) { civs[c0].totalFaithForContests += Int(faithIncome) }   // Unciv TurnManager.endTurn
        guard let ci = civIndex(civId) else { return }
        civs[ci].faithStored += Double(Int(faithIncome))   // Unciv religionManager.endTurn(faith.toInt()): every civ, religion or not
    }

    /// Unciv ReligionManager.startTurn → generateProphet: the prophet the stored faith paid for is born at the start of the turn.
    func generateProphet(for civId: Int) {
        guard religionEnabled, let ci = civIndex(civId), civs[ci].isMajor else { return }
        // Prophet generation once a religion can be founded or enhanced/spread.
        // Unciv canGenerateProphet: a pantheon or religion exists, and a pantheon-only civ still has a religion left to found
        if (civs[ci].pantheonBelief != nil || civs[ci].religionName != nil) && !(civs[ci].religionName == nil && remainingFoundableReligions() == 0) && !eraForbidsProphets(civId) {
            let cost = prophetCost(civs[ci])
            if civs[ci].faithStored >= cost {
                let chance = Double(Float(5 + civs[ci].faithStored - cost) / Float(100))   // Unciv (5f + storedFaith - prophetCost) / 100f
                // Unciv ReligionManager: Random(gameInfo.turns).nextFloat() — the same draw for every civ this turn, so a reload cannot reroll it
                if prophetRandom() < chance, let seer = rs.units.values.first(where: { $0.canFoundReligion }) {
                    let home = civs[ci].holyCityId.flatMap { city($0) }.flatMap { $0.civId == civId && $0.isHolyCity ? $0 : nil } ?? capital(of: civId)   // Unciv getHolyCity(): isHolyCityOf (not blocked), and only while we own it
                    if let c = home, let unit = spawnUnit(equivalentUnitName(civId, seer.name), civId: civId, at: c.coord), let ui = unitIndex(unit.id) {
                        civs[ci].faithStored -= cost
                        civs[ci].prophetsEarned += 1
                        let prophetName = equivalentUnit(civId, seer).name
                        civs[ci].boughtWithIncreasingPrice[prophetName] = (civs[ci].boughtWithIncreasingPrice[prophetName] ?? (civs[ci].prophetsEarned - 1)) + 1   // Unciv boughtItemsWithIncreasingPrice.add(prophet, 1)
                        addConstructionBonuses(unitIndex: ui, city: c)   // Unciv: the birth city's bonuses apply
                        units[ui].religion = civs[ci].religionName ?? civs[ci].pantheonBelief   // Unciv generateProphet: prophet.religion = religion!!.name, overriding addUnit's birth-city majority
                        units[ui].charges = seer.spreadCharges + units[ui].promotions.reduce(0) { $0 + extraSpreadTimes(promotion: $1) }   // Unciv getMaxUsages: plus Devout's extra time
                        units[ui].customName = rs.unitNameGroups["Prophet"].flatMap { rng.pick($0) }
                        notify(civId, "A [\(seer.name)] has been born in [\(c.name)]!", category: .General, icons: [seer.name], actions: [.unit(unit.coord, unit.id)])
                    }
                }
            }
        }
    }
}
