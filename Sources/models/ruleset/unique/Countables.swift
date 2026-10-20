// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv Countables + Expressions: the numbers a `when number of [x] is …` conditional can compare.
extension GameState {
    func countable(_ raw: String, _ ctx: UniqueContext) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(text) { return n }
        if let v = simpleCountable(text, ctx) { return v }
        return CountableExpression.eval(text) { self.simpleCountable($0, ctx) ?? Int($0) }
    }

    func civMatches(_ c: Civilization, _ filter: String, viewer: Int) -> Bool {
        switch filter.trimmingCharacters(in: .whitespaces) {
        case "All", "all": return true
        case "Major", "Major Civilizations": return c.isMajor
        case "City-State", "City-States", "City-state": return c.isCityState
        case "Human", "Humans", "Human player": return c.isPlayer
        case "AI", "AI player": return !c.isPlayer
        case "Open Borders": return hasOpenBorders(viewer, in: c.id)   // Unciv Civilization.matchesSingleFilter
        case "Barbarians", "Barbarian": return c.isBarbarian
        case "Known", "known": return c.id == viewer || (civ(viewer)?.metCivs.contains(c.id) ?? false)
        case "Friendly": return c.id == viewer || relationshipLevel(viewer, c.id) >= .friend
        case "Enemy", "at war", "Hostile": return areAtWar(viewer, c.id)
        default: return c.nation == filter || c.nationDef?.cityStateType == filter
        }
    }
    /// Unciv Building.matchesFilter (models/ruleset/Building.swift)
    func buildingMatches(_ name: String, _ filter: String) -> Bool {
        guard let b = rs.buildings[name] else { return false }
        return buildingMatchesFilter(b, filter)
    }
    /// Unciv Policy.matchesFilter: MultiFilter over all / its name / "[branch] branch" (a branch is its own branch),
    /// or a tag unique of the policy. Filtering by a branch's name matches only the branch itself.
    func policyMatches(_ name: String, _ filter: String) -> Bool {
        let branchName = rs.policyBranches.contains(where: { $0.name == name }) ? name : rs.policyBranchOf[name]
        let uniques = rs.policyBranches.first(where: { $0.name == name })?.uniqueObjects ?? rs.policies[name]?.uniqueObjects ?? []
        return MultiFilter.multiFilter(filter) { f in
            if f == "All" || f == "all" || f == name { return true }
            if let branchName, f == "[\(branchName)] branch" { return true }
            return self.hasTagUnique(uniques, f, nil)
        }
    }
    func techMatches(_ name: String, _ filter: String) -> Bool {
        if filter == "All" || filter == "all" || filter == name { return true }
        return rs.techs[name]?.era == filter
    }
    private func statValue(_ st: Stats, _ stat: String) -> Double? {
        switch stat {
        case "Food": return st.food
        case "Production": return st.production
        case "Gold": return st.gold
        case "Science": return st.science
        case "Culture": return st.culture
        case "Faith": return st.faith
        case "Happiness": return st.happiness
        default: return nil
        }
    }

    private func simpleCountable(_ text: String, _ ctx: UniqueContext) -> Int? {
        guard let civ = civ(ctx.civId) else { return nil }
        let probe = Unique(text)
        switch text {
        case "turns": return uncivTurns                     // Unciv gameInfo.turns: counted from zero
        case "year": return year
        case "Cities": return cities(of: civ.id).count
        case "Units": return units(of: civ.id).count
        case "Completed Policy branches": return civ.completedBranches
        case "Era number": return rs.eras.firstIndex { $0.name == civ.eraName } ?? 0
        case "City-States": return civs.filter { $0.isAlive && $0.isCityState }.count
        default: break
        }
        if GameState.statNames.contains(text) {
            // Unciv Countables.Stats: the stat *reserve* - `city?.getStatReserve(stat) ?: civInfo?.getStatReserve(stat)`.
            return statReserve(text, city: ctx.city, civId: civ.id)
        }
        // Unciv Countables.TileResources: `city?.getAvailableResourceAmount(resource) ?: civInfo?.getResourceAmount(resource)`
        if rs.resources[text] != nil { return ctx.city.map { availableResourceAmount($0, text) } ?? (resourceCounts(civ.id)[text] ?? 0) }
        switch probe.pattern {
        case "[] Per Turn":
            let p = probe.param(0)
            if GameState.statNames.contains(p) {
                if let city = ctx.city, p == "Food" || p == "Production" { return Int(statValue(currentCityStats(city.id).total, p) ?? 0) }
                if p == "Happiness" { return happiness(of: civ.id) }
                return Int(cities(of: civ.id).reduce(0.0) { $0 + (statValue(currentCityStats($1.id).total, p) ?? 0) })
            }
            // Unciv: the city's generated resources, else the civ's supply (per turn - never the stockpile)
            if rs.resources[p] != nil { return ctx.city.map { resourcesGeneratedByCity($0)[p] ?? 0 } ?? ((rs.resources[p]?.isStockpiled == true ? civResourceSupply(civ.id) : resourceCounts(civ.id))[p] ?? 0) }
            return nil
        case "[] Cities": return cities(of: civ.id).filter { cityMatchesFilter(probe.param(0), city: $0, viewer: civ.id) }.count
        case "[] Units": return units(of: civ.id).filter { unitMatches($0, probe.param(0)) }.count
        case "Carried [] units":
            guard let u = ctx.unit else { return nil }
            return units(at: u.coord).filter { $0.id != u.id && $0.civId == u.civId && $0.def.isAir && unitMatches($0, probe.param(0)) }.count
        case "[] Buildings": return cities(of: civ.id).reduce(0) { $0 + $1.buildings.filter { buildingMatches($0, probe.param(0)) }.count }
        case "[] Buildings by [] Civilizations":
            return civs.filter { $0.isAlive && civMatches($0, probe.param(1), viewer: civ.id) }.reduce(0) { acc, c in acc + cities(of: c.id).reduce(0) { $0 + $1.buildings.filter { buildingMatches($0, probe.param(0)) }.count } }
        case "[] in [] Cities":
            let popFilter = probe.param(0)
            let list = probe.param(1) == "in this city" && ctx.city != nil ? [ctx.city!] : cities(of: civ.id).filter { cityMatchesFilter(probe.param(1), city: $0, viewer: civ.id) }
            return list.reduce(0) { acc, city in
                switch popFilter {
                case "Population": return acc + city.population
                case "Specialists": return acc + city.specialists.values.reduce(0, +)
                case "Followers of the Majority Religion", "Followers of this Religion": return acc + (majorityReligion(of: city).map { followers(of: city)[$0] ?? 0 } ?? 0)
                case "Unemployed": return acc + max(0, freePopulation(city))
                default: return acc + (city.specialists[popFilter] ?? 0)
                }
            }
        case "[] Cities of [] Civilizations":
            return civs.filter { $0.isAlive && civMatches($0, probe.param(1), viewer: civ.id) }.reduce(0) { $0 + cities(of: $1.id).filter { cityMatchesFilter(probe.param(0), city: $0, viewer: civ.id) }.count }
        case "Adopted [] Policies": return civ.policies.filter { policyMatches($0, probe.param(0)) }.count
        case "Adopted [] Policies by [] Civilizations":
            return civs.filter { $0.isAlive && civMatches($0, probe.param(1), viewer: civ.id) }.reduce(0) { $0 + $1.policies.filter { policyMatches($0, probe.param(0)) }.count }
        case "Researched [] Technologies": return civ.techs.filter { techMatches($0, probe.param(0)) }.count
        case "Known [] Civilizations":   // Unciv KnownCivs: alive civs the civ has met, never itself
            return knownCivs(civ.id).filter { civMatches($0, probe.param(0), viewer: civ.id) }.count
        case "Remaining [] Civilizations": return civs.filter { $0.isAlive && civMatches($0, probe.param(0), viewer: civ.id) }.count   // Unciv RemainingCivs: barbarlar da suzgecten gecerse sayilir
        case "Worked [] Tiles in this city":
            guard let city = ctx.city else { return nil }
            return city.workedTiles.filter { c in map[c].map { tileMatches($0, probe.param(0), civId: civ.id) } ?? false }.count
        case "Worked [] Tiles": return cities(of: civ.id).reduce(0) { $0 + $1.workedTiles.filter { c in map[c].map { tileMatches($0, probe.param(0), civId: civ.id) } ?? false }.count }
        case "Owned [] Tiles": return cities(of: civ.id).reduce(0) { $0 + $1.tiles.filter { c in map[c].map { tileMatches($0, probe.param(0), civId: civ.id) } ?? false }.count }
        case "[] Tiles": return map.tiles.filter { tileMatches($0, probe.param(0), civId: civ.id) }.count
        case "[] resource of [] Civilizations":
            let relevant = civs.filter { $0.isAlive && civMatches($0, probe.param(1), viewer: civ.id) }
            let resources = rs.resources.values.filter { probe.param(0) == "All" || probe.param(0) == "all" || $0.name == probe.param(0) || $0.resourceType == probe.param(0) }
            return resources.reduce(0) { acc, r in acc + relevant.reduce(0) { $0 + (resourceCounts($1.id)[r.name] ?? 0) } }
        case "Speed modifier for []":
            let sp = speed
            switch probe.param(0) {
            case "Gold": return Int(sp.goldCostModifier * 100)
            case "Production": return Int(sp.productionCostModifier * 100)
            case "Science": return Int(sp.scienceCostModifier * 100)
            case "Culture": return Int(sp.cultureCostModifier * 100)
            case "Faith": return Int(sp.faithCostModifier * 100)
            case "Food", "Happiness": return Int(sp.modifier * 100)
            default: return nil
            }
        default: return nil
        }
    }
}
