// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `models/ruleset/unique/UniqueTriggerExecutors.kt`.
///
/// Container for the innermost "executors" for triggers, the code actually affecting game state.
/// `UniqueTriggerActivation.triggerUniques` calls into them, therefore this also serves as
/// documentation of exactly what is needed as closure - here the function parameters.
/// They return the Boolean "success" status the caller should return.
extension GameState {
    @discardableResult
    func triggerGlobalAlerts(civId: Int, alertText: String, triggerNotificationText: String) -> Bool {
        // civId is the cause of the alert, the one not getting notified.
        // triggerNotificationText is e.g. "due to adopting [${policy.name}]" or "due to researching [$techName]"
        // alertText is the parameter of the unique.

        // Translate what the original triggerUnique got from the container into something aimed
        // at the other civilizations, and guess an icon:
        guard let ci = civIndex(civId) else { return false }
        let (suffix, icon): (String, String) = {
            let t = triggerNotificationText
            if t.hasPrefix("due to adopting ") { return ("has adopted the " + t.dropFirst("due to adopting ".count) + " policy", "Culture") }
            if t.hasPrefix("due to researching ") { return ("has researched " + t.dropFirst("due to researching ".count), "Science") }
            if t.hasPrefix("due to ") { return (String(t.dropFirst("due to ".count)), "") }
            return (t, "")
        }()
        for j in civs.indices where civs[j].isMajor && civs[j].id != civId {
            let who = civs[j].metCivs.contains(civId) ? "[\(civs[ci].nation)]" : "[An unknown civilization]"
            notify(civs[j].id, "{\(who) \(suffix)}.\n{\(alertText)}", category: .General, icons: icon.isEmpty ? [] : [icon])
        }
        return true
    }
}
