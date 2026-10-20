// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// One timed offer of a trade (Unciv `TradeOffer` with a duration), as it sits in BOTH sides' copies of the trade.
///
/// Unciv keeps a trade as two `Trade` objects, one in each side's `DiplomacyManager.trades` (`acceptTrade` adds
/// `currentTrade` to ours and `currentTrade.reverse()` to theirs), and each side counts its own copy down in its
/// own `endTurn` (DiplomacyTurnManager.nextTurnTrades). A deal is one offer of that trade: `from` gives it, so it
/// is in `from`'s `ourOffers` and in `to`'s `theirOffers`; `fromLeft` / `toLeft` are the two copies' durations.
/// Offers agreed together share a `tradeId`, because Unciv drops a trade only when ALL its offers have run out,
/// and until then every offer of it - a resource, gold per turn - still counts (resourcesFromTrade, goldPerTurn).
struct Deal: Codable, Identifiable {
    enum Kind: String, Codable { case resource, openBorders, researchAgreement, goldPerTurn, defensivePact }
    let id: Int
    let kind: Kind
    let from: Int          // provider (resource / borders opened by)
    let to: Int
    var resource: String? = nil
    var turnsLeft: Int
    @Lenient var amount: Int = 0   // gold per turn; copies of a resource; the research agreement's cost
    @Lenient var raScienceFrom: Double = 0   // legacy: Unciv DiplomacyManager.totalOfScienceDuringRA now lives in Civilization.totalOfScienceDuringRA
    @Lenient var raScienceTo: Double = 0     // legacy
    @Lenient var tradeId: Int = 0            // Unciv Trade: deals agreed together live and die together
    /// The two copies' durations; -1 means "not split yet" and falls back to `turnsLeft`.
    @Lenient var fromLeft: Int = -1
    @Lenient var toLeft: Int = -1
    /// The side's copy of the whole trade has been removed (Unciv `trades.remove(trade)` in that side's
    /// nextTurnTrades, removeUntenableTrades or onWarDeclared).
    @Lenient var fromGone: Bool = false
    @Lenient var toGone: Bool = false
    /// Unciv Trade: every offer of the trade this deal belongs to - the immediate ones too (gold, a city, the peace
    /// treaty...), which stay in the stored Trade until it is dropped - as Trade.equalTrade compares them. Empty for
    /// a save from before it was kept: the group's own timed offers stand in (GameState.tradeContent(ofGroup:)).
    @Lenient var tradeContent: [TradeOfferContent] = []

    func left(for civId: Int) -> Int {
        if civId == from { return fromLeft >= 0 ? fromLeft : turnsLeft }
        if civId == to { return toLeft >= 0 ? toLeft : turnsLeft }
        return turnsLeft
    }
    func gone(for civId: Int) -> Bool { civId == from ? fromGone : civId == to ? toGone : true }
    /// The offer is still in `civId`'s copy of the trade: what Unciv's resourcesFromTrade and goldPerTurn read.
    func exists(for civId: Int) -> Bool { (civId == from || civId == to) && !gone(for: civId) }
    mutating func setLeft(_ v: Int, for civId: Int) {
        if civId == from { fromLeft = v } else if civId == to { toLeft = v }
        turnsLeft = max(fromGone ? 0 : left(for: from), toGone ? 0 : left(for: to))
    }
    mutating func setGone(for civId: Int) { if civId == from { fromGone = true } else if civId == to { toGone = true } }
    /// Unciv TradeOffer.name / TradeOffer.type, the parts of a data-class equality besides amount and duration.
    var offerName: String {
        switch kind {
        case .resource: return resource ?? ""
        case .goldPerTurn: return "Gold per turn"
        case .openBorders: return "Open Borders"
        case .researchAgreement: return "Research Agreement"
        case .defensivePact: return "Defensive Pact"
        }
    }
    /// Where getAvailableOffers - and so a trade made in play - lists this offer among its side's: Open Borders,
    /// the research agreement, the defensive pact, the resources, gold per turn (TradeOffer.recordOffers' order).
    var canonicalRank: Int {
        switch kind {
        case .openBorders: return 0
        case .researchAgreement: return 1
        case .defensivePact: return 2
        case .resource: return 3
        case .goldPerTurn: return 4
        }
    }
    /// Unciv TradeOffer.amount (Agreement and Treaty offers carry the default 1, the research agreement its cost).
    var offerAmount: Int { kind == .openBorders || kind == .defensivePact ? 1 : (kind == .researchAgreement && amount == 0 ? 1 : max(kind == .resource ? 1 : 0, amount)) }
}

/// One Unciv TradeOffer as Trade.equalTrade compares it - `TradeOffer.equals(offer)`: name, type and amount, never
/// the duration - with the civ whose side of the trade (whose `ourOffers`) holds it.
struct TradeOfferContent: Codable, Equatable {
    var giver: Int
    var type: String     // Unciv TradeOfferType's name
    var name: String
    var amount: Int
    func equals(_ o: TradeOfferContent) -> Bool { o.name == name && o.type == type && o.amount == amount }
}

/// A whole trade as it sits in Unciv's DiplomacyManager.trades - what the Trades overview lists. A `Deal` holds only
/// the timed offers; the immediate ones (gold, an embassy, cities, stockpiles, introductions, war declarations, peace
/// proposals) leave nothing behind, and the Peace Treaty lives in `peaceTreatyUntil`. So each accepted trade (acceptTrade,
/// a PeaceProposal, an ally's peace, remakePeaceTreaty, a loaded Unciv save's trades) also keeps its offers here, one copy
/// per side: a side drops its copy when its own nextTurnTrades finds every offer of it run out - no timed deal of it still
/// counting, its peace treaty over, so an immediate-only trade at that side's next end of turn - or when onWarDeclared,
/// removeUntenableTrades or the civ's destruction clears it. The game reads it only in nextTurnTrades, for a peace treaty
/// that is part of a trade still going on (it ends silently and is announced with the rest of the trade).
struct TradeRecord: Codable {
    /// The trade's tradeId, which its deals carry; -1 for a peace-only trade (it has no deals)
    let id: Int
    /// The civ whose copy lists `ourSide` as ourOffers (acceptTrade's ourCivilization); `theirs` holds the reverse
    let ours: Int
    let theirs: Int
    var ourSide = TradeSide()
    var theirSide = TradeSide()
    /// The Peace Treaty offers' duration when the trade was made (both copies start there, TradeOffer(speed))
    var peaceDuration = 0
    var oursGone = false
    var theirsGone = false
    /// Unciv's `ourOffers` / `theirOffers` are lists in the order their offers were added (TradeOffersList.add appends a
    /// new one): ours keeps each side as TradeSide fields, listed in TradeLogic.getAvailableOffers' order, and these name
    /// the offers added past that order, last and in the order they came - a counteroffer's asks and gifts
    /// (TradeOffer.evTailGive / evTailWant), the player's clicks on the trade screen, a loaded save's lists (every offer).
    @Lenient var ourTail: [String] = []
    @Lenient var theirTail: [String] = []
    func involves(_ a: Int, _ b: Int) -> Bool { (ours == a && theirs == b) || (ours == b && theirs == a) }
    func exists(for civId: Int) -> Bool { civId == ours ? !oursGone : civId == theirs ? !theirsGone : false }
    mutating func setGone(for civId: Int) { if civId == ours { oursGone = true } else if civId == theirs { theirsGone = true } }
    /// `civId`'s copy: its ourOffers and theirOffers
    func sides(for civId: Int) -> (ours: TradeSide, theirs: TradeSide) { civId == ours ? (ourSide, theirSide) : (theirSide, ourSide) }
    /// `civId`'s copy: the order past the canonical one of its ourOffers and theirOffers (`trade.reverse()` keeps each list)
    func tails(for civId: Int) -> (ours: [String], theirs: [String]) { civId == ours ? (ourTail, theirTail) : (theirTail, ourTail) }
    var hasPeace: Bool { ourSide.peace || theirSide.peace }
}

/// Unciv's TradeOffersList order of one side's offers: the canonical ones (`canonical`, getAvailableOffers' order) not
/// named in `tail`, then those of `tail` in its order - what evOfferNames prints and every list of a trade follows.
func uncivOfferOrder<T>(_ canonical: [T], name: (T) -> String, tail: [String]) -> [T] {
    guard !tail.isEmpty else { return canonical }
    var ordered = canonical.filter { !tail.contains(name($0)) }
    var seen = Set<String>()
    for n in tail where seen.insert(n).inserted { ordered += canonical.filter { name($0) == n } }
    return ordered
}

/// One offer of a trade as a civ's copy holds it: Unciv TradeOffer's name, type and amount, the duration that copy has
/// left (-1 for an immediate one) and its getOfferText (empty when not asked for)
struct TradeOverviewOffer { let name: String; let type: String; let amount: Int; let text: String; let duration: Int }
/// One trade in a civ's copy: our offers beside theirs
struct TradeOverviewRow { let ours: [TradeOverviewOffer]; let theirs: [TradeOverviewOffer] }

extension GameState {
    /// Unciv `viewingPlayer.diplomacy[other].trades`: every trade `me`'s copy still holds with each civ, in the order
    /// they were added - what the Trades overview's "Current trades" lists and what the Unciv file writes as that civ's
    /// `diplomacy[other].trades` (UncivSave.exportJSON). A trade is a TradeRecord; deals and a peace treaty without one (a
    /// save from before the records) are shown from what is left of them. `withText`: each offer's getOfferText too.
    func currentTrades(_ me: Civilization, withText: Bool = true) -> [Int: [TradeOverviewRow]] {
        let s = self
        var byCiv: [Int: [TradeOverviewRow]] = [:]
        let recorded = s.tradeRecords.filter { $0.exists(for: me.id) }
        // Deals whose trade has no record: the deals agreed together (tradeId) in id order, trades by their first deal
        var groups: [Int: [Deal]] = [:]
        for d in s.deals where (d.from == me.id || d.to == me.id) && d.exists(for: me.id) && !recorded.contains(where: { $0.id == d.tradeId && d.tradeId > 0 }) {
            groups[d.tradeId == 0 ? -d.id : d.tradeId, default: []].append(d)
        }
        for g in groups.values.map({ $0.sorted { $0.id < $1.id } }).sorted(by: { $0[0].id < $1[0].id }) {
            let other = g[0].from == me.id ? g[0].to : g[0].from
            // in getAvailableOffers' order, as a trade made in play lists them (Deal.canonicalRank)
            func rows(_ list: [Deal]) -> [TradeOverviewOffer] { list.enumerated().sorted { ($0.element.canonicalRank, $0.offset) < ($1.element.canonicalRank, $1.offset) }.map(\.element).map { TradeOverviewOffer(name: $0.offerName, type: dealOfferType($0), amount: $0.offerAmount, text: withText ? dealOfferText($0, me) : "", duration: $0.left(for: me.id)) } }
            byCiv[other, default: []].append(TradeOverviewRow(ours: rows(g.filter { $0.from == me.id }), theirs: rows(g.filter { $0.from != me.id })))
        }
        // A peace treaty still running in our copy with no record of its trade
        for other in me.peaceTreatyUntil.keys where s.peaceTreatyTradeRunning(me.id, other) && !recorded.contains(where: { $0.hasPeace && $0.involves(me.id, other) }) {
            var peace = TradeSide(); peace.peace = true
            byCiv[other, default: []].insert(TradeOverviewRow(ours: recordOffers(me, peace, giver: me.id, other: other, tradeId: -1, ourList: true, peaceStart: s.speed.peaceDealDuration, withText: withText),
                                                              theirs: recordOffers(me, peace, giver: other, other: other, tradeId: -1, ourList: false, peaceStart: s.speed.peaceDealDuration, withText: withText)), at: 0)
        }
        for r in recorded {
            let other = r.ours == me.id ? r.theirs : r.ours
            let sides = r.sides(for: me.id), tails = r.tails(for: me.id)
            byCiv[other, default: []].append(TradeOverviewRow(ours: recordOffers(me, sides.ours, giver: me.id, other: other, tradeId: r.id, ourList: true, peaceStart: r.peaceDuration, withText: withText, tail: tails.ours),
                                                              theirs: recordOffers(me, sides.theirs, giver: other, other: other, tradeId: r.id, ourList: false, peaceStart: r.peaceDuration, withText: withText, tail: tails.theirs)))
        }
        return byCiv
    }

    /// Unciv TradeOfferType of a timed deal
    private func dealOfferType(_ d: Deal) -> String {
        switch d.kind {
        case .resource: return rs.resources[d.resource ?? ""]?.resourceType == "Strategic" ? "Strategic_Resource" : "Luxury_Resource"
        case .goldPerTurn: return "Gold_Per_Turn"
        case .openBorders: return "Agreement"
        case .researchAgreement, .defensivePact: return "Treaty"
        }
    }

    /// Unciv TradeOffer.getOfferText: the name, " (amount)" for counted offers, the research agreement's cost, then the turns
    private func dealOfferText(_ d: Deal, _ me: Civilization) -> String {
        let name: String
        switch d.kind {
        case .resource: name = "\(L(d.resource ?? "")) (\(max(1, d.amount)))"
        case .openBorders: name = L("Open Borders")
        case .researchAgreement: name = "\(L("Research Agreement")) (-\(d.amount)💰)"
        case .defensivePact: name = L("Defensive Pact")
        case .goldPerTurn: name = "\(L("Gold per turn")) (\(d.amount))"
        }
        let left = d.left(for: me.id)
        return left > 0 ? "\(name)\n\(left)⏳" : name
    }

    /// Unciv TradeOffer.getOfferText for each offer `giver` put into a recorded trade, with the duration `me`'s copy has
    /// left: none for the immediate ones (-1), a timed one's from its deal (0 once it has run out), the peace treaty's
    /// from `peaceTreatyUntil` - our copy's ourOffers loses a turn at each of our ends of turn, and its theirOffers,
    /// equal to it at first, only from the second on (`ourOffers.union(theirOffers)` holds one of two equal offers) -
    /// but along with it in a PeaceProposal giver's copy, one offer in both lists (peaceTreatyTheirOffersLeft).
    /// In the order the side's list holds them (uncivOfferOrder): offerTexts' order, then the offers added past it (`tail`).
    private func recordOffers(_ me: Civilization, _ side: TradeSide, giver: Int, other: Int, tradeId: Int, ourList: Bool, peaceStart: Int, withText: Bool, tail: [String] = []) -> [TradeOverviewOffer] {
        let s = self
        var out: [TradeOverviewOffer] = []
        func left(_ kind: Deal.Kind, _ resource: String? = nil) -> Int {
            guard tradeId > 0, let d = s.deals.first(where: { $0.tradeId == tradeId && $0.kind == kind && $0.from == giver && (resource == nil || $0.resource == resource) && $0.exists(for: me.id) }) else { return 0 }
            return d.left(for: me.id)
        }
        // `if (duration > 0) offerText += "\n" + duration + Fonts.turn`
        // `text` is an autoclosure: getOfferText is worked out only when asked for (the overview, not the Unciv file)
        func add(_ name: String, _ type: String, _ amount: Int, _ text: @autoclosure () -> String, _ duration: Int) {
            let t = withText ? text() : ""
            out.append(TradeOverviewOffer(name: name, type: type, amount: amount, text: withText && duration > 0 ? "\(t)\n\(duration)⏳" : t, duration: duration))
        }
        if side.embassy { add("Accept Embassy", "Embassy", 1, L("Accept Embassy"), -1) }
        if side.peace {
            add("Peace Treaty", "Treaty", 1, L("Peace Treaty"), ourList ? s.turnsToPeaceTreaty(me.id, other) : min(peaceStart, max(0, s.peaceTreatyTheirOffersLeft(me.id, other) ?? 0)))
        }
        if side.openBorders { add("Open Borders", "Agreement", 1, L("Open Borders"), left(.openBorders)) }
        if side.researchAgreement { add("Research Agreement", "Treaty", side.researchAgreementCost, "\(L("Research Agreement")) (-\(side.researchAgreementCost)💰)", left(.researchAgreement)) }
        if side.defensivePact { add("Defensive Pact", "Treaty", 1, L("Defensive Pact"), left(.defensivePact)) }
        var seen = Set<String>()
        for r in side.resources where seen.insert(r).inserted {
            let n = side.resources.filter { $0 == r }.count
            add(r, s.rs.resources[r]?.resourceType == "Strategic" ? "Strategic_Resource" : "Luxury_Resource", n, "\(L(r)) (\(n))", left(.resource, r))
        }
        for r in side.stockpiles.filter({ $0.value > 0 }).map(\.key).sorted() { add(r, "Stockpiled_Resource", side.stockpiles[r] ?? 0, "\(L(r)) (\(side.stockpiles[r] ?? 0))", -1) }
        if side.gold > 0 { add("Gold", "Gold", side.gold, "\(L("Gold")) (\(side.gold))", -1) }
        if side.goldPerTurn > 0 { add("Gold per turn", "Gold_Per_Turn", side.goldPerTurn, "\(L("Gold per turn")) (\(side.goldPerTurn))", left(.goldPerTurn)) }
        // `city?.run { "{$name} (${population.population})" } ?: "Non-existent city"` - TradeOffer(city.id, City)
        // the name is the city's id, the one the Unciv file writes for it (uncivCityId)
        for c in side.cities { if let city = s.city(c) { add(s.uncivCityId(c), "City", 1, "\(L(city.name)) (\(city.population))", -1) } else { add(s.uncivCityId(c), "City", 1, L("Non-existent city"), -1) } }
        for x in side.introductions { add(s.civ(x)?.nation ?? "?", "Introduction", 1, L("Introduction to [\(s.civ(x)?.nation ?? "?")]"), -1) }
        for w in side.warOns { add(s.civ(w)?.nation ?? "?", "WarDeclaration", 1, L("Declare war on [\(s.civ(w)?.nation ?? "?")]"), -1) }
        for x in side.peaceWith { add(s.civ(x)?.nation ?? "?", "PeaceProposal", 1, L("Make peace with [\(s.civ(x)?.nation ?? "?")]"), -1) }
        return uncivOfferOrder(out, name: \.name, tail: tail)
    }

    /// A list's order past getAvailableOffers' (`tail`, TradeOffer.evTailGive) after one change of the side, whose offers
    /// were `before` and are `after` (evOfferNames): TradeOffersList.add appends an offer it did not hold, an offer taken
    /// out leaves the list, one still there keeps its place.
    func followOfferOrder(_ tail: [String], before: [String], after: [String]) -> [String] {
        var t = tail.filter { after.contains($0) }
        for n in after where !before.contains(n) { t.removeAll { $0 == n }; t.append(n) }
        return t
    }

    /// Unciv City.id: the id a city carries in the Unciv file (its `id`, a TradeOffer of the city's name, the keys of
    /// CivConstructions' free buildings) - the one read from the save or made by CityFounder (`uncivId`), which every
    /// city-scoped roll hashes; the port's own id only for a city from before it was kept.
    func uncivCityId(_ id: Int) -> String {
        guard let c = city(id) else { return "\(id)" }
        return c.uncivId.isEmpty ? "\(c.id)" : c.uncivId
    }
}
