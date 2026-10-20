// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct BuildingDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let stats: Stats
    let cost: Int
    let maintenance: Int
    let requiredTech: String?
    let requiredBuilding: String?
    let isWonder: Bool
    let isNationalWonder: Bool
    let uniqueTo: String?
    let replaces: String?
    let cityStrength: Double
    let cityHealth: Int
    let percentStatBonus: Stats
    let uniques: [String]
    let uniqueObjects: [Unique]
    let requiredResource: String?
    let greatPersonPoints: [String: Int]
    let specialistSlots: [String: Int]
    let hurryCostModifier: Int
    let requiredNearbyImprovedResources: [String]

    /// Unciv ICivilopediaText.civilopediaText: the flavour lines written for this object.
    var civilopediaText: [CivilopediaLine] = []
    /// Unciv Building.quote (shown by the WonderBuilt alert)
    var quote: String = ""
    private enum CodingKeys: String, CodingKey {
        case quote, name, cost, maintenance, requiredTech, requiredBuilding, isWonder, isNationalWonder, uniqueTo, replaces, cityStrength, cityHealth, percentStatBonus, uniques, requiredResource, greatPersonPoints, specialistSlots, hurryCostModifier, requiredNearbyImprovedResources, civilopediaText
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        civilopediaText = try c.decodeIfPresent([CivilopediaLine].self, forKey: .civilopediaText) ?? []
        quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
        name = try c.decode(String.self, forKey: .name)
        stats = try Stats(from: decoder)
        cost = try c.decodeIfPresent(Int.self, forKey: .cost) ?? -1
        maintenance = try c.decodeIfPresent(Int.self, forKey: .maintenance) ?? 0
        requiredTech = try c.decodeIfPresent(String.self, forKey: .requiredTech)
        requiredBuilding = try c.decodeIfPresent(String.self, forKey: .requiredBuilding)
        isWonder = try c.decodeIfPresent(Bool.self, forKey: .isWonder) ?? false
        isNationalWonder = try c.decodeIfPresent(Bool.self, forKey: .isNationalWonder) ?? false
        uniqueTo = try c.decodeIfPresent(String.self, forKey: .uniqueTo)
        replaces = try c.decodeIfPresent(String.self, forKey: .replaces)
        cityStrength = try c.decodeIfPresent(Double.self, forKey: .cityStrength) ?? 0
        cityHealth = try c.decodeIfPresent(Int.self, forKey: .cityHealth) ?? 0
        percentStatBonus = try c.decodeIfPresent(Stats.self, forKey: .percentStatBonus) ?? .zero
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        uniqueObjects = uniques.map(Unique.init)
        requiredResource = try c.decodeIfPresent(String.self, forKey: .requiredResource)
        greatPersonPoints = try c.decodeIfPresent([String: Int].self, forKey: .greatPersonPoints) ?? [:]
        specialistSlots = try c.decodeIfPresent([String: Int].self, forKey: .specialistSlots) ?? [:]
        hurryCostModifier = try c.decodeIfPresent(Int.self, forKey: .hurryCostModifier) ?? 0
        requiredNearbyImprovedResources = try c.decodeIfPresent([String].self, forKey: .requiredNearbyImprovedResources) ?? []
    }
    var isAnyWonder: Bool { isWonder || isNationalWonder }
    var cannotBeHurried: Bool { uniques.contains("Cannot be hurried") }
}

// MARK: - Unciv Building: matchesFilter / isStatRelated / requiredTechs

extension GameState {
    /// Unciv IHasUniques.requiredTechs: the legacy `requiredTech`, then every "after discovering [tech]" modifier of an
    /// "Only available" unique, then of a "Can only be built" unique (techsRequiredByUniques).
    func requiredTechs(requiredTech: String?, uniques: [Unique]) -> [String] {
        var out: [String] = requiredTech.map { [$0] } ?? []
        for pattern in ["Only available", "Can only be built"] {
            for u in uniques where u.pattern == pattern {
                for m in u.conditionals where m.pattern == "after discovering []" { out.append(m.param(0)) }
            }
        }
        return out
    }

    /// Unciv hasTagUnique(tag[, state]): a unique whose placeholder text is the tag - with a state its
    /// conditionals must hold, without one (`hasTagUnique(tag)`) they are not looked at.
    func hasTagUnique(_ uniques: [Unique], _ tag: String, _ ctx: UniqueContext?) -> Bool {
        uniques.contains { u in u.pattern == tag && (ctx.map { c in self.conditionalsHold(u, c) } ?? true) }
    }

    /// Unciv Technology.matchesFilter: all, its name, its era, then (only when a state with a game is known)
    /// the era's own filters (Era.matchesFilter with multiFilter = false), or a tag unique of the technology.
    func technologyMatchesFilter(_ tech: String, _ filter: String, _ ctx: UniqueContext?, multiFilter: Bool = true) -> Bool {
        guard let t = rs.techs[tech] else { return false }
        func single(_ f: String) -> Bool {
            if f == "All" || f == "all" || f == t.name || f == t.era { return true }
            if ctx != nil && eraMatchesFilter(t.era, f) { return true }
            return hasTagUnique(t.uniqueObjects, f, ctx)
        }
        return multiFilter ? MultiFilter.multiFilter(filter, single) : single(filter)
    }

    /// Unciv Building.matchesFilter (implements UniqueParameterType.BuildingFilter)
    func buildingMatchesFilter(_ b: BuildingDef, _ filter: String, _ ctx: UniqueContext? = nil) -> Bool {
        MultiFilter.multiFilter(filter) { f in
            self.buildingMatchesSingleFilter(b, f) || self.hasTagUnique(b.uniqueObjects, f, ctx)
        }
    }

    /// Unciv Building.matchesSingleFilter
    func buildingMatchesSingleFilter(_ b: BuildingDef, _ filter: String) -> Bool {
        switch filter {
        case "all", "All": return true
        case "Building", "Buildings": return !b.isAnyWonder
        case "Wonder", "Wonders": return b.isAnyWonder
        case "National Wonder", "National": return b.isNationalWonder
        case "World Wonder", "World": return b.isWonder
        default:
            if filter == b.name { return true }
            if filter == b.replaces { return true }
            // `ruleset.technologies[requiredTech]?.matchesFilter(filter, multiFilter = false)` - no state
            for tech in requiredTechs(requiredTech: b.requiredTech, uniques: b.uniqueObjects)
                where technologyMatchesFilter(tech, filter, nil, multiFilter: false) { return true }
            guard GameState.statNames.contains(filter) else { return false }
            return buildingIsStatRelated(b, filter)
        }
    }

    /// Unciv Building.isStatRelated(stat, city = null): the building's own stats, its unconditional "[stats]"
    /// uniques, its percentage bonuses, and its tile / population stat uniques (all read in GameContext.EmptyState).
    func buildingIsStatRelated(_ b: BuildingDef, _ stat: String) -> Bool {
        let empty = UniqueContext(civId: -1)
        func statUnique(_ pattern: String) -> Bool {
            b.uniqueObjects.contains { $0.pattern == pattern && conditionalsHold($0, empty) && ($0.stats?[stat] ?? 0) > 0 }
        }
        if b.stats[stat] > 0 { return true }
        if statUnique("[]") { return true }
        if b.percentStatBonus[stat] > 0 { return true }
        if statUnique("[] from [] tiles []") { return true }
        if statUnique("[] per [] population []") { return true }
        if stat == "Happiness" && b.uniqueObjects.contains(where: { $0.pattern == "Removes extra unhappiness from annexed cities" && conditionalsHold($0, empty) }) { return true }
        return false
    }
}
