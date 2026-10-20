// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/managers/GoldenAgeManager.kt`.
extension GameState {
    /// Unciv GoldenAgeManager: (500 + 250 × golden ages) × (1 + cities/100) × speed.
    /// Unciv happinessRequiredForNextGoldenAge, in Float as there: `(500 + n * 250).toFloat()`, times
    /// `cities.size.toPercent()` (1 + size / 100f), times speed.modifier, then toInt().
    func goldenAgeThreshold(_ civ: Civilization) -> Double {
        var cost = Float(500 + civ.goldenAgesHad * 250)
        cost *= 1 + Float(cities(of: civ.id).count) / 100
        cost *= Float(speed.modifier)
        return Double(Int(cost))
    }

    /// Unciv GoldenAgeManager.endTurn(happiness), called by TurnManager.endTurn with `civInfo.getHappiness()`:
    /// outside a golden age the happiness (also negative) is stored, never below 0; in one the countdown runs
    /// and its end fires TriggerUpponEndingGoldenAge; otherwise enough stored happiness starts one - and only a
    /// golden age reached this way counts toward numberOfGoldenAges. Unciv does NOT update the cities when a
    /// golden age ends: the +20% stays in the stored stats until something else refreshes them.
    func goldenAgeEndTurn(civId: Int, happiness: Int) {
        guard let ci = civIndex(civId) else { return }
        if civs[ci].goldenAgeTurns <= 0 { civs[ci].goldenAgePoints = max(0, civs[ci].goldenAgePoints + Double(happiness)) }
        if civs[ci].goldenAgeTurns > 0 {
            civs[ci].goldenAgeTurns -= 1
            if civs[ci].goldenAgeTurns <= 0 { triggerConditionalUniques(civId: civId) { $0.pattern == "upon ending a Golden Age" } }
        } else if civs[ci].goldenAgePoints >= goldenAgeThreshold(civs[ci]) {
            civs[ci].goldenAgePoints -= goldenAgeThreshold(civs[ci])
            startGoldenAge(civId)
            if let cj = civIndex(civId) { civs[cj].goldenAgesHad += 1 }
        }
    }

    /// Unciv GoldenAgeManager.calculateGoldenAgeLength: each "[x]% Golden Age length" multiplies, × speed golden age length
    /// modifier, toInt - Float throughout (`unmodifiedNumberOfTurns.toFloat()`, `*= params[0].toPercent()`, `*= goldenAgeLengthModifier`)
    func calculateGoldenAgeLength(_ civId: Int, _ unmodifiedNumberOfTurns: Int) -> Int {
        var length = Float(unmodifiedNumberOfTurns)
        for u in civUniques(civId) where u.pattern == "[]% Golden Age length" && conditionalsHold(u, UniqueContext(civId: civId)) { length *= 1 + Float(u.double(0)) / 100 }
        let vpMono = vpMonopolyGoldenAgePercent(civId)   // VP: MonopolyGALength of global monopolies
        if vpMono != 0 { length *= 1 + Float(vpMono) / 100 }
        length *= Float(speed.goldenAgeLengthModifier)
        return Int(length)
    }

    func startGoldenAge(_ civId: Int, turns: Int? = nil) {
        guard let i = civIndex(civId) else { return }
        let length = calculateGoldenAgeLength(civId, turns ?? 10)
        civs[i].goldenAgeTurns += length
        notify(civId, "You have entered a Golden Age!", category: .General, icons: ["Happiness"], actions: [.civilopedia("Tutorial/Golden Age")])
        addAlert(civId, .GoldenAge)
        triggerConditionalUniques(civId: civId) { $0.pattern == "upon entering a Golden Age" }   // Unciv GoldenAgeManager.enterGoldenAge
        // Unciv GoldenAgeManager.enterGoldenAge ends in `for (city in civInfo.cities) city.cityStats.update()`
        // Unciv GoldenAgeManager.enterGoldenAge: `city.cityStats.update()`, default updateCivStats = true.
        // Unciv enterGoldenAge ends with the city loop and nothing after it: `update()` defaults to
        // updateCivStats = true, so the empire's stats are already rewritten once per city. The extra call
        // that stood here was ours, and a civ with no cities does not update at all there.
        for c in cities(of: civId) { updateCityStats(c.id, reason: "GoldenAgeManager:1512") }
    }

    // MARK: policies

    /// Unciv MapSize.getPredefinedOrNextSmaller
    var mapSizePreset: MapSizePreset {
        // Unciv reads mapParameters.mapSize: the preset's name, else the radius the size was made with
        if let size = map.uncivSize { return size.predefinedOrNextSmaller }
        if let p = MapSizePreset(rawValue: settings.mapSizeName) { return p }
        // a game saved before the map kept its size: the radius of the map's real tiles (not the padded grid)
        let radius = map.hexRadius ?? MapGenerator.equivalentRadius(tiles: map.realTileCount)
        for p in MapSizePreset.allCases.reversed() where radius >= p.radius { return p }
        return .Tiny
    }
}
