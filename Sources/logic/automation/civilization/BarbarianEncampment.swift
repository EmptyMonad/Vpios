// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Unciv BarbarianEncampment
struct Encampment: Codable, Equatable {
    var position: HexCoord
    var countdown: Int = 0
    var spawnedUnits: Int = -1
    var destroyed: Bool = false
    init(position: HexCoord) { self.position = position }
}
