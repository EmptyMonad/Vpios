// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/managers/GreatPersonManager.kt`.
extension GameState {
    /// Unciv GreatPersonManager.getPoolKey: the civ's equivalent unit's "Is part of Great Person group []", "" without one
    func greatPersonPoolKey(_ civId: Int, _ name: String) -> String {
        guard let base = rs.units[name] else { return "" }
        return equivalentUnit(civId, base).uniqueObjects.first { $0.pattern == "Is part of Great Person group []" }?.param(0) ?? ""
    }

    /// Unciv GreatPersonManager.getPointsRequiredForGreatPerson: the pool counter (100 initially) × game speed, truncated
    func greatPersonThreshold(_ civ: Civilization, for name: String) -> Double {
        if rs.units[name]?.uniqueObjects.contains(where: { $0.pattern == "Can be earned through combat" }) == true { return Double(civ.pointsForNextGreatGeneralCounter[name] ?? 200) }
        let base = civ.pointsForNextGreatPersonCounter[greatPersonPoolKey(civ.id, name)] ?? 100
        return Double(Int(Float(base == 0 ? 100 : base) * Float(speed.modifier)))   // Unciv: Int * Float speed.modifier, toInt()
    }

    /// Unciv GreatPersonPointsBreakdown.sum per city: specialist and building points, percentages summed (all-GP bonuses plus
    /// "[] is earned []% faster" for names with base points), fixed-point rounding half up, only real units
    /// Unciv City.getGreatPersonPointsBreakdown: one city's contribution. Passing `onlyCity` answers for that
    /// city alone, which is what the city screen shows - the empire-wide rate belongs to the progress bar.
    func greatPersonPointsPerTurn(_ civId: Int, onlyCity: Int? = nil) -> [String: Double] {
        var out: [String: Double] = [:]
        for city in cities(of: civId) where onlyCity == nil || city.id == onlyCity {
            var base: [String: Int] = [:]
            for (name, n) in city.specialists where n > 0 { for (gp, pts) in rs.specialists[name]?.greatPersonPoints ?? [:] { base[gp, default: 0] += pts * n } }
            for b in city.builtBuildingObjects { for (gp, pts) in rs.buildings[b]?.greatPersonPoints ?? [:] { base[gp, default: 0] += pts } }
            guard !base.isEmpty else { continue }
            let allGP = Int(civPercent(civId, pattern: "[]% Great Person generation []", city: city, filterParamIndex: 1, filterMatches: { self.cityMatchesFilter($0, city: city, viewer: civId) })) + Int(friendshipGreatPersonBoost(civId))
            let ctx = UniqueContext(civId: civId, city: city)
            for (gp, pts) in base {
                var bonus = allGP
                for u in civUniques(civId) where u.pattern == "[] is earned []% faster" && u.param(0) == gp && conditionalsHold(u, ctx) { bonus += u.int(1) }
                var fixed = pts * 1000
                fixed += fixed * bonus / 100
                let points = (fixed + 500) / 1000
                if points != 0, rs.units[gp] != nil { out[gp, default: 0] += Double(points) }
            }
        }
        return out
    }

    /// Unciv GreatPersonPointsBreakdown.Entry
    struct GPPEntry { let source: String; let link: String?; let isAllGP: Bool; let counter: [String: Int] }
    /// Unciv GreatPersonPointsBreakdown(city): the flat points by source ("Specialists", each building) and the percentage
    /// bonuses by source (the "[]% Great Person generation []" uniques and friendship boosts for every great person with
    /// base points, then "[] is earned []% faster" for its own)
    func greatPersonPointsBreakdown(_ city: City) -> (base: [GPPEntry], percent: [GPPEntry]) {
        var base: [GPPEntry] = []
        var spec: [String: Int] = [:]
        for (name, n) in city.specialists where n > 0 { for (gp, pts) in rs.specialists[name]?.greatPersonPoints ?? [:] { spec[gp, default: 0] += pts * n } }
        base.append(GPPEntry(source: "Specialists", link: nil, isAllGP: false, counter: spec))
        var allNames = Set(spec.keys)
        for b in city.builtBuildingObjects { if let g = rs.buildings[b]?.greatPersonPoints, !g.isEmpty { base.append(GPPEntry(source: b, link: "Building/\(b)", isAllGP: false, counter: g)); allNames.formUnion(g.keys) } }
        var percent: [GPPEntry] = []
        let ctx = UniqueContext(civId: city.civId, city: city)
        func link(_ u: Unique) -> String? { guard let n = u.sourceObjectName, let t = u.sourceObjectType else { return nil }; return "\(t.rawValue)/\(n)" }
        for u in cityUniques(city) where u.pattern == "[]% Great Person generation []" {
            guard scopeIncludes(u, city: city), conditionalsHold(u, ctx), cityMatchesFilter(u.param(1), city: city, viewer: city.civId) else { continue }
            percent.append(GPPEntry(source: u.sourceObjectName ?? "Bonus", link: link(u), isAllGP: true, counter: Dictionary(uniqueKeysWithValues: allNames.map { ($0, u.int(0)) })))
        }
        if let civ = civ(city.civId) {
            for (friend, _) in civ.friendships {
                guard let f = self.civ(friend), !isDefeated(f), !f.isSpectator else { continue }   // Unciv civ.getKnownCivs()
                for u in civUniques(city.civId) + civUniques(friend) where u.pattern == "When declaring friendship, both parties gain a []% boost to great person generation" {
                    percent.append(GPPEntry(source: "Declaration of Friendship", link: nil, isAllGP: true, counter: Dictionary(uniqueKeysWithValues: allNames.map { ($0, u.int(0)) })))
                }
            }
        }
        for u in civUniques(city.civId) where u.pattern == "[] is earned []% faster" && allNames.contains(u.param(0)) && conditionalsHold(u, ctx) {
            percent.append(GPPEntry(source: u.sourceObjectName ?? "Bonus", link: link(u), isAllGP: false, counter: [u.param(0): u.int(1)]))
        }
        return (base, percent)
    }

    /// The order Unciv's per-turn Counter first meets each great person in: city by city, the specialists
    /// (GreatPersonPointsBreakdown's "Specialists" entry, walking getNewSpecialists() - the specialistAllocations
    /// Counter, in the order each kind was first allocated), then the built buildings. The civ's
    /// greatPersonPointsCounter keeps first appearances, and when two great people cross the threshold together the
    /// earlier one is born (t_45 turn 113: Great Scientist, not Engineer).
    func greatPersonPointsOrder(_ civId: Int) -> [String] {
        var order: [String] = []
        func note(_ gp: String) { if !order.contains(gp) { order.append(gp) } }
        for city in cities(of: civId) {
            // Unciv: `if (ruleset.specialists.containsKey(specialistName))`
            for name in city.orderedSpecialistKeys where (city.specialists[name] ?? 0) > 0 && rs.specialists[name] != nil {
                for gp in (rs.specialists[name]?.greatPersonPoints ?? [:]).keys.sorted() { note(gp) }
            }
            for b in city.builtBuildingObjects { for gp in (rs.buildings[b]?.greatPersonPoints ?? [:]).keys.sorted() { note(gp) } }
        }
        return order
    }

    /// Unciv TurnManager: majors add great person points; then every eligible great person is born (combat ones first)
    /// Unciv TurnManager.endTurn: greatPeople.addGreatPersonPoints() — only the points, the person itself is born at the start of the next turn
    func accumulateGreatPeople(_ civId: Int) {
        guard let i = civIndex(civId) else { return }
        if civs[i].isMajor {
            let perTurn = greatPersonPointsPerTurn(civId)
            let order = greatPersonPointsOrder(civId).filter { perTurn[$0] != nil }
            for gp in order + perTurn.keys.filter({ !order.contains($0) }).sorted() {
                let pts = perTurn[gp]!
                if civs[i].greatPersonPoints[gp] == nil { civs[i].greatPersonOrder.append(gp) }   // remember when this source first appeared
                civs[i].greatPersonPoints[gp, default: 0] += pts
            }
        }
    }

    /// Unciv TurnManager.startTurn: greatPeople.getNewGreatPerson() → units.addUnit, so a great person appears in a city at the start of the turn
    func spawnGreatPeople(_ civId: Int) {
        guard let i = civIndex(civId) else { return }
        // Unciv TurnManager.startTurn: `if (civInfo.cities.isNotEmpty())` around the whole loop. Unciv never
        // chooses a banked free great person here: the AI's NextTurnAutomation.chooseGreatPerson runs only where
        // the free great person is granted (OneTimeFreeGreatPerson, the Maya long count). Ours re-tried the
        // choice at every turn start, a second chance Unciv's AI does not get.
        guard !cities(of: civId).isEmpty else { return }
        func nextGreatPerson() -> String? {
            for gp in civs[i].greatGeneralOrder + civs[i].greatGeneralPoints.keys.filter({ !civs[i].greatGeneralOrder.contains($0) }).sorted() {
                let value = civs[i].greatGeneralPoints[gp] ?? 0
                // Unciv getNewGreatPerson: `if (pointsForNextGreatGeneralCounter[unit] == 0) pointsForNextGreatGeneralCounter[unit] = 200`
                if (civs[i].pointsForNextGreatGeneralCounter[gp] ?? 0) == 0 { civs[i].pointsForNextGreatGeneralCounter[gp] = 200 }
                let required = civs[i].pointsForNextGreatGeneralCounter[gp] ?? 200
                if value >= required {
                    civs[i].greatGeneralPoints[gp] = value - required
                    if value == required { civs[i].greatGeneralPoints[gp] = nil; civs[i].greatGeneralOrder.removeAll { $0 == gp } }   // a Counter drops a zero
                    civs[i].pointsForNextGreatGeneralCounter[gp] = required + 50
                    return gp
                }
            }
            for gp in civs[i].greatPersonOrder + civs[i].greatPersonPoints.keys.filter({ !civs[i].greatPersonOrder.contains($0) }).sorted() {
                let value = civs[i].greatPersonPoints[gp] ?? 0
                // Unciv getPointsRequiredForGreatPerson writes the 100 it reads: `if (pointsForNextGreatPersonCounter[key] == 0)
                // pointsForNextGreatPersonCounter[key] = 100` - the pool's entry is in the counter (and the save) from the first
                // turn the civ has points, which the a state comparison showed (a test game, turn 6, Persia: Unciv Great Person:100, ours none)
                let poolKey = greatPersonPoolKey(civId, gp)
                if (civs[i].pointsForNextGreatPersonCounter[poolKey] ?? 0) == 0 { civs[i].pointsForNextGreatPersonCounter[poolKey] = 100 }
                let required = greatPersonThreshold(civs[i], for: gp)
                if value >= required {
                    civs[i].greatPersonPoints[gp] = value - required
                    if value == required { civs[i].greatPersonPoints[gp] = nil; civs[i].greatPersonOrder.removeAll { $0 == gp } }   // a Counter drops a zero
                    let key = greatPersonPoolKey(civId, gp)
                    civs[i].pointsForNextGreatPersonCounter[key] = (civs[i].pointsForNextGreatPersonCounter[key] ?? 100) * 2
                    return gp
                }
            }
            return nil
        }
        var guardCount = 0
        while guardCount < 20, let gp = nextGreatPerson() {   // the guard has to be tested before the points are spent
            guardCount += 1
            guard rs.units[gp] != nil else { continue }
            civs[i].greatPeopleSpawned += 1
            // Unciv TurnManager.startTurn: `civInfo.units.addUnit(greatPerson)` - UnitManager.addUnit without a city:
            // `civInfo.state.stateBasedRandom("UnitManager.addUnit")`, a WATER unit (the Great Admiral) to a random
            // naval city (not in resistance first), anything else to a random city not in resistance; the civ's own
            // version of the unit; the "has been born" notification. Ours picked among all cities for every unit and
            // put a Great Admiral inland (t_45 turn 151: Byzantium's Admiral on -4,-5 instead of the coast at -3,-8).
            guard let def = rs.units[gp] else { continue }
            if ProcessInfo.processInfo.environment["DUMP_GPCITY"] != nil {
                print("GPCITYE t=\(turn) \(civs[i].nation) cities=[\(cities(of: civId).map { $0.name }.joined(separator: ","))] unit=\(gp)")
            }
            guard unitManagerAddUnit(civId: civId, def, city: nil) != nil else { continue }
            civs[i].everEarnedUnits.insert(gp)
        }
    }

    // MARK: triggered uniques (policies adopted, wonders finished, ruins, great person actions)

    /// Unciv getTriggeredUniques: every unique of the civ (and of the unit, when given) carrying a trigger conditional that `matches`,
    /// activated with that conditional stripped. Used for "upon discovering [tech] technology", "upon entering the [era]", "upon gaining the [status] status" …
    /// Trigger chains such as "Free [Warrior] appears <upon gaining a [Warrior] unit>" are guarded against endless
    /// recursion by the game's own `triggerDepth` (GameInfo.swift).
}
