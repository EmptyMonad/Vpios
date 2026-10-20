// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `models/ruleset/unique/LocalUniqueCache.kt`: caching the results of a getMatchingUniques
/// lookup. The cache is invalidated whenever anything feeding it changes (see `invalidateCaches`), so callers
/// never see a stale pool.
extension GameState {
    /// Empire-wide uniques: nation, adopted policies, opened branches, global rules, wonders in any city.
    func civUniques(_ civId: Int) -> [Unique] {
        if let cached = civUniquesCache[civId] { return cached }
        let result = computeCivUniques(civId)
        civUniquesCache[civId] = result
        return result
    }
}
