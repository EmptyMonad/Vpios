// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Part of the mirror of Unciv `logic/civilization/managers/TechManager.kt`: entering a new era, and what that makes obsolete.
extension GameState {
    /// Unciv TechManager.moveToNewEra: era notifications for us and everyone who knows us, policy branches unlocked by the era, era uniques, "upon entering the [era]" triggers.
    func moveToNewEra(civId: Int, previousEraIndex: Int, showNotification: Bool = true) {
        guard let ci = civIndex(civId) else { return }
        let civ = civs[ci]
        let currentEra = civ.eraName
        guard let currentIndex = rs.eras.firstIndex(where: { $0.name == currentEra }), currentIndex > previousEraIndex else { return }
        if showNotification && !civ.isSpectator { notify(civId, "You have entered the [\(currentEra)]!", category: .General, icons: ["Science"]) }
        if showNotification && civ.isMajor {
            for other in civs where other.isAlive && other.id != civId && (other.metCivs.contains(civId) || other.isSpectator) { notify(other.id, "[\(civ.nation)] has entered the [\(currentEra)]!", category: .General, icons: [civ.nation, "Science"]) }
        }
        if showNotification && !civ.isSpectator {
            for branch in rs.policyBranches where branch.era == currentEra && canOpenBranch(civ, branch) { notify(civId, "[\(branch.name)] policy branch unlocked!", category: .General, icons: ["Culture"], actions: [.policy(branch.name)]) }
        }
        for era in rs.eras[(previousEraIndex + 1)...currentIndex] {
            if era.uniques.contains("Every major Civilization gains a spy once a civilization enters this era") { grantGlobalEraSpies(enteredBy: civId, era: era.name) }
            let eraUniques = era.uniques.map(Unique.init).filter { !$0.conditionals.contains { $0.pattern.hasPrefix("upon ") } }
            if !eraUniques.isEmpty { triggerUniques(eraUniques, civId: civId, cityId: nil, triggerText: "due to entering the [\(era.name)]") }
            triggerConditionalUniques(civId: civId, cityId: nil, triggerText: "due to entering the [\(era.name)]") { $0.pattern == "upon entering the []" && $0.param(0) == era.name }
        }
        triggerConditionalUniques(civId: civId, cityId: nil) { $0.pattern == "upon entering a new era" }   // Unciv TriggerUponEnteringEraUnfiltered
    }

    /// Unciv TechManager.obsoleteOldUnits: units made obsolete by the tech are swapped for their upgrade in every construction queue (or dropped).
    func obsoleteOldUnits(civId: Int, tech: String) {
        guard let civ = civ(civId) else { return }
        // Unciv builds `obsoleteUnits` with associateByNotNull over getEquivalentUpgradeOrNull: a unit made
        // obsolete by this tech but with no `upgradesTo` maps to null and is left OUT of the map, so
        // transformConstruction passes it through untouched - it stays in the queue until
        // validateConstructionQueue drops it at the next turn boundary, keeping its production until then.
        // Ours removed it (and zeroed the city's production) on the spot. G&K: the Scout at Scientific Theory.
        func replacement(_ name: String) -> String? {
            guard let def = rs.units[name], def.obsoleteTech == tech else { return name }
            guard let up = def.upgradesTo else { return name }
            return (rs.units.values.first { $0.replaces == up && $0.uniqueTo == civ.nation } ?? rs.units[up])?.name
        }
        var touched: [String: [City]] = [:]   // obsolete unit -> cities whose queue changed (Unciv unitUpgrades)
        for i in cities.indices where cities[i].civId == civId {
            let before = cities[i]
            if case .unit(let n) = cities[i].currentProduction ?? .building("") {
                // Unciv transformQueue only renames the queue entry: the old unit's work stays under its own name in
                // inProgressConstructions (our didSet parks it there), and validateInProgressConstructions below moves
                // it into the upgrade.
                if let r = replacement(n) { if r != n { cities[i].currentProduction = .unit(r); touched[n, default: []].append(before) } } else { cities[i].currentProduction = nil; touched[n, default: []].append(before) }
            }
            cities[i].productionQueue = cities[i].productionQueue.compactMap { p in
                if case .unit(let n) = p { let r = replacement(n); if r != n, !touched[n, default: []].contains(where: { $0.id == before.id }) { touched[n, default: []].append(before) }; return r.map { Production.unit($0) } }
                return p
            }
            if cities[i].currentProduction == nil { advanceProductionQueue(cityId: cities[i].id) }
        }
        // Unciv: "[unit] has become obsolete and was removed from the queue in [city]!" / "[city] changed production from [unit] to [newUnit]"
        for (unit, list) in touched.sorted(by: { $0.key < $1.key }) {
            // Unciv: "for mid-turn free tech picks ... it should happen immediately so the hammers from the obsolete
            // unit are guaranteed to go to the upgraded unit" - validateInProgressConstructions for every city whose
            // queue changed. Ours never ran it here, so a Crossbowman's 60 hammers were still parked under the
            // Crossbowman when Budapest's gold automation looked at the Gatling Gun (t_45 turn 179): with no work
            // done on it, it was bought for 740 gold, where Unciv's carried the hammers over and skipped the purchase.
            for c in list { if let ci = cityIndex(c.id) { validateInProgressConstructions(cityIndex: ci) } }
            let cityText = list.count == 1 ? "[\(list[0].name)]" : "[\(list.count)] cities"
            let newUnit = replacement(unit)
            let text = newUnit.map { "\(cityText) changed production from [\(unit)] to [\($0)]" } ?? "[\(unit)] has become obsolete and was removed from the queue in \(cityText)!"
            notify(civId, text, category: .Production, icons: newUnit.map { [unit, "StatIcons/Production", $0] } ?? ["StatIcons/Production"], actions: list.map { .location($0.coord) })   // LocationAction(cities)
        }
    }

    // MARK: tech
    func researchableTechs(for civ: Civilization) -> [TechDef] {
        rs.techs.values.filter { t in
            (!civ.techs.contains(t.name) || t.uniques.contains("Can be continually researched")) && t.prerequisites.allSatisfy { civ.techs.contains($0) }
                // Unciv TechManager.canBeResearched: not isUnresearchable
                && !t.uniqueObjects.contains { $0.pattern == "Only available" && !conditionalsHold($0, UniqueContext(civId: civ.id)) }
                && !t.uniqueObjects.contains { $0.pattern == "Unavailable" && conditionalsHold($0, UniqueContext(civId: civ.id)) }
        }.sorted { ($0.column, $0.row) < ($1.column, $1.row) }
    }

    /// Unciv TechManager.getScienceModifier: `1 + researched / remaining.toFloat() * 0.3f`, all in Float.
    /// Known civs are `getKnownCivs()` (neither defeated nor spectators) that are majors and have the tech;
    /// the remaining ones are every major that is not defeated.
    private func scienceModifier(_ techName: String, for civ: Civilization) -> Float {
        let researched = civ.metCivs.compactMap { self.civ($0) }.filter { $0.isMajor && $0.isAlive && !$0.isSpectator && $0.techs.contains(techName) }.count
        let remaining = civs.filter { $0.isMajor && $0.isAlive }.count
        return 1 + Float(researched) / Float(max(1, remaining)) * Float(0.3)   // max(1, ...): never divide by zero
    }

    /// Unciv TechManager.costOfTech, step for step and in Float as there: the difficulty (humans only), the
    /// speed, the known civs' discount, the map-size multiplier, the per-city modifier (with
    /// LessTechCostFromCities), LessTechCost, then `* (1 + cityModifier)` and `toInt()`.
    /// Ours multiplied the same factors in a different order and in Double, which truncates differently
    /// whenever the product lands a hair either side of a whole number.
    func techCost(_ tech: TechDef, for civ: Civilization) -> Double {
        var techCost = Float(tech.cost)
        if civ.isPlayer { techCost *= Float(difficulty.researchCostModifier) }
        techCost *= Float(speed.scienceCostModifier)
        techCost /= scienceModifier(tech.name, for: civ)
        // Unciv MapSize.Predefined.techCostMultiplier / techCostPerCityModifier (getPredefinedOrNextSmaller)
        let (sizeMult, perCity): (Float, Float) = {
            switch mapSizePreset { case .Huge: return (1.3, 0.025); case .Large: return (1.2, 0.0375); case .Medium: return (1.1, 0.05); default: return (1.0, 0.05) }
        }()
        techCost *= sizeMult
        var cityModifier = Float(cities(of: civ.id).filter { !$0.isPuppet }.count - 1) * perCity   // Unciv: count - 1 (may be -1)
        let ctx = UniqueContext(civId: civ.id)
        for u in civUniques(civ.id) where u.pattern == "Each city founded increases Science cost of Technologies []% less than normal" && conditionalsHold(u, ctx) { cityModifier *= 1 - Float(u.double(0)) / 100 }
        for u in civUniques(civ.id) where u.pattern == "[]% Science cost of researching new Technologies" && conditionalsHold(u, ctx) { techCost *= 1 + Float(u.double(0)) / 100 }   // Unciv LessTechCost: params[0].toPercent()
        techCost *= 1 + cityModifier
        return Double(Int(techCost))   // Unciv techCost.toInt()
    }

    /// Prerequisite chain (unknown techs only) ending with `tech`, in a researchable order.
    func techChain(to tech: String, for civ: Civilization) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        func visit(_ name: String) {
            guard !civ.techs.contains(name), !seen.contains(name), let def = rs.techs[name] else { return }
            seen.insert(name)
            for p in def.prerequisites { visit(p) }
            out.append(name)
        }
        visit(tech)
        return out
    }

    /// Unciv TechManager.isUnresearchable
    func isUnresearchable(_ civ: Civilization, _ t: TechDef) -> Bool {
        t.uniqueObjects.contains { $0.pattern == "Only available" && !conditionalsHold($0, UniqueContext(civId: civ.id)) }
            || t.uniqueObjects.contains { $0.pattern == "Unavailable" && conditionalsHold($0, UniqueContext(civId: civ.id)) }
    }

    /// Unciv TechPickerScreen.selectTechnology: the OnlyAvailable / Unavailable unique that blocks a technology
    func unavailableUnique(_ civ: Civilization, _ t: TechDef) -> Unique? {
        t.uniqueObjects.first { ($0.pattern == "Only available" && !conditionalsHold($0, UniqueContext(civId: civ.id))) || ($0.pattern == "Unavailable" && conditionalsHold($0, UniqueContext(civId: civ.id))) }
    }

    /// Unciv TechManager.getRequiredTechsToDestination: empty when the destination or a tech on the way is unresearchable, sorted by column
    func requiredTechsToDestination(_ civ: Civilization, _ tech: String) -> [TechDef] {
        guard let dest = rs.techs[tech], !isUnresearchable(civ, dest) else { return [] }
        var prerequisites: [TechDef] = []
        var names: Set<String> = []
        var check: [TechDef] = [dest]
        while !check.isEmpty {
            let t = check.removeFirst()
            if isUnresearchable(civ, t) { return [] }
            if !t.uniques.contains("Can be continually researched") && (civ.techs.contains(t.name) || names.contains(t.name)) { continue }
            for p in t.prerequisites { if let pd = rs.techs[p] { check.append(pd) } }   // HashSet order (TechDef.init)
            prerequisites.append(t); names.insert(t.name)
        }
        return prerequisites.enumerated().sorted { ($0.element.column, $0.offset) < ($1.element.column, $1.offset) }.map { $0.element }   // stable sortedBy
    }

    /// Sets research: a researchable tech becomes current at once, a distant one queues its whole chain.
    // MARK: Unciv TechManager research progress
    func researchOfTech(_ civ: Civilization, _ tech: String?) -> Int { tech.flatMap { civ.techsInProgress[$0] } ?? 0 }

    func canBeResearched(_ civ: Civilization, _ tech: String) -> Bool { researchableTechs(for: civ).contains { $0.name == tech } }

    /// Unciv TechManager.remainingScienceToTech
    func remainingScienceToTech(_ civ: Civilization, _ tech: String) -> Int {
        guard let def = rs.techs[tech] else { return 0 }
        let spareScience = canBeResearched(civ, tech) ? civ.overflowScience : 0
        return Int(techCost(def, for: civ)) - researchOfTech(civ, tech) - spareScience
    }

    /// Unciv TechManager.turnsToTech
    func turnsToTech(_ civ: Civilization, _ tech: String, science: Double) -> String {
        let remaining = Double(remainingScienceToTech(civ, tech))
        if remaining <= 0 { return "0" }
        if science <= 0 { return "∞" }
        return "\(max(1, Int(ceil(remaining / science))))"
    }

    /// Unciv Civilization.getStatReserve(Stat.Science)
    func scienceReserve(_ civ: Civilization) -> Int { civ.currentTech == nil ? 0 : researchOfTech(civ, civ.currentTech) }

    /// Unciv TechManager.limitOverflowScience: min(overflow, max(science per turn × 5, base cost of the current tech))
    private func limitOverflowScience(_ i: Int, _ overflow: Int, sciencePerTurn: Double?) -> Int {
        let baseCost = civs[i].currentTech.flatMap { rs.techs[$0]?.cost } ?? 0
        // Unciv reads `civInfo.stats.statsForNextTurn.science.toInt()` - the stored field, not a fresh sum.
        let perTurn = sciencePerTurn ?? civs[i].statsForNextTurn?.science ?? scienceOutput(for: civs[i].id)
        return min(overflow, max(Int(perTurn) * 5, baseCost))
    }

    /// Unciv TechManager.addScience
    func addScience(civId: Int, _ scienceGet: Int, sciencePerTurn: Double? = nil) {
        guard let i = civIndex(civId), let current = civs[i].currentTech, let def = rs.techs[current] else { return }
        civs[i].techsInProgress[current] = researchOfTech(civs[i], current) + scienceGet
        let cost = Int(techCost(def, for: civs[i]))
        if ProcessInfo.processInfo.environment["TECHCHOICE_CIV"] == civs[i].nation { print("TECHSCIE t=\(turn) \(current) +\(scienceGet) progress=\(civs[i].techsInProgress[current] ?? -1) cost=\(cost) overflow=\(civs[i].overflowScience)") }
        guard let progress = civs[i].techsInProgress[current], progress >= cost else { return }
        civs[i].overflowScience += limitOverflowScience(i, progress - cost, sciencePerTurn: sciencePerTurn)
        addTechnology(civId: civId, tech: current)
    }

    /// Unciv TechManager.updateResearchProgress
    func updateResearchProgress(civId: Int) {
        guard let i = civIndex(civId), let current = civs[i].currentTech, let def = rs.techs[current] else { return }
        let realOverflow = civs[i].overflowScience
        if researchOfTech(civs[i], current) + realOverflow >= Int(techCost(def, for: civs[i])) {
            civs[i].overflowScience = 0
            addScience(civId: civId, realOverflow)
        }
    }

    /// Unciv TechManager.addTechnology, in its order: the tech joins the researched set and leaves the
    /// queue, moveToNewEra (era notifications, era uniques, the "upon entering" triggers), the notification and
    /// the popup, the tech's own triggerable uniques, the TriggerUponResearch uniques, the revealed resources
    /// (humans), updateCivResources, every city's reassignPopulationDeferred, obsoleteOldUnits, and last
    /// updateResearchProgress. Ours ran updateCivResources and obsoleteOldUnits first and the tech's own
    /// uniques last, so a trigger (a free unit, a free building) saw the resources and the queues as they were
    /// before the tech instead of after.
    func addTechnology(civId: Int, tech: String, showNotification: Bool = true) {
        guard let i = civIndex(civId), let def = rs.techs[tech] else { return }
        // Unciv TechManager.era starts as `Era()` (eraNumber -1) and updateEra leaves it there while nothing is
        // researched, so a civ's first technology (GameStarter.addCivTechs' starting tech) takes moveToNewEra through
        // every era up to its own, the first one included
        let previousEra = civs[i].techs.isEmpty ? -1 : eraIndexByUncivRule(for: civs[i].techs)
        let isNewTech = civs[i].techs.insert(tech).inserted
        if !isNewTech { researchedTechnologyRepeats[civId, default: [:]][tech, default: 0] += 1 }   // researchedTechnologies.withItem(newTech)
        if GameState.evlogOn { ev(civId, "TECH", EvLog.name(tech)) }   // EVLOG: Unciv techsResearched.add
        if ProcessInfo.processInfo.environment["TECHCHOICE_CIV"] == civs[i].nation { print("TECHADDE t=\(turn) \(tech) gold=\(civs[i].gold) " + Thread.callStackSymbols.dropFirst(1).prefix(6).map { String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first ?? "") }.joined(separator: " < ")) }
        if !def.uniques.contains("Can be continually researched") {
            if civs[i].currentTech == tech { civs[i].currentTech = civs[i].techQueue.isEmpty ? nil : civs[i].techQueue.removeFirst() }
            civs[i].techQueue.removeAll { $0 == tech }
        } else { civs[i].futureTechs += 1 }
        civs[i].techsInProgress[tech] = nil
        onTechResearched(civId: civId, tech: tech, isNew: isNewTech, previousEraIndex: previousEra, showNotification: showNotification)
        updateResearchProgress(civId: civId)
    }

    /// Unciv TechManager.endTurn(scienceForNewTurn): the turn's science goes into the last-8-turns ring first,
    /// and only then - when something is being researched - the research agreements' banked science and the
    /// overflow join it and addScience spends the lot.
    func techEndTurn(civId: Int, scienceForNewTurn: Int, sciencePerTurn: Double) {
        guard let ci = civIndex(civId) else { return }
        // Unciv addCurrentScienceToScienceOfLast8Turns: `scienceOfLast8Turns[gameInfo.turns % 8]`. Our `turn`
        // is Unciv's `turns + 1`, so indexing by `turn % 8` wrote the slot one AHEAD of Unciv's: the ring holds
        // the same eight numbers once it has turned over, but the first eight turns after loading a save
        // overwrote the wrong entry, and the Great Scientist's bulb read a different sum.
        if civs[ci].scienceOfLast8Turns.count != 8 { civs[ci].scienceOfLast8Turns = [0, 0, 0, 0, 0, 0, 0, 0] }
        civs[ci].scienceOfLast8Turns[(turn - 1) % 8] = scienceForNewTurn
        // The AI picks its research in NextTurnAutomation before this, and Unciv's TechManager.endTurn returns
        // when there is none: a great scientist that finished the research this turn leaves the AI with nothing
        // to put the turn's science into, and it is lost. Only the headless run's player gets the first researchable tech.
        if civs[ci].currentTech == nil, civs[ci].isPlayer && epochsAutoplay, let next = researchableTechs(for: civs[ci]).first { civs[ci].currentTech = next.name }
        guard civs[ci].currentTech != nil else { return }
        var finalScienceToAdd = scienceForNewTurn
        if civs[ci].scienceFromResearchAgreements != 0 {
            // Unciv scienceFromResearchAgreements(): `(scienceFromResearchAgreements / 3 * modifier).toInt()` -
            // Int division first, then a Float modifier of 0.5 + params/200 per unique.
            var modifier: Float = 0.5
            for u in civUniques(civId) where u.pattern == "Science gained from research agreements []%" && conditionalsHold(u, UniqueContext(civId: civId)) { modifier += Float(u.double(0)) / 200 }
            let scienceBoost = Int(Float(Int(civs[ci].scienceFromResearchAgreements) / 3) * modifier)
            finalScienceToAdd += scienceBoost
            civs[ci].scienceFromResearchAgreements = 0
            notify(civId, "We gained [\(scienceBoost)] Science from Research Agreement", category: .General, icons: ["Science"])
        }
        if civs[ci].overflowScience != 0 { finalScienceToAdd += civs[ci].overflowScience; civs[ci].overflowScience = 0 }
        addScience(civId: civId, finalScienceToAdd, sciencePerTurn: sciencePerTurn)
    }

    /// Unciv TechManager.getScienceFromGreatScientist: `(scienceOfLast8Turns.sum() * speed.scienceCostModifier).toInt()`,
    /// an Int times a Float.
    func scienceFromGreatScientist(_ civ: Civilization) -> Int {
        Int(Float(civ.scienceOfLast8Turns.reduce(0, +)) * Float(speed.scienceCostModifier))
    }

    func chooseResearch(civId: Int, tech: String) {
        guard let i = civIndex(civId), !civs[i].techs.contains(tech) || rs.techs[tech]?.uniques.contains("Can be continually researched") == true else { return }
        if researchableTechs(for: civs[i]).contains(where: { $0.name == tech }) {
            civs[i].currentTech = tech
            civs[i].techQueue.removeAll { $0 == tech }
            return
        }
        let chain = techChain(to: tech, for: civs[i])
        guard let first = chain.first(where: { t in researchableTechs(for: civs[i]).contains { $0.name == t } }) else { return }
        civs[i].currentTech = first
        civs[i].techQueue = chain.filter { $0 != first }
    }

    /// After a discovery, continue with the queue; otherwise the cheapest available tech.
    func nextResearch(civId: Int) {
        guard let i = civIndex(civId) else { return }
        let known = civs[i].techs   // read before the write: a closure reading `civs` inside a removeAll on it trips Swift's exclusivity check
        civs[i].techQueue.removeAll { known.contains($0) }
        if let next = civs[i].techQueue.first(where: { t in researchableTechs(for: civs[i]).contains { $0.name == t } }) {
            civs[i].currentTech = next; civs[i].techQueue.removeAll { $0 == next }
        } else { civs[i].currentTech = researchableTechs(for: civs[i]).first?.name }
    }

    /// Spend a banked free technology on the given tech.
    /// Unciv TechPickerScreen.selectTechnology: `if (godMode && !isResearched(tech) && selectedTech == previousSelectedTech) addTechnology(tech)`
    /// — no prerequisite check; the tap then continues as a normal selection.
    func godModeAddTechnology(civId: Int, tech: String) {
        guard let i = civIndex(civId), !civs[i].techs.contains(tech), rs.techs[tech] != nil else { return }
        addTechnology(civId: civId, tech: tech)
    }

    /// Unciv TechManager.getFreeTechnology
    func claimFreeTech(civId: Int, tech: String) {
        guard let i = civIndex(civId), civs[i].freeTechs > 0, researchableTechs(for: civs[i]).contains(where: { $0.name == tech }) else { return }
        civs[i].freeTechs -= 1
        addTechnology(civId: civId, tech: tech)
    }

    /// Unciv TechManager.updateEra: the era of the latest researched tech, or of the earliest unresearched one when later.
    func eraIndexByUncivRule(for techs: Set<String>) -> Int {
        guard !techs.isEmpty else { return 0 }
        var best = 0
        var minUnresearched: Int? = nil
        for (name, d) in rs.techs {
            guard let i = rs.eras.firstIndex(where: { $0.name == d.era }) else { continue }
            if techs.contains(name) { best = max(best, i) } else { minUnresearched = min(minUnresearched ?? i, i) }
        }
        return max(best, minUnresearched ?? best)
    }

    func eraIndex(for techs: Set<String>) -> Int {
        var best = 0
        for t in techs { if let d = rs.techs[t], let i = rs.eras.firstIndex(where: { $0.name == d.era }) { best = max(best, i) } }
        return best
    }

    func onTechResearched(civId: Int, tech: String, isNew: Bool = true, previousEraIndex: Int? = nil, showNotification: Bool = true) {
        let previousEra = previousEraIndex ?? eraIndexByUncivRule(for: (civ(civId)?.techs ?? []).subtracting([tech]))
        moveToNewEra(civId: civId, previousEraIndex: previousEra, showNotification: showNotification)
        // Unciv TechManager: the era is announced first, and a spectator is told nothing at all
        if showNotification, civ(civId)?.isSpectator != true { notify(civId, "Research of [\(tech)] has completed!", category: .General, icons: ["StatIcons/Science"], actions: [.tech(tech)]) }
        if isNew { addAlert(civId, .TechResearched, tech) }   // Unciv addTechnology: popup only for a newly researched tech
        // Unciv addTechnology: the MayanGainGreatPerson unique whose tech this is announces the Long Count.
        if let u = longCountUnique(civId), u.param(1) == tech { notify(civId, "You have unlocked [The Long Count]!", category: .General, icons: ["Maya"], actions: [.civilopedia("Nation/The Maya")]) }
        // Unciv reveals the map for a tech only through the tech's own triggerable uniques below (OneTimeRevealEntireMap).
        // Ours also revealed it here and marked every natural wonder discovered - Unciv's naturalWonders fills only from
        // what the civ SEES (discoverNaturalWonders), so a city-state got +2 happiness for wonders it never saw.
        // Unciv addTechnology: the tech's own triggerable uniques, then TriggerUponResearch
        if let def = rs.techs[tech] { triggerUniques(def.uniqueObjects, civId: civId, cityId: nil, triggerText: "due to researching [\(tech)]", sourceTech: tech) }
        triggerConditionalUniques(civId: civId, cityId: nil, triggerText: "due to researching [\(tech)]") { $0.pattern == "upon discovering [] technology" && $0.param(0) == tech }
        // Unciv TechManager.addTechnology → notifyExploredResources for every resource this tech reveals (within 5 tiles of a city).
        // rs.resources bir Dictionary: values sırası süreç başına rastgele. Unciv ruleset.tileResources
        // (Resources.json sırası) üzerinde yürüdüğü için rs.resourcesInOrder kullanıyoruz.
        if civ(civId)?.isPlayer == true { for r in rs.resourcesInOrder where r.revealedBy == tech { notifyExploredResources(civId, resource: r.name, maxDistance: 5) } }   // Unciv addTechnology: only when playerType == Human
        // Unciv TechManager.addTechnology ends in `civInfo.cache.updateCivResources()`. A technology can reveal
        // a resource that is already sitting on an improved tile we own, and from that instant the civ has it:
        // measured on t_45, Japan finished Calendar on turn 41 and Silk appeared in Unciv's resource list the
        // same turn, taking its happiness from -1 to +2 - which is the difference between the -75% unhappiness
        // growth penalty applying to Kyoto's food that turn and not applying. Our resource count is keyed on a
        // visibility generation that a technology does not bump, and the happiness built on it was cached too,
        // so both stayed on the pre-tech answer until something else happened to invalidate them.
        invalidateHappiness(civId)
        updateCivResources(civId)   // Unciv TechManager.addTechnology:345
        for i in cities.indices where cities[i].civId == civId { reassignPopulationDeferred(i) }   // Unciv TechManager.addTechnology:347
        obsoleteOldUnits(civId: civId, tech: tech)
    }
}
