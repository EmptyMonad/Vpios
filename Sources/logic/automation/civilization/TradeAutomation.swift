// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's civilization/TradeAutomation.kt.

/// Unciv TradeOfferType, in declaration order: `sortedByDescending { it.type.ordinal }` reads the ordinal.
enum UncivTradeOfferType: Int {
    case embassy = 0, gold, goldPerTurn, treaty, agreement, luxuryResource, strategicResource, stockpiledResource,
         technology, introduction, warDeclaration, peaceProposal, city
}

/// One Unciv `TradeOffer(name, type, amount, duration)` as getCounteroffer handles it.
struct UncivTradeOfferItem {
    let name: String
    let type: UncivTradeOfferType
    var amount: Int
    let duration: Int
    /// The third civ of an introduction, war declaration or peace proposal (its name is `name`).
    var civId: Int? = nil

    /// Kotlin data-class `hashCode()`: name, type, amount, duration folded by 31. The enum has no hashCode of
    /// its own, and the reference runs with -XX:hashCode=2, so every identity hash - the type's - is 1.
    var dataClassHash: Int32 {
        var h = javaStringHash(name)
        h = h &* 31 &+ 1
        h = h &* 31 &+ Int32(truncatingIfNeeded: amount)
        h = h &* 31 &+ Int32(truncatingIfNeeded: duration)
        return h
    }

    /// The same offer as one side of our trade model.
    var side: TradeSide {
        var s = TradeSide()
        switch type {
        case .embassy: s.embassy = true
        case .gold: s.gold = amount
        case .goldPerTurn: s.goldPerTurn = amount
        case .agreement: s.openBorders = true
        case .luxuryResource, .strategicResource: s.resources = Array(repeating: name, count: max(0, amount))
        case .stockpiledResource: s.stockpiles = [name: amount]
        case .introduction: if let c = civId { s.introductions = [c] }
        case .warDeclaration: if let c = civId { s.warOns = [c] }
        case .peaceProposal: if let c = civId { s.peaceWith = [c] }
        case .treaty, .technology, .city: break
        }
        return s
    }
}

/// A `java.util.HashMap<TradeOffer, Int>` as far as its iteration order goes: bucket by bucket of the table,
/// in insertion order within a bucket. The bucket is fixed by the key's hash when it was put in - a key whose
/// amount changes afterwards stays where it was, as it does there.
private struct JavaOfferHashMap {
    struct Entry { var key: UncivTradeOfferItem; let value: Int; let hash: Int32; let insertion: Int }
    private(set) var entries: [Entry] = []
    private var inserted = 0
    private var maxSize = 0
    var isEmpty: Bool { entries.isEmpty }

    mutating func put(_ key: UncivTradeOfferItem, _ value: Int) {
        entries.append(Entry(key: key, value: value, hash: key.dataClassHash, insertion: inserted))
        inserted += 1
        maxSize = max(maxSize, entries.count)
    }
    mutating func remove(insertion: Int) { entries.removeAll { $0.insertion == insertion } }
    mutating func setAmount(insertion: Int, _ amount: Int) {
        if let i = entries.firstIndex(where: { $0.insertion == insertion }) { entries[i].key.amount = amount }
    }
    /// The table grows past 3/4 full and never shrinks.
    private var capacity: Int { var c = 16; while maxSize > c * 3 / 4 { c <<= 1 }; return c }
    var ordered: [Entry] {
        let mask = Int32(capacity - 1)
        return entries.map { e -> (Int32, Entry) in (((e.hash ^ Int32(bitPattern: UInt32(bitPattern: e.hash) >> 16)) & mask), e) }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.insertion < $1.1.insertion }
            .map { $0.1 }
    }
}

extension GameState {
    /// Unciv TradeAutomation.respondToTradeRequests – AIs answer offers addressed to them, and so does a human AutoPlay
    /// automates; then `tradeRequests.clear()`. The Declarations of Friendship are no trade requests (Unciv sends them as
    /// popup alerts): automateCivMoves has answered them already in respondToPopupAlerts, whatever tradeAndChangeState says.
    func respondToTradeRequests(_ civId: Int, tradeAndChangeState: Bool) {
        guard let civ = civ(civId), isAIOrAutoPlaying(civId) else { return }
        for o in pendingOffers.filter({ $0.to == civId && !$0.isFriendshipRequest }) {
            // Unciv removes a request it answers and clears the rest (the skipped ones) at the end: either way it goes
            pendingOffers.removeAll { $0.id == o.id }
            // Treat 'no trade' state as if all trades are invalid - thus AIs will not update its "turns to offer"
            guard tradeAndChangeState, tradeIsValid(o) else { continue }
            tradeLogicInit(civId, o.from)   // Unciv `TradeLogic(civInfo, otherCiv)`
            if tradeAcceptability(o, evaluator: civId) >= 0 {
                executeTrade(o)
                notify(o.from, "[\(civ.nation)] has accepted your trade request", category: .Trade, icons: ["Trade", civ.nation])
            } else if let counter = counteroffer(civId, for: o) {
                notify(o.from, "[\(civ.nation)] has made a counteroffer to your trade request", category: .Trade, icons: ["Trade", civ.nation])   // Unciv: no action
                queueOffer(counter)
            } else {
                notify(o.from, "[\(civ.nation)] has denied your trade request", category: .Trade, icons: [civ.nation, "Trade"])
                declineTradeRequest(o, decliner: civId)
            }
        }
        // `civInfo.tradeRequests.clear()`: a human's requests also stand in its alert queue (.TradeRequest, one TradePopup
        // each) - every one is answered or dropped now (the kept alerts are picked before the list is written back)
        if let ci = civIndex(civId), civs[ci].popupAlerts.contains(where: { $0.type == .TradeRequest }) {
            let kept = civs[ci].popupAlerts.filter { $0.type != .TradeRequest }
            civs[ci].popupAlerts = kept
        }
    }
    /// Unciv TradeRequest.decline (+ TradePopup "Not this time."): turns the requester waits before offering again.
    /// The request's trade is seen from the decliner: its ourOffers are `o.want`, its theirOffers `o.give`.
    func declineTradeRequest(_ o: TradeOffer, decliner civId: Int) {
        guard let civ = civ(civId) else { return }
        let p = personality(of: o.from)   // Unciv TradeRequest.decline reads the *requesting* civ's personality
        let declinerIsAI = !civ.isPlayer || epochsAutoplay   // Unciv `decliningCiv.isAI()`
        if !declinerIsAI && GameState.evlogOn { hbr("A7.humanDeclines10", civId) }
        func onlyLuxuries(_ side: TradeSide) -> Bool {
            var rest = side; rest.resources = []
            return rest.isEmpty && side.resources.allSatisfy { rs.resources[$0]?.resourceType == "Luxury" }
        }
        if onlyLuxuries(o.give) && onlyLuxuries(o.want) { setFlag(o.from, civId, "DeclinedLuxExchange", 5 - Int(Float(p[.commerce]) / 2)) }
        if o.want.researchAgreement { setFlag(o.from, civId, "DeclinedResearchAgreement", 15 - Int(Float(p[.science]))) }
        if o.want.defensivePact { setFlag(o.from, civId, "DeclinedDefensivePact", 10) }
        if o.want.openBorders { setFlag(o.from, civId, "DeclinedOpenBorders", declinerIsAI ? 5 : 10) }
        if o.give.embassy || o.want.embassy { setFlag(o.from, civId, "DeclinedEmbassy", declinerIsAI ? 5 : 10) }
        if !o.give.warOns.isEmpty { setFlag(o.from, civId, "DeclinedJoinWarOffer", declinerIsAI ? 5 : 10) }
        if !o.want.warOns.isEmpty { setFlag(civId, o.from, "DeclinedJoinWarOffer", declinerIsAI ? 5 : 10) }   // otherCivDiplomacy(): the decliner's side
        if o.want.peace { setFlag(o.from, civId, "DeclinedPeace", 3) }   // trade.isPeaceTreaty()
    }
    /// Unciv TradeAutomation.exchangeLuxuries
    func exchangeLuxuries(_ civId: Int) {
        for other in knownCivs(civId) where other.isMajor && !areAtWar(civId, other.id) && !hasFlag(civId, other.id, "DeclinedLuxExchange") {
            if relationshipLevel(civId, other.id) <= .enemy { continue }
            // Unciv `otherCiv.tradeRequests.any { it.requestingCiv == civInfo.civID }`. Our pending offers also carry the
            // declaration of friendship, which Unciv sends as a PopupAlert, never as a trade request - so it blocks nothing.
            if pendingOffers.contains(where: { $0.from == civId && $0.to == other.id && !$0.give.friendship }) { continue }
            tradeLogicInit(civId, other.id)   // Unciv potentialLuxuryTrades' `TradeLogic(civInfo, otherCivInfo)`
            // Unciv potentialLuxuryTrades: luxury offers with amount > 1 that the other side has no offer for at all
            let ourOffers = tradableResourceSupply(civId), theirOffers = tradableResourceSupply(other.id)
            // Unciv walks `tradeLogic.ourAvailableOffers` / `theirAvailableOffers`, whose resource order is
            // the supply list's own - not alphabetical. Then `theyHaveWeDont` gets ONE stable
            // sortedByDescending on "how many of my cities are demanding this", which ties whenever none are.
            let weHaveTheyDont = tradableResourceOrder(civId).filter { n in rs.resources[n]?.resourceType == "Luxury" && (ourOffers[n]?.tradable ?? 0) > 1 && theirOffers[n] == nil }
            let theyHaveWeDont = sortedDescendingStable(tradableResourceOrder(other.id).filter { n in rs.resources[n]?.resourceType == "Luxury" && (theirOffers[n]?.tradable ?? 0) > 1 && ourOffers[n] == nil }) { name in
                cities(of: civId).filter { $0.demandedResource == name }.count   // Prioritize resources that get WLTKD
            }
            for i in 0..<min(weHaveTheyDont.count, theyHaveWeDont.count) {
                var offer = TradeOffer(id: newId(), from: civId, to: other.id, turnCreated: turn)
                offer.give.resources = [weHaveTheyDont[i]]; offer.want.resources = [theyHaveWeDont[i]]
                queueOffer(offer)   // Unciv otherCiv.tradeRequests.add
            }
        }
    }

    /// Unciv `TradeLogic(ourCivilization, otherCivilization)` as far as it leaves anything behind: its init fills
    /// ourAvailableOffers and theirAvailableOffers (getAvailableOffers both ways), whose PeaceProposal items ask
    /// TradeEvaluation.isPeaceProposalEnabled for every third civ the other side knows at war with the giver, and
    /// evaluating that peace reads the Force ranking of both (Civilization.cachedMilitaryMight, kept until that civ's
    /// own endTurn) - so a TradeLogic built in an AI's turn decides which strength a civ playing later reads. Ours
    /// builds no offer lists where Unciv's automation builds a TradeLogic, so each such place calls this.
    func tradeLogicInit(_ our: Int, _ other: Int) {
        availableOffersPeaceProposals(giver: our, receiver: other)
        availableOffersPeaceProposals(giver: other, receiver: our)
    }
    /// Unciv TradeLogic.getAvailableOffers(civInfo = giver, otherCiv = receiver): nothing between city-states, then
    /// `otherCiv.getKnownCivs().filter { it.isAtWarWith(civInfo) && !it.isDefeated() && !DiplomaticRelationshipsCannotChange }`.
    private func availableOffersPeaceProposals(giver: Int, receiver: Int) {
        guard let g = civ(giver), let r = civ(receiver), !g.isCityState, !r.isCityState else { return }
        if rs.modOptionUniques.contains(where: { $0.pattern == "Diplomatic relationships cannot change" }) { return }
        for third in knownCivs(receiver) where third.isAlive && areAtWar(third.id, giver) { _ = isPeaceProposalEnabled(third: third.id, giver) }
    }

    /// Unciv TradeLogic.theirAvailableOffers - what `giver` could give `receiver` - as far as a counteroffer may
    /// ask for it, in the list's order: the embassy line of the TradeLogic's init, then getAvailableOffers'
    /// open borders, per-turn resources, stockpiles, gold, gold per turn, introductions, war declarations and
    /// peace proposals. (Treaties, luxuries and cities are never asked for, so they are left out.)
    private func counterofferCandidates(giver: Int, receiver: Int) -> [UncivTradeOfferItem] {
        guard let g = civ(giver), let r = civ(receiver) else { return [] }
        var out: [UncivTradeOfferItem] = []
        let dealDuration = speed.dealDuration
        // Embassy trade availability depends solely on our ability to trade it
        if canEstablishEmbassy(receiver, with: giver) { out.append(UncivTradeOfferItem(name: "Accept Embassy", type: .embassy, amount: 1, duration: -1)) }
        if g.isCityState || r.isCityState { return out }
        func enablesOpenBorders(_ c: Civilization) -> Bool { c.techs.contains(where: { rs.techs[$0]?.uniqueObjects.contains(where: { $0.pattern == "Enables Open Borders agreements" }) == true }) }
        if advancedDiplomacyAllowed(giver, receiver) && !hasOpenBorders(receiver, in: giver) && enablesOpenBorders(g) && enablesOpenBorders(r) {
            out.append(UncivTradeOfferItem(name: "Open Borders", type: .agreement, amount: 1, duration: dealDuration))
        }
        let supply = tradableResourceSupply(giver)
        for name in tradableResourceOrder(giver) {
            guard let def = rs.resources[name], def.resourceType != "Bonus" else { continue }
            out.append(UncivTradeOfferItem(name: name, type: def.resourceType == "Luxury" ? .luxuryResource : .strategicResource, amount: supply[name]?.tradable ?? 0, duration: dealDuration))
        }
        for (name, amount) in tradableStockpiles(giver).sorted(by: { $0.key < $1.key }) {
            out.append(UncivTradeOfferItem(name: name, type: .stockpiledResource, amount: amount, duration: -1))
        }
        out.append(UncivTradeOfferItem(name: "Gold", type: .gold, amount: Int(g.gold), duration: -1))
        out.append(UncivTradeOfferItem(name: "Gold per turn", type: .goldPerTurn, amount: Int(netGoldPerTurn(giver)), duration: dealDuration))
        let otherCivsWeKnow = knownCivs(giver).filter { $0.id != receiver && $0.isMajor && $0.isAlive }
        if introductionValue > 0 {   // UniqueType.TradeCivIntroductions
            for third in otherCivsWeKnow where !r.metCivs.contains(third.id) {
                out.append(UncivTradeOfferItem(name: third.nation, type: .introduction, amount: 1, duration: -1, civId: third.id))
            }
        }
        let relationshipsFixed = rs.modOptionUniques.contains(where: { $0.pattern == "Diplomatic relationships cannot change" })
        if !relationshipsFixed {
            for third in otherCivsWeKnow where r.metCivs.contains(third.id) && canDeclareWar(giver, on: third.id) {
                out.append(UncivTradeOfferItem(name: third.nation, type: .warDeclaration, amount: 1, duration: -1, civId: third.id))
            }
            // Setting amount to 0 makes TradeOffer.isTradable() return false
            for third in knownCivs(receiver) where areAtWar(third.id, giver) {
                out.append(UncivTradeOfferItem(name: third.nation, type: .peaceProposal, amount: isPeaceProposalEnabled(third: third.id, giver) ? 1 : 0, duration: -1, civId: third.id))
            }
        }
        return out
    }

    /// Unciv TradeAutomation.getCounteroffer: the same ourOffers as the request, with enough of their offers added
    /// to make the deal acceptable. Will find a valid counteroffer if any exist, but is not guaranteed to find the
    /// best or closest one.
    func counteroffer(_ civId: Int, for o: TradeOffer) -> TradeOffer? {
        let other = o.from
        guard civ(other) != nil, let me = civ(civId) else { return nil }
        // The request's trade seen from us: ourOffers = o.want, theirOffers = o.give
        var deltaInOurFavor = tradeAcceptability(o, evaluator: civId, includeGifts: true)
        if deltaInOurFavor > 0 { deltaInOurFavor = kotlinToInt(Float(deltaInOurFavor) / 1.1) }   // They seem very interested in this deal, let's push it a bit.
        tradeLogicInit(civId, other)   // Unciv `TradeLogic(civInfo, otherCiv)`

        func hasType(_ s: TradeSide, _ t: UncivTradeOfferType) -> Bool {
            switch t {
            case .gold: return s.gold != 0
            case .goldPerTurn: return s.goldPerTurn != 0
            default: return false
            }
        }
        /// `currentTrade.theirOffers.any { it.type == offer.type && it.name == offer.name }`
        func theyOfferAlready(_ item: UncivTradeOfferItem) -> Bool {
            let s = o.give
            switch item.type {
            case .embassy: return s.embassy
            case .gold: return s.gold != 0
            case .goldPerTurn: return s.goldPerTurn != 0
            case .agreement: return s.openBorders
            case .luxuryResource, .strategicResource: return s.resources.contains(item.name)
            case .stockpiledResource: return (s.stockpiles[item.name] ?? 0) != 0
            case .introduction: return item.civId.map { s.introductions.contains($0) } ?? false
            case .warDeclaration: return item.civId.map { s.warOns.contains($0) } ?? false
            case .peaceProposal: return item.civId.map { s.peaceWith.contains($0) } ?? false
            case .treaty, .technology, .city: return false
            }
        }
        let inflation = goldInflation(civId)
        /// Unciv evaluateBuyCostWithInflation: gold and gold per turn as they are, the rest `(cost / inflation).toInt()`
        func buyCostWithInflation(_ item: UncivTradeOfferItem) -> Int {
            let v = evaluateBuyCost(item.side, civId: civId, partner: other, offer: o)
            if item.type == .gold || item.type == .goldPerTurn { return v }
            return GameState.kotlinToInt(Double(v) / inflation)   // Kotlin Double.toInt(): truncating, saturating
        }

        // What do they have that we would want?
        var potentialAsks = JavaOfferHashMap()
        var counterofferAsks = JavaOfferHashMap()
        var counterofferGifts: [UncivTradeOfferItem] = []

        for offer in counterofferCandidates(giver: other, receiver: civId) {
            if (offer.type == .gold || offer.type == .goldPerTurn) && hasType(o.want, offer.type) { continue }   // Don't want to counteroffer straight gold for gold, that's silly
            if !(offer.amount > 0) { continue }   // isTradable: for example resources gained by trade or CS
            if offer.type == .city { continue }   // Players generally don't want to give up their cities
            if offer.type == .luxuryResource { continue }   // Don't ask for luxuries as counteroffer
            if theyOfferAlready(offer) { continue }   // So you don't get double offers of open borders declarations of war etc.
            if offer.type == .treaty { continue }   // Don't try to counter with a defensive pact or research pact
            let value = buyCostWithInflation(offer)
            if value > 0 { potentialAsks.put(offer, value) }
        }

        if GameState.evlogOn && ProcessInfo.processInfo.environment["CTRTRACE"] != nil {
            print("CTRE t=\(uncivTurns) \(me.nation)<-\(self.civ(other)?.nation ?? "?") delta=\(deltaInOurFavor) asks=[\(potentialAsks.ordered.map { "\($0.key.name)x\($0.key.amount)d\($0.key.duration)=\($0.value)" }.joined(separator: ", "))]")
        }
        while !potentialAsks.isEmpty && deltaInOurFavor < 0 {
            // Keep adding their worst offer until we get above the threshold (minByOrNull: the first minimum)
            var offerToAdd: JavaOfferHashMap.Entry? = nil
            for e in potentialAsks.ordered where offerToAdd == nil || e.value < offerToAdd!.value { offerToAdd = e }
            guard let add = offerToAdd else { break }
            deltaInOurFavor += add.value
            counterofferAsks.put(add.key, add.value)
            potentialAsks.remove(insertion: add.insertion)
        }
        if deltaInOurFavor < 0 { return nil }   // We couldn't get a good enough deal

        // At this point we are sure to find a good counteroffer
        while deltaInOurFavor > 0 {
            // Now remove the best offer valued below delta until the deal is barely acceptable (maxByOrNull: the first maximum)
            var offerToRemove: JavaOfferHashMap.Entry? = nil
            for e in counterofferAsks.ordered where e.value <= deltaInOurFavor && (offerToRemove == nil || e.value > offerToRemove!.value) { offerToRemove = e }
            guard let remove = offerToRemove else { break }   // Nothing more can be removed, at least en bloc
            deltaInOurFavor -= remove.value
            counterofferAsks.remove(insertion: remove.insertion)
        }

        // Only ask for enough of each resource to get maximum price
        for ask in counterofferAsks.ordered where ask.key.type == .luxuryResource || ask.key.type == .strategicResource {
            // Remove 1 amount as long as doing so does not change the price
            let originalValue = ask.value
            var amount = ask.key.amount
            while amount > 1 {
                var fewer = ask.key; fewer.amount = amount - 1
                if originalValue != buyCostWithInflation(fewer) { break }
                amount -= 1
            }
            counterofferAsks.setAmount(insertion: ask.insertion, amount)
        }

        // Adjust any gold asked for - GPT first. Unciv collects the fully removable ones in a `toRemove` list that
        // it never applies, so such an ask stays in the trade whole while the delta drops by its value.
        let goldAsks = sortedDescendingStable(counterofferAsks.ordered.filter { $0.key.type == .goldPerTurn || $0.key.type == .gold }) { $0.key.type.rawValue }
        for goldAsk in goldAsks {
            var one = goldAsk.key; one.amount = 1
            let valueOfOne = buyCostWithInflation(one)
            let amountCanBeRemoved = deltaInOurFavor / valueOfOne
            if amountCanBeRemoved >= goldAsk.key.amount {
                deltaInOurFavor -= goldAsk.value
            } else {
                deltaInOurFavor -= valueOfOne * amountCanBeRemoved
                counterofferAsks.setAmount(insertion: goldAsk.insertion, goldAsk.key.amount - amountCanBeRemoved)
            }
        }

        // If the delta is still very in our favor consider sweetening the pot with some gold
        if deltaInOurFavor >= 100 {
            deltaInOurFavor = (deltaInOurFavor * 2) / 3   // Only compensate some of it though, they're the ones asking us
            // First give some GPT, then lump sum - but only if they're not already offering the same
            let ourGoldOffers = [UncivTradeOfferItem(name: "Gold per turn", type: .goldPerTurn, amount: Int(netGoldPerTurn(civId)), duration: speed.dealDuration),
                                 UncivTradeOfferItem(name: "Gold", type: .gold, amount: Int(me.gold), duration: -1)]
            for ourGold in ourGoldOffers where ourGold.amount > 0 {
                if !hasType(o.give, ourGold.type) && !counterofferAsks.entries.contains(where: { $0.key.type == ourGold.type }) {
                    var one = ourGold; one.amount = 1
                    let valueOfOne = evaluateSellCost(one.side, civId: civId, partner: other, offer: o)   // gold: evaluateSellCostWithInflation does not inflate
                    let amountToGive = min(deltaInOurFavor / valueOfOne, ourGold.amount)
                    deltaInOurFavor -= amountToGive * valueOfOne
                    if amountToGive > 0 { var gift = ourGold; gift.amount = amountToGive; counterofferGifts.append(gift) }
                }
            }
        }

        if GameState.evlogOn && ProcessInfo.processInfo.environment["CTRTRACE"] != nil {
            print("CTRE2 t=\(uncivTurns) \(me.nation) final=[\(counterofferAsks.ordered.map { "\($0.key.name)x\($0.key.amount)" }.joined(separator: ", "))]")
        }
        // Trades reversed, because when *they* get it then the 'ouroffers' become 'theiroffers'
        var counter = TradeOffer(id: newId(), from: civId, to: other, turnCreated: turn)
        counter.give = o.want; counter.want = o.give
        counter.evTailGive = o.evTailWant; counter.evTailWant = o.evTailGive   // reverse() keeps each list's order
        for ask in counterofferAsks.ordered {
            if !evOfferNames(counter.want, other: counter.give).contains(ask.key.name) { counter.evTailWant.append(ask.key.name) }   // TradeOffersList.add: a new entry goes last
            counter.want = counter.want.merged(with: ask.key.side)
        }
        for gift in counterofferGifts {
            if !evOfferNames(counter.give, other: counter.want).contains(gift.name) { counter.evTailGive.append(gift.name) }
            counter.give = counter.give.merged(with: gift.side)
        }
        return counter
    }
}
