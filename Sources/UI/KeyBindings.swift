// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv KeyboardBindings: every binding has a name, a default key and a value the player may change.
/// The name is what the Keys page shows and what the stored override is filed under, so a rebinding
/// follows the action rather than the position in a list.
struct KeySpec: Equatable {
    var key: String              // a single character, one of the named keys below, or "" - no key at all
    var mods: EventModifiers = []

    static let namedKeys: [String: KeyEquivalent] = [
        "Space": .space, "Return": .return, "Delete": .delete, "Esc": .escape, "Home": .home, "Tab": .tab,
        "PgUp": .pageUp, "PgDn": .pageDown, "←": .leftArrow, "→": .rightArrow, "↑": .upArrow, "↓": .downArrow,
    ]
    /// Unciv Input.Keys.F1..F12: stored and shown like the named keys, but SwiftUI has no KeyEquivalent for them -
    /// FunctionKeys (EpochsApplication) dispatches them.
    static let functionKeyNames: Set<String> = Set((1...12).map { "F\($0)" })
    var isFunctionKey: Bool { Self.functionKeyNames.contains(key) }
    /// Unciv KeyCharAndCode.UNKNOWN: a binding with no key (Diplomacy, Espionage, the AutoPlay menu...), which the
    /// Keys page shows empty and nothing answers to until the player assigns one.
    static let unassigned = KeySpec("")
    var isUnassigned: Bool { key.isEmpty }
    /// The SwiftUI key, or nil when there is none to bind (no key assigned, or a function key).
    var equivalent: KeyEquivalent? {
        if let named = Self.namedKeys[key] { return named }
        if isFunctionKey { return nil }
        return key.count == 1 ? KeyEquivalent(Character(key.lowercased())) : nil
    }

    /// How the binding reads in the Keys page: "⌃O", "⇧↑", "Space"; an unassigned one is empty.
    var label: String {
        if isUnassigned { return "" }
        var out = ""
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option) { out += "⌥" }
        if mods.contains(.shift) { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }
        return out + (Self.namedKeys[key] != nil || isFunctionKey ? key : key.uppercased())
    }
    /// The stored form, "mods:key".
    var stored: String {
        var m: [String] = []
        if mods.contains(.control) { m.append("ctrl") }
        if mods.contains(.option) { m.append("opt") }
        if mods.contains(.shift) { m.append("shift") }
        if mods.contains(.command) { m.append("cmd") }
        return m.joined(separator: "+") + ":" + key
    }
    init(_ key: String, _ mods: EventModifiers = []) { self.key = key; self.mods = mods }
    init?(stored: String) {
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        var m: EventModifiers = []
        for name in parts[0].split(separator: "+") {
            switch name { case "ctrl": m.insert(.control); case "opt": m.insert(.option); case "shift": m.insert(.shift); case "cmd": m.insert(.command); default: break }
        }
        self.init(parts[1], m)
    }
}

enum KeyBindings {
    /// Unciv KeyboardBinding.Category and its entries, in Unciv's order. The names are the labels the Keys page shows and
    /// the keys the player's own bindings are stored under; the main menu's "Load game" and "Options" are bindings of
    /// their own (Unciv MainMenuLoad / MainMenuOptions), filed under "Main menu: ..." so they do not take the world
    /// screen's Ctrl+L / Ctrl+O.
    static let groups: [(String, [(String, KeySpec)])] = [
        ("World screen", [
            ("Deselect then Quit", KeySpec("Esc")), ("Menu", KeySpec("Tab")),
            ("Next turn", KeySpec("n")), ("Next turn alternate", KeySpec("Space")),
            ("Open AutoPlay menu", .unassigned),   // Unciv: "'a' is already assigned to map panning"
            ("Start AutoPlay", KeySpec("a", .control)),
            ("Empire overview", KeySpec("e")), ("Music player", KeySpec("m", .control)), ("Developer console", KeySpec("`")),
            ("Idle Prev", KeySpec(",")), ("Idle Next", KeySpec(".")), ("Cycle", KeySpec(";")),
            // Unciv: "These try to be faithful to default Civ5 key bindings"
            ("Civilopedia", KeySpec("F1")), ("Empire Overview Trades", KeySpec("F2")), ("Empire Overview Units", KeySpec("F3")),
            ("Empire Overview Politics", KeySpec("F4")), ("Social policies", KeySpec("F5")), ("Technology tree", KeySpec("F6")),
            ("Empire Overview Notifications", KeySpec("F7")), ("Victory status", KeySpec("F8")), ("Empire Overview Stats", KeySpec("F9")),
            ("Empire Overview Resources", KeySpec("F10")), ("Quick Save", KeySpec("F11")), ("Quick Load", KeySpec("F12")),
            ("View capital city", KeySpec("Home")), ("Options", KeySpec("o", .control)),
            ("Save game", KeySpec("s", .control)), ("Load game", KeySpec("l", .control)),
            ("Toggle resource display", KeySpec("r", .control)), ("Toggle yield display", KeySpec("y", .control)),
            // Unciv QuitGame (Ctrl+Q) is game.popScreen() - with the WorldScreen last, "Do you want to exit the game?" and
            // Gdx.app.exit(): an iOS app does not quit itself, so it is not offered (as DeselectOrQuit stops at deselecting)
            ("New Game", KeySpec("n", .control)), ("Diplomacy", .unassigned), ("Espionage", .unassigned),
            ("Undo", KeySpec("z", .control)), ("Toggle UI", KeySpec("u", .control)),
            ("Toggle Worked Tiles Display", .unassigned), ("Toggle Movement Display", .unassigned), ("Toggle Improvement Display", .unassigned),
            ("Zoom in", KeySpec("+")), ("Zoom out", KeySpec("-")),
        ]),
        ("Civilopedia", [
            ("Pedia: Buildings", KeySpec("b")), ("Pedia: Wonders", KeySpec("w")), ("Pedia: Resources", KeySpec("r")),
            ("Pedia: Terrains", KeySpec("t")), ("Pedia: Tile Improvements", KeySpec("i")), ("Pedia: Units", KeySpec("u")),
            ("Pedia: Unit types", KeySpec("y")), ("Pedia: Nations", KeySpec("n")), ("Pedia: Technologies", KeySpec("t", .control)),
            ("Pedia: Promotions", KeySpec("p")), ("Pedia: Policies", KeySpec("o")), ("Pedia: Religions and Beliefs", KeySpec("f")),
            ("Pedia: Unit Names", KeySpec("g")), ("Pedia: Victory Types", KeySpec("v")), ("Pedia: Difficulty levels", KeySpec("d")),
            ("Pedia: Eras", KeySpec("e")), ("Pedia: Speeds", KeySpec("s")),
            ("Open the Search Dialog", KeySpec("f", .control)),   // Unciv PediaSearch: a Civilopedia binding only
        ]),
        ("Map panning", [
            ("Pan up", KeySpec("↑")), ("Pan left", KeySpec("←")), ("Pan down", KeySpec("↓")), ("Pan right", KeySpec("→")),
            ("Pan up alternate", KeySpec("w")), ("Pan left alternate", KeySpec("a")),
            ("Pan down alternate", KeySpec("s")), ("Pan right alternate", KeySpec("d")),
        ]),
        ("Unit actions", [
            ("Swap units", KeySpec("y")), ("Automate", KeySpec("m")), ("Stop automation", KeySpec("m")),
            ("Stop movement", KeySpec("m")), ("Show unit destination", KeySpec("j")),
            ("Sleep", KeySpec("f")), ("Sleep until healed", KeySpec("h")),
            ("Fortify", KeySpec("f")), ("Fortify until healed", KeySpec("h")),
            ("Explore", KeySpec("x")), ("Stop exploration", KeySpec("x")),
            ("Promote", KeySpec("o")), ("Upgrade", KeySpec("u")), ("Transform", KeySpec("k")),
            ("Pillage", KeySpec("p")), ("Paradrop", KeySpec("p")), ("Air Sweep", KeySpec("a")),
            ("Set up", KeySpec("t")), ("Found city", KeySpec("c")), ("Connect road", KeySpec("c")),
            ("Construct improvement", KeySpec("i")), ("Create", KeySpec("i")), ("Repair", KeySpec("r")),
            // (Unciv UnitActionType.HurryPolicy has no KeyboardBinding of its name - KeyboardBinding.None, no key, no row)
            ("Hurry Research", KeySpec("g")), ("Hurry Wonder", KeySpec("g")),
            ("Hurry Construction", KeySpec("g")), ("Conduct Trade Mission", KeySpec("g")),
            ("Found a Religion", KeySpec("g")), ("Enhance a Religion", KeySpec("g")),
            ("Spread Religion", KeySpec("g")), ("Remove Heresy", KeySpec("h")), ("Add in capital", KeySpec("g")),
            ("Trigger unique", KeySpec("g")), ("Disband unit", KeySpec("Delete")), ("Skip", KeySpec("z")),
            ("Show more", KeySpec("PgDn")), ("Back", KeySpec("PgUp")),
        ]),
        ("City screen", [
            ("Previous city", KeySpec("←")), ("Next city", KeySpec("→")),
            ("Reset Citizens", KeySpec("r", .control)), ("Avoid growth", KeySpec("a", .control)),
            ("Default Focus", KeySpec("d", .control)), ("Food Focus", KeySpec("f", .control)),
            ("Production Focus", KeySpec("p", .control)), ("Gold Focus", KeySpec("g", .control)),
            ("Science Focus", KeySpec("s", .control)), ("Culture Focus", KeySpec("c", .control)),
        ]),
        // Unciv QuitMainMenu (Back) is game.popScreen() → exit, which an iOS app does not do; Scenarios has no button in 4.22.1
        ("Main menu", [
            ("Resume", KeySpec("r")), ("Quickstart", KeySpec("q")),   // Unciv: a binding without a key takes `name[0]`
            ("Start new game", KeySpec("n")), ("Main menu: Load game", KeySpec("l")), ("Multiplayer", KeySpec("m")),
            ("Map editor", KeySpec("e")), ("Mods", KeySpec("d")), ("Main menu: Options", KeySpec("o")),
        ]),
        ("Popups", [
            ("Confirm Dialog", KeySpec("y")), ("Cancel Dialog", KeySpec("n")), ("Upgrade All", KeySpec("a", .control)),
        ]),
    ]

    private static let storeKey = "epochs.keyBindings"
    static var overrides: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: storeKey) }
    }

    private static let defaultsByName: [String: KeySpec] = Dictionary(
        groups.flatMap { $0.1 }.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })

    /// The key a binding answers to now: the player's own if they set one, otherwise Unciv's default - which may be
    /// no key (KeyCharAndCode.UNKNOWN), as is any name without a binding.
    static func spec(_ name: String) -> KeySpec {
        if let stored = overrides[name], let s = KeySpec(stored: stored) { return s }
        return defaultsByName[name] ?? .unassigned
    }
    static func set(_ name: String, _ spec: KeySpec?) {
        var all = overrides
        if let spec, spec != defaultsByName[name] { all[name] = spec.stored } else { all[name] = nil }
        overrides = all
    }
    static func resetAll() { overrides = [:] }
    /// What the Keys page shows for a binding: Unciv KeyboardBinding.label - the label it is given, else unCamelCase of its
    /// name ("NextTurnAlternate" → "Next Turn Alternate", PediaResources → "Resources", FoodFocus → "[Food] Focus") - the
    /// keys TranslationFileWriter puts in the translation files. Our names stay the stored overrides' keys; where one is
    /// written otherwise the Keys page showed it in English in a Turkish game. The main menu's own lose their "Main menu: ".
    static let uncivLabels: [String: String] = [
        "Next turn": "Next Turn", "Social policies": "Social Policies", "Save game": "Save Game", "Load game": "Load Game",
        "Next turn alternate": "Next Turn Alternate", "Empire overview": "Empire Overview", "Music player": "Music Player",
        "Developer console": "Developer Console", "Technology tree": "Technology Tree", "View capital city": "View Capital City",
        "Toggle resource display": "Toggle Resource Display", "Toggle yield display": "Toggle Yield Display", "Zoom in": "Zoom In",
        "Zoom out": "Zoom Out", "Pedia: Buildings": "Buildings", "Pedia: Wonders": "Wonders", "Pedia: Resources": "Resources",
        "Pedia: Terrains": "Terrains", "Pedia: Tile Improvements": "Tile Improvements", "Pedia: Units": "Units",
        "Pedia: Unit types": "Unit types", "Pedia: Nations": "Nations", "Pedia: Technologies": "Technologies",
        "Pedia: Promotions": "Promotions", "Pedia: Policies": "Policies", "Pedia: Religions and Beliefs": "Religions and Beliefs",
        "Pedia: Unit Names": "Unit Names", "Pedia: Victory Types": "Victory Types", "Pedia: Difficulty levels": "Difficulty levels",
        "Pedia: Eras": "Eras", "Pedia: Speeds": "Speeds", "Pan up": "Pan Up", "Pan left": "Pan Left", "Pan down": "Pan Down",
        "Pan right": "Pan Right", "Pan up alternate": "Pan Up Alternate", "Pan left alternate": "Pan Left Alternate",
        "Pan down alternate": "Pan Down Alternate", "Pan right alternate": "Pan Right Alternate", "Previous city": "Previous City",
        "Next city": "Next City", "Avoid growth": "Avoid Growth", "Food Focus": "[Food] Focus", "Production Focus": "[Production] Focus",
        "Gold Focus": "[Gold] Focus", "Science Focus": "[Science] Focus", "Culture Focus": "[Culture] Focus"
    ]
    /// Unciv KeyboardBinding.Category.label: unCamelCase of the category's name ("MapPanning" → "Map Panning").
    static func groupLabel(_ group: String) -> String {
        ["World screen": "World Screen", "Map panning": "Map Panning", "Unit actions": "Unit Actions", "City screen": "City Screen",
         "Main menu": "Main Menu"][group] ?? group
    }
    static func label(_ name: String) -> String {
        if let l = uncivLabels[name] { return l }
        return name.hasPrefix("Main menu: ") ? String(name.dropFirst("Main menu: ".count)) : name
    }
    static func isChanged(_ name: String) -> Bool { overrides[name] != nil }
}
