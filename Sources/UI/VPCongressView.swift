// Vox Populi World Congress screen for VPiOS (MPL-2.0).
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// The host, the delegates, the active resolutions, the proposals of the coming session with the player's delegates
// on each (Yea / Nay), and, when the player is a proposer, the proposals it can make (VP/VPLeague.swift).

import SwiftUI

struct VPCongressView: View {
    @ObservedObject var controller: GameController
    @State private var tick = 0
    @State private var proposing = false

    var body: some View {
        let s = controller.state
        let me = s.playerId
        let league = s.vpLeague
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { controller.showCongress = false }
            Panel(highlighted: true) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("World Congress")).font(Theme.title(20)).foregroundStyle(Theme.gold)
                        Spacer()
                        Button(L("Close")) { controller.showCongress = false }.buttonStyle(ThemedButtonStyle(compact: true))
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if !league.founded {
                                Text(L("The World Congress is founded once a civilization that knows Printing Press has met every other civilization."))
                                    .font(Theme.body).foregroundStyle(Theme.cream)
                            } else {
                                header(s, league)
                                delegates(s)
                                section("Active resolutions")
                                if league.active.isEmpty { Text(L("None")).font(Theme.caption).foregroundStyle(Theme.creamDim) }
                                ForEach(Array(league.active.enumerated()), id: \.offset) { _, a in entry(s, a) }
                                projects(s, me)
                                if s.vpHegemonyEnabled || !league.lastHegemony.isEmpty { hegemony(s, me) }
                                proposals(s, me)
                                if league.pendingProposers.contains(me) { proposeSection(s, me) }
                                if !league.lastResults.isEmpty {
                                    section("Last session")
                                    ForEach(league.lastResults, id: \.self) { Text($0).font(Theme.caption).foregroundStyle(Theme.creamDim) }
                                }
                            }
                        }.id(tick)
                    }.frame(maxHeight: 520)
                }
            }.frame(maxWidth: 520).padding(16)
        }
    }

    private func section(_ t: String) -> some View {
        Text(L(t)).font(Theme.title(15)).foregroundStyle(Theme.gold).padding(.top, 4)
    }

    private func header(_ s: GameState, _ league: VPLeagueState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Host") + ": " + L(s.civ(league.host ?? -1)?.nation ?? "-")).font(Theme.body).foregroundStyle(Theme.cream)
            Text(L("Congress era") + ": " + L(GameState.vpLeagueEraNames[min(3, league.era)])).font(Theme.caption).foregroundStyle(Theme.creamDim)
            Text(L("Next session in [\(s.vpLeagueTurnsToSession())] turns")).font(Theme.caption).foregroundStyle(Theme.creamDim)
        }
    }

    private func delegates(_ s: GameState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            section("Delegates")
            ForEach(s.vpLeagueMembers().sorted { s.vpDelegates($0.id).0 > s.vpDelegates($1.id).0 }) { c in
                let d = s.vpDelegates(c.id)
                HStack(spacing: 6) {
                    NationBadge(nation: c.nationDef, size: 20)
                    Text(L(c.nation)).font(Theme.caption).foregroundStyle(Theme.cream)
                    Spacer()
                    Text("\(d.0)").font(Theme.body).foregroundStyle(Theme.gold)
                }
                if c.id == s.playerId {
                    Text(d.1.map { "\(L($0.0)) \($0.1)" }.joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(Theme.creamDim)
                }
            }
        }
    }

    private func entry(_ s: GameState, _ e: VPLeagueEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L(s.vpEntryTitle(e))).font(Theme.body).foregroundStyle(Theme.cream)
            Text(L(e.resolution.help)).font(.system(size: 11)).foregroundStyle(Theme.creamDim)
        }.padding(6).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelDark))
    }

    private func proposals(_ s: GameState, _ me: Int) -> some View {
        let league = s.vpLeague
        let mine = s.vpDelegates(me).0
        let used = league.playerVotes.reduce(0) { $0 + abs($1) }
        return VStack(alignment: .leading, spacing: 6) {
            section("Proposals")
            if league.proposals.isEmpty { Text(L("None yet")).font(Theme.caption).foregroundStyle(Theme.creamDim) }
            else { Text(L("Delegates left: [\(max(0, mine - used))] of [\(mine)]")).font(Theme.caption).foregroundStyle(Theme.creamDim) }
            ForEach(Array(league.proposals.enumerated()), id: \.offset) { i, p in
                VStack(alignment: .leading, spacing: 4) {
                    entry(s, p)
                    HStack {
                        Text(L("Proposed by [\(s.civ(p.proposer)?.nation ?? "?")]")).font(.system(size: 10)).foregroundStyle(Theme.creamDim)
                        Spacer()
                        let v = i < league.playerVotes.count ? league.playerVotes[i] : 0
                        Button("−") { vote(i, -1, mine) }.buttonStyle(ThemedButtonStyle(compact: true))
                        Text(v == 0 ? L("Abstain") : v > 0 ? L("Yea [\(v)]") : L("Nay [\(-v)]"))
                            .font(Theme.caption).foregroundStyle(v > 0 ? Theme.gold : v < 0 ? Theme.danger : Theme.cream).frame(minWidth: 70)
                        Button("+") { vote(i, 1, mine) }.buttonStyle(ThemedButtonStyle(compact: true))
                    }
                }
            }
        }
    }

    @ViewBuilder private func projects(_ s: GameState, _ me: Int) -> some View {
        let underway = s.vpProjectsUnderway()
        if !underway.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                section("International projects")
                ForEach(underway, id: \.self) { r in
                    let cost = max(1, s.vpProjectCost(r)), done = s.vpProjectProgress(r)
                    let tier = ["-", "Bronze", "Silver", "Gold"][s.vpProjectTier(r, me)]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(r.title) + " \(done * 100 / cost)%").font(Theme.body).foregroundStyle(Theme.cream)
                        Text(L("Your contribution: [\(s.vpProjectContribution(r, me))] (Bronze [\(s.vpProjectCostPerPlayer(r) / 2)], Silver [\(s.vpProjectCostPerPlayer(r))], Gold: the most). Now: [\(tier)]"))
                            .font(.system(size: 10)).foregroundStyle(Theme.creamDim)
                        Text(L("Choose \"Produce [\(r.title)]\" in a city to contribute its Production.")).font(.system(size: 10)).foregroundStyle(Theme.creamDim)
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelDark))
                }
            }
        }
    }

    private func hegemony(_ s: GameState, _ me: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            section("Global Hegemony")
            if s.vpHegemonyEnabled {
                Text(L("Delegates needed: [\(s.vpHegemonyVotesNeeded())]. Hegemony votes alternate with resolution sessions.")).font(Theme.caption).foregroundStyle(Theme.creamDim)
                Text(L("Your vote:")).font(Theme.caption).foregroundStyle(Theme.cream)
                ForEach(s.vpLeagueMembers()) { c in
                    Button {
                        s.vpLeague.playerHegemonyVote = c.id; tick += 1
                    } label: {
                        HStack(spacing: 6) {
                            NationBadge(nation: c.nationDef, size: 18)
                            Text(L(c.nation)).font(Theme.caption)
                            Spacer()
                            if s.vpLeague.playerHegemonyVote == c.id { Image(systemName: "checkmark").foregroundStyle(Theme.gold) }
                        }.padding(4)
                    }.buttonStyle(.plain)
                }
                Button(L("Abstain")) { s.vpLeague.playerHegemonyVote = nil; tick += 1 }.buttonStyle(ThemedButtonStyle(compact: true))
            }
            if !s.vpLeague.lastHegemony.isEmpty { Text(s.vpLeague.lastHegemony).font(.system(size: 10)).foregroundStyle(Theme.creamDim) }
        }
    }

    /// One delegate more towards Yea (+1) or Nay (-1), within the player's delegates.
    private func vote(_ i: Int, _ step: Int, _ mine: Int) {
        let s = controller.state
        if s.vpLeague.playerVotes.count != s.vpLeague.proposals.count { s.vpLeague.playerVotes = Array(repeating: 0, count: s.vpLeague.proposals.count) }
        let cur = s.vpLeague.playerVotes[i], next = cur + step
        let used = s.vpLeague.playerVotes.reduce(0) { $0 + abs($1) } - abs(cur) + abs(next)
        guard used <= mine else { return }
        s.vpLeague.playerVotes[i] = next
        tick += 1
    }

    private func proposeSection(_ s: GameState, _ me: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            section("Your proposal")
            Button(proposing ? L("Hide options") : L("Choose a proposal")) { proposing.toggle() }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
            if proposing {
                ForEach(Array(s.vpProposalOptions(me).enumerated()), id: \.offset) { _, e in
                    Button {
                        s.vpPropose(e); proposing = false; tick += 1
                        controller.refresh(full: false)
                    } label: { entry(s, e) }.buttonStyle(.plain)
                }
                Button(L("Make no proposal")) { s.vpLeague.pendingProposers.removeAll { $0 == me }; proposing = false; tick += 1 }
                    .buttonStyle(ThemedButtonStyle(compact: true))
            }
        }
    }
}
