// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/trade/TradeLogic.kt` and the trade half of `DiplomacyTurnManager.kt` (nextTurnTrades,
/// removeUntenableTrades, updateHasOpenBorders): deals between major civilizations, each side counting its own
/// copy of a trade down in its own turn.
extension GameState {
    /// The offers still in either side's copy of a trade between the two.
    func activeDeals(between a: Int, _ b: Int) -> [Deal] { deals.filter { (($0.from == a && $0.to == b) || ($0.from == b && $0.to == a)) && !($0.fromGone && $0.toGone) } }

    // MARK: - open borders (Unciv DiplomacyManager.hasOpenBorders / updateHasOpenBorders)

    /// Unciv `mover.getDiplomacyManager(owner).hasOpenBorders`: a transient CACHE of the trades, refreshed only where
    /// Unciv calls updateHasOpenBorders - acceptTrade, the mover's own nextTurn, onWarDeclared, loading a game.
    /// Ours was computed live, so a city-state's new alliance or a trade's last turn opened and closed borders at
    /// moments Unciv's cache did not.
    func hasOpenBorders(_ mover: Int, in owner: Int) -> Bool { civ(mover)?.hasOpenBordersWith.contains(owner) ?? false }

    /// What updateHasOpenBorders would set: a city-state may enter its ally's land, and anyone may enter the land
    /// of a civ whose Open Borders offer is still running in the mover's own copy of a trade (`theirOffers`).
    private func computeHasOpenBorders(_ civId: Int, _ other: Int) -> Bool {
        if civ(civId)?.isCityState == true && ally(of: civId) == other { return true }   // Unciv `civInfo.allyCiv == otherCiv`
        return deals.contains { $0.kind == .openBorders && $0.from == other && $0.to == civId && $0.exists(for: civId) && $0.left(for: civId) > 0 }
    }

    /// Unciv DiplomacyManager.updateHasOpenBorders: "borders were closed, get out!"
    func updateHasOpenBorders(_ civId: Int, _ other: Int) {
        guard let ci = civIndex(civId) else { return }
        let newHas = computeHasOpenBorders(civId, other)
        let bordersWereClosed = civs[ci].hasOpenBordersWith.contains(other) && !newHas
        if newHas { civs[ci].hasOpenBordersWith.insert(other) } else { civs[ci].hasOpenBordersWith.remove(other) }
        if bordersWereClosed {
            for id in units(of: civId).filter({ map[$0.coord]?.ownerCivId == other }).map({ $0.id }) { teleportToClosestMoveableTile(id) }
        }
    }

    /// Unciv GameInfo.setTransients / Civilization.setTransients: every diplomacy manager runs updateHasOpenBorders
    /// on load, from a cache that starts out false - so nobody is sent home.
    func updateAllHasOpenBorders() {
        for i in civs.indices { civs[i].hasOpenBordersWith = [] }
        for i in civs.indices { for other in civs[i].metCivs where computeHasOpenBorders(civs[i].id, other) { civs[i].hasOpenBordersWith.insert(other) } }
    }

    /// Resources the civ has spare (count > 1 for strategic, > 0 for luxuries it already enjoys) and could export.
    /// Unciv Civilization.getPerTurnResourcesWithOriginsForTrade: per resource the tradable amount and the copies from city-states / trades
    /// (not stockpiled, not "Cannot be traded"); city-state and trade copies with a positive amount cannot be traded on.
    /// Unciv Civilization.getStockpiledResourcesForTrade: a stockpiled resource can be traded when it is not
    /// barred from trade and the ruleset gives the AI a price for it.
    func tradableStockpiles(_ civId: Int) -> [String: Int] {
        guard let c = civ(civId) else { return [:] }
        return c.resourceStockpiles.filter { name, amount in
            guard amount > 0, let r = rs.resources[name], r.isStockpiled else { return false }
            if r.uniqueObjects.contains(where: { $0.pattern == "Cannot be traded" }) { return false }
            return r.uniqueObjects.contains { $0.pattern == "AI will sell at [] Gold" || $0.pattern == "AI will buy at [] Gold" }
        }
    }
    func tradableResourceSupply(_ civId: Int) -> [String: (tradable: Int, untradable: Int)] {
        var out: [String: (tradable: Int, untradable: Int)] = [:]
        for e in detailedCivResources(civId) {
            guard let r = rs.resources[e.resource], !r.isStockpiled, !r.uniqueObjects.contains(where: { $0.pattern == "Cannot be traded" }) else { continue }
            var entry = out[e.resource] ?? (0, 0)
            if (e.origin == "City-States" || e.origin == "Trade") && e.amount > 0 { entry.untradable += e.amount } else { entry.tradable += e.amount }
            out[e.resource] = entry
        }
        return out
    }
    /// The order Unciv's offer list puts the resources in: `getPerTurnResourcesWithOriginsForTrade()` walks
    /// `detailedCivResources` and `ResourceSupplyList.add` merges by (resource, origin), so a resource holds
    /// the place of its FIRST entry - cities in city order, then the city-state block, the uniques, the
    /// trades, the units. Sorting the names alphabetically instead, as we did, was a determinism we made up.
    func tradableResourceOrder(_ civId: Int) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for e in detailedCivResources(civId) {
            guard let r = rs.resources[e.resource], !r.isStockpiled, !r.uniqueObjects.contains(where: { $0.pattern == "Cannot be traded" }) else { continue }
            if seen.insert(e.resource).inserted { out.append(e.resource) }
        }
        return out
    }
    /// Unciv TradeLogic.getAvailableOffers: non-bonus resources offered with their tradable amount
    func exportableResources(_ civId: Int) -> [String] {
        tradableResourceSupply(civId).filter { name, e in rs.resources[name]?.resourceType != "Bonus" && e.tradable > 0 }.map { $0.key }.sorted()
    }
    /// Unciv OffersListScroll untradableOffers
    func untradableResourceCount(_ civId: Int, _ resource: String) -> Int { tradableResourceSupply(civId)[resource]?.untradable ?? 0 }

    /// Unciv TradeLogic.getAvailableOffers, the Open Borders line, for `giver` offering them to `receiver`:
    /// `giver.meetsEmbassyRequirementFor(receiver) && !receiver.getDiplomacyManager(giver).hasOpenBorders` and both
    /// civs have the unique. The arguments are (receiver, giver), as every caller passes them; ours tested the
    /// borders the other way round - whether the GIVER could already enter the receiver's land.
    /// `ignoringWar`: TradeLogic.getAvailableOffers lists Open Borders even between civs at war (only the AI's own
    /// offers ask about war), so the trade table passes true
    func canOpenBorders(_ receiver: Int, _ giver: Int, ignoringWar: Bool = false) -> Bool {
        func enabled(_ c: Civilization) -> Bool { c.techs.contains(where: { rs.techs[$0]?.uniqueObjects.contains(where: { $0.pattern == "Enables Open Borders agreements" }) == true }) }
        guard let r = civ(receiver), let g = civ(giver), enabled(r), enabled(g), advancedDiplomacyAllowed(giver, receiver) else { return false }
        return (ignoringWar || !areAtWar(receiver, giver)) && !hasOpenBorders(receiver, in: giver)
    }

    /// Unciv DiplomacyFunctions.getResearchAgreementCost: `(max(both eras' cost) * speed.goldCostModifier).toInt()`, in Float.
    func researchAgreementCost(_ civId: Int, with other: Int? = nil) -> Double {
        let mine = rs.era(named: civ(civId)?.eraName ?? "")?.researchAgreementCost ?? 300
        let theirs = other.flatMap { rs.era(named: civ($0)?.eraName ?? "")?.researchAgreementCost } ?? mine
        return Double(Int(Float(max(mine, theirs)) * Float(speed.goldCostModifier)))
    }
    /// Unciv DiplomacyFunctions.canSignResearchAgreement: a major civ with the unique and not
    /// `tech.allTechsAreResearched()` - which turns true once Future Tech has been researched once, where
    /// "is anything researchable?" never does (Future Tech stays researchable for ever).
    private func canSignResearchAgreement(_ c: Civilization) -> Bool {
        c.isMajor && c.techs.contains { rs.techs[$0]?.uniques.contains(where: { $0.hasPrefix("Enables Research agreements") }) == true } && !allTechsResearched(c.id)
    }
    /// Unciv DiplomacyFunctions.canSignResearchAgreementWith: the no-cost checks, and both can pay.
    func canResearchAgreement(_ a: Int, _ b: Int) -> Bool {
        guard let civA = civ(a), let civB = civ(b) else { return false }
        let cost = researchAgreementCost(a, with: b)
        return canResearchAgreementNoCost(a, b) && civA.gold >= cost && civB.gold >= cost
    }
    /// Unciv DiplomacyFunctions.canSignResearchAgreementNoCostWith: both can sign, the embassy requirement, a
    /// Declaration of Friendship, and neither side's ResearchAgreement flag is up. (Ours had an extra "not at war".)
    func canResearchAgreementNoCost(_ a: Int, _ b: Int) -> Bool {
        guard let civA = civ(a), let civB = civ(b) else { return false }
        return canSignResearchAgreement(civA) && canSignResearchAgreement(civB) && advancedDiplomacyAllowed(a, b)
            && hasFlag(a, b, "DeclarationOfFriendship") && !hasFlag(a, b, "ResearchAgreement") && !hasFlag(b, a, "ResearchAgreement")
    }
    /// Unciv TradeLogic.transferTrade, the Research Agreement treaty: both pay the offer's amount and each side's
    /// ResearchAgreement flag is set to the offer's duration. The treaty offers themselves come with the trade.
    func signResearchAgreement(receiver to: Int, giver from: Int, cost: Double, duration: Int) {
        guard let ti = civIndex(to), let fi = civIndex(from) else { return }
        civs[ti].gold -= cost
        civs[fi].gold -= cost
        setFlag(to, from, "ResearchAgreement", duration)
        setFlag(from, to, "ResearchAgreement", duration)
    }

    /// The diplomacy screen's shortcut: the research agreement as the trade it is in Unciv (both sides' Treaty offer).
    @discardableResult
    func signResearchAgreement(_ a: Int, _ b: Int) -> Bool {
        guard canResearchAgreement(a, b) else { return false }
        var o = TradeOffer(id: newId(), from: a, to: b, turnCreated: turn)
        let cost = Int(researchAgreementCost(a, with: b))   // the offer's amount, as TradeLogic.getAvailableOffers prices it
        o.give.researchAgreement = true; o.want.researchAgreement = true
        o.give.researchAgreementCost = cost; o.want.researchAgreementCost = cost
        return executeTrade(o)
    }

    /// Unciv: a plain peace-for-peace trade is acceptable when TradeEvaluation says the AI owes nothing (and is not planning an attack).
    func aiAcceptsPeace(_ ai: Int, with other: Int) -> Bool {
        guard let civAI = civ(ai), civAI.isAtWar(with: other), !hasFlag(ai, other, "DeclaredWar") else { return false }
        var offer = TradeOffer(id: -1, from: other, to: ai, turnCreated: turn)
        offer.give.peace = true; offer.want.peace = true
        return tradeAcceptability(offer, evaluator: ai) >= 0
    }

    /// What a deal is called in a notification, as Unciv names the TradeOffer.
    func dealOfferName(_ d: Deal) -> String { d.offerName }

    /// Round-level trade bookkeeping. Everything Unciv does with trades happens inside a civ's own turn now
    /// (DiplomacyTurnManager per pair, TurnManager.startTurn for the requests); nothing is left for the round.
    func dealsTurn() {}

    /// Unciv TurnManager.startTurn, for the civ holding the requests: a request whose proposer is defeated or whose
    /// trade is no longer valid is withdrawn, and the proposer hears "Our proposed trade is no longer relevant!".
    /// Ours did this once for everyone after the whole round, and only told human proposers.
    /// (Our pending Declarations of Friendship are Unciv popupAlerts, not tradeRequests: this leaves them to
    /// respondToDeclarationOfFriendship, which turns one that can no longer be signed down - DeclinedDeclarationOfFriendship.)
    func removeUntenableTradeRequests(_ civId: Int) {
        // `civInfo.tradeRequests` only (TurnManager.kt:85-90): a Declaration of Friendship is a popup alert there, kept for
        // respondToPopupAlerts to decline (a state comparison, a test game, turn 146: ours withdrew Polynesia's offer at Austria's turn
        // start, now at war, and told Polynesia "Our proposed trade is no longer relevant!")
        for o in pendingOffers where o.to == civId && !(o.give.friendship && o.want.friendship) {
            guard civ(o.from)?.isAlive == false || !tradeIsValid(o) else { continue }
            pendingOffers.removeAll { $0.id == o.id }
            notify(o.from, "Our proposed trade is no longer relevant!", category: .Trade, icons: ["Trade"])
            // Unciv: "If it's a counteroffer, remove notification" - every notification of the holder that reads
            // "[${offeringCiv.civName}] has made a counteroffer to your trade request" (TurnManager.kt:85-95)
            if let from = civ(o.from) { removeAllNotifications(civId: civId, text: "[\(from.nation)] has made a counteroffer to your trade request") }
        }
    }

    // MARK: - DiplomacyTurnManager, the trade part (one pair, in the civ's own endTurn)

    private struct OfferKey: Equatable { let kind: Deal.Kind; let name: String; let amount: Int; let duration: Int }

    /// One timed offer of a trade's list: its Peace Treaty, or one of its deals
    enum TradeListItem: Equatable { case peace, deal(Int) }

    /// The timed offers `giver` put into one trade (the deals at `group`), in the order `giver`'s list of the trade holds
    /// them - Unciv's TradeOffersList, in the order they were added: getAvailableOffers' order (the Peace Treaty, Open
    /// Borders, the research agreement, the defensive pact, the resources as the side lists them, gold per turn), the
    /// offers the record names past it (`tail`: a counteroffer's additions, the player's clicks, a loaded save's list)
    /// last, in that order (uncivOfferOrder, as the Trades overview and the Unciv file list them). A deal group with no
    /// record (`side` nil, a save from before the records) in getAvailableOffers' order.
    func tradeListOrder(_ group: [Int], giver: Int, side: TradeSide?, tail: [String], peace: Bool) -> [TradeListItem] {
        let mine = group.filter { deals[$0].from == giver }
        var resourceOrder: [String] = []
        for r in side?.resources ?? [] where !resourceOrder.contains(r) { resourceOrder.append(r) }
        func rank(_ i: Int) -> (Int, Int) {
            let d = deals[i]
            return (d.canonicalRank, d.kind == .resource ? (resourceOrder.firstIndex(of: d.resource ?? "") ?? resourceOrder.count) : 0)
        }
        var canonical: [(name: String, item: TradeListItem)] = peace ? [("Peace Treaty", .peace)] : []
        canonical += mine.enumerated().sorted { (rank($0.element).0, rank($0.element).1, $0.offset) < (rank($1.element).0, rank($1.element).1, $1.offset) }.map { (deals[$0.element].offerName, .deal($0.element)) }
        return uncivOfferOrder(canonical, name: { $0.name }, tail: tail).map(\.item)
    }

    /// `civId`'s copy of each trade with `other`, as lists of deal indices, trades in the order they were agreed.
    func tradeGroups(_ civId: Int, _ other: Int) -> [[Int]] {
        var order: [Int] = []
        var groups: [Int: [Int]] = [:]
        for (i, d) in deals.enumerated() where ((d.from == civId && d.to == other) || (d.from == other && d.to == civId)) && d.exists(for: civId) {
            let k = d.tradeId != 0 ? d.tradeId : -d.id
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(i)
        }
        return order.map { groups[$0]! }
    }

    /// Unciv DiplomacyTurnManager.nextTurnTrades for `civId`'s DiplomacyManager with `other`, trade by trade in the order
    /// civId's list holds them (`for (trade in trades.toList())`; TradeRecord order).
    /// `trade.ourOffers.union(trade.theirOffers).filter { it.duration > 0 }` decrements each offer of this side's
    /// copy - and TradeOffer is a data class, so two EQUAL offers (mutual open borders, the research agreement,
    /// the peace treaty) collapse into one and only ourOffers' goes down: theirOffers stays one behind for good.
    /// The trade is dropped only when every offer has run out; "will end" warnings come from theirOffers.
    /// The Peace Treaty is a Treaty offer on both sides of its trade; this side's copy is `peaceTreatyUntil`. This runs at
    /// civId's own end of turn with civId already in diplomacyTurnDoneThisRound, so its ourOffers has just come to
    /// `until - turn - 1` (turnsToPeaceTreaty) and theirOffers - one behind, which the warnings read - to
    /// peaceTreatyTheirOffersLeft. A trade holding only the treaty (the one that ended a war, a PeaceProposal, an ally's
    /// peace, each trade remakePeaceTreaty made) warns and ends in its own place in the list - after trades made before
    /// it, before trades made after it; a treaty traded together with timed offers (gold per turn, a resource) warns
    /// with its trade, ahead of its other offers, and is announced only when that whole trade goes.
    func nextTurnTrades(_ civId: Int, _ other: Int) {
        let otherName = civ(other)?.nation ?? "?"
        let k = "\(civId)>\(other)"
        // EVLOG: Unciv drops a trade with no timed offer here, in its place in the trades list (start order).
        var instantEnds: [(seq: Int, summary: String)] = []
        var peaceEnds: [(seq: Int, summary: String)] = []   // EVLOG: the trades holding only the treaty, in start order
        if GameState.evlogOn, EvLog.game === self {
            let list = EvLog.pendingInstantTradeEnds.removeValue(forKey: k) ?? []
            let seqs = EvLog.pendingSeq.removeValue(forKey: "I|\(k)") ?? []
            instantEnds = list.enumerated().map { ($0.offset < seqs.count ? seqs[$0.offset] : -1, $0.element) }
            let plist = EvLog.pendingPeaceTradeEnds[k] ?? [], pseqs = EvLog.pendingSeq["P|\(k)"] ?? []
            peaceEnds = plist.enumerated().map { ($0.offset < pseqs.count ? pseqs[$0.offset] : -1, $0.element) }
        }
        func flushInstantEnds(before seq: Int) {
            while let f = instantEnds.first, f.seq < seq { ev(civId, "TRADE", evOtherName(other), "end", f.summary); instantEnds.removeFirst() }
        }
        let peaceTheirs = peaceTreatyTheirOffersLeft(civId, other)
        // the shown game's treaty offers this count reaches (SharedTradeOffers): one of the copy's two - `ourOffers.union(
        // theirOffers).filter { it.duration > 0 }` - whenever its theirOffers had a turn left before this end of turn
        if let shared = sharedTradeOffers, shared.peace.contains(SharedTradeOffers.key(civId, other)), let c = civ(civId), let until = c.peaceTreatyUntil[other] {
            let oursBefore = until - turn
            let theirsBefore = c.peaceTreatySharedOffer.contains(other) ? oursBefore : min(oursBefore + 1, c.peaceTreatyStartDuration[other] ?? Int.max)
            if theirsBefore > 0 { shared.countedPeace.append((civId, other)) }
        }
        func peaceNotice(_ text: String) { notify(civId, "[Peace Treaty] from [\(otherName)] \(text)", category: .Trade, icons: [otherName, "Trade"], actions: [.diplomacyTrade(otherName)]) }
        /// `for (offer in trade.theirOffers.filter { it.duration <= 3 })`, for the treaty's offer: 3 and 1 warn
        func peaceWarning() {
            if peaceTheirs == 3 { peaceNotice("will end in [3] turns") } else if peaceTheirs == 1 { peaceNotice("will end next turn") }
        }
        // civId's list: each deal group at its trade's record, each trade holding only the treaty at its own (none before
        // the records were kept: the treaty heads the list, the deal groups follow in the order they were made)
        let records = tradeRecords.indices.filter { tradeRecords[$0].involves(civId, other) && tradeRecords[$0].exists(for: civId) }
        func hasDeals(_ r: Int) -> Bool { let id = tradeRecords[r].id; return id > 0 && deals.contains { $0.tradeId == id && $0.exists(for: civId) } }
        var peaceOnly = records.filter { tradeRecords[$0].sides(for: civId).theirs.peace && !hasDeals($0) }.map { $0 }
        if peaceOnly.isEmpty, (peaceTheirs ?? -1) >= 0, !records.contains(where: { tradeRecords[$0].hasPeace }) { peaceOnly = [-2] }
        enum Entry { case group([Int]), peace(Int) }
        var entries: [(pos: Int, entry: Entry)] = tradeGroups(civId, other).map { g in
            let tid = deals[g[0]].tradeId
            return (records.first { tradeRecords[$0].id == tid && tid > 0 } ?? -1, .group(g))
        }
        for (n, r) in peaceOnly.enumerated() { entries.append((r, .peace(n))) }
        let ordered = entries.enumerated().sorted { ($0.element.pos, $0.offset) < ($1.element.pos, $1.offset) }.map { $0.element.entry }
        var peaceEnded: [Int] = []
        for entry in ordered {
            switch entry {
            case .peace(let n):
                // a trade of the treaty alone: both its offers at 0 after this count - theirOffers last - drop it
                if !instantEnds.isEmpty, n < peaceEnds.count { flushInstantEnds(before: peaceEnds[n].seq) }
                if let t = peaceTheirs, t <= 0 {
                    if GameState.evlogOn, n < peaceEnds.count { ev(civId, "TRADE", evOtherName(other), "end", peaceEnds[n].summary); peaceEnded.append(n) }   // EVLOG: trades.remove
                    peaceNotice("has ended")
                    updateStatsForNextTurn(civId)
                }
                peaceWarning()
            case .group(let group):
                if !instantEnds.isEmpty { let tid = deals[group[0]].tradeId; flushInstantEnds(before: (tid != 0 ? EvLog.tradeSeq["\(tid)>\(civId)"] : nil) ?? -1) }
                let tid = deals[group[0]].tradeId
                let rec = tid > 0 ? records.first { tradeRecords[$0].id == tid } : nil
                let withPeace = rec.map { tradeRecords[$0].hasPeace } ?? false
                let ours = group.filter { deals[$0].from == civId }, theirs = group.filter { deals[$0].to == civId }
                // civId's copy of the trade: its ourOffers and theirOffers in their lists' order (the treaty in both)
                let recSides = rec.map { tradeRecords[$0].sides(for: civId) }, recTails = rec.map { tradeRecords[$0].tails(for: civId) }
                let ourList = tradeListOrder(group, giver: civId, side: recSides?.ours, tail: recTails?.ours ?? [], peace: withPeace)
                let theirList = tradeListOrder(group, giver: other, side: recSides?.theirs, tail: recTails?.theirs ?? [], peace: withPeace)
                func key(_ i: Int) -> OfferKey { let d = deals[i]; return OfferKey(kind: d.kind, name: d.offerName, amount: d.offerAmount, duration: d.left(for: civId)) }
                var seen: [OfferKey] = []
                var counted: [Int] = []
                for i in ours + theirs {
                    let k = key(i)
                    if seen.contains(k) { continue }
                    seen.append(k)
                    if k.duration > 0 { counted.append(i) }
                }
                for i in counted { deals[i].setLeft(deals[i].left(for: civId) - 1, for: civId) }
                if let shared = sharedTradeOffers { for i in counted where shared.deals.contains(deals[i].id) { shared.countedDeals.append((deals[i].id, civId)) } }
                // `ourOffers.all { it.duration <= 0 } && theirOffers.all { it.duration <= 0 }` - the treaty's offers too
                if group.allSatisfy({ deals[$0].left(for: civId) <= 0 }) && (!withPeace || (peaceTheirs ?? 0) <= 0) {
                    let resourcesInvolved = group.contains { deals[$0].kind == .resource }
                    // Unciv: `trades.remove(trade)` FIRST, then per ended offer updateStatsForNextTurn / updateCivResources -
                    // so the supply is recomputed without the trade. Ours dropped it after, and the stored supply kept the
                    // ended luxury (t_45 turn 60: Japan's Wine from Carthage stayed, +4 happiness Unciv did not have).
                    for i in group { deals[i].setGone(for: civId) }
                    if GameState.evlogOn { evTradeEnd(civId, other, group) }   // EVLOG: TRADE end (trades.remove)
                    // `for (offer in trade.ourOffers.union(trade.theirOffers).filter { it.duration == 0 })`: ourOffers in its
                    // list's order, then theirOffers' not equal to one of them - the treaty, at 0 since this or an earlier
                    // end of turn, once ("from": it is in theirOffers), in its place among the trade's offers. No
                    // `peaceTreatyUntil` is a treaty over before the game was loaded: the importer reads only a running one,
                    // and a save whose two copies are both at 0 while the gold goes on still announces it here
                    var ended: [OfferKey] = []
                    var peaceTold = false
                    for item in ourList + theirList {
                        switch item {
                        case .peace:
                            if peaceTold { continue }
                            peaceTold = true
                            peaceNotice("has ended")
                            updateStatsForNextTurn(civId)
                            if resourcesInvolved { updateCivResources(civId) }
                        case .deal(let i):
                            let k = key(i)
                            if ended.contains(k) { continue }
                            ended.append(k)
                            guard k.duration == 0 else { continue }   // this was a timed trade
                            let direction = theirs.contains(where: { key($0) == k }) ? "from" : "to"
                            notify(civId, "[\(k.name)] \(direction) [\(otherName)] has ended", category: .Trade, icons: [otherName, "Trade"], actions: [.diplomacyTrade(otherName)])
                            updateStatsForNextTurn(civId)   // if they were bringing us gold per turn
                            if resourcesInvolved { updateCivResources(civId) }
                        }
                    }
                }
                // `for (offer in trade.theirOffers.filter { it.duration <= 3 })`: theirOffers in its list's order
                for item in theirList {
                    switch item {
                    case .peace: peaceWarning()
                    case .deal(let i):
                        let n = deals[i].left(for: civId)
                        if n == 3 { notify(civId, "[\(deals[i].offerName)] from [\(otherName)] will end in [3] turns", category: .Trade, icons: [otherName, "Trade"], actions: [.diplomacyTrade(otherName)]) }
                        else if n == 1 { notify(civId, "[\(deals[i].offerName)] from [\(otherName)] will end next turn", category: .Trade, icons: [otherName, "Trade"], actions: [.diplomacyTrade(otherName)]) }
                    }
                }
            }
        }
        flushInstantEnds(before: .max)
        if GameState.evlogOn, !peaceEnded.isEmpty {   // EVLOG: the treaty trades printed above leave the pending list
            let keep = peaceEnds.indices.filter { !peaceEnded.contains($0) }
            EvLog.pendingPeaceTradeEnds[k] = keep.isEmpty ? nil : keep.map { peaceEnds[$0].summary }
            EvLog.pendingSeq["P|\(k)"] = keep.isEmpty ? nil : keep.map { peaceEnds[$0].seq }
        }
        // The whole trade (TradeRecord) goes from this side's list with the rest of `trades.remove(trade)`: once no timed
        // offer of it still runs here and its peace treaty's theirOffers copy (`until - turn`) is out too - an
        // immediate-only trade at this, its side's first end of turn.
        let peaceLeft = peaceTreatyTheirOffersLeft(civId, other) ?? 0
        for r in tradeRecords.indices where tradeRecords[r].involves(civId, other) && tradeRecords[r].exists(for: civId) {
            let id = tradeRecords[r].id
            let timedLeft = id > 0 && deals.contains { $0.tradeId == id && $0.exists(for: civId) && $0.left(for: civId) > 0 }
            if !timedLeft && (!tradeRecords[r].hasPeace || peaceLeft <= 0) { tradeRecords[r].setGone(for: civId) }
        }
        tradeRecords.removeAll { $0.oursGone && $0.theirsGone }
        deals.removeAll { $0.fromGone && $0.toGone }
    }

    /// PeaceTreatySelfTest's look at what removeUntenableTrades decides on: (civ, other civ, the resources the civ's
    /// stored supply has negative) for each trade of that civ's copy, as `negativeCivResources` is read there.
    nonisolated(unsafe) static var untenableTradesProbe: ((Int, Int, Set<String>) -> Void)? = nil

    /// Unciv DiplomacyTurnManager.removeUntenableTrades for `civId`'s DiplomacyManager with `other`: trade by trade,
    /// a Luxury / Strategic offer of OURS whose resource our stored supply now has negative (or that the ruleset no
    /// longer knows) cancels the whole trade on both sides - on theirs every trade with the same offers too
    /// (Trade.equalTrade); the other civ won't trust our resource offers for
    /// dealDuration × 2 turns. Only our own supply is refreshed. Ours ran once for everyone after the round, and
    /// read a freshly computed supply instead of the stored one.
    ///
    /// "Can't cut short peace treaties!" (DiplomacyTurnManager.kt:49-52, 68-76): a trade whose theirOffers holds the
    /// Peace Treaty is made again as a trade of its own on both sides, every offer of both copies at the duration our
    /// copy's theirOffers had (`trade.theirOffers.first { it.name == peaceTreaty }.duration`, after this end of turn's
    /// nextTurnTrades) - our ourOffers gains the turn it was ahead of theirOffers, the other side's copy takes that
    /// duration whatever its own count was, and a treaty run out while a longer resource offer kept its trade is made at
    /// 0, a trade each side drops at its next end of turn with "[Peace Treaty] from [..] has ended".
    func removeUntenableTrades(_ civId: Int, _ other: Int) {
        let myName = civ(civId)?.nation ?? "?", otherName = civ(other)?.nation ?? "?"
        for group in tradeGroups(civId, other) {
            let supply = civResourceSupply(civId)   // Unciv getCivResourceSupply(): the stored field
            let negative = Set(supply.filter { $0.value < 0 && rs.resources[$0.key]?.isStockpiled != true }.map { $0.key })
            GameState.untenableTradesProbe?(civId, other, negative)
            // `trade.theirOffers.first { it.name == Constants.peaceTreaty }.duration` of this trade, which a second cut
            // offer of the same trade reads again (the remade treaty is a trade of its own)
            let peaceTheirOffers = max(0, peaceTreatyTheirOffersLeft(civId, other) ?? 0)
            var endSummary: String? = nil   // EVLOG: this trade's TRADE end, which the reference prints again for each cut offer
            for i in group where deals[i].from == civId && deals[i].kind == .resource {
                let name = deals[i].resource ?? ""
                guard negative.contains(name) || rs.resources[name] == nil else { continue }
                if GameState.evlogOn {   // EVLOG: TRADE end (trades.remove) - every cut offer of the trade prints it
                    if let s = endSummary { ev(civId, "TRADE", evOtherName(other), "end", s) } else { endSummary = evTradeEnd(civId, other, group) }
                }
                for j in group { deals[j].setGone(for: civId) }
                // `otherCivTrades.removeAll { it.equalTrade(trade.reverse()) }`: the other side loses its copy of this
                // trade and of every trade with the same offers (the duration aside), in its list's order; our own
                // copies of those stay, so we keep giving and receiving what they hold.
                let cut = tradeContent(ofGroup: group)
                for g in tradeGroups(other, civId) where g.contains(group[0]) || GameState.equalTrade(tradeContent(ofGroup: g), cut, civId, other) {
                    if GameState.evlogOn { evTradeEnd(other, civId, g) }   // EVLOG: TRADE end for the other side
                    for j in g { deals[j].setGone(for: other) }
                    // ...and its whole-trade copy the Trades overview lists (TradeRecord)
                    let gid = deals[g[0]].tradeId
                    if gid > 0 { for r in tradeRecords.indices where tradeRecords[r].id == gid && tradeRecords[r].involves(civId, other) { tradeRecords[r].setGone(for: other) } }
                }
                // The whole trade (TradeRecord) goes the same way: our copy (`trades.remove(trade)`) and the other side's copy
                // of it; "Can't cut short peace treaties!" - `if (trade.theirOffers.any { it.name == Constants.peaceTreaty })
                // remakePeaceTreaty(..duration)`: a trade of its own, `treaty` with two offers at that duration in our list
                // and `treaty.reverse()` in theirs (addPeaceTreaty: both copies, the record, the start duration)
                let tid = deals[group[0]].tradeId
                if tid > 0, let r = tradeRecords.firstIndex(where: { $0.id == tid && $0.involves(civId, other) }) {
                    tradeRecords[r].setGone(for: civId); tradeRecords[r].setGone(for: other)
                    if tradeRecords[r].sides(for: civId).theirs.peace {
                        addPeaceTreaty(civId, other, duration: peaceTheirOffers)
                        if GameState.evlogOn { evPeaceTreatyStart(civId, other) }   // EVLOG: remakePeaceTreaty's two `trades.add`
                    }
                }
                notify(civId, "One of our trades with [\(otherName)] has been cut short", category: .Trade, icons: ["Trade", otherName], actions: [.diplomacyTrade(otherName)])
                notify(other, "One of our trades with [\(myName)] has been cut short", category: .Trade, icons: ["Trade", myName], actions: [.diplomacyTrade(myName)])
                setFlag(other, civId, "ResourceTradesCutShort", speed.dealDuration * 2)
                updateCivResources(civId)
            }
        }
        tradeRecords.removeAll { $0.oursGone && $0.theirsGone }
        deals.removeAll { $0.fromGone && $0.toGone }
    }

    /// The offers of a trade (a group of deal indices): what it stored when it was agreed, or - for a save from before
    /// that - its timed offers, all the deals hold.
    func tradeContent(ofGroup group: [Int]) -> [TradeOfferContent] {
        if let first = group.first, !deals[first].tradeContent.isEmpty { return deals[first].tradeContent }
        return group.map { i in
            let d = deals[i]
            let type: String
            switch d.kind {
            case .resource: type = rs.resources[d.resource ?? ""]?.resourceType == "Strategic" ? "Strategic_Resource" : "Luxury_Resource"
            case .goldPerTurn: type = "Gold_Per_Turn"
            case .openBorders: type = "Agreement"
            case .researchAgreement, .defensivePact: type = "Treaty"
            }
            return TradeOfferContent(giver: d.from, type: type, name: d.offerName, amount: d.offerAmount)
        }
    }

    /// Unciv Trade.equalTrade: each side holds as many offers in both trades, and every offer of `y` has an equal one
    /// (TradeOffer.equals(offer): name, type, amount - not the duration) on the same side of `x`.
    static func equalTrade(_ x: [TradeOfferContent], _ y: [TradeOfferContent], _ a: Int, _ b: Int) -> Bool {
        for giver in [a, b] where x.filter({ $0.giver == giver }).count != y.filter({ $0.giver == giver }).count { return false }
        for o in y where !x.contains(where: { $0.giver == o.giver && $0.equals(o) }) { return false }
        return true
    }

    /// `trades.add(trade)` on `ours`' side and `trades.add(trade.reverse())` on `theirs`', as the Trades overview keeps it
    /// (TradeRecord). A Declaration of Friendship is not a trade offer in Unciv, so a trade of nothing else is not one.
    /// `ourTail` / `theirTail`: the offers each list holds past getAvailableOffers' order, in the order they were added
    /// (TradeRecord.ourTail).
    func recordTrade(id: Int, ours: Int, theirs: Int, ourSide: TradeSide, theirSide: TradeSide, peaceDuration: Int? = nil, ourTail: [String] = [], theirTail: [String] = []) {
        var a = ourSide, b = theirSide
        a.friendship = false; b.friendship = false
        guard !a.isEmpty || !b.isEmpty else { return }
        var r = TradeRecord(id: id, ours: ours, theirs: theirs, ourSide: a, theirSide: b, peaceDuration: peaceDuration ?? speed.peaceDealDuration)
        r.ourTail = ourTail; r.theirTail = theirTail
        tradeRecords.append(r)
    }
    /// A trade of its own holding a Peace Treaty on both sides (Unciv's PeaceProposal, an ally's peace, remakePeaceTreaty)
    func recordPeaceTrade(_ a: Int, _ b: Int, duration: Int? = nil) {
        var peace = TradeSide(); peace.peace = true
        recordTrade(id: -1, ours: a, theirs: b, ourSide: peace, theirSide: peace, peaceDuration: duration)
    }

    /// Unciv acceptTrade's `trades.add(currentTrade)` and `trades.add(currentTrade.reverse())`, for one timed offer:
    /// both copies start at the offer's duration.
    @discardableResult
    func addTradeDeal(_ kind: Deal.Kind, from: Int, to: Int, resource: String? = nil, amount: Int = 0, duration: Int, tradeId: Int) -> Int {
        var d = Deal(id: newId(), kind: kind, from: from, to: to, resource: resource, turnsLeft: duration)
        d.amount = amount
        d.fromLeft = duration; d.toLeft = duration
        d.tradeId = tradeId
        deals.append(d)
        return deals.count - 1
    }

    /// Unciv DeclareWar.onWarDeclared: `diplomacyManager.trades.clear()` for one side (onWarDeclared announces the
    /// offers it was receiving itself, before this); `notifyEnded` tells them here, deal by deal.
    func clearTrades(of civId: Int, with other: Int, notifyEnded: Bool) {
        let otherName = civ(other)?.nation ?? "?"
        if GameState.evlogOn {   // EVLOG: TRADE end for every trade still in this side's list
            evTradeEndsInStartOrder(civId, other)
        }
        for i in deals.indices where ((deals[i].from == civId && deals[i].to == other) || (deals[i].from == other && deals[i].to == civId)) && deals[i].exists(for: civId) {
            // Unciv `theirOffers.filter { it.duration > 0 && it.name != Constants.defensivePact }`
            if notifyEnded && deals[i].to == civId && deals[i].kind != .defensivePact && deals[i].left(for: civId) > 0 {
                notify(civId, "[\(deals[i].offerName)] from [\(otherName)] has ended", category: .Trade, icons: [otherName, "Trade"], actions: [.diplomacyTrade(otherName)])
            }
            deals[i].setGone(for: civId)
        }
        for r in tradeRecords.indices where tradeRecords[r].involves(civId, other) { tradeRecords[r].setGone(for: civId) }   // the whole trades too
        tradeRecords.removeAll { $0.oursGone && $0.theirsGone }
        deals.removeAll { $0.fromGone && $0.toGone }
    }
}


/// Unciv GameInfo.clone → Civilization.clone → DiplomacyManager.clone takes `trades.map { it.clone() }` (DiplomacyManager.kt:
/// 270), and Trade.clone copies the two lists with `addAll` (Trade.kt:37-42): the clone's trades are new lists holding the
/// original's TradeOffer objects. So WorldScreen.nextTurn's `gameInfoClone.nextTurn()` (WorldScreen.kt:615-621) counts the
/// shown game's offers down with its own - DiplomacyTurnManager.nextTurnTrades' `offer.duration--` (:238), for every offer
/// of a trade still in the clone's list when its civ's turn comes. The shown game stays when an online upload fails
/// (WorldScreen.kt:650-677: failedUpload, no startNewScreenJob), and Retry Upload clones it again (NextTurnAction.kt:30 →
/// worldScreen.nextTurn()), from those durations. Ours decodes the clone afresh (GameState.nextTurnClone): this notes, on
/// the clone, which of the original's offers its countdown reached - the deals and treaties the original held when it
/// was cloned, a treaty no more once the clone drops or remakes it (onWarDeclared, addPeaceTreaty) - and
/// `applySharedTradeCountdown` counts them down on the original.
final class SharedTradeOffers {
    /// The deals (by id) and the treaty copies (`key(a, b)`: a's with b) the original held when it was cloned
    let deals: Set<Int>
    var peace: Set<Int>
    /// The clone's countdown of them, in the order it ran: a deal's copy (its id and the civ whose copy it is), a treaty's
    var countedDeals: [(id: Int, civ: Int)] = []
    var countedPeace: [(a: Int, b: Int)] = []
    static func key(_ a: Int, _ b: Int) -> Int { a &* 1_000_003 &+ b }
    init(of g: GameState) {
        deals = Set(g.deals.map(\.id))
        var p = Set<Int>()
        for c in g.civs { for b in c.peaceTreatyUntil.keys { p.insert(SharedTradeOffers.key(c.id, b)) } }
        peace = p
    }
}

extension GameState {
    /// Unciv's original after its clone's countdown (SharedTradeOffers): each offer the clone counted is a turn shorter -
    /// a deal's copy one turn less, a treaty copy's offers a turn further on (`peaceTreatyUntil`, a turn number, one less).
    func applySharedTradeCountdown(_ shared: SharedTradeOffers) {
        for (id, c) in shared.countedDeals {
            guard let i = deals.firstIndex(where: { $0.id == id }) else { continue }
            deals[i].setLeft(deals[i].left(for: c) - 1, for: c)
        }
        for (a, b) in shared.countedPeace {
            guard let ai = civIndex(a), let until = civs[ai].peaceTreatyUntil[b] else { continue }
            civs[ai].peaceTreatyUntil[b] = until - 1
        }
    }
}
