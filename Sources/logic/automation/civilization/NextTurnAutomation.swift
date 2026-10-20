// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's civilization/NextTurnAutomation.kt.

extension GameState {
    /// Unciv NextTurnAutomation.automateCivMoves – the top-level AI turn.
    func automateCivMoves(_ civId: Int, tradeAndChangeState: Bool = true) {
        guard let civ = civ(civId), civ.isAlive else { return }
        if civ.isBarbarian { barbarianAutomate(civId); return }
        AI.timed("alerts") { respondToPopupAlerts(civId) }   // Unciv automateCivMoves step 2: respondToPopupAlerts
        AI.timed("trade") { respondToTradeRequests(civId, tradeAndChangeState: tradeAndChangeState) }
        if tradeAndChangeState && civ.isMajor {
            AI.timed("war") { diplomacyDeclareWar(civId) }
            AI.timed("peace") { offerPeaceTreaty(civId); askForHelp(civId) }
            AI.timed("friendship") { offerDeclarationOfFriendship(civId) }
            if religionEnabled { AI.timed("faith") { spendFaithOnReligion(civId) } }
            AI.timed("denounce") { diplomacyDenounce(civId) }
            AI.timed("offers") { offerToEstablishEmbassy(civId); offerOpenBorders(civId); offerResearchAgreement(civId); offerDefensivePact(civId) }
            AI.timed("border") { checkMilitaryPresenceNearBorder(civId) }
            AI.timed("offers") { exchangeLuxuries(civId) }   // Unciv: exchangeLuxuries, checkMilitaryPresenceNearBorder'dan sonra
            checkDemandViolations(civId)   // Unciv issueRequests: after exchangeLuxuries, before adoptPolicy
            AI.timed("policy") { adoptPolicyAI(civId) }
            AI.timed("space") { freeUpSpaceResources(civId) }
        } else if civ.isCityState, let ci = civIndex(civId) {
            // Unciv automateCivMoves: a city-state takes its free techs HERE, inside its own turn and before it
            // picks what to research. We granted them once at the end of the whole turn instead, so a city-state
            // finished the tech the majority had already handed it, banked the overflow, and sat out a turn
            // before starting the next one - and then drew its next tech from a different turn's seed.
            AI.timed("citystate") { freeTechsForCityState(ci); updateDiplomaticRelationshipForCityState(civId) }   // Unciv: getFreeTechForCityState, then updateDiplomaticRelationshipForCityState
        }
        AI.timed("research") { chooseTechToResearch(civId) }
        AI.timed("bombard") { automateCityBombardment(civId) }
        if tradeAndChangeState { AI.timed("gold") { useGoldAI(civId) } }
        if tradeAndChangeState && !civ.isCityState { AI.timed("citystates") { protectCityStates(civId); bullyCityStates(civId) } }
        AI.timed("units") { automateUnitsAI(civId) }
        if tradeAndChangeState && civ.isMajor {
            if religionEnabled { AI.timed("beliefs") { chooseReligiousBeliefs(civId) } }
            if settings.espionageEnabled { AI.timed("spies") { automateSpies(civId) } }
        }
        AI.timed("cities") { automateCitiesAI(civId) }
        if tradeAndChangeState { AI.timed("settler") { trainSettlerAI(civId) } }
        tryVoteForDiplomaticVictory(civId)
    }

    /// Unciv NextTurnAutomation.respondToPopupAlerts: every popup waiting for us, in the order it was queued -
    /// demands (respondToDemandAlert) and Declarations of Friendship (respondToDeclarationOfFriendship) mixed - and
    /// then `popupAlerts.clear()`. Ours keeps the two kinds in `pendingDemands` and `pendingOffers`; both take their
    /// id from `newId()` when they are queued, so the id order is the queue order. A friendship offer is answered
    /// here, before respondToTradeRequests, and whatever `tradeAndChangeState` says.
    func respondToPopupAlerts(_ civId: Int) {
        guard let me = civ(civId) else { return }
        // A human (under AutoPlay - automateCivMoves runs for no other human) keeps Unciv's own queue, `popupAlerts`: each
        // alert in the order it came, a demand answered by respondToDemandAlert, a Declaration of Friendship by
        // respondToDeclarationOfFriendship, and then every alert is gone - the ones nobody answers (a war declared, a
        // tech researched, a wonder built...) with them. (Our trade requests sit in the same list: Unciv's tradeRequests,
        // which respondToTradeRequests answers and clears.)
        if me.isPlayer && !epochsAutoplay, let ci = civIndex(civId) {
            for alert in me.popupAlerts {
                if let demand = Demand.allCases.first(where: { $0.demandAlert == alert.type }) {
                    // respondToDemandAlert: `if (demandingCiv.isDefeated()) return`
                    guard let from = Int(alert.value), civ(from)?.isAlive == true else { continue }
                    respondToDemand(demand, from: from, to: civId)
                } else if alert.type == .DeclarationOfFriendship, let from = Int(alert.value) {
                    respondToDeclarationOfFriendship(civId, from: from)
                }
            }
            civs[ci].popupAlerts.removeAll { $0.type != .TradeRequest }
            pendingDemands.removeAll { $0.to == civId }
            return
        }
        enum Alert { case demand(DemandRequest), friendship(TradeOffer) }
        var alerts: [(id: Int, alert: Alert)] = pendingDemands.filter { $0.to == civId }.map { ($0.id, .demand($0)) }
        alerts += pendingOffers.filter { $0.to == civId && $0.give.friendship && $0.want.friendship }.map { ($0.id, .friendship($0)) }
        alerts.sort { $0.id < $1.id }
        // A human's own Declaration of Friendship is the alert alone (offerDeclarationOfFriendship, the importer); one
        // still queued when its turn is automated is answered too, as Unciv walks civInfo.popupAlerts - before the
        // offers made since, which reach a human under automation as pendingOffers
        if me.isPlayer {
            let fromAlerts = me.popupAlerts.filter { $0.type == .DeclarationOfFriendship }.compactMap { Int($0.value) }
                .filter { from in !alerts.contains { if case .friendship(let o) = $0.alert { return o.from == from }; return false } }
                .map { from -> (id: Int, alert: Alert) in var o = TradeOffer(id: -1, from: from, to: civId, turnCreated: turn); o.give.friendship = true; o.want.friendship = true; return (-1, .friendship(o)) }
            alerts = fromAlerts + alerts
        }
        for (_, alert) in alerts {
            switch alert {
            case .demand(let request):
                // respondToDemandAlert: `if (demandingCiv.isDefeated()) return` - the alert is dropped with the rest
                guard civ(request.from)?.isAlive == true else { pendingDemands.removeAll { $0.id == request.id }; continue }
                respondToDemand(request.demand, from: request.from, to: civId)
            case .friendship(let offer):
                pendingOffers.removeAll { $0.id == offer.id }
                respondToDeclarationOfFriendship(civId, from: offer.from)
            }
        }
        // `civInfo.popupAlerts.clear()`: AIs don't care about popups - a demand left over is gone too, and so is every alert
        // a save brought in for this civ (the importer keeps them in its popupAlerts; an export would write them again)
        pendingDemands.removeAll { $0.to == civId }
        if let i = civIndex(civId) { civs[i].popupAlerts.removeAll() }
    }

    /// Unciv NextTurnAutomation.respondToDeclarationOfFriendship
    func respondToDeclarationOfFriendship(_ civId: Int, from requester: Int) {
        guard let me = civ(civId), civ(requester)?.isAlive == true else { return }   // `if (requestingCiv.isDefeated()) return`
        if canDeclareFriendship(civId, requester) && wantsToSignDeclarationOfFriendship(civId, requester) {
            declareFriendship(civId, requester)   // diploManager (ours, towards the requester).signDeclarationOfFriendship()
            notify(requester, "We have signed a Declaration of Friendship with [\(me.nation)]!", category: .Diplomacy, icons: ["Diplomacy", me.nation])
        } else {
            // `diploManager.otherCivDiplomacy().setFlag(DeclinedDeclarationOfFriendship, 10)` - the requester's side
            setFlag(requester, civId, "DeclinedDeclarationOfFriendship", 10)
            notify(requester, "[\(me.nation)] has denied our Declaration of Friendship!", category: .Diplomacy, icons: ["Diplomacy", me.nation])
        }
    }

    /// Unciv NextTurnAutomation.valueCityStateAlliance
    func valueCityStateAlliance(_ civId: Int, _ cityState: Int, includeQuests: Bool = false) -> Int {
        guard let cs = civ(cityState), cs.isCityState, let civ = civ(civId) else { return 0 }
        var value = 0
        let p = personality(of: civId)
        let bonuses = (cs.cityStateType.flatMap { rs.cityStateTypes[$0] }?.allyBonusUniques ?? []).map(Unique.init)
        func canProvide(_ stat: String) -> Bool { bonuses.contains { ($0.stats?[stat] ?? 0) > 0 } }
        if canProvide("Culture") { value += Int(p.culture) - 5 }
        if canProvide("Faith") { value += Int(p.faith) - 5 }
        if canProvide("Production") { value += Int(p.production) - 5 }
        if canProvide("Science") { value += Int(p.science) - 5 }
        if canProvide("Happiness") { if happiness(of: civId) < 10 { value += 10 - happiness(of: civId) }; value += Int(p.happiness) - 5 }
        if canProvide("Food") { value += 5; value += Int(p.food) - 5 }
        if !cs.isAlive || cities(of: cityState).isEmpty || cities(of: civId).isEmpty { return value }
        let ourInfluence = civ.metCivs.contains(cityState) ? Int(influence(of: civId, with: cityState)) : 0   // Unciv getInfluence (−60 at war)
        value += min(10, ourInfluence / 10)
        if ourInfluence < 30 { value -= 5 }
        if let a = ally(of: cityState), a != civId { value -= (Int(influence(of: a, with: cityState)) - 30) / 10 }
        // Unciv counts the city-state's supply rows whose resource has no row at all on our side - membership,
        // not amount, so a luxury we hold but have traded entirely away still counts as ours.
        let ours = Set(detailedCivResources(civId).map { $0.resource })
        value += detailedCivResources(cityState).filter { rs.resources[$0.resource]?.resourceType == "Luxury" && !ours.contains($0.resource) }.count
        if includeQuests { value += Int(investmentMultiplier(cityState, for: civId) * 10) - 10 }
        return value
    }
    func investmentMultiplier(_ cityState: Int, for civId: Int) -> Double {
        // Unciv getInvestmentMultiplier: the Invest quest's data (e.g. [50]%) for this donor
        guard let q = civ(cityState)?.quests.first(where: { $0.assigneeId == civId && $0.name == "Invest" }) else { return 1 }
        return 1 + (Double(q.target ?? "0") ?? 0) / 100
    }
    /// Unciv NextTurnAutomation.protectCityStates: `getKnownCivs().filter { !it.isDefeated() && it.isCityState }` -
    /// the diplomacy map's order, not the civ list's.
    private func protectCityStates(_ civId: Int) {
        for cs in knownCivs(civId) where cs.isCityState && canPledgeProtection(civId, cs.id) { pledgeProtection(civId, cs.id) }
    }
    /// Unciv NextTurnAutomation.bullyCityStates, over the known city-states in the diplomacy map's order.
    private func bullyCityStates(_ civId: Int) {
        for cs in knownCivs(civId) where cs.isCityState {
            if relationshipLevel(cs.id, civId) >= .friend { continue }
            // Unciv bullyCityStates: only city-states we are at plain peace with (a protector's status is not Peace)
            if areAtWar(civId, cs.id) || civ(civId)?.protectedCityStates.contains(cs.id) == true { continue }
            if valueCityStateAlliance(civId, cs.id) > 0 { continue }
            if ProcessInfo.processInfo.environment["TRIBQ"] == civ(civId)?.nation {
                let g = tributeModifiers(from: civId, cs.id, requireWholeList: true).map { "\($0.0.replacingOccurrences(of: " ", with: "_")):\($0.1)" }.joined(separator: ",")
                let w = tributeModifiers(from: civId, cs.id, demandingWorker: true, requireWholeList: true).map { "\($0.0.replacingOccurrences(of: " ", with: "_")):\($0.1)" }.joined(separator: ",")
                print("TRIBE t=\(uncivTurns) \(cs.nation) gold=\(g) worker=\(w)")
                if let cap = capital(of: cs.id) {
                    let range = min(10, max(5, max(map.width, map.height) / 10))
                    let tiles = map.tilesWithin(cap.coord, radius: range).filter { $0 != cap.coord }
                    let near: [String] = tiles.flatMap { c in units(at: c).filter { $0.isMilitary && !$0.def.isAir && $0.civId == civId }.map { u in let p = uncivPosition(c); return "\(u.name)@\(p.x),\(p.y)=\(unitForceEvaluation(u))[\(u.promotions.joined(separator: "+"))]n\(u.numberOfPromotions ?? -1)" } }
                    let own = tiles.flatMap { units(at: $0) }.filter { $0.isMilitary && !$0.def.isAir && $0.civId == cs.id }.reduce(0) { $0 + unitForceEvaluation($1) }
                    print("TRIBFE t=\(uncivTurns) \(cs.nation) w=\(map.width) h=\(map.height) range=\(range) def=\(cityStrength(cap)) own=\(own) near=\(near.joined(separator: " "))")
                }
            }
            if !canDemandTribute(from: civId, cs.id) { continue }
            // Unciv tributeCityStates: a worker when they are willing to give one, otherwise gold
            if tributeWillingness(from: civId, cs.id, demandingWorker: true) > 0 { tributeWorker(from: civId, cs.id) } else { demandTribute(from: civId, cs.id) }
        }
    }
    /// Unciv NextTurnAutomation.chooseTechToResearch
    func chooseTechToResearch(_ civId: Int) {
        guard let i = civIndex(civId) else { return }
        // Unciv Technology.getWeightForAiDecision(civInfo.state): a Float
        func weight(_ t: TechDef) -> Float { aiDecisionWeight(t.uniqueObjects, UniqueContext(civId: civId)) }
        func grouped() -> [[TechDef]] { Dictionary(grouping: researchableTechs(for: civs[i]), by: { $0.cost }).sorted { $0.key < $1.key }.map { $0.value } }
        // Unciv NextTurnAutomation.kt:243: `civInfo.state.stateBasedRandom("NextTurnAutomation.chooseTechToResearch")` —
        // while dongusunun DISINDA bir kez kurulur, butun randomWeighted cekimleri ayni akistan gelir.
        var techRng = stateBasedRandom("NextTurnAutomation.chooseTechToResearch", civId: civId)
        if ProcessInfo.processInfo.environment["TECHCHOICE_CIV"] == civs[i].nation { print("TECHPE t=\(turn) cur=\(civs[i].currentTech ?? "-") free=\(civs[i].freeTechs) queue=\(civs[i].techQueue)") }
        // Unciv `randomWeighted(rng) { it.getWeightForAiDecision(...) }`: one nextDouble per call, zero total included
        func pickWeighted(_ list: [TechDef]) -> TechDef? { uncivRandomWeighted(list, &techRng, weight) }
        while civs[i].freeTechs > 0 {
            let costs = grouped(); guard !costs.isEmpty else { return }
            let most = costs.last { $0.contains { weight($0) > 0 } } ?? costs.last!
            guard let chosen = pickWeighted(most) else { return }
            claimFreeTech(civId: civId, tech: chosen.name)
        }
        if civs[i].currentTech == nil {
            let costs = grouped(); guard !costs.isEmpty else { return }
            let cheapest = costs.first { $0.contains { weight($0) > 0 } } ?? costs.first!
            let pool = (cheapest.count == 1 || costs.count == 1) ? cheapest : cheapest + costs[1]
            if ProcessInfo.processInfo.environment["TECHCHOICE_CIV"] == civs[i].nation {
                var probe = techRng
                print("TECHCE t=\(turn) pool=" + pool.map { "\($0.name):\(weight($0)):\($0.cost)" }.joined(separator: ",") + " draw=\(probe.double())")
            }
            if let t = pickWeighted(pool) { civs[i].currentTech = t.name }
        }
    }
    /// Unciv NextTurnAutomation.adoptPolicy – branch-based priorities from the personality.
    func adoptPolicyAI(_ civId: Int) {
        guard civ(civId) != nil else { return }
        let p = personality(of: civId)
        let victories = preferredVictoryTypes(civId)
        let ctx = UniqueContext(civId: civId)
        // Unciv NextTurnAutomation.kt:288: `civInfo.state.stateBasedRandom("NextTurnAutomation.adoptPolicy")` —
        // while dongusunun DISINDA bir kez kurulur, dal secimi (:340) ve politika secimi (:345) ayni akistan gelir.
        var policyRng = stateBasedRandom("NextTurnAutomation.adoptPolicy", civId: civId)
        // Unciv PolicyManager.branchCompletionMap is a HashMap<PolicyBranch, Int>: PolicyBranch keeps Object's
        // hashCode, which is 1 for every object under the reference's -XX:hashCode=2, so the map walks in the order
        // JavaHash1Set gives the ruleset's branches. `filterKeys` keeps that order and `groupBy` groups in it.
        let branchWalk: [PolicyBranch] = {
            let order = JavaHash1Set.iterationOrder(rs.policyBranches.map { $0.name })
            return order.compactMap { n in rs.policyBranches.first { $0.name == n } }
        }()
        var guardCount = 0
        while let civ = self.civ(civId), canAffordPolicy(civ), guardCount < 1000 {   // Unciv: while canAdoptPolicy() (the guard only prevents a runaway loop)
            guardCount += 1
            let incomplete = rs.policyBranches.filter { b in b.policies.contains { canAdopt(civ, policy: $0) } }   // Unciv: branches with an adoptable policy
            let adoptable = rs.policyBranches.filter { canOpenBranch(civ, $0) }
            if incomplete.isEmpty && adoptable.isEmpty { return }
            // Unciv PolicyManager.priorityMap: `((victoryPriority + personalityPriority) * branch.getWeightForAiDecision(state)).roundToInt()`
            // - an Int times a Float, rounded half up.
            func priority(_ b: PolicyBranch) -> Int {
                let victoryPriority = victories.reduce(0) { $0 + (b.priorities[$1] ?? 0) }
                let personalityPriority = Int(p.priorities[b.name] ?? 0)
                let product = Float(victoryPriority + personalityPriority) * aiDecisionWeight(b.uniqueObjects, ctx)
                return Stats.roundToInt(Double(product))
            }
            if ProcessInfo.processInfo.environment["POLTRACE"] == civ.nation {
                let pr: [String] = rs.policyBranches.map { b in "\(b.name):\(priority(b))" }
                let inc: [String] = incomplete.map { $0.name }, ad: [String] = adoptable.map { $0.name }
                print("POLT t=\(turn) victories=\(victories) prio=\(pr.joined(separator: ",")) incomplete=\(inc.joined(separator: ",")) adoptable=\(ad.joined(separator: ","))")
            }
            var maxIncomplete = incomplete.map(priority).max()
            var maxAdoptable = adoptable.map(priority).max()
            if maxIncomplete == nil { maxIncomplete = (maxAdoptable ?? 0) - 1 }
            if maxAdoptable == nil { maxAdoptable = maxIncomplete! - 1 }
            let candidateNames: Set<String> = Set((maxAdoptable! <= maxIncomplete! ? incomplete.filter { priority($0) == maxIncomplete! } : adoptable.filter { priority($0) == maxAdoptable! }).map { $0.name })
            guard !candidateNames.isEmpty else { return }
            // `candidateCompletionMap.asIterable().groupBy { it.key.policies.size - it.value }.minByOrNull { it.key }!!.value.random(rng)`
            func remaining(_ b: PolicyBranch) -> Int { b.policies.count - b.policies.filter { civ.policies.contains($0.name) }.count }
            let candidates = branchWalk.filter { candidateNames.contains($0.name) }
            let minRemaining = candidates.map(remaining).min()!
            guard let target = policyRng.pick(candidates.filter { remaining($0) == minRemaining }) else { return }   // Unciv :340
            if canOpenBranch(civ, target) { if !adopt(civId: civId, branch: target.name) { return } ; continue }
            let options = target.policies.filter { canAdopt(civ, policy: $0) }
            // Unciv :345 `randomWeighted(rng) { it.getWeightForAiDecision(civInfo.state) }` - draws even when every weight is zero
            guard let pol = uncivRandomWeighted(options, &policyRng, { self.aiDecisionWeight($0.uniqueObjects, ctx) }) else { return }
            if !adopt(civId: civId, policy: pol.name) { return }
        }
    }
    /// Unciv NextTurnAutomation.automateUnits
    func automateUnitsAI(_ civId: Int) {
        let atWar = isAtWarAtAll(civId)
        // Unciv sortedBy kararlidir: esit oncelikli birimler ilk siralarini korur.
        // Unciv `val sortedUnits = civInfo.units.getCivUnits().sortedBy { ... }` is a lazy Sequence: every `for`
        // over it re-reads the unit list and re-sorts with the priorities of that moment. A unit promoted in the
        // first pass (numberOfPromotions + 1) moves up in the next - Yerevan's new trireme went before the older
        // one and stayed put instead of sliding into the tile the older one left.
        // The sequence is also bound to the unit LIST of that moment: `getCivUnits()` is `unitList.asSequence()`,
        // and UnitManager replaces the list on every add or remove instead of editing it. A unit captured, bought
        // or upgraded during the passes is on the new list only and waits for next turn; an upgraded unit keeps
        // its id here, so the snapshot remembers the name as well and a renamed unit is the new object.
        let snapshot: [(id: Int, name: String)] = units(of: civId).map { ($0.id, $0.name) }
        func sortedNow() -> [Unit] {
            snapshot.compactMap { s in unit(s.id).flatMap { $0.name == s.name && $0.civId == civId ? $0 : nil } }
                .enumerated().sorted { a, b in
                    let pa = unitPriority(a.element, atWar: atWar), pb = unitPriority(b.element, atWar: atWar)
                    return pa != pb ? pa < pb : a.offset < b.offset
                }.map { $0.element }
        }
        func stillSame(_ u: Unit) -> Bool { unit(u.id).map { $0.name == u.name && $0.civId == civId } ?? false }
        // Unciv `civInfo.getKnownCivs().filter { it.isAtWarWith(civInfo) }.flatMap { it.cities }` - the known
        // civs in the diplomacy map's order.
        let citiesRequiringManualPlacement = knownCivs(civId).filter { areAtWar(civId, $0.id) }.flatMap { cities(of: $0.id) }.filter { c in map.tilesWithin(c.coord, radius: 4).filter { militaryUnitOn($0)?.civId == civId }.count > 4 }   // Unciv `tile.militaryUnit?.civ == civInfo`: aircraft never count
        let sorted = sortedNow()
        if epochsTradeDbg { print("ORDER t=\(turn) \(civ(civId)?.nation ?? "?") " + sorted.map { "\($0.name)@\(uncivPosition($0.coord).x),\(uncivPosition($0.coord).y)=\(unitPriority($0, atWar: isAtWarAtAll(civId)))" }.joined(separator: " ")) }
        for u in sorted where stillSame(u) { applyPromotions(u.id) }
        // Unciv `unit.hasUnique(SpaceshipPart) || unit.hasUnique(FoundCity)`: the unit's own uniques with their
        // conditionals in cache.state, asked of the live unit when its turn in the pass comes. Spain's Conquistador
        // ("Founds a new city <on foreign continents>") on its home continent is not a settler here and moves in the
        // last pass - and one that went abroad and came back moves again there. FoundPuppetCity is not asked.
        func movesEarly(_ x: Unit) -> Bool { unitHasUnique(x, "Spaceship part") || unitHasUnique(x, "Founds a new city") }
        for u in sortedNow() { if stillSame(u), let now = unit(u.id), movesEarly(now) { automateUnitMoves(u.id) } }
        if !cities(of: civId).isEmpty { automateSettlerEscorting(civId) }
        for city in citiesRequiringManualPlacement { automateCityConquer(civId, city) }
        for u in sortedNow() { if stillSame(u), let now = unit(u.id), !movesEarly(now) { automateUnitMoves(u.id) } }   // Unciv: a spent unit still decides
    }
    /// Unciv NextTurnAutomation.applyPromotions
    func applyPromotions(_ unitId: Int) {
        var guardCount = 0
        // Unciv NextTurnAutomation.kt:434: the stream is opened ONCE, before the loop, and the same rng draws for
        // every promotion the unit takes in this call. Opening it inside the loop restarted it, so a unit taking
        // two promotions at once drew the first value twice and its second pick was never Unciv's.
        guard let first = unit(unitId) else { return }
        // Unciv NextTurnAutomation.applyPromotions: `if (!unit.civ.isAI() && !settings.automatedUnitsChoosePromotions) return`,
        // before the rng is opened. isAI() is the player type, which autoplay leaves Human, so the player's units
        // stay unpromoted under autoplay as well.
        if civ(first.civId)?.isPlayer == true && !UserSettings.automatedUnitsChoosePromotions { if GameState.evlogOn && promotionsAvailable(first) > 0 { hbr("S3.noAutoPromotion", first.civId) }; return }
        var g = stateBasedRandom("NextTurnAutomation.automateUnits", unit: first)
        while let unit = unit(unitId), promotionsAvailable(unit) > 0, guardCount < 30 {   // Unciv promotes as long as the unit can be promoted
            guardCount += 1
            let promotions = availablePromotions(for: unit)
            // Unciv: OneTimeUnitHeal ("[unitTriggerTarget] heals [positiveAmount] HP") picks the healing ones when
            // the unit is at 60 HP or less; otherwise everything but SkipPromotion. `unit.hasUnique(CanMoveAfterAttacking)`
            // is the MapUnit's own uniques - base unit, type, promotions (Chu-Ko-Nu ability, Logistics), statuses.
            func heals(_ p: PromotionDef) -> Bool { p.uniqueObjects.contains { $0.pattern == "[] heals [] HP" } }
            let available: [PromotionDef] = (unit.health <= 60 && promotions.contains(where: heals) && !(unit.def.isAir || unitHasUnique(unit, "Can move after attacking"))) ? promotions.filter(heals) : promotions.filter { !$0.isOneShot }
            if available.isEmpty { return }
            // Unciv NextTurnAutomation.applyPromotions: a promotion that costs nothing is always taken before the others
            let free = available.filter { $0.uniques.contains("This Promotion is free") }
            let pool = free.isEmpty ? available : free
            // Unciv `randomWeighted(rng) { it.getWeightForAiDecision(unit.cache.state) }`: Float weights, one draw per pick
            let ctx = UniqueContext(civId: unit.civId, unit: unit)
            guard let chosen = uncivRandomWeighted(pool, &g, { self.aiDecisionWeight($0.uniqueObjects, ctx) }) else { return }
            promote(unitId: unitId, chosen.name)
        }
    }
    /// Unciv NextTurnAutomation.automateCityConquer
    private func automateCityConquer(_ civId: Int, _ cityAtStart: City) {
        // Unciv holds the City object, so every `city.health` below is the live figure after the attacks before it.
        var city: City { self.city(cityAtStart.id) ?? cityAtStart }
        // Unciv `getTilesInDistance(range).mapNotNull { it.militaryUnit }`: one unit per tile, and never an aircraft -
        // putInTile files air units under `tile.airUnits` - so the "air units first" loop below never runs in Unciv
        func ours(_ range: Int) -> [Unit] { map.tilesWithin(cityAtStart.coord, radius: range).compactMap { militaryUnitOn($0) }.filter { $0.civId == civId && (!$0.def.isMelee || $0.health > 30) } }
        func attackIfPossible(_ u: Unit, _ tile: HexCoord) {
            if let a = attackableEnemies(u, distanceToTiles: distanceToTiles(u), tilesToCheck: [tile]).first { moveAndAttack(u.id, a) }
        }
        for u in ours(7) where u.def.isAir { automateUnitMoves(u.id) }
        if city.health != 1 {
            // Unciv leaves a siege unit that still needs setting up to automateUnitMoves, which chooses its own
            // target; setting it up here and firing at the city centre is a decision Unciv never makes.
            for u in ours(4) where u.def.isProbablySiegeUnit { if !u.def.mustSetUp || u.isSetUp { attackIfPossible(u, city.coord) } }
        }
        // Unciv `meleeUnits.sortedByDescending { it.baseUnit.getForceEvaluation() }` - a stable sort
        let melee = ours(5).filter { $0.def.isMelee }.enumerated().sorted { a, b in
            a.element.def.forceEvaluation != b.element.def.forceEvaluation ? a.element.def.forceEvaluation > b.element.def.forceEvaluation : a.offset < b.offset
        }.map { $0.element }
        for u in melee {
            guard let live = unit(u.id) else { continue }
            if city.health < cityMaxHealth(city) / 5 { attackIfPossible(live, city.coord) }
            guard let live2 = unit(u.id), live2.hasMovement else { continue }
            let targets = map.tilesWithin(city.coord, radius: 4)
            let attackable = attackableEnemies(live2, distanceToTiles: distanceToTiles(live2), tilesToCheck: targets)
            guard !attackable.isEmpty else { continue }
            // Unciv `tile.militaryUnit?.civ == unit.civ` around the target
            let mostSurrounded = attackable.max { a, b in
                // Unciv `tile.militaryUnit?.civ == unit.civ`
                map.neighbors(of: a.tileToAttack).filter { militaryUnitOn($0)?.civId == civId }.count < map.neighbors(of: b.tileToAttack).filter { militaryUnitOn($0)?.civId == civId }.count
            }!
            moveAndAttack(live2.id, mostSurrounded)
        }
    }
    /// Unciv NextTurnAutomation.automateSettlerEscorting
    private func automateSettlerEscorting(_ civId: Int) {
        guard let cap = capital(of: civId) else { return }
        func bestUnitInRange(_ tile: HexCoord, _ range: Int) -> Unit? {
            // Unciv `getTilesInDistance(range).mapNotNull { it.militaryUnit }` - aircraft are never escorts
            map.tilesWithin(tile, radius: range).compactMap { militaryUnitOn($0) }
                .filter { $0.civId == civId && $0.health >= 100 && $0.coord.distance(to: cap.coord) < tile.distance(to: cap.coord) && canReach($0, tile) }
                .enumerated().sorted { a, b in   // Unciv sortedBy kararlidir
                    let da = a.element.coord.distance(to: tile), db = b.element.coord.distance(to: tile)
                    return da != db ? da < db : a.offset < b.offset
                }.map { $0.element }
                .max { $0.def.strength < $1.def.strength }
        }
        for settler in units(of: civId) where settler.isCivilian && settler.def.isSettler {
            guard let escort = bestUnitInRange(settler.coord, 3) else { continue }
            moveUnit(escort.id, toward: settler.coord)
            if let e = unit(escort.id), e.coord != settler.coord, let blocker = units(at: settler.coord).first(where: { $0.isMilitary && $0.civId == civId }), canSwap(e, with: blocker) { swapUnits(e.id, blocker.id) }
        }
    }
    /// Unciv NextTurnAutomation.getUnitPriority
    func unitPriority(_ u: Unit, atWar: Bool) -> Int {
        if u.def.isSpaceshipPart { return 0 }
        if u.isCivilian && u.def.isSettler { return 1 }
        if u.isCivilian && !u.isGreatPersonOfWar { return 2 }
        // Unciv `unit.canIntercept()` is MapUnit.canIntercept() - a chance above zero, movement and interceptions left
        // now - and `unit.hasUnique(UniqueType.SelfDestructs)` the MapUnit's uniques, its type's included (the Guided
        // Missile has it only on the Missile unit type): fighters 2, nukes 3, bombers 4, missiles 5.
        if u.def.isAir { return canInterceptAtAll(u) ? 2 : u.def.isNuclear ? 3 : !unitHasUnique(u, "Self-destructs when attacking") ? 4 : 5 }
        let distance = atWar ? distanceToClosestEnemyUnit(u.coord, civId: u.civId, maxDist: 6) : 0
        let kind: Int = u.def.isRanged ? 10 : u.def.isMelee ? 30 : u.isGreatPersonOfWar ? 100 : 1
        // Unciv getUnitPriority subtracts `unit.promotions.numberOfPromotions` - the COUNTER of promotions
        // bought with experience - not the size of the promotion list, which also holds the free ones a
        // Barracks or a unit type hands out. Measured on `t_45` turn 57: Byzantium's Scout carries one free
        // promotion, so ours scored it 39 against the Warrior's 40 and moved it first; Unciv scores both 40,
        // and a stable sort leaves the Warrior ahead. The Warrior took the settler's tile as its escort, and
        // Unciv's Scout - finding a military unit already there - did not accompany anyone.
        return distance + u.health / 10 - u.promotionNumber + kind
    }
    func automateCityBombardment(_ civId: Int) { for c in cities(of: civId) { _ = tryBombardEnemy(c) } }
    private func shouldAnnexCity(_ civId: Int, _ city: City) -> Bool {
        // Unciv: `civInfo.getHappiness() >= 5` (the stats.happiness field) for the first bar, and
        // `civInfo.stats.statsForNextTurn.happiness > population * 2 - 8` for the second - the happiness in the
        // stored sum of every city's finalStatList (buildings, city-states, global stat uniques), a different
        // quantity from the empire's happiness. Ours read the turn-start empire happiness there.
        city.isPuppet && city.population > 9 && city.resistanceTurns == 0 && !mayNotAnnexCities(civId) && happiness(of: civId) >= 5
            && (civ(civId)?.statsForNextTurn?.happiness ?? 0) > Double(city.population * 2 - 8)
    }
    /// Unciv NextTurnAutomation.automateCities
    func automateCitiesAI(_ civId: Int) {
        let own = militaryMight(civId)
        let enemies = civsAtWarWith(civId).reduce(0) { $0 + militaryMight($1.id) }
        // Unciv `ownMilitaryStrength < sumOfEnemiesMilitaryStrength * 0.66f`: Int × Float, compared in Float
        let significantlyWeaker = Float(own) < Float(enemies) * Float(0.66)
        if epochsTradeDbg {
            let at = civsAtWarWith(civId).map { "\($0.nation)=\(militaryMight($0.id))" }.joined(separator: ",")
            print("CITYAI t=\(turn) \(civ(civId)?.nation ?? "?") own=\(own) enemies=\(enemies) weak=\(significantlyWeaker) atWar=[\(at)]")
        }
        for city in cities(of: civId) {
            if shouldAnnexCity(civId, city) && !civUniques(civId).contains(where: { $0.pattern == "May not annex cities" }) { annex(cityId: city.id) }
            guard let current = self.city(city.id) else { continue }
            let onSpaceshipPart: Bool = { if case .unit(let n)? = current.currentProduction { return rs.units[n]?.isSpaceshipPart == true }; return false }()
            if current.health < cityMaxHealth(current) || (significantlyWeaker && !onSpaceshipPart) {
                tryTrainMilitaryUnit(current)
                // Unciv `if (city.cityConstructions.constructionQueue.isNotEmpty()) continue` - ANY construction in
                // the queue, a building or a perpetual Science/Gold (or Idle's "Nothing") as much as the unit just chosen.
                // Only an empty queue goes on to chooseNextConstruction.
                if let c2 = self.city(city.id), c2.currentProduction != nil || !c2.convertProductionTo.isEmpty { continue }
            }
            // `city.cityConstructions.chooseNextConstruction()` - CityConstructions', with its gate: a human's city chooses
            // only with auto-assign on or under a full-AI AutoPlay (or as a puppet). A human automated with fullAutoPlayAI
            // off - and the AutoPlay menu's "Economy" outside AutoPlay - leaves an idle city idle; ours chose for it.
            chooseNextConstructionIfAutomated(cityId: city.id)
        }
    }
    /// Unciv NextTurnAutomation.trainSettler
    func trainSettlerAI(_ civId: Int) {
        guard let civ = civ(civId), !civ.isCityState, !(settings.oneCityChallenge && civ.isPlayer) else { return }
        let myCities = cities(of: civId)
        if myCities.isEmpty { return }
        if happiness(of: civId) <= myCities.count { return }
        if isLateGame(civId) {
            // Unciv counts city by city (`for (city in cities) forEachTileInDistance(10) { ... count++ }`): a tile
            // within 10 of two cities counts twice.
            let unoccupied = myCities.flatMap { map.tilesWithin($0.coord, radius: 10) }.filter { c in map[c]?.ownerCivId == nil && map.neighbors(of: c).allSatisfy { map[$0]?.ownerCivId == nil } }.count
            if unoccupied < 6 { return }
        }
        let maxInFlight = 2
        let inFlight = units(of: civId).filter { $0.def.isSettler }.count + myCities.filter { if case .unit(let n)? = $0.currentProduction { return rs.units[n]?.isSettler == true }; return false }.count
        if inFlight >= maxInFlight { return }
        let avoid = personality(of: civId).willNotBuild
        let settlers = rs.availableUnitDefs(for: civ.nation).filter { u in u.isSettler && u.cost > 0 && civ.hasTech(u.requiredTech) && !avoid.contains { productionMatches(.unit(u.name), $0) } }
        guard let settler = settlers.min(by: { $0.cost < $1.cost }) else { return }
        let slack = !isAtWarAtAll(civId) && happiness(of: civId) >= 8 && uncivTurns < 150 && majorCivs.filter { $0.isAlive }.count >= 3
        if units(of: civId).filter({ $0.isMilitary }).count < myCities.count && !slack { return }
        let best = myCities.filter { !$0.isPuppet && $0.population >= 3 }.filter { c in if case .unit(let n)? = c.currentProduction { return rs.units[n]?.isSettler != true }; return true }
            .max { currentCityStats($0.id).total.production < currentCityStats($1.id).total.production }
        guard let city = best, city.builtBuildingObjects.count > 1, let ci = cityIndex(city.id) else { return }   // getBuiltBuildings().count() > 1
        // Unciv setCurrentConstruction: only the head of the queue is replaced - a trailing perpetual stays
        if cities[ci].currentProduction == nil { cities[ci].convertProductionTo = "" }
        cities[ci].currentProduction = .unit(settler.name)
    }
    /// Unciv NextTurnAutomation.tryVoteForDiplomaticVictory
    private func tryVoteForDiplomaticVictory(_ civId: Int) {
        guard mayVoteForDiplomaticVictory(civId), let civ = civ(civId) else { return }
        var chosen: Int? = nil
        if civ.isMajor {
            let known = knownCivs(civId).filter { $0.isMajor }
            if let highest = known.map({ opinion(of: civId, toward: $0.id) }).max() {
                // Abstain if we hate everybody (proportional chance in the Enemy range - lesser evil).
                // Unciv NextTurnAutomation.kt:636 `civ.state.stateBasedRandom("NextTurnAutomation.tryVoteForDiplomaticVictory")` — :646 ve :650 ayni uretecten.
                var g = stateBasedRandom("NextTurnAutomation.tryVoteForDiplomaticVictory", civId: civId)
                if !(highest < -80 || (highest < -40 && highest + Double(g.nextInt(below: 40)) < -40)) { chosen = g.pick(known.filter { opinion(of: civId, toward: $0.id) == highest })?.id }
            }
        } else { chosen = ally(of: civId) }
        diplomaticVoteForCiv(civId, chosen)
    }
}


/// Thin facade over the Unciv automation port in Game/Automation. Kept so existing call sites
/// (`AI(state:civId:).takeTurn()`, `promoteIfPossible`, `explore`, `actWorker`) still work.
struct AI {
    let state: GameState
    let civId: Int
    /// The `--debug` PROFILE table. With the UI the next turn is played on its own thread while the world screen's reads
    /// (computeStats) count into it too: every access holds the lock, an in-place `+=` or `removeAll` included.
    static var profile: [String: Double] {
        get { profileLock.lock(); defer { profileLock.unlock() }; return profileTable }
        _modify { profileLock.lock(); defer { profileLock.unlock() }; yield &profileTable }
        set { profileLock.lock(); defer { profileLock.unlock() }; profileTable = newValue }
    }
    private static let profileLock = NSLock()
    nonisolated(unsafe) private static var profileTable: [String: Double] = [:]
    @inline(__always) static func timed(_ key: String, _ body: () -> Void) {
        guard epochsDebug else { body(); return }
        let t = Date(); body(); profile[key, default: 0] += Date().timeIntervalSince(t)
    }

    @inline(__always) static func timedBool(_ key: String, _ body: () -> Bool) -> Bool {
        guard epochsDebug else { return body() }
        let t = Date(); let r = body(); profile[key, default: 0] += Date().timeIntervalSince(t); return r
    }

    var civ: Civilization? { state.civ(civId) }

    /// Unciv NextTurnAutomation.automateCivMoves
    func takeTurn() { state.automateCivMoves(civId) }

    /// Unciv NextTurnAutomation.applyPromotions / UnitAutomation promotion choice
    func promoteIfPossible(_ u: Unit) { state.applyPromotions(u.id) }

    /// Unciv UnitAutomation.automatedExplore for a human-owned unit on the Explore order.
    @discardableResult
    func explore(_ u: Unit) -> Bool { state.automatedExplore(u.id); return state.unit(u.id)?.order == .explore }

    /// Unciv WorkerAutomation.automateWorkerAction for a human-owned automated worker.
    func actWorker(_ u: Unit) {
        // Unciv: the same entry point the AI uses, so the worker flees when it must
        if u.def.isWater && u.isCivilian { _ = state.automateWorkBoats(u.id) } else { state.automateCivilianUnit(u.id, dangerousTiles: state.dangerousTilesForCivilian(u)) }
    }
}
