// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv DiplomaticVotePickerScreen: every known civ (sorted like the diplomacy screen) plus Abstain; "Choose a civ to vote for" confirms.
struct DiplomaticVotePickerView: View {
    /// Unciv GameInfo.getCivsSorted (getKnownCivsSorted; the result screen puts the viewing civ first itself): majors first,
    /// then by the translated name in the locale's collation
    static func civOrder(_ a: Civilization, _ b: Civilization) -> Bool {
        a.isMajor != b.isMajor ? a.isMajor : LocaleCode.compare(L(a.nation), L(b.nation)) == .orderedAscending
    }
    @ObservedObject var controller: GameController
    @State private var chosen: Int? = nil
    @State private var picked = false

    var body: some View {
        let s = controller.state
        let me = s.player
        let civs = s.knownCivs(me.id).filter { $0.isAlive && $0.isMajor && $0.id != me.id }.sorted(by: DiplomaticVotePickerView.civOrder)
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea().bleedIntoCutout()
            Panel(highlighted: true) {
                VStack(spacing: 8) {
                    Text(L("Vote for World Leader")).font(Theme.title(20)).foregroundStyle(Theme.gold)
                    Text(L("Choose who should become the world leader and win a Diplomatic Victory!")).font(Theme.caption).foregroundStyle(Theme.creamDim).multilineTextAlignment(.center)
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(civs) { c in
                                // Unciv addButton: a tap picks, a double tap votes at once
                                HStack(spacing: 8) { NationBadge(nation: c.nationDef, size: 26); Text(L(c.nation)).font(Theme.body); Spacer() }
                                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(picked && chosen == c.id ? Theme.panelLight : Theme.panelDark))
                                    .contentShape(Rectangle())
                                    .uncivTaps(onTap: { chosen = c.id; picked = true }, onDoubleTap: { controller.castDiplomaticVote(for: c.id) })
                            }
                            HStack(spacing: 8) { ArtIcon(name: "Stop", folder: "OtherIcons", fallback: "hand.raised.slash.fill", size: 26); Text(L("Abstain")).font(Theme.body); Spacer() }
                                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(picked && chosen == nil ? Theme.panelLight : Theme.panelDark))
                                .contentShape(Rectangle())
                                .uncivTaps(onTap: { chosen = nil; picked = true }, onDoubleTap: { controller.castDiplomaticVote(for: nil) })
                        }
                    }.frame(maxHeight: 260)
                    HStack {
                        Button(L("Close")) { controller.showVotePicker = false }.buttonStyle(ThemedButtonStyle(compact: true))
                        Spacer()
                        Button(picked ? (chosen.map { L("Vote for [\(s.civ($0)?.nation ?? "?")]") } ?? L("Abstain")) : L("Choose a civ to vote for")) { controller.castDiplomaticVote(for: chosen) }
                            .buttonStyle(ThemedButtonStyle(filled: true, compact: true)).disabled(!picked)
                    }
                }
            }.frame(maxWidth: 460).padding(20)
        }
    }
}

/// Unciv DiplomaticVoteResultScreen: votes received per civ, the UN owner's double vote, who voted for whom, and the winner text.
struct DiplomaticVoteResultView: View {
    @ObservedObject var controller: GameController

    var body: some View {
        let s = controller.state
        let me = s.player
        let breakdown = s.diplomaticVictoryVoteBreakdown(viewer: me.id)
        let un = s.unBuildingAndOwner()
        let ordered = [me] + s.votingCivs().filter { $0.id != me.id }.sorted(by: DiplomaticVotePickerView.civOrder)
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea().bleedIntoCutout()
            Panel(highlighted: true) {
                VStack(spacing: 8) {
                    Text(L("Vote for World Leader")).font(Theme.title(20)).foregroundStyle(Theme.gold)
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(ordered) { c in
                                HStack(spacing: 8) {
                                    Text(c.isMajor ? "\(breakdown.results[c.id] ?? 0)" : "").font(Theme.body.bold()).frame(width: 26, alignment: .trailing)
                                    NationBadge(nation: c.nationDef, size: 22)
                                    Text(L(c.nation)).font(Theme.caption).frame(width: 110, alignment: .leading).lineLimit(1)
                                    if let un, un.owner == c.id { ArtIcon(name: un.building, folder: "BuildingIcons", fallback: "building.columns", size: 20); Text(L("[2] votes")).font(Theme.small) }
                                    else { Text(L("[1] vote")).font(Theme.small).frame(width: 60, alignment: .leading) }
                                    if let v = s.diplomaticVictoryVotesCast[c.id], v >= 0, let voted = s.civ(v), voted.isAlive {
                                        Text(L("Voted for")).font(Theme.small).foregroundStyle(Theme.creamDim)
                                        NationBadge(nation: voted.nationDef, size: 20)
                                        Text(L(voted.nation)).font(Theme.caption).lineLimit(1)
                                    } else { Text(L("Abstained")).font(Theme.small).foregroundStyle(Theme.creamDim) }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }.frame(maxHeight: 240)
                    Text(breakdown.winnerText).font(Theme.body).foregroundStyle(Theme.gold).multilineTextAlignment(.center)
                    Button(L("Continue")) { controller.dismissVoteResult() }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                }
            }.frame(maxWidth: 560).padding(20)
        }
    }
}
