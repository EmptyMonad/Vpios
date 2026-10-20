// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// One side of a multi-item trade: what a civilization puts on the table.
struct TradeSide: Codable, Equatable {
    var gold: Int = 0
    var goldPerTurn: Int = 0          // paid for 30 turns
    var resources: [String] = []
    /// Unciv TradeOfferType.Stockpiled_Resource: handed over at once rather than as a standing deal.
    var stockpiles: [String: Int] = [:]
    var openBorders = false
    var embassy = false
    var researchAgreement = false     // mutual; both pay the agreement cost
    /// Unciv TradeOffer.amount of the Research Agreement treaty: its cost, fixed when the offer is made
    /// (DiplomacyAutomation.offerResearchAgreement, TradeLogic.getAvailableOffers) - what TradeEvaluation rates
    /// (`-offer.amount`) and acceptTrade charges both sides, however the eras have moved since.
    var researchAgreementCost = 0
    var peace = false                 // mutual
    var cities: [Int] = []
    /// Unciv TradeOfferType.WarDeclaration: one offer per civ the giver declares war on - a counteroffer can ask
    /// for several. `warOn` is the single-war view the proposals and the trade screen use.
    var warOns: [Int] = []
    var warOn: Int? {
        get { warOns.first }
        set { warOns = newValue.map { [$0] } ?? [] }
    }
    var friendship = false            // mutual Declaration of Friendship
    var defensivePact = false         // mutual
    var introductions: [Int] = []     // Unciv TradeOfferType.Introduction: civs the giver introduces to the receiver
    var peaceWith: [Int] = []         // Unciv TradeOfferType.PeaceProposal: third civs (at war with the giver) the giver makes peace with
    var isEmpty: Bool { gold == 0 && goldPerTurn == 0 && resources.isEmpty && stockpiles.values.allSatisfy { $0 == 0 } && introductions.isEmpty && peaceWith.isEmpty && !openBorders && !embassy && !researchAgreement && !peace && cities.isEmpty && warOns.isEmpty && !friendship && !defensivePact }
    init() {}
    private enum CodingKeys: String, CodingKey { case gold, goldPerTurn, resources, stockpiles, openBorders, embassy, researchAgreement, researchAgreementCost, peace, cities, warOns, friendship, defensivePact, introductions, peaceWith }
    private enum LegacyKeys: String, CodingKey { case warOn }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gold = try c.decodeIfPresent(Int.self, forKey: .gold) ?? 0
        goldPerTurn = try c.decodeIfPresent(Int.self, forKey: .goldPerTurn) ?? 0
        resources = try c.decodeIfPresent([String].self, forKey: .resources) ?? []
        stockpiles = try c.decodeIfPresent([String: Int].self, forKey: .stockpiles) ?? [:]
        openBorders = try c.decodeIfPresent(Bool.self, forKey: .openBorders) ?? false
        embassy = try c.decodeIfPresent(Bool.self, forKey: .embassy) ?? false
        researchAgreement = try c.decodeIfPresent(Bool.self, forKey: .researchAgreement) ?? false
        // -1: a save from before the offer carried its cost; GameState's decoder prices it (legacyResearchAgreementCosts)
        researchAgreementCost = try c.decodeIfPresent(Int.self, forKey: .researchAgreementCost) ?? (researchAgreement ? -1 : 0)
        peace = try c.decodeIfPresent(Bool.self, forKey: .peace) ?? false
        cities = try c.decodeIfPresent([Int].self, forKey: .cities) ?? []
        warOns = try c.decodeIfPresent([Int].self, forKey: .warOns)
            ?? (try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Int.self, forKey: .warOn)).map { [$0] } ?? []
        friendship = try c.decodeIfPresent(Bool.self, forKey: .friendship) ?? false
        defensivePact = try c.decodeIfPresent(Bool.self, forKey: .defensivePact) ?? false
        introductions = try c.decodeIfPresent([Int].self, forKey: .introductions) ?? []
        peaceWith = try c.decodeIfPresent([Int].self, forKey: .peaceWith) ?? []
    }
}

/// A proposal from `from` to `to`: `give` is what the proposer hands over, `want` what the other side hands over.
struct TradeOffer: Codable, Identifiable {
    let id: Int
    let from: Int
    let to: Int
    var give = TradeSide()
    var want = TradeSide()
    var turnCreated: Int = 0
    /// Unciv's TradeOffersList keeps insertion order: the offers a counteroffer adds (TradeAutomation.getCounteroffer,
    /// `theirOffers.addAll(counterofferAsks.keys)` / `ourOffers.addAll(counterofferGifts)`) come after the request's
    /// own. Our sides are sets, so these name the appended offers for the EV log, in the order they were added.
    @Lenient var evTailGive: [String] = []
    @Lenient var evTailWant: [String] = []
}

extension TradeOffer {
    /// The trade screen's staged lists are Unciv TradeOffersLists (OfferColumnsTable.addOffer, openGoldSelectionPopup): an
    /// offer clicked in goes last, one taken back leaves its list (and goes last again if clicked back in), a resource's
    /// second copy or a new gold amount stays where its offer is - after one change from `before`, each list's order past
    /// getAvailableOffers' (evTailGive / evTailWant) follows it: the order the accepted trade keeps (TradeRecord.ourTail),
    /// its Trades overview row and its notifications list it in.
    mutating func followListOrder(from before: TradeOffer, in s: GameState) {
        evTailGive = s.followOfferOrder(evTailGive, before: s.evOfferNames(before.give, other: before.want), after: s.evOfferNames(give, other: want))
        evTailWant = s.followOfferOrder(evTailWant, before: s.evOfferNames(before.want, other: before.give), after: s.evOfferNames(want, other: give))
    }

    /// Ours keeps a Declaration of Friendship offered to an AI as a pending offer (the AI answers it in
    /// respondToTradeRequests); Unciv keeps it as `otherCiv.popupAlerts` DeclarationOfFriendship, apart from
    /// `tradeRequests` - so the trade table, the offer button and the overview never see it as a trade request.
    var isFriendshipRequest: Bool { give.friendship && want.friendship }
}

extension GameState {
    // MARK: valuation


    /// Unciv TradeEvaluation.isTradeValid / isOfferValid: every offer is still something its owner can give. The
    /// offer-time conditions (who may offer open borders, a city not in resistance, a research agreement's
    /// friendship) are TradeLogic.getAvailableOffers' business and are NOT asked again here - ours asked them, so a
    /// request that turned stale in between was refused where Unciv signs it.
    func tradeIsValid(_ o: TradeOffer) -> Bool {
        func sideOK(_ side: TradeSide, owner: Int, other: Int) -> Bool {
            guard let c = civ(owner) else { return false }
            // Unciv isOfferValid: going a little negative is okay (amount × 0.9f < gold)
            if side.gold > 0 && !(Float(side.gold) * 0.9 < Float(c.gold)) { return false }
            if side.goldPerTurn > 0 && !(Float(side.goldPerTurn) * 0.9 < Float(netGoldPerTurn(owner))) { return false }
            // Unciv isTradeValid: a civ that has owned its original capital cannot trade away all of its cities
            if c.hasEverOwnedOriginalCapital && !side.cities.isEmpty && side.cities.count == cities(of: owner).count { return false }
            let counts = resourceCounts(owner)
            // Unciv TradeEvaluation.isOfferValid hasResource: getCivResourcesByName()[name] >= offer.amount
            for (r, copies) in Dictionary(grouping: side.resources, by: { $0 }).mapValues(\.count) { if (counts[r] ?? 0) < copies { return false } }
            for (r, n) in side.stockpiles where n > 0 { if (c.resourceStockpiles[r] ?? 0) < n { return false } }
            // Unciv isTradeValid: an embassy offer needs the hosting capital and no embassy there already.
            if side.embassy && (capital(of: owner) == nil || hasEmbassy(other, with: owner)) { return false }
            for cid in side.cities { guard let city = city(cid), city.civId == owner else { return false } }   // `offerer.cities.any { it.id == name }`
            for x in side.introductions { guard civ(other)?.metCivs.contains(x) == false else { return false } }   // you can't introduce them to someone they already know
            for x in side.peaceWith { guard areAtWar(owner, x) else { return false } }
            // Unciv Treaty offers: peace needs the war, the research agreement and the pact our own flag's absence
            if side.peace && !areAtWar(owner, other) { return false }
            if side.researchAgreement && hasFlag(owner, other, "ResearchAgreement") { return false }
            if side.defensivePact && hasFlag(owner, other, "DefensivePact") { return false }
            for w in side.warOns { guard w != owner, civ(owner)?.metCivs.contains(w) == true, canDeclareWar(owner, on: w) else { return false } }   // Unciv isOfferValid: canDeclareWar
            return true
        }
        if o.give.researchAgreement != o.want.researchAgreement || o.give.peace != o.want.peace { return false }
        if o.give.friendship != o.want.friendship || o.give.defensivePact != o.want.defensivePact { return false }
        if o.give.friendship && !canDeclareFriendship(o.from, o.to) { return false }   // ours: friendship is not a trade offer in Unciv
        return sideOK(o.give, owner: o.from, other: o.to) && sideOK(o.want, owner: o.to, other: o.from)
    }

    /// Would the AI civ `evaluator` (one of the two parties) agree to this offer?
    func aiAccepts(_ o: TradeOffer, evaluator: Int) -> Bool {
        guard tradeIsValid(o), civ(evaluator) != nil, isAIOrAutoPlaying(evaluator) else { return false }
        // Unciv TradeEvaluation.isTradeAcceptable
        if o.give.friendship { return wantsToSignDeclarationOfFriendship(evaluator, evaluator == o.to ? o.from : o.to) }
        return tradeAcceptability(o, evaluator: evaluator) >= 0
    }

    /// Gold the proposer would have to add for the AI to accept, or nil if a sweetener would not help.
    func goldToBalance(_ o: TradeOffer, evaluator: Int) -> Int? {
        var probe = o
        for step in stride(from: 0, through: 2000, by: 10) {
            if evaluator == o.to { probe.give.gold = o.give.gold + step } else { probe.want.gold = o.want.gold + step }
            if aiAccepts(probe, evaluator: evaluator) { return step }
        }
        return nil
    }

    /// Saves written before a pending research agreement offer carried its cost (TradeSide.researchAgreementCost
    /// decoded as -1): priced now, at the eras the old code would have charged.
    func legacyResearchAgreementCosts() {
        for i in pendingOffers.indices where pendingOffers[i].give.researchAgreementCost < 0 || pendingOffers[i].want.researchAgreementCost < 0 {
            let cost = Int(researchAgreementCost(pendingOffers[i].from, with: pendingOffers[i].to))
            if pendingOffers[i].give.researchAgreementCost < 0 { pendingOffers[i].give.researchAgreementCost = cost }
            if pendingOffers[i].want.researchAgreementCost < 0 { pendingOffers[i].want.researchAgreementCost = cost }
        }
    }

    // MARK: execution

    /// Unciv acceptTrade's `currentTrade`, offer by offer as Trade.equalTrade compares them (TradeLogic.getAvailableOffers'
    /// names, types and amounts): `o.to`'s ourOffers (o.want), then its theirOffers (o.give). The immediate offers are in
    /// it too, as they stay in the stored trade until it is dropped. Friendship is no trade offer in Unciv.
    func tradeContent(_ o: TradeOffer) -> [TradeOfferContent] {
        func offers(_ s: TradeSide, giver: Int) -> [TradeOfferContent] {
            var out: [TradeOfferContent] = []
            func add(_ type: String, _ name: String, _ amount: Int = 1) { out.append(TradeOfferContent(giver: giver, type: type, name: name, amount: amount)) }
            if s.embassy { add("Embassy", "Accept Embassy") }
            if s.peace { add("Treaty", "Peace Treaty") }
            if s.openBorders { add("Agreement", "Open Borders") }
            if s.researchAgreement { add("Treaty", "Research Agreement", s.researchAgreementCost) }
            if s.defensivePact { add("Treaty", "Defensive Pact") }
            // one offer per resource carrying the number of copies (TradeOffersList.add merges them)
            for (r, copies) in Dictionary(grouping: s.resources, by: { $0 }).mapValues(\.count).sorted(by: { $0.key < $1.key }) {
                add(rs.resources[r]?.resourceType == "Strategic" ? "Strategic_Resource" : "Luxury_Resource", r, copies)
            }
            for (r, n) in s.stockpiles.sorted(by: { $0.key < $1.key }) where n > 0 { add("Stockpiled_Resource", r, n) }
            if s.gold != 0 { add("Gold", "Gold", s.gold) }
            if s.goldPerTurn > 0 { add("Gold_Per_Turn", "Gold per turn", s.goldPerTurn) }
            for cid in s.cities { add("City", uncivCityId(cid)) }
            for x in s.introductions { add("Introduction", civ(x)?.nation ?? "\(x)") }
            for x in s.warOns { add("WarDeclaration", civ(x)?.nation ?? "\(x)") }
            for x in s.peaceWith { add("PeaceProposal", civ(x)?.nation ?? "\(x)") }
            return out
        }
        return offers(o.want, giver: o.to) + offers(o.give, giver: o.from)
    }

    /// Unciv TradeLogic.acceptTrade, run by the civ that accepts a request: `ourCivilization` is `o.to` and its
    /// `currentTrade.ourOffers` are `o.want`, `theirOffers` are `o.give`. In Unciv's order:
    /// 1. the trade goes into both sides' copies, each side's updateHasOpenBorders right after;
    /// 2. the gift value (skipped for peace / war / peace-proposal offers of ours), evaluated before anything moves;
    /// 3. the instant transfers - theirOffers first, then ours - and only then the treaties of theirOffers, so a
    ///    city changes hands before a peace sends units home;
    /// 4. the embassy modifiers, ours first;
    /// 5. updateCivResources + updateStatsForNextTurn, ours and then theirs.
    @discardableResult
    func executeTrade(_ o: TradeOffer, applyGifts: Bool = true) -> Bool {
        guard tradeIsValid(o), civIndex(o.from) != nil, civIndex(o.to) != nil else { return false }
        if epochsTradeDbg {
            func side(_ s: TradeSide) -> String { "g\(s.gold)/gpt\(s.goldPerTurn)/res\(s.resources.sorted())/ob\(s.openBorders)/emb\(s.embassy)/ra\(s.researchAgreement)/peace\(s.peace)/fr\(s.friendship)/dp\(s.defensivePact)/ct\(s.cities.count)/war\(s.warOn ?? -1)/intro\(s.introductions)" }
            print("TRADEE t=\(turn) \(civ(o.from)?.nation ?? "?")->\(civ(o.to)?.nation ?? "?") give=\(side(o.give)) want=\(side(o.want))")
        }
        let our = o.to, their = o.from
        let tradeId = o.id > 0 ? o.id : newId()
        // 1. `trades.add(currentTrade)` / `trades.add(currentTrade.reverse())`: every offer with a duration, in the
        // order of its TradeOffersList (evOfferNames: the order the offers were put in, a counteroffer's additions last),
        // which every walk of a trade's ourOffers / theirOffers follows - DiplomacyTurnManager.nextTurnTrades' union
        // ("[Open Borders] from [..] has ended" before "[Gold per turn] to [..]" when the open borders were offered
        // first). Ours added gold per turn first and the resources by name.
        func addDeals(_ side: TradeSide, other: TradeSide, tail: [String], giver: Int, receiver: Int) {
            // Unciv TradeOffer.amount: one trade offer per resource carrying the number of copies
            let copies = Dictionary(grouping: side.resources, by: { $0 }).mapValues(\.count)
            var resourcesAdded = Set<String>()   // the Gold resource and a lump sum of gold share a name
            // The timed offers' names close the walk too, each taken once: a timed offer the event log's order does not
            // name is still stored (last) rather than dropped.
            let timed = ["Open Borders", "Research Agreement", "Defensive Pact", "Gold per turn"]
            var timedAdded = Set<String>()
            for name in evOfferNames(side, other: other, tail: tail) + side.resources + timed {
                switch name {
                case _ where timed.contains(name) && !timedAdded.insert(name).inserted:
                    break
                case "Gold per turn" where side.goldPerTurn > 0:
                    addTradeDeal(.goldPerTurn, from: giver, to: receiver, amount: side.goldPerTurn, duration: speed.dealDuration, tradeId: tradeId)
                case "Open Borders" where side.openBorders:
                    addTradeDeal(.openBorders, from: giver, to: receiver, duration: speed.dealDuration, tradeId: tradeId)
                // The Research Agreement is a Treaty offer on BOTH sides, its amount the cost
                case "Research Agreement" where side.researchAgreement:
                    addTradeDeal(.researchAgreement, from: giver, to: receiver, amount: side.researchAgreementCost, duration: speed.dealDuration, tradeId: tradeId)
                // The Defensive Pact too is a Treaty offer on both sides with the deal's duration: Unciv keeps it in both
                // trade lists, counts each copy down and announces its end ("will end in [3] turns", "has ended"). Ours
                // only set the pact's flags, so none of those notifications came and the EV trade ended at once.
                case "Defensive Pact" where side.defensivePact:
                    addTradeDeal(.defensivePact, from: giver, to: receiver, duration: speed.dealDuration, tradeId: tradeId)
                default:
                    if let n = copies[name], resourcesAdded.insert(name).inserted { addTradeDeal(.resource, from: giver, to: receiver, resource: name, amount: n, duration: speed.dealDuration, tradeId: tradeId) }
                }
            }
        }
        let firstNewDeal = deals.count
        addDeals(o.want, other: o.give, tail: o.evTailWant, giver: our, receiver: their)
        addDeals(o.give, other: o.want, tail: o.evTailGive, giver: their, receiver: our)
        // the whole `currentTrade`, which Unciv's stored copies keep (removeUntenableTrades compares it: equalTrade)
        if deals.count > firstNewDeal {
            let content = tradeContent(o)
            for i in firstNewDeal..<deals.count { deals[i].tradeContent = content }
        }
        // ...and the whole trade, immediate offers and the peace treaty included, as the Trades overview lists it
        recordTrade(id: tradeId, ours: our, theirs: their, ourSide: o.want, theirSide: o.give, ourTail: o.evTailWant, theirTail: o.evTailGive)
        if GameState.evlogOn { evTradeStart(o, tradeId: tradeId) }   // EVLOG: TRADE start, both copies
        updateHasOpenBorders(our, their)
        updateHasOpenBorders(their, our)

        // 2. We shouldn't evaluate trades if we are doing a peace treaty - their value can be so big it throws the gift
        // system out of whack - and offers for peace / war with a third nation are not a "gift".
        if applyGifts && !o.want.peace && o.want.warOns.isEmpty && o.want.peaceWith.isEmpty {
            let ourValue = tradeAcceptability(o, evaluator: our, includeGifts: false), theirValue = tradeAcceptability(o, evaluator: their, includeGifts: false)
            if ourValue > theirValue { giftGold(from: their, to: our, value: ourValue - max(0, theirValue), isPureGift: o.want.isEmpty) }
            else if theirValue > ourValue { giftGold(from: our, to: their, value: theirValue - max(0, ourValue), isPureGift: o.give.isEmpty) }
        }

        // 3. instant transfers (Unciv transferTrade, every type but Treaty)
        func warType(on target: Int) -> WarType {
            if o.give.warOns.contains(target) && o.want.warOns.contains(target) { return .teamWar }
            if (o.give.warOns.contains(target) && areAtWar(our, target)) || (o.want.warOns.contains(target) && areAtWar(their, target)) { return .joinWar }
            return .directWar
        }
        func transfer(_ side: TradeSide, from giver: Int, to receiver: Int) {
            if side.embassy, let gi = civIndex(giver), let ri = civIndex(receiver) {
                civs[ri].embassiesWith.insert(giver)
                civs[ri].explored.formUnion(cities(of: giver).filter { $0.isCapital }.flatMap { map.tilesWithin($0.coord, radius: 2) })
                // `getCapital().getCenterTile().forEachTileInDistance(2) { it.setExplored(to, true) }`: ring by ring
                if let capital = cities(of: giver).first(where: { $0.isCapital }) { checkExploredRegion(ri, map.tilesInDistanceUncivOrder(capital.coord, radius: 2), explorer: nil) }
                _ = gi
            }
            if side.gold != 0, let gi = civIndex(giver), let ri = civIndex(receiver) {
                civs[ri].gold += Double(side.gold); goldTrace(civs[ri].id, Double(side.gold))
                civs[gi].gold -= Double(side.gold)
            }
            for (r, n) in side.stockpiles.sorted(by: { $0.key < $1.key }) where n > 0 {
                guard let gi = civIndex(giver), let ri = civIndex(receiver) else { continue }
                civs[ri].resourceStockpiles[r, default: 0] += n
                civs[gi].resourceStockpiles[r, default: 0] -= n
            }
            for cid in side.cities {
                guard let c = city(cid), c.civId == giver else { continue }
                transferCity(cityId: cid, to: receiver)   // Unciv: removeAllPresentSpies(CityBought), city.moveToCiv(to), the unit teleports, updateOurTiles for both
                // suggest an option to liberate the city
                if civ(receiver)?.isPlayer == true, let moved = city(cid), moved.originalOwner >= 0, moved.originalOwner != giver, moved.originalOwner != receiver {
                    addAlert(receiver, .CityTraded, "\(cid)")
                }
            }
            for x in side.introductions { makeCivilizationsMeet(receiver, x) }
            for w in side.warOns {
                // `from` is always the declaring civ; team and joint wars name the trade partner as the ally
                let type = warType(on: w)
                declareWar(giver, on: w, warType: type, allyCiv: type == .directWar ? nil : receiver)
            }
            for x in side.peaceWith {
                // Unciv PeaceProposal: a peace-treaty trade between the giver and the third civ - the giver's copy one
                // offer in both lists, the third civ's its reverse - both sides' updateHasOpenBorders, then the giver's makePeace
                addPeaceProposalTreaty(giver: giver, x)
                if GameState.evlogOn { evPeaceTreatyStart(giver, x) }   // EVLOG: TRADE start, both copies (PeaceProposal)
                updateHasOpenBorders(giver, x); updateHasOpenBorders(x, giver)
                makePeace(giver, x, withTreaty: false)
            }
        }
        transfer(o.give, from: their, to: our)
        transfer(o.want, from: our, to: their)
        // Transfer of treaties should only be done from one side to avoid double signing and notifying
        if o.give.peace { makePeace(our, their, recordTrade: false) }   // `to.getDiplomacyManager(from).makePeace()` - the trade is recorded already
        // Unciv `to.addGold(-offer.amount); from.addGold(-offer.amount)`: the cost the offer was made at
        if o.give.researchAgreement { signResearchAgreement(receiver: our, giver: their, cost: Double(o.give.researchAgreementCost), duration: speed.dealDuration) }
        if o.give.defensivePact { signDefensivePact(our, their, duration: speed.dealDuration) }
        if o.give.friendship { declareFriendship(our, their) }   // not a trade offer in Unciv; ours comes from the trade table

        // 4. Diplomatic modifiers for embassy depend on whether a civ gives its embassy, accepts it or both
        if o.want.embassy { applyEmbassyModifiers(their, with: our) }
        if o.give.embassy { applyEmbassyModifiers(our, with: their) }

        invalidateHappiness()
        // 5. Unciv TradeLogic.acceptTrade ends with, for BOTH sides - ours first: `cache.updateCivResources()` then
        // `updateStatsForNextTurn()`. A luxury changing hands is four happiness, and the cities that bank their
        // food later in the same turn have to see it: measured on `t_45` turn 41, Kyoto ate at -75% growth
        // against a Silk that had already arrived.
        updateCivResources(our); updateStatsForNextTurn(our)
        updateCivResources(their); updateStatsForNextTurn(their)
        return true
    }

    /// Unciv TradeLogic.acceptTrade, TradeOfferType.City: the spies leave (CityBought), the city goes through the
    /// same CityConquestFunctions.moveToCiv a conquest uses, the units in the centre are teleported out and those on
    /// its tiles too when the new owner's borders do not let them stay, and both owners' tiles are updated.
    func transferCity(cityId: Int, to newOwner: Int) {
        guard let ci = cityIndex(cityId), civIndex(newOwner) != nil else { return }
        let from = cities[ci].civId
        spiesFlee(fromCity: cityId, cityName: cities[ci].name, reason: .takenOver)   // removeAllPresentSpies(CityBought)
        moveToCiv(cityId: cityId, newCiv: newOwner)
        guard let c = city(cityId) else { return }
        for u in units(at: c.coord) { teleportToClosestMoveableTile(u.id) }
        for t in uncivTileWalk(c) {
            for u in units(at: t) where !canPassThroughTiles(u.civId, newOwner)
                && !u.promotionUniques.contains(where: { $0.pattern.hasPrefix("May enter foreign tiles without open borders") }) {
                teleportToClosestMoveableTile(u.id)
            }
        }
        updateOurTiles(newOwner)
        updateOurTiles(from)
    }

    // MARK: liberation

    func canLiberate(_ city: City, by civId: Int) -> Bool {
        guard city.civId == civId, city.originalOwner >= 0, city.originalOwner != civId, civ(city.originalOwner) != nil else { return false }
        return city.isPuppet || city.resistanceTurns > 0 || city.isOccupied
    }

    // MARK: AI proposals to humans

    /// Unciv TradeOffer.getOfferText for each offer on one side, in the order of Unciv's TradeOffersList - the order
    /// the EV log's evOfferNames measured (how Unciv's AI builds its requests), a counteroffer's additions (`tail`)
    /// last in the order they were added. With a viewer, TradePopup.getOfferText's "Owned by you" line goes under
    /// each luxury or strategic resource.
    func offerTexts(_ side: TradeSide, ownedBy viewer: Int? = nil, tail: [String] = []) -> [String] {
        // TradeOffer(speed): an isImmediate type (Embassy, Gold, Stockpiled_Resource, Introduction, WarDeclaration,
        // PeaceProposal, City) has duration -1 and no turns line; the Peace Treaty lasts peaceDealDuration, every other
        // offer dealDuration - `if (duration > 0) offerText += "\n" + duration + Fonts.turn`
        let d = "\n\(speed.dealDuration)⏳"
        let pd = "\n\(speed.peaceDealDuration)⏳"
        let owned = viewer.map { resourceCounts($0) }
        var texts: [(name: String, text: String)] = []   // (the evOfferNames name, the offer text)
        if side.embassy { texts.append(("Accept Embassy", L("Accept Embassy"))) }   // Constants.acceptEmbassy
        if side.peace { texts.append(("Peace Treaty", L("Peace Treaty") + pd)) }
        if side.openBorders { texts.append(("Open Borders", L("Open Borders") + d)) }
        // `else if (name == Constants.researchAgreement) offerText += " (-$amount💰)"` - the amount is the offer's cost
        if side.researchAgreement { texts.append(("Research Agreement", L("Research Agreement") + " (-\(side.researchAgreementCost)💰)" + d)) }
        if side.defensivePact { texts.append(("Defensive Pact", L("Defensive Pact") + d)) }
        if side.friendship { texts.append(("Declaration of Friendship", L("Declaration of Friendship"))) }   // ours: not a trade offer in Unciv
        var seen = Set<String>()
        for r in side.resources where seen.insert(r).inserted {   // one offer per resource, the copies are its amount
            let n = side.resources.filter { $0 == r }.count
            texts.append((r, "\(L(r)) (\(n))" + d + (owned.map { "\n" + L("Owned by you: [\($0[r] ?? 0)]") } ?? "")))
        }
        for r in side.stockpiles.filter({ $0.value > 0 }).map(\.key).sorted() { texts.append((r, "\(L(r)) (\(side.stockpiles[r] ?? 0))")) }
        if side.gold > 0 { texts.append(("Gold", "\(L("Gold")) (\(side.gold))")) }
        if side.goldPerTurn > 0 { texts.append(("Gold per turn", "\(L("Gold per turn")) (\(side.goldPerTurn))" + d)) }
        for c in side.cities {
            // `city?.run { "{$name} (${population.population})" } ?: "Non-existent city"`
            if let city = city(c) { texts.append((city.uncivId.isEmpty ? "city\(c)" : city.uncivId, "\(L(city.name)) (\(city.population))")) }
            else { texts.append(("city\(c)", L("Non-existent city"))) }
        }
        for x in side.introductions { let n = civ(x)?.nation ?? "?"; texts.append((n, L("Introduction to [\(n)]"))) }
        for w in side.warOns { let n = civ(w)?.nation ?? "?"; texts.append((n, L("Declare war on [\(n)]"))) }
        for x in side.peaceWith { let n = civ(x)?.nation ?? "?"; texts.append((n, L("Make peace with [\(n)]"))) }
        var tailTexts: [String] = []
        for name in tail { tailTexts += texts.filter { $0.name == name }.map(\.text) }
        return texts.filter { !tail.contains($0.name) }.map(\.text) + tailTexts
    }

    /// The offers of one side as one string (TradePopup's column): each offer's text, joined by `separator`; in a
    /// one-line form an offer's own line breaks become spaces.
    func describe(_ side: TradeSide, ownedBy viewer: Int? = nil, tail: [String] = [], separator: String = ", ") -> String {
        let parts = offerTexts(side, ownedBy: viewer, tail: tail).map { separator == "\n" ? $0 : $0.replacingOccurrences(of: "\n", with: " ") }
        return parts.isEmpty ? "—" : parts.joined(separator: separator)
    }

    func respondToOffer(_ id: Int, accept: Bool) {
        guard let idx = pendingOffers.firstIndex(where: { $0.id == id }) else { return }
        let o = pendingOffers.remove(at: idx)
        if accept {
            // Unciv TradePopup "Sounds good!": a trade that is no longer valid is refused in the popup, silently.
            // `requestingCiv.addNotification(..., NotificationCategory.Trade, viewingCiv.civName, NotificationIcon.Trade)`
            tradeLogicInit(o.to, o.from)   // `TradeLogic(viewingCiv, requestingCiv)`, then acceptTrade
            if executeTrade(o) { notify(o.from, "[\(civ(o.to)?.nation ?? "?")] has accepted your trade request", category: .Trade, icons: [civ(o.to)?.nation ?? "?", "Trade"]) }
        } else {
            // Unciv TradePopup "Not this time.": `tradeRequest.decline(viewingCiv)`, then the requesting civ is told
            declineTradeRequest(o, decliner: o.to)
            let n = civ(o.to)?.nation ?? "?"
            notify(o.from, "[\(n)] has denied your trade request", category: .Trade, icons: [n, "Trade"])
        }
    }
}

extension GameState {
    /// Unciv TradeEvaluation.introductionValue: only rulesets whose ModOptions carry "Can trade civilization introductions for [] Gold".
    var introductionValue: Int { rs.modOptionUniques.first { $0.pattern == "Can trade civilization introductions for [] Gold" }?.int(0) ?? 0 }
    /// Unciv DiplomacyFunctions.makeCivilizationsMeet.
    /// Unciv DiplomacyFunctions.makeCivilizationsMeet: both sides meet (First Contact popups, city-state goodwill gift).
    func makeCivilizationsMeet(_ a: Int, _ b: Int, warOnContact: Bool = false) {
        guard a != b, civ(a) != nil, civ(b) != nil else { return }
        meetCiv(a, b, warOnContact: warOnContact)
        meetCiv(b, a, warOnContact: warOnContact)
    }
    /// Unciv DiplomacyFunctions.meetCiv for `civId` meeting `other`: a city-state hands a major 15 gold (30 for the first major it meets) and
    /// religious city-states 4 faith as a token of goodwill — unless war is declared on contact or the major is a minor-civ aggressor.
    private func meetCiv(_ civId: Int, _ other: Int, warOnContact: Bool) {
        guard let ci = civIndex(civId), let oi = civIndex(other) else { return }
        guard meet(ci, other) else { return }
        if !civs[ci].isBarbarian && !civs[oi].isBarbarian && !civs[oi].isSpectator { addAlert(other, .FirstContact, "\(civId)") }
        // `if (civInfo.isCurrentPlayer()) addCompletedTutorialTask("Meet another civilization")` - whoever the
        // other civ is, a city-state too
        if civId == playerId { Tutorial.complete("meet") }
        guard civs[ci].isCityState, civs[oi].isMajor, civs[oi].isAlive else { return }
        // No gift if they are bad people, or we are just about to be at war - and then no justMet either: Unciv
        // calls questManager.justMet last, after the gift, so the early return skips it too.
        if warOnContact || civs[oi].numMinorCivsAttacked >= 2 { return }
        defer { warWithMajorJustMet(cityState: civId, other: other) }   // Unciv QuestManager.justMet
        let cs = civs[ci]
        var gift = 15.0
        var meetString = "[\(cs.nation)] has given us [+\(Int(gift)) Gold] as a token of goodwill for meeting us"
        if cs.metCivs.filter({ civ($0)?.isMajor == true }).count == 1 {
            gift *= 2
            meetString = "[\(cs.nation)] has given us [+\(Int(gift)) Gold] as we are the first major civ to meet them"
        }
        let capitalCoord = capital(of: civId)?.coord
        notify(other, meetString, category: .Diplomacy, icons: ["Gold"], coord: capitalCoord)
        // Unciv `if (civInfo.cityStateFunctions.canProvideStat(Stat.Faith))` - an Ally bonus of the city-state's type with
        // faith in its stats - then `otherCiv.addStat(Faith, 4)`, which (Civilization.addStat) also counts a positive amount
        // in totalFaithForContests: ours only stored the faith, so a Contest Faith quest started from a total 4 short (SX
        // dump, a test game, turn 14: Songhai met Vatican City and Unciv's total read 4, ours 0)
        let providesFaith = cs.cityStateType.flatMap { rs.cityStateTypes[$0] }?.allyBonusUniques.contains { (Unique($0).stats?.faith ?? 0) > 0 } ?? false
        if providesFaith {
            notify(other, "[\(cs.nation)] has also given us [+4 Faith]", category: .Diplomacy, icons: ["Faith"])
            civs[oi].faithStored += 4
            civs[oi].totalFaithForContests += 4
        }
        civs[oi].gold += gift; goldTrace(civs[oi].id, gift)
        if let c = capitalCoord { civs[oi].explored.insert(c); checkExploredRegion(oi, [c], explorer: nil) }   // Tile.setExplored(otherCiv, true)
    }
}
