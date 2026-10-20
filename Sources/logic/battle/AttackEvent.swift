// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/AttackEvent.kt`: one unit attack — who fought where, and which
/// civilizations saw it happen.
struct AttackEvent: Codable, Hashable {
    var turn: Int
    var sourceTile: HexCoord
    var targetTile: HexCoord
    var attacker: AttackParticipant
    var targets: [AttackParticipant] = []
    var civIdsKnowingAttackSource: Set<Int> = []
    var civIdsKnowingAttackTarget: Set<Int> = []
    var resolution: String = "Completed"   // Unciv AttackResolution: Completed / Withdrawn
}
