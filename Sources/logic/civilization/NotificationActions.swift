// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Unciv NotificationAction subclasses: what tapping a notification does (cycled when there are several).
enum NotificationAction: Codable, Equatable {
    case location(HexCoord)
    case city(HexCoord)
    case tech(String)
    case diplomacy(String)          // other civ name
    case diplomacyTrade(String)     // Unciv DiplomacyAction(otherCiv, showTrade = true): opens the trade table
    case unit(HexCoord, Int)        // MapUnitAction: location + id
    case civilopedia(String)        // link "Category/Name"
    case overview(String, String)   // page + select
    case policy(String)
    case espionage
    case religion(String)
    case link(String)
    case promoteUnit(String, HexCoord, Int)
    case mayaLongCount
}
