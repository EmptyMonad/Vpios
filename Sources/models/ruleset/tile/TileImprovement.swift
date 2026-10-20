// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct ImprovementDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    /// Unciv TileImprovement.replaces: a unique improvement also answers to the improvement it replaces.
    let replaces: String?
    let terrainsCanBeBuiltOn: [String]
    let stats: Stats
    let turnsToBuild: Int
    let techRequired: String?
    let uniques: [String]
    let uniqueTo: String?
    /// Unciv TileImprovement.shortcutKey
    let shortcutKey: String?
    /// Unciv ICivilopediaText.civilopediaText: the hand-written rules text for this improvement.
    var civilopediaText: [CivilopediaLine] = []
    private enum CodingKeys: String, CodingKey { case name, replaces, terrainsCanBeBuiltOn, turnsToBuild, techRequired, uniques, uniqueTo, shortcutKey, civilopediaText }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        civilopediaText = try c.decodeIfPresent([CivilopediaLine].self, forKey: .civilopediaText) ?? []
        name = try c.decode(String.self, forKey: .name)
        uniqueTo = try c.decodeIfPresent(String.self, forKey: .uniqueTo)
        replaces = try c.decodeIfPresent(String.self, forKey: .replaces)
        terrainsCanBeBuiltOn = try c.decodeIfPresent([String].self, forKey: .terrainsCanBeBuiltOn) ?? []
        stats = try Stats(from: decoder)
        turnsToBuild = try c.decodeIfPresent(Int.self, forKey: .turnsToBuild) ?? -1
        techRequired = try c.decodeIfPresent(String.self, forKey: .techRequired)
        shortcutKey = try c.decodeIfPresent(String.self, forKey: .shortcutKey)
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        uniqueObjects = uniques.map(Unique.init)
    }
    /// Only ordinary worker improvements: buildable in a number of turns, with a real terrain list.
    var isWorkerBuildable: Bool { turnsToBuild > 0 && (!terrainsCanBeBuiltOn.isEmpty || name.hasPrefix("Remove ") || uniques.contains("Can only be built to improve a resource")) && !uniques.contains("Unbuildable") }   // Unciv ImprovementPickerScreen lists everything with turnsToBuild != -1, removals included
    /// Parsed once at load, as Unciv's IHasUniques does - canImprovementBeBuiltHere asks for these for every
    /// improvement on every tile a worker looks at.
    private(set) var uniqueObjects: [Unique] = []
    var isGreatImprovement: Bool { uniques.contains("Great Improvement") }
}

extension ImprovementDef {
    /// Unciv TileImprovement.isRoad: named after a RoadStatus other than None.
    var isRoad: Bool { name == "Road" || name == "Railroad" }
    /// Unciv IHasUniques.hasTagUnique: a unique whose placeholder text is the filter itself.
    func hasTagUnique(_ tag: String) -> Bool { uniqueObjects.contains { $0.pattern == tag } }

    /// Unciv TileImprovement.matchesSingleFilter (ImprovementFilter)
    func matchesSingleFilter(_ filter: String) -> Bool {
        switch filter {
        case "all", "All": return true
        case "Improvement": return true   // Unciv: "For situations involving tileFilter"
        case "All Road": return isRoad
        case "Great Improvement", "Great": return isGreatImprovement
        default: return filter == name || filter == replaces
        }
    }

    /// Unciv TileImprovement.matchesFilter: a multi-filter over matchesSingleFilter or a tag unique.
    func matchesFilter(_ filter: String, multiFilter: Bool = true) -> Bool {
        if !multiFilter { return matchesSingleFilter(filter) || hasTagUnique(filter) }
        return MultiFilter.multiFilter(filter) { matchesSingleFilter($0) || hasTagUnique($0) }
    }

    /// Unciv TileImprovement.canBeBuiltOn(terrain: String): the raw list.
    func canBeBuiltOn(_ terrain: String) -> Bool { terrainsCanBeBuiltOn.contains(terrain) }
    /// Unciv TileImprovement.canBeBuiltOn(terrain: Terrain): any listed entry matches the terrain as a filter.
    func canBeBuiltOn(_ terrain: Terrain) -> Bool { terrainsCanBeBuiltOn.contains { terrain.matchesFilter($0) } }

    /// Unciv TileImprovement.isAllowedOnFeature: listed for the terrain, or a "Does not need removal of []" naming it.
    func isAllowedOnFeature(_ terrain: Terrain) -> Bool {
        canBeBuiltOn(terrain) || uniqueObjects.contains { $0.pattern == "Does not need removal of []" && terrain.matchesFilter($0.param(0)) }
    }
}
