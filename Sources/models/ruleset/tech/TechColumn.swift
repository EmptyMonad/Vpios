// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct TechColumn: Decodable {
    let columnNumber: Int
    let era: String
    let techCost: Int
    let buildingCost: Int
    let wonderCost: Int
    let techs: [TechDef]
}
