// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
extension GameState {
    var espionageEnabled: Bool { settings.espionageEnabled }

    /// First era whose definition says "Every major Civilization gains a spy once a civilization enters this era" (Renaissance in Civ V).
    static var spyEraStart: String {
        Ruleset.shared.eras.first { $0.uniques.contains("Every major Civilization gains a spy once a civilization enters this era") }?.name ?? "Age of Sails"
    }

    /// Unciv UniqueTriggerActivation.OneTimeGlobalSpiesWhenEnteringEra: when a major civ enters an era carrying the unique,
    /// every alive major that has not yet earned a spy for that era gets one.
    func grantGlobalEraSpies(enteredBy civId: Int, era: String) {
        guard espionageEnabled, civ(civId)?.isMajor == true else { return }
        for other in majorCivs where other.isAlive {
            guard let oi = civIndex(other.id), !civs[oi].spiesGranted.contains(era) else { continue }
            civs[oi].spiesGranted.insert(era)
            let knows = other.id == civId || civs[oi].metCivs.contains(civId)
            addSpy(civId: other.id, unknownEntrantEra: knows ? nil : era)
        }
    }

    /// Unciv EspionageManager.getStartingSpyRank
    func startingSpyRank(_ civId: Int) -> Int { 1 + civUniques(civId).filter { $0.pattern == "New spies start with [] level(s)" && conditionalsHold($0, UniqueContext(civId: civId)) }.reduce(0) { $0 + $1.int(0) } }   // Unciv getMatchingUniques(SpyStartingLevel): conditionals apply

    /// Unciv EspionageManager.getSpyName: a random unused name.
    /// Unciv EspionageManager.kt:50 -> `civInfo.state.stateBasedRandom("EspianageManager.getSpyName")`.
    /// Caller dizesi Unciv'in kendi yazim hatasini ("Espianage") birebir tasir - tohum harfi harfine eslesmeli.
    /// `used` yalnizca `contains` icin kullanilir, suzgec `spyNames` dizisinin sirasini korur: gezinme sirasi sabit.
    private func newSpyName(_ ci: Int) -> String {
        var g = stateBasedRandom("EspianageManager.getSpyName", civId: civs[ci].id)
        let used = Set(civs[ci].spies.map { $0.name })
        return g.pick((civs[ci].nationDef?.spyNames ?? []).filter { !used.contains($0) }) ?? "Spy \(civs[ci].spies.count + 1)"
    }

    func addSpy(civId: Int, unknownEntrantEra: String? = nil) {
        guard let ci = civIndex(civId) else { return }
        let name = newSpyName(ci)
        civs[ci].spies.append(Spy(id: newId(), name: name, rank: startingSpyRank(civId)))
        // spy.addNotification - a new spy is in the hideout: no location, the espionage overview alone
        if let era = unknownEntrantEra { notifySpy(civId, "After [an unknown civilization] entered the [\(era)], we have recruited [\(name)] as a spy!", at: nil) }
        else { notifySpy(civId, "We have recruited [\(name)] as a spy!", at: nil) }
    }

    /// Unciv Spy.addNotification ("Shorthand for addNotification specialized for espionage - action, category and icon are
    /// always the same"): `EspionageAction.withLocation(location)` - the spy's city when it has one, then the espionage
    /// overview - NotificationCategory.Espionage and NotificationIcon.Spy alone. Ours gave a location only (or none) and
    /// added the stolen tech's or Death's icon.
    func notifySpy(_ civId: Int, _ text: String, at coord: HexCoord?) {
        notify(civId, text, category: .Espionage, icons: ["Spy"], actions: (coord.map { [NotificationAction.location($0)] } ?? []) + [.espionage], coord: coord)
    }

    func spy(_ id: Int, of civId: Int) -> Spy? { civ(civId)?.spies.first { $0.id == id } }

    /// Unciv SpyAction.isSetUp
    static let spySetUpActions: Set<String> = ["Surveillance", "StealingTech", "RiggingElections", "Coup", "CounterIntelligence"]

    /// Unciv SpyAction.displayString (used for the "[] levels for []" rank bonus)
    static let spyActionDisplay: [String: String] = ["None": "None", "Moving": "Moving", "EstablishNetwork": "Establishing Network", "Surveillance": "Observing City", "StealingTech": "Stealing Tech", "RiggingElections": "Rigging Elections", "Coup": "Coup", "CounterIntelligence": "Counter-intelligence", "Dead": "Dead"]

    /// Unciv Spy.getSkillModifierPercent
    func spySkill(_ spy: Spy) -> Int { effectiveSpyRank(spy, action: GameState.spyActionDisplay[spy.action] ?? spy.action) * rs.constants.spyRankSkillPercentBonus }

    /// Unciv Spy.getEfficiencyModifier
    func spyEfficiency(_ spy: Spy, civId: Int) -> Double {
        let city = spy.cityId.flatMap { self.city($0) }
        var friendly: [Unique] = [], enemy: [Unique] = []
        if let c = city, c.civId == civId { friendly = cityUniques(c).filter { $0.pattern == "[]% spy effectiveness []" } }
        else {
            friendly = civUniques(civId).filter { $0.pattern == "[]% spy effectiveness []" }
            if let c = city { enemy = cityUniques(c).filter { $0.pattern == "[]% enemy spy effectiveness []" } }
        }
        var total = 1.0
        total *= (100 + friendly.filter { u in city.map { cityMatchesFilter(u.param(1), city: $0, viewer: civId) } ?? true }.reduce(0.0) { $0 + $1.double(0) }) / 100
        total *= (100 + enemy.filter { u in city.map { cityMatchesFilter(u.param(1), city: $0, viewer: $0.civId) } ?? false }.reduce(0.0) { $0 + $1.double(0) }) / 100
        return max(0, total)
    }

    /// Unciv EspionageAutomation.automateSpies
    /// Unciv SpyAction.isDoingWork: moving → working; own city → counter-intelligence for 10 turns; city-state → rigging elections unless at war;
    /// foreign major → stealing tech only while something is stealable (otherwise Surveillance, i.e. idle); hideout → idle.
    func spyIsDoingWork(_ spy: Spy, civId: Int) -> Bool {
        switch spy.action {
        case "Moving", "EstablishNetwork", "StealingTech", "Coup": return true
        case "RiggingElections": return spy.cityId.flatMap { city($0) }.map { !areAtWar(civId, $0.civId) } ?? false
        case "CounterIntelligence": return spy.turnsRemaining > 0
        default: return false
        }
    }
    /// Unciv Spy.canMoveTo, in its order: a promise not to send spies closes the city (even the one the spy is
    /// in), then the spy's own city is fine, then the centre must be explored and no spy of ours assigned there.
    func spyCanMoveTo(_ spy: Spy, _ c: City, civId: Int) -> Bool {
        if !mayMoveSpy(civId, to: c.civId) { return false }   // canDismissAgreementToNotSendSpies
        if spy.cityId == c.id { return true }
        guard let me = civ(civId), me.explored.contains(c.coord) else { return false }
        return !me.spies.contains { $0.alive && $0.id != spy.id && $0.cityId == c.id }
    }

    // MARK: coups in city-states
    /// Unciv Spy.canDoCoup: set up in a city-state that is not our ally
    func canDoCoup(civId: Int, spy: Spy) -> Bool {
        guard let cid = spy.cityId, let city = city(cid), let cs = civ(city.civId), cs.isCityState else { return false }
        return GameState.spySetUpActions.contains(spy.action) && ally(of: cs.id) != civId
    }

    /// Unciv Spy.getCoupChanceOfSuccess(includeUnknownFactors = true)
    func coupChance(civId: Int, spy: Spy, includeUnknownFactors: Bool = true) -> Double? {
        guard canDoCoup(civId: civId, spy: spy), let cid = spy.cityId, let city = city(cid), let cs = civ(city.civId) else { return nil }
        // Unciv getCoupChanceOfSuccess works in Float throughout
        var pct: Float = 50
        var influenceDifference: Float = ally(of: cs.id).map { Float(influence(of: $0, with: cs.id)) } ?? 60
        influenceDifference -= Float(influence(of: civId, with: cs.id))
        pct -= influenceDifference / 2
        var spyRanks = spySkill(spy)   // Int: getSkillModifierPercent() - (defendingSpy?.getSkillModifierPercent() ?: 0)
        if includeUnknownFactors, let a = ally(of: cs.id), let defending = civ(a)?.spies.first(where: { $0.cityId == cid }) { spyRanks -= spySkill(defending) }
        pct += Float(spyRanks) / 2   // each rank counts for 15%
        return Double(min(85, max(0, pct)) / 100)
    }

    /// Unciv: a coup is ordered now and resolved at the end of the turn - `spy.setAction(SpyAction.Coup, 1)` in both
    /// EspionageAutomation.checkIfShouldStageCoup and the overview screen's CoupButton
    @discardableResult
    func attemptCoup(civId: Int, spyId: Int) -> Bool {
        guard let ci = civIndex(civId), let si = civs[ci].spies.firstIndex(where: { $0.id == spyId }), canDoCoup(civId: civId, spy: civs[ci].spies[si]) else { return false }
        civs[ci].spies[si].action = "Coup"; civs[ci].spies[si].turnsRemaining = 1
        return true
    }

    /// Unciv EspionageOverviewScreen.CoupButton: pressing it again cancels the coup (setAction(CounterIntelligence, 10))
    func cancelCoup(civId: Int, spyId: Int) {
        guard let ci = civIndex(civId), let si = civs[ci].spies.firstIndex(where: { $0.id == spyId }), civs[ci].spies[si].action == "Coup" else { return }
        civs[ci].spies[si].action = "CounterIntelligence"; civs[ci].spies[si].turnsRemaining = 10
    }

    /// Unciv Spy.initiateCoup
    private func initiateCoup(_ ci: Int, _ si: Int) {
        let civId = civs[ci].id
        let spy = civs[ci].spies[si]
        guard canDoCoup(civId: civId, spy: spy), let cid = spy.cityId, let city = city(cid), let ti = civIndex(city.civId) else {
            civs[ci].spies[si].action = "RiggingElections"; civs[ci].spies[si].turnsRemaining = 10   // maybe we are the ally now
            return
        }
        let csId = civs[ti].id, csName = civs[ti].nation, ourName = civs[ci].nation
        let allyCiv = ally(of: csId)
        let chance = coupChance(civId: civId, spy: spy) ?? 0
        var coupRng = SeededRandom(kotlinSeed: spyRandomSeed(spy))   // Unciv Spy.initiateCoup: `Random(randomSeed()).nextFloat() <= successChance`
        if coupRng.nextFloat() <= Float(chance) {
            let previousInfluence = allyCiv.map { influence(of: $0, with: csId) } ?? 80
            // Unciv `setInfluence(previousInfluence)`: clamped, and the ally recomputed at once - tied with the old
            // ally, we take over here when we come first in the city-state's diplomacy order
            setInfluence(cityState: csId, major: civId, previousInfluence)
            notify(civId, "Your spy [\(spy.name)] successfully staged a coup in [\(csName)]!", category: .Espionage, icons: ["Spy", csName], coord: city.coord)
            if let a = allyCiv {
                let current = civs[ti].influence[a] ?? 0
                if current > 0 { civs[ti].influence[a] = Double(max(0, Float(current) - 20)) }   // reduceInfluence: no ally recompute
                notify(a, "A spy from [\(ourName)] successfully staged a coup in our former ally [\(csName)]!", category: .Espionage, icons: [ourName, "Spy", csName], coord: city.coord)
                addModifier(a, civId, .SpiedOnUs, -15)
            }
            // Unciv cityState.getKnownCivsWithSpectators(): the city-state's diplomacy order, the defeated skipped;
            // a spectator is told but keeps its influence
            for other in diplomacyOrder(csId) where other != allyCiv && other != civId && civ(other).map({ !$0.isBarbarian && !isDefeated($0) }) == true {
                notify(other, "A spy from [\(ourName)] successfully staged a coup in [\(csName)]!", category: .Espionage, icons: [ourName, "Spy", csName], coord: city.coord)
                if civ(other)?.isSpectator == true { continue }
                let current = civs[ti].influence[other] ?? 0
                if current > 0 { civs[ti].influence[other] = Double(max(0, Float(current) - 10)) }   // reduceInfluence (Guess)
            }
            civs[ci].spies[si].action = "RiggingElections"; civs[ci].spies[si].turnsRemaining = 10
            // Unciv: the ally is recomputed last, after every third civ lost its 10
            updateAllyCivForCityState(csId)
            invalidateHappiness()
        } else {
            let defending: (Int, Int)? = allyCiv.flatMap { a in civIndex(a).flatMap { ai in civs[ai].spies.firstIndex(where: { $0.cityId == cid && $0.action != "Dead" }).map { (ai, $0) } } }
            addInfluence(cityState: csId, major: civId, -20)
            if let a = allyCiv {
                notify(a, "A spy from [\(ourName)] failed to stage a coup in our ally [\(csName)] and was killed!", category: .Espionage, icons: [ourName, "Spy", csName], coord: city.coord)
                addModifier(a, civId, .SpiedOnUs, -10)
            }
            // Unciv: `civInfo.addNotification(..., getCity().location, Espionage, civInfo.civName, NotificationIcon.Spy, cityState.civName)`
            notify(civId, "Our spy [\(spy.name)] failed to stage a coup in [\(csName)] and was killed!", category: .Espionage, icons: [ourName, "Spy", csName], coord: city.coord)
            killSpy(ci, si)
            if let d = defending { civs[d.0].spies[d.1] = spyLeveledUp(civs[d.0].spies[d.1], civId: civs[d.0].id) }
        }
    }

    /// Unciv Spy.killSpy: back to the hideout, dead for 5 turns, rank reset
    private func killSpy(_ ci: Int, _ si: Int) {
        civs[ci].spies[si].cityId = nil; civs[ci].spies[si].arriving = 0; civs[ci].spies[si].turnsInCity = 0
        civs[ci].spies[si].action = "Dead"; civs[ci].spies[si].turnsRemaining = 5; civs[ci].spies[si].rank = 1; civs[ci].spies[si].alive = false
    }

    /// Unciv Spy.randomSeed ("Anti-save-scum: Deterministic random from city and turn"):
    /// `(getCity().location.x * location.y + 123f * gameInfo.turns).toInt() + name.hashCode()`.
    func spyRandomSeed(_ spy: Spy) -> Int32 {
        let loc = spy.cityId.flatMap { city($0) }.map { uncivPosition($0.coord) } ?? (x: 0, y: 0)
        let turns = turn - (barbarianPhase ? 0 : 1)   // Unciv gameInfo.turns
        let f = Float(Int32(truncatingIfNeeded: loc.x) &* Int32(truncatingIfNeeded: loc.y)) + 123 * Float(turns)
        return Int32(clamping: Int(f)) &+ javaStringHash(spy.name)
    }

    /// Unciv Spy.canMoveTo → !canDismissAgreementToNotSendSpies: while we have promised a civilization not to send
    /// spies, its cities stay closed to us unless its technology is more than ten percent ahead of ours - in Float,
    /// `(researched / technologies.size) * 100f`. (The invented splitmix `espionageRandom` that stood here is gone:
    /// EspionageAutomation draws Kotlin `Random(seed)` like Unciv.)
    func mayMoveSpy(_ civId: Int, to owner: Int) -> Bool {
        guard owner != civId, hasFlag(owner, civId, Demand.DontSpyOnUs.agreedToDemand) else { return true }
        let treeSize = Float(rs.techs.count)
        let ourLevel = (Float(civ(civId)?.techs.count ?? 0) / treeSize) * 100
        let theirLevel = (Float(civ(owner)?.techs.count ?? 0) / treeSize) * 100
        return !(theirLevel <= ourLevel + 10)
    }

    /// Unciv Spy.moveTo: a city means one turn Moving, nil means the hideout. moveTo checks nothing: canMoveTo (our
    /// promise not to spy, canDismissAgreementToNotSendSpies) is the AI's and the map's filter (spyCanMoveTo), and the
    /// overview's MoveToLocationButton only asks "This may result in breaking your promise" before moving. Ours
    /// refused the move here, so the overview's confirmed Move left the spy where it was.
    func assignSpy(civId: Int, spyId: Int, to cityId: Int?) {
        guard let ci = civIndex(civId), let si = civs[ci].spies.firstIndex(where: { $0.id == spyId }), civs[ci].spies[si].action != "Dead" else { return }
        if let cid = cityId, civs[ci].spies.contains(where: { $0.id != spyId && $0.cityId == cid && $0.action != "Dead" }) { return }
        civs[ci].spies[si].turnsInCity = 0
        if let cid = cityId, city(cid) != nil {
            civs[ci].spies[si].cityId = cid; civs[ci].spies[si].action = "Moving"; civs[ci].spies[si].turnsRemaining = 1; civs[ci].spies[si].arriving = 1
        } else {
            civs[ci].spies[si].cityId = nil; civs[ci].spies[si].action = "None"; civs[ci].spies[si].turnsRemaining = 0; civs[ci].spies[si].arriving = 0
        }
    }

    /// Unciv Spy.levelUpSpy: capped at maxSpyRank, one notice naming how many ranks were gained.
    func spyLeveledUp(_ spy: Spy, civId: Int, amount: Int = 1) -> Spy {
        let maxRank = rs.constants.maxSpyRank
        guard spy.rank < maxRank else { return spy }
        let ranks = min(amount, maxRank - spy.rank)
        guard ranks > 0 else { return spy }
        if ranks == 1 { notifySpy(civId, "Your spy [\(spy.name)] has leveled up!", at: spy.cityId.flatMap { city($0)?.coord }) }
        else { notifySpy(civId, "Your spy [\(spy.name)] has leveled up [\(ranks)] times!", at: spy.cityId.flatMap { city($0)?.coord }) }
        var s = spy; s.rank += ranks
        return s
    }

    enum CanStealTech { case yes, noTechsToSteal, noScienceInCity }

    /// Unciv Spy.incrementTechStealingProgress: turns left, 0 when the tech can be stolen now. In Float as there: the
    /// city's Float science times `(rank * spyRankStealPercentBonus + 75f) / 100f` (an Int rank bonus) and the
    /// efficiency `toFloat()`, truncated into the Int progress; the cost `maxCost.toFloat() *= spyTechStealCostModifier
    /// * scienceCostModifier` (the two modifiers multiplied first), the turns `ceil(remainingCost / progressThisTurn)`.
    /// Ours ran it in Double, which truncates a point lower whenever the Float product lands on a whole number.
    private func incrementTechStealingProgress(_ ci: Int, _ si: Int, city: City) -> Int {
        let civId = civs[ci].id
        let spy = civs[ci].spies[si]
        var progressThisTurn = Float(currentCityStats(city.id).total.science)
        let rankTechStealModifier = spy.rank * rs.constants.spyRankStealPercentBonus
        progressThisTurn *= (Float(rankTechStealModifier) + 75) / 100
        progressThisTurn *= Float(spyEfficiency(spy, civId: civId))
        civs[ci].spies[si].progress += Double(Int(progressThisTurn))
        let stealable = techsStealable(by: civId, from: city.civId)
        var techStealCost = Float(stealable.compactMap { rs.techs[$0]?.cost }.max() ?? 0)
        techStealCost *= Float(rs.constants.spyTechStealCostModifier) * Float(speed.scienceCostModifier)
        let remainingCost = techStealCost - Float(Int(civs[ci].spies[si].progress))
        if remainingCost <= 0 { return 0 }
        return progressThisTurn > 0 ? Int((remainingCost / progressThisTurn).rounded(.up)) : Int.max / 4
    }

    /// Unciv Spy.stealTech: roll 0-299 minus our skill plus the defender's; 200+ kills the spy, 100+ reveals it, below 0 goes unnoticed
    private func stealTech(_ ci: Int, _ si: Int, city: City) {
        let civId = civs[ci].id, civName = civs[ci].nation
        let spy = civs[ci].spies[si]
        guard let oi = civIndex(city.civId) else { return }
        let otherId = civs[oi].id
        // Unciv Spy.stealTech: `getTechsToSteal(city.civ).randomOrNull(Random(randomSeed))`, then a SECOND
        // `Random(randomSeed).nextInt(300)` from the same seed; the list is in getTechsToSteal's order.
        let seed = spyRandomSeed(spy)
        var techRng = SeededRandom(kotlinSeed: seed)
        let stolen: String? = techRng.pick(techsStealable(by: civId, from: otherId))
        var resultRng = SeededRandom(kotlinSeed: seed)
        var result = Int(resultRng.nextInt(until: 300)) - spySkill(spy)
        let defendingIndex = civs[oi].spies.firstIndex(where: { $0.cityId == city.id && $0.action != "Dead" })
        if let d = defendingIndex { result += spySkill(civs[oi].spies[d]) }
        var detection: String? = nil
        if result >= 200 {
            if let d = defendingIndex { detection = "A spy from [\(civName)] was found and killed by [\(civs[oi].spies[d].name)] trying to steal Technology in [\(city.name)]!" }
            else { detection = "A spy from [\(civName)] was found and killed trying to steal Technology in [\(city.name)]!" }
        } else if let tech = stolen, result >= 0 {
            detection = result < 100 ? "An unidentified spy stole the Technology [\(tech)] from [\(city.name)]!" : "A spy from [\(civName)] stole the Technology [\(tech)] from [\(city.name)]!"
        }
        if let d = detection { notify(otherId, d, category: .Espionage, icons: ["Spy"], coord: city.coord) }
        if result < 200, let tech = stolen {
            addTechnology(civId: civId, tech: tech)
            notifySpy(civId, "Your spy [\(spy.name)] stole the Technology [\(tech)] from [\(city.name)]!", at: city.coord)
            civs[ci].spies[si] = spyLeveledUp(civs[ci].spies[si], civId: civId)
        }
        if result >= 200 {
            notifySpy(civId, "Your spy [\(spy.name)] was killed trying to steal Technology in [\(city.name)]!", at: city.coord)
            if let d = defendingIndex { civs[oi].spies[d] = spyLeveledUp(civs[oi].spies[d], civId: otherId) }
            killSpy(ci, si)
            demandToNotBeSpiedOn(otherId, by: civId)
        } else {
            civs[ci].spies[si].progress = 0; civs[ci].spies[si].action = "StealingTech"; civs[ci].spies[si].turnsRemaining = 0   // startStealingTech
        }
        if result >= 100 { demandToNotBeSpiedOn(otherId, by: civId) }
    }

    /// Unciv Spy.demandToNotBeSpiedOn
    private func demandToNotBeSpiedOn(_ other: Int, by civId: Int) {
        addModifier(other, civId, .SpiedOnUs, -15)
        setFlag(other, civId, "DiscoveredSpiesInOurCities", Int((30 * speed.modifier).rounded()))   // Unciv: scaled by game speed
    }

    /// Saves from before spy actions: derive the Unciv action from the old fields
    private func migrateLegacySpy(_ ci: Int, _ si: Int) {
        var sp = civs[ci].spies[si]
        guard sp.action == "None" else { return }
        if !sp.alive { sp.action = "Dead"; sp.turnsRemaining = 5 }
        else if let cid = sp.cityId, let c = city(cid) {
            if sp.arriving > 0 { sp.action = "Moving"; sp.turnsRemaining = 1 }
            else if c.civId == civs[ci].id { sp.action = "CounterIntelligence"; sp.turnsRemaining = 10 }
            else if let owner = civ(c.civId), owner.isCityState { sp.action = "RiggingElections"; sp.turnsRemaining = max(0, (owner.civFlags["TurnsTillCityStateElection"] ?? 1) - 1) }
            else { sp.action = "StealingTech" }
        } else { return }
        civs[ci].spies[si] = sp
    }

    /// Unciv Spy.endTurn
    private func spyEndTurn(_ ci: Int, _ si: Int) {
        let civId = civs[ci].id
        let spy = civs[ci].spies[si]
        if ["Moving", "EstablishNetwork", "Dead"].contains(spy.action) {
            civs[ci].spies[si].turnsRemaining -= 1
            if civs[ci].spies[si].turnsRemaining > 0 { return }
        }
        func set(_ action: String, _ turns: Int = 0) { civs[ci].spies[si].action = action; civs[ci].spies[si].turnsRemaining = turns }
        let city = spy.cityId.flatMap { self.city($0) }
        switch spy.action {
        case "Moving":
            guard let c = city else { set("None"); return }
            if c.civId == civId { set("CounterIntelligence", 10) } else { set("EstablishNetwork", 3) }
        case "EstablishNetwork":
            guard let c = city, let owner = civ(c.civId) else { set("None"); return }
            if owner.isCityState { set("RiggingElections", (owner.civFlags["TurnsTillCityStateElection"] ?? 1) - 1) }
            else if c.civId == civId { set("CounterIntelligence", 10) }
            else { civs[ci].spies[si].progress = 0; set("StealingTech") }
        case "Surveillance":
            guard let c = city, civ(c.civId)?.isMajor == true, canStealTech(civId: civId, city: c) == .yes else { return }
            set("StealingTech")
        case "StealingTech":
            guard let c = city else { set("None"); return }
            let result = canStealTech(civId: civId, city: c)
            if result != .yes {
                set("Surveillance")
                if result == .noTechsToSteal { notifySpy(civId, "Your spy [\(spy.name)] cannot steal any more techs from [\(civ(c.civId)?.nation ?? "?")] as we've already researched all the technology they know!", at: c.coord) }
                return
            }
            let remaining = incrementTechStealingProgress(ci, si, city: c)
            civs[ci].spies[si].turnsRemaining = remaining
            if remaining == 0 { stealTech(ci, si, city: c) }
        case "RiggingElections":
            guard let c = city else { set("None"); return }
            civs[ci].spies[si].turnsRemaining = (civ(c.civId)?.civFlags["TurnsTillCityStateElection"] ?? 0) - 1
        case "Coup":
            initiateCoup(ci, si)
        case "Dead":
            let oldName = spy.name
            let fresh = newSpyName(ci)
            civs[ci].spies[si].name = fresh
            set("None")
            civs[ci].spies[si].rank = startingSpyRank(civId)
            notifySpy(civId, "We have recruited a new spy name [\(fresh)] after [\(oldName)] was killed.", at: nil)   // a dead spy is in no city
        case "CounterIntelligence":
            civs[ci].spies[si].turnsRemaining -= 1
        default:
            return
        }
    }

    /// Unciv EspionageManager.endTurn
    func espionageTurn(for civId: Int) {
        guard espionageEnabled, let ci = civIndex(civId), civs[ci].isMajor else { return }
        // Unciv EspionageManager.endTurn is only `for (spy in spyList.toList()) spy.endTurn()`. Our old per-turn
        // spy top-up (which re-counted "Gain an extra spy" every turn) is gone: that unique is a one-time
        // trigger (OneTimeGainSpy in triggerUniques), fired when the building is built or the era is entered.
        for spyId in civs[ci].spies.map({ $0.id }) {
            guard let si = civs[ci].spies.firstIndex(where: { $0.id == spyId }) else { continue }
            migrateLegacySpy(ci, si)
            spyEndTurn(ci, si)
            guard let s2 = civs[ci].spies.firstIndex(where: { $0.id == spyId }) else { continue }
            var sp = civs[ci].spies[s2]
            sp.alive = sp.action != "Dead"
            sp.arriving = ["Moving", "EstablishNetwork"].contains(sp.action) ? max(1, sp.turnsRemaining) : 0
            sp.surveillance = sp.action == "Surveillance"
            if GameState.spySetUpActions.contains(sp.action) { sp.turnsInCity += 1 }
            civs[ci].spies[s2] = sp
        }
    }
}

// MARK: - Unciv CityEspionageManager.removeAllPresentSpies (SpyFleeReason)
extension GameState {

    enum SpyFleeReason: String { case conquered, destroyed, takenOver = "taken over", other }

    /// Unciv CityEspionageManager.removeAllPresentSpies: `getAllStationedSpies()` (every civilization in order, each
    /// one's spies located in the city), the notification, then `spy.moveTo(null)` - back to the hideout with
    /// action None. Ours left the action as it was (a "RiggingElections" spy with no city). The notification is
    /// `spy.addNotification`, given while the spy is still in the city: a LocationAction there and EspionageAction.
    func spiesFlee(fromCity cityId: Int, cityName: String, reason: SpyFleeReason) {
        for ci in civs.indices {
            for si in civs[ci].spies.indices where civs[ci].spies[si].cityId == cityId {
                let name = civs[ci].spies[si].name
                let text = reason == .other ? "Due to the chaos ensuing in [\(cityName)], your spy [\(name)] has fled back to our hideout." : "After the city of [\(cityName)] was \(reason.rawValue), your spy [\(name)] has fled back to our hideout."
                // spy.addNotification before spy.moveTo(null): the city it is fleeing
                notifySpy(civs[ci].id, text, at: city(cityId)?.coord)
                spyMoveToHideout(ci, si)
            }
        }
    }

    /// Unciv Spy.moveTo(null): `location = null; setAction(SpyAction.None)` (turnsRemainingForAction = 0).
    func spyMoveToHideout(_ ci: Int, _ si: Int) {
        civs[ci].spies[si].cityId = nil; civs[ci].spies[si].arriving = 0; civs[ci].spies[si].turnsInCity = 0
        civs[ci].spies[si].action = "None"; civs[ci].spies[si].turnsRemaining = 0
        civs[ci].spies[si].alive = true; civs[ci].spies[si].surveillance = false
    }

    /// Unciv EspionageManager.removeAllSpies ("Called when the civ is destroyed"): `spyList.forEach { it.moveTo(null) }` -
    /// every spy, a dead one included, is back in the hideout with no action.
    func removeAllSpies(civId: Int) {
        guard let ci = civIndex(civId) else { return }
        for si in civs[ci].spies.indices { spyMoveToHideout(ci, si) }
    }
}

// MARK: - Unciv CityStateFunctions.holdElections / TurnManager revolts
extension GameState {

    /// Unciv Spy.getSkillModifierPercent × getEfficiencyModifier.
    func spyElectionStrength(_ spy: Spy, civId: Int, in city: City) -> Double { Double(spySkill(spy)) * spyEfficiency(spy, civId: civId) }

    /// Unciv CityStateFunctions.holdElections: the timer is re-armed first; the spies RIGGING ELECTIONS in the capital
    /// (getAllStationedSpies: every civilization in order) and a neutral party of 20 votes draw one winner with
    /// `randomWeighted(Random((x*y + 123f*turns).toInt()))` - Float weights influence/2 + skill*efficiency, one
    /// nextDouble() against the Float running sum of weight/total. A lost election costs each rigging civ 5 influence;
    /// otherwise every known civ (the city-state's diplomacy order) gets +20 (winner) or -5.
    /// Ours seeded a generator of its own from the capital and the turn, rolled a Double against Double weights and
    /// walked only the majors that had met the city-state.
    func holdElections(cityState csId: Int) {
        guard let ti = civIndex(csId) else { return }
        civs[ti].civFlags["TurnsTillCityStateElection"] = rs.constants.cityStateElectionTurns
        guard let capital = capital(of: csId) else { return }
        var spies: [(civId: Int, spy: Spy)] = []
        for c in civs { for sp in c.spies where sp.cityId == capital.id && sp.action == "RiggingElections" { spies.append((c.id, sp)) } }
        guard !spies.isEmpty else { return }
        electionsHeldCount += 1
        func votesFromSpy(_ p: (civId: Int, spy: Spy)?) -> Float {
            guard let p else { return 20 }
            var votes = Float(civs[ti].influence[p.civId] ?? 0) / 2
            votes += Float(Double(spySkill(p.spy)) * spyEfficiency(p.spy, civId: p.civId))   // ranges from 30 to 90
            return votes
        }
        let parties: [(civId: Int, spy: Spy)?] = spies.map { Optional($0) } + [nil]
        let weights = parties.map { votesFromSpy($0) }
        let pos = uncivPosition(capital.coord)
        let turns = turn - (barbarianPhase ? 0 : 1)   // Unciv gameInfo.turns
        let randomSeed = Float(Int32(truncatingIfNeeded: pos.x) &* Int32(truncatingIfNeeded: pos.y)) + 123 * Float(turns)
        var g = SeededRandom(kotlinSeed: Int32(clamping: Int(randomSeed)))
        let totalWeight = weights.reduce(Float(0), +)
        let randDouble = g.nextDouble()
        var sum: Float = 0
        var winnerIndex = parties.count - 1   // `return this.last()`
        for i in weights.indices { sum += weights[i] / totalWeight; if randDouble <= Double(sum) { winnerIndex = i; break } }
        guard let won = parties[winnerIndex]?.civId else {
            for p in spies {
                addInfluence(cityState: csId, major: p.civId, -5)
                notify(p.civId, "Your spy lost the election in [\(capital.name)]!", category: .Espionage, icons: ["Spy"], coord: capital.coord)
            }
            return
        }
        let csName = civs[ti].nation
        let allyCiv = ally(of: csId)
        let wonName = civ(won)?.nation ?? "?"
        for other in knownCivs(csId) {
            addInfluence(cityState: csId, major: other.id, other.id == won ? 20 : -5)
            if other.id == won { notify(other.id, "Your spy successfully rigged the election in [\(csName)]!", category: .Espionage, icons: ["Spy"], coord: capital.coord) }
            else if spies.contains(where: { $0.civId == other.id }) { notify(other.id, "Your spy lost the election in [\(csName)] to [\(wonName)]!", category: .Espionage, icons: ["Spy"], coord: capital.coord) }
            else if other.id == allyCiv { notify(other.id, "The election in [\(csName)] was rigged by [\(wonName)]!", category: .Espionage, icons: ["Spy"], coord: capital.coord) }
        }
    }

    /// Unciv TurnManager.updateRevolts.
    func updateRevolts(_ civId: Int) {
        guard barbarianCivId != nil, let ci = civIndex(civId) else { return }
        let rebels = civUniques(civId).contains { $0.pattern == "Rebel units may spawn" && conditionalsHold($0, UniqueContext(civId: civId)) }
        if !rebels { civs[ci].civFlags["RevoltSpawning"] = nil; return }
        if civs[ci].civFlags["RevoltSpawning"] == nil {
            // Unciv TurnManager.kt:249-251: `civInfo.state.stateBasedRandom("TurnManager.getTurnsBeforeRevolt").nextInt(3)`
            var g = stateBasedRandom("TurnManager.getTurnsBeforeRevolt", civId: civId)
            let turns = Int(Double(rs.constants.baseTurnsUntilRevolt + g.nextInt(below: 3)) * max(1, speed.modifier))
            civs[ci].civFlags["RevoltSpawning"] = max(1, turns)
        }
    }

    /// Unciv TurnManager.doRevoltSpawn.
    /// Unciv Spy.getEffectiveRank: rank plus "Spies in [cityFilter] cities act as though they have [n] levels for [action]" of the city the spy is in
    /// (filter seen by the spy's owner, action matched case-insensitively), clamped to 1…3.
    func effectiveSpyRank(_ spy: Spy, action: String) -> Int {
        guard let cid = spy.cityId, let city = city(cid) else { return max(1, min(rs.constants.maxSpyRank, spy.rank)) }
        let owner = civs.first(where: { $0.spies.contains { $0.id == spy.id } })?.id ?? city.civId
        let bonus = cityUniques(city).filter { $0.pattern == "Spies in [] cities act as though they have [] levels for []" && cityMatchesFilter($0.param(0), city: city, viewer: owner) && $0.param(2).lowercased() == action.lowercased() }.reduce(0) { $0 + $1.int(1) }
        return max(1, min(rs.constants.maxSpyRank, spy.rank + bonus))
    }

    func doRevoltSpawn(_ civId: Int) {
        guard let ci = civIndex(civId) else { return }
        guard let barbId = barbarianCivId else { civs[ci].civFlags["RevoltSpawning"] = nil; return }   // Unciv: no barbarian civ → removeFlag, return
        let myCities = cities(of: civId)
        // Unciv TurnManager.kt:206: `civInfo.state.stateBasedRandom("TurnManager.doRevoltSpawn")` — asagidaki uc cekim AYNI uretecten sirayla gelir.
        var g = stateBasedRandom("TurnManager.doRevoltSpawn", civId: civId)
        let rebelCount = 1 + g.nextInt(below: 100 + 20 * (myCities.count - 1)) / 100   // Unciv draws the count first
        var bestCity: (city: City, key: Int)? = nil
        // Kotlin maxByOrNull returns a lone element before calling its selector: a one-city civ draws no city key.
        if myCities.count == 1 { bestCity = (myCities[0], 0) } else {
            for c in myCities {
                let k = g.nextInt(below: c.population + 10)   // Unciv TurnManager.kt:208 `random.nextInt(it.population.population + 10)`
                if bestCity == nil || k > bestCity!.key { bestCity = (c, k) }   // Unciv maxByOrNull keeps the first maximum
            }
        }
        guard let spawnCity = bestCity?.city else { return }
        func rate(_ c: HexCoord) -> Int {
            // Unciv rateTileForRevoltSpawn: militaryUnit / civilianUnit block the tile, aircraft do not
            guard let t = map[c], !t.isWater, !units(at: c).contains(where: { !$0.def.isAir }), !t.isCityCenter, !t.isImpassable else { return -1 }
            var score = 10
            if t.improvement == nil { score += 4; if t.resource != nil { score += 3 } }
            // Unciv `tile.getDefensiveBonus() > 0` (includeImprovementBonus = true): a Fort or Citadel counts too
            if t.defensiveBonusF(includeImprovementBonus: true) > 0 { score += 4 }
            return score
        }
        // Unciv `spawnCity.getTiles().maxByOrNull { rateTileForRevoltSpawn(it) }`: getTiles() walks the city's
        // HashSet<HexCoord> (uncivTileWalk), and maxByOrNull keeps the first maximum - ties are common (every plain
        // unimproved tile scores 14). Ours walked the tiles sorted by our own (q, r). placeUnitNearTile relocates
        // if need be.
        guard let spawnTile = uncivTileWalk(spawnCity).max(by: { rate($0) < rate($1) }) else { return }
        // Unciv `ruleset.units.values.asSequence().filter { uniqueTo == null && isMelee() && isLandUnit && !CannotAttack
        // && isBuildable(civInfo) }`: the civ-level BaseUnit.getRejectionReasons(civ, city = null), in Units.json order -
        // a construction the player disabled in the spawn city stays a candidate.
        let candidates = rs.unitOrder.compactMap { rs.units[$0] }.filter { u in
            u.uniqueTo == nil && u.isMelee && u.isLand && !u.cannotAttack && unitRejections(u, civId: civId, city: nil).isEmpty
        }
        var bestUnit: (def: UnitDef, key: Int)? = nil
        // Kotlin maxByOrNull: a lone candidate is returned without a draw
        if candidates.count == 1 { bestUnit = (candidates[0], 0) } else {
            for u in candidates {
                let k = g.nextInt(below: 1000)   // Unciv TurnManager.kt:214 `maxByOrNull { random.nextInt(1000) }`
                if bestUnit == nil || k > bestUnit!.key { bestUnit = (u, k) }
            }
        }
        guard let unitDef = bestUnit?.def else { return }
        var placed = 0
        for _ in 0..<rebelCount where spawnUnit(unitDef.name, civId: barbId, at: spawnTile) != nil { placed += 1 }
        revoltSpawnCount += placed
        // Unciv removes the flag only here, after the spawn: an early return above (no city, tile or unit) leaves
        // it at 0 and the spawn is tried again next turn. It is re-armed while unhappiness stays low enough.
        if let cj = civIndex(civId) { civs[cj].civFlags["RevoltSpawning"] = nil }
        notify(civId, "Your citizens are revolting due to very high unhappiness!", category: .General, icons: [unitDef.name, "StatIcons/Malcontent"], coord: spawnTile)   // Unciv notifies whatever was placed
    }
}
