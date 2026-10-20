// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's civilization/DiplomacyAutomation.kt, MotivationToAttackAutomation.kt,
// DeclareWarPlanEvaluator.kt, DeclareWarTargetAutomation.kt, TradeAutomation.kt, UseGoldAutomation.kt
// and the parts of logic/trade/TradeEvaluation.kt the AI needs.

extension GameState {
    // MARK: - random per (civ, other, context, turn) like Unciv getRandom
    /// Unciv `DiplomacyAutomation.getRandom`:
    ///   `Random(hashOf(context.hashCode(), civInfo.civID.hashCode(), otherCiv.civID.hashCode(), gameInfo.turns))`
    /// and the caller then takes `(1..10).random(rng)`, which is Kotlin's `nextInt(from, until)`.
    /// This was a hash of our own invention, seeded from our integer civ ids - so every diplomatic roll came out
    /// somewhere else than Unciv's, and whole decisions (an embassy offered, a pact proposed) simply never fired.
    /// `civID` is the civ's name string; `turns` is Unciv's counter, one behind ours, as in `contextHash`.
    func diplomacyRoll(_ civId: Int, _ other: Int, _ context: String, _ range: ClosedRange<Int>) -> Int {
        let seed = hashOf(javaStringHash(context),
                          civ(civId).map { javaStringHash($0.nation) } ?? 0,
                          civ(other).map { javaStringHash($0.nation) } ?? 0,
                          Int32(truncatingIfNeeded: turn - 1))
        var rng = SeededRandom(kotlinSeed: seed)
        return range.lowerBound + rng.nextInt(below: range.count)
    }

    /// Queue an AI proposal; humans get a notification, AIs answer in respondToTradeRequests on their turn.
    /// Unciv `otherCiv.tradeRequests.add(TradeRequest(...))`: an ArrayList - an identical request made twice is
    /// there twice and answered twice. Ours dropped the second copy.
    func queueOffer(_ offer: TradeOffer) {
        pendingOffers.append(offer)
        // POPUPLOG: Unciv `otherCiv.tradeRequests.add` - or, for a Declaration of Friendship, `otherCiv.popupAlerts.add`
        if GameState.evlogOn, civ(offer.to)?.isPlayer == true {
            if offer.isFriendshipRequest { ev(offer.to, "POPUP", AlertType.DeclarationOfFriendship.rawValue, EvLog.name(civ(offer.from)?.nation ?? "civ\(offer.from)")) }
            else { let t = evTradeRequestText(offer); let c = t.firstIndex(of: ":")!; ev(offer.to, "TREQ", String(t[..<c]), String(t[t.index(after: c)...])) }
        }
        if civ(offer.to)?.isPlayer == true { addAlert(offer.to, .TradeRequest, "\(offer.id)") }   // Unciv WorldScreen: one TradePopup per pending request
    }

    /// Kotlin `Float.toInt()`: truncation, saturating, NaN -> 0.
    func kotlinToInt(_ f: Float) -> Int { f.isNaN ? 0 : f >= Float(Int32.max) ? Int(Int32.max) : f <= Float(Int32.min) ? Int(Int32.min) : Int(f) }
    /// Kotlin `Float.coerceAtLeast(min)`: `if (this < min) min else this` - a NaN stays NaN.
    fileprivate func coerceAtLeastF(_ x: Float, _ m: Float) -> Float { x < m ? m : x }

    /// Kotlin `sortedByDescending { key }`: a stable sort, equal keys keep their order. Each key is taken once - and none
    /// for a list of one or none: Kotlin's sortedWith returns `toList()` when `size <= 1` without comparing, so a key with a
    /// side effect (getStatForRanking(Force) fills cachedMilitaryMight) is not taken. Ours took it: a civ at war with one
    /// major had that enemy's Force cached in askForHelp, before its units fought (raging t=96: 196 where Unciv's later
    /// read gave 176), and automateCities' "significantly weaker" check then trained a Catapult in London.
    func sortedDescendingStable<T, K: Comparable>(_ a: [T], _ key: (T) -> K) -> [T] {
        if a.count <= 1 { return a }
        return a.enumerated().map { ($0.offset, key($0.element), $0.element) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map { $0.2 }
    }

    /// Unciv ThreatManager.getNeighboringCivilizations as the LinkedHashSet it is: in the order our cities'
    /// neighbouring cities bring the civs up, known civs only.
    func neighboringCivilizationsInOrder(_ civId: Int) -> [Int] {
        guard let me = civ(civId) else { return [] }
        var seen: Set<Int> = [], out: [Int] = []
        for ours in cities(of: civId) {
            for n in neighboringCities(of: ours) where n.civId != civId && me.metCivs.contains(n.civId) { if seen.insert(n.civId).inserted { out.append(n.civId) } }
        }
        return out
    }

    /// Unciv Civilization.getCivsAtWarWith: `diplomacy.values` at war, the defeated left out - in that map's order.
    func civsAtWarWithInDiplomacyOrder(_ civId: Int) -> [Civilization] {
        guard let me = civ(civId) else { return [] }
        return diplomacyOrder(civId).compactMap { civ($0) }.filter { me.atWarWith.contains($0.id) && $0.isAlive && !$0.isBarbarian }
    }

    /// Unciv DiplomacyAutomation.areWeOfferingTrade: a request of ours to them already carries the offer, on either side.
    private func areWeOfferingTrade(_ civId: Int, _ other: Int, _ has: (TradeSide) -> Bool) -> Bool {
        pendingOffers.contains { $0.from == civId && $0.to == other && (has($0.give) || has($0.want)) }
    }

    // MARK: - DeclareWarTargetAutomation

    /// Unciv DeclareWarTargetAutomation.chooseDeclareWarTarget: by score, highest first (a stable sort).
    func chooseDeclareWarTarget(_ civId: Int, _ civAttackMotivations: [(Int, Float)]) {
        let highestValueTargets = sortedDescendingStable(civAttackMotivations) { scoreRankingForAI($0.0) }
        for (target, motivation) in highestValueTargets {
            if tryDeclareWarWithPlan(civId, target, motivation) { return }   // We have successfully found a plan and started executing it!
        }
    }
    /// Unciv DeclareWarTargetAutomation.tryDeclareWarWithPlan
    private func tryDeclareWarWithPlan(_ civId: Int, _ target: Int, _ motivation: Float) -> Bool {
        if civ(target)?.isCityState != true {
            if motivation > 5 && tryTeamWar(civId, target, motivation) { return true }
            if motivation >= 15 && tryJoinWar(civId, target, motivation) { return true }
        }
        if motivation >= 20 && evaluateDeclareWarPlan(civId, target: target, given: motivation) > 0 { declareWar(civId, on: target); return true }
        // prepareWar: a negative WaryOf marks the planned war
        if motivation >= 15 && evaluateStartPreparingWarPlan(civId, target: target, given: motivation) > 0 { setFlag(civId, target, "WaryOf", -1); return true }
        return false
    }
    /// Unciv tryTeamWar: invite a new ally to declare war on the target together with us.
    private func tryTeamWar(_ civId: Int, _ target: Int, _ motivation: Float) -> Bool {
        let potentialAllies = sortedDescendingStable(commonKnownCivIds(civId, target).compactMap { civ($0) }.filter {
            $0.isMajor && !hasFlag(civId, $0.id, "DeclinedJoinWarOffer") && relationshipLevel(civId, $0.id) >= .neutral && !$0.isAtWar(with: target)
        }) { forceRanking($0.id) }
        for third in potentialAllies {
            if evaluateTeamWarPlan(civId, target: target, teamCiv: third.id, given: motivation) <= 0 { continue }
            tradeLogicInit(civId, third.id)   // Unciv `TradeLogic(civInfo, thirdCiv)`
            var offer = TradeOffer(id: newId(), from: civId, to: third.id, turnCreated: turn)
            offer.give.warOn = target; offer.want.warOn = target
            queueOffer(offer)
            return true
        }
        return false
    }
    /// Unciv tryJoinWar: join an ally already at war with the target.
    private func tryJoinWar(_ civId: Int, _ target: Int, _ motivation: Float) -> Bool {
        let potentialAllies = sortedDescendingStable(commonKnownCivIds(civId, target).compactMap { civ($0) }.filter {
            $0.isMajor && !hasFlag(civId, $0.id, "DeclinedJoinWarOffer") && relationshipLevel(civId, $0.id) >= .favorable && $0.isAtWar(with: target)
        }) { forceRanking($0.id) }
        for third in potentialAllies {
            if evaluateJoinWarPlan(civId, target: target, civToJoin: third.id, given: motivation) <= 0 { continue }
            tradeLogicInit(civId, third.id)   // Unciv `TradeLogic(civInfo, thirdCiv)`
            var offer = TradeOffer(id: newId(), from: civId, to: third.id, turnCreated: turn)
            offer.give.warOn = target
            queueOffer(offer)
            return true
        }
        return false
    }

    // MARK: - DiplomacyAutomation

    /// Unciv DiplomacyAutomation.declareWar
    func diplomacyDeclareWar(_ civId: Int) {
        guard let civ = civ(civId), !cities(of: civId).isEmpty, !civ.metCivs.isEmpty else { return }
        if personality(of: civId).declareWar == 0 { return }
        if happiness(of: civId) <= 0 { return }
        let ourMilitaryUnits = units(of: civId).filter { $0.isMilitary }.count
        if ourMilitaryUnits < cities(of: civId).count { return }
        if ourMilitaryUnits < 4 { return }   // to stop AI declaring war at the beginning of games when everyone isn't set up well enough
        if cities(of: civId).reduce(0, { $0 + $1.population }) < 12 { return }   // FAR too early for that
        // If the AI declares war on a civ without knowing the location of any cities, it'll just keep amassing an army
        let targetCivs = knownCivs(civId).filter { t in
            !(t.id == civId || cities(of: t.id).isEmpty || !canDeclareWar(civId, on: t.id) || !cities(of: t.id).contains { civ.explored.contains($0.coord) })
        }
        if targetCivs.isEmpty { return }
        let targetCivsWithMotivation = targetCivs.map { ($0.id, motivationToAttack(civId, $0.id, atLeast: 0)) }.filter { $0.1 > 0 }
        chooseDeclareWarTarget(civId, targetCivsWithMotivation)
    }
    /// Unciv DiplomacyAutomation.offerPeaceTreaty
    func offerPeaceTreaty(_ civId: Int) {
        guard let me = civ(civId), !civsAtWarWithInDiplomacyOrder(civId).isEmpty, !cities(of: civId).isEmpty, !me.metCivs.isEmpty else { return }
        let enemiesCiv = diplomacyOrder(civId).compactMap { civ($0) }
            .filter { me.atWarWith.contains($0.id) }
            .filter { e in !(e.id == civId || e.isBarbarian || cities(of: e.id).isEmpty || hasFlag(e.id, civId, "DeclaredWar") || hasFlag(civId, e.id, "DeclaredWar")) }
            .filter { !hasFlag(civId, $0.id, "DeclinedPeace") }
            // Don't allow AIs to offer peace to city states allied with their enemies
            .filter { e in !(e.isCityState && (ally(of: e.id).map { areAtWar(civId, $0) } ?? false)) }
            // ignore civs that we have already offered peace this turn as a counteroffer to another civ's peace offer
            .filter { e in !pendingOffers.contains { $0.from == civId && $0.to == e.id && $0.want.peace } }
        for enemy in enemiesCiv {
            if motivationToAttack(civId, enemy.id, atLeast: 10) >= 10 { continue }   // We can still fight. Refuse peace.
            if cities(of: enemy.id).contains(where: { Float($0.health) / Float(cityMaxHealth($0)) < 0.5 }) { continue }   // We are just about to take their city!
            if Float(forceRanking(civId)) - 0.8 * Float(combinedForceOfWarringCivsAI(civId)) > 0 {
                // Unciv: Random(civilizations.indexOf(enemy) + getCivsAtWarWith().count() + 123 * turns).nextInt(100) > 80
                let enemyIndex = civs.firstIndex { $0.id == enemy.id } ?? -1
                var rng = SeededRandom(kotlinSeed: Int32(truncatingIfNeeded: enemyIndex + civsAtWarWithInDiplomacyOrder(civId).count + 123 * (turn - 1)))
                if rng.nextInt(below: 100) > 80 { continue }
            }
            // pay for peace
            tradeLogicInit(civId, enemy.id)   // Unciv `TradeLogic(civInfo, enemy)`
            var offer = TradeOffer(id: newId(), from: civId, to: enemy.id, turnCreated: turn)
            offer.give.peace = true; offer.want.peace = true
            if enemy.isMajor {
                var moneyWeNeedToPay = -evaluatePeaceCostForThem(civId, enemy.id)
                let ourGold = Int(civ(civId)?.gold ?? 0)
                if ourGold > 0 && moneyWeNeedToPay > 0 {
                    if moneyWeNeedToPay > ourGold { moneyWeNeedToPay = ourGold }   // As much as possible
                    offer.give.gold = moneyWeNeedToPay
                } else if moneyWeNeedToPay < -100 {
                    let moneyTheyNeedToPay = min(abs(moneyWeNeedToPay), Int(enemy.gold))
                    if moneyTheyNeedToPay > 0 { offer.want.gold = moneyTheyNeedToPay }
                }
            }
            queueOffer(offer)   // Unciv enemy.tradeRequests.add: answered in the enemy's respondToTradeRequests
        }
    }
    /// Unciv DiplomacyAutomation.askForHelp
    func askForHelp(_ civId: Int) {
        guard let me = civ(civId), !civsAtWarWithInDiplomacyOrder(civId).isEmpty, !cities(of: civId).isEmpty, !me.metCivs.isEmpty else { return }
        let enemyCivs = sortedDescendingStable(civsAtWarWithInDiplomacyOrder(civId).filter { $0.isMajor }) { forceRanking($0.id) }
        for enemyCiv in enemyCivs {
            let potentialAllies = sortedDescendingStable(neighboringCivilizationsInOrder(enemyCiv.id).compactMap { civ($0) }.filter {
                me.metCivs.contains($0.id) && !$0.isAtWar(with: enemyCiv.id)
                    && relationshipLevel(civId, $0.id) >= .friend
                    && !hasFlag($0.id, civId, "DeclinedJoinWarOffer")
            }) { forceRanking($0.id) }
            guard let civToAsk = potentialAllies.first(where: { evaluateJoinOurWarPlan(civId, target: enemyCiv.id, civToJoin: $0.id, given: nil) > 0 }) else { continue }
            tradeLogicInit(civId, civToAsk.id)   // Unciv `TradeLogic(civInfo, civToAsk)`
            var offer = TradeOffer(id: newId(), from: civId, to: civToAsk.id, turnCreated: turn)
            offer.want.warOn = enemyCiv.id
            queueOffer(offer)
        }
    }
    /// Unciv DiplomacyAutomation.offerDeclarationOfFriendship
    func offerDeclarationOfFriendship(_ civId: Int) {
        let p = personality(of: civId)
        let civsThatWeCanDeclareFriendshipWith = sortedDescendingStable(knownCivs(civId).filter {
            canDeclareFriendship(civId, $0.id) && !hasFlag(civId, $0.id, "DeclinedDeclarationOfFriendship")
        }) { relationshipLevel($0.id, civId) }
        for other in civsThatWeCanDeclareFriendshipWith {
            if ProcessInfo.processInfo.environment["DOFTRACE"] != nil {
                print("DOFO t=\(turn) \(civ(civId)?.nation ?? "?")->\(other.nation) roll=\(diplomacyRoll(civId, other.id, "declaration of friendship", 1...10)) limit=\(2 * Float(p.scaledFocus(.diplomacy)))")
            }
            // Default setting is 2, this will be changed according to different civ.
            if Float(diplomacyRoll(civId, other.id, "declaration of friendship", 1...10)) <= 2 * Float(p.scaledFocus(.diplomacy)) && wantsToSignDeclarationOfFriendship(civId, other.id) {
                queueDeclarationOfFriendship(from: civId, to: other.id)
            }
        }
    }
    /// Unciv `otherCiv.popupAlerts.add(PopupAlert(AlertType.DeclarationOfFriendship, civInfo.civID))`
    /// (offerDeclarationOfFriendship): a human's stays in its queue - answered in the popup, or under AutoPlay by its
    /// next automation's respondToPopupAlerts; ours keeps an AI's - and, headless, the player's, an AI there - as a
    /// pending offer, once, which the receiver's respondToPopupAlerts answers first thing in its automateCivMoves.
    func queueDeclarationOfFriendship(from civId: Int, to other: Int) {
        if civ(other)?.isPlayer == true && !epochsAutoplay {
            addAlert(other, .DeclarationOfFriendship, "\(civId)")
        } else if !pendingOffers.contains(where: { $0.from == civId && $0.to == other && $0.give.friendship }) {
            var offer = TradeOffer(id: newId(), from: civId, to: other, turnCreated: turn); offer.give.friendship = true; offer.want.friendship = true
            queueOffer(offer)
        }
    }
    /// Unciv DiplomacyAutomation.wantsToSignDeclarationOfFrienship, in Float as there.
    func wantsToSignDeclarationOfFriendship(_ civId: Int, _ other: Int) -> Bool {
        guard let civ = civ(civId), let o = self.civ(other) else { return false }
        if hasFlag(civId, other, "DeclinedDeclarationOfFriendship") { return false }
        // Shortcut, if it is below favorable then don't consider it
        if relationshipLevel(civId, other) < .favorable { return false }
        let diplomacyFocus = Float(personality(of: civId).scaledFocus(.diplomacy))
        let numOfFriends = diplomacyOrder(civId).filter { hasFlag(civId, $0, "DeclarationOfFriendship") }.count
        let otherCivNumberOfFriends = diplomacyOrder(other).filter { hasFlag(other, $0, "DeclarationOfFriendship") }.count
        let knownCivs = self.knownCivs(civId).filter { $0.isMajor && $0.isAlive }.count
        // Unciv counts every major civ that was ever in the game, so that the dead share is a real number
        let allCivs = civs.filter { $0.isMajor }.count - 1   // Don't include us
        let deadCivs = civs.filter { $0.isMajor && !$0.isAlive }.count
        let allAliveCivs = allCivs - deadCivs

        // Motivation should be constant as the number of civs changes
        var motivation = Float(opinion(of: civId, toward: other)) - 40
        // Warmongerers don't make good allies
        if hasModifier(civId, other, .WarMongerer) { motivation += Float(modifier(civId, other, .WarMongerer)) * diplomacyFocus }
        // If the other civ is stronger than we are compelled to be nice to them
        switch threatAssessment(civId, other) { case .veryHigh: motivation += 10; case .high: motivation += 5; case .veryLow: motivation += -5; default: motivation += 0 }
        // Try to ally with a fourth of the civs in play
        let civsToAllyWith = 0.25 * Float(allAliveCivs) * diplomacyFocus
        if Float(numOfFriends) < civsToAllyWith {
            // Goes from 10 to 0 once the civ gets 1/4 of all alive civs as friends
            motivation += (10 - Float(10 * numOfFriends) / civsToAllyWith)
        } else {
            // Goes from 0 to -120 as the civ gets more friends, offset by civsToAllyWith
            motivation -= (120 * (Float(numOfFriends) - civsToAllyWith) / (Float(knownCivs) - civsToAllyWith))
        }
        // The more friends they have the less we should want to sign friendship (To promote teams)
        motivation -= Float(otherCivNumberOfFriends * 10)
        // Goes from 0 to -50 as more civs die
        motivation -= 50 * Float(deadCivs) / Float(allCivs)
        // Become more desperate as we have more wars
        let wars = diplomacyOrder(civId).filter { (self.civ($0)?.isMajor ?? false) && civ.atWarWith.contains($0) }.count
        motivation += Float(wars * 10)
        // Wait to declare frienships until more civs; goes from -30 to 0 when we know 75% of allCivs
        let civsToKnow = 0.75 * Float(allAliveCivs)
        motivation -= coerceAtLeastF((civsToKnow - Float(knownCivs)) / civsToKnow * 30, 0)
        // If they are the only non-friendly civ near us then they are the only civ to attack and expand into
        if !neighboringCivilizations(civId).contains(where: { $0 != other && (self.civ($0)?.isMajor ?? false) && relationshipLevel(civId, $0) < .favorable }) { motivation -= 20 }
        let beforeAttack = motivation
        motivation -= motivationToAttack(civId, other, atLeast: motivation / 2) * 2
        if ProcessInfo.processInfo.environment["DOFTRACE"] != nil {
            print("DOFE t=\(turn) \(civ.nation)->\(o.nation) opinion=\(opinion(of: civId, toward: other)) threat=\(threatAssessment(civId, other)) friends=\(numOfFriends)/\(otherCivNumberOfFriends) known=\(knownCivs) all=\(allCivs) dead=\(deadCivs) wars=\(wars) neigh=\(neighboringCivilizations(civId).compactMap { self.civ($0)?.nation }) beforeAttack=\(beforeAttack) final=\(motivation)")
        }
        return motivation > 0
    }
    /// Unciv DiplomacyAutomation.offerToEstablishEmbassy
    func offerToEstablishEmbassy(_ civId: Int) {
        guard capital(of: civId) != nil else { return }
        let civsThatWeCanEstablishEmbassyWith = sortedDescendingStable(knownCivs(civId).filter {
            canEstablishEmbassy(civId, with: $0.id) && !hasFlag(civId, $0.id, "DeclinedEmbassy") && !areWeOfferingTrade(civId, $0.id, { $0.embassy })
        }) { relationshipLevel($0.id, civId) }
        for other in civsThatWeCanEstablishEmbassyWith {
            if epochsTradeDbg {
                print("EMBE t=\(turn) \(civ(civId)?.nation ?? "?")->\(other.nation) roll=\(diplomacyRoll(civId, other.id, "embassy", 1...10)) wants=\(wantsToAcceptEmbassy(civId, other.id)) mutual=\(canEstablishEmbassy(other.id, with: civId)) gold=\(Int(civ(civId)?.gold ?? 0)) gpt=\(Int(netGoldPerTurn(civId)))")
            }
            // Default setting is 3
            if diplomacyRoll(civId, other.id, "embassy", 1...10) < 7 { continue }
            if wantsToAcceptEmbassy(civId, other.id) {
                tradeLogicInit(civId, other.id)   // Unciv `TradeLogic(civInfo, otherCiv)`
                var offer = TradeOffer(id: newId(), from: civId, to: other.id, turnCreated: turn)
                offer.want.embassy = true
                // If possible offer mutual embassies (Civ V behavior) so we don't waste gold
                if canEstablishEmbassy(other.id, with: civId) { offer.give.embassy = true }
                else {
                    // Otherwise offer GPT (prefered) or flat gold for embassy in their capital: evaluateBuyCostWithInflation,
                    // `(evaluateBuyCost / getGoldInflation).toInt()` - the buy cost is already an Int there.
                    var embassyOnly = TradeSide(); embassyOnly.embassy = true
                    let embassyValue = Int(Double(evaluateBuyCost(embassyOnly, civId: civId, partner: other.id, offer: offer)) / goldInflation(civId))
                    let embassyGptValue = embassyValue / speed.dealDuration
                    let ourGpt = Int(netGoldPerTurn(civId))
                    if embassyGptValue >= 1 && embassyGptValue <= ourGpt { offer.give.goldPerTurn = embassyGptValue }
                    else if let me = self.civ(civId), me.gold >= Double(embassyValue) && ourGpt >= 0 { offer.give.gold = embassyValue }
                    // else let them make counter offer
                }
                queueOffer(offer)   // Unciv otherCiv.tradeRequests.add: answered on the recipient's turn
            } else {
                setFlag(civId, other.id, "DeclinedEmbassy", 5)   // Remember this for a few turns to save computation power
            }
        }
    }
    /// Unciv DiplomacyAutomation.wantsToAcceptEmbassy: does `other` want to accept our embassy in their capital?
    func wantsToAcceptEmbassy(_ civId: Int, _ other: Int) -> Bool {
        if hasFlag(civId, other, "DeclinedEmbassy") { return false }
        if relationshipLevel(other, civId) < .afraid { return false }
        guard let ourCap = capital(of: civId), let theirCap = capital(of: other), let o = civ(other), let c = civ(civId) else { return false }
        // Being able to see their capital can give us an advantage later on, especially with espionage enabled
        if !o.explored.contains(ourCap.coord) { return true }
        // Did they not discovered our capital yet?
        if !c.explored.contains(theirCap.coord) {
            // If we're afraid of them deny embassy
            if relationshipLevel(other, civId) == .afraid { return false }
            // If they're much stronger than us deny embassy
            let ourCombatStrength = forceRanking(civId), theirCombatStrength = forceRanking(other)
            let percentageAdvantage = Float(ourCombatStrength - theirCombatStrength) / Float(theirCombatStrength)
            if Double(percentageAdvantage) > 0.5 { return false }
        }
        return true // Relationship is Afraid or greater
    }
    /// Unciv `civInfo.hasUnique(UniqueType.EnablesOpenBorders)` as the trade code reads it (from the techs).
    private func enablesOpenBorders(_ civId: Int) -> Bool {
        civ(civId)?.techs.contains(where: { rs.techs[$0]?.uniqueObjects.contains(where: { $0.pattern == "Enables Open Borders agreements" }) == true }) ?? false
    }
    /// Unciv DiplomacyAutomation.offerOpenBorders
    func offerOpenBorders(_ civId: Int) {
        if !enablesOpenBorders(civId) { return }
        if ProcessInfo.processInfo.environment["OBTRACE"] != nil {
            for o in knownCivs(civId) where o.isMajor {
                print("OBO t=\(turn) \(civ(civId)?.nation ?? "?")->\(o.nation) war=\(areAtWar(civId, o.id)) can=\(canOpenBorders(civId, o.id))/\(canOpenBorders(o.id, civId)) open=\(hasOpenBorders(civId, in: o.id))/\(hasOpenBorders(o.id, in: civId)) declined=\(hasFlag(civId, o.id, "DeclinedOpenBorders")) roll=\(diplomacyRoll(civId, o.id, "open borders", 1...10)) pending=\(pendingOffers.contains(where: { $0.from == civId && $0.to == o.id && $0.give.openBorders }))")
            }
        }
        let civsThatWeCanOpenBordersWith = sortedDescendingStable(knownCivs(civId).filter { o in
            o.isMajor && !areAtWar(civId, o.id) && enablesOpenBorders(o.id)
                && !hasOpenBorders(civId, in: o.id) && !hasOpenBorders(o.id, in: civId)
                && advancedDiplomacyAllowed(civId, o.id)   // meetsEmbassyRequirementFor
                && !hasFlag(civId, o.id, "DeclinedOpenBorders")
                && !areWeOfferingTrade(civId, o.id, { $0.openBorders })
        }) { relationshipLevel($0.id, civId) }
        for other in civsThatWeCanOpenBordersWith {
            // Default setting is 3
            if diplomacyRoll(civId, other.id, "open borders", 1...10) < 7 { continue }
            if ProcessInfo.processInfo.environment["OBTRACE"] != nil {
                let theirCities = cities(of: other.id); let vis = visibleTiles(for: civId)
                let friendsAtWar = diplomacyOrder(civId).contains(where: { relationshipLevel(civId, $0) >= .friend && (civ($0)?.isAtWar(with: other.id) ?? false) })
                let atLeast = Float(opinion(of: civId, toward: other.id)) * Float(personality(of: civId).scaledFocus(.commerce)) / 2
                print("OBWE t=\(uncivTurns) \(civ(civId)?.nation ?? "?")->\(other.nation) rel=\(relationshipLevel(civId, other.id)) friendsAtWar=\(friendsAtWar) hidden=\(theirCities.filter { !vis.contains($0.coord) }.count)/\(theirCities.count) motiv=\(motivationToAttack(civId, other.id, atLeast: atLeast))")
            }
            if wantsToOpenBorders(civId, other.id) {
                tradeLogicInit(civId, other.id)   // Unciv `TradeLogic(civInfo, otherCiv)`
                var offer = TradeOffer(id: newId(), from: civId, to: other.id, turnCreated: turn); offer.give.openBorders = true; offer.want.openBorders = true
                queueOffer(offer)
            } else { setFlag(civId, other.id, "DeclinedOpenBorders", 5) }   // Remember this for a few turns to save computation power
        }
    }
    /// Unciv DiplomacyAutomation.wantsToOpenBorders, in Float as there.
    func wantsToOpenBorders(_ civId: Int, _ other: Int) -> Bool {
        if hasFlag(civId, other, "DeclinedOpenBorders") { return false }
        if relationshipLevel(civId, other) < .favorable { return false }
        if ProcessInfo.processInfo.environment["OBTRACE"] != nil {
            let fr: [String] = knownCivs(civId).map { c in "\(c.nation):\(relationshipLevel(civId, c.id)):war=\(c.isAtWar(with: other))/\(areAtWar(c.id, other))" }
            print("OBT t=\(turn) \(civ(civId)?.nation ?? "?")->\(civ(other)?.nation ?? "?") \(fr.joined(separator: ","))")
            for c in knownCivs(civId) where c.isMajor {
                let m: [String] = (civ(civId)?.opinions[c.id] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }
                let b: [String] = (c.opinions[civId] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }
                print("MODE t=\(turn) \(civ(civId)?.nation ?? "?")->\(c.nation) \(m.joined(separator: ",")) | back \(b.joined(separator: ","))")
            }
        }
        // Don't accept if they are at war with our friends, they might use our land to attack them
        if diplomacyOrder(civId).contains(where: { relationshipLevel(civId, $0) >= .friend && (civ($0)?.isAtWar(with: other) ?? false) }) { return false }
        // Being able to see their cities can give us an advantage later on, especially with espionage enabled
        let theirCities = cities(of: other)
        let vis = visibleTiles(for: civId)
        if Float(theirCities.filter { !vis.contains($0.coord) }.count) > Float(theirCities.count) * 0.8 { return true }
        let atLeast = Float(opinion(of: civId, toward: other)) * Float(personality(of: civId).scaledFocus(.commerce)) / 2
        if motivationToAttack(civId, other, atLeast: atLeast) > 0 { return false }
        return true
    }
    /// Unciv DiplomacyAutomation.offerResearchAgreement – always offered when possible (Unciv dropped the old
    /// ~50% roll), to the civs with the most science first.
    func offerResearchAgreement(_ civId: Int) {
        let civsThatWeCanSignResearchAgreementWith = sortedDescendingStable(knownCivs(civId).filter {
            canResearchAgreement(civId, $0.id) && !hasFlag(civId, $0.id, "DeclinedResearchAgreement") && !areWeOfferingTrade(civId, $0.id, { $0.researchAgreement })
        }) { c -> Float in Float(c.statsForNextTurn?.science ?? scienceOutput(for: c.id)) }   // it.stats.statsForNextTurn.science
        for other in civsThatWeCanSignResearchAgreementWith {
            tradeLogicInit(civId, other.id)   // Unciv `TradeLogic(civInfo, otherCiv)`, before the cost
            // Unciv: `val cost = getResearchAgreementCost(otherCiv)`, one TradeOffer(researchAgreement, Treaty, cost) in both lists
            let cost = Int(researchAgreementCost(civId, with: other.id))
            var offer = TradeOffer(id: newId(), from: civId, to: other.id, turnCreated: turn); offer.give.researchAgreement = true; offer.want.researchAgreement = true
            offer.give.researchAgreementCost = cost; offer.want.researchAgreementCost = cost
            queueOffer(offer)
        }
    }
    /// Unciv DiplomacyAutomation.offerDefensivePact
    func offerDefensivePact(_ civId: Int) {
        let p = personality(of: civId)
        let civsThatWeCanSignDefensivePactWith = knownCivs(civId).filter {
            canSignDefensivePact(civId, $0.id) && !hasFlag(civId, $0.id, "DeclinedDefensivePact")
                && Float(opinion(of: civId, toward: $0.id)) > 70 * Float(p.inverseScaledFocus(.aggressive))
                && !areWeOfferingTrade(civId, $0.id, { $0.defensivePact })
        }
        for other in civsThatWeCanSignDefensivePactWith {
            // Default setting is 3, this will be changed according to different civ.
            if Float(diplomacyRoll(civId, other.id, "defensive pact", 1...10)) <= 7 * Float(p.inverseScaledFocus(.loyal)) { continue }
            if wantsToSignDefensivePact(civId, other.id) {
                tradeLogicInit(civId, other.id)   // Unciv `TradeLogic(civInfo, otherCiv)`
                var offer = TradeOffer(id: newId(), from: civId, to: other.id, turnCreated: turn); offer.give.defensivePact = true; offer.want.defensivePact = true
                queueOffer(offer)
            } else { setFlag(civId, other.id, "DeclinedDefensivePact", 5) }   // Remember this for a few turns to save computation power
        }
    }
    /// Unciv DiplomacyAutomation.wantsToSignDefensivePact, in Float as there.
    func wantsToSignDefensivePact(_ civId: Int, _ other: Int) -> Bool {
        guard civ(civId) != nil, civ(other) != nil else { return false }
        if hasFlag(civId, other, "DeclinedDefensivePact") { return false }
        let p = personality(of: civId)
        let opinion = Float(self.opinion(of: civId, toward: other))
        if opinion < 65 * Float(p.inverseScaledFocus(.aggressive)) { return false }
        for third in commonKnownCivIds(civId, other) {
            // If they have bad relations with any of our friends, don't consider it
            if hasFlag(civId, third, "DeclarationOfFriendship") && relationshipLevel(third, other) < .favorable { return false }
            // If they have bad relations with any of our friends, don't consider it
            if hasFlag(other, third, "DeclarationOfFriendship") && relationshipLevel(third, civId) < .neutral { return false }
        }
        let defensivePacts = diplomacyOrder(civId).filter { hasFlag(civId, $0, "DefensivePact") }.count
        let otherCivNonOverlappingDefensivePacts = diplomacyOrder(other).filter { hasFlag(other, $0, "DefensivePact") && !hasFlag($0, civId, "DefensivePact") }.count
        let allCivs = civs.filter { $0.isMajor }.count - 1   // Don't include us
        let deadCivs = civs.filter { $0.isMajor && !$0.isAlive }.count
        let allAliveCivs = allCivs - deadCivs

        // We have to already be at RelationshipLevel.Ally, so we must have 80 oppinion of them
        var motivation = opinion - 80
        // Warmongerers don't make good allies
        if hasModifier(civId, other, .WarMongerer) { motivation += Float(modifier(civId, other, .WarMongerer)) * Float(p.scaledFocus(.diplomacy)) }
        // If they are stronger than us, then we value it a lot more
        switch threatAssessment(civId, other) { case .veryHigh: motivation += 10; case .high: motivation += 5; case .low: motivation += -3; case .veryLow: motivation += -7; default: motivation += 0 }
        // If they have a defensive pact with another civ then we would get drawn into their battles as well
        motivation -= Float(15 * otherCivNonOverlappingDefensivePacts)
        // Become more desperate as we have more wars
        motivation += Float(diplomacyOrder(civId).filter { (civ($0)?.isMajor ?? false) && (civ(civId)?.atWarWith.contains($0) ?? false) }.count * 5)
        // Try to have a defensive pact with 1/5 of all civs
        let civsToAllyWith = 0.20 * Float(allAliveCivs) * Float(p.scaledFocus(.diplomacy))
        // Goes from 0 to -40 as the civ gets more allies, offset by civsToAllyWith
        motivation -= coerceAtLeastF(40 * (Float(defensivePacts) - civsToAllyWith) / (Float(allAliveCivs) - civsToAllyWith), 0)
        return motivation > 0
    }
    /// Unciv DiplomacyAutomation.denounce – denounce when opinion drops faster than the smoothed opinion.
    func diplomacyDenounce(_ civId: Int) {
        guard civ(civId) != nil else { return }
        let p = personality(of: civId)
        /// This is not an official formula - modify or replace as needed. In Float, `pow` through Double as Kotlin's.
        func requiredOpinionChange(_ other: Int, _ numberOfActiveDenouncements: Int) -> Float {
            if p.denounceWillingness == 0 { return -Float.infinity }   // never denounce
            let personalityModifier = 1 / Float(p.scaledFocus(.denounceWillingness))
            let opinionModifier = Float(pow(Double(Float(1.005)), Double(Float(opinion(of: civId, toward: other)))))
            let multipleDenouncementsModifier = Float(pow(Double(Float(1.1)), Double(numberOfActiveDenouncements)))
            return -65 * personalityModifier * opinionModifier * multipleDenouncementsModifier
        }
        let relationships = knownCivs(civId).filter { $0.isMajor }.map { $0.id }
        var numberOfActiveDenouncements = relationships.filter { hasFlag(civId, $0, "Denunciation") }.count
        let denounceableRelationships = relationships.filter {
            !(civ(civId)?.isAtWar(with: $0) ?? false) && !hasFlag(civId, $0, "DeclarationOfFriendship") && !hasFlag(civId, $0, "Denunciation")
        }
        for other in denounceableRelationships {
            // compare our current opinion with the smoothed opinion; denounce if opinion dropped too quickly
            let opinionChange = Float(smoothedOpinionDelta(civId, other))
            if opinionChange <= requiredOpinionChange(other, numberOfActiveDenouncements) {
                denounce(civId, other)
                numberOfActiveDenouncements += 1
            }
        }
    }
    // MARK: - TradeEvaluation / TradeAutomation

    /// Unciv TradeEvaluation.getGoldInflation
    func goldInflation(_ civId: Int) -> Double {
        let gpt = max(1, netGoldPerTurn(civId))
        return 1000 / (pow(gpt, 1.2) + 1660) + 0.4
    }
    /// Unciv TradeEvaluation.evaluatePeaceCostForThem
    func evaluatePeaceCostForThem(_ ourCiv: Int, _ otherCiv: Int) -> Int {
        // Unciv, in Float: `Int * 1.5f`, `absoluteAdvantage / strength.toFloat()`, `(absolute * percentage).toInt()`
        let ours = militaryMight(ourCiv), theirs = militaryMight(otherCiv)
        if Float(ours) * 1.5 >= Float(theirs) && Float(theirs) * 1.5 >= Float(ours) { return 0 }
        /// Kotlin Float.toInt(): truncation, saturating, NaN -> 0
        func kotlinInt(_ f: Float) -> Int { f.isNaN ? 0 : f >= Float(Int32.max) ? Int(Int32.max) : f <= Float(Int32.min) ? Int(Int32.min) : Int(f) }
        func kotlinInt(_ d: Double) -> Int { d.isNaN ? 0 : d >= Double(Int32.max) ? Int(Int32.max) : d <= Double(Int32.min) ? Int(Int32.min) : Int(d) }
        if ours > theirs {
            if hasAtLeastMotivationToAttack(ourCiv, otherCiv, atLeast: 0) <= 0 { return 0 }
            let absolute = ours - theirs
            let pct = Float(absolute) / Float(theirs)
            let total = kotlinInt(Float(absolute) * pct)
            if total < 0 { return 10000 }
            return kotlinInt(Double(total) / (goldInflation(otherCiv) * 2))
        } else {
            // Unciv: no motivation check on the losing side, and the cost is capped at maxGoldTradeOffer
            let absolute = theirs - ours
            let pct = Float(absolute) / Float(ours)
            let peaceCost = Double(Float(absolute) * pct) / (goldInflation(ourCiv) * 2.0)
            return -min(kotlinInt(peaceCost), rs.constants.maxGoldTradeOffer)
        }
    }
    /// Unciv TradeEvaluation.isPeaceProposalEnabled: `civId` (at war with `third`) may offer peace with `third` as a trade item when no fresh war declaration
    /// stands, the third civ is AI, it is not a city-state allied to someone we are at war with, and the third civ itself would accept a plain peace treaty.
    func isPeaceProposalEnabled(third: Int, _ civId: Int) -> Bool {
        guard let t = civ(third), let me = civ(civId), me.isAtWar(with: third) else { return false }
        if hasFlag(civId, third, "DeclaredWar") { return false }
        if t.isPlayer { if GameState.evlogOn { hbr("A6.noPeaceForHumanThird", civId) }; return false }
        if t.isCityState, let a = ally(of: third), me.isAtWar(with: a) { return false }
        var probe = TradeOffer(id: -1, from: civId, to: third, turnCreated: turn)
        probe.give.peace = true; probe.want.peace = true
        return tradeAcceptability(probe, evaluator: third, includeGifts: true) >= 0   // Unciv isTradeAcceptable counts gifts
    }
    /// Unciv TradeEvaluation.evaluateBuyCost – what their side is worth to `civId`, in gold.
    func evaluateBuyCost(_ side: TradeSide, civId: Int, partner: Int, offer: TradeOffer) -> Int {
        var v = 0
        v += side.gold
        v += side.goldPerTurn * speed.dealDuration * 4 / 5
        if side.embassy { v += Int(30 * speed.goldCostModifier) }
        if side.openBorders { v += 100 }
        if side.peace { v += evaluatePeaceCostForThem(civId, partner) }
        // Unciv PeaceProposal (buy side): we pay for peace only when the third civ is a city-state allied to us (surplus influence × 15); a disliked third civ makes the deal unacceptable.
        for third in side.peaceWith {
            if let t = civ(third), t.isCityState, ally(of: third) == civId { v += Int(max(0, (t.influence[civId] ?? 0) - 60) * 15) }
            else if relationshipLevel(civId, third) < .neutral { return Int(Int32.min) }   // Unciv Int.MIN_VALUE: "Maximum negative for deal to be rejected"
        }
        if side.researchAgreement { v -= side.researchAgreementCost }   // Unciv `-offer.amount`: the cost the offer was made at
        let counts = resourceCounts(civId)
        let happy = happiness(of: civId)
        for (r, amount) in Dictionary(grouping: side.resources, by: { $0 }).mapValues(\.count).sorted(by: { $0.key < $1.key }) {
            guard let def = rs.resources[r] else { continue }
            if hasFlag(civId, partner, "ResourceTradesCutShort") { continue }   // Unciv TradeEvaluation: "We don't trust you for resources"
            let explicit = def.uniqueObjects.filter({ ($0.pattern == "AI will buy at [] Gold" || $0.pattern == "AI will buy at []") }).map({ $0.int(0) }).min()
            if def.resourceType == "Luxury" {
                if let explicit { v += explicit; continue }
                if (counts[r] ?? 0) > 0 { continue }
                let wltkd = cities(of: civId).filter { $0.demandedResource == r }.count * 50
                v += wltkd + (happy < 0 ? 450 : happy < 10 ? 350 : 300)
            } else {
                let willing = 2 - (counts[r] ?? 0)
                if willing <= 0 { continue }   // Unciv: "we already have enough" comes before the explicit buy price
                if let explicit { v += explicit; continue }
                // Unciv evaluateBuyCost: a buildable building or constructable unit of one of our cities needs it per turn
                let canUse = cities(of: civId).contains { city in
                    buildableBuildings(for: city).contains { resourceRequirementsPerTurn(requiredResource: $0.requiredResource, uniques: $0.uniqueObjects, ctx: UniqueContext(civId: civId, city: city))[r] != nil }
                        || buildableUnits(for: city).contains { resourceRequirementsPerTurn(requiredResource: $0.requiredResource, uniques: $0.uniqueObjects, ctx: UniqueContext(civId: civId))[r] != nil }
                }
                if !canUse { continue }
                v += 50 * min(willing, amount)
            }
        }
        // Unciv evaluateBuyCost Stockpiled_Resource: kural setinin AI alış fiyatı, yoksa bizim için değersiz
        for (r, n) in side.stockpiles where n > 0 {
            guard let def = rs.resources[r] else { continue }
            v += def.uniqueObjects.filter({ ($0.pattern == "AI will buy at [] Gold" || $0.pattern == "AI will buy at []") }).map({ $0.int(0) }).min() ?? 0
        }
        for war in side.warOns {   // Unciv: every WarDeclaration offer on its own
            guard let target = civ(war) else { continue }
            if offer.give.warOns.contains(war) && offer.want.warOns.contains(war) { }   // team war handled by the selling side
            else if areAtWar(civId, war) { v += max(0, kotlinToInt(20 * evaluateJoinOurWarPlan(civId, target: war, civToJoin: partner, given: nil))) }   // Float, then toInt()
            _ = target
        }
        v += side.introductions.count * introductionValue
        for cid in side.cities {
            guard let city = city(cid) else { continue }
            // Unciv: our happiness plus the city's own happiness list must not go negative
            if Double(happiness(of: civId)) + happinessBreakdown(city.civId, onlyCity: city.id).total < 0 { continue }
            // Unciv surroundedByOurCities: 3 when a tile bordering the city's tiles belongs to us
            let cityTiles = Set(city.tiles)
            let surrounded = cityTiles.contains { c in map.neighbors(of: c).contains { !cityTiles.contains($0) && map[$0]?.ownerCivId == civId } } ? 3 : 0
            v += (city.population * 4 + city.builtBuildingObjects.count + 4 + surrounded) * 100   // getBuiltBuildings().count()
        }
        return v
    }
    /// Unciv TradeEvaluation.evaluateSellCost – what our side costs `civId`, in gold.
    func evaluateSellCost(_ side: TradeSide, civId: Int, partner: Int, offer: TradeOffer) -> Int {
        var v = 0
        v += side.gold
        v += side.goldPerTurn * speed.dealDuration * 4 / 5
        let rel = relationshipLevel(civId, partner)
        if side.embassy { v += Int(Double(rel <= .enemy ? 300 : rel <= .competitor ? 60 : 30) * speed.goldCostModifier) }
        if side.openBorders {
            switch rel { case .unforgivable: v += 10000; case .enemy: v += 2000; case .competitor: v += 500; case .neutral, .afraid: v += 200; default: v += 100 }
        }
        if side.peace { v += evaluatePeaceCostForThem(civId, partner) }
        for third in side.peaceWith { v += evaluatePeaceCostForThem(civId, third) }   // Unciv PeaceProposal (sell side)
        if side.defensivePact { v += wantsToSignDefensivePact(civId, partner) ? 0 : 100000 }
        if side.friendship { v += wantsToSignDeclarationOfFriendship(civId, partner) ? 0 : 100000 }
        if side.researchAgreement { v -= side.researchAgreementCost }   // Unciv `-offer.amount`: the cost the offer was made at
        let counts = resourceCounts(civId)
        for (r, amount) in Dictionary(grouping: side.resources, by: { $0 }).mapValues(\.count).sorted(by: { $0.key < $1.key }) {
            guard let def = rs.resources[r] else { continue }
            if let explicit = def.uniqueObjects.filter({ ($0.pattern == "AI will sell at [] Gold" || $0.pattern == "AI will sell at []") }).map({ $0.int(0) }).min() { v += explicit; continue }
            if def.resourceType == "Luxury" {
                // Unciv evaluateSellCost: a spare copy is a fair 250, the last one 600 unless happiness is retained after trading it away
                if (counts[r] ?? 0) > 1 { v += 250 }
                else if let retain = civUniques(civId).first(where: { $0.pattern == "Retain []% of the happiness from a luxury after the last copy has been traded away" }) { v += 600 - Int(retain.double(0) * 3.5) }
                else { v += 600 }
            }
            else {
                if rs.units.values.contains(where: { $0.isSpaceshipPart && $0.requiredResource == r }) && (civUniques(civId).contains { $0.pattern == "Enables construction of Spaceship parts" } || civUniques(partner).contains { $0.pattern == "Enables construction of Spaceship parts" }) { return Int.max / 4 }
                if !isAtWarAtAll(civId) { v += 50 * amount; continue }
                // Unciv: some unit of the ruleset needing this resource per turn is buildable
                // Unciv: ruleset.units.values.any { it.getResourceRequirementsPerTurn().containsKey(resource) && it.isBuildable(civInfo) }
                // isBuildable(civ) = getRejectionReasons(civ, city = null).none(): the "Only available" gates (an Atomic
                // Bomb without the Manhattan Project), our unique's replacement, nukes turned off, Unbuildable...
                let canUse = rs.units.values.contains { def in
                    resourceRequirementsPerTurn(requiredResource: def.requiredResource, uniques: def.uniqueObjects, ctx: UniqueContext(civId: civId))[r] != nil
                        && unitRejections(def, civId: civId, city: nil).isEmpty
                }
                if !canUse { v += 50 * amount; continue }
                let left = counts[r] ?? 0
                for numberOfResource in (left - amount + 1)...left { v += numberOfResource > 5 ? 100 : (6 - numberOfResource) * 100 }
            }
        }
        // Unciv evaluateSellCost Stockpiled_Resource: AI satış fiyatı yoksa asla elden çıkarmayız
        for (r, n) in side.stockpiles where n > 0 {
            guard let def = rs.resources[r] else { continue }
            guard let lowest = def.uniqueObjects.filter({ ($0.pattern == "AI will sell at [] Gold" || $0.pattern == "AI will sell at []") }).map({ $0.int(0) }).min() else { return Int.max / 4 }
            v += lowest
        }
        for war in side.warOns {   // Unciv: every WarDeclaration offer on its own
            let motivation: Float
            if offer.give.warOns.contains(war) && offer.want.warOns.contains(war) { motivation = evaluateTeamWarPlan(civId, target: war, teamCiv: partner, given: nil) }
            else if areAtWar(partner, war) { motivation = evaluateJoinWarPlan(civId, target: war, civToJoin: partner, given: nil) }
            else { motivation = evaluateDeclareWarPlan(civId, target: war, given: nil) }
            if motivation < -10 { return Int.max / 4 }
            if motivation < 0 { v += min(10000, kotlinToInt(-motivation * 1000)) } else { v += 1000 }   // `(-motivation * 1000).toInt()` in Float
        }
        v += side.introductions.count * introductionValue
        for cid in side.cities { if let city = city(cid) { v += max(1000, (city.population * 4 + city.builtBuildingObjects.count + 4) * 100) } }   // getBuiltBuildings().count()
        return v
    }
    /// One TradeOffer each: Unciv evaluates, inflates and truncates every offer on its own
    /// (evaluateBuyCostWithInflation / evaluateSellCostWithInflation) and only then sums them. Gold and gold per turn
    /// are the offers that are not divided by the inflation.
    private func tradeOfferPieces(_ s: TradeSide) -> [(side: TradeSide, isGold: Bool)] {
        var out: [(side: TradeSide, isGold: Bool)] = []
        func piece(_ f: (inout TradeSide) -> Void, gold: Bool = false) { var p = TradeSide(); f(&p); out.append((p, gold)) }
        if s.gold != 0 { piece({ $0.gold = s.gold }, gold: true) }
        if s.goldPerTurn != 0 { piece({ $0.goldPerTurn = s.goldPerTurn }, gold: true) }
        for (r, n) in Dictionary(grouping: s.resources, by: { $0 }).mapValues(\.count).sorted(by: { $0.key < $1.key }) { piece { $0.resources = Array(repeating: r, count: n) } }
        for (r, n) in s.stockpiles.sorted(by: { $0.key < $1.key }) where n > 0 { piece { $0.stockpiles = [r: n] } }
        if s.openBorders { piece { $0.openBorders = true } }
        if s.embassy { piece { $0.embassy = true } }
        if s.researchAgreement { piece { $0.researchAgreement = true; $0.researchAgreementCost = s.researchAgreementCost } }
        if s.peace { piece { $0.peace = true } }
        if s.friendship { piece { $0.friendship = true } }
        if s.defensivePact { piece { $0.defensivePact = true } }
        for c in s.cities { piece { $0.cities = [c] } }
        for w in s.warOns { piece { $0.warOns = [w] } }
        for x in s.introductions { piece { $0.introductions = [x] } }
        for x in s.peaceWith { piece { $0.peaceWith = [x] } }
        return out
    }

    /// Unciv TradeEvaluation.getTradeAcceptability for `evaluator` (one of the two parties): the sum of their
    /// offers (treaties excluded) less the sum of ours - each offer inflated and truncated on its own, the sums in
    /// Long - ours × 1.5 / × 2 for an Enemy / Unforgivable unless we give peace or a research agreement, never a
    /// defensive pact below Ally, plus their gold gifts when asked. Ours inflated each side's total at once.
    func tradeAcceptability(_ o: TradeOffer, evaluator: Int, includeGifts: Bool = true) -> Int {
        let partner = evaluator == o.to ? o.from : o.to
        let ours = evaluator == o.to ? o.want : o.give      // what evaluator gives
        let theirs = evaluator == o.to ? o.give : o.want    // what evaluator gets
        if ours.cities.count > Int(ceil(Double(cities(of: evaluator).count) / 5)) { return Int.min / 4 }
        // Unciv getTradeAcceptability: never agree to declare war on more than one enemy at a time - summing the
        // war declarations would rate each as if it were the only one
        if ours.warOns.count > 1 { return Int(Int32.min) }
        let inflation = goldInflation(evaluator)
        // Unciv getTradeAcceptability: the other side's treaties (peace, research agreement, defensive pact) are not counted as gains
        var theirsWithoutTreaties = theirs
        theirsWithoutTreaties.peace = false; theirsWithoutTreaties.researchAgreement = false; theirsWithoutTreaties.defensivePact = false; theirsWithoutTreaties.friendship = false
        var sumOfTheirOffers: Int64 = 0
        for p in tradeOfferPieces(theirsWithoutTreaties) {
            let v = evaluateBuyCost(p.side, civId: evaluator, partner: partner, offer: o)
            // evaluateBuyCostWithInflation: `(cost / inflation).toInt()` saturates at Int.MIN_VALUE, so no piece - a
            // disliked peace proposal's Int.MIN_VALUE neither - can take the Long sum past its range
            sumOfTheirOffers += p.isGold ? Int64(v) : Int64(GameState.kotlinToInt(Double(v) / inflation))
        }
        var sumOfOurOffers: Int64 = 0
        for p in tradeOfferPieces(ours) {
            let v = evaluateSellCost(p.side, civId: evaluator, partner: partner, offer: o)
            if v >= Int.max / 4 { return Int.min / 4 }   // Unciv Int.MAX_VALUE: never
            sumOfOurOffers += p.isGold ? Int64(v) : Int64(GameState.kotlinToInt(Double(v) / inflation))   // evaluateSellCostWithInflation, the same toInt()
        }
        let rel = relationshipIgnoreAfraid(evaluator, partner)
        // If we're making a peace treaty, don't try to up the bargain for people you don't like
        if !ours.peace && !ours.researchAgreement {
            if rel == .enemy { sumOfOurOffers = Int64(Double(sumOfOurOffers) * 1.5) } else if rel == .unforgivable { sumOfOurOffers *= 2 }
        }
        if ours.defensivePact && rel != .ally { return Int.min / 4 }
        // Unciv isTradeAcceptable / getCounteroffer: gold gifts the partner gave us count in their favour
        let gifts = Int64(includeGifts ? goldGifts(receivedBy: evaluator, from: partner) : 0)
        return Int(max(Int64(Int32.min), min(Int64(Int32.max), sumOfTheirOffers - sumOfOurOffers + gifts)))
    }

    // MARK: - UseGoldAutomation

    /// Unciv UseGoldAutomation.useGold
    func useGoldAI(_ civId: Int) {
        for u in units(of: civId) { tryUpgradeUnit(u.id) }
        if civ(civId)?.isMajor == true { useGoldForCityStatesAI(civId) }
        guard let civ = civ(civId) else { return }
        let acceptableHurry = Int(max(0, civ.gold) / 100)
        // Unciv `civ.cities.sortedByDescending { it.cityStats.currentCityStats.production }` - a STABLE sort, so
        // cities of equal production keep the civ's city order. Swift's `sorted` is not stable.
        let byProduction = cities(of: civId).enumerated().sorted { a, b in
            let pa = currentCityStats(a.element.id).total.production, pb = currentCityStats(b.element.id).total.production
            return pa != pb ? pa > pb : a.offset < b.offset
        }.map { $0.element.id }
        for cityId in byProduction {
            // Unciv holds the City object: its current construction is read now, after the purchases before it
            guard let city = self.city(cityId), city.civId == civId else { continue }
            guard let p = city.currentProduction, canPurchase(p, in: city) else { continue }
            let hurry = p.isUnit ? (rs.units[p.name]?.hurryCostModifier ?? 0) : (rs.buildings[p.name]?.hurryCostModifier ?? 0)
            let cost = purchaseCost(p, for: civId, in: city)   // Unciv construction.getStatBuyCost(city, Gold)
            // Unciv: `if (city.cityConstructions.getWorkDone(construction.name) > 0) continue` - the work actually banked.
            // Ours read `workDoneOn`, set only when the construction was switched to, so work added since went unseen
            // (fresh turn 173: Ragusa bought the Hospital it had 49 hammers in; Unciv kept building it).
            guard Double(cost) <= (self.civ(civId)?.gold ?? 0), hurry <= acceptableHurry, workDone(p, in: city) <= 0 else { continue }
            _ = purchase(cityId: city.id, p)
        }
        maybeBuyCityTiles(civId)
    }
    func useGoldForCityStatesAI(_ civId: Int) {
        guard let civ = civ(civId) else { return }
        // Unciv `civ.getKnownCivs().filter { it.isCityState && ... }.toList()` - the diplomacy map's order
        let known = knownCivs(civId).filter { $0.isCityState && hasAtLeastMotivationToAttack(civId, $0.id, atLeast: 0) <= 0 }
        if civ.gold >= 330 && happiness(of: civId) > 0 && marriageTurnsRequired(civId) != nil {
            for cs in known where canMarry(civId, cs.id) { marry(civId, cs.id); if happiness(of: civId) <= 0 { break } }
        }
        guard (self.civ(civId)?.gold ?? 0) >= 500, !known.isEmpty else { return }
        let valued = known.filter { ally(of: $0.id) != civId }.map { ($0, valueCityStateAlliance(civId, $0.id, includeQuests: true)) }.max { $0.1 < $1.1 }
        if ProcessInfo.processInfo.environment["CSGIFT"] != nil {
            let parts: [String] = known.map { cs in "\(cs.nation):ally=\(ally(of: cs.id).flatMap { self.civ($0)?.nation } ?? "-"):inf=\(influence(of: civId, with: cs.id)):value=\(valueCityStateAlliance(civId, cs.id, includeQuests: true))" }
            print("CSGIFTE t=\(turn) \(civ.nation) gold=\(Int(self.civ(civId)?.gold ?? 0)) " + parts.joined(separator: " "))
        }
        if let (cs, value) = valued, value > 0 { tryGainInfluence(civId, cs.id) }
    }
    func tryGainInfluence(_ civId: Int, _ cityState: Int) {
        guard let civ = civ(civId), civ.gold >= 500, self.civ(cityState) != nil else { return }
        let influence = self.influence(of: civId, with: cityState)
        let stop = influence > 60 + 2 * Double(valueCityStateAlliance(civId, cityState, includeQuests: true))
        if influence < 10 || stop { return }
        giftGold(from: civId, to: cityState, amount: civ.gold >= 1000 ? 1000 : 500)
    }
    /// Unciv UseGoldAutomation: a breadth-first search from the city through tiles nobody owns (or that this city already
    /// owns) to the tile we want; the answer is the unowned tiles along the way, the nearest one first.
    func tilePathToBuy(from city: City, to target: HexCoord) -> [HexCoord] {
        guard map[target]?.ownerCivId == nil else { return [] }
        var cameFrom: [HexCoord: HexCoord] = [:]
        var seen: Set<HexCoord> = [city.coord]
        var queue: [HexCoord] = [city.coord], head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            if cur == target { break }
            for n in map.neighbors(of: cur) where !seen.contains(n) {
                // Unciv BFS predicate: `it.getOwner() == null || it.owningCity == cityWithLeastCostToBuy` - THIS
                // city's tiles, not every tile of the civ
                guard let t = map[n], t.ownerCivId == nil || city.tiles.contains(n) else { continue }
                seen.insert(n); cameFrom[n] = cur; queue.append(n)
            }
        }
        guard seen.contains(target) else { return [] }
        var path: [HexCoord] = [], cur = target
        while cur != city.coord {
            if map[cur]?.ownerCivId == nil { path.append(cur) }
            guard let prev = cameFrom[cur] else { return [] }
            cur = prev
        }
        return path.reversed()
    }

    func isHighlyDesirableTile(_ c: HexCoord, civId: Int, city: City) -> Bool {
        guard let t = map[c], t.ownerCivId == nil, visibleTiles(for: civId).contains(c), map.neighbors(of: c).contains(where: { city.tiles.contains($0) }) else { return false }
        if t.naturalWonder != nil { return true }
        if let r = t.resource, canSeeResource(r, civId: civId), rs.resources[r]?.resourceType == "Luxury", (resourceCounts(civId)[r] ?? 0) < 2 { return true }
        let y = yields(of: t, for: civId)
        return y.food + y.production >= 3
    }
}

// MARK: - Unciv TradeAutomation.getCounteroffer / DiplomacyAutomation.checkMilitaryPresenceNearBorder / NextTurnAutomation.freeUpSpaceResources
extension GameState {

    /// Unciv DiplomacyAutomation.checkMilitaryPresenceNearBorder: large human troop concentrations at our border
    /// trigger the "don't attack us" demand.
    func checkMilitaryPresenceNearBorder(_ civId: Int) {
        guard let civ = civ(civId) else { return }
        let vis = visibleTiles(for: civId)
        // cities' tiles, 2 around, not ours (skip open borders), visible to us - as a set
        var nearby: Set<HexCoord> = []
        for c in cities(of: civId) { for t in c.tiles { for n in map.tilesWithin(t, radius: 2) where map[n]?.ownerCivId != civId && vis.contains(n) { nearby.insert(n) } } }
        // only counts what is visible to us: the tile's military unit, a major civ's, not ours
        var nearbyUnitCountByCiv: [Int: Int] = [:], nearbyForceByCiv: [Int: Int] = [:]
        let seenIds = Set(visibleUnits(for: civId).map { $0.id })
        for u in units where u.isMilitary && !u.def.isAir && u.civId != civId && nearby.contains(u.coord) && seenIds.contains(u.id) {
            guard let owner = self.civ(u.civId), owner.isMajor else { continue }
            nearbyUnitCountByCiv[u.civId, default: 0] += 1; nearbyForceByCiv[u.civId, default: 0] += unitForceEvaluation(u)
        }
        for other in knownCivs(civId) {
            // this ultimatum can currently only be made by AI to human players, to avoid abuse
            if !other.isPlayer { continue }
            if GameState.evlogOn { hbr("A3.borderCheckOfHuman", other.id) }
            // don't check violation if we are at war; ignore if they promised they would not attack us
            if civ.isAtWar(with: other.id) || hasFlag(civId, other.id, "AgreedToNotAttackUs") { continue }
            // let's not doubt our allies
            if hasFlag(civId, other.id, "DeclarationOfFriendship") || hasFlag(civId, other.id, "DefensivePact") || hasOpenBorders(other.id, in: civId) { continue }
            // ignore if they only have a few units near our borders (relevant in early game)
            if (nearbyUnitCountByCiv[other.id] ?? 0) < 8 { continue }
            // ignore if they are weak, stay silent if they are too strong
            let threat = threatAssessment(civId, other.id)
            if threat == .veryLow || threat == .veryHigh { continue }
            // ignore if most of their military is elsewhere: `nearbyForce / (50 / 100f)`, an Int total against a Float
            let forceCutoff = Float(nearbyForceByCiv[other.id] ?? 0) / 0.5
            var totalForce = 0
            var mostElsewhere = false
            for u in units(of: other.id) where u.isMilitary {
                totalForce += unitForceEvaluation(u)
                if Float(totalForce) > forceCutoff { mostElsewhere = true; break }
            }
            if mostElsewhere { continue }
            // let's ask what's up: setFlag(..., 30, adjustWithGameSpeed = true) - `(30 * speed.modifier).roundToInt()` in Float
            setFlag(civId, other.id, "MilitaryPresenceNearBorderOrAttackedUsDespitePromise", Stats.roundToInt(Double(Float(30) * Float(speed.modifier))))
        }
    }

    /// Unciv NextTurnAutomation.freeUpSpaceResources: disband units and sell buildings that eat the resources spaceship parts need.
    func freeUpSpaceResources(_ civId: Int) {
        guard settings.victoryTypes.contains("Scientific") else { return }
        let spaceResources = Set(rs.units.values.filter { $0.isSpaceshipPart }.compactMap { $0.requiredResource })
        guard !spaceResources.isEmpty, let civ = civ(civId) else { return }
        // Unciv NextTurnAutomation.freeUpSpaceResources: only when a victory's next milestone is adding the parts
        let partsAreNext = rs.victories.contains { v in
            guard settings.victoryTypes.contains(v.name), let next = v.milestones.first(where: { !milestoneCompleted($0, by: civ) }) else { return false }
            return Unique(next).pattern == "Add all [] in capital"
        }
        guard partsAreNext else { return }
        for res in spaceResources.sorted() {   // Swift Set sirasi surec basina rastgele; Unciv sabit bir HashSet uzerinde yurur
            if (resourceCounts(civId)[res] ?? 0) >= 2 { continue }
            if let victim = units(of: civId).filter({ $0.def.requiredResource == res && !$0.def.isSpaceshipPart }).min(by: { unitForceEvaluation($0) < unitForceEvaluation($1) }) { disband(unitId: victim.id) }
            for city in cities(of: civId) where !city.hasSoldBuildingThisTurn {
                // Unciv `ruleset.buildings.values.filter { city.isBuilt(it) && ... }.randomOrNull(rng)`: Buildings.json order.
                // Unciv's own filter - isBuilt, requires the resource, isSellable, not a free building - and then
                // City.sellBuilding, which checks nothing: a puppet sells too (only the Sell button refuses puppets).
                let candidates = rs.buildingOrder.filter { city.buildings.contains($0) && rs.buildings[$0]?.requiredResource == res && rs.buildings[$0].map(isSellable) == true && !hasFreeBuilding(city, $0) }
                // Unciv NextTurnAutomation.kt:385 (sellBuildingForResource): `city.state.stateBasedRandom("NextTurnAutomation.freeUpSpaceResources")`
                var g = stateBasedRandom("NextTurnAutomation.freeUpSpaceResources", city: city)
                if let pick = g.pick(candidates) { sellBuilding(cityId: city.id, pick); break }
            }
        }
    }
}

extension TradeSide {
    func merged(with o: TradeSide) -> TradeSide {
        var r = self
        r.gold += o.gold; r.goldPerTurn += o.goldPerTurn; r.resources += o.resources   // Unciv TradeOffersList.add sums amounts
        r.openBorders = r.openBorders || o.openBorders; r.embassy = r.embassy || o.embassy
        r.researchAgreement = r.researchAgreement || o.researchAgreement; r.peace = r.peace || o.peace
        r.researchAgreementCost += o.researchAgreementCost   // TradeOffersList.add sums the amounts
        r.cities += o.cities.filter { !r.cities.contains($0) }; r.warOns += o.warOns.filter { !r.warOns.contains($0) }   // Unciv TradeOffersList: one offer per civ
        r.friendship = r.friendship || o.friendship; r.defensivePact = r.defensivePact || o.defensivePact
        r.introductions += o.introductions.filter { !r.introductions.contains($0) }
        r.peaceWith += o.peaceWith.filter { !r.peaceWith.contains($0) }
        for (k, v) in o.stockpiles { r.stockpiles[k, default: 0] += v }   // TradeOffersList.add sums amounts
        return r
    }
}
