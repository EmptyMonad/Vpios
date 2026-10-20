// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv BeliefType.color
func beliefTypeColor(_ type: String) -> Color {
    switch type {
    case "Pantheon": return Color(red: 0x44 / 255, green: 0xc6 / 255, blue: 0xcc / 255)
    case "Founder": return Color(red: 0xc0 / 255, green: 0, blue: 0)
    case "Follower": return Color(red: 0xcc / 255, green: 0xaa / 255, blue: 0x44 / 255)
    case "Enhancer": return Color(red: 0x72 / 255, green: 0xcc / 255, blue: 0x45 / 255)
    default: return Theme.cream
    }
}

/// Unciv ImageGetter.getReligionPortrait: the religion's icon, else its belief type's, charcoal on a white disc ringed in black
struct ReligionPortrait: View {
    let name: String
    var size: CGFloat = 40
    var body: some View {
        let rs = Ruleset.shared
        let icon = Art.shared.image(name, folder: "ReligionIcons") ?? rs.beliefs[name].flatMap { Art.shared.image($0.type, folder: "ReligionIcons") }
        ZStack {
            Circle().fill(Color.black)
            Circle().fill(Color.white).padding(size * 0.05)
            if let icon { Image(uiImage: icon).renderingMode(.template).resizable().interpolation(.medium).foregroundStyle(Color(white: 0.2)).padding(size * 0.2) }
        }.frame(width: size, height: size)
    }
}

/// Unciv Religion.getAllBeliefsOrdered: pantheon, founder, follower, enhancer beliefs
func religionBeliefsOrdered(_ s: GameState, _ civ: Civilization) -> [String] {
    var all: [String] = []
    for b in (civ.pantheonBelief.map { [$0] } ?? []) + civ.religionBeliefs where !all.contains(b) && s.rs.beliefs[b] != nil { all.append(b) }
    let order = ["Pantheon", "Founder", "Follower", "Enhancer"]
    return order.flatMap { t in all.filter { s.rs.beliefs[$0]?.type == t } }
}

/// Unciv ReligionPickerScreenCommon.getBeliefButton content: the type (when asked for), the name as a heading, the visible uniques
struct BeliefButtonLabel: View {
    let belief: BeliefDef?
    var slotType: String? = nil
    var withTypeLabel = true
    var body: some View {
        VStack(alignment: .center, spacing: 3) {
            if let b = belief {
                if withTypeLabel { Text(L(b.type)).font(Theme.small).foregroundStyle(beliefTypeColor(b.type)) }
                Text(L(b.name)).font(Theme.heading(15)).multilineTextAlignment(.center)
                Text(b.uniques.filter(isPlayerFacing).map { L($0) }.joined(separator: "\n")).font(Theme.small).multilineTextAlignment(.center)
            } else if slotType == "Any" {
                Text(L("Choose any belief!")).font(Theme.caption)
            } else if let t = slotType {
                Text(L("Choose a [\(t)] belief!")).font(Theme.caption)
            }
        }
        .frame(maxWidth: .infinity).padding(10)
    }
}

/// Unciv's belief button states: selectable, the current selection (disabled), or disabled in green (ours) or red (blocked)
enum BeliefButtonState { case normal, selected, green, red }

struct BeliefButton: View {
    let label: BeliefButtonLabel
    let state: BeliefButtonState
    let action: () -> Void
    var body: some View {
        let tint: Color = state == .green ? Theme.good : state == .red ? Theme.danger : Theme.cream
        Button(action: action) {
            label.foregroundStyle(state == .normal ? Theme.cream : tint)
                .background(RoundedRectangle(cornerRadius: 10).fill(state == .selected ? Theme.gold.opacity(0.18) : Theme.fill))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(state == .selected ? Theme.gold : state == .normal ? Theme.hairline : tint.opacity(0.6), lineWidth: state == .selected ? 1.5 : 1))
                .opacity(state == .green || state == .red ? 0.75 : 1)
        }
        .buttonStyle(.plain)
        .disabled(state != .normal)
    }
}

/// Unciv Belief.getCivilopediaTextLines(withHeader = true): the name (a link to its Civilopedia page), "Type: …" in the type's
/// colour, the visible uniques
struct BeliefDescription: View {
    @ObservedObject var controller: GameController
    let belief: BeliefDef
    var onOpenCivilopedia: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Button { onOpenCivilopedia?(); controller.civilopediaEntry = "Belief/\(belief.name)"; controller.showCivilopedia = true } label: {
                Text(L(belief.name)).font(Theme.heading(17)).foregroundStyle(Theme.gold)
            }.buttonStyle(.plain)
            Text("\(L("Type")): \(L(belief.type))").font(Theme.caption).foregroundStyle(beliefTypeColor(belief.type))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(belief.uniques.filter(isPlayerFacing), id: \.self) { Text(L($0)).font(Theme.caption).foregroundStyle(Theme.cream) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
    }
}

/// Unciv PickerScreen as the religion pickers use it: the content on top, then the description on the left of the bottom
/// bar and the right side button, with the close button in the corner
struct ReligionPickerFrame<Top: View, Content: View, Description: View>: View {
    let onClose: () -> Void
    var showClose = true
    let okTitle: String
    let okEnabled: Bool
    let onOK: () -> Void
    @ViewBuilder var top: () -> Top
    @ViewBuilder var content: () -> Content
    @ViewBuilder var description: () -> Description
    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 0) {
                top()
                content().frame(maxHeight: .infinity)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(alignment: .bottom, spacing: 12) {
                    ScrollView { description().frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
                    Button(okTitle, action: onOK).buttonStyle(ThemedButtonStyle(filled: true)).disabled(!okEnabled)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .overlay(alignment: .topTrailing) {
                if showClose { Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.cream)
                        .frame(width: 34, height: 34).background(Circle().fill(Theme.fill)).overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                }.padding(12) }
            }
        }
        .foregroundStyle(Theme.cream)
    }
}

/// Unciv PantheonPickerScreen: every pantheon belief, those taken by another religion or blocked disabled in red; a tap
/// selects one and shows its description, "Follow [belief]" founds the pantheon with Choir and closes.
struct ReligionScreen: View {
    @ObservedObject var controller: GameController
    @State private var selected: String? = nil   // Unciv PantheonPickerScreen.selectedPantheon
    var body: some View {
        let s = controller.state
        let civ = s.player
        ReligionPickerFrame(onClose: { controller.showReligion = false },
                            okTitle: selected.map { L("Follow [\($0)]") } ?? L("Choose a pantheon"),
                            okEnabled: selected != nil && controller.isMyTurn && !civ.isSpectator,
                            onOK: {
                                guard let b = selected else { return }
                                controller.foundPantheon(b); controller.showReligion = false
                            }) {
            EmptyView()
        } content: {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                    ForEach(s.rs.beliefList.filter { $0.type == "Pantheon" }) { b in   // Unciv ruleset.beliefs.values: json order
                        let allowed = s.beliefOwner(b.name) == nil && s.beliefIsAllowed(civ, b)
                        BeliefButton(label: BeliefButtonLabel(belief: b, withTypeLabel: false), state: !allowed ? .red : selected == b.name ? .selected : .normal) { selected = b.name }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 54).padding(.bottom, 10)
            }
        } description: {
            if let b = selected.flatMap({ s.rs.beliefs[$0] }) { BeliefDescription(controller: controller, belief: b) }
        }
        .screenShown("religion")
    }
}

/// Unciv ReligiousBeliefsPickerScreen: religion icons on top (pick one and name it when founding, all disabled with the
/// current one green otherwise), the religion's beliefs so far (green) and one button per belief to choose on the left,
/// the beliefs of the selected slot's type on the right, the last tapped belief described in the bottom bar.
struct FoundReligionSheet: View {
    @ObservedObject var controller: GameController
    let enhance: Bool
    var freeBeliefs: Bool = false
    @State private var religionName: String? = nil     // Unciv religionName: the icon picked
    @State private var displayName: String? = nil      // Unciv displayName: the icon's name or the name typed for it
    @State private var choices: [String?] = []         // Unciv beliefsToChoose[i].belief
    @State private var leftSelectedIndex = -1          // Unciv leftSelectedIndex
    @State private var described: String? = nil        // the belief shown in the description
    @State private var renaming = false
    private var pickIconAndName: Bool { !enhance && !freeBeliefs }
    /// Unciv beliefsToChoose: one entry per belief of the counter, in BeliefType order
    private var slotTypes: [String] {
        let s = controller.state
        let counter = freeBeliefs ? s.player.freeBeliefsByType : s.beliefsToChoose(civId: s.playerId, enhancing: enhance)
        return s.beliefTypeOrder.flatMap { t in Array(repeating: t, count: counter[t] ?? 0) }
    }
    private func close() { controller.showFoundReligion = false; controller.showEnhanceReligion = false; controller.showFreeBeliefs = false }
    var body: some View {
        let s = controller.state
        let civ = s.player
        let types = slotTypes
        let picks = types.indices.map { $0 < choices.count ? choices[$0] : nil }
        let currentName = civ.religionDisplayName ?? civ.religionName ?? civ.pantheonBelief ?? "None"
        let okTitle = pickIconAndName ? (displayName.map { L("Found [\($0)]") } ?? L("Choose a Religion")) : L("Enhance [\(currentName)]")
        let ready = (!pickIconAndName || (religionName != nil && displayName != nil)) && picks.allSatisfy { $0 != nil } && controller.isMyTurn
        ReligionPickerFrame(onClose: close, okTitle: okTitle, okEnabled: ready, onOK: {
            let beliefs = picks.compactMap { $0 }
            if freeBeliefs { controller.applyFreeBeliefs(beliefs) }
            else if enhance { controller.enhanceReligion(beliefs: beliefs) }
            else if let n = religionName { controller.foundReligion(name: n, displayName: displayName == n ? nil : displayName, beliefs: beliefs) }
        }) {
            topIcons(s, civ, currentName: currentName)
        } content: {
            HStack(alignment: .top, spacing: 0) {
                ScrollView { leftTable(s, civ, types: types, picks: picks).padding(10) }.frame(maxWidth: .infinity)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                ScrollView { rightTable(s, civ, types: types, picks: picks).padding(10) }.frame(maxWidth: .infinity)
            }
        } description: {
            if let b = described.flatMap({ s.rs.beliefs[$0] }) { BeliefDescription(controller: controller, belief: b) }
        }
        .overlay {
            if renaming, let n = religionName {
                // Unciv AskTextPopup "Choose a name for your religion": not "No religion", no ruleset religion, no founded one, not empty
                RenamePopup(title: L("Choose a name for your religion"), initial: n, validate: { s.religionDisplayNameIsValid($0) }, onDone: { t in
                    if let t { displayName = t }
                    renaming = false
                })
            }
        }
        .onAppear { if choices.count != types.count { choices = Array(repeating: nil, count: types.count) } }
    }

    /// Unciv setupChoosableReligionIcons / setupVisibleReligionIcons
    @ViewBuilder private func topIcons(_ s: GameState, _ civ: Civilization, currentName: String) -> some View {
        VStack(spacing: 6) {
            if pickIconAndName {
                HStack(spacing: 8) {
                    Text(displayName.map { L($0) } ?? L("Choose an Icon and name for your Religion")).font(Theme.heading(16))
                    Button { renaming = true } label: {
                        Image(uiImage: Art.shared.image("Pencil", folder: "OtherIcons") ?? UIImage()).renderingMode(.template).resizable().foregroundStyle(Color(white: 0.2)).padding(6).frame(width: 30, height: 30).background(Circle().fill(Color.white))
                    }.buttonStyle(.plain).disabled(religionName == nil).opacity(religionName == nil ? 0.4 : 1)
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(s.rs.religionNames, id: \.self) { r in
                            let isCurrent = pickIconAndName ? religionName == r : civ.religionName == r
                            let taken = s.foundedReligions.contains(r)
                            Button {
                                religionName = r; displayName = r   // Unciv changeDisplayedReligionName(religionName)
                            } label: {
                                ReligionPortrait(name: r, size: 50).padding(3)
                                    .overlay(Circle().stroke(isCurrent ? Theme.good : taken ? Theme.danger : Color.clear, lineWidth: 2.5))
                                    .opacity(taken && !isCurrent ? 0.45 : 1)
                            }
                            .buttonStyle(.plain).id(r)
                            .disabled(!pickIconAndName || isCurrent || taken)
                        }
                    }.padding(.horizontal, 16)
                }
                .onAppear { if let r = pickIconAndName ? religionName : civ.religionName { proxy.scrollTo(r, anchor: .center) } }
            }
            if !pickIconAndName { Text(L(currentName)).font(Theme.heading(16)) }
        }
        .padding(.top, 12).padding(.bottom, 8).padding(.trailing, 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// Unciv updateLeftTable: the religion's beliefs (disabled green) then one button per belief to choose
    @ViewBuilder private func leftTable(_ s: GameState, _ civ: Civilization, types: [String], picks: [String?]) -> some View {
        VStack(spacing: 10) {
            ForEach(religionBeliefsOrdered(s, civ), id: \.self) { b in
                BeliefButton(label: BeliefButtonLabel(belief: s.rs.beliefs[b]), state: .green) {}
            }
            ForEach(Array(types.enumerated()), id: \.offset) { i, t in
                BeliefButton(label: BeliefButtonLabel(belief: picks[i].flatMap { s.rs.beliefs[$0] }, slotType: t), state: leftSelectedIndex == i ? .selected : .normal) {
                    leftSelectedIndex = i; described = picks[i]
                }
            }
        }
    }

    /// Unciv loadRightTable: every ruleset belief of the slot's type (all for Any), in ruleset order
    @ViewBuilder private func rightTable(_ s: GameState, _ civ: Civilization, types: [String], picks: [String?]) -> some View {
        if types.indices.contains(leftSelectedIndex) {
            let type = types[leftSelectedIndex]
            VStack(spacing: 10) {
                ForEach(s.rs.beliefList.filter { type == "Any" || $0.type == type }) { b in
                    BeliefButton(label: BeliefButtonLabel(belief: b), state: rightState(s, civ, b, picks: picks)) {
                        if choices.count != types.count { choices = Array(repeating: nil, count: types.count) }
                        choices[leftSelectedIndex] = b.name; described = b.name
                    }
                }
            }
        }
    }

    private func rightState(_ s: GameState, _ civ: Civilization, _ b: BeliefDef, picks: [String?]) -> BeliefButtonState {
        if picks[leftSelectedIndex] == b.name { return .selected }
        if picks.contains(b.name) || religionBeliefsOrdered(s, civ).contains(b.name) { return .green }
        if let owner = s.beliefOwner(b.name), owner.id != civ.id { return .red }
        if !s.beliefIsAllowed(civ, b) { return .red }
        return .normal
    }
}

/// Unciv EspionageOverviewScreen: the spies (name, rank, location, action, Move) beside the locations (the hideout, then
/// every explored city: ours, majors', city-states'); tapping Move shows where the spy may go, a long press picks the city
/// on the map.
struct EspionageScreen: View {
    @ObservedObject var controller: GameController
    var body: some View {
        ZStack {
            Theme.background
            EspionageList(controller: controller, onMove: { controller.showEspionage = false })
                .padding(.top, 50)
        }
        .overlay(alignment: .topTrailing) {
            Button { controller.closeEspionage() } label: {   // Unciv closeButton: updateViewableTiles, then popScreen
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.cream)
                    .frame(width: 34, height: 34).background(Circle().fill(Theme.fill)).overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
            }.padding(12)
        }
        .foregroundStyle(Theme.cream)
        .screenShown("espionage")
    }
}

/// Unciv EspionageOverviewScreen: the two panes
struct EspionageList: View {
    @ObservedObject var controller: GameController
    @State private var selectedSpyId: Int? = nil   // Unciv EspionageOverviewScreen.selectedSpy
    @State private var coupCity: Int? = nil        // Unciv CoupButton ConfirmPopup
    @State private var promiseMove: Int? = nil     // Unciv MoveToLocationButton "This may result in breaking your promise to [civ]"
    /// Unciv onSpyRightClicked (long press here): select the spy on the world screen and pick a city on the map.
    var onMove: (() -> Void)? = nil
    private static func rankColor(_ r: Int) -> Color { r == 1 ? Color(red: 0.59, green: 0.29, blue: 0) : r == 2 ? Color(white: 0.75) : Theme.gold }   // BROWN, LIGHT_GRAY, GOLD
    var body: some View {
        let s = controller.state
        let civ = controller.selectedCiv   // Unciv EspionageOverviewScreen(worldScreen.selectedCiv, worldScreen)
        HStack(alignment: .top, spacing: 0) {
            ScrollView { spyTable(s, civ).padding(10) }.frame(maxWidth: .infinity)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ScrollView { locationTable(s, civ).padding(10) }.frame(maxWidth: .infinity)
        }
        // Unciv CoupButton: `(getCoupChanceOfSuccess(false) * 100f).toInt()` - without the defending spy ("we don't want
        // to reveal that there is a defending spy"), multiplied and truncated in Float
        .confirmationDialog(L("Do you want to stage a coup in [\(coupCity.flatMap { s.city($0) }.flatMap { s.civ($0.civId) }?.nation ?? "?")] with a [\(Int(Float((selectedSpyId.flatMap { id in civ.spies.first { $0.id == id } }).flatMap { s.coupChance(civId: civ.id, spy: $0, includeUnknownFactors: false) } ?? 0) * Float(100)))]% chance of success?"), isPresented: Binding(get: { coupCity != nil }, set: { if !$0 { coupCity = nil } }), titleVisibility: .visible) {
            Button(L("Stage Coup"), role: .destructive) { if let id = selectedSpyId { controller.attemptCoup(id) }; coupCity = nil; selectedSpyId = nil }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("This may result in breaking your promise to [\(promiseMove.flatMap { s.city($0) }.flatMap { s.civ($0.civId) }?.nation ?? "?")]"), isPresented: Binding(get: { promiseMove != nil }, set: { if !$0 { promiseMove = nil } }), titleVisibility: .visible) {
            Button(L("Move")) { if let id = selectedSpyId, let c = promiseMove { controller.assignSpy(id, to: c) }; promiseMove = nil; selectedSpyId = nil }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    private func canMove(_ spy: Spy) -> Bool { controller.isMyTurn && !controller.state.player.isSpectator && spy.alive && controller.state.player.isAlive }
    /// Unciv onSpyClicked: the same spy again resets the selection
    private func toggle(_ spy: Spy) { selectedSpyId = selectedSpyId == spy.id ? nil : spy.id }

    /// Unciv updateSpyList: Spy, Rank (the effective rank as a number), the location's icon, Location, Action, Move
    @ViewBuilder private func spyTable(_ s: GameState, _ civ: Civilization) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text(L("Spy")); Text(L("Rank")); Color.clear.frame(width: 1, height: 1); Text(L("Location")); Text(L("Action")); Color.clear.frame(width: 1, height: 1)
            }.font(Theme.caption.bold()).foregroundStyle(Theme.gold)
            ForEach(civ.spies) { spy in
                let rank = s.effectiveSpyRank(spy, action: GameState.spyActionDisplay[spy.action] ?? spy.action)
                let display = L(GameState.spyActionDisplay[spy.action] ?? spy.action)
                let showTurns = ["Moving", "EstablishNetwork", "StealingTech", "RiggingElections", "Dead"].contains(spy.action)
                let city = spy.cityId.flatMap { s.city($0) }
                GridRow {
                    Text(L(spy.name)).font(Theme.caption)
                    Text(Translations.shared.numberTr(rank)).font(Theme.caption)   // getEffectiveRank().toLabel()
                    locationIcon(s, city)
                    Text(city?.name ?? L("Spy Hideout")).font(Theme.caption).lineLimit(1)
                    Text(showTurns ? "\(display) \(spy.turnsRemaining)⏳" : display).font(Theme.caption).lineLimit(1)
                    Text(selectedSpyId == spy.id ? L("Cancel") : L("Move")).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelDark)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.gold, lineWidth: 1))
                        .opacity(canMove(spy) ? 1 : 0.4)
                        .onTapGesture { if canMove(spy) { toggle(spy) } }
                        .onLongPressGesture { if canMove(spy) { controller.selectSpy(spy.id); onMove?() } }
                }
            }
        }
    }

    /// Unciv Location.getIcon: the hideout, or the owner's nation portrait with the capital indicator for a major's capital
    @ViewBuilder private func locationIcon(_ s: GameState, _ c: City?) -> some View {
        if let c {
            NationBadge(nation: s.civ(c.civId)?.nationDef, size: 30)
                .overlay(alignment: .topTrailing) {
                    if c.isCapital, s.civ(c.civId)?.isCityState != true { ArtIcon(name: "Capital", folder: "OtherIcons", fallback: "star.fill", size: 12) }
                }
        } else {
            ArtIcon(name: "Hideout", folder: "OtherIcons", fallback: "house.fill", size: 33)
        }
    }

    /// Unciv getSpyIcon: the spy icon with its rank in stars (up to nine, a bigger star per ten ranks); tapping it selects the
    /// spy like Move, a long press picks a city on the map
    @ViewBuilder private func spyIcon(_ s: GameState, _ spy: Spy) -> some View {
        let r = s.effectiveSpyRank(spy, action: GameState.spyActionDisplay[spy.action] ?? spy.action)
        HStack(spacing: 1) {
            ArtIcon(name: "Spy_White", folder: "OtherIcons", fallback: "person.fill.viewfinder", size: 26)
            if r >= 10 { Image(systemName: "star.fill").font(.system(size: 14)).foregroundStyle(Self.rankColor(r / 10)) }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(8), spacing: 1), count: 3), spacing: 1) {
                ForEach(0..<(r % 10), id: \.self) { _ in Image(systemName: "star.fill").font(.system(size: 7)).foregroundStyle(Self.rankColor(r)) }
            }.frame(width: 26)
        }
        .contentShape(Rectangle())
        .onTapGesture { if canMove(spy) { toggle(spy) } }
        .onLongPressGesture { if canMove(spy) { controller.selectSpy(spy.id); onMove?() } }
    }

    /// Unciv updateLocationList: the hideout, then explored cities - ours first, then majors', then city-states', by
    /// civ name and city name
    @ViewBuilder private func locationTable(_ s: GameState, _ civ: Civilization) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Color.clear.frame(width: 1, height: 1); Text(L("City")); Text(L("Spy present")); Color.clear.frame(width: 1, height: 1)
            }.font(Theme.caption.bold()).foregroundStyle(Theme.gold)
            locationRow(s, civ, nil)
            ForEach(sortedLocations()) { c in locationRow(s, civ, c) }
        }
    }

    private func sortedLocations() -> [City] {
        let s = controller.state, civ = controller.selectedCiv
        return s.cities.filter { civ.explored.contains($0.coord) }.sorted { a, b in
            let ka = (a.civId == civ.id ? 0 : 1, s.civ(a.civId)?.isCityState == true ? 1 : 0), kb = (b.civId == civ.id ? 0 : 1, s.civ(b.civId)?.isCityState == true ? 1 : 0)
            if ka != kb { return ka < kb }
            let na = L(s.civ(a.civId)?.nation ?? ""), nb = L(s.civ(b.civId)?.nation ?? "")
            if na != nb { return LocaleCode.compare(na, nb) == .orderedAscending }
            return LocaleCode.compare(L(a.name), L(b.name)) == .orderedAscending
        }
    }

    @ViewBuilder private func locationRow(_ s: GameState, _ civ: Civilization, _ c: City?) -> some View {
        // Unciv Location.getSpies: the idle spies for the hideout, the spies assigned to a city
        let spiesHere = civ.spies.filter { c == nil ? $0.alive && $0.cityId == nil && $0.action == "None" : $0.cityId == c!.id && $0.action != "Dead" }
        let selected = selectedSpyId.flatMap { id in civ.spies.first { $0.id == id } }
        GridRow {
            locationIcon(s, c)
            if let c {
                // Unciv: tapping a city's name closes the screen and centres the map on it (setCenterPosition, selectUnit)
                Button(L(c.name)) { onMove?(); controller.setCenterPosition(c.coord); controller.refresh(full: false) }.font(Theme.caption).buttonStyle(.plain)
            } else {
                Text(L("Spy Hideout")).font(Theme.caption)
            }
            HStack(spacing: 4) { ForEach(spiesHere) { sp in spyIcon(s, sp) } }
            actionButton(s, civ, c, spiesHere: spiesHere, selected: selected)
        }
    }

    /// Unciv SpyLocationActionButton: shown only while a spy is selected - at its own location (the coup fist in a
    /// city-state its first spy may stage a coup in, else the disabled right arrow), and at the hideout and every location
    /// without a spy of ours (the left arrow)
    @ViewBuilder private func actionButton(_ s: GameState, _ civ: Civilization, _ c: City?, spiesHere: [Spy], selected: Spy?) -> some View {
        if let spy = selected {
            let isCurrent = spy.cityId == c?.id
            let first = spiesHere.first
            if let c, s.civ(c.civId)?.isCityState == true, let f = first, s.canDoCoup(civId: civ.id, spy: f) {
                if isCurrent {
                    Button { if f.action == "Coup" { controller.cancelCoup(f.id) } else { coupCity = c.id } } label: {
                        ArtIcon(name: "Resistance", folder: "StatIcons", fallback: "hand.raised.fill", size: 24).opacity(f.action == "Coup" ? 1 : 0.45)
                    }.buttonStyle(.plain)
                }
            } else if isCurrent || c == nil || !civ.spies.contains(where: { $0.cityId == c!.id && $0.action != "Dead" }) {
                Button { move(spy, to: c) } label: {
                    Image(systemName: isCurrent ? "arrow.right" : "arrow.left").font(.system(size: 18, weight: .bold)).foregroundStyle(isCurrent ? Theme.creamDim : Theme.cream)
                }.buttonStyle(.plain).disabled(isCurrent)
            }
        }
    }

    private func move(_ spy: Spy, to c: City?) {
        let s = controller.state, civ = controller.selectedCiv
        if let c, let owner = s.civ(c.civId), owner.id != civ.id, owner.isMajor, civ.metCivs.contains(owner.id), s.hasFlag(owner.id, civ.id, "AgreedToNotSendSpies") {
            promiseMove = c.id
            return
        }
        controller.assignSpy(spy.id, to: c?.id)
        selectedSpyId = nil
    }
}
