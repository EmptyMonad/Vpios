// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct PersonalityDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let production, food, gold, science, culture, happiness, faith, military, aggressive, declareWar, commerce, diplomacy, loyal, expansion, denounceWillingness: Double
    let priorities: [String: Double]
    /// Unciv Personality.preferredVictoryType (default Neutral)
    let preferredVictoryType: String
    let uniques: [String]
    /// Unciv RulesetObject.civilopediaText: the leader's biography on the personality's page.
    let civilopediaText: [CivilopediaLine]
    var uniqueObjects: [Unique] { uniques.map(Unique.init) }
    /// Unciv WillNotBuild: filters of things this personality never builds.
    var willNotBuild: [String] { uniqueObjects.filter { $0.pattern == "Will not build []" }.map { $0.param(0) } }
    private enum CodingKeys: String, CodingKey { case name, production, food, gold, science, culture, happiness, faith, military, aggressive, declareWar, commerce, diplomacy, loyal, expansion, denounceWillingness, priorities, uniques, preferredVictoryType, civilopediaText }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        func v(_ k: CodingKeys) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)) .flatMap { $0 } ?? 5 }
        production = v(.production); food = v(.food); gold = v(.gold); science = v(.science); culture = v(.culture); happiness = v(.happiness); faith = v(.faith)
        military = v(.military); aggressive = v(.aggressive); declareWar = v(.declareWar); commerce = v(.commerce); diplomacy = v(.diplomacy); loyal = v(.loyal); expansion = v(.expansion); denounceWillingness = v(.denounceWillingness)
        priorities = try c.decodeIfPresent([String: Double].self, forKey: .priorities) ?? [:]
        preferredVictoryType = (try? c.decodeIfPresent(String.self, forKey: .preferredVictoryType)).flatMap { $0 } ?? "Neutral"
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        civilopediaText = (try? c.decodeIfPresent([CivilopediaLine].self, forKey: .civilopediaText)) ?? []
    }
    /// Unciv NationDescriptions Personality.getShortDescription: the preferred victory type unless Neutral, then the
    /// description of every PersonalityValue at the highest value, in the enum's order, distinct
    var shortDescriptionParts: [String] {
        var parts: [String] = []
        if !preferredVictoryType.isEmpty && preferredVictoryType != "Neutral" { parts.append(preferredVictoryType) }
        let focuses: [(Double, String)] = [(production, "Productive"), (food, "Prolific"), (gold, "Greedy"), (science, "Scientific"), (culture, "Cultured"),
                                           (happiness, "Hedonistic"), (faith, "Religious"), (military, "Militaristic"), (aggressive, "Pushy"), (declareWar, "Warmonger"),
                                           (commerce, "Trader"), (diplomacy, "Negotiator"), (loyal, "Stalwart"), (expansion, "Expansionistic"), (denounceWillingness, "Denouncer")]
        let maxFocus = focuses.map(\.0).max()
        for (value, description) in focuses where value == maxFocus && !parts.contains(description) { parts.append(description) }
        return parts
    }
    /// Unciv scaledFocus: 0.5 ... 1.5 around the neutral value 5.
    static func scaled(_ v: Double) -> Double { 0.5 + v / 10 }
    static let neutral: PersonalityDef = {
        let json = #"{"name":"Neutral"}"#
        return try! JSONDecoder().decode(PersonalityDef.self, from: Data(json.utf8))
    }()
}
