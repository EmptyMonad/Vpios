// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv TradeTable + OfferColumnsTable + OffersListScroll: four columns - our items, their items, our trade offer, their
/// trade offer. Tapping an item moves it (one copy of a resource, the whole of anything else; gold asks for an amount)
/// onto the table; tapping a staged item takes it back. Treaties go on both sides at once.
struct TradeScreen: View {
    @ObservedObject var controller: GameController
    let partnerId: Int
    @State private var offer: TradeOffer
    /// Unciv TradeTable: the offer button starts disabled and is enabled by the first change (Negotiate Peace enables it)
    @State private var changed: Bool
    @State private var goldEntry: GoldEntry? = nil
    @State private var amountText = ""
    /// AskNumberPopup's errorLabel, shown once OK is pressed with no number in the field
    @State private var amountInvalid = false

    /// One button of an OffersListScroll
    struct Item: Identifiable {
        let id: String
        let type: Int            // Unciv TradeOfferType ordinal
        let sortName: String
        let amount: Int
        let label: String
        let icon: (name: String, folder: String)?
        let enabled: Bool
        var green = false
        let click: () -> Void
    }
    /// Unciv TradeOfferType order
    enum T: Int { case embassy, gold, goldPerTurn, treaty, agreement, luxury, strategic, stockpiled, technology, introduction, war, peace, city }
    struct GoldEntry: Identifiable { let id = UUID(); let perTurn: Bool; let ours: Bool; let max: Int }

    init(controller: GameController, partnerId: Int) {
        self.controller = controller
        self.partnerId = partnerId
        let ourPending = controller.state.pendingOffers.first(where: { $0.from == controller.state.playerId && $0.to == partnerId && !$0.isFriendshipRequest })
        // Unciv TradeTable init: with a pending offer from us the button only reads "Retract offer" - it is never
        // disabled, and retracting (setText only) leaves it enabled; without one it starts disabled
        var initialChanged = ourPending != nil
        if let pending = ourPending, !(controller.counterOfferSeed.map { $0.from == partnerId } ?? false) {
            _offer = State(initialValue: pending)   // Unciv TradeTable: tryLoadOurPendingOffer
        } else if let seed = controller.counterOfferSeed, seed.to == controller.state.playerId, seed.from == partnerId {
            // Unciv: their proposal (or the Negotiate Peace seed) becomes the table, seen from our side
            var mine = TradeOffer(id: -1, from: controller.state.playerId, to: partnerId, turnCreated: controller.state.turn)
            mine.give = seed.want; mine.want = seed.give
            mine.evTailGive = seed.evTailWant; mine.evTailWant = seed.evTailGive   // each list keeps its order
            _offer = State(initialValue: mine)
            // only Negotiate Peace (its seed has no request id) calls enableOfferButton(true); TradePopup's "How about
            // something else..." hands over the real request and leaves the button as TradeTable left it
            if seed.id == -1 { initialChanged = true }
        } else {
            _offer = State(initialValue: TradeOffer(id: -1, from: controller.state.playerId, to: partnerId, turnCreated: controller.state.turn))
        }
        _changed = State(initialValue: initialChanged)
    }

    var body: some View {
        let s = controller.state
        let me = s.player
        ThemedSheet(L("Trade"), subtitle: s.civ(partnerId).map { L($0.nation) } ?? "", onClose: { controller.showTrade = false }) {
            if let them = s.civ(partnerId) {
                let ourAvail = available(civ: me, other: them, s: s)
                let theirAvail = available(civ: them, other: me, s: s)
                HStack(alignment: .top, spacing: 8) {
                    column(L("Our items"), items: filtered(ourAvail, staged: offer.give, ours: true, s: s, otherAvailable: theirAvail))
                    column(L("[\(them.nation)]'s items"), items: filtered(theirAvail, staged: offer.want, ours: false, s: s, otherAvailable: ourAvail))
                }
                Divider2()
                HStack(alignment: .top, spacing: 8) {
                    column(L("Our trade offer"), items: staged(offer.give, ours: true, s: s, otherAvailable: theirAvail))
                    column(L("[\(them.nation)]'s trade offer"), items: staged(offer.want, ours: false, s: s, otherAvailable: ourAvail))
                }
                let pending = controller.hasPendingOffer(to: partnerId)
                Button { offerTrade(me: me, them: them, s: s) } label: {
                    // Unciv offerTradeText is two lines; the button style's single-line limit would loop the layout
                    Text(pending ? L("Retract offer") : L("Offer trade") + "\n(" + L("They'll decide on their turn") + ")").lineLimit(2).multilineTextAlignment(.center)
                }
                    .buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                    .disabled(!pending && !(changed && !(offer.give.isEmpty && offer.want.isEmpty)))
            }
        }
        .onAppear { if controller.counterOfferSeed != nil { controller.counterOfferSeed = nil } }
        // Unciv AskNumberPopup is a popup over the table (a .sheet here, inside the diplomacy cover, locked up SwiftUI's layout)
        .overlay { if let e = goldEntry { ZStack { Color.black.opacity(0.5).ignoresSafeArea().bleedIntoCutout().onTapGesture { if !UserSettings.neverCloseByTapOutside { goldEntry = nil } }; goldPopup(e).frame(maxWidth: 420).padding(24) } } }
        .screenShown("trade")
    }

    // MARK: columns

    private func column(_ title: String, items: [Item]) -> some View {
        Panel(padding: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.small.bold()).foregroundStyle(Theme.gold)
                let headers: [Int: String] = [T.luxury.rawValue: "Luxury resources", T.strategic.rawValue: "Strategic resources", T.stockpiled.rawValue: "Stockpiled resources",
                                              T.technology.rawValue: "Technologies", T.war.rawValue: "Declarations of war", T.peace.rawValue: "Peace Proposals", T.city.rawValue: "Cities"]
                let byType = Dictionary(grouping: items, by: { $0.type })
                ForEach(byType.keys.sorted(), id: \.self) { type in
                    if let h = headers[type] { Text(L(h)).font(Theme.small.bold()).foregroundStyle(Theme.creamDim) }
                    ForEach(sortItems(byType[type] ?? [])) { item in itemButton(item) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    /// OffersListScroll: by amount (when "Order trade offers by amount" is on), then by translated name
    private func sortItems(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            if UserSettings.orderTradeOffersByAmount && a.amount != b.amount { return a.amount > b.amount }
            return a.sortName < b.sortName
        }
    }
    private func itemButton(_ item: Item) -> some View {
        Button { item.click() } label: {
            HStack(spacing: 4) {
                if let i = item.icon { ArtIcon(name: i.name, folder: i.folder, fallback: "circle", size: 18) }
                Text(item.label).font(Theme.small).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            .padding(5)
            .foregroundStyle(item.enabled ? (item.green ? Color.green : Theme.cream) : Theme.creamDim)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelDark.opacity(item.enabled ? 0.9 : 0.4)))
        }.buttonStyle(.plain).disabled(!item.enabled)
    }

    // MARK: available offers (Unciv TradeLogic.getAvailableOffers)

    private func duration(_ s: GameState, peace: Bool = false) -> String { "\n\(peace ? s.speed.peaceDealDuration : s.speed.dealDuration)⏳" }

    private func available(civ: Civilization, other: Civilization, s: GameState) -> [Item] {
        var out: [Item] = []
        let ours = civ.id == s.playerId
        // Embassy: judged by our ability to trade it, on both columns
        let embassyOK = ours ? s.canOfferEmbassy(s.playerId, to: partnerId) : s.canEstablishEmbassy(s.playerId, with: partnerId)
        if embassyOK { out.append(Item(id: "embassy", type: T.embassy.rawValue, sortName: L("Accept Embassy"), amount: 1, label: L("Accept Embassy"), icon: nil, enabled: true, click: { add(ours) { $0.embassy = true } })) }
        if civ.isCityState || other.isCityState { return out }
        if civ.isAtWar(with: other.id) {
            // OffersListScroll: the Peace Treaty button is always disabled - peace comes onto the table only through Negotiate Peace
            out.append(Item(id: "peace", type: T.treaty.rawValue, sortName: L("Peace Treaty"), amount: 1, label: L("Peace Treaty") + duration(s, peace: true), icon: nil, enabled: false, click: {}))
        }
        if s.canOpenBorders(other.id, civ.id, ignoringWar: true) {
            out.append(Item(id: "ob", type: T.agreement.rawValue, sortName: L("Open Borders"), amount: 1, label: L("Open Borders") + duration(s), icon: nil, enabled: true, click: { add(ours) { $0.openBorders = true } }))
        }
        if s.canResearchAgreementNoCost(civ.id, other.id) {
            let cost = Int(s.researchAgreementCost(civ.id, with: other.id))
            let affordable = civ.gold + other.gold > s.researchAgreementCost(civ.id, with: other.id) * 2
            out.append(Item(id: "ra", type: T.treaty.rawValue, sortName: L("Research Agreement"), amount: cost, label: L("Research Agreement") + " (-\(cost)💰)" + duration(s), icon: nil, enabled: affordable, click: { addTreaty { $0.researchAgreement = true; $0.researchAgreementCost = cost } }))
        }
        if s.canSignDefensivePact(civ.id, other.id) {
            out.append(Item(id: "dp", type: T.treaty.rawValue, sortName: L("Defensive Pact"), amount: 1, label: L("Defensive Pact") + duration(s), icon: nil, enabled: true, click: { addTreaty { $0.defensivePact = true } }))
        }
        let supply = s.tradableResourceSupply(civ.id)
        for r in s.exportableResources(civ.id) {
            guard let n = supply[r]?.tradable, n > 0 else { continue }
            let lux = s.rs.resources[r]?.resourceType == "Luxury"
            out.append(Item(id: "res-\(r)", type: (lux ? T.luxury : T.strategic).rawValue, sortName: L(r), amount: n, label: L(r) + " (\(n))" + duration(s), icon: (r, "ResourceIcons"), enabled: true, click: { add(ours) { $0.resources.append(r) } }))
        }
        for (r, n) in s.tradableStockpiles(civ.id) where n > 0 {
            out.append(Item(id: "stock-\(r)", type: T.stockpiled.rawValue, sortName: L(r), amount: n, label: L(r) + " (\(n))", icon: (r, "ResourceIcons"), enabled: true, click: { add(ours) { $0.stockpiles[r, default: 0] += 1 } }))
        }
        let gold = Int(civ.gold)
        out.append(Item(id: "gold", type: T.gold.rawValue, sortName: L("Gold"), amount: gold, label: L("Gold") + " (\(gold))", icon: nil, enabled: gold > 0, click: { goldEntry = GoldEntry(perTurn: false, ours: ours, max: gold) }))
        let gpt = Int(s.netGoldPerTurn(civ.id))
        out.append(Item(id: "gpt", type: T.goldPerTurn.rawValue, sortName: L("Gold per turn"), amount: gpt, label: L("Gold per turn") + " (\(gpt))" + duration(s), icon: nil, enabled: gpt > 0, click: { goldEntry = GoldEntry(perTurn: true, ours: ours, max: gpt) }))
        if !s.settings.oneCityChallenge {
            for c in s.cities(of: civ.id) where !c.isCapital && c.resistanceTurns == 0 {
                out.append(Item(id: "city-\(c.id)", type: T.city.rawValue, sortName: "\(L(c.name)) (\(c.population))", amount: 1, label: "\(L(c.name)) (\(c.population))", icon: nil, enabled: true, click: { add(ours) { $0.cities.append(c.id) } }))
            }
        }
        let knownMajors = s.majorCivs.filter { $0.id != civ.id && $0.id != other.id && $0.isAlive && civ.metCivs.contains($0.id) }
        if s.introductionValue > 0 {
            for x in knownMajors where !other.metCivs.contains(x.id) {
                out.append(Item(id: "intro-\(x.id)", type: T.introduction.rawValue, sortName: L(x.nation), amount: 1, label: L("Introduction to [\(x.nation)]"), icon: nil, enabled: true, click: { add(ours) { $0.introductions.append(x.id) } }))
            }
        }
        let relationsLocked = s.rs.modOptionUniques.contains { $0.pattern == "Diplomatic relationships cannot change" }
        if !relationsLocked {
            for x in knownMajors where other.metCivs.contains(x.id) && s.canDeclareWar(civ.id, on: x.id) {
                out.append(Item(id: "war-\(x.id)", type: T.war.rawValue, sortName: L(x.nation), amount: 1, label: L("Declare war on [\(x.nation)]"), icon: (x.nation, "NationIcons"), enabled: true, click: { add(ours) { $0.warOns.append(x.id) } }))
            }
            let thirds = s.civs.filter { $0.id != civ.id && $0.id != other.id && $0.isAlive && other.metCivs.contains($0.id) && civ.isAtWar(with: $0.id) }
            for x in thirds {
                let enabled = s.isPeaceProposalEnabled(third: x.id, civ.id)
                out.append(Item(id: "peacewith-\(x.id)", type: T.peace.rawValue, sortName: L(x.nation), amount: enabled ? 1 : 0, label: L("Make peace with [\(x.nation)]") + duration(s, peace: true), icon: (x.nation, "NationIcons"), enabled: enabled, click: { add(ours) { $0.peaceWith.append(x.id) } }))
            }
        }
        return out
    }

    /// OfferColumnsTable.update: the available lists without what is already staged (resources by count)
    private func filtered(_ items: [Item], staged side: TradeSide, ours: Bool, s: GameState, otherAvailable: [Item]) -> [Item] {
        var out: [Item] = []
        for var item in items {
            switch item.id {
            case "embassy": if side.embassy { continue }
            case "peace": if side.peace { continue }
            case "ob": if side.openBorders { continue }
            case "ra": if side.researchAgreement { continue }
            case "dp": if side.defensivePact { continue }
            // TradeOffersList.without: the staged amount comes off the available one, and the offer goes only when
            // exactly 0 is left - a negative remainder stays, not tradable (isTradable: amount > 0)
            case "gold":
                if side.gold > 0 {
                    let left = item.amount - side.gold
                    if left == 0 { continue }
                    item = Item(id: item.id, type: item.type, sortName: item.sortName, amount: left, label: L("Gold") + " (\(left))", icon: item.icon, enabled: left > 0, click: item.click)
                }
            case "gpt":
                if side.goldPerTurn > 0 {
                    let left = item.amount - side.goldPerTurn
                    if left == 0 { continue }
                    item = Item(id: item.id, type: item.type, sortName: item.sortName, amount: left, label: L("Gold per turn") + " (\(left))" + duration(s), icon: item.icon, enabled: left > 0, click: item.click)
                }
            default:
                if item.id.hasPrefix("res-") {
                    let r = String(item.id.dropFirst(4))
                    let left = item.amount - side.resources.filter { $0 == r }.count
                    if left <= 0 { continue }
                    let lux = item.type == T.luxury.rawValue
                    item = Item(id: item.id, type: item.type, sortName: item.sortName, amount: left, label: L(r) + " (\(left))" + duration(s), icon: item.icon, enabled: true, click: item.click)
                    _ = lux
                } else if item.id.hasPrefix("stock-") {
                    let r = String(item.id.dropFirst(6))
                    let left = item.amount - (side.stockpiles[r] ?? 0)
                    if left <= 0 { continue }
                    item = Item(id: item.id, type: item.type, sortName: item.sortName, amount: left, label: L(r) + " (\(left))", icon: item.icon, enabled: true, click: item.click)
                } else if item.id.hasPrefix("city-"), let cid = Int(item.id.dropFirst(5)), side.cities.contains(cid) { continue }
                else if item.id.hasPrefix("intro-"), let x = Int(item.id.dropFirst(6)), side.introductions.contains(x) { continue }
                else if item.id.hasPrefix("war-"), let x = Int(item.id.dropFirst(4)), side.warOns.contains(x) { continue }
                else if item.id.hasPrefix("peacewith-"), let x = Int(item.id.dropFirst(10)), side.peaceWith.contains(x) { continue }
            }
            // highlight unique suggestions: a resource the other side has no offer of
            if item.type == T.luxury.rawValue || item.type == T.strategic.rawValue {
                item.green = !otherAvailable.contains { $0.id == item.id }
            }
            out.append(item)
        }
        return out
    }

    /// The staged column: tapping takes it back (one copy of a resource, gold reopens the amount popup, treaties from both sides)
    private func staged(_ side: TradeSide, ours: Bool, s: GameState, otherAvailable: [Item]) -> [Item] {
        var out: [Item] = []
        func remove(_ f: @escaping (inout TradeSide) -> Void) -> () -> Void { { changeSide(ours, f) } }
        if side.embassy { out.append(Item(id: "embassy", type: T.embassy.rawValue, sortName: "", amount: 1, label: L("Accept Embassy"), icon: nil, enabled: true, click: remove { $0.embassy = false })) }
        if side.gold > 0 { out.append(Item(id: "gold", type: T.gold.rawValue, sortName: "", amount: side.gold, label: L("Gold") + " (\(side.gold))", icon: nil, enabled: true, click: { goldEntry = GoldEntry(perTurn: false, ours: ours, max: ours ? Int(s.player.gold) : Int(s.civ(partnerId)?.gold ?? 0)) })) }
        if side.goldPerTurn > 0 { out.append(Item(id: "gpt", type: T.goldPerTurn.rawValue, sortName: "", amount: side.goldPerTurn, label: L("Gold per turn") + " (\(side.goldPerTurn))" + duration(s), icon: nil, enabled: true, click: { goldEntry = GoldEntry(perTurn: true, ours: ours, max: Int(s.netGoldPerTurn(ours ? s.playerId : partnerId))) })) }
        // OffersListScroll: "can't disable peace treaty!" - once on the table it cannot be taken back
        if side.peace { out.append(Item(id: "peace", type: T.treaty.rawValue, sortName: L("Peace Treaty"), amount: 1, label: L("Peace Treaty") + duration(s, peace: true), icon: nil, enabled: false, click: {})) }
        if side.researchAgreement {
            let cost = side.researchAgreementCost   // the staged offer's amount
            out.append(Item(id: "ra", type: T.treaty.rawValue, sortName: L("Research Agreement"), amount: cost, label: L("Research Agreement") + " (-\(cost)💰)" + duration(s), icon: nil, enabled: true, click: { removeTreaty { $0.researchAgreement = false } }))
        }
        if side.defensivePact { out.append(Item(id: "dp", type: T.treaty.rawValue, sortName: L("Defensive Pact"), amount: 1, label: L("Defensive Pact") + duration(s), icon: nil, enabled: true, click: { removeTreaty { $0.defensivePact = false } })) }
        if side.openBorders { out.append(Item(id: "ob", type: T.agreement.rawValue, sortName: L("Open Borders"), amount: 1, label: L("Open Borders") + duration(s), icon: nil, enabled: true, click: remove { $0.openBorders = false })) }
        for (r, n) in Dictionary(grouping: side.resources, by: { $0 }).mapValues(\.count) {
            let lux = s.rs.resources[r]?.resourceType == "Luxury"
            var item = Item(id: "res-\(r)", type: (lux ? T.luxury : T.strategic).rawValue, sortName: L(r), amount: n, label: L(r) + " (\(n))" + duration(s), icon: (r, "ResourceIcons"), enabled: true,
                            click: remove { if let i = $0.resources.firstIndex(of: r) { $0.resources.remove(at: i) } })
            item.green = !otherAvailable.contains { $0.id == "res-\(r)" }
            out.append(item)
        }
        for (r, n) in side.stockpiles where n > 0 {
            out.append(Item(id: "stock-\(r)", type: T.stockpiled.rawValue, sortName: L(r), amount: n, label: L(r) + " (\(n))", icon: (r, "ResourceIcons"), enabled: true,
                            click: remove { $0.stockpiles[r] = n > 1 ? n - 1 : nil }))
        }
        for x in side.introductions { if let c = s.civ(x) { out.append(Item(id: "intro-\(x)", type: T.introduction.rawValue, sortName: L(c.nation), amount: 1, label: L("Introduction to [\(c.nation)]"), icon: nil, enabled: true, click: remove { $0.introductions.removeAll { $0 == x } })) } }
        for x in side.warOns { if let c = s.civ(x) { out.append(Item(id: "war-\(x)", type: T.war.rawValue, sortName: L(c.nation), amount: 1, label: L("Declare war on [\(c.nation)]"), icon: (c.nation, "NationIcons"), enabled: true, click: remove { $0.warOns.removeAll { $0 == x } })) } }
        for x in side.peaceWith { if let c = s.civ(x) { out.append(Item(id: "peacewith-\(x)", type: T.peace.rawValue, sortName: L(c.nation), amount: 1, label: L("Make peace with [\(c.nation)]") + duration(s, peace: true), icon: (c.nation, "NationIcons"), enabled: true, click: remove { $0.peaceWith.removeAll { $0 == x } })) } }
        for cid in side.cities { if let c = s.city(cid) { out.append(Item(id: "city-\(cid)", type: T.city.rawValue, sortName: "\(L(c.name)) (\(c.population))", amount: 1, label: "\(L(c.name)) (\(c.population))", icon: nil, enabled: true, click: remove { $0.cities.removeAll { $0 == cid } })) } }
        return out
    }

    // MARK: changes (Unciv TradeTable.onChange: the table changes, our pending request is retracted, the button re-enabled)

    private func changeSide(_ ours: Bool, _ f: (inout TradeSide) -> Void) {
        let before = offer
        if ours { f(&offer.give) } else { f(&offer.want) }
        followListOrder(before)
        onChange()
    }
    private func add(_ ours: Bool, _ f: (inout TradeSide) -> Void) { changeSide(ours, f) }
    // OfferColumnsTable.addOffer: a Treaty goes into both lists
    private func addTreaty(_ f: (inout TradeSide) -> Void) { let before = offer; f(&offer.give); f(&offer.want); followListOrder(before); onChange() }
    private func removeTreaty(_ f: (inout TradeSide) -> Void) { let before = offer; f(&offer.give); f(&offer.want); followListOrder(before); onChange() }
    /// Unciv's staged lists are TradeOffersLists (TradeOffer.followListOrder)
    private func followListOrder(_ before: TradeOffer) { offer.followListOrder(from: before, in: controller.state) }
    private func onChange() {
        let s = controller.state
        if let pending = s.pendingOffers.first(where: { $0.from == s.playerId && $0.to == partnerId && !$0.isFriendshipRequest }) { controller.retractOffer(pending.id) }
        changed = true
    }

    /// Unciv TradeTable offer button: retract a pending request, or top up a research agreement with the gold either side
    /// is short of and propose the staged trade
    private func offerTrade(me: Civilization, them: Civilization, s: GameState) {
        if let pending = s.pendingOffers.first(where: { $0.from == me.id && $0.to == partnerId && !$0.isFriendshipRequest }) { controller.retractOffer(pending.id); return }
        var o = offer; o.turnCreated = s.turn
        if o.give.researchAgreement {
            let cost = s.researchAgreementCost(me.id, with: partnerId)
            let mine = me.gold + Double(o.want.gold) - cost
            let theirs = them.gold + Double(o.give.gold) - cost
            if mine < 0 { o.want.gold += Int((-mine).rounded(.up)) }
            if theirs < 0 { o.give.gold += Int((-theirs).rounded(.up)) }
            offer = o
        }
        _ = controller.propose(o)
    }

    // MARK: Unciv AskNumberPopup "Enter the amount of gold"

    /// Unciv UncivTextField.Integer.intValue, `formatter.parse(text)?.toInt()`: the number the text starts with - a minus
    /// sign, then digits - read as a Long and wrapped to a 32-bit Int by `toInt()`; nil when no digit starts it. (The
    /// field also lets in the number format's grouping separator, which the parse skips; ours keeps digits and the sign.)
    nonisolated static func askNumberIntValue(_ text: String) -> Int? {
        var rest = Substring(text), negative = false
        if rest.first == "-" { negative = true; rest = rest.dropFirst() }
        let digits = rest.prefix { ("0"..."9").contains($0) }
        // at most 14 characters (askNumberText), so the Long never overflows
        guard !digits.isEmpty, digits.count <= 18, let long = Int(digits) else { return nil }
        return Int(Int32(truncatingIfNeeded: negative ? -long : long))
    }
    /// AskNumberPopup.clampInBounds with `bounds = IntRange(0, maxGold)`: the lower bound first, then the upper
    nonisolated static func askNumberClamp(_ v: Int, max: Int) -> Int { v < 0 ? 0 : v > max ? max : v }
    /// AskNumberPopup `nameField.onChange { nameField.intValue = clampInBounds(nameField.intValue) }`: what the field
    /// keeps of a typed or pasted text - digits and the minus sign, 14 characters (UncivTextField.Integer maxLength) -
    /// is read and written back clamped, or emptied when it reads as no number. Ours took any text and added the
    /// button's step to Int(text) before clamping it, and nineteen digits overflowed there and stopped the app.
    nonisolated static func askNumberText(_ text: String, max: Int) -> String {
        let kept = String(text.filter { $0 == "-" || ("0"..."9").contains($0) }.prefix(14))
        return askNumberIntValue(kept).map { "\(askNumberClamp($0, max: max))" } ?? ""
    }
    /// AskNumberPopup's ±amount buttons: `val value = nameField.intValue ?: return@onClick` and
    /// `nameField.intValue = clampInBounds(value + delta)` - a 32-bit sum, nothing done on an empty field
    nonisolated static func askNumberStep(_ text: String, delta: Int, max: Int) -> String? {
        guard let v = askNumberIntValue(text) else { return nil }
        return "\(askNumberClamp(Int(Int32(truncatingIfNeeded: v + delta)), max: max))"
    }

    @ViewBuilder
    private func goldPopup(_ entry: GoldEntry) -> some View {
        let steps = entry.perTurn ? [5, 15] : [50, 500]
        Panel {
                VStack(spacing: 8) {
                    Text(L("Enter the amount of gold")).font(Theme.heading(15))
                    HStack {
                        ForEach(steps.reversed(), id: \.self) { st in Button("-\(st)") { if let t = TradeScreen.askNumberStep(amountText, delta: -st, max: entry.max) { amountText = t } }.buttonStyle(ThemedButtonStyle(compact: true)) }
                        TextField("", text: $amountText).keyboardType(.numberPad).textFieldStyle(.roundedBorder).font(Theme.body).frame(width: 90)
                            .onChange(of: amountText) { _, t in let kept = TradeScreen.askNumberText(t, max: entry.max); if kept != t { amountText = kept } }
                        ForEach(steps, id: \.self) { st in Button("+\(st)") { if let t = TradeScreen.askNumberStep(amountText, delta: st, max: entry.max) { amountText = t } }.buttonStyle(ThemedButtonStyle(compact: true)) }
                    }
                    HStack {
                        Button(L("Cancel")) { goldEntry = nil }.buttonStyle(ThemedButtonStyle(compact: true))
                        Button(L("OK")) {
                            // Unciv addOKButton's validate: `nameField.intValue?.let { validate(it) } != true` adds the
                            // error label and keeps the popup open on an empty field
                            guard let read = TradeScreen.askNumberIntValue(amountText) else { amountInvalid = true; return }
                            let v = TradeScreen.askNumberClamp(read, max: entry.max)
                            changeSide(entry.ours) { if entry.perTurn { $0.goldPerTurn = v } else { $0.gold = v } }
                            goldEntry = nil
                        }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                    }
                    if amountInvalid { Text(L("Invalid input! Please enter a valid number.")).font(Theme.small).foregroundStyle(Theme.danger) }
                }
        }
        .onAppear {
            amountInvalid = false
            // Unciv openGoldSelectionPopup: the staged amount (existingGoldOffer) if there is one, otherwise the clicked
            // offer's - OffersListScroll hands over `min(amountPerClick, offer.amount)`, amountPerClick 50 for Gold
            // and 1 for everything else (Gold_Per_Turn too)
            let side = entry.ours ? offer.give : offer.want
            let staged = entry.perTurn ? side.goldPerTurn : side.gold
            amountText = "\(staged > 0 ? staged : min(entry.perTurn ? 1 : 50, entry.max))"
        }
    }
}
