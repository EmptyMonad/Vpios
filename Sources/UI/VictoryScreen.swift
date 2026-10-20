// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv VictoryScreen: Our status, Global status, Rankings, Demographics, Charts.
struct VictoryScreen: View {
    @ObservedObject var controller: GameController
    /// Unciv displayWonOrLost's rightSideButton "Start new game"
    var onNewGame: (() -> Void)? = nil
    @State private var tab: String   // Unciv VictoryScreen opens on page 0, "Our status"
    @State private var chartType = "Score"
    @State private var chartCiv: Int? = nil
    init(controller: GameController, onNewGame: (() -> Void)? = nil) {
        self.controller = controller
        self.onNewGame = onNewGame
        _tab = State(initialValue: controller.state.player.isSpectator ? "Global status" : "Our status")
    }
    private var tabs: [String] {
        let s = controller.state, p = s.player
        let won = s.victoryData != nil   // Unciv gates the stats pages on the recorded victory, not on the game-over popup
        let stats = p.isSpectator || won || s.settings.showCivilizationStats
        var t: [String] = p.isSpectator ? [] : ["Our status"]
        t.append("Global status")
        if stats && (p.isSpectator || s.settings.showDemographics || won) { t.append("Demographics") }
        if stats && (p.isSpectator || s.settings.showRankings || won) { t.append("Rankings") }
        // Unciv VictoryTabs.Charts.isHidden: a spectator (who records no history of its own) sees it once any civ has
        // two history rows, whatever victoryData says; anyone else needs their own two rows and the settings, or a victory
        let chartsShown = p.isSpectator
            ? s.civs.contains { $0.statsHistory.count >= 2 }
            : won || (p.statsHistory.count >= 2 && s.settings.showCivilizationStats && s.settings.showCharts)
        if chartsShown { t.append("Charts") }
        // Unciv: Replay from turn 5, or once the game is won, the player is defeated or spectating
        if s.turn - s.historyStartTurn >= 5 || won || p.isSpectator || s.outcome != nil { t.append("Replay") }
        return t
    }

    /// Unciv VictoryScreen init: displayWinner once a victory is recorded, displayWonOrLost(defeatString) for a defeated player
    private var endTexts: [String]? {
        let s = controller.state
        if let v = s.victoryData, let winner = s.civ(v.winningCiv) {
            let def = s.rs.victory(v.victoryType)
            return winner.id == s.playerId
                ? [L("You have won a [\(v.victoryType)] Victory!"), L(def?.victoryString ?? VictoryDef.defaultVictoryString)]
                : [L("[\(winner.nation)] has won a [\(v.victoryType)] Victory!"), L(def?.defeatString ?? VictoryDef.defaultDefeatString)]
        }
        if s.isDefeated(s.player) { return [L(VictoryDef.defaultDefeatString)] }
        return nil
    }
    /// Unciv displayWonOrLost closeButton "One more turn...!": oneMoreTurnMode, then back to the map
    private func oneMoreTurn() {
        controller.state.oneMoreTurnMode = true
        controller.state.outcome = nil
        controller.showVictory = false
        controller.refresh()
    }

    var body: some View {
        let s = controller.state
        let end = endTexts
        VStack(spacing: 0) {
            ThemedSheet(L("Victory status"), subtitle: "\(L("Difficulty")): \(L(s.settings.difficulty)) · \(L("Game Speed")): \(L(s.settings.speed))" + (s.settings.victoryTypes.contains("Time") ? " · \(L("Max Turns")): \(s.settings.maxTurns)" : ""), onClose: { if end != nil { oneMoreTurn() } else { controller.showVictory = false } }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(tabs, id: \.self) { t in Button(L(t)) { tab = t }.buttonStyle(ThemedButtonStyle(filled: tab == t, compact: true)) } }
                }
                switch tab {
                case "Our status": ourStatus(s)
                case "Global status": globalStatus(s)
                case "Rankings": rankings(s)
                case "Demographics": demographics(s)
                case "Replay": ReplayView(controller: controller)
                default: charts(s)
                }
            }
            // Unciv PickerScreen bottom: the description label, the close button as "One more turn...!", "Start new game"
            if let end {
                HStack(alignment: .center, spacing: 12) {
                    Text(end.joined(separator: "\n")).font(Theme.caption).foregroundStyle(Theme.cream).frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("One more turn...!")) { oneMoreTurn() }.buttonStyle(ThemedButtonStyle(compact: true))
                    // (not while the next turn runs on its clone: the new-game screen rebuilds the shared ruleset the turn's
                    // thread reads, as the menu's Start new game waits for it)
                    Button(L("Start new game")) { onNewGame?() }.buttonStyle(ThemedButtonStyle(filled: true)).disabled(controller.isProcessing)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.panelDark)
            }
        }
        // Unciv VictoryScreen init: worldScreen.autoPlay.stopAutoPlay()
        .onAppear { controller.stopAutoPlay() }
        .screenShown("victory")
    }

    private var enabledVictories: [VictoryDef] { controller.state.rs.victories.filter { !$0.hiddenInVictoryScreen && controller.state.settings.victoryTypes.contains($0.name) } }

    // MARK: Our status (VictoryScreenOurVictory)
    private func ourStatus(_ s: GameState) -> some View {
        let me = s.player
        return ForEach(enabledVictories) { v in
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("[\(v.name)] Victory")).font(Theme.heading(15)).foregroundStyle(Theme.gold)
                    // Unciv VictoryScreenOurVictory.getColumn: each milestone's (done/total) header, and under the
                    // one being worked on, Milestone.getVictoryScreenButtons' checklist of its single steps.
                    ForEach(Array(MilestoneProgress.column(s, v, for: me).enumerated()), id: \.offset) { _, row in
                        if row.step {
                            HStack(spacing: 6) {
                                Image(systemName: row.done ? "checkmark.circle.fill" : "circle").font(.system(size: 10)).foregroundStyle(row.done ? Theme.good : Theme.creamDim)
                                Text(row.text).font(Theme.small).foregroundStyle(row.done ? Theme.cream : Theme.creamDim)
                            }
                            .padding(.leading, 24).padding(.vertical, 1).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: row.done ? "checkmark.seal.fill" : row.partial ? "circle.dotted" : "circle").foregroundStyle(row.done ? Theme.good : row.partial ? Theme.gold : Theme.creamDim)
                                Text(row.text).font(Theme.caption).foregroundStyle(row.done ? Theme.cream : row.partial ? Theme.cream : Theme.creamDim)
                            }
                            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(row.done ? Theme.good.opacity(0.15) : row.partial ? Theme.gold.opacity(0.12) : Color.clear))
                        }
                    }
                    if !v.victoryScreenHeader.isEmpty { Text(L(v.victoryScreenHeader)).font(Theme.small).foregroundStyle(Theme.creamDim) }
                }
            }
        }
    }

    // MARK: Global status (VictoryScreenGlobalVictory)
    private func globalStatus(_ s: GameState) -> some View {
        ForEach(enabledVictories) { v in
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("[\(v.name)] Victory")).font(Theme.heading(15)).foregroundStyle(Theme.gold)
                    // Unciv VictoryScreenGlobalVictory: every major civ, defeated ones last, then ascending by milestones completed
                    let sorted = s.civs.filter { $0.isMajor }.sorted { a, b in
                        if a.isAlive != b.isAlive { return a.isAlive }
                        return v.milestones.filter { s.milestoneCompleted($0, by: a) }.count < v.milestones.filter { s.milestoneCompleted($0, by: b) }.count
                    }
                    ForEach(sorted) { c in
                        // Unciv VictoryScreenGlobalVictory: the civ's next milestone with its (done/total) progress
                        let next = v.milestones.first { !s.milestoneCompleted($0, by: c) }
                        civRow(s, c, detail: next.map { MilestoneProgress.header(s, $0, for: c, completed: false) } ?? L("Done!"))
                    }
                }
            }
        }
    }

    /// Unciv VictoryScreen.canViewCivStats - which civs the Rankings and Charts pages list at all; it does not
    /// decide whether a listed civ's name and value show (labelKnown does).
    private func canView(_ s: GameState, _ c: Civilization) -> Bool { s.victoryData != nil || s.player.isSpectator || !s.settings.hideOtherCivilizationStats || c.id == s.playerId }
    /// Unciv VictoryScreenCivGroup labelText: the civ's name (and its value) only when the viewer knows it, is it,
    /// the civ is defeated or the viewer is - otherwise Constants.unknownNationName ("???") alone, with no value.
    /// (isAlive stands in for Unciv's !isDefeated().)
    private func labelKnown(_ s: GameState, _ c: Civilization) -> Bool {
        let me = s.player
        return me.metCivs.contains(c.id) || c.id == me.id || !c.isAlive || !me.isAlive
    }
    /// Unciv VictoryScreenCivGroup.getCivImageAndColors / LineChart.useActualColor: the nation's own portrait and
    /// colours for a spectator, a defeated civ, the viewer itself, a civ it knows, once the viewer is defeated or
    /// has won (victoryManager.hasWon) - otherwise a grey stand-in.
    private func actualColor(_ s: GameState, _ c: Civilization) -> Bool {
        let me = s.player
        return me.isSpectator || !c.isAlive || c.id == me.id || me.metCivs.contains(c.id) || !me.isAlive || s.victoryTypeAchieved(me) != nil
    }
    private func civRow(_ s: GameState, _ c: Civilization, detail: String) -> some View {
        let known = labelKnown(s, c)
        return HStack(spacing: 8) {
            NationBadge(nation: actualColor(s, c) ? c.nationDef : nil, size: 24)
            Text(known ? L(c.nation) : "???").font(Theme.caption.bold()).foregroundStyle(c.isAlive ? Theme.cream : Theme.creamDim).strikethrough(!c.isAlive)   // labelText.toLabel(): the civName translated; Constants.unknownNationName as is
            Spacer()
            if known { Text(detail).font(Theme.small).foregroundStyle(Theme.creamDim).multilineTextAlignment(.trailing) }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(c.isPlayer ? Theme.gold.opacity(0.12) : Color.clear))
    }

    // MARK: Rankings (VictoryScreenCivRankings)
    private func rankings(_ s: GameState) -> some View {
        ForEach(s.shownRankingTypes, id: \.self) { cat in
            Panel(padding: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(cat)).font(Theme.heading(14)).foregroundStyle(Theme.gold)
                    // Unciv VictoryScreenCivRankings: only the major civs canViewCivStats lets us see are listed
                    let rows = s.civs.filter { $0.isMajor && canView(s, $0) }.map { ($0, s.statForRanking($0, cat)) }.sorted { a, b in
                        let av = a.0.isAlive ? a.1 : Int.min, bv = b.0.isAlive ? b.1 : Int.min
                        return av != bv ? av > bv : a.0.nation < b.0.nation
                    }
                    ForEach(rows, id: \.0.id) { row in civRow(s, row.0, detail: row.0.isAlive ? "\(row.1)" : "") }
                }
            }
        }
    }

    // MARK: Demographics (VictoryScreenDemographics)
    private func demographics(_ s: GameState) -> some View {
        let me = s.player
        return Panel(padding: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        Text(L("Demographic")).font(Theme.small.bold()).frame(width: 90, alignment: .leading)
                        ForEach(["Rank", "Value", "Best", "Average", "Worst"], id: \.self) { h in Text(L(h)).font(Theme.small.bold()).foregroundStyle(Theme.gold).frame(width: h == "Rank" || h == "Average" ? 70 : 120, alignment: .trailing) }
                    }
                    Divider2()
                    ForEach(s.shownRankingTypes, id: \.self) { cat in
                        // Unciv: every major civ (the defeated included) filtered to `isAlive() || it == playerCiv` - a
                        // defeated viewer keeps its place - then a stable sortedByDescending
                        let sorted = s.civs.filter { $0.isMajor && ($0.isAlive || $0.id == me.id) }.map { c -> (Civilization, Int) in
                            let snapshot = c.statsHistory[s.turn - 1] ?? c.statsHistory.max(by: { $0.key < $1.key })?.value
                            return (c, snapshot?[cat] ?? s.statForRanking(c, cat))
                        }.enumerated().sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }.map(\.element)
                        let rank = (sorted.firstIndex { $0.0.id == me.id } ?? -1) + 1   // Unciv: indexOfFirst + 1, 0 when we are not listed
                        // Unciv: (sumOf { value }.toFloat() / size).roundToInt() - a Float division, halves toward +infinity
                        let avg = sorted.isEmpty ? 0 : Stats.roundToInt(Double(Float(sorted.reduce(0) { $0 + $1.1 }) / Float(sorted.count)))
                        HStack(spacing: 0) {
                            Text(L(cat)).font(Theme.small).frame(width: 90, alignment: .leading)
                            // Unciv VictoryScreenDemographics: no Value row for a defeated or non-major player; the rank and
                            // the average are Int.toLabel() = this.tr() - Number.tr in the game's language, as every value here
                            Text(Translations.shared.numberTr(rank)).font(Theme.small).frame(width: 70, alignment: .trailing)
                            if me.isAlive && me.isMajor, let mine = sorted.first(where: { $0.0.id == me.id }) { demoCell(s, mine) }   // Unciv: addRankCivGroup, our own name and value
                            else { Text("-").font(Theme.small).frame(width: 120, alignment: .trailing) }
                            demoCell(s, sorted.first)
                            Text(Translations.shared.numberTr(avg)).font(Theme.small).frame(width: 70, alignment: .trailing)
                            demoCell(s, sorted.last)
                        }
                    }
                }
            }
        }
    }
    private func demoCell(_ s: GameState, _ entry: (Civilization, Int)?) -> some View {
        HStack(spacing: 3) {
            // Unciv VictoryScreenCivGroup(civEntry, playerCiv): "{name}: {value}" for a civ labelText lets us know (no
            // value for a defeated one), else "???" alone - hideOtherCivilizationStats plays no part here
            if let e = entry {
                let known = labelKnown(s, e.0)
                NationBadge(nation: actualColor(s, e.0) ? e.0.nationDef : nil, size: 14)
                Text(known ? (e.0.isAlive ? "\(L(e.0.nation)): \(Translations.shared.numberTr(e.1))" : L(e.0.nation)) : "???").font(Theme.small).lineLimit(1).minimumScaleFactor(0.7)
            }
        }.frame(width: 120, alignment: .trailing)
    }

    // MARK: Charts (VictoryScreenCharts + LineChart)
    private func charts(_ s: GameState) -> some View {
        let civs = s.civs.filter { $0.isMajor && canView(s, $0) }
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) { ForEach(s.shownRankingTypes, id: \.self) { t in Button(L(t)) { chartType = t }.buttonStyle(ThemedButtonStyle(filled: chartType == t, compact: true)) } }
            }
            // Unciv LineChart.useActualColor: an unknown civ's line is DARK_GRAY
            let colored = Set(civs.filter { actualColor(s, $0) }.map(\.id))
            Panel(padding: 8) { LineChartView(state: s, civs: civs, category: chartType, selected: chartCiv ?? s.playerId, actualColor: colored).frame(height: 240) }
            Panel(padding: 6) {
                VStack(spacing: 2) {
                    // Unciv VictoryScreenCharts.updateControls: descending by value, a defeated civ last, then by civName
                    let rows = civs.map { ($0, s.statForRanking($0, chartType)) }.sorted { a, b in
                        let av = a.0.isAlive ? a.1 : Int.min, bv = b.0.isAlive ? b.1 : Int.min
                        return av != bv ? av > bv : a.0.nation < b.0.nation
                    }
                    ForEach(rows, id: \.0.id) { row in
                        // Unciv VictoryScreenCivGroup(civEntry, viewingCiv, DefeatedPlayerStyle.REGULAR): "???" alone for an
                        // unknown civ, the name alone for a defeated one (no `0`), else the name and the value
                        let known = labelKnown(s, row.0)
                        Button { chartCiv = row.0.id } label: {
                            HStack(spacing: 8) {
                                Image(systemName: (chartCiv ?? s.playerId) == row.0.id ? "star.fill" : "circle").foregroundStyle(Theme.gold).font(.system(size: 10))
                                Circle().fill(colored.contains(row.0.id) ? Color(uiColor: UIColor(rgb: row.0.nationDef?.outerColor ?? [200, 200, 200])) : Color(white: 0.75)).frame(width: 12, height: 12)   // LIGHT_GRAY
                                Text(known ? L(row.0.nation) : "???").font(Theme.caption).foregroundStyle(row.0.isAlive ? Theme.cream : Theme.creamDim)
                                Spacer()
                                if known && row.0.isAlive { Text(Translations.shared.numberTr(row.1)).font(Theme.caption).foregroundStyle(Theme.creamDim) }
                            }.padding(.vertical, 3)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Unciv Milestone.getVictoryScreenButtonHeaderText / getVictoryScreenButtons: a milestone's own
/// "(done/total)" progress line, and the checklist of single steps shown while it is the one being worked on.
enum MilestoneProgress {
    /// Unciv Victory.CompletionStatus
    enum Status { case completed, partially, incomplete }
    /// One button of Unciv's milestone column: the milestone header, or one step under it.
    struct Row {
        let text: String
        let done: Bool
        /// A step button under the milestone that is currently being worked on.
        let step: Bool
        let partial: Bool
    }

    /// Unciv VictoryScreenOurVictory.getColumn: milestones in order, the first unfinished one "Partially" done
    /// and the only one that gets its steps listed.
    static func column(_ s: GameState, _ v: VictoryDef, for civ: Civilization) -> [Row] {
        var rows: [Row] = []
        var firstIncomplete = true
        for m in v.milestones {
            let status: Status
            if s.milestoneCompleted(m, by: civ) { status = .completed }
            else if firstIncomplete { firstIncomplete = false; status = .partially }
            else { status = .incomplete }
            rows.append(Row(text: header(s, m, for: civ, completed: status == .completed), done: status == .completed, step: false, partial: status == .partially))
            guard status == .partially else { continue }   // Unciv: only the milestone in progress lists its steps
            for (text, done) in steps(s, v, m, for: civ) { rows.append(Row(text: text, done: done, step: true, partial: false)) }
        }
        return rows
    }

    /// Unciv Milestone.getVictoryScreenButtonHeaderText. GameState.milestoneText writes the milestones it can
    /// count from the game state; the two that need this screen's religion and countable helpers are counted here.
    static func header(_ s: GameState, _ milestone: String, for civ: Civilization, completed: Bool) -> String {
        let u = Unique(milestone)
        switch u.pattern {
        case "Become the world religion":
            // Unciv WorldReligion: (living major civs our religion is the majority of / every living major civ but us);
            // a pantheon alone counts as 1
            let toDo = s.majorCivs.count - 1
            let done: Int
            if completed { done = toDo }
            else if let r = civ.religionName { done = s.majorCivs.filter { isMajorityReligion(s, r, of: $0) }.count }
            else if civ.pantheonBelief != nil { done = 1 }   // Unciv: religion!!.isPantheon() -> 1
            else { done = 0 }
            return L("{\(milestone)} (\(done)/\(toDo))")
        case "Have more [] than each player's []":
            // Unciv MoreCountableThanEachPlayer: (other living majors we beat / all of them) - `completed` is not used
            let others = relevantCivs(s, civ)
            let done = others.filter { percent(s, u, civ, $0) > 100 }.count
            return s.shouldHideCivCount(civ) ? L("{\(milestone)} (\(done)/?)") : L("{\(milestone)} (\(done)/\(others.count))")
        default: return s.milestoneText(milestone, for: civ, completed: completed)
        }
    }

    /// Unciv Milestone.getVictoryScreenButtons: one button per single thing the milestone still asks for.
    static func steps(_ s: GameState, _ v: VictoryDef, _ milestone: String, for civ: Civilization) -> [(String, Bool)] {
        let u = Unique(milestone)
        switch u.pattern {
        case "Add all [] in capital":
            // Unciv: every part already in the capital, walking currentsSpaceshipParts (a Counter - the order the
            // parts were first added) and repeating each by its full count; then getIncompleteSpaceshipParts -
            // requiredSpaceshipPartsAsCounter (first-occurrence order) minus ours, where a count at or below 0 adds nothing
            var out: [(String, Bool)] = []
            for part in civ.spaceshipPartsInOrder { for _ in 0..<max(civ.spaceshipParts[part] ?? 0, 0) { out.append((L(part), true)) } }
            var requiredOrder: [String] = []
            var required: [String: Int] = [:]
            for part in v.requiredSpaceshipParts { if required[part] == nil { requiredOrder.append(part) }; required[part, default: 0] += 1 }
            for part in requiredOrder { for _ in 0..<max(required[part]! - (civ.spaceshipParts[part] ?? 0), 0) { out.append((L(part), false)) } }
            return out
        case "Destroy all players":
            // Unciv DestroyAllPlayers: with the civ count hidden, only the civs we know, then one "Destroy ? * [???]"
            let hideCivCount = s.shouldHideCivCount(civ)
            var out: [(String, Bool)] = []
            for other in s.civs where other.isMajor && other.id != civ.id {
                if hideCivCount && !civ.metCivs.contains(other.id) { continue }
                out.append((L("Destroy [\(civName(civ, other))]"), !other.isAlive))
            }
            if hideCivCount { out.append((L("Destroy ? * [???]"), false)) }   // Unciv "Destroy ? * [${Constants.unknownNationName}]"
            return out
        case "Capture all capitals":
            // Unciv CaptureAllCapitals: a civ whose original capital still stands has to be captured, one without it
            // destroyed; with the civ count hidden a capital we have not explored is left out and one
            // "Capture ? * [???]" closes the list (the "Destroy" rows are not filtered)
            var capitals: [Int: City] = [:]
            for c in s.cities where c.isOriginalCapital { if capitals[c.originalOwner] == nil { capitals[c.originalOwner] = c } }
            let hideCivCount = s.shouldHideCivCount(civ)
            var out: [(String, Bool)] = []
            for other in s.civs where other.isMajor {
                guard let city = capitals[other.id] else { out.append((L("Destroy [\(civName(civ, other))]"), !other.isAlive)); continue }
                let known = civ.explored.contains(city.coord)   // Unciv civInfo.hasExplored(city.getCenterTile())
                if hideCivCount && !known { continue }
                out.append((L("Capture [\(known ? city.name : "???")]"), city.civId == civ.id))   // Constants.unknownCityName
            }
            if hideCivCount { out.append((L("Capture ? * [???]"), false)) }   // Unciv "Capture ? * [${Constants.unknownCityName}]"
            return out
        case "Complete [] Policy branches":
            // Unciv: the finisher policy of every branch
            return s.rs.policyBranches.map { b in
                let finisher = b.completion?.name ?? b.policies.last?.name ?? b.name
                return (L(finisher), civ.policies.contains(finisher))
            }
        case "Become the world religion":
            return s.majorCivs.map { other in
                let met = civ.religionName.map { isMajorityReligion(s, $0, of: other) } ?? false
                return (L("Majority religion of [\(civName(civ, other))]"), met)
            }
        case "Have more [] than each player's []":
            // Unciv MoreCountableThanEachPlayer: with the civ count hidden, only the civs we know, then one "[???]"
            let hideCivCount = s.shouldHideCivCount(civ)
            var out: [(String, Bool)] = []
            for other in relevantCivs(s, civ) {
                if hideCivCount && !civ.metCivs.contains(other.id) { continue }
                let pct = percent(s, u, civ, other)
                let name = civName(civ, other)
                // Unciv hides the percentage when it is zero or already double, like BNW's "Dominant" influence
                out.append((pct < 1 || pct >= 200 ? L("[\(name)]") : L("[\(name)] [\(Int(pct))]%"), pct > 100))
            }
            if hideCivCount { out.append((L("[???]"), false)) }   // Unciv "[${Constants.unknownNationName}]"
            return out
        default: return []   // Unciv: Built/BuiltGlobally, diplomatic vote and score need no extra buttons
        }
    }

    /// Unciv Milestone.getMoreCountableThanOtherCivRelevant: the other living major civs.
    private static func relevantCivs(_ s: GameState, _ civ: Civilization) -> [Civilization] {
        s.civs.filter { $0.isMajor && $0.isAlive && $0.id != civ.id }
    }
    /// Unciv Milestone.getMoreCountableThanOtherCivPercent (>100 means "more than"): our params[0] against
    /// their params[1], in Float.
    private static func percent(_ s: GameState, _ u: Unique, _ civ: Civilization, _ other: Civilization) -> Float {
        let countable1 = s.countable(u.param(0), GameState.UniqueContext(civId: civ.id)) ?? 0
        let countable2 = s.countable(u.param(1), GameState.UniqueContext(civId: other.id)) ?? 0
        guard countable2 > 0 else { return countable1 > countable2 ? 100.1 : 0 }   // Unciv: the extra .1 makes it qualify as >100%
        return Float(countable1) / Float(countable2) * 100
    }
    /// Unciv ReligionManager.isMajorityReligionForCiv: the majority religion in more than half of that civ's cities.
    private static func isMajorityReligion(_ s: GameState, _ religion: String, of civ: Civilization) -> Bool {
        let owned = s.cities(of: civ.id)
        return owned.filter { s.majorityReligion(of: $0) == religion }.count > owned.count / 2
    }
    /// Unciv: a civ we have not met is "???" until it is defeated.
    private static func civName(_ civ: Civilization, _ other: Civilization) -> String {
        other.id == civ.id || civ.metCivs.contains(other.id) || !other.isAlive ? other.nation : L("Unknown civilization")
    }
}

/// Unciv LineChart: one line per civilization from statsHistory, the selected civ drawn on top.
struct LineChartView: View {
    let state: GameState
    let civs: [Civilization]
    let category: String
    let selected: Int
    /// Unciv LineChart.useActualColor: the civs drawn in their nation's colour; any other line is DARK_GRAY.
    let actualColor: Set<Int>
    var body: some View {
        Canvas { ctx, size in
            var series: [(Civilization, [(Int, Int)])] = []
            for c in civs {
                var pts = c.statsHistory.compactMap { turn, row in row[category].map { (turn, $0) } }.sorted { $0.0 < $1.0 }
                // Unciv getLineChartData: the live stat appended at `gameInfo.turns`, the zero-based count the history is keyed by
                if c.isAlive { pts.append((state.uncivTurns, state.statForRanking(c, category))) }
                if pts.count >= 2 { series.append((c, pts)) }
            }
            guard !series.isEmpty else { return }
            let allX = series.flatMap { $0.1.map { $0.0 } }, allY = series.flatMap { $0.1.map { $0.1 } }
            let minX = allX.min() ?? 0, maxX = max((allX.max() ?? 1), minX + 1)
            let minY = min(0, allY.min() ?? 0), maxY = max((allY.max() ?? 1), minY + 1)
            let left: CGFloat = 36, bottom: CGFloat = 18
            let w = size.width - left - 6, h = size.height - bottom - 6
            func px(_ x: Int) -> CGFloat { left + CGFloat(x - minX) / CGFloat(maxX - minX) * w }
            func py(_ y: Int) -> CGFloat { 6 + h - CGFloat(y - minY) / CGFloat(maxY - minY) * h }
            // axes + labels
            var axis = Path(); axis.move(to: CGPoint(x: left, y: 6)); axis.addLine(to: CGPoint(x: left, y: 6 + h)); axis.addLine(to: CGPoint(x: left + w, y: 6 + h))
            ctx.stroke(axis, with: .color(Theme.goldDim), lineWidth: 1)
            for i in 0...4 {
                let y = minY + (maxY - minY) * i / 4
                ctx.draw(Text(Translations.shared.numberTr(y)).font(.system(size: 8)).foregroundStyle(Theme.creamDim), at: CGPoint(x: left - 4, y: py(y)), anchor: .trailing)
                let x = minX + (maxX - minX) * i / 4
                ctx.draw(Text(Translations.shared.numberTr(x)).font(.system(size: 8)).foregroundStyle(Theme.creamDim), at: CGPoint(x: px(x), y: 6 + h + 9), anchor: .center)
            }
            for (c, pts) in series.sorted(by: { a, _ in a.0.id != selected }) {
                var path = Path()
                for (i, p) in pts.enumerated() { let pt = CGPoint(x: px(p.0), y: py(p.1)); if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) } }
                let color = !actualColor.contains(c.id) ? Color(white: 0.25) : Color(uiColor: UIColor(rgb: c.nationDef?.outerColor ?? [200, 200, 200]))   // Color.DARK_GRAY
                ctx.stroke(path, with: .color(color.opacity(c.id == selected ? 1 : 0.55)), lineWidth: c.id == selected ? 3 : 1.5)
            }
        }
    }
}

