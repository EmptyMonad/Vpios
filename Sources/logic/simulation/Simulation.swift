// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv Simulation: play many all-AI games headlessly and print who won, how, and after how many turns.
/// `--simulate <games> <maxTurns> [seed]` on the command line.
enum Simulation {
    struct Result { let winner: String?; let victoryType: String?; let turns: Int; let seconds: Double }

    static func run(games: Int, maxTurns: Int, seed: UInt64) {
        epochsAutoplay = true
        var results: [Result] = []
        let t0 = Date()
        for g in 0..<games {
            var settings = GameSettings()
            settings.seed = seed &+ UInt64(g)
            settings.players = (0..<6).map { _ in PlayerSetup(chosenCiv: "Random", isHuman: false) }
            let s: GameState
            do { s = try GameState.newGame(settings: settings) } catch { print("SIMULATION game \(g + 1)/\(games) seed=\(settings.seed) could not start: \(error)"); continue }
            let start = Date()
            var turns = 0
            while turns < maxTurns && s.outcome == nil { s.endTurn(); turns += 1 }
            var winner: String? = nil, type: String? = nil
            if let v = s.victoryData {   // Unciv Simulation reads gameInfo.victoryData
                winner = s.civ(v.winningCiv)?.nation
                type = v.victoryType
            }
            let r = Result(winner: winner, victoryType: type, turns: turns, seconds: Date().timeIntervalSince(start))
            results.append(r)
            print("SIMULATION game \(g + 1)/\(games) seed=\(settings.seed) turns=\(turns) winner=\(winner ?? "-") type=\(type ?? "-") \(Int(r.seconds))s")
        }
        // Unciv Simulation.getStats: per winner nation the win count, share, victory types and average winning turn.
        let byWinner = Dictionary(grouping: results.filter { $0.winner != nil }, by: { $0.winner! })
        print("SIMULATION summary: \(games) games, \(results.filter { $0.winner != nil }.count) decided, avg \(Int(results.map { $0.seconds }.reduce(0, +) / Double(max(1, games))))s/game, total \(Int(Date().timeIntervalSince(t0)))s")
        for (name, rs) in byWinner.sorted(by: { $0.value.count > $1.value.count }) {
            let types = Dictionary(grouping: rs, by: { $0.victoryType ?? "?" }).map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
            let avgTurn = rs.map { $0.turns }.reduce(0, +) / rs.count
            print("SIMULATION \(name): \(rs.count) wins (\(rs.count * 100 / games)%), avg turn \(avgTurn), \(types)")
        }
        let byType = Dictionary(grouping: results.filter { $0.victoryType != nil }, by: { $0.victoryType! })
        for (type, rs) in byType.sorted(by: { $0.value.count > $1.value.count }) { print("SIMULATION victory \(type): \(rs.count) (\(rs.count * 100 / games)%), avg turn \(rs.map { $0.turns }.reduce(0, +) / rs.count)") }
    }
}
