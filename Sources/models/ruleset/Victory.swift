// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Victory conditions and scoring.
extension GameState {
    /// Unciv Civilization.calculateTotalScore
    func score(_ civ: Civilization) -> Int { Int(totalScore(civ)) }

    func victoryStatus() -> [(civ: Civilization, score: Int, spaceship: Int, branches: Int, capitals: Int)] {
        civs.filter { $0.isMajor }.map { c in
            let caps = cities.filter { $0.civId == c.id && $0.isCapital }.count
            return (c, score(c), spaceshipProgress(c).have, c.completedBranches, caps)
        }.sorted { $0.score > $1.score }
    }

    /// Unciv TurnManager.updateWinningCiv + VictoryScreen.displayWinner: record VictoryData, tell the other humans
    /// (AlertType.GameHasBeenWon) and show "You have won a [type] Victory!" / "[civ] has won a [type] Victory!" with the victory's texts.
    /// The record is made whatever the screen does; the screen (our outcome) only outside One more turn, where WorldScreen.update
    /// no longer opens it - over a defeat screen not yet left too, as VictoryScreen shows the winner before `isDefeated()`.
    func declareVictory(_ civId: Int, type: String) {
        guard let w = civ(civId) else { return }
        victoryData = VictoryRecord(winningCiv: civId, victoryType: type, victoryTurn: uncivTurns)   // Unciv VictoryData(civ, type, gameInfo.turns)
        for h in humans where h.id != civId { addAlert(h.id, .GameHasBeenWon) }
        guard !oneMoreTurnMode else { return }
        let def = rs.victory(type)
        if w.isPlayer {
            outcome = .victory(L("You have won a [\(type)] Victory!") + "\n" + L(def?.victoryString ?? VictoryDef.defaultVictoryString))
        } else {
            outcome = .defeat(L("[\(w.nation)] has won a [\(type)] Victory!") + "\n" + L(def?.defeatString ?? VictoryDef.defaultDefeatString))
        }
    }

    /// Unciv Civilization.isDefeated: a civ that ever owned its original capital is out once it has no cities, any other civ once it has no units
    func isDefeated(_ c: Civilization) -> Bool {
        if c.isBarbarian || c.isSpectator { return false }
        // Unciv Civilization.isDefeated: a civ that ever held its original capital falls with its last city; one that
        // never did (still wandering with its settler) falls with its last unit - whatever cities it may hold.
        if c.hasEverOwnedOriginalCapital { return cities(of: c.id).isEmpty }
        return units(of: c.id).isEmpty
    }
    /// Unciv VictoryManager.getVictoryTypeAchieved: the first enabled ruleset victory whose milestones are all completed
    func victoryTypeAchieved(_ c: Civilization) -> String? {
        guard c.isMajor else { return nil }
        for v in rs.victories where v.name != "Neutral" && settings.victoryTypes.contains(v.name) {
            if v.milestones.allSatisfy({ milestoneCompleted($0, by: c) }) { return v.name }
        }
        if civUniques(c.id).contains(where: { $0.pattern == "Triggers victory" }) { return "Neutral" }
        return nil
    }

    /// Unciv WorldScreen.update on the player's turn, no popup open and no AutoPlay going on, after every action and every
    /// popup closed: `!gameInfo.oneMoreTurnMode && (viewingCiv.isDefeated() || gameInfo.checkForVictory()) -> VictoryScreen`
    /// (WorldScreen.kt:450) - GameInfo.checkForVictory runs updateWinningCiv for every civ (GameInfo.kt:550-557), so a victory
    /// the human's own action completes (the last capital taken, a spaceship part, a project bought) is recorded at once, the
    /// other humans' GameHasBeenWon with it, not at the human's endTurn. In One more turn, or for a defeated viewer, the `&&` /
    /// `||` short-circuit: nothing is recorded. True when that condition holds - the game has ended for the viewer, which
    /// also stops a multi-turn AutoPlay (the same condition's first use in WorldScreen.update, WorldScreen.kt:441-443).
    @discardableResult
    func worldScreenVictoryCheck() -> Bool {
        guard !oneMoreTurnMode else { return false }
        if let p = civ(playerId), isDefeated(p) { return true }
        if victoryData != nil { return true }   // GameInfo.checkForVictory's own first line
        checkVictory()
        return victoryData != nil
    }

    /// `winningCivOnly`: Unciv TurnManager.updateWinningCiv, which a civ's startTurn and endTurn run for THAT civ
    /// alone - a victory another civ completes during this civ's turn is declared at that civ's own next turn
    /// boundary. Without it, every alive major is examined in civ order (GameInfo.checkForVictory).
    func checkVictory(winningCivOnly: Int? = nil) {
        // Unciv destroys a civ only from the battle paths; a defeat found here is only read as one - after a victory too,
        // since the round goes on to the human (Unciv's isAlive() is live)
        refreshDefeatedFlags()
        // Unciv TurnManager.updateWinningCiv, civilization by civilization: `if (victoryData != null) return` is its only
        // guard, so a victory is recorded in One more turn and after the human's defeat too (the GameHasBeenWon alert with it)
        if victoryData == nil {
            for c in civs where c.isAlive && c.isMajor && (winningCivOnly == nil || c.id == winningCivOnly) {
                if let type = victoryTypeAchieved(c) { declareVictory(c.id, type: type); break }
            }
        }
        // WorldScreen.update: `!gameInfo.oneMoreTurnMode && (viewingCiv.isDefeated() || ...)` opens the VictoryScreen
        guard outcome == nil, !oneMoreTurnMode else { return }
        let humansLeft = humans.filter { $0.isAlive }
        if humansLeft.isEmpty && !humans.contains(where: { $0.isSpectator }) {
            revealMapWhenDefeated(playerId)
            outcome = .defeat(L(VictoryDef.defaultDefeatString))   // Unciv VictoryScreen: playerCiv.isDefeated()
        }
    }
}

/// Unciv VictoryData(winningCiv, victoryType, victoryTurn)
struct VictoryRecord: Codable, Equatable {
    var winningCiv: Int
    var victoryType: String
    var victoryTurn: Int
}

struct VictoryDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let victoryScreenHeader: String
    let milestones: [String]
    let requiredSpaceshipParts: [String]
    let victoryString: String
    let defeatString: String
    /// Unciv Victory defaults (also used when a victory type is missing from the ruleset)
    static let defaultVictoryString = "Your civilization stands above all others! The exploits of your people shall be remembered until the end of civilization itself!"
    static let defaultDefeatString = "You have been defeated. Your civilization has been overwhelmed by its many foes. But your people do not despair, for they know that one day you shall return - and lead them forward to victory!"
    /// Unciv Victory.hiddenInVictoryScreen (vanilla: Time); GameInfo.getEnabledVictories drops these.
    let hiddenInVictoryScreen: Bool
    private enum CodingKeys: String, CodingKey { case name, victoryScreenHeader, milestones, requiredSpaceshipParts, victoryString, defeatString, hiddenInVictoryScreen }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        victoryScreenHeader = try c.decodeIfPresent(String.self, forKey: .victoryScreenHeader) ?? "Do things to win!"   // Unciv Victory default
        milestones = try c.decodeIfPresent([String].self, forKey: .milestones) ?? []
        requiredSpaceshipParts = try c.decodeIfPresent([String].self, forKey: .requiredSpaceshipParts) ?? []
        victoryString = try c.decodeIfPresent(String.self, forKey: .victoryString) ?? VictoryDef.defaultVictoryString
        defeatString = try c.decodeIfPresent(String.self, forKey: .defeatString) ?? VictoryDef.defaultDefeatString
        hiddenInVictoryScreen = try c.decodeIfPresent(Bool.self, forKey: .hiddenInVictoryScreen) ?? false
    }
}

enum GameOutcome: Codable, Equatable {
    case victory(String)
    case defeat(String)
}
