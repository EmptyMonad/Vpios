// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv MainMenuScreen: Resume, Quickstart, Start new game, Load game, Multiplayer, Map editor, Mods, Options; "?" opens the Civilopedia.
struct MainMenuView: View {
    let onStart: (GameState) -> Void
    /// A message brought back to the main menu (Unciv's ToastPopup on the MainMenuScreen a refused load goes to)
    var message: Binding<String?> = .constant(nil)
    @State private var showNewGame = false
    @State private var showLoad = false
    @State private var showOnline = false
    @State private var showEditor = false
    @State private var showMods = false
    @State private var showOptions = false
    @State private var optionsWithDebug = false
    /// The long press on Options opened it with the Debug tab; its lift is no tap (uncivLongPress)
    @State private var optionsLongPressFired = false
    @State private var showCivilopedia = false
    @State private var showAbout = false
    @State private var loadError: String? = nil
    @State private var hasAutosave = SaveManager.hasAutosave
    @State private var busy = false
    @State private var newGameSettings = GameSettings()

    private static let tablet = UIDevice.current.userInterfaceIdiom == .pad

    var body: some View {
        ZStack {
            Theme.background
            HStack(spacing: 20) {
                VStack(spacing: 12) {
                    HStack {
                        // Unciv MainMenuScreen.getCivilopediaRuleset: the last game setup's ruleset (base and mods), else the default base
                        Button { openCivilopedia() } label: {
                            Text("?").font(Theme.title(20)).foregroundStyle(Theme.gold).frame(width: 40, height: 40).background(Circle().fill(Theme.panelDark)).overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                        }
                        Spacer()
                    }
                    Spacer()
                    MainMenuBrandingHeader(tablet: Self.tablet, onAbout: { showAbout = true })
                    Spacer()
                    if let e = loadError { Text(e).font(Theme.caption).foregroundStyle(Theme.danger).multilineTextAlignment(.center) }
                    if busy { ProgressView().tint(Theme.gold) }
                    MainMenuBrandingFooter(onAbout: { showAbout = true })
                }
                .frame(maxWidth: .infinity)
                // a tablet's stage is taller than a phone's (4:3): the column stands in the middle of it, as Unciv's centred
                // menu column does, instead of at the top with the lower half empty
                GeometryReader { g in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        if hasAutosave {
                            Button { resume() } label: { Label(L("Resume"), systemImage: "play.fill") }.buttonStyle(ThemedButtonStyle(filled: true))
                        }
                        Button { quickstart() } label: { Label(L("Quickstart"), systemImage: "bolt.fill") }.buttonStyle(ThemedButtonStyle())
                        Button { newGameSettings = MainMenuView.setupForNewGame(); showNewGame = true } label: { Label(L("Start new game"), systemImage: "globe.europe.africa.fill") }.buttonStyle(ThemedButtonStyle())
                        Button { showLoad = true } label: { Label(L("Load game"), systemImage: "tray.and.arrow.down.fill") }.buttonStyle(ThemedButtonStyle())
                        Button { showOnline = true } label: { Label(L("Multiplayer"), systemImage: "antenna.radiowaves.left.and.right") }.buttonStyle(ThemedButtonStyle()).comingSoon(place: "main_menu")
                        Button { showEditor = true } label: { Label(L("Map editor"), systemImage: "paintbrush.pointed.fill") }.buttonStyle(ThemedButtonStyle())
                        Button { showMods = true } label: { Label(L("Mods"), systemImage: "shippingbox.fill") }.buttonStyle(ThemedButtonStyle()).comingSoon(mods: true, place: "main_menu")
                        Button {
                            if optionsLongPressFired { optionsLongPressFired = false; return }   // the lift after a long press is no tap
                            optionsWithDebug = false; showOptions = true
                        } label: { Label(L("Options"), systemImage: "gearshape.fill") }.buttonStyle(ThemedButtonStyle())
                            .uncivLongPress(fired: $optionsLongPressFired) { optionsWithDebug = true; showOptions = true }   // Unciv optionsTable.onLongPress
                    }.padding(.vertical, 4)
                    .frame(minHeight: Self.tablet ? g.size.height : 0)
                }
                }
                .frame(width: 300)
            }.padding()
        }
        .overlay { if UserSettings.enableEasterEggs, let holiday = HolidayDates.holiday() { EasterEggFloatingArt(holiday: holiday).allowsHitTesting(false) } }
        .background(MainMenuKeyboardShortcuts(onResume: hasAutosave ? { resume() } : nil, onQuickstart: { quickstart() },
                                              onNewGame: { newGameSettings = MainMenuView.setupForNewGame(); showNewGame = true }, onLoad: { showLoad = true },
                                              onMultiplayer: { if !StoreBuild.onlineAndModsComingSoon { showOnline = true } }, onEditor: { showEditor = true },
                                              onMods: { if !StoreBuild.onlineAndModsComingSoon { showMods = true } },
                                              onOptions: { optionsWithDebug = false; showOptions = true },   // Unciv's Options binding: openOptionsPopup() with no Debug page
                                              onCivilopedia: { openCivilopedia() }))
        .overlay { LoadingOverlay(active: busy) }
        .foregroundStyle(Theme.cream)
        // Unciv MainMenuScreen's init: SoundPlayer.initializeForMainMenu() - the sound cache checked against the mods, the
        // effects preloaded again in the background when they changed
        .onAppear { hasAutosave = SaveManager.hasAutosave; Audio.shared.initializeForMainMenu(); if let m = message.wrappedValue { loadError = m; message.wrappedValue = nil }
            if LaunchOptions.opensNewGameScreen { newGameSettings = MainMenuView.setupForNewGame(); showNewGame = true } }
        .onChange(of: message.wrappedValue) { _, m in if let m { loadError = m; message.wrappedValue = nil } }
        .fullScreenCover(isPresented: $showNewGame) { NewGameScreen(initial: newGameSettings, fromSettings: true, onStart: { s in showNewGame = false; onStart(s) }, onClose: { showNewGame = false }).onStage().immersiveSystemUI() }
        .fullScreenCover(isPresented: $showLoad) { LoadGameScreen(onLoad: { s in showLoad = false; onStart(s) }, onClose: { showLoad = false }).onStage().immersiveSystemUI() }
        .fullScreenCover(isPresented: $showEditor) { MapEditorView(onClose: { showEditor = false }).onStage().immersiveSystemUI() }
        .stageSheet(isPresented: $showMods) { ModManagerView(onClose: { showMods = false }).immersiveSystemUI() }
        .stageSheet(isPresented: $showOnline) { MultiplayerView(settings: $newGameSettings, onOpen: { s in showOnline = false; onStart(s) }, onClose: { showOnline = false }).immersiveSystemUI() }
        .stageSheet(isPresented: $showOptions) { OptionsView(controller: nil, withDebug: optionsWithDebug, onClose: { showOptions = false }).immersiveSystemUI() }
        .stageSheet(isPresented: $showCivilopedia) { CivilopediaScreen(ruleset: Ruleset.shared, onClose: { showCivilopedia = false }).immersiveSystemUI() }
        .stageSheet(isPresented: $showAbout) { AboutView(onClose: { showAbout = false }).immersiveSystemUI() }
        .screenShown("main_menu")
    }

    /// Unciv MainMenuScreen.getCivilopediaRuleset: the last game setup's ruleset (base and mods), else the default base
    private func openCivilopedia() {
        if let last = UserSettings.lastGameSetup { Ruleset.activate(mods: last.mods, baseRuleset: last.baseRuleset) }
        else { Ruleset.activate(mods: [], baseRuleset: Ruleset.baseRulesetName) }
        showCivilopedia = true
    }

    /// Unciv GameSetupInfo.fromSettings: start from the remembered setup (lastGameSetup) with a fresh seed. The
    /// GameParameters.clone keeps the online flag (and the seats' player IDs, which only NewGameScreen's
    /// PlayerPickerTable wipes); the game id belongs to the game, not the parameters.
    static func setupForNewGame(defaultDifficulty: String? = nil) -> GameSettings {
        guard var s = UserSettings.lastGameSetup else {
            // Unciv GameSetupInfo.fromSettings: with nothing remembered, espionage is on and the map wraps.
            var fresh = GameSettings()
            if let d = defaultDifficulty { fresh.difficulty = d }
            fresh.mapShape = "Rectangular"; fresh.worldWrap = true; fresh.espionageEnabled = true
            return fresh
        }
        s.seed = 0; s.gameId = nil
        if s.players.isEmpty { s.players = GameSettings().players }
        return s
    }

    /// Unciv MainMenuScreen.resumeGame → QuickSave.autoLoadGame: load the latest autosave; an online game is then
    /// checked against the server first (Multiplayer.downloadGame(gameInfo)) - the autosave is opened only while
    /// the server's preview has the same current player and turn (hasLatestGameState), otherwise the server's game is
    /// downloaded and opened (downloadGame(gameId): the list's preview updated when newer). A failure is the load
    /// exception's message. Ours always opened the autosave, so an online turn resumed from a stale autosave was
    /// played again and uploaded over the server's newer game.
    private func resume() {
        busy = true; loadError = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let saved: GameState
            do { saved = try SaveManager.loadLatestAutosave() } catch {
                loadError = MultiplayerHelpers.loadExceptionMessage(error, primary: "Cannot resume game!"); busy = false; return
            }
            GameEvents.post(.gameLoaded(saved, source: "resume"))
            guard saved.settings.isOnline, let gameId = saved.settings.gameId else { busy = false; onStart(saved); return }
            Task {
                do {
                    let preview = try await Multiplayer.downloadPreview(gameId)
                    if Multiplayer.hasLatestGameState(saved, preview) { busy = false; onStart(saved); return }
                    let latest = try await MultiplayerHelpers.downloadGame(gameId)
                    busy = false; onStart(latest)
                } catch {
                    loadError = MultiplayerHelpers.loadExceptionMessage(error); busy = false
                }
            }
        }
    }

    /// Unciv MainMenuScreen.quickstartNewGame: last setup, difficulty Chieftain, random nation, start at once.
    private func quickstart() {
        busy = true; loadError = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Unciv MainMenuScreen.quickstartNewGame passes Chieftain as the *default* difficulty, which
            // fromSettings applies only when there is no remembered setup - a remembered Immortal stays Immortal.
            var s = MainMenuView.setupForNewGame(defaultDifficulty: "Chieftain")
            // Deviation: Unciv's quickstart keeps a remembered online flag and starts a local game marked online that was
            // never uploaded (no game id here), so ours would fail its upload every turn - the quickstart game is local.
            s.isOnline = false
            // Unciv has no step making a seat human: with none, GameStarter's GameInfo.setTransients throws on
            // `civilizations.first { it.isHuman() }` (GameInfo.kt:779-783) and quickstartNewGame shows its toast - ours made
            // the first seat human and started
            if !s.players.isEmpty, !s.players.contains(where: { $0.isHuman }) {
                loadError = L("Cannot start game with the default new game parameters!"); busy = false; return
            }
            // A remembered custom-map setup cannot be quickstarted in Unciv: fromSettings copies it through
            // GameSetupInfo(setup), which leaves the @Transient mapFile null while mapParameters.name keeps the map's name,
            // so GameStarter's `MapSaver.loadMap(gameSetupInfo.mapFile!!)` throws and quickstartNewGame shows its toast -
            // ours loaded the remembered map again and started on it
            if s.mapMainType == "Custom" {
                loadError = L("Cannot start game with the default new game parameters!"); busy = false; return
            }
            // Unciv quickstartNewGame: a start that fails (GameStarter threw) is a toast on the main menu
            let state: GameState
            do { state = try GameState.newGame(settings: s) } catch { loadError = L("Cannot start game with the default new game parameters!"); busy = false; return }
            // (Unciv quickstartNewGame only calls game.loadGame, which writes no autosave - the first one comes with the
            // turn's end, the menu's Main menu or the app going to the background)
            busy = false
            GameEvents.post(.gameStarted(state, source: "quickstart"))
            onStart(state)
        }
    }
}
