// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv UnitAction: one action the selected unit offers - its title, icon, page and what it does.
/// The static properties Unciv keeps in UnitActionType (use frequency, keyboard binding) are the tables below.
struct UnitAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    var page = 0
    var enabled = true
    var isCurrent = false
    var longPress: (() -> Void)? = nil
    var key: KeyEquivalent? = nil
    let action: () -> Void

    /// Unciv UnitAction.useFrequency: how often the action is wanted, which is the order the buttons are in.
    static let useFrequency: [String: Double] = [
        "promote": 150, "upgrade": 120, "sweep": 90, "repair": 90, "setup": 85, "construct": 85, "create": 85,
        "found": 80, "foundreligion": 80, "golden": 80, "capital": 80, "enhance": 79,
        "hurryresearch": 76, "hurrypolicy": 76, "hurrywonder": 75, "hurrybuilding": 75,
        "transform": 70, "trademission": 70, "heresy": 69, "spread": 68, "pillage": 65,
        "paradrop": 60, "swap": 60, "escort": 50, "stopescort": 50,
        "fortifyhealed": 45, "sleephealed": 44, "fortify": 30, "dest": 30, "sleep": 29,
        // Unciv lowers these once the unit is already in that state, which moves them below Automate (25).
        "sleepcurrent": 21, "sleephealedcurrent": 20, "fortifycurrent": 10, "fortifyhealedcurrent": 10,
        "connectroad": 25, "automate": 25, "stopmove": 20, "stopexplore": 20, "stopauto": 10,
        "gift": 5, "explore": 5, "guard": 0, "skip": 0, "disband": 0,
    ]

    /// Unciv KeyboardBinding.Category.UnitActions: the letter each action answers to on a hardware keyboard.
    /// Several actions share a letter in Unciv too - they are the ones a unit never offers at the same time -
    /// so the first action on screen claims the key and the rest go without, which is what Unciv's list does.
    static let actionBindings: [String: String] = [
        "swap": "Swap units", "automate": "Automate", "stopauto": "Stop automation", "stopmove": "Stop movement",
        "dest": "Show unit destination", "sleep": "Sleep", "sleephealed": "Sleep until healed",
        "fortify": "Fortify", "fortifyhealed": "Fortify until healed",
        "explore": "Explore", "stopexplore": "Stop exploration", "promote": "Promote", "upgrade": "Upgrade",
        "transform": "Transform", "pillage": "Pillage", "paradrop": "Paradrop", "sweep": "Air Sweep",
        "setup": "Set up", "found": "Found city", "connectroad": "Connect road",
        "construct": "Construct improvement", "create": "Create", "repair": "Repair",
        "hurryresearch": "Hurry Research", "hurrywonder": "Hurry Wonder",   // HurryPolicy: KeyboardBinding.None
        "hurrybuilding": "Hurry Construction", "trademission": "Conduct Trade Mission",
        "foundreligion": "Found a Religion", "enhance": "Enhance a Religion", "spread": "Spread Religion",
        "heresy": "Remove Heresy", "capital": "Add in capital", "golden": "Trigger unique",
        "disband": "Disband unit", "skip": "Skip", "more": "Show more", "back": "Back",
    ]
}
