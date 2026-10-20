// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct Quest: Codable, Identifiable {
    let id: Int
    let name: String
    let cityStateId: Int
    let assigneeId: Int?           // nil = global (all majors that know the city-state)
    let target: String?            // resource, wonder, civ name, natural wonder ...
    let startTurn: Int
    let endTurn: Int
    var baseline: [Int: Double] = [:]   // global contests: stat at start per civ
    var completedBy: Int? = nil
}

extension GameState {
    /// Unciv AssignedQuest.data1 / data2 for one of our quests: a civilization's name where ours keeps its id (the
    /// civTargetQuests), the camp's position as data1 = x, data2 = y in Unciv's coordinates where ours keeps the tile as
    /// "q,r" (ClearBarbarianCamp.getAssignedQuestData), anything else as it is
    func uncivQuestData(_ q: Quest) -> (data1: String, data2: String) {
        if GameState.civTargetQuests.contains(q.name), let nation = q.target.flatMap({ Int($0) }).flatMap({ civ($0)?.nation }) { return (nation, "") }
        if q.name == "Clear Barbarian Camp", let parts = q.target?.split(separator: ","), parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) {
            let p = uncivPosition(HexCoord(a, b)); return ("\(p.x)", "\(p.y)")
        }
        // Unciv SpreadReligion.getAssignedQuestData: data1 = the religion's display name ("For display"), data2 = its name
        // ("To check completion"); ours keeps the name (the state dump's CS line, a test game, turn 33)
        if q.name == "Spread Religion", let name = q.target {
            return (civs.first { $0.religionName == name }?.religionDisplayName ?? name, name)
        }
        return (q.target ?? "", "")
    }
}
