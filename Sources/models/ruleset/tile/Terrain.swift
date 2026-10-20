// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct Terrain: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let type: TerrainType
    let stats: Stats
    let movementCost: Int
    let defenceBonus: Double
    let rgb: [Int]
    let overrideStats: Bool
    let unbuildable: Bool
    let impassable: Bool
    let occursOn: [String]
    let uniques: [String]
    let uniqueObjects: [Unique]
    let turnsInto: String?
    let weight: Int

    /// Unciv Terrain.isFreshwater / isCoast / isOcean / isIce — a ruleset that renames its water keeps working
    var isFreshwater: Bool { uniques.contains("Fresh water") }
    var isCoast: Bool { type == .water && !isFreshwater && (uniques.contains("Coastal Water") || name == "Coast") }
    var isOcean: Bool { type == .water && !isFreshwater && !isCoast }
    var isIce: Bool { type == .terrainFeature && impassable && occursOn.contains("Ocean") }

    /// Unciv ICivilopediaText.civilopediaText: the hand-written rules text for this terrain.
    var civilopediaText: [CivilopediaLine] = []

    private enum CodingKeys: String, CodingKey {
        case name, type, movementCost, defenceBonus, RGB, overrideStats, unbuildable, impassable, occursOn, uniques, turnsInto, weight, civilopediaText
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        civilopediaText = try c.decodeIfPresent([CivilopediaLine].self, forKey: .civilopediaText) ?? []
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(TerrainType.self, forKey: .type)
        stats = try Stats(from: decoder)
        movementCost = try c.decodeIfPresent(Int.self, forKey: .movementCost) ?? 1
        defenceBonus = try c.decodeIfPresent(Double.self, forKey: .defenceBonus) ?? 0
        rgb = try c.decodeIfPresent([Int].self, forKey: .RGB) ?? [128, 128, 128]
        overrideStats = try c.decodeIfPresent(Bool.self, forKey: .overrideStats) ?? false
        unbuildable = try c.decodeIfPresent(Bool.self, forKey: .unbuildable) ?? false
        occursOn = try c.decodeIfPresent([String].self, forKey: .occursOn) ?? []
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        let imp = try c.decodeIfPresent(Bool.self, forKey: .impassable) ?? false
        impassable = imp || uniques.contains("Impassable")
        uniqueObjects = uniques.map(Unique.init)
        turnsInto = try c.decodeIfPresent(String.self, forKey: .turnsInto)
        weight = try c.decodeIfPresent(Int.self, forKey: .weight) ?? 10
    }
    var isNaturalWonder: Bool { type == .naturalWonder }
    var isRough: Bool { uniques.contains("Rough terrain") }
}

extension Terrain {
    /// Unciv IHasUniques.hasTagUnique: a unique whose placeholder text is the filter itself ("Vegetation", "Fresh water").
    func hasTagUnique(_ tag: String) -> Bool { uniqueObjects.contains { $0.pattern == tag } }

    /// Unciv Terrain.matchesSingleFilter (TerrainFilter): the keywords, the name, the type's name.
    func matchesSingleFilter(_ filter: String) -> Bool {
        switch filter {
        case "all", "All", "Terrain": return true
        case "Impassable": return impassable
        case "Open terrain": return !isRough
        case "Rough terrain": return isRough
        case "Natural Wonder": return type == .naturalWonder
        case "Terrain Feature": return type == .terrainFeature
        default: return filter == name || filter == type.rawValue
        }
    }

    /// Unciv Terrain.matchesFilter: a multi-filter over matchesSingleFilter or a tag unique.
    func matchesFilter(_ filter: String, multiFilter: Bool = true) -> Bool {
        if !multiFilter { return matchesSingleFilter(filter) || hasTagUnique(filter) }
        return MultiFilter.multiFilter(filter) { matchesSingleFilter($0) || hasTagUnique($0) }
    }
}
