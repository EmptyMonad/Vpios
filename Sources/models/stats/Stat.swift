// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv Stat: the seven yields, which this port addresses by their Unciv names rather than as an enum.
/// What is left of Unciv's enum is its companion - the set of stat names and the ones a purchase can be paid in.
extension GameState {
    /// Unciv Stat.names(): the stat names the ruleset and the unique parameters use.
    static let statNames: Set<String> = ["Food", "Production", "Gold", "Science", "Culture", "Faith", "Happiness"]

    /// Unciv Stat.statsUsableToBuy without Gold, which has its own cost model.
    static let statsUsableToBuy = ["Food", "Science", "Culture", "Faith"]
}
