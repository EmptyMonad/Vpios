// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `models/ruleset/unique/UniqueTarget.kt`.
/// Unciv UniqueTarget: the kind of ruleset object a unique was declared on. Only the targets our
/// rulesets actually use are listed; Unciv's modifier targets are not uniques in our model.
enum UniqueTarget: String {
    case global = "Global", nation = "Nation", personality = "Personality", era = "Era", tech = "Tech"
    case policy = "Policy", founderBelief = "FounderBelief", followerBelief = "FollowerBelief"
    case building = "Building", wonder = "Wonder"
    case unit = "Unit", unitType = "UnitType", promotion = "Promotion"
    case terrain = "Terrain", improvement = "Improvement", resource = "Resource", ruins = "Ruins"
    case globalUniques = "GlobalUniques", speed = "Speed", difficulty = "Difficulty"
    case cityState = "CityState", modOptions = "ModOptions", event = "Event", eventChoice = "EventChoice"
}
