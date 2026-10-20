// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv TemporaryUnique: a triggered unique with a `<for [n] turns>` modifier lives on the civilization for n turns.
struct TemporaryUnique: Codable, Hashable {
    var unique: String
    var turnsLeft: Int
    var sourceObjectName: String? = nil
    /// Unciv TemporaryUnique.sourceObjectType (a UniqueTarget name): the kind of object that granted it - the
    /// first-to-research / first-to-adopt conditionals ask for it.
    var sourceObjectType: String? = nil
    var uniqueObject: Unique {
        var u = Unique(unique)
        u.sourceObjectName = sourceObjectName   // Unciv: the stored unique remembers what granted it
        u.sourceObjectType = sourceObjectType.flatMap(UniqueTarget.init(rawValue:))
        return u
    }
}

extension Unique {
    /// The `<for [n] turns>` modifier (Unciv ConditionalTimedUnique), if any.
    var timedTurns: Int? { conditionals.first { $0.pattern == "for [] turns" }?.int(0) }
    /// The unique text without its `<for [n] turns>` modifier.
    var textWithoutTiming: String {
        guard let r = text.range(of: #"\s*<for \[\d+\] turns>"#, options: .regularExpression) else { return text }
        return text.replacingCharacters(in: r, with: "").trimmingCharacters(in: .whitespaces)
    }
}

extension GameState {
    /// UniqueTriggerActivation: a timed trigger is stored instead of applied.
    func addTemporaryUnique(_ u: Unique, turns: Int, civId: Int, source: String? = nil, sourceType: UniqueTarget? = nil) {
        guard let ci = civIndex(civId) else { return }
        civs[ci].temporaryUniques.append(TemporaryUnique(unique: u.textWithoutTiming, turnsLeft: turns, sourceObjectName: source, sourceObjectType: sourceType?.rawValue))
        civUniquesCache[civId] = nil
    }
    /// Unciv `ArrayList<TemporaryUnique>.endTurn()`, called from ONE civ's TurnManager.endTurn after its cities.
    func endTurnTemporaryUniques(civId: Int) {
        guard let i = civIndex(civId), !civs[i].temporaryUniques.isEmpty else { return }
        var list = civs[i].temporaryUniques
        for j in list.indices where list[j].turnsLeft >= 0 { list[j].turnsLeft -= 1 }
        list.removeAll { $0.turnsLeft == 0 }
        civs[i].temporaryUniques = list
        civUniquesCache[civId] = nil
    }
}
