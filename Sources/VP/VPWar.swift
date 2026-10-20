// Vox Populi 4.22 war weariness for the Unciv 4X core (MPL-2.0).
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// CvPlayer::DoUpdateWarDamageAndWeariness / GetHighestWarWearinessPercent / GetUnhappinessFromWarWeariness, simplified:
// while at war with a major civ for 10+ turns, weariness against it grows by 1% of what the civ owns (its "war
// value": cities and military units) each turn; at peace it halves each turn. The highest weariness, as a percent
// of the war value (cut by policy modifiers, capped at 100), costs that percent of 34% of the empire's citizens
// in Unhappiness. Not ported: weariness from units and cities lost in battle, VP's per-unit power weighting.

import Foundation

extension GameState {
    private func vpWarKey(_ a: Int, _ b: Int) -> String { "\(a)-\(b)" }

    /// CvPlayer's war value: what the civ owns, in VP's units (a military unit ~100, a city by its size).
    func vpWarValue(_ civId: Int) -> Int {
        let cityValue = cities(of: civId).reduce(0) { $0 + 200 + 25 * $1.population }
        let unitValue = units(of: civId).filter { $0.isMilitary }.count * 100
        return cityValue + unitValue
    }

    /// Once a round (with the medians).
    func vpUpdateWarWeariness() {
        guard let vp = vpNeeds else { return }
        var ww = vpMedians.warWeariness ?? [:]
        let minTurns = Int(vp.define("WAR_MAJOR_MINIMUM_TURNS", 10))
        for me in civs where me.isAlive && me.isMajor {
            let value = vpWarValue(me.id)
            for other in civs where other.id != me.id && other.isMajor && me.metCivs.contains(other.id) {
                let k = vpWarKey(me.id, other.id)
                if !other.isAlive || !areAtWar(me.id, other.id) {
                    if let v = ww[k] { ww[k] = v / 2; if ww[k] == 0 { ww[k] = nil } }
                    continue
                }
                let turnsAtWar = turn - (me.warStartTurn[other.id] ?? turn)
                if turnsAtWar < minTurns { continue }
                ww[k, default: 0] += max(value / 100, 1)
            }
        }
        vpMedians.warWeariness = ww.isEmpty ? nil : ww
    }

    /// CvPlayer::GetHighestWarWearinessPercent
    func vpWarWearinessPercent(_ civId: Int) -> Int {
        guard let vp = vpNeeds, let me = civ(civId), me.isMajor, let ww = vpMedians.warWeariness else { return 0 }
        var highest = 0
        for other in civs where other.id != civId && other.isMajor {
            highest = max(highest, ww[vpWarKey(civId, other.id)] ?? 0)
        }
        guard highest > 0 else { return 0 }
        var pct = 100 * highest / max(vpWarValue(civId), 1)
        var mod = 0
        for p in me.policies { mod += Int(vp.policies[p]?.flags?["warWearinessMod"] ?? 0) }
        mod += Int(vp.nations[me.nation]?.flags?["warWearinessMod"] ?? 0)
        pct = pct * (100 - min(mod, 100)) / 100
        return min(pct, 100)
    }

    /// CvPlayer::GetUnhappinessFromWarWeariness
    func vpWarWearinessUnhappiness(_ civId: Int) -> Int {
        guard let vp = vpNeeds else { return 0 }
        let pop = cities(of: civId).reduce(0) { $0 + $1.population }
        return vpWarWearinessPercent(civId) * pop * Int(vp.define("WAR_WEARINESS_POPULATION_PERCENT_CAP", 34)) / 10000
    }
}
