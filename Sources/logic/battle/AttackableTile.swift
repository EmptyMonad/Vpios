// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/AttackableTile.kt`.
struct AttackableTile {
    let tileToAttackFrom: HexCoord
    let tileToAttack: HexCoord
    let movementLeftAfterMovingToAttackTile: Double
}
