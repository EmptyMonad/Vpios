// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct EventChoiceDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let text: String
    let uniques: [String]
    let uniqueObjects: [Unique]
    let civilopediaText: [CivilopediaLine]
    let keyShortcut: String
    private enum CodingKeys: String, CodingKey { case name, text, uniques, civilopediaText, keyShortcut }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        uniqueObjects = uniques.map(Unique.init)
        civilopediaText = try c.decodeIfPresent([CivilopediaLine].self, forKey: .civilopediaText) ?? []
        keyShortcut = try c.decodeIfPresent(String.self, forKey: .keyShortcut) ?? ""
    }
}

struct EventDef: Decodable, Identifiable {
    enum Presentation: String, Decodable { case None, Alert, Floating }
    var id: String { name }
    let name: String
    let presentation: Presentation
    let text: String
    let uniques: [String]
    let uniqueObjects: [Unique]
    let civilopediaText: [CivilopediaLine]
    let choices: [EventChoiceDef]
    private enum CodingKeys: String, CodingKey { case name, presentation, text, uniques, civilopediaText, choices }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        presentation = try c.decodeIfPresent(Presentation.self, forKey: .presentation) ?? .Alert
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        uniqueObjects = uniques.map(Unique.init)
        civilopediaText = try c.decodeIfPresent([CivilopediaLine].self, forKey: .civilopediaText) ?? []
        choices = try c.decodeIfPresent([EventChoiceDef].self, forKey: .choices) ?? []
    }
    /// Unciv Event: tutorial tasks are events named "Tutorial Task: [X]".
    var isTutorialTask: Bool { name.hasPrefix("Tutorial Task: [") }
    var tutorialTaskName: String? { isTutorialTask ? Translations.placeholderParameters(name).first : nil }
    var description: String { civilopediaText.map { $0.text }.filter { !$0.isEmpty }.joined(separator: " ") }
}

/// Unciv Event / EventChoice (models/ruleset/Event.kt + UniqueTriggerActivation "Triggers a [event] event"):
/// an event is available when its OnlyAvailable/Unavailable conditionals hold; Alert presentation asks the player,
/// None picks a random matching choice, Floating just shows the text.
extension GameState {
    func eventIsAvailable(_ e: EventDef, civId: Int, unitId: Int? = nil) -> Bool {
        let ctx = UniqueContext(civId: civId, city: capital(of: civId), unit: unitId.flatMap { unit($0) })
        for u in e.uniqueObjects where u.pattern == "Only available" { if !conditionalsHold(u, ctx) { return false } }
        for u in e.uniqueObjects where u.pattern == "Unavailable" { if conditionalsHold(u, ctx) { return false } }
        return true
    }
    func matchingChoices(_ e: EventDef, civId: Int, unitId: Int? = nil) -> [EventChoiceDef] {
        let ctx = UniqueContext(civId: civId, city: capital(of: civId), unit: unitId.flatMap { unit($0) })
        return e.choices.filter { ch in
            if ch.uniqueObjects.contains(where: { $0.pattern == "Unavailable" && conditionalsHold($0, ctx) }) { return false }
            if ch.uniqueObjects.contains(where: { $0.pattern == "Only available" && !conditionalsHold($0, ctx) }) { return false }
            return true
        }
    }
    /// Unciv UniqueTriggerActivation.TriggerEvent.
    @discardableResult
    func triggerEvent(_ name: String, civId: Int, unitId: Int? = nil, triggerUniqueText: String = "") -> Bool {
        guard let e = rs.events.first(where: { $0.name == name }), eventIsAvailable(e, civId: civId, unitId: unitId) else { return false }
        let choices = matchingChoices(e, civId: civId, unitId: unitId)
        if e.choices.isEmpty || choices.isEmpty {
            if e.presentation != .None { notify(civId, e.text.isEmpty ? e.name : e.text, category: .General) }
            return e.choices.isEmpty
        }
        switch e.presentation {
        case .None:
            if let pick = pickEventChoice(choices, civId: civId, unitId: unitId, uniqueText: triggerUniqueText) { return triggerChoice(pick, civId: civId, unitId: unitId) }
            return false
        case .Alert:
            // Unciv TriggerEvent: `if (civInfo.isAI() || presentation == None)` the choice is made at once - a human under
            // AutoPlay gets the Alert too (the headless run plays the player as an AI)
            if civ(civId)?.isPlayer == true, !epochsAutoplay { addAlert(civId, .Event, name + (unitId.map { "|\($0)" } ?? "")); return true }
            if let pick = pickEventChoice(choices, civId: civId, unitId: unitId, uniqueText: triggerUniqueText) { return triggerChoice(pick, civId: civId, unitId: unitId) }
            return false
        case .Floating:
            notify(civId, e.text.isEmpty ? e.name : e.text, category: .General)
            if let pick = pickEventChoice(choices, civId: civId, unitId: unitId, uniqueText: triggerUniqueText) { return triggerChoice(pick, civId: civId, unitId: unitId) }
            return false
        }
    }
    /// Unciv Event: the choice is drawn by its AI weight, from the game's own generator.
    /// Unciv UniqueTriggerActivation.kt:108: `gameContext.stateBasedRandom("UniqueTriggerActivation.getTriggerFunction", unique.text.hashCode())`
    /// — tuz varsayilan 31 DEGIL, tetikleyen unique'in metninin Java string hash'i; secim :124'te `randomWeighted(rng)`.
    private func pickEventChoice(_ list: [EventChoiceDef], civId: Int, unitId: Int?, uniqueText: String) -> EventChoiceDef? {
        guard !list.isEmpty else { return nil }
        var g = stateBasedRandom("UniqueTriggerActivation.getTriggerFunction",
                                 UniqueContext(civId: civId, city: capital(of: civId), unit: unitId.flatMap { unit($0) }),
                                 seed: javaStringHash(uniqueText))
        let weights = list.map { c in c.uniqueObjects.filter { $0.pattern == "[]% weight to this choice for AI decisions" }.reduce(1.0) { $0 * max(0, 1 + $1.double(0) / 100) } }
        let total = weights.reduce(0, +)
        guard total > 0 else { return list.last }   // Unciv randomWeighted: a zero total takes the last
        var roll = g.double() * total
        for (c, w) in zip(list, weights) { roll -= w; if roll <= 0 { return c } }
        return list.last
    }

    /// Unciv EventChoice.triggerChoice: fire every triggerable unique of the choice.
    @discardableResult
    func triggerChoice(_ choice: EventChoiceDef, civId: Int, unitId: Int? = nil) -> Bool {
        triggerUniques(choice.uniqueObjects, civId: civId, cityId: nil, unitId: unitId)
        return !choice.uniqueObjects.isEmpty
    }
}
