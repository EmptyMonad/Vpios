// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv DiplomacyScreen: the known civilizations down the left (getKnownCivsSorted - majors first, then by translated
/// name), the selected one's table on the right (MajorCivDiplomacyTable / CityStateDiplomacyTable), and a close button.
/// The trade table, the demands, the gold / improvement gifts and the tribute table all replace the right side.
struct DiplomacyScreen: View {
    @ObservedObject var controller: GameController
    /// Unciv updateRightSide / setTrade / getDemandsTable / getGoldGiftTable / getImprovementGiftTable /
    /// getDemandTributeTable / setRightSideFlavorText
    enum RightSide: Equatable { case table, demands, goldGift, improvementGift, tribute, flavor(String) }
    @State private var selectedCivId: Int? = nil
    @State private var right: RightSide = .table
    @State private var warTarget: Int? = nil           // Unciv "Declare war on [x]?" ConfirmPopup
    @State private var peaceTarget: Int? = nil         // Unciv CityStateDiplomacyTable "Peace with [x]?" ConfirmPopup
    @State private var denounceTarget: Int? = nil      // Unciv MajorCivDiplomacyTable "Denounce [x]?" ConfirmPopup
    @State private var protectPrompt: (Int, Bool)? = nil   // Unciv "Declare Protection of [x]?" / "Revoke protection for [x]?"

    private var relationsLocked: Bool { controller.state.rs.modOptionUniques.contains { $0.pattern == "Diplomatic relationships cannot change" } }
    private var offTurn: Bool { !controller.isMyTurn }

    var body: some View {
        let s = controller.state
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                Theme.background.ignoresSafeArea().bleedIntoCutout()
                HStack(spacing: 0) {
                    leftSide(s).frame(width: max(110, geo.size.width * 0.2))
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    Group {
                        if controller.showTrade, let p = controller.tradePartner {
                            TradeScreen(controller: controller, partnerId: p)
                        } else if let id = selectedCivId, let civ = s.civ(id) {
                            ScrollView { rightSide(civ, s: s).padding(14).frame(maxWidth: .infinity) }
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.panel.opacity(0.35))
                }
                Button { controller.showDiplomacy = false; controller.diplomacyCiv = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.cream)
                        .frame(width: 34, height: 34).background(Circle().fill(Theme.fill)).overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                }.padding(10)
            }
        }
        .foregroundStyle(Theme.cream)
        .onAppear { if selectedCivId == nil { selectedCivId = controller.diplomacyCiv } }
        .onChange(of: controller.diplomacyCiv) { _, c in if let c { selectedCivId = c; right = .table } }
        .confirmationDialog(warConfirmText, isPresented: Binding(get: { warTarget != nil }, set: { if !$0 { warTarget = nil } }), titleVisibility: .visible) {
            Button(L("Declare war"), role: .destructive) {
                if let t = warTarget {
                    controller.declareWar(on: t)
                    // Unciv setRightSideFlavorText(otherCiv, nation.attacked, "Very well.")
                    let a = controller.state.civ(t)?.nationDef?.attacked ?? ""
                    right = .flavor(a)
                }
                warTarget = nil
            }
            // Unciv ConfirmPopup's own "Cancel" button: without it SwiftUI adds the system's, which the app's English-only
            // bundle never shows in the game's language
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(protectPrompt.map { L($0.1 ? "Declare Protection of [\(controller.state.civ($0.0)?.nation ?? "?")]?" : "Revoke protection for [\(controller.state.civ($0.0)?.nation ?? "?")]?") } ?? "", isPresented: Binding(get: { protectPrompt != nil }, set: { if !$0 { protectPrompt = nil } }), titleVisibility: .visible) {
            Button(L(protectPrompt?.1 == false ? "Revoke Protection" : "Pledge to protect")) { if let p = protectPrompt { if p.1 { controller.pledgeProtection(p.0) } else { controller.withdrawProtection(p.0) } }; protectPrompt = nil }
            Button(L("Cancel"), role: .cancel) {}   // Unciv ConfirmPopup's "Cancel" (the system's stays in English)
        }
        .confirmationDialog(L("Peace with [\(peaceTarget.flatMap { controller.state.civ($0)?.nation } ?? "?")]?"), isPresented: Binding(get: { peaceTarget != nil }, set: { if !$0 { peaceTarget = nil } }), titleVisibility: .visible) {
            Button(L("Negotiate Peace")) { if let t = peaceTarget { controller.makePeace(with: t) }; peaceTarget = nil }
            Button(L("Cancel"), role: .cancel) {}   // Unciv ConfirmPopup's "Cancel" (the system's stays in English)
        }
        .confirmationDialog(L("Denounce [\(denounceTarget.flatMap { controller.state.civ($0)?.nation } ?? "?")]?"), isPresented: Binding(get: { denounceTarget != nil }, set: { if !$0 { denounceTarget = nil } }), titleVisibility: .visible) {
            Button(L("Denounce ([30] turns)"), role: .destructive) {
                if let t = denounceTarget {
                    controller.denounce(t)
                    let d = controller.state.civ(t)?.nationDef?.denounced ?? ""
                    right = .flavor(d.isEmpty ? "We will remember this." : d)
                }
                denounceTarget = nil
            }
            Button(L("Cancel"), role: .cancel) {}   // Unciv ConfirmPopup's "Cancel" (the system's stays in English)
        }
        .screenShown("diplomacy")
    }

    // MARK: left side (updateLeftSideTable)

    private func leftSide(_ s: GameState) -> some View {
        let me = s.player
        // DiplomacyFunctions.getKnownCivsSorted: known, not barbarian / spectator / defeated; majors first, then by translated name
        let known = s.civs.filter { $0.id != me.id && me.metCivs.contains($0.id) && !$0.isBarbarian && !$0.isSpectator && $0.isAlive }
            .sorted { a, b in a.isMajor != b.isMajor ? a.isMajor : LocaleCode.compare(L(a.nation), L(b.nation)) == .orderedAscending }
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    Color.clear.frame(height: 4)
                    ForEach(known) { civ in
                        Button {
                            selectedCivId = civ.id; right = .table; controller.showTrade = false; controller.diplomacyCiv = civ.id
                        } label: {
                            VStack(spacing: 4) {
                                civIndicator(civ, s: s)
                                Text(L(civ.nation)).font(Theme.small).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .padding(6).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selectedCivId == civ.id ? Theme.gold.opacity(0.22) : .clear))   // highlightCiv
                        }.buttonStyle(.plain).id(civ.id)
                    }
                }.padding(.horizontal, 6)
            }
            .onAppear { if let id = selectedCivId { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    /// Unciv updateLeftSideTable: the nation portrait with the relationship circle (bottom left), a city-state's type icon
    /// (top right) and a quest icon when it has quests for us (bottom right)
    private func civIndicator(_ civ: Civilization, s: GameState) -> some View {
        let me = s.player
        let size: CGFloat = 50   // on the virtual canvas: VirtualCanvas scales it with the screen
        let level = s.relationshipLevel(civ.id, me.id)
        let color: Color = {
            if civ.isPlayer && me.isPlayer {   // getHumanRelationshipColor
                if civ.defensivePacts.contains(me.id) { return .cyan }
                if s.hasFlag(civ.id, me.id, "DeclarationOfFriendship") { return .green }
                if s.areAtWar(civ.id, me.id) { return .red }
                return .white
            }
            if civ.defensivePacts.contains(me.id) { return .purple }
            if civ.isAtWar(with: me.id) { return .red }
            return Self.levelColor(level)
        }()
        return ZStack {
            NationBadge(nation: civ.nationDef, size: size)
            if civ.isCityState && level == .ally {
                Image(systemName: "star.fill").font(.system(size: size * 0.16)).foregroundStyle(Color(red: 1, green: 0.84, blue: 0))
                    .frame(width: size * 0.3, height: size * 0.3).background(Circle().fill(Self.levelColor(.ally)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                Circle().fill(color).frame(width: size * 0.3, height: size * 0.3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            if civ.isCityState, let type = civ.cityStateType {
                let inner = civ.nationDef?.innerColor.map { Color(uiColor: UIColor(rgb: $0)) } ?? .white
                ArtIcon(name: type, folder: "CityStateIcons", fallback: "circle", size: size * 0.25)
                    .colorMultiply(Color(white: 0.07))
                    .frame(width: size * 0.35, height: size * 0.35).background(Circle().fill(inner))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if civ.isCityState && civ.quests.contains(where: { $0.assigneeId == me.id }) {
                ArtIcon(name: "Quest", folder: "OtherIcons", fallback: "exclamationmark", size: size * 0.2)
                    .frame(width: size * 0.3, height: size * 0.3).background(Circle().fill(Color(red: 0.855, green: 0.647, blue: 0.125)))   // GOLDENROD
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }.frame(width: size * 1.1, height: size * 1.1)
    }

    /// Unciv RelationshipLevel colours
    static func levelColor(_ level: RelationshipLevel) -> Color {
        switch level {
        case .unforgivable: return Color(red: 0.545, green: 0.271, blue: 0.075)   // BROWN
        case .enemy: return .orange
        case .afraid: return .yellow
        case .competitor: return .gray
        case .neutral: return .white
        case .favorable: return Color(red: 0x14 / 255, green: 0xcc / 255, blue: 0x3c / 255)
        case .friend: return Color(red: 0.255, green: 0.412, blue: 0.882)   // ROYAL
        case .ally: return .cyan
        }
    }

    // MARK: right side

    @ViewBuilder
    private func rightSide(_ civ: Civilization, s: GameState) -> some View {
        switch right {
        case .flavor(let text):
            // setRightSideFlavorText: the leader, the text and the response button
            VStack(spacing: 10) {
                leaderIntro(civ)
                Divider2()
                Text(L(text)).font(Theme.body).multilineTextAlignment(.center)
                Button(L("Very well.")) { right = .table }.buttonStyle(ThemedButtonStyle(compact: true))
            }
        case .demands: demandsTable(civ, s: s)
        case .goldGift: VStack(spacing: 6) { cityStateHeader(civ, s: s); Divider2(); goldGiftTable(civ, s: s) }
        case .improvementGift: VStack(spacing: 6) { cityStateHeader(civ, s: s); Divider2(); improvementGiftTable(civ, s: s) }
        case .tribute: VStack(spacing: 6) { cityStateHeader(civ, s: s); Divider2(); tributeTable(civ, s: s) }
        case .table:
            if civ.isCityState { cityStateTable(civ, s: s) } else { majorCivTable(civ, s: s) }
        }
    }

    /// Unciv LeaderIntroTable: tapping it opens the nation's Civilopedia entry
    private func leaderIntro(_ civ: Civilization, hello: String? = nil) -> some View {
        LeaderIntroView(civ: civ, hello: hello, suffix: LeaderIntroView.suffix(civ, controller.state))
            .onTapGesture { controller.openCivilopediaFromDiplomacy("Nation/\(civ.nation)") }
    }

    // MARK: MajorCivDiplomacyTable.getMajorCivDiplomacyTable

    private func majorCivTable(_ civ: Civilization, s: GameState) -> some View {
        let me = s.player
        let war = me.isAtWar(with: civ.id)
        let hello = s.relationshipLevel(civ.id, me.id) <= .enemy ? civ.nationDef?.hateHello : civ.nationDef?.neutralHello   // isRelationshipLevelLE(Enemy)
        return VStack(spacing: 10) {
            leaderIntro(civ, hello: hello)
            Divider2()
            if !war {
                Button(L("Trade")) { controller.openTrade(with: civ.id) }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(offTurn)
                if !s.hasFlag(me.id, civ.id, "DeclarationOfFriendship") {
                    Button(L("Offer Declaration of Friendship ([30] turns)")) { controller.declareFriendship(civ.id) }.buttonStyle(ThemedButtonStyle(compact: true))
                        // Unciv: disabled once clicked and while the offer waits in otherCiv.popupAlerts (ours keeps an AI's as a pending offer)
                        .disabled(offTurn || s.civ(civ.id)?.popupAlerts.contains { $0.type == .DeclarationOfFriendship && $0.value == "\(me.id)" } == true
                                  || s.pendingOffers.contains { $0.from == me.id && $0.to == civ.id && $0.isFriendshipRequest })
                }
                if !s.hasFlag(me.id, civ.id, "Denunciation") && !s.hasFlag(me.id, civ.id, "DeclarationOfFriendship") {
                    Button(L("Denounce ([30] turns)")) { denounceTarget = civ.id }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(offTurn)
                }
                if !relationsLocked { declareWarButton(civ, s: s) }
            } else if !relationsLocked {
                // getNegotiatePeaceMajorCivButton: the trade table with a peace treaty on both sides, the offer button enabled
                let declared = s.hasFlag(civ.id, me.id, "DeclaredWar")
                Button(L("Negotiate Peace") + (declared ? "\n\(s.flag(civ.id, me.id, "DeclaredWar"))⏳" : "")) {
                    var seed = TradeOffer(id: -1, from: civ.id, to: me.id, turnCreated: s.turn)
                    seed.give.peace = true; seed.want.peace = true
                    controller.counterOfferSeed = seed
                    controller.openTrade(with: civ.id)
                }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(offTurn || declared)
            }
            Button(L("Demands")) { right = .demands }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(offTurn)
            goToOnMapButton(civ, s: s)
            if civ.isPlayer {
                // getHumanRelationshipTable
                HStack(spacing: 0) {
                    Text(L("Our relationship") + ": ")
                    Text(L(s.humanRelationshipText(civ.id, me.id))).foregroundStyle(humanRelationshipColor(civ, s: s))
                }.font(Theme.body)
            } else {
                relationshipLine(civ, s: s)
                modifiersTable(civ, s: s)
            }
            promisesTable(civ, s: s)
        }
    }

    private func humanRelationshipColor(_ civ: Civilization, s: GameState) -> Color {
        let me = s.player
        if civ.defensivePacts.contains(me.id) { return .cyan }
        if s.hasFlag(civ.id, me.id, "DeclarationOfFriendship") { return .green }
        if s.areAtWar(civ.id, me.id) { return .red }
        return .white
    }

    /// DiplomacyScreen.getRelationshipTable: "Our relationship: <level> (<opinion or influence>)", coloured by level; a
    /// city-state adds its influence bar
    @ViewBuilder
    private func relationshipLine(_ civ: Civilization, s: GameState) -> some View {
        let me = s.player
        let level = s.relationshipLevel(civ.id, me.id)
        let value = civ.isCityState ? Int(s.influence(of: me.id, with: civ.id)) : Int(s.opinion(of: civ.id, toward: me.id))
        let color: Color = {
            switch level {
            case .neutral: return .white
            case .favorable, .friend, .ally: return .green
            case .afraid: return .yellow
            default: return .red
            }
        }()
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                Text(L("Our relationship") + ": ")
                Text(L(Self.levelName(level)) + " (\(value))").foregroundStyle(color)
            }.font(Theme.body)
            if civ.isCityState { InfluenceBar(influence: s.influence(of: me.id, with: civ.id), level: level).frame(width: 200, height: 10) }
        }
    }

    static func levelName(_ level: RelationshipLevel) -> String {
        switch level {
        case .unforgivable: return "Unforgivable"
        case .enemy: return "Enemy"
        case .afraid: return "Afraid"
        case .competitor: return "Competitor"
        case .neutral: return "Neutral"
        case .favorable: return "Favorable"
        case .friend: return "Friend"
        case .ally: return "Ally"
        }
    }

    /// getDiplomacyModifiersTable: in the modifier map's own order (a Java HashMap of the names); the reason, then the rounded
    /// value with its sign, green or red; attacked-protected-minor does not stack with destroyed-protected-minor
    private func modifiersTable(_ civ: Civilization, s: GameState) -> some View {
        let me = s.player
        let mods = civ.opinions[me.id] ?? [:]
        let destroyed = mods[DiploModifier.DestroyedProtectedMinor.rawValue] != nil
        let keys = javaHashMapOrder(Array(mods.keys).sorted()).filter { !($0 == DiploModifier.AttackedProtectedMinor.rawValue && destroyed) && DiploModifier(rawValue: $0) != nil }
        return VStack(spacing: 2) {
            ForEach(keys, id: \.self) { k in
                let v = mods[k] ?? 0
                Text(L("\(L(DiploModifier(rawValue: k)?.text ?? k)) \(v > 0 ? "+" : "")\(Stats.roundToInt(v))"))   // text.toLabel(color): the whole line through tr() again
                    .font(Theme.small).foregroundStyle(v < 0 ? Color.red : Color.green)
            }
        }
    }

    /// getPromisesTable: for each Demand, what we promised them and what they promised us, with the turns left
    @ViewBuilder
    private func promisesTable(_ civ: Civilization, s: GameState) -> some View {
        let me = s.player
        VStack(spacing: 2) {
            ForEach(Demand.allCases, id: \.self) { d in
                if s.hasFlag(civ.id, me.id, d.agreedToDemand) { Text(L(d.wePromisedText.replacingOccurrences(of: "[turns]", with: "[\(s.flag(civ.id, me.id, d.agreedToDemand))]"))).font(Theme.small).foregroundStyle(Color(white: 0.75)) }
                if s.hasFlag(me.id, civ.id, d.agreedToDemand) { Text(L(d.theyPromisedText.replacingOccurrences(of: "[turns]", with: "[\(s.flag(me.id, civ.id, d.agreedToDemand))]"))).font(Theme.small).foregroundStyle(Color(white: 0.75)) }
            }
        }
    }

    /// getDemandsTable: Demand.entries shown by demand.show(), disabled when already demanded or agreed; Close
    private func demandsTable(_ civ: Civilization, s: GameState) -> some View {
        let me = s.player
        return VStack(spacing: 10) {
            ForEach(Demand.allCases.filter { $0 != .DoNotAttackUs && ($0 != .DontSpyOnUs || s.espionageEnabled) && ($0 != .DoNotSpreadReligion || s.religionEnabled) }, id: \.self) { d in
                Button(L(d.demandText)) { controller.demand(d, of: civ.id) }.buttonStyle(ThemedButtonStyle(compact: true))
                    .disabled(s.hasFlag(me.id, civ.id, d.agreedToDemand) || s.pendingDemands.contains { $0.from == me.id && $0.to == civ.id && $0.demand == d })
            }
            Button(L("Close")) { right = .table }.buttonStyle(ThemedButtonStyle(compact: true))
        }
    }

    /// DiplomacyScreen.getDeclareWarButton: "Declare war (N⏳)" - `diplomacyManager.turnsToPeaceTreaty()` - and disabled while a peace treaty runs
    private func declareWarButton(_ civ: Civilization, s: GameState) -> some View {
        let treaty = s.turnsToPeaceTreaty(s.playerId, civ.id)
        return Button(L("Declare war") + (treaty > 0 ? " (\(treaty)⏳)" : "")) { warTarget = civ.id }
            .buttonStyle(ThemedButtonStyle(destructive: true, compact: true)).disabled(offTurn || treaty > 0 || !s.canDeclareWar(s.playerId, on: civ.id))
    }

    /// getGoToOnMapButton: shown once the capital has been explored
    @ViewBuilder
    private func goToOnMapButton(_ civ: Civilization, s: GameState) -> some View {
        if let cap = s.capital(of: civ.id), s.player.explored.contains(cap.coord) {
            // Unciv getGoToOnMapButton: resetToWorldScreen - an overview under this screen is gone too - and
            // setCenterPosition(capital, selectUnit = false)
            Button(L("Go to on map")) { controller.overviewReturn = nil; controller.showDiplomacy = false; controller.setCenterPosition(cap.coord, selectUnit: false); controller.refresh(full: false) }.buttonStyle(ThemedButtonStyle(compact: true))
        }
    }

    /// DiplomacyScreen "Declare war on [x]?" ConfirmPopup text: the promise and defensive-pact lines
    private var warConfirmText: String {
        guard let t = warTarget, let civ = controller.state.civ(t) else { return "" }
        let s = controller.state, me = s.player
        var lines = [L("Declare war on [\(civ.nation)]?")]
        if s.hasFlag(t, me.id, "AgreedToNotAttackUs") { lines.append(L("This will break your promise to not attack them. Other leaders will view this unfavorably.")) }
        let joining = (s.civ(t)?.defensivePacts ?? []).filter { $0 != me.id && !me.isAtWar(with: $0) }
        for partner in joining.sorted() {
            if me.metCivs.contains(partner) { lines.append(L("[\(s.civ(partner)?.nation ?? "?")] will also join them in the war")) }
            else { lines.append(L("[An unknown civilization] will also join them in the war")) }
        }
        for partner in me.defensivePacts.sorted() where partner != t && !joining.contains(partner) {
            lines.append(L("This will cancel your defensive pact with [\(s.civ(partner)?.nation ?? "?")]"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: CityStateDiplomacyTable

    /// getCityStateDiplomacyTableHeader
    private func cityStateHeader(_ cs: Civilization, s: GameState) -> some View {
        let me = s.player
        let inf = s.influence(of: me.id, with: cs.id)
        let level = s.relationshipLevel(cs.id, me.id)
        let ally = s.ally(of: cs.id)
        let gifted = s.cityStateResourcesForAlly(cs.id)
        let giftedList = s.rs.resourceOrder.filter { gifted[$0] != nil && s.rs.resources[$0]?.resourceType != "Bonus" }
        let protectors = s.majorCivs.filter { $0.isAlive && $0.protectedCityStates.contains(cs.id) }
        let atWar = cs.isAtWar(with: me.id)
        let nextLevel = atWar ? "" : Int(inf) < 30 ? "Reach 30 for friendship." : ally == me.id ? "" : "Reach highest influence above 60 for alliance."
        let relation = s.relationshipIgnoreAfraid(cs.id, me.id)
        let turnsToChange = s.turnsToRelationshipChange(me.id, cs.id)
        let type = cs.cityStateType.flatMap { s.rs.cityStateTypes[$0] }
        return VStack(spacing: 4) {
            leaderIntro(cs).padding(.bottom, 10)
            Text(L("Type") + ":  " + L(cs.cityStateType ?? "")).font(Theme.body)
            Text(L("Personality") + ":  " + L(cs.cityStatePersonality)).font(Theme.body)
            if !giftedList.isEmpty {
                HStack(spacing: 14) {
                    Text(L("Resources") + ":  ").font(Theme.body)
                    ForEach(giftedList, id: \.self) { r in
                        HStack(spacing: 4) { ArtIcon(name: r, folder: "ResourceIcons", fallback: "cube", size: 22); Text(Translations.shared.numberTr(gifted[r] ?? 0)).font(Theme.body) }
                            .onTapGesture { controller.openCivilopediaFromDiplomacy("Resource/\(r)") }
                    }
                }
            }
            Spacer().frame(height: 10)
            if let a = ally {
                let name = (!me.metCivs.contains(a) && a != me.id) ? "Unknown civilization" : (s.civ(a)?.nation ?? "?")
                Text(L("Ally: [\(name)] with [\(Int(s.influence(of: a, with: cs.id)))] Influence")).font(Theme.body)
            }
            if !protectors.isEmpty {
                Text(L("Protected by") + ": " + protectors.map { (!me.metCivs.contains($0.id) && $0.id != me.id) ? L("Unknown civilization") : L($0.nation) }.joined(separator: ", "))
                    .font(Theme.body).multilineTextAlignment(.center)
            }
            relationshipLine(cs, s: s)
            if !nextLevel.isEmpty { Text(L(nextLevel)).font(Theme.body) }
            Spacer().frame(height: 10)
            if relation >= .friend, turnsToChange != 0 { Text(L("Relationship changes in another [\(turnsToChange)] turns")).font(Theme.body) }
            if let t = type {
                bonusLabels("When Friends:", t.friendBonusUniques, bonusLevel: .friend, current: relation, s: s)
                bonusLabels("When Allies:", t.allyBonusUniques, bonusLevel: .ally, current: relation, s: s)
            }
            if let uu = cs.cityStateUniqueUnit, let ud = s.rs.units[uu] {
                // requiredTechs joined with " and ", "is" or "are"
                let techs = s.requiredTechs(requiredTech: ud.requiredTech, uniques: ud.uniqueObjects)
                Text(L("[\(cs.nation)] is able to provide [\(uu)] once [\(techs.joined(separator: " and "))] [\(techs.count == 1 ? "is" : "are")] researched."))
                    .font(Theme.body).multilineTextAlignment(.center)
            }
        }
    }

    /// addBonusLabels: the header green when that is our current level; each bonus green when it is and its conditionals apply
    @ViewBuilder
    private func bonusLabels(_ header: String, _ bonuses: [String], bonusLevel: RelationshipLevel, current: RelationshipLevel, s: GameState) -> some View {
        let shown = bonuses.filter { uniqueIsPlayerFacing($0) }
        if !shown.isEmpty {
            Text(L(header)).font(Theme.body).foregroundStyle(current == bonusLevel ? Color.green : Color.white)
            ForEach(shown, id: \.self) { b in
                let applies = current == bonusLevel && s.conditionalsHold(Unique(b), GameState.UniqueContext(civId: s.playerId))
                Text(L(b)).font(Theme.small).multilineTextAlignment(.center).foregroundStyle(applies ? Color.green : Color.gray)
            }
        }
    }

    private func cityStateTable(_ cs: Civilization, s: GameState) -> some View {
        let me = s.player
        let war = me.isAtWar(with: cs.id)
        let knownTargets = s.civs.filter { cs.metCivs.contains($0.id) && cs.unitsToKillForCiv[$0.id] != nil && $0.id != me.id }
        return VStack(spacing: 8) {
            cityStateHeader(cs, s: s)
                // Unciv getCityStateDiplomacyTable: `otherCiv.cityStateFunctions.updateAllyCivForCityState()` each time the
                // table is built (CityStateDiplomacyTable.kt:128) - the civ picked, the screen opened on it
                .onAppear { controller.cityStateDiplomacyTableShown(cs.id) }
                .onChange(of: cs.id) { _, id in controller.cityStateDiplomacyTableShown(id) }
            Divider2()
            Button(L("Give a Gift")) { right = .goldGift }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(offTurn || war)
            // getImproveTilesButton: only when an improvable resource tile exists; disabled below 60 influence
            if !s.giftableImprovementTiles(of: cs.id, by: me.id).isEmpty {
                Button(L("Gift Improvement")) { right = .improvementGift }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(offTurn || s.influence(of: me.id, with: cs.id) < 60)
            }
            if !me.protectedCityStates.contains(cs.id) {
                Button(L("Pledge to protect")) { protectPrompt = (cs.id, true) }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(offTurn || !s.canPledgeProtection(me.id, cs.id))
            } else {
                Button(L("Revoke Protection")) { protectPrompt = (cs.id, false) }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(offTurn || !s.canWithdrawProtection(me.id, cs.id))
            }
            Button(L("Demand Tribute")) { right = .tribute }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(offTurn || war)
            if !relationsLocked {
                if war {
                    // getNegotiatePeaceCityStateButton: disabled while at war with its ally or for the turns after the declaration
                    let declared = s.hasFlag(cs.id, me.id, "DeclaredWar")
                    let atWarWithAlly = s.ally(of: cs.id).map { me.metCivs.contains($0) && me.isAtWar(with: $0) } == true
                    Button(L("Negotiate Peace") + (declared ? "\n\(s.flag(cs.id, me.id, "DeclaredWar"))⏳" : "")) { peaceTarget = cs.id }
                        .buttonStyle(ThemedButtonStyle(compact: true)).disabled(offTurn || atWarWithAlly || declared)
                } else { declareWarButton(cs, s: s) }
            }
            goToOnMapButton(cs, s: s)
            if s.marriageTurnsRequired(me.id) != nil {
                Button(L("Diplomatic Marriage ([\(Int(s.marriageCost(me.id, cityState: cs.id)))] Gold)")) { controller.marry(cs.id); controller.showDiplomacy = false }
                    .buttonStyle(ThemedButtonStyle(compact: true)).disabled(offTurn || !s.canMarry(me.id, cs.id))
            }
            ForEach(cs.quests.filter { $0.assigneeId == me.id }) { q in
                Divider2()
                questTable(q, cs: cs, s: s)
            }
            ForEach(knownTargets) { target in
                Divider2()
                // getWarWithMajorTable
                VStack(spacing: 8) {
                    Text(L("War against [\(target.nation)]")).font(Theme.heading(16))
                    Text(L("We need you to help us defend against [\(target.nation)]. Killing [\(s.unitsToKill(cityState: cs.id, target: target.id))] of their military units would slow their offensive.")).font(Theme.body).multilineTextAlignment(.center)
                    Text(me.metCivs.contains(target.id) ? L("Currently you have killed [\(s.unitsKilledSoFar(cityState: cs.id, target: target.id, by: me.id))] of their military units.") : L("You need to find them first!")).font(Theme.body).multilineTextAlignment(.center)
                }
            }
        }
    }

    /// getQuestTable: title (with the influence reward), description, turns remaining, the global contest standing
    private func questTable(_ q: Quest, cs: Civilization, s: GameState) -> some View {
        let influence = s.questDef(q.name)?.influence ?? 0
        return VStack(spacing: 8) {
            Text(influence > 0 ? L("[\(q.name)] (+[\(Int(influence))] influence)") : L(q.name)).font(Theme.heading(16))
            Text(L(s.questText(q, cityState: cs))).font(Theme.body).multilineTextAlignment(.center)   // Unciv description.toLabel()
            if q.endTurn > 0 { Text(L("[\(max(0, q.endTurn - s.turn))] turns remaining")).font(Theme.body) }
            if let standing = s.contestStandingText(q, cityState: cs) { Text(L(standing)).font(Theme.body) }
        }
        .contentShape(Rectangle())
        // onClickAction: GUI.resetToWorldScreen() - an overview under this screen is gone too - and
        // setCenterPosition(target, selectUnit = false)
        .onTapGesture { if let c = questClickTarget(q, cs: cs, s: s) { controller.overviewReturn = nil; controller.showDiplomacy = false; controller.setCenterPosition(c, selectUnit: false); controller.refresh(full: false) } }
    }

    /// AssignedQuest.onClickAction: the barbarian camp, the city-state's capital for a route, or the target city-state's
    /// capital for a bully / conquer quest; nothing for the others
    private func questClickTarget(_ q: Quest, cs: Civilization, s: GameState) -> HexCoord? {
        switch q.name {
        case "Clear Barbarian Camp":
            guard let parts = q.target?.split(separator: ","), parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else { return nil }
            return HexCoord(x, y)
        case "Route": return s.capital(of: cs.id)?.coord
        case "Bully City State", "Conquer City State":
            guard let id = q.target.flatMap({ Int($0) }), s.civ(id)?.isAlive == true else { return nil }
            return s.capital(of: id)?.coord
        default: return nil
        }
    }

    /// getGoldGiftTable
    private func goldGiftTable(_ cs: Civilization, s: GameState) -> some View {
        let me = s.player
        return VStack(spacing: 8) {
            ForEach([250, 500, 1000], id: \.self) { g in
                Button(L("Gift [\(g)] gold (+[\(Int(s.influenceGainedByGift(from: me.id, amount: Double(g), cityState: cs.id)))] influence)")) {
                    controller.giftGold(to: cs.id, Double(g)); right = .table
                }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(offTurn || me.gold < Double(g))
            }
            Button(L("Back")) { right = .table }.buttonStyle(ThemedButtonStyle(compact: true))
        }
    }

    /// getImprovementGiftTable
    private func improvementGiftTable(_ cs: Civilization, s: GameState) -> some View {
        let me = s.player
        return VStack(spacing: 8) {
            ForEach(Array(s.giftableImprovementTiles(of: cs.id, by: me.id).enumerated()), id: \.offset) { _, t in
                Button(L("Build [\(t.2)] on [\(t.1)] (200 Gold)")) { controller.giftImprovement(to: cs.id, at: t.0, improvement: t.2); right = .table }
                    .buttonStyle(ThemedButtonStyle(compact: true)).disabled(me.gold < 200)
            }
            Button(L("Back")) { right = .table }.buttonStyle(ThemedButtonStyle(compact: true))
        }
    }

    /// getDemandTributeTable
    private func tributeTable(_ cs: Civilization, s: GameState) -> some View {
        let me = s.player
        let mods = s.tributeModifiers(from: me.id, cs.id, demandingWorker: false, requireWholeList: true)
        return VStack(spacing: 8) {
            Text(L("Tribute Willingness")).font(Theme.body)
            VStack(spacing: 2) {
                ForEach(Array(mods.enumerated()), id: \.offset) { _, m in
                    HStack { Text(L(m.0)); Spacer(); Text(Translations.shared.numberTr(m.1)) }.font(Theme.small).foregroundStyle(m.1 >= 0 ? Color.green : Color.red)
                }
                HStack { Text(L("Sum:")); Spacer(); Text(Translations.shared.numberTr(mods.reduce(0) { $0 + $1.1 })) }.font(Theme.small)
            }.frame(maxWidth: 360)
            Text(L("At least 0 to take gold, at least 30 and size 4 city for worker")).font(Theme.small).multilineTextAlignment(.center)
            Divider2()
            Button(L("Take [\(s.goldGainedByTribute())] gold (-15 Influence)")) { controller.demandTribute(from: cs.id); right = .table }
                .buttonStyle(ThemedButtonStyle(compact: true)).disabled(!s.canDemandTribute(from: me.id, cs.id))
            Button(L("Take worker (-50 Influence)")) { controller.demandWorker(from: cs.id); right = .table }
                .buttonStyle(ThemedButtonStyle(compact: true)).disabled(!s.canDemandWorker(from: me.id, cs.id))
            Button(L("Back")) { right = .table }.buttonStyle(ThemedButtonStyle(compact: true))
        }
    }
}

/// Unciv InfluenceTable: four pieces (-60..-30, -30..0, 0..30, 30..60), the negative ones filling from the right, the
/// positive from the left, in the level's colour over DARK_GRAY on a CHARCOAL background
struct InfluenceBar: View {
    let influence: Double
    let level: RelationshipLevel
    var body: some View {
        let n = min(60, max(-60, influence)) / 30
        var p: [Double] = [0, 0, 0, 0]
        if n < -1 { p[0] = -n - 1; p[1] = 1 } else if n < 0 { p[1] = -n } else if n < 1 { p[2] = n } else { p[2] = 1; p[3] = n - 1 }
        let color: Color = {
            switch level {
            case .unforgivable: return .red
            case .enemy: return .orange
            case .afraid: return .yellow
            case .neutral, .friend: return Color(red: 0.196, green: 0.804, blue: 0.196)   // LIME
            case .ally: return Color(red: 0.529, green: 0.808, blue: 0.922)                // SKY
            default: return Color(white: 0.25)                                            // DARK_GRAY
            }
        }()
        return GeometryReader { g in
            let piece = (g.size.width - 8) / 4
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    HStack(spacing: 0) {
                        if i < 2 { Rectangle().fill(Color(white: 0.25)).frame(width: piece * (1 - p[i])); Rectangle().fill(color).frame(width: piece * p[i]) }
                        else { Rectangle().fill(color).frame(width: piece * p[i]); Rectangle().fill(Color(white: 0.25)).frame(width: piece * (1 - p[i])) }
                    }
                }
            }.padding(1).background(Color(white: 0.067))
        }
    }
}
