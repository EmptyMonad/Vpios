// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/AttackParticipant.kt`: a participant's identity at attack time,
/// independent of later movement, renaming or capture.
struct AttackParticipant: Codable, Hashable {
    var civId: Int
    var unitId: Int?            // nil for a city
    var name: String
    var healthBefore: Int
    var healthAfter: Int = 0
    var damageReceived: Int = 0
    var outcome: String = "Survived"   // Unciv AttackParticipantOutcome: Survived / Destroyed / Captured / Withdrew
}
