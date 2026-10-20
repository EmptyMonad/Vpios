// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct SpeedDef: Decodable, Identifiable {
    var id: String { name }
    struct YearStep: Decodable {
        let yearsPerTurn: Double; let untilTurn: Int
        /// Unciv Speed.turns is `ArrayList<HashMap<String, Float>>`: both numbers are read as Float.
        private enum CodingKeys: String, CodingKey { case yearsPerTurn, untilTurn }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            yearsPerTurn = Stats.f32(try c.decode(Double.self, forKey: .yearsPerTurn))
            untilTurn = Int(Float(try c.decode(Double.self, forKey: .untilTurn)))
        }
    }
    let name: String
    let modifier: Double
    let productionCostModifier: Double
    let goldCostModifier: Double
    let scienceCostModifier: Double
    let cultureCostModifier: Double
    let improvementBuildLengthModifier: Double
    let barbarianModifier: Double
    let goldenAgeLengthModifier: Double
    let faithCostModifier: Double
    let goldGiftModifier: Double
    let cityStateTributeScalingInterval: Double
    let religiousPressureAdjacentCity: Double
    let dealDuration: Int
    let peaceDealDuration: Int
    let startYear: Double
    let turns: [YearStep]
    private enum CodingKeys: String, CodingKey { case name, modifier, productionCostModifier, goldCostModifier, scienceCostModifier, cultureCostModifier, improvementBuildLengthModifier, barbarianModifier, goldenAgeLengthModifier, startYear, turns, faithCostModifier, goldGiftModifier, cityStateTributeScalingInterval, religiousPressureAdjacentCity, dealDuration, peaceDealDuration }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        modifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .modifier) ?? 1)
        productionCostModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .productionCostModifier) ?? 1)   // Unciv Speed: a sub-modifier defaults to one, not to the overall modifier
        goldCostModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .goldCostModifier) ?? 1)   // Unciv Speed: a sub-modifier defaults to one, not to the overall modifier
        scienceCostModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .scienceCostModifier) ?? 1)   // Unciv Speed: a sub-modifier defaults to one, not to the overall modifier
        cultureCostModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .cultureCostModifier) ?? 1)   // Unciv Speed: a sub-modifier defaults to one, not to the overall modifier
        improvementBuildLengthModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .improvementBuildLengthModifier) ?? 1)   // Unciv Speed: a sub-modifier defaults to one, not to the overall modifier
        barbarianModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .barbarianModifier) ?? 1)   // Unciv Speed: a sub-modifier defaults to one, not to the overall modifier
        goldenAgeLengthModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .goldenAgeLengthModifier) ?? 1)   // Unciv Speed: a sub-modifier defaults to one, not to the overall modifier
        faithCostModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .faithCostModifier) ?? 1)   // Unciv Speed: a sub-modifier defaults to one, not to the overall modifier
        goldGiftModifier = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .goldGiftModifier) ?? 1)
        cityStateTributeScalingInterval = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .cityStateTributeScalingInterval) ?? 6.5)
        religiousPressureAdjacentCity = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .religiousPressureAdjacentCity) ?? 6)
        dealDuration = try c.decodeIfPresent(Int.self, forKey: .dealDuration) ?? 30
        peaceDealDuration = try c.decodeIfPresent(Int.self, forKey: .peaceDealDuration) ?? 10
        startYear = Stats.f32(try c.decodeIfPresent(Double.self, forKey: .startYear) ?? -4000)
        turns = try c.decodeIfPresent([YearStep].self, forKey: .turns) ?? []
    }
    /// Calendar year for a given turn number (1-based).
    /// Epochs counts turns from 1, Unciv's turn counter from 0; Kotlin Float.toInt truncates toward zero.
    func year(forTurn turn: Int) -> Int { Int(uncivTurnToYear(turn - 1)) }
    /// Unciv Speed.turnToYear: linear within each yearsPerTurn interval, the last interval extends forever.
    func uncivTurnToYear(_ turn: Int) -> Double {
        // Unciv accumulates the year in Float
        var year = Float(startYear)
        var intervalStartTurn = 0
        let lastIntervalEndTurn = lastTurn
        for step in turns {
            if intervalStartTurn >= turn { break }
            if turn <= step.untilTurn || step.untilTurn == lastIntervalEndTurn {
                year += Float(turn - intervalStartTurn) * Float(step.yearsPerTurn)
                break
            }
            year += Float(step.untilTurn - intervalStartTurn) * Float(step.yearsPerTurn)
            intervalStartTurn = step.untilTurn
        }
        return Double(year)
    }
    var lastTurn: Int { turns.last?.untilTurn ?? 500 }
}
