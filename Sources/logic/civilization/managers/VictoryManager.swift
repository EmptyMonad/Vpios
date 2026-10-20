// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/managers/VictoryManager.kt`: the diplomatic vote and the victory it decides.
extension GameState {
    func unitedNationsExists() -> Bool { unBuildingAndOwner() != nil }

    /// Civs that take part in the vote: everyone alive except barbarians and spectators.
    func votingCivs() -> [Civilization] { civs.filter { $0.isAlive && !$0.isBarbarian && !$0.isSpectator && !isDefeated($0) } }

    /// Unciv getUNBuildingAndOwnerNames: the building with "Triggers voting for the Diplomatic Victory" and its living owner.
    func unBuildingAndOwner() -> (building: String, owner: Int)? {
        for civ in votingCivs() {
            for c in cities(of: civ.id) { if let b = c.buildings.first(where: { rs.buildings[$0]?.uniques.contains("Triggers voting for the Diplomatic Victory") == true }) { return (b, civ.id) } }
        }
        return nil
    }

    /// Unciv votesNeededForDiplomaticVictory: CvGame.cpp::DoUpdateDiploVictory integer math.
    func votesNeededForDiplomaticVictory() -> Int {
        let voteCount = votingCivs().count + (unBuildingAndOwner() != nil ? 1 : 0)
        if voteCount > 28 { return voteCount * 35 / 100 }
        return voteCount * (67 - Int(1.1 * Double(voteCount))) / 100 + 1
    }

    /// Unciv calculateDiplomaticVotingResults: the UN owner's vote counts double (G&K).
    func calculateDiplomaticVotingResults() -> [Int: Int] {
        var results: [Int: Int] = [:]
        let unOwner = unBuildingAndOwner()?.owner
        for (voter, votedFor) in diplomaticVictoryVotesCast where votedFor >= 0 { results[votedFor, default: 0] += voter == unOwner ? 2 : 1 }
        return results
    }

    func hasEnoughVotesForDiplomaticVictory(_ civId: Int) -> Bool {
        let results = calculateDiplomaticVotingResults()
        guard let best = results.max(by: { $0.value < $1.value }) else { return false }
        if best.key != civId { return false }
        if best.value < votesNeededForDiplomaticVictory() { return false }
        return !results.contains { $0.key != best.key && $0.value == best.value }
    }

    /// Unciv getDiplomaticVictoryVoteBreakdown: vote counts plus the "{...}" winner lines shown on the result screen.
    func diplomaticVictoryVoteBreakdown(viewer: Int) -> (results: [Int: Int], winnerText: String) {
        let results = calculateDiplomaticVotingResults()
        guard let topCount = results.values.max() else { return (results, L("No valid votes were cast.")) }
        let winners = results.filter { $0.value == topCount }.map { $0.key }.sorted()
        var lines: [String] = []
        let minVotes = votesNeededForDiplomaticVictory()
        if topCount < minVotes { lines.append(L("Minimum votes for electing a world leader: [\(minVotes)]")) }
        // Unciv: "Tied in first position: [${winnerList.joinToString { it.tr() }}]" - each name translated before joining
        if winners.count > 1 { lines.append(L("Tied in first position: [\(winners.map { L(civ($0)?.nation ?? "?") }.joined(separator: ", "))]")) }
        let winner = winners[0]
        if !lines.isEmpty { lines.append(L("No world leader was elected.")) }
        else if winner == viewer { lines.append(L("You have been elected world leader!")) }
        else {
            // Unciv "${winnerCiv.nation.getLeaderDisplayName()} has been elected world leader!": Nation.getLeaderDisplayName()
            // with no title - the name alone for a city-state or the spectator, else "[$leaderName] of [$name]"
            let w = civ(winner)
            let display: String
            if let w, !(w.isCityState || w.isSpectator) { display = "[\(w.leaderName)] of [\(w.nation)]" } else { display = w?.nation ?? "?" }
            lines.append(L("\(display) has been elected world leader!"))
        }
        return (results, lines.joined(separator: "\n"))
    }

    /// Unciv Civilization.getTurnsBetweenDiplomaticVotes
    func turnsBetweenDiplomaticVotes() -> Int { Int(15 * speed.modifier) }

    func turnsTillNextDiplomaticVote(_ civId: Int) -> Int? { civ(civId)?.civFlags["TurnsTillNextDiplomaticVote"] }

    /// Unciv Civilization.mayVoteForDiplomaticVictory
    func mayVoteForDiplomaticVictory(_ civId: Int) -> Bool {
        guard let c = civ(civId), !c.isSpectator, c.isAlive, turnsTillNextDiplomaticVote(civId) == 0, diplomaticVictoryVotesCast[civId] == nil else { return false }
        return civs.contains { $0.isMajor && $0.isAlive && $0.id != civId }
    }

    func diplomaticVoteForCiv(_ voter: Int, _ chosen: Int?) { diplomaticVictoryVotesCast[voter] = chosen ?? -1 }

    /// Unciv Civilization.shouldShowDiplomaticVotingResults
    func shouldShowDiplomaticVotingResults(_ civId: Int) -> Bool {
        civ(civId)?.civFlags["ShowDiplomaticVotingResults"] == 0 && civs.contains { $0.isMajor && $0.isAlive && $0.id != civId }
    }

    /// Unciv GameInfo.processDiplomaticVictory
    func processDiplomaticVictory() {
        guard !diplomaticVictoryVotesProcessed else { return }
        for i in civs.indices where hasEnoughVotesForDiplomaticVictory(civs[i].id) { civs[i].hasEverWonDiplomaticVote = true }
        diplomaticVictoryVotesProcessed = true
    }

    /// Unciv "Triggers voting for the Diplomatic Victory" (OneTimeTriggerVoting): every civ in gameInfo.civilizations
    /// but barbarians and spectators starts the countdown to the first vote - defeated civs too, since their
    /// startTurn still counts the flag down and runs handleDiplomaticVictoryFlags.
    func triggerDiplomaticVoting() {
        let between = turnsBetweenDiplomaticVotes()
        for i in civs.indices where !civs[i].isBarbarian && !civs[i].isSpectator { civs[i].civFlags["TurnsTillNextDiplomaticVote"] = between }
    }

    /// Unciv TurnManager.handleDiplomaticVictoryFlags, run for each civ after its flags counted down.
    func handleDiplomaticVictoryFlags(civIndex i: Int) {
        if civs[i].civFlags["ShouldResetDiplomaticVotes"] == 0 {
            diplomaticVictoryVotesCast.removeAll()   // Unciv: diplomaticVictoryVotesProcessed is never cleared again
            civs[i].civFlags["ShowDiplomaticVotingResults"] = nil; civs[i].civFlags["ShouldResetDiplomaticVotes"] = nil
        }
        if civs[i].civFlags["ShowDiplomaticVotingResults"] == 0 {
            processDiplomaticVictory()
            if civs.contains(where: { victoryTypeAchieved($0) != nil }) { civs[i].civFlags["TurnsTillNextDiplomaticVote"] = nil }   // Unciv victoryManager.hasWon()
            else { civs[i].civFlags["ShouldResetDiplomaticVotes"] = 1; civs[i].civFlags["TurnsTillNextDiplomaticVote"] = turnsBetweenDiplomaticVotes() }
        }
        if civs[i].civFlags["TurnsTillNextDiplomaticVote"] == 0 { civs[i].civFlags["ShowDiplomaticVotingResults"] = 1 }
    }

    // Unciv starts the vote countdown only from UniqueTriggerActivation.OneTimeTriggerVoting (the UN being built);
    // our once-per-round `diplomaticVotingTurn` that re-armed it whenever no civ held a vote flag - also after a
    // win had removed TurnsTillNextDiplomaticVote on purpose - was invented and is gone.
}
