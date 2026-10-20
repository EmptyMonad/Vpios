// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/civilization/diplomacy/DeclareWar.kt` (declareWar, in its order: the city-state direct
/// attack, notifyOfWar, onWarDeclared for the declarer and then for the target, changeOpinions, breakTreaties,
/// the triggers) and of DiplomacyManager.makePeace / makePeaceOneSide.
///
/// Unciv's war is a per-side `diplomaticStatus`, set inside each side's onWarDeclared: while the declarer's side
/// calls in its city-state allies, the target's side is not at war yet. Ours set both sides at war before anything
/// else, so an ally called in, an opinion scored or a unit sent home saw a different war than Unciv's.
extension GameState {
    /// Unciv Civilization.destroy(): the trades (both copies) and the pending trade requests of a destroyed civ stop.
    func clearDealsOf(_ civId: Int) {
        if GameState.evlogOn {   // EVLOG: TRADE end, both copies of every trade of the destroyed civ
            // Unciv Civilization.destroy: `for (diplomacyManager in diplomacy.values)` - the HashMap's order
            for other in diplomacyOrder(civId) where other != civId {
                evTradeEndsInStartOrder(civId, other)
                evTradeEndsInStartOrder(other, civId)
            }
        }
        for i in deals.indices where deals[i].from == civId || deals[i].to == civId { deals[i].fromGone = true; deals[i].toGone = true }
        deals.removeAll { $0.fromGone && $0.toGone }
        tradeRecords.removeAll { $0.ours == civId || $0.theirs == civId }   // the whole trades, both copies (TradeRecord)
        pendingOffers.removeAll { $0.from == civId || $0.to == civId }
    }

    /// Unciv DiplomacyManager.canDeclareWar: `!civInfo.isDefeated() && !otherCiv.isDefeated() && turnsToPeaceTreaty() == 0
    /// && diplomaticStatus != War` - no Peace Treaty left in OUR copy of the trades, however far the other side's has got.
    func canDeclareWar(_ a: Int, on b: Int) -> Bool {
        guard let civA = civ(a), let civB = civ(b), a != b, !civA.isAtWar(with: b) else { return false }
        if civB.isBarbarian || civA.isBarbarian { return true }
        if rs.modOptionUniques.contains(where: { $0.pattern == "Diplomatic relationships cannot change" }) { return false }   // Unciv DiplomaticRelationshipsCannotChange
        if isDefeated(civA) || isDefeated(civB) { return false }
        return turnsToPeaceTreaty(a, b) == 0
    }

    /// Unciv DiplomacyManager.turnsToPeaceTreaty: the duration left on the Peace Treaty in `a`'s own copy of the trade
    /// (`ourOffers`), which DiplomacyTurnManager.nextTurnTrades counts down at `a`'s own end of turn. Our
    /// `peaceTreatyUntil` is a turn number: a civ that has ended its turn this round (diplomacyTurnDoneThisRound) has
    /// counted this round's turn already, so its copy holds one less than `until - turn` (addPeaceTreaty's `+ 1` the
    /// other way round). Unciv's canAttack (Nuke.mayUseNuke) and the diplomacy screen's "Declare war (n⏳)" read it too.
    func turnsToPeaceTreaty(_ a: Int, _ b: Int) -> Int {
        guard let until = civ(a)?.peaceTreatyUntil[b] else { return 0 }
        return max(0, until - turn - (diplomacyTurnDoneThisRound.contains(a) ? 1 : 0))
    }

    /// The Peace Treaty's duration left in theirOffers of `a`'s own copy of the trade - what DiplomacyTurnManager's
    /// "will end" / "has ended" and onWarDeclared's "has ended" read. Two equal offers (every treaty but one): a copy's
    /// `ourOffers.union(theirOffers)` holds only one of them, so theirOffers loses its first turn an end of turn after
    /// ourOffers and stays one ahead of turnsToPeaceTreaty from then on (`until - turn - done + 1`), at most the duration
    /// both started at (peaceTreatyStartDuration) - which a copy remakePeaceTreaty made at 0 reads until its next end of
    /// turn drops it, theirOffers already out. The PeaceProposal giver's copy holds ONE offer object in both lists
    /// (peaceTreatySharedOffer): its theirOffers is its ourOffers, `until - turn - done`. Not clamped below: 0 or less is out.
    func peaceTreatyTheirOffersLeft(_ a: Int, _ b: Int) -> Int? {
        guard let c = civ(a), let until = c.peaceTreatyUntil[b] else { return nil }
        let ours = until - turn - (diplomacyTurnDoneThisRound.contains(a) ? 1 : 0)
        if c.peaceTreatySharedOffer.contains(b) { return ours }
        return min(ours + 1, c.peaceTreatyStartDuration[b] ?? Int.max)
    }

    /// Whether `a`'s own copy of the Peace Treaty's trade is still in its trades list: nextTurnTrades drops it once
    /// theirOffers is out too. With two equal offers that is an end of turn after ourOffers reaches 0, so the trade is
    /// still there through the treaty's last turn, when `a` may already declare war (theirOffers at 1, `until - done ==
    /// turn`); the PeaceProposal giver's copy, one offer in both lists, goes with ourOffers (`until - done - 1 >= turn`).
    func peaceTreatyTradeRunning(_ a: Int, _ b: Int) -> Bool {
        (peaceTreatyTheirOffersLeft(a, b) ?? 0) > 0
    }

    /// Unciv DeclareWar.declareWar for `a`'s DiplomacyManager with `b`. Like Unciv, no treaty is checked here -
    /// callers ask canDeclareWar - so a war entered through an alliance or a refused demand always happens.
    /// `evenAtWar`: Unciv's declareWar asks nothing of the war either, and one caller runs it on a civ already at war
    /// (AlertPopup.addDemand's refusal of "Do not attack us", after refuseDemand's own) - the declaration happens again.
    func declareWar(_ a: Int, on b: Int, warType: WarType = .directWar, allyCiv: Int? = nil, evenAtWar: Bool = false) {
        guard let ai = civIndex(a), let bi = civIndex(b), a != b, evenAtWar || !civs[ai].isAtWar(with: b) else { return }
        if civs[ai].isBarbarian || civs[bi].isBarbarian {
            civs[ai].atWarWith.insert(b); civs[bi].atWarWith.insert(a)
            return
        }
        if !civs[ai].metCivs.contains(b) { makeCivilizationsMeet(a, b, warOnContact: true) }   // Unciv's callers always meet first
        if civs[bi].isCityState && warType == .directWar { handleCityStateDirectAttack(a, cityState: b) }
        notifyOfWar(a, b, warType: warType, allyCiv: allyCiv)
        onWarDeclared(a, b, isOffensiveWar: true, warType: warType)
        onWarDeclared(b, a, isOffensiveWar: false, warType: warType)
        changeOpinions(a, b, warType: warType, allyCiv: allyCiv)
        breakTreaties(a, b)
        // Unciv DeclareWar.triggerUniques
        guard let civA = civ(a), let civB = civ(b) else { return }
        triggerConditionalUniques(civId: a) { $0.pattern == "upon declaring war on [] Civilizations" && self.civMatches(civB, $0.param(0), viewer: a) }
        triggerConditionalUniques(civId: b) { $0.pattern == "upon being declared war on by [] Civilizations" && self.civMatches(civA, $0.param(0), viewer: b) }
        triggerConditionalUniques(civId: a) { $0.pattern == "upon entering a war with [] Civilizations" && self.civMatches(civB, $0.param(0), viewer: a) }
        triggerConditionalUniques(civId: b) { $0.pattern == "upon entering a war with [] Civilizations" && self.civMatches(civA, $0.param(0), viewer: b) }
    }

    /// Unciv DeclareWar.handleCityStateDirectAttack. `setInfluence(-60)` recomputes the ally at once, so by the time
    /// Unciv asks "you attacked your own ally?" the attacker no longer is - that branch never fires there, and ours
    /// (which asked before the influence moved) handed out a -120 and BetrayedDeclarationOfFriendship Unciv never does.
    private func handleCityStateDirectAttack(_ a: Int, cityState cs: Int) {
        setInfluence(cityState: cs, major: a, -60)
        if let ai = civIndex(a) { civs[ai].numMinorCivsAttacked += 1 }
        cityStateAttacked(cs, by: a)
        if ally(of: cs) == a {   // You attacked your own ally, you're a right bastard
            updateAllyCivForCityState(cs)
            setInfluence(cityState: cs, major: a, -120)
            for known in knownCivs(a) { addModifier(known.id, a, .BetrayedDeclarationOfFriendship, -10) }
        }
    }

    /// Unciv DeclareWar.notifyOfWar
    private func notifyOfWar(_ a: Int, _ b: Int, warType: WarType, allyCiv: Int?) {
        guard let an = civ(a)?.nation, let bn = civ(b)?.nation else { return }
        let onlookers = commonKnownCivIds(a, b, withSpectators: true)
        switch warType {
        case .directWar:
            addAlert(b, .WarDeclaration, "\(a)")
            notify(b, "[\(an)] has declared war on us!", category: .Diplomacy, icons: [bn, "War", an])
            for t in onlookers { notify(t, "[\(an)] has declared war on [\(bn)]!", category: .Diplomacy, icons: [bn, "War", an]) }
        case .defensivePactWar, .cityStateAllianceWar, .joinWar:
            guard let al = allyCiv, let aln = civ(al)?.nation else { return }
            addAlert(b, .WarDeclaration, "\(a)")
            let pact = warType == .defensivePactWar
            let aggressor = pact ? b : a, defender = pact ? a : b
            let agg = pact ? bn : an, def = pact ? an : bn
            notify(defender, "[\(agg)] has joined [\(aln)] in the war against us!", category: .Diplomacy, icons: [def, "War", aln, agg])
            notify(aggressor, "We have joined [\(aln)] in the war against [\(def)]!", category: .Diplomacy, icons: [def, "War", aln, agg])
            for t in onlookers where t != al { notify(t, "[\(agg)] has joined [\(aln)] in the war against [\(def)]!", category: .Diplomacy, icons: [def, "War", aln, agg]) }
            notify(al, "[\(agg)] has joined us in the war against [\(def)]!", category: .Diplomacy, icons: [def, "War", aln, agg])
        case .teamWar:
            guard let al = allyCiv, let aln = civ(al)?.nation else { return }
            // We only want to send these notifications once, it doesn't matter who sends it though
            if let ia = civs.firstIndex(where: { $0.id == a }), let ial = civs.firstIndex(where: { $0.id == al }), ia > ial { return }
            addAlert(b, .WarDeclaration, "\(a)"); addAlert(b, .WarDeclaration, "\(al)")
            notify(a, "You and [\(aln)] have declared war against [\(bn)]!", category: .Diplomacy, icons: [bn, "War", aln, an])
            notify(al, "You and [\(an)] have declared war against [\(bn)]!", category: .Diplomacy, icons: [bn, "War", an, aln])
            notify(b, "[\(an)] and [\(aln)] have declared war against us!", category: .Diplomacy, icons: [bn, "War", aln, an])
            for t in onlookers where t != al { notify(t, "[\(an)] and [\(aln)] have declared war against [\(bn)]!", category: .Diplomacy, icons: [bn, "War", aln, an]) }
        }
    }

    /// Unciv DeclareWar.onWarDeclared for `x`'s DiplomacyManager with `y` - everything that happens to each side.
    private func onWarDeclared(_ x: Int, _ y: Int, isOffensiveWar: Bool, warType: WarType) {
        guard civIndex(x) != nil, civIndex(y) != nil else { return }
        // Cancel all trades: `for (trade in trades) for (offer in trade.theirOffers.filter { it.duration > 0 && it.name !=
        // Constants.defensivePact })` "[offer] from [..] has ended" - trade by trade in x's list (GameState.currentTrades,
        // what the Trades overview lists: a Peace Treaty in its own trade's place, its theirOffers copy running through
        // the treaty's last turn when ourOffers is already at 0, unless x's copy is a PeaceProposal giver's one offer in
        // both lists, which goes with ourOffers; twice after a trade cut short for two resources) - then `trades.clear()`.
        // Ours told the deals first in the order they were made and the treaty after them, once.
        if let cx = civ(x), let yn = civ(y)?.nation {
            for row in currentTrades(cx, withText: false)[y] ?? [] {
                for o in row.theirs where o.duration > 0 && o.name != "Defensive Pact" {
                    notify(x, "[\(o.name)] from [\(yn)] has ended", category: .Trade, icons: [yn, "Trade"], actions: [.diplomacyTrade(yn)])
                }
            }
        }
        clearTrades(of: x, with: y, notifyEnded: false)
        if let xi = civIndex(x), civs[xi].peaceTreatyUntil[y] != nil {
            civs[xi].peaceTreatyUntil[y] = nil; civs[xi].peaceTreatySharedOffer.remove(y); civs[xi].peaceTreatyStartDuration[y] = nil
        }
        sharedTradeOffers?.peace.remove(SharedTradeOffers.key(x, y))   // `trades.clear()`: the shown game's treaty offers leave x's list
        // civInfo.tradeRequests from the other side - a trade request only: a Declaration of Friendship is a popup alert in
        // Unciv (AlertType.DeclarationOfFriendship), not a trade request, and stays to be declined at the AI's turn (setting
        // DeclinedDeclarationOfFriendship on the requester). Ours keeps it among the offers and dropped it with them (SX
        // dump, a test game, turn 146: Austria joined Celts against Polynesia, whose friendship offer Unciv's Austria declined)
        pendingOffers.removeAll { $0.to == x && $0.from == y && !($0.give.friendship && $0.want.friendship) }
        // Must come *before* state is "at war" so units know they're not allowed in tiles without open borders anymore
        updateHasOpenBorders(x, y)
        // If we attacked, then we need to end all of our defensive pacts according to Civ 5
        if isOffensiveWar { removeDefensivePacts(x, atWarWith: y) }
        if let xi = civIndex(x) {
            let evNew = civs[xi].atWarWith.insert(y).inserted
            civs[xi].warStartTurn[y] = turn
            if GameState.evlogOn, evNew { ev(x, "WAR", EvLog.name(civ(y)?.nation ?? "civ\(y)"), "war") }   // EVLOG: diplomaticStatus = War
        }
        // if we broke our promise to not attack them
        if isOffensiveWar && hasFlag(y, x, "AgreedToNotAttackUs") && (warType == .directWar || warType == .joinWar) {
            setFlag(y, x, "MilitaryPresenceNearBorderOrAttackedUsDespitePromise", Int((30 * speed.modifier).rounded()))
        }
        // Defensive pact chains are not allowed now
        if civ(x)?.isMajor == true {
            if !isOffensiveWar && warType != .defensivePactWar && civ(y)?.isCityState != true { callInDefensivePactAllies(x, atWarWith: y) }
            callInCityStateAllies(x, atWarWith: y)
        }
        // Unciv then asks the city-state's getProtectorCivs() - read from diplomaticStatus == Protector, which was
        // just overwritten with War - so the protection simply ends, without removeProtectorCiv's -20 and flag.
        if civ(x)?.isCityState == true, let yi = civIndex(y) { civs[yi].protectedCityStates.remove(x) }
        removeModifier(x, y, .YearsOfPeace)
        setFlag(x, y, "DeclinedPeace", rs.constants.minimumWarDuration)   // AI won't propose peace for 10 turns
        setFlag(x, y, "DeclaredWar", rs.constants.minimumWarDuration)     // AI won't agree to trade for 10 turns
        removeFlag(x, y, "BorderConflict")
        removeEmbassies(x, y)   // war results in removal of embassies for both sides
    }

    /// Unciv DeclareWar.removeDefensivePacts: every pact of the declarer stops working on both sides; with anyone
    /// but the target the pact's trades and the flags go too (with the target they stay, so breakTreaties can
    /// punish the betrayal - onWarDeclared has cleared those trades already).
    private func removeDefensivePacts(_ x: Int, atWarWith y: Int) {
        guard let xn = civ(x)?.nation else { return }
        for partner in diplomacyOrder(x) where civ(x)?.defensivePacts.contains(partner) == true {
            if let xi = civIndex(x) { civs[xi].defensivePacts.remove(partner) }
            if let pi = civIndex(partner) { civs[pi].defensivePacts.remove(x) }
            if partner != y {
                // Trades with defensive pact are now invalid: `trades.firstOrNull { ourOffers has a Defensive Pact }`
                // is removed from our list, then from theirs - the whole trade, silently (no "has ended", no
                // resource refresh). Ours kept counting those deals down and announced their end later.
                if let g = tradeGroups(x, partner).first(where: { $0.contains { deals[$0].kind == .defensivePact && deals[$0].from == x } }) {
                    if GameState.evlogOn { evTradeEnd(x, partner, g) }   // EVLOG: TRADE end (trades.remove)
                    for i in g { deals[i].setGone(for: x) }
                }
                if let g = tradeGroups(partner, x).first(where: { $0.contains { deals[$0].kind == .defensivePact && deals[$0].from == partner } }) {
                    if GameState.evlogOn { evTradeEnd(partner, x, g) }   // EVLOG: TRADE end (trades.remove)
                    for i in g { deals[i].setGone(for: partner) }
                }
                deals.removeAll { $0.fromGone && $0.toGone }
                removeFlag(x, partner, "DefensivePact"); removeFlag(partner, x, "DefensivePact")
            }
            let pn = civ(partner)?.nation ?? "?"
            for c in commonKnownCivIds(x, partner, withSpectators: true) {
                notify(c, "[\(xn)] cancelled their Defensive Pact with [\(pn)]!", category: .Diplomacy, icons: [xn, "Diplomacy", pn])
            }
            notify(partner, "[\(xn)] cancelled their Defensive Pact with us!", category: .Diplomacy, icons: [xn, "Diplomacy", pn])
            notify(x, "We have cancelled our Defensive Pact with [\(pn)]!", category: .Diplomacy, icons: ["Diplomacy", pn])
        }
    }

    /// Unciv DeclareWar.callInDefensivePactAllies: the list is made first; each ally not yet at war is declared war
    /// upon BY the aggressor.
    private func callInDefensivePactAllies(_ x: Int, atWarWith y: Int) {
        let allies = diplomacyOrder(x).filter { p in civ(x)?.defensivePacts.contains(p) == true && civ(p)?.isAlive == true && !areAtWar(p, y) }
        for ally in allies {
            if civ(y)?.metCivs.contains(ally) != true { makeCivilizationsMeet(y, ally, warOnContact: true) }
            declareWar(y, on: ally, warType: .defensivePactWar, allyCiv: x)
        }
    }

    /// Unciv DeclareWar.callInCityStateAllies: our allied city-states (listed first) join, meeting the enemy if needed.
    private func callInCityStateAllies(_ x: Int, atWarWith y: Int) {
        let allies = knownCivs(x).filter { $0.isCityState && ally(of: $0.id) == x }.map { $0.id }
        for cs in allies {
            if areAtWar(cs, y) { continue }
            if civ(cs)?.metCivs.contains(y) != true { makeCivilizationsMeet(cs, y, warOnContact: true) }
            declareWar(cs, on: y, warType: .cityStateAllianceWar, allyCiv: x)
        }
    }

    /// Unciv DeclareWar.changeOpinions
    private func changeOpinions(_ a: Int, _ b: Int, warType: WarType, allyCiv: Int?) {
        setModifier(b, a, .DeclaredWarOnUs, -20)
        removeModifier(b, a, .ReturnedCapturedUnits)
        // Apply warmongering
        if warType == .directWar || warType == .joinWar || warType == .teamWar {
            for third in knownCivs(a) {
                // `thirdCiv.getDiplomacyManager(otherCiv)?.isRelationshipLevelGT(Competitor) != false`: true when unknown
                let notEnemies = third.id == b || !third.metCivs.contains(b) || relationshipLevel(third.id, b) > .competitor
                if !areAtWar(third.id, b) && notEnemies && third.id != allyCiv { addModifier(third.id, a, .WarMongerer, -5) }
            }
        }
        // Apply shared enemy modifiers - weighed by the DECLARER's loyalty
        let loyal = personality(of: a).modifierFocus(.loyal, 0.3)
        for third in commonKnownCivIds(a, b) {
            guard let t = civ(third) else { continue }
            if (areAtWar(third, b) || third == allyCiv) && !areAtWar(third, a) {
                if t.isCityState { addInfluence(cityState: third, major: a, 10) }   // improve our relations
                else { addModifier(third, a, .SharedEnemy, Double(Float(5) * Float(loyal))) }
            } else if areAtWar(third, a) {
                if t.isCityState { addInfluence(cityState: third, major: b, 10) }   // improve their relations
                else { addModifier(third, b, .SharedEnemy, Double(Float(5) * Float(loyal))) }
            }
        }
    }

    /// Unciv DeclareWar.breakTreaties
    private func breakTreaties(_ a: Int, _ b: Int) {
        var betrayedFriendship = false, betrayedDefensivePact = false
        if hasFlag(a, b, "DeclarationOfFriendship") {
            betrayedFriendship = true
            removeFlag(a, b, "DeclarationOfFriendship")
            removeModifier(b, a, .DeclarationOfFriendship)
        }
        removeFlag(b, a, "DeclarationOfFriendship")
        if let ai = civIndex(a) { civs[ai].friendships[b] = nil }
        if let bi = civIndex(b) { civs[bi].friendships[a] = nil }
        if hasFlag(a, b, "DefensivePact") {
            betrayedDefensivePact = true
            removeFlag(a, b, "DefensivePact")
            removeModifier(b, a, .DefensivePact)
        }
        removeFlag(b, a, "DefensivePact")
        if betrayedFriendship || betrayedDefensivePact {
            for known in knownCivs(a) {
                let loyal = Float(personality(of: known.id).modifierFocus(.loyal, 0.3))
                if betrayedFriendship { addModifier(known.id, a, .BetrayedDeclarationOfFriendship, Double((known.id == b ? -40 : -20) * loyal)) }
                // this stacks with the Declaration of Friendship
                if betrayedDefensivePact { addModifier(known.id, a, .BetrayedDefensivePact, Double((known.id == b ? -20 : -10) * loyal)) }
                removeModifier(known.id, a, .DeclaredFriendshipWithOurAllies)   // obviously this guy's declarations of friendship aren't worth much
                removeModifier(known.id, a, .SignedDefensivePactWithOurAllies)
            }
        }
        if hasFlag(a, b, "ResearchAgreement") {
            removeFlag(a, b, "ResearchAgreement")
            if let ai = civIndex(a) { civs[ai].totalOfScienceDuringRA[b] = 0 }
            if let bi = civIndex(b) { civs[bi].totalOfScienceDuringRA[a] = 0 }
        }
        removeFlag(b, a, "ResearchAgreement")
        // The other civ should keep any gifts we gave them, but we should not necessarily take away their gifts
        removeModifier(b, a, .GaveUsGifts)
    }

    func canMakePeace(_ a: Int, _ b: Int) -> Bool {
        guard let civA = civ(a), civA.isAtWar(with: b), civ(b)?.isBarbarian == false, civA.isBarbarian == false else { return false }
        return !rs.modOptionUniques.contains(where: { $0.pattern == "Diplomatic relationships cannot change" })   // Unciv DiplomaticRelationshipsCannotChange
    }

    /// The Peace Treaty offers of a trade, one copy per side: each side's copy of ourOffers runs out `peaceDealDuration`
    /// of ITS OWN turns later - a round later for a side that has already ended its turn this round. `recordTrade`: the
    /// treaty is a trade of its own (a PeaceProposal, an ally's peace, remakePeaceTreaty), `a` holding the copy that was
    /// added first - an accepted trade records its whole self instead (TradeRecord).
    func addPeaceTreaty(_ a: Int, _ b: Int, duration: Int? = nil, recordTrade: Bool = true) {
        let d = duration ?? speed.peaceDealDuration
        // new TradeOffer objects: none of them the shown game's (SharedTradeOffers)
        if let shared = sharedTradeOffers { shared.peace.remove(SharedTradeOffers.key(a, b)); shared.peace.remove(SharedTradeOffers.key(b, a)) }
        // two equal offers on each side (TradeOffer made twice, or `trade.reverse()`'s copies), both at `d`
        if let ai = civIndex(a) { civs[ai].peaceTreatyUntil[b] = turn + d + (diplomacyTurnDoneThisRound.contains(a) ? 1 : 0); civs[ai].peaceTreatySharedOffer.remove(b); civs[ai].peaceTreatyStartDuration[b] = d }
        if let bi = civIndex(b) { civs[bi].peaceTreatyUntil[a] = turn + d + (diplomacyTurnDoneThisRound.contains(b) ? 1 : 0); civs[bi].peaceTreatySharedOffer.remove(a); civs[bi].peaceTreatyStartDuration[a] = d }
        if recordTrade { recordPeaceTrade(a, b, duration: d) }
    }

    /// Unciv TradeLogic.acceptTrade, TradeOfferType.PeaceProposal: `val peaceOffer = TradeOffer(Constants.peaceTreaty, ...)`
    /// goes into `trade.ourOffers` AND `trade.theirOffers`, that trade into the giver's DiplomacyManager with the third civ
    /// and `trade.reverse()` - two copies - into the third civ's. The giver's copy then counts its one offer down once per
    /// end of turn in both lists, and is dropped (its "[Peace Treaty] from [..] has ended" included) at the end of turn
    /// that brings ourOffers to 0, an end of turn before a treaty of two offers would be.
    func addPeaceProposalTreaty(giver: Int, _ x: Int, duration: Int? = nil) {
        addPeaceTreaty(giver, x, duration: duration)
        if let gi = civIndex(giver) { civs[gi].peaceTreatySharedOffer.insert(x) }
    }

    /// Unciv DiplomacyManager.makePeace for `a`'s manager with `b`: both makePeaceOneSide calls - an allied
    /// city-state's own peace and its notification happen inside them - and only then the notification for these
    /// two and the triggers. `withTreaty` adds the Peace Treaty offers of the trade that brought the peace, as every
    /// caller of ours does (the trade, a PeaceProposal, a liberated city-state); `recordTrade` is false when that trade
    /// is an accepted one, which keeps its own record.
    func makePeace(_ a: Int, _ b: Int, withTreaty: Bool = true, recordTrade: Bool = true) {
        guard civIndex(a) != nil, civIndex(b) != nil else { return }
        if withTreaty { addPeaceTreaty(a, b, recordTrade: recordTrade) }
        makePeaceOneSide(a, b)
        makePeaceOneSide(b, a)
        if let na = civ(a)?.nation, let nb = civ(b)?.nation {
            for third in commonKnownCivIds(a, b, withSpectators: true) { notify(third, "[\(na)] and [\(nb)] have signed a Peace Treaty!", category: .Diplomacy, icons: [na, "Diplomacy", nb]) }
        }
        // Unciv DiplomacyManager.makePeace: TriggerUponSigningPeace on both sides
        if let civA = civ(a), let civB = civ(b) {
            triggerConditionalUniques(civId: a) { $0.pattern == "upon signing a peace treaty with [] Civilizations" && self.civMatches(civB, $0.param(0), viewer: a) }
            triggerConditionalUniques(civId: b) { $0.pattern == "upon signing a peace treaty with [] Civilizations" && self.civMatches(civA, $0.param(0), viewer: b) }
        }
    }

    /// Unciv DiplomacyManager.makePeaceOneSide: our status turns to Peace, our units leave their land (all of
    /// them - at war there are no open borders to keep them), our allied city-states at war with them make peace
    /// with a treaty, and the other city-states at war with them hold it against us.
    private func makePeaceOneSide(_ x: Int, _ y: Int) {
        guard let xi = civIndex(x) else { return }
        let evWasAtWar = civs[xi].atWarWith.remove(y) != nil
        civs[xi].lastPeaceTurn[y] = turn
        if GameState.evlogOn, evWasAtWar { ev(x, "WAR", EvLog.name(civ(y)?.nation ?? "civ\(y)"), "peace") }   // EVLOG: diplomaticStatus = Peace
        for id in units(of: x).filter({ map[$0.coord]?.ownerCivId == y }).map({ $0.id }) { teleportToClosestMoveableTile(id) }
        for third in knownCivs(x) {
            // Our ally city states make peace with us
            if ally(of: third.id) == x && areAtWar(third.id, y) {
                makePeace(third.id, y)
                if GameState.evlogOn { evPeaceTreatyStart(third.id, y) }   // EVLOG: the ally's peace-treaty trade, both copies
            }
            // Other City-States that are not our ally don't like the fact that we made peace with their enemy
            if ally(of: third.id) != x && areAtWar(third.id, y) { addInfluence(cityState: third.id, major: x, -10) }
        }
    }

    /// Kept for callers of the old split: the peace's side effects are makePeaceOneSide now.
    func onPeaceMade(_ a: Int, _ b: Int) {}

    // MARK: - gifts (Unciv DiplomacyManager.giftGold / recieveGoldGifts)

    /// Unciv CityConquestFunctions.diplomaticRepercussionsForConqueringCity
    func repercussionsForConqueringCity(_ city: City, oldCiv: Int, conqueror: Int) {
        let totalPop = max(1, cities(of: oldCiv).filter { $0.id != city.id }.reduce(0) { $0 + $1.population } + city.population)   // Unciv reads oldCiv.cities BEFORE the city leaves them
        // Unciv: `currentPopulation * 100f / sum`, `10f + pct.roundToInt()`, `(aggro / 10).roundToInt().toFloat()` - Float
        let pct = Float(city.population) * 100 / Float(totalPop)
        let aggro = Double(10 + Float(Stats.roundToInt(Double(pct))))
        // "How can you conquer a city but not know the civ you conquered it from?!"
        if civ(conqueror)?.metCivs.contains(oldCiv) != true { makeCivilizationsMeet(conqueror, oldCiv) }
        addModifier(oldCiv, conqueror, .CapturedOurCities, -aggro)
        let forOthers = Double(Stats.roundToInt(Double(Float(aggro) / 10)))
        for third in knownCivs(conqueror) where third.isMajor {   // Unciv: the old owner is NOT excluded
            if third.isAtWar(with: oldCiv) { addModifier(third.id, conqueror, .SharedEnemy, forOthers) }
            else { addModifier(third.id, conqueror, .WarMongerer, -forOthers) }
        }
    }

    /// Unciv CityConquestFunctions.diplomaticRepercussionsForLiberatingCity
    func repercussionsForLiberatingCity(_ city: City, founder: Int, liberator: Int, conquered: Int) {
        let totalPop = cities(of: founder).reduce(0) { $0 + $1.population } + city.population
        let pct = Float(city.population) * 100 / Float(max(1, totalPop))   // Unciv: in Float
        let respect = Double(10 + Float(Stats.roundToInt(Double(pct))))
        if civ(founder)?.isMajor == true {
            // Unciv `foundingCiv.getDiplomacyManagerOrMeet(conqueringCiv)`: `if (!knows(civInfo)) makeCivilizationsMeet` -
            // the founder's meetCiv first (the liberator's First Contact), then the liberator's
            if civ(founder)?.metCivs.contains(liberator) != true { makeCivilizationsMeet(founder, liberator) }
            addModifier(founder, liberator, .CapturedOurCities, respect)
            // Unciv: TradeLogic(foundingCiv, conqueringCiv) with the founder's Open Borders, acceptTrade(false) -
            // the same acceptance every trade goes through (ours is executeTrade: `to` is Unciv's ourCivilization)
            tradeLogicInit(founder, liberator)
            var ob = TradeOffer(id: 0, from: liberator, to: founder); ob.want.openBorders = true
            _ = executeTrade(ob, applyGifts: false)
        } else if let fi = civIndex(founder) {
            // Liberating a city-state gives a large amount of influence, and peace
            let maxOther = diplomacyOrder(founder).filter { $0 != liberator && civ($0)?.isMajor == true && civ($0)?.isAlive == true }
                .reduce(-60.0) { max($0, influence(of: $1, with: civs[fi].id)) }   // Unciv folds from MINOR_FRIENDSHIP_AT_WAR
            if !civs[fi].metCivs.contains(liberator) { makeCivilizationsMeet(founder, liberator) }
            let old = influence(of: liberator, with: founder)
            setInfluence(cityState: founder, major: liberator, max(max(maxOther, old) + 105, 60))
            if areAtWar(founder, liberator) {
                // Unciv: a peace-treaty trade (both sides' offers), acceptTrade(false) - both sides' open borders,
                // `founder.getDiplomacyManager(liberator).makePeace()`, both refreshes
                var peace = TradeOffer(id: 0, from: liberator, to: founder); peace.want.peace = true; peace.give.peace = true
                _ = executeTrade(peace, applyGifts: false)
            }
        }
        let forOthers = Double(Stats.roundToInt(Double(Float(respect) / 10)))
        for third in knownCivs(liberator) where third.isMajor && third.id != conquered { addModifier(third.id, liberator, .LiberatedCity, forOthers) }   // Unciv: the founder is included
    }
}
