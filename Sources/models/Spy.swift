// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct Spy: Codable, Identifiable {
    let id: Int
    var name: String
    var rank: Int = 1
    var cityId: Int? = nil
    var turnsInCity: Int = 0
    var progress: Double = 0       // toward stealing a technology
    var alive: Bool = true
    var arriving: Int = 0          // turns until set up in the assigned city
    @Lenient var surveillance: Bool = false   // Unciv SpyAction.Surveillance: nothing left to steal here
    @Lenient var action: String = "None"      // Unciv SpyAction: None, Moving, EstablishNetwork, Surveillance, StealingTech, RiggingElections, Coup, CounterIntelligence, Dead
    @Lenient var turnsRemaining: Int = 0      // Unciv Spy.turnsRemainingForAction
}
