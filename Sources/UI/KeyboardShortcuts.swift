// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv KeyboardBinding defaults for hardware keyboards (iPad / Mac): invisible buttons carrying the shortcuts, and the
/// function keys (F1-F12), which SwiftUI cannot bind, through FunctionKeys.
struct WorldKeyboardShortcuts: View {
    @ObservedObject var controller: GameController
    var onOptions: () -> Void = {}
    var onSave: () -> Void = {}
    var onLoad: () -> Void = {}
    var onNewGame: () -> Void = {}
    var onQuickSave: () -> Void = {}
    var onQuickLoad: () -> Void = {}
    @State private var functionKeysId = UUID()
    var body: some View {
        Group {
            // Unciv PlayerReadyScreen is a screen of its own; an open popup or a screen over the world vetoes these keys
            if controller.handoffTo != nil || controller.worldShortcutsVetoed { EmptyView() } else { live }
        }
        .frame(width: 0, height: 0).opacity(0)
        .onAppear { FunctionKeys.register(functionKeysId) { handleFunctionKey($0) } }
        .onDisappear { FunctionKeys.unregister(functionKeysId) }
    }

    @ViewBuilder
    private var live: some View {
        ForEach(bindings, id: \.name) { b in bind(b.name, b.action) }
    }

    /// Unciv WorldScreen.addKeyboardPresses (globalShortcuts) and the bindings its buttons carry (NextTurnButton,
    /// WorldScreenTopBar, TechPolicyDiplomacyButtons, UnitTable's IdleUnitButtons, AutoPlayStatusButton), plus MapPanning.
    /// The SmallUnitButton's Cycle stays on that button (GameView).
    private var bindings: [(name: String, action: () -> Void)] {
        var out: [(name: String, action: () -> Void)] = [
            ("Deselect then Quit", { controller.deselectAll() }),                                  // DeselectOrQuit
            // Menu: WorldScreenTopBar menuButton → WorldScreenMenuPopup, whose init stops AutoPlay
            ("Menu", { controller.stopAutoPlay(); controller.menuExpertMode = false; controller.showMenu = true }),
            // NextTurn / NextTurnAlternate: the NextTurnButton's own bindings, which a disabled button does not answer
            ("Next turn", { if controller.nextTurnButtonEnabled { controller.performNextTurnAction() } }),
            ("Next turn alternate", { if controller.nextTurnButtonEnabled { controller.performNextTurnAction() } }),
        ]
        // Unciv AutoPlayStatusButton carries its two bindings, and WorldScreen.updateAutoPlayStatusButton builds that button
        // only with settings.autoPlay.showAutoPlayButton (off by default) - the same condition as the button (GameView)
        if UserSettings.showAutoPlayButton || controller.isAutoPlaying {
            // AutoPlayMenu: the button's onActivation - stop a running AutoPlay, else the menu on the player's turn
            out.append(("Open AutoPlay menu", { if controller.isAutoPlaying { controller.stopAutoPlay() } else if controller.isMyTurn { controller.showAutoPlayMenu = true } }))
            // AutoPlay: directAutoPlay - never in an online game, and only for the current player (isMyTurn)
            out.append(("Start AutoPlay", { if !controller.isOnline && controller.isMyTurn && !controller.isAutoPlaying { controller.startAutoPlay() } }))
        }
        out += [
            ("Empire overview", { controller.showOverview = true }),                               // EmpireOverview: openEmpireOverview(), the last page
            ("Music player", { controller.showMusic = true }),                                     // MusicPlayer
            ("Developer console", { controller.openDeveloperConsole() }),                          // DeveloperConsole
            ("Idle Prev", { controller.idleArrow(previous: true) }),                               // PrevIdleButton
            ("Idle Next", { controller.idleArrow(previous: false) }),                              // NextIdleButton
            ("Civilopedia", { controller.showCivilopedia = true }),                                // Civilopedia: openCivilopedia()
            ("Empire Overview Trades", { openOverview("Trades") }),
            ("Empire Overview Units", { openOverview("Units") }),
            ("Empire Overview Politics", { openOverview("Politics") }),
            ("Social policies", { controller.showPolicies = true }),                               // SocialPolicies
            // TechnologyTree: Unciv binds it to the tech button and to the spectator's "Fog of War" button, only one of which is there to take it
            ("Technology tree", { if controller.player.isSpectator { controller.toggleFogOfWar() } else { controller.showTech = true } }),
            ("Empire Overview Notifications", { openOverview("Notifications") }),
            ("Victory status", { controller.showVictory = true }),                                 // VictoryScreen
            ("Empire Overview Stats", { openOverview("Stats") }),
            ("Empire Overview Resources", { openOverview("Resources") }),
            ("Quick Save", { onQuickSave() }),                                                     // QuickSave.save(gameInfo, this)
            ("Quick Load", { onQuickLoad() }),                                                     // QuickSave.load(this)
            ("View capital city", { controller.viewCapitalCity() }),                               // ViewCapitalCity
            ("Options", { onOptions() }),                                                          // Options
            ("Save game", { onSave() }),                                                           // SaveGame
            ("Load game", { onLoad() }),                                                           // LoadGame
            // The display toggles: minimapWrapper.<button>.toggle(), as the minimap's toggle buttons do
            ("Toggle resource display", { UserSettings.showResourcesAndImprovements.toggle(); controller.overlaysChanged() }),   // resourceImageButton
            ("Toggle yield display", { UserSettings.showTileYields.toggle(); controller.overlaysChanged() }),
            ("New Game", { onNewGame() }),                                                         // NewGame: openNewGameScreen()
            ("Diplomacy", { controller.showDiplomacy = true }),                                    // Diplomacy
        ]
        // Unciv TechPolicyDiplomacyButtons: the espionage button and its binding exist only with espionage on
        if controller.state.espionageEnabled {
            out.append(("Espionage", { controller.selectedSpyId = nil; controller.showEspionage = true }))
        }
        out += [
            ("Undo", { controller.undo() }),                                                       // Undo
            ("Toggle UI", { controller.toggleUI() }),                                              // ToggleUI
            ("Toggle Worked Tiles Display", { UserSettings.showWorkedTiles.toggle(); controller.overlaysChanged() }),
            ("Toggle Movement Display", { UserSettings.showUnitMovements.toggle(); controller.overlaysChanged() }),
            ("Toggle Improvement Display", { UserSettings.showPixelImprovements.toggle(); controller.overlaysChanged() }),   // improvementsImageButton
            ("Zoom in", { controller.zoomIn() }),                                                  // mapHolder.zoomIn()
            ("Zoom out", { controller.zoomOut() }),                                                // mapHolder.zoomOut()
            // Unciv KeyboardPanningListener: the arrows, and W A S D as alternates
            ("Pan up", { controller.scene.pan(dx: 0, dy: 1) }),
            ("Pan down", { controller.scene.pan(dx: 0, dy: -1) }),
            ("Pan left", { controller.scene.pan(dx: -1, dy: 0) }),
            ("Pan right", { controller.scene.pan(dx: 1, dy: 0) }),
            ("Pan up alternate", { controller.scene.pan(dx: 0, dy: 1) }),
            ("Pan down alternate", { controller.scene.pan(dx: 0, dy: -1) }),
            ("Pan left alternate", { controller.scene.pan(dx: -1, dy: 0) }),
            ("Pan right alternate", { controller.scene.pan(dx: 1, dy: 0) }),
        ]
        return out
    }

    /// Unciv WorldScreen.openEmpireOverview(category): the overview on that page, selection "".
    private func openOverview(_ page: String) {
        controller.overviewPage = page; controller.overviewSelect = ""; controller.showOverview = true
    }

    /// A function key: the binding it is the key of now (F1-F12 by default, or one the player put there).
    private func handleFunctionKey(_ spec: KeySpec) -> Bool {
        guard controller.handoffTo == nil, !controller.worldKeysBlocked,
              let b = bindings.first(where: { KeyBindings.spec($0.name) == spec }) else { return false }
        b.action()
        return true
    }

    /// The binding by name, so a key the player changed takes effect everywhere it is used; a binding with no key
    /// (Unciv KeyCharAndCode.UNKNOWN) or a function key has no SwiftUI shortcut. A key that reaches the world from a
    /// sheet or cover presented over it without a shortcut of its own (UIKit passes it up) is vetoed there.
    @ViewBuilder private func bind(_ name: String, _ action: @escaping () -> Void) -> some View {
        let spec = KeyBindings.spec(name)
        if let key = spec.equivalent { Button("") { if !controller.worldKeysBlocked { action() } }.keyboardShortcut(key, modifiers: spec.mods) }
    }
}

/// A KeyboardBinding on a button that is on screen (Unciv `keyShortcuts.add(binding)` on the actor): the binding's key
/// now, or none - nil, an unassigned binding and a function key add nothing.
struct BindingShortcut: ViewModifier {
    let name: String?
    func body(content: Content) -> some View {
        if let name, let key = KeyBindings.spec(name).equivalent { content.keyboardShortcut(key, modifiers: KeyBindings.spec(name).mods) } else { content }
    }
}

/// Unciv KeyboardBinding.Category.CityScreen: moving between cities, the citizen controls and the focus letters.
struct CityKeyboardShortcuts: View {
    @ObservedObject var controller: GameController
    var body: some View {
        Group {
            bind("Previous city") { controller.cycleCity(-1) }            // PreviousCity
            bind("Next city") { controller.cycleCity(1) }            // NextCity
            bind("Reset Citizens") { controller.resetCitizens() }           // ResetCitizens
            bind("Avoid growth") { controller.toggleAvoidGrowth() }       // AvoidGrowth
            bind("Default Focus") { controller.setCityFocus("NoFocus") }   // NoFocus ("Default Focus")
            bind("Food Focus") { controller.setCityFocus("FoodFocus") }
            bind("Production Focus") { controller.setCityFocus("ProductionFocus") }
            bind("Gold Focus") { controller.setCityFocus("GoldFocus") }
            bind("Science Focus") { controller.setCityFocus("ScienceFocus") }
            bind("Culture Focus") { controller.setCityFocus("CultureFocus") }
        }
        .frame(width: 0, height: 0).opacity(0)
    }
    @ViewBuilder private func bind(_ name: String, _ action: @escaping () -> Void) -> some View {
        let spec = KeyBindings.spec(name)
        if let key = spec.equivalent { Button("", action: action).keyboardShortcut(key, modifiers: spec.mods) }
    }
}

/// Unciv MainMenuScreen's buttons and their bindings: R resume (only with an autosave to resume), Q quickstart, N new
/// game, L load, M multiplayer, E editor, D mods, O options; the Civilopedia button's F1.
struct MainMenuKeyboardShortcuts: View {
    var onResume: (() -> Void)? = nil
    var onQuickstart: () -> Void = {}
    var onNewGame: () -> Void = {}
    var onLoad: () -> Void = {}
    var onMultiplayer: () -> Void = {}
    var onEditor: () -> Void = {}
    var onMods: () -> Void = {}
    var onOptions: () -> Void = {}
    var onCivilopedia: () -> Void = {}
    @State private var functionKeysId = UUID()
    var body: some View {
        Group {
            if let onResume { menuKey("Resume", onResume) }
            menuKey("Quickstart", onQuickstart)
            menuKey("Start new game", onNewGame)
            menuKey("Main menu: Load game", onLoad)
            menuKey("Multiplayer", onMultiplayer)
            menuKey("Map editor", onEditor)
            menuKey("Mods", onMods)
            menuKey("Main menu: Options", onOptions)
        }.frame(width: 0, height: 0).opacity(0)
        // civilopediaButton.keyShortcuts.add(KeyboardBinding.Civilopedia) - F1 by default
        .onAppear {
            FunctionKeys.register(functionKeysId) { spec in
                guard KeyBindings.spec("Civilopedia") == spec, !FunctionKeys.rootIsCovered else { return false }
                onCivilopedia(); return true
            }
        }
        .onDisappear { FunctionKeys.unregister(functionKeysId) }
    }
}

extension MainMenuKeyboardShortcuts {
    /// A screen presented over the main menu (Unciv pushes it) has the keys; the main menu's do nothing under it.
    @ViewBuilder fileprivate func menuKey(_ name: String, _ action: @escaping () -> Void) -> some View {
        let spec = KeyBindings.spec(name)
        if let key = spec.equivalent { Button("") { if !FunctionKeys.rootIsCovered { action() } }.keyboardShortcut(key, modifiers: spec.mods) }
    }
}
