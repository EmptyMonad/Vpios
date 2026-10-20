// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv NewGameScreen (portrait layout): "Game Options", "Mods", "Map Options" and "Civilizations" expanders, then "Start game!" and "Reset to defaults".
struct NewGameScreen: View {
    @State var settings: GameSettings
    let onStart: (GameState) -> Void
    let onClose: () -> Void
    @State private var openGame = true
    @State private var openMods = false
    @State private var openMap = true
    @State private var openCivs = true
    @State private var openAdvanced = false
    @State private var openMapAdvanced = false
    @State private var busy = false
    @State private var error: String? = nil
    @State private var customWidth = 44
    @State private var customHeight = 29
    @State private var customRadius = 20
    @State private var seedText = ""
    @State private var picker: OptionPicker? = nil
    // Map Options state (Unciv MapOptionsTable, MapParametersTable, MapFileSelectTable, ScenarioSelectTable)
    @State private var didAppear = false
    /// Unciv generatedMapOptionsTable.mapTypeSelectBox: restored into the map parameters when "Generated" is chosen again
    @State private var generatedMapType = "Pangaea"
    /// Unciv MultiCheckboxTable values of the "Random Generated" table: every box ticked on each new screen
    @State private var randomShapes: Set<String> = Set(NewGameScreen.mapShapes)
    @State private var randomTypes: Set<String> = Set(MapTypeInfo.generatedTypes)
    @State private var randomSizes: Set<String> = Set(NewGameScreen.worldSizeNames)
    @State private var randomResources: Set<String> = Set(NewGameScreen.resourceSettings)
    @State private var expanderOpen: [String: Bool] = NewGameExpanderMemory.open
    @State private var mapEntries: [MapFileEntry] = []
    @State private var scenarioEntries: [ScenarioEntry] = []
    @State private var mapCategory: String? = nil
    @State private var preselectedMapName: String? = nil
    @State private var failedMaps: Set<String> = []
    @State private var previewMap: GameMap? = nil
    @State private var previewDescription = ""
    @State private var mapNations: [String] = []
    @State private var mapHumanPick: String? = nil
    @State private var nationsFromMapUsed = false
    @State private var scenarioChoice: String? = nil
    /// Unciv NewGameScreen(defaultGameSetupInfo = null): opened on GameSetupInfo.fromSettings, the last game setup
    private let fromSettings: Bool
    /// Unciv GameOptionsTable.update / PlayerPickerTable.update rebuild their widgets from the parameters: a new id
    /// rebuilds ours (the duration boxes back on their defaults, the player ID fields on the stored IDs)
    @State private var gameOptionsRevision = 0
    @State private var playerTableRevision = 0
    /// Unciv NewGameScreen.startNewGame: GameStarter threw - the error's text for "Copy to clipboard"
    @State private var mapFailure: String? = nil
    /// The ruleset in use when the screen opened (the running game's, or the main menu's). Unciv's NewGameScreen fills its
    /// own `ruleset` (updateRuleset: RulesetCache.getComplexRuleset) and the game reads gameInfo.ruleset; ours is the shared one
    @State private var rulesetBeforeScreen: (base: String, mods: [String])? = nil
    /// A game went out of the screen (onStart): its own ruleset is the active one and stays so
    @State private var gameStarted = false

    init(initial: GameSettings, fromSettings: Bool = false, onStart: @escaping (GameState) -> Void, onClose: @escaping () -> Void) {
        var s = initial
        self.fromSettings = fromSettings
        // Unciv PlayerPickerTable init: "This is to stop people from getting other users' IDs and cheating with them in
        // multiplayer games" - every seat's player ID is wiped, and the shuffle box starts unticked - once per screen
        for i in s.players.indices { s.players[i].playerId = "" }
        s.shufflePlayerOrder = false
        // Unciv MapOptionsTable: mapParameters.type only ever holds a generated map type or "Custom", so a remembered
        // "Random Generated" or "Scenario" opens as "Generated" (and only "Custom" keeps a map name)
        if s.mapMainType == "Random Generated" || s.mapMainType == "Scenario" { s.mapMainType = "Generated" }
        if s.mapMainType != "Custom" { s.customMap = nil }
        // Unciv MapParameters.seed = System.currentTimeMillis() (fromSettings reseeds): the seed field always shows a seed
        if s.seed == 0 { s.seed = NewGameScreen.freshSeed() }
        s.godMode = false   // Unciv MapOptionsTable init runs updateOnMapTypeChange once
        _settings = State(initialValue: s); self.onStart = onStart; self.onClose = onClose
        let f = NewGameScreen.customSizeFields(s)
        _customWidth = State(initialValue: f.width); _customHeight = State(initialValue: f.height)
        _customRadius = State(initialValue: f.radius)
        _seedText = State(initialValue: NewGameScreen.seedString(s.seed))
        _generatedMapType = State(initialValue: s.mapType == "Inland Sea" ? "Inner Sea" : s.mapType)
    }

    private var rs: Ruleset { Ruleset.shared }

    /// One presented sheet at a time (several .sheet modifiers on a view that carries presentation modifiers lock SwiftUI into a layout loop).
    enum ActiveSheet: Identifiable, Hashable {
        case nationPicker(Int), nationsPool, options
        var id: Self { self }
    }
    @State private var activeSheet: ActiveSheet? = nil
    var body: some View {
        // Pickers are drawn as an in-place overlay: a .sheet attached inside this fullScreenCover locks SwiftUI into a layout loop on iOS 26.
        ZStack {
            base
            if let which = activeSheet {
                // Unciv Popup.getBehindClickListener: forbidPopupClickBehindToClose keeps the picker open
                Color.black.opacity(0.55).ignoresSafeArea().bleedIntoCutout().onTapGesture { if !UserSettings.neverCloseByTapOutside { activeSheet = nil } }
                Group {
                    switch which {
                    case .nationPicker(let i):
                        if i < settings.players.count {
                            NationPickerSheet(current: settings.players[i].chosenCiv, taken: Set(settings.players.enumerated().filter { $0.offset != i }.map { $0.element.chosenCiv }), allowSpectator: settings.players[i].isHuman,
                                          noRandom: settings.randomNumberOfPlayers && !settings.players[i].isHuman) { pick in
                                settings.players[i].chosenCiv = pick; activeSheet = nil
                                updatePlayerPicker()   // Unciv NationPickerPopup.returnSelected: playerPicker.update()
                            } onClose: { activeSheet = nil }
                        }
                    case .nationsPool: RandomNationsPoolSheet(pool: $settings.randomNationsPool, enabled: $settings.enableRandomNationsPool, onClose: { activeSheet = nil })
                    case .options: if let p = picker { OptionPickerSheet(picker: p, onClose: { activeSheet = nil }) }
                    }
                }
                .padding(.top, 40).padding(.horizontal, 6)
                .transition(.move(edge: .bottom))
            }
            if let failure = mapFailure {
                // Unciv NewGameScreen.startNewGame: the "Working..." popup reused for the failure, with "Copy to clipboard"
                // (the stack trace) and a close button; "Start game!" works again
                Color.black.opacity(0.55).ignoresSafeArea().bleedIntoCutout()
                Panel(highlighted: true) {
                    VStack(spacing: 10) {
                        Text(L("It looks like we can't make a map with the parameters you requested!")).font(Theme.heading(15)).foregroundStyle(Theme.cream).multilineTextAlignment(.center)
                        Text(L("Maybe you put too many players into too small a map?")).font(Theme.caption).foregroundStyle(Theme.creamDim).multilineTextAlignment(.center)
                        HStack(spacing: 10) {
                            Button(L("Copy to clipboard")) { UIPasteboard.general.string = failure }.buttonStyle(ThemedButtonStyle(compact: true))
                            Button(L("Close")) { mapFailure = nil }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                        }
                    }
                }
                .frame(maxWidth: 480).padding(20)
            }
        }
        .onAppear {
            if !didAppear {
                didAppear = true
                rulesetBeforeScreen = (Ruleset.currentBaseRuleset, Ruleset.shared.mods)
                // Unciv NewGameScreen init: a broken mod combination from the last setup falls back silently, then
                // tryUpdateRuleset builds the screen's ruleset from the setup ("must come before playerPickerTable"),
                // victory types it lacks are dropped (all of its victories when none is left), and PlayerPickerTable's
                // update fits the seats to it
                if fromSettings { resetIfInitialModsAreBroken() }
                tryUpdateRuleset()
                filterVictoryTypes()
                updatePlayerPicker()
                setUpMapOptions()
            }
        }
        // the screen taken away without its close button (the world screen it was pushed over replaced by the next turn,
        // UncivGame.loadGame's screenStack.clear()) drops its ruleset all the same
        .onDisappear { restoreRulesetBeforeScreen() }
        .screenShown("new_game")
    }
    /// Unciv NewGameScreen closeButton: `game.popScreen()` drops the screen with its own ruleset, so the rules the running
    /// game plays by never change; ours were the shared ones, so the ruleset from before the screen comes back
    /// (as MapEditorView.closeEditor). Starting a game needs no restore: GameStarter activates the new setup.
    private func close() {
        restoreRulesetBeforeScreen()
        onClose()
    }
    private func restoreRulesetBeforeScreen() {
        if !gameStarted, let r = rulesetBeforeScreen { Ruleset.activate(mods: r.mods, baseRuleset: r.base) }
    }
    /// onStart, with the new game's ruleset left active
    private func start(_ game: GameState) {
        gameStarted = true
        GameEvents.post(.gameStarted(game, source: settings.mapMainType == "Scenario" ? "scenario" : "new_game"))
        onStart(game)
    }
    private var base: some View {
        // Unciv's NewGameScreen has no title; the sheet's is the button that opens it ("Start new game")
        ThemedSheet(L("Start new game"), subtitle: nil, onClose: close) {
            // Unciv landscape NewGameScreen: Game Options | Map Options | Civilizations side by side.
            let mods = Ruleset.availableMods()
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 10) {
                    Expander(L("Game Options"), open: $openGame) { gameOptions }
                    if !mods.isEmpty { Expander(L("Mods"), open: $openMods) { modsTable(mods) }.comingSoon(alignment: .topTrailing, mods: true, place: "new_game") }
                }.frame(maxWidth: .infinity)
                VStack(spacing: 10) { Expander(L("Map Options"), open: $openMap) { mapOptions } }.frame(maxWidth: .infinity)
                VStack(spacing: 10) { Expander(L("Civilizations"), open: $openCivs) { civilizations } }.frame(maxWidth: .infinity)
            }
            if let e = error { Text(e).font(Theme.caption).foregroundStyle(Theme.danger) }
            HStack(spacing: 8) {
                // Unciv NewGameScreen: its own "Start game!" button, never disabled - PlayerPickerTable.update's
                // setRightSideButtonEnabled(isValid) only reaches pickerPane.rightSideButton, which was removed; what
                // cannot start is told by getErrorMessage (startGame below). Only a start in progress blocks it.
                Button { startGame() } label: { Label(L("Start game!"), systemImage: "play.fill") }.buttonStyle(ThemedButtonStyle(filled: true))
                    .disabled(busy)
                if UserSettings.lastGameSetup != nil {   // Unciv NewGameScreen: the reset button exists only with a remembered setup
                    Button(L("Reset to defaults")) { confirmReset = true }.buttonStyle(ThemedButtonStyle(compact: true))
                        .confirmationDialog(L("Are you sure you want to reset all game options to defaults?"), isPresented: $confirmReset, titleVisibility: .visible) { Button(L("Reset to defaults"), role: .destructive) { resetToDefaults() }; Button(L("Cancel"), role: .cancel) {} }   // Unciv NewGameScreen ConfirmPopup
                }
            }.padding(.top, 6)
            if busy { HStack { Spacer(); ProgressView().tint(Theme.gold); Text(L("Working...")).font(Theme.caption); Spacer() } }
        }
    }

    // MARK: Game Options (Unciv GameOptionsTable)
    private var gameOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Unciv GameOptionsTable.addBaseRulesetSelectBox
            if Ruleset.baseRulesets.count > 1 {
                selectRow(L("Base Ruleset"), value: settings.baseRuleset, options: Ruleset.baseRulesets) { chosen in
                    // Unciv onBaseRulesetSelected: the same choice does nothing; another goes through onChooseMod
                    guard chosen != settings.baseRuleset else { return }
                    settings.baseRuleset = chosen
                    chooseMod(chosen)
                }.newGameLocked(locked)
            }
            selectRow(L("Difficulty"), value: settings.difficulty, options: rs.difficulties.map { $0.name }) { settings.difficulty = $0 }.newGameLocked(locked)
            selectRow(L("Game Speed"), value: settings.speed, options: rs.speeds.map { $0.name }) { settings.speed = $0 }.newGameLocked(locked)
            // Unciv GameOptionsTable.addEraSelectBox: "Can only start games from the starting era" hides the choice (first era forced at setup).
            if !rs.modOptionUniques.contains(where: { $0.pattern == "Can only start games from the starting era" }) {
                selectRow(L("Starting Era"), value: settings.startingEra.isEmpty ? rs.ancientEra.name : settings.startingEra, options: rs.eras.map { $0.name }) { settings.startingEra = $0 }.newGameLocked(locked)
            }
            // Unciv addMaxTurnsSlider: only when a chosen victory enablesMaxTurns (a ScoreAfterTimeOut milestone); 100-1500 in
            // steps of 5, snapping within 125 to Unciv's values
            if rs.victories.contains(where: { settings.victoryTypes.contains($0.name) && $0.milestones.contains("Have highest score after max turns") }) {
                IntSliderRow(title: L("Max Turns"), value: settings.maxTurns, range: 100...1500, step: 5,
                             snapValues: [100, 150, 200, 250, 300, 350, 400, 450, 500, 550, 600, 650, 700, 750, 800, 900, 1000, 1250, 1500], snapThreshold: 125) { settings.maxTurns = $0 }.newGameLocked(locked)
            }
            // Unciv addCityStatesSlider: 0 to numberOfCityStates() (the city-states a new game may choose), and no slider
            // when there are none
            if !settings.randomNumberOfCityStates && numberOfCityStates > 0 {
                IntSliderRow(title: L("City-States"), value: settings.cityStateCount < 0 ? min(6, numberOfCityStates) : settings.cityStateCount, range: Int(0)...Int(numberOfCityStates)) { settings.cityStateCount = $0 }.newGameLocked(locked)
            }
            Text(L("Victory Conditions")).font(Theme.heading(14)).foregroundStyle(Theme.gold)
            // Unciv addVictoryTypeCheckboxes: ticking a victory that enablesMaxTurns rebuilds the table (update)
            FlowToggles(items: rs.victories.map { v in (L(v.name), settings.victoryTypes.contains(v.name), {
                if settings.victoryTypes.contains(v.name) { settings.victoryTypes.remove(v.name) } else { settings.victoryTypes.insert(v.name) }
                if v.milestones.contains("Have highest score after max turns") { rebuildGameOptions() }
            }) }).newGameLocked(locked)
            // Unciv lockTables: "Online Multiplayer" and the online timers are not lockable
            // Unciv addIsOnlineMultiplayerCheckbox: the flag, updatePlayerPickerTable(""), then update()
            checkbox(L("Online Multiplayer"), settings.isOnline) { settings.isOnline.toggle(); updatePlayerPicker(); rebuildGameOptions() }.comingSoon(place: "new_game")
            if settings.isOnline {
                checkbox(L("Allow anyone to spectate"), settings.anyoneCanSpectate) { settings.anyoneCanSpectate.toggle() }.newGameLocked(locked)
                // Unciv addDurationSelectBox(title, param, 1, 0, 0) / (3, 0, 0) / (3, 0, 0)
                DurationSelectorRow(title: L("Time until skip turn:"), defaultDays: 1, defaultHours: 0, defaultMinutes: 0, present: presentPicker) { settings.minutesUntilSkipTurn = $0 }
                DurationSelectorRow(title: L("Total time to play:"), defaultDays: 3, defaultHours: 0, defaultMinutes: 0, present: presentPicker) { settings.minutesUntilForceResign = $0 }
                DurationSelectorRow(title: L("Time recovered per turn:"), defaultDays: 3, defaultHours: 0, defaultMinutes: 0, present: presentPicker) { settings.minutesRecoveredPerTurn = $0 }
            }
            Expander(L("Advanced Settings"), open: $openAdvanced, compact: true) {
                VStack(alignment: .leading, spacing: 8) {
                    FlowToggles(items: [
                        (L("No City Razing"), settings.noCityRazing, { settings.noCityRazing.toggle() }),
                        (L("No Barbarians"), !settings.barbarians, { settings.barbarians.toggle() }),
                        (L("Raging Barbarians"), settings.ragingBarbarians, { settings.ragingBarbarians.toggle() }),
                        (L("One City Challenge"), settings.oneCityChallenge, { settings.oneCityChallenge.toggle() }),
                        (L("Enable Nuclear Weapons"), settings.nuclearWeaponsEnabled, { settings.nuclearWeaponsEnabled.toggle() }),
                        (L("Enable Espionage"), settings.espionageEnabled, { settings.espionageEnabled.toggle() }),
                        (L("Disable starting bias"), settings.noStartBias, { settings.noStartBias.toggle() }),
                        (L("Random number of Civilizations"), settings.randomNumberOfPlayers, { toggleRandomPlayers() }),
                        (L("Random number of City-States"), settings.randomNumberOfCityStates, { toggleRandomCityStates() }),
                        // Unciv addRandomNationsPoolCheckbox: update() to show the chooser button
                        (L("Set available nations for random pool"), settings.enableRandomNationsPool, { settings.enableRandomNationsPool.toggle(); rebuildGameOptions() }),
                    ]).newGameLocked(locked)
                    // Unciv addLinkedMinMaxSliders: nothing when the maximum is below the minimum
                    if settings.randomNumberOfPlayers && numberOfMajorCivs >= 2 {
                        // Unciv addMinMaxPlayersSliders: 2 to numberOfMajorCivs(); the two sliders push each other, min can never exceed max
                        IntSliderRow(title: L("Min number of Civilizations"), value: settings.minNumberOfPlayers, range: Int(2)...Int(numberOfMajorCivs)) { settings.minNumberOfPlayers = $0; if settings.maxNumberOfPlayers < $0 { settings.maxNumberOfPlayers = $0 } }.newGameLocked(locked)
                        IntSliderRow(title: L("Max number of Civilizations"), value: settings.maxNumberOfPlayers, range: Int(2)...Int(numberOfMajorCivs)) { settings.maxNumberOfPlayers = $0; if settings.minNumberOfPlayers > $0 { settings.minNumberOfPlayers = $0 } }.newGameLocked(locked)
                    }
                    if settings.randomNumberOfCityStates {
                        // Unciv addMinMaxCityStatesSliders: 0 to numberOfCityStates(); the two sliders push each other, min can never exceed max
                        IntSliderRow(title: L("Min number of City-States"), value: settings.minNumberOfCityStates, range: Int(0)...Int(numberOfCityStates)) { settings.minNumberOfCityStates = $0; if settings.maxNumberOfCityStates < $0 { settings.maxNumberOfCityStates = $0 } }.newGameLocked(locked)
                        IntSliderRow(title: L("Max number of City-States"), value: settings.maxNumberOfCityStates, range: Int(0)...Int(numberOfCityStates)) { settings.maxNumberOfCityStates = $0; if settings.minNumberOfCityStates > $0 { settings.minNumberOfCityStates = $0 } }.newGameLocked(locked)
                    }
                    if settings.enableRandomNationsPool {
                        Button(L("Select nations")) { activeSheet = .nationsPool }.buttonStyle(ThemedButtonStyle(compact: true))   // Unciv addNationsSelectTextButton
                    }
                    // Unciv addShowCivilizationStatsCheckbox: update() to show the stats boxes
                    checkbox(L("Show Civilization Stats"), settings.showCivilizationStats) { settings.showCivilizationStats.toggle(); rebuildGameOptions() }.newGameLocked(locked)
                    if settings.showCivilizationStats {
                        FlowToggles(items: [
                            (L("Show Demographics"), settings.showDemographics, { settings.showDemographics.toggle() }),
                            (L("Show Rankings"), settings.showRankings, { settings.showRankings.toggle() }),
                            (L("Show Charts"), settings.showCharts, { settings.showCharts.toggle() }),
                            (L("Restrict to own civilization"), settings.hideOtherCivilizationStats, { settings.hideOtherCivilizationStats.toggle() }),
                            (L("Show additional stat types"), settings.showAdditionalRankingTypes, { settings.showAdditionalRankingTypes.toggle() }),
                        ]).newGameLocked(locked)
                    }
                }
            }
        }
        .id(gameOptionsRevision)   // Unciv GameOptionsTable.update: clear() and every widget built again from the parameters
    }
    /// Unciv GameOptionsTable.update
    private func rebuildGameOptions() { gameOptionsRevision += 1 }
    /// The options picker overlay, for rows built outside this view (DurationSelectorRow)
    private func presentPicker(_ p: OptionPicker) { picker = p; activeSheet = .options }

    private func modsTable(_ mods: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Unciv ModCompatibility: only mods meeting the base requirements are listed; incompatible or unmet ones are disabled.
            ForEach(mods.filter { Ruleset.modMeetsBaseRequirements($0) }, id: \.self) { m in
                let selected = settings.mods.contains(m)
                let allowed = selected || Ruleset.modMeetsAllRequirements(m, selected: settings.mods + [m])
                // Unciv ModCheckboxTable.checkBoxChanged: the mod goes in or out, disableIncompatibleMods, then
                // onUpdate(mod) = GameOptionsTable.onChooseMod
                checkbox(m, selected) { if let i = settings.mods.firstIndex(of: m) { settings.mods.remove(at: i) } else { settings.mods.append(m) }; settings.mods = Ruleset.pruneModSelection(settings.mods); chooseMod(m) }
                    .disabled(!allowed).opacity(allowed ? 1 : 0.45)
            }
        }
    }

    // MARK: Map Options (Unciv MapOptionsTable / MapParametersTable / MapFileSelectTable / ScenarioSelectTable)
    private var mapOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            selectRow(L("Map Type"), value: settings.mapMainType, options: mapMainTypes) { changeMapMainType($0) }
            switch settings.mapMainType {
            case "Custom": customMapTable
            case "Scenario": scenarioTable
            case "Random Generated": randomMapTable
            default: generatedMapTable
            }
        }
    }
    /// Unciv MapOptionsTable: "Custom" only with a map to choose, "Scenario" only with a scenario file
    private var mapMainTypes: [String] {
        var types = ["Generated", "Random Generated"]
        if !mapEntries.isEmpty { types.append("Custom") }
        if !scenarioEntries.isEmpty { types.append("Scenario") }
        return types
    }
    /// Unciv NewGameScreen.lockTables: a scenario locks the game options and the player picker
    private var locked: Bool { settings.mapMainType == "Scenario" }

    /// Unciv MapParametersTable(MapGeneratedMainType.generated)
    @ViewBuilder private var generatedMapTable: some View {
        selectRow(L("Map Shape"), value: settings.mapShape, options: NewGameScreen.mapShapes) { settings.mapShape = $0; applySize() }
        selectRow(L("Map Generation Type"), value: settings.mapType == "Inland Sea" ? "Inner Sea" : settings.mapType, options: MapTypeInfo.generatedTypes) { settings.mapType = $0; generatedMapType = $0 }
        selectRow(L("World Size"), value: settings.mapSizeName, options: NewGameScreen.worldSizeNames + ["Custom"]) { settings.mapSizeName = $0; applySize() }
        if settings.mapSizeName == "Custom" { customSizeTable }
        selectRow(L("Resource Setting"), value: settings.resourceSetting == "Strategic Balance" ? "Default" : settings.resourceSetting, options: NewGameScreen.resourceSettings) { settings.resourceSetting = $0 }
        generatedCheckboxes
        mapAdvancedSettings
    }

    /// Unciv MapParametersTable.addHexagonalSizeTable / addRectangularSizeTable: free integer fields; the other
    /// shape's dimensions follow as Unciv's MapSize does (MapSize(radius) / MapSize(width, height))
    @ViewBuilder private var customSizeTable: some View {
        if settings.mapShape != "Rectangular" {
            sizeField(L("Radius"), value: customRadius) { r in
                customRadius = r; (customWidth, customHeight) = NewGameScreen.rectSize(r); applySize()
            }
            largeMapWarning(tiles: NewGameScreen.tilesInHexagon(customRadius))
        } else {
            sizeField(L("Width"), value: customWidth) { w in
                customWidth = w; customRadius = NewGameScreen.hexRadius(w, customHeight); applySize()
            }
            sizeField(L("Height"), value: customHeight) { h in
                customHeight = h; customRadius = NewGameScreen.hexRadius(customWidth, h); applySize()
            }
            largeMapWarning(tiles: customWidth &* customHeight)
        }
    }
    /// Unciv MapParametersTable.updateHexagonalWarnings / updateRectangularWarnings: LARGE_MAP_TILES 4000, VERY_LARGE_MAP_TILES 16000
    @ViewBuilder private func largeMapWarning(tiles: Int) -> some View {
        if tiles >= 16000 { Text(L("This is a very large map - may cause Out Of Memory crashes")).font(Theme.small).foregroundStyle(Theme.danger) }
        else if tiles >= 4000 { Text(L("This is a large map - may cause latency issues")).font(Theme.small).foregroundStyle(Theme.danger) }
    }
    private func sizeField(_ title: String, value: Int, onEdit: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title).font(Theme.caption).foregroundStyle(Theme.creamDim)
            Spacer()
            NewGameIntField(hint: title, value: value, onEdit: onEdit)
        }
    }

    /// Unciv MapParametersTable(MapGeneratedMainType.randomGenerated): the prompt, one expander of ticked boxes per option
    /// (a tick change picks at random among the ticked values - all of them when none is ticked - into the map
    /// parameters), "Other Settings" and the advanced settings
    @ViewBuilder private var randomMapTable: some View {
        Text(L("Which options should be available to the random selection?")).font(Theme.caption).foregroundStyle(Theme.creamDim)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        randomOptions("Enabled Map Shapes", id: "NewGameMapShapes", values: NewGameScreen.mapShapes, checked: randomShapes) { v in
            NewGameScreen.flip(&randomShapes, v)
            settings.mapShape = NewGameScreen.randomPick(randomShapes, all: NewGameScreen.mapShapes) ?? settings.mapShape
            applySize()
        }
        randomOptions("Enabled Map Generation Types", id: "NewGameMapGenerationTypes", values: MapTypeInfo.generatedTypes, checked: randomTypes) { v in
            NewGameScreen.flip(&randomTypes, v)
            settings.mapType = NewGameScreen.randomPick(randomTypes, all: MapTypeInfo.generatedTypes) ?? settings.mapType
        }
        randomOptions("Enabled World Sizes", id: "NewGameWorldSizes", values: NewGameScreen.worldSizeNames, checked: randomSizes) { v in
            NewGameScreen.flip(&randomSizes, v)
            settings.mapSizeName = NewGameScreen.randomPick(randomSizes, all: NewGameScreen.worldSizeNames) ?? settings.mapSizeName
            applySize()
        }
        randomOptions("Enabled Resource Settings", id: "NewGameResourceSettings", values: NewGameScreen.resourceSettings, checked: randomResources) { v in
            NewGameScreen.flip(&randomResources, v)
            settings.resourceSetting = NewGameScreen.randomPick(randomResources, all: NewGameScreen.resourceSettings) ?? settings.resourceSetting
        }
        Expander(L("Other Settings"), open: remembered("NewGameOtherSettings"), compact: true) { generatedCheckboxes }
        mapAdvancedSettings
    }
    /// Unciv MultiCheckboxTable: the boxes in the order of the HashSet they were built from, all ticked at first
    private func randomOptions(_ title: String, id: String, values: [String], checked: Set<String>, onToggle: @escaping (String) -> Void) -> some View {
        let order = NewGameScreen.javaHashOrder(values, capacity: NewGameScreen.kotlinHashSetCapacity(values.count))
        return Expander(L(title), open: remembered(id), compact: true) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(order, id: \.self) { v in checkbox(L(v), checked.contains(v)) { onToggle(v) } }
            }
        }
    }
    /// Unciv ExpanderTab persistenceID: the open state is remembered while the app runs
    private func remembered(_ id: String) -> Binding<Bool> {
        Binding(get: { expanderOpen[id] ?? false }, set: { expanderOpen[id] = $0; NewGameExpanderMemory.open[id] = $0 })
    }

    /// Unciv MapParametersTable.addWrappedCheckBoxes: World Wrap stands with the other checkboxes on every shape and map type.
    private var generatedCheckboxes: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowToggles(items: [
                (L("Strategic Balance"), settings.strategicBalance, { settings.strategicBalance.toggle() }),
                (L("Legendary Start"), settings.legendaryStart, { settings.legendaryStart.toggle() }),
                (L("No Ancient Ruins"), !settings.ancientRuins, { settings.ancientRuins.toggle() }),
                (L("No Natural Wonders"), !settings.naturalWonders, { settings.naturalWonders.toggle() }),
                (L("World Wrap"), settings.worldWrap, { settings.worldWrap.toggle() }),   // Unciv addWrappedCheckBoxes: on every shape
            ])
            // Unciv addWrappedCheckBoxes: the warning always stands under the checkboxes
            Text(L("World wrap maps are very memory intensive - creating large world wrap maps on Android can lead to crashes!")).font(Theme.small).foregroundStyle(Theme.creamDim)
        }
    }

    /// Unciv MapParametersTable.addAdvancedSettings / addAdvancedControls: the seed, then sliders whose step is a
    /// twentieth of the range unless given, and "Reset to defaults"
    private var mapAdvancedSettings: some View {
        Expander(L("Advanced Settings"), open: $openMapAdvanced, compact: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("RNG Seed")).font(Theme.caption).foregroundStyle(Theme.creamDim)
                    TextField(L("RNG Seed"), text: $seedText).textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation).font(Theme.caption)
                        .onChange(of: seedText) { _, v in settings.seed = NewGameScreen.parseSeed(v) ?? 0 }
                }
                sliderRow(L("Map Elevation"), value: $settings.elevationExponent, range: 0.6...0.8, step: 0.01, format: NewGameScreen.tip2)
                sliderRow(L("Temperature intensity"), value: $settings.temperatureIntensity, range: 0.4...0.8, step: 0.02, format: NewGameScreen.tip2)
                sliderRow(L("Temperature shift"), value: $settings.temperatureShift, range: -0.4...0.4, step: 0.1, format: NewGameScreen.tip1)
                sliderRow(L("Vegetation richness"), value: $settings.vegetationRichness, range: 0...1, step: 0.05, format: NewGameScreen.tip2)
                sliderRow(L("Rare features richness"), value: $settings.rareFeaturesRichness, range: 0...0.5, step: 0.025, format: NewGameScreen.tip2)
                IntSliderRow(title: L("Max Coast extension"), value: settings.maxCoastExtension, range: Int(1)...Int(5)) { settings.maxCoastExtension = $0 }
                IntSliderRow(title: L("Biome size"), value: settings.tilesPerBiomeArea, range: Int(1)...Int(15)) { settings.tilesPerBiomeArea = $0 }
                sliderRow(L("Water level"), value: $settings.waterThreshold, range: -0.1...0.1, step: 0.01, format: NewGameScreen.tip2)
                Button(L("Reset to defaults")) { resetMapAdvanced() }.buttonStyle(ThemedButtonStyle(compact: true))
            }
        }
    }

    /// Unciv MapFileSelectTable: "Map Mod" and "Map file", the players button, the map's description and its preview
    @ViewBuilder private var customMapTable: some View {
        let files = mapFiles(in: mapCategory ?? "")
        let current = mapEntries.first { $0.id == settings.customMap }
        selectRow(L("Map Mod"), value: mapCategory ?? "", options: mapCategories) { pick in mapCategory = pick; categoryChanged() }
        selectRow(L("Map file"), value: current?.name ?? "", options: files.map(\.name)) { pick in
            if let e = files.first(where: { $0.name == pick }) { selectMapFile(e) }
        }
        if !mapNations.isEmpty {
            Button(L("Select players from starting locations")) { useNationsFromMap() }
                .buttonStyle(ThemedButtonStyle(compact: true)).disabled(nationsFromMapUsed)
        }
        if !previewDescription.isEmpty { Text(previewDescription).font(Theme.caption).foregroundStyle(Theme.cream) }
        if let m = previewMap { NewGameMapPreview(map: m, side: 240).frame(maxWidth: .infinity).transition(.opacity) }
    }
    /// Unciv MapFileSelectTable.addAsyncEntryToSelectBoxes: the current base ruleset first, then by name
    private var mapCategories: [String] {
        let top = settings.baseRuleset
        return Array(Set(mapEntries.map(\.category))).sorted { a, b in
            if (a == top) != (b == top) { return a == top }
            return LocaleCode.compare(a, b) == .orderedAscending
        }
    }
    /// Unciv onCategorySelectBoxChange: the category's maps by name (a map whose mods failed to load is dropped)
    private func mapFiles(in category: String) -> [MapFileEntry] {
        mapEntries.filter { $0.category == category && !failedMaps.contains($0.id) }
            .sorted { LocaleCode.compare($0.name, $1.name) == .orderedAscending }
    }

    /// Unciv ScenarioSelectTable: the scenario names sorted, no label
    private var scenarioTable: some View {
        let names = scenarioEntries.map(\.name).sorted()
        return Button {
            picker = OptionPicker(title: L("Scenario"), options: names, selected: scenarioChoice ?? "", onPick: { pick in scenarioChoice = pick; selectScenario() })
            activeSheet = .options
        } label: {
            HStack(spacing: 4) { Text(L(scenarioChoice ?? "")).font(Theme.caption.bold()).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                .padding(.horizontal, 10).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelDark)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.gold, lineWidth: 1))
        }.buttonStyle(.plain).frame(maxWidth: .infinity)
    }

    // MARK: Civilizations (Unciv PlayerPickerTable)
    private var civilizations: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Unciv PlayerPickerTable init: the box starts unticked (the flag is cleared once, in init above) and only its
            // listener writes it afterwards
            checkbox(L("Shuffle Civ Order at Start"), settings.shufflePlayerOrder) { settings.shufflePlayerOrder.toggle() }
            ForEach(Array(settings.players.enumerated()), id: \.element.id) { i, p in
                VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button { activeSheet = .nationPicker(i) } label: {
                        HStack(spacing: 8) {
                            if p.chosenCiv == "Random" { Text("?").font(Theme.title(18)).foregroundStyle(Theme.gold).frame(width: 36, height: 36).background(Circle().fill(Theme.panelDark)).overlay(Circle().stroke(Theme.hairline, lineWidth: 1)) }
                            else { NationBadge(nation: rs.nations[p.chosenCiv], size: 36) }
                            Text(p.chosenCiv == "Random" ? L("Random") : p.chosenCiv).font(Theme.heading(15)).foregroundStyle(Theme.cream).lineLimit(1)
                        }
                    }.buttonStyle(.plain)
                    .disabled(locked)   // Unciv PlayerPickerTable: a locked table ignores the nation click
                    Spacer()
                    // Unciv updatePlayerTypeButtonEnabled: an AI may always become human; a human spectator, or a human Random
                    // seat while the number of players is random, cannot become AI
                    Button(p.isHuman ? L("Human") : L("AI")) { settings.players[i].isHuman.toggle(); if !settings.players[i].isHuman { settings.players[i].playerId = "" }; updatePlayerPicker() }.buttonStyle(ThemedButtonStyle(filled: p.isHuman, compact: true))
                        .disabled(p.isHuman && (p.chosenCiv == "Spectator" || (settings.randomNumberOfPlayers && p.chosenCiv == "Random")))
                    if !locked {   // Unciv PlayerPickerTable: no remove button while locked
                        Button { settings.players.remove(at: i); updatePlayerPicker() } label: { Image(systemName: "minus") }.buttonStyle(ThemedButtonStyle(destructive: true, compact: true))
                    }
                }
                // Unciv getPlayerTable: an online game's human seat gets addPlayerTableMultiplayerControls under it
                if p.isHuman && settings.isOnline {
                    PlayerIdControls(playerId: Binding(get: { settings.players.first { $0.id == p.id }?.playerId ?? "" },
                                                       set: { v in if let k = settings.players.firstIndex(where: { $0.id == p.id }) { settings.players[k].playerId = v } }),
                                     onFriends: UserSettings.friends.isEmpty ? nil : { popupFriendPicker(p.id) })
                        .id("\(p.id.uuidString)-\(playerTableRevision)")   // rebuilt with the table: the field shows the stored ID again
                }
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelDark.opacity(0.6))).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
            }
            // Unciv updateRandomNumberLabel, in gold under the players
            if settings.randomNumberOfPlayers {
                let range = settings.minNumberOfPlayers == settings.maxNumberOfPlayers ? "\(settings.minNumberOfPlayers)" : "\(settings.minNumberOfPlayers) - \(settings.maxNumberOfPlayers)"
                let explicit = settings.players.count == 1 ? L("The number of players will be adjusted") : L("These [\(settings.players.count)] players will be adjusted")
                Text(L("[\(explicit)] to [\(range)] actual players by adding random AI's or by randomly omitting AI's.")).font(Theme.small).foregroundStyle(Theme.gold).frame(maxWidth: .infinity)
            }
            // Unciv: players up to the choosable nations (majors and the spectator), and no add button while locked
            if !locked && settings.players.count < playableCivs {
                Button {
                    // Unciv PlayerPickerTable: with a random number of players, a new seat gets the first nation still free,
                    // else a human spectator; otherwise a random AI
                    if settings.randomNumberOfPlayers {
                        let taken = Set(settings.players.map { $0.chosenCiv })
                        if let civ = rs.majorNations.first(where: { !taken.contains($0.name) && !$0.uniques.contains("Will not be chosen for new games") })?.name {
                            settings.players.append(PlayerSetup(chosenCiv: civ, isHuman: false))
                        } else { settings.players.append(PlayerSetup(chosenCiv: "Spectator", isHuman: true)) }
                    } else { settings.players.append(PlayerSetup()) }
                    updatePlayerPicker()
                } label: { Image(systemName: "plus").font(.system(size: 18, weight: .bold)).foregroundStyle(Color(white: 0.2)).frame(width: 50, height: 50).background(Circle().fill(Color.white)) }.buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: actions
    private func applySize() {
        if settings.mapSizeName == "Custom" {
            if settings.mapShape != "Rectangular" { settings.mapWidth = customRadius * 2 + 1; settings.mapHeight = customRadius * 2 + 1 }
            else { settings.mapWidth = customWidth; settings.mapHeight = customHeight }
        } else if let p = MapSizePreset(rawValue: settings.mapSizeName) {
            if settings.mapShape != "Rectangular" { settings.mapWidth = p.radius * 2 + 1; settings.mapHeight = p.radius * 2 + 1 } else { settings.mapWidth = p.width; settings.mapHeight = p.height }
        }
    }
    /// Unciv MapSize.fixUndesiredSizes, for a custom size of a generated map: an odd width is rounded down silently for
    /// world wrap; too narrow for world wrap, too small, too big or too stretched sets a fitting radius and is reported
    /// (getErrorMessage then writes the new radius, width and height back into the fields). World wrap counts on every
    /// shape, a hexagonal map's width being its MapSize(radius)'s equivalent rectangular one.
    private func fixUndesiredSizes() -> String? {
        guard settings.mapMainType != "Custom", settings.mapSizeName == "Custom" else { return nil }
        let rectangular = settings.mapShape == "Rectangular"
        let worldWrap = settings.worldWrap
        if !rectangular { (customWidth, customHeight) = NewGameScreen.rectSize(customRadius) }
        if worldWrap && customWidth % 2 != 0 { customWidth -= 1 }
        let (w, h) = (customWidth, customHeight)
        let r = rectangular ? NewGameScreen.hexRadius(customWidth, customHeight) : customRadius
        let message: String
        if worldWrap && w < 32 { message = "World wrap requires a minimum width of 32 tiles" }
        else if w < 3 || h < 3 || r < 2 { message = "The provided map dimensions were too small" }
        else if r > 500 { message = "The provided map dimensions were too big" }
        else if h &* 16 < w || w &* 16 < h { message = "The provided map dimensions had an unacceptable aspect ratio" }
        else { applySize(); return nil }
        let newRadius = r < 2 ? 2 : r > 500 ? 500 : (worldWrap && r < 15 ? 15 : r)
        customRadius = newRadius
        (customWidth, customHeight) = NewGameScreen.rectSize(newRadius)
        applySize()
        return message
    }
    /// Unciv addRandomPlayersCheckbox: switching on drops the random AI seats, switching off fills random AI seats up to
    /// the minimum number
    private func toggleRandomPlayers() {
        settings.randomNumberOfPlayers.toggle()
        if settings.randomNumberOfPlayers {
            settings.players.removeAll { !$0.isHuman && $0.chosenCiv == "Random" }
            updatePlayerPicker()
        } else {
            let additionalRandom = settings.minNumberOfPlayers - settings.players.count
            if additionalRandom > 0 {
                for _ in 0..<additionalRandom { settings.players.append(PlayerSetup()) }
                updatePlayerPicker()
            }
        }
        rebuildGameOptions()   // Unciv: update() "To see the new sliders"
    }
    /// Unciv addRandomCityStatesCheckbox: the fixed number widens the range when switching on, and is clamped into it when
    /// switching off
    private func toggleRandomCityStates() {
        settings.randomNumberOfCityStates.toggle()
        let fixed = settings.cityStateCount < 0 ? min(6, numberOfCityStates) : settings.cityStateCount
        if settings.randomNumberOfCityStates {
            if fixed > settings.maxNumberOfCityStates { settings.maxNumberOfCityStates = fixed }
            if fixed < settings.minNumberOfCityStates { settings.minNumberOfCityStates = fixed }
        } else {
            settings.cityStateCount = min(max(fixed, settings.minNumberOfCityStates), settings.maxNumberOfCityStates)
        }
        rebuildGameOptions()   // Unciv: update() "To see the changed sliders"
    }
    /// Unciv MapParameters.resetAdvancedSettings: a new seed (shown in the field) and the generator defaults
    private func resetMapAdvanced() {
        let d = GameSettings()
        settings.elevationExponent = d.elevationExponent; settings.temperatureIntensity = d.temperatureIntensity; settings.temperatureShift = d.temperatureShift
        settings.vegetationRichness = d.vegetationRichness; settings.rareFeaturesRichness = d.rareFeaturesRichness; settings.waterThreshold = d.waterThreshold
        settings.maxCoastExtension = d.maxCoastExtension; settings.tilesPerBiomeArea = d.tilesPerBiomeArea
        settings.seed = NewGameScreen.freshSeed(); seedText = NewGameScreen.seedString(settings.seed)
    }
    @State private var confirmReset = false
    /// Unciv "Reset to defaults": a fresh GameSetupInfo() with espionage on - no mods, the default base ruleset, a
    /// hexagonal Medium pangaea, six city-states and every selectable victory - in a new screen, so the map tables
    /// start over too
    private func resetToDefaults() {
        var d = GameSettings()
        d.mods = []
        d.espionageEnabled = true
        d.mapShape = "Hexagonal"
        d.mapSizeName = "Medium"
        d.cityStateCount = 6
        d.seed = NewGameScreen.freshSeed()
        // the new screen's init: tryUpdateRuleset on the defaults, then every selectable victory of that ruleset
        if d.baseRuleset != settings.baseRuleset || !settings.mods.isEmpty { Ruleset.activate(mods: [], baseRuleset: d.baseRuleset) }
        d.victoryTypes = Set(rs.victories.map(\.name))
        settings = d; seedText = NewGameScreen.seedString(d.seed)
        let f = NewGameScreen.customSizeFields(d)
        customRadius = f.radius; customWidth = f.width; customHeight = f.height
        generatedMapType = d.mapType
        randomShapes = Set(NewGameScreen.mapShapes); randomTypes = Set(MapTypeInfo.generatedTypes)
        randomSizes = Set(NewGameScreen.worldSizeNames); randomResources = Set(NewGameScreen.resourceSettings)
        mapCategory = nil; preselectedMapName = nil; failedMaps = []; previewMap = nil; previewDescription = ""
        mapNations = []; mapHumanPick = nil; nationsFromMapUsed = false
        scenarioChoice = NewGameScreen.javaHashMapFirst(scenarioEntries.map(\.name))
        applySize()
        updatePlayerPicker(); rebuildGameOptions()   // the new screen's PlayerPickerTable and GameOptionsTable
    }

    private func startGame() {
        error = nil
        // Unciv NewGameScreen.getErrorMessage, in its order: a human (not only a spectator online), a victory type, the map
        if !settings.players.contains(where: { $0.isHuman && !($0.chosenCiv == "Spectator" && settings.isOnline) }) { error = L("No human players selected!"); return }
        if settings.victoryTypes.isEmpty { error = L("No victory conditions were selected!"); return }
        if settings.mapMainType == "Custom" && settings.customMap == nil { settings.customMap = MapStore.list().first }
        if settings.mapMainType == "Custom" {
            let map = settings.customMap.flatMap { NewGameScreen.loadMapQuietly($0) }
            Ruleset.activate(mods: settings.mods, baseRuleset: settings.baseRuleset)   // loading an Unciv map activates its own ruleset
            guard let map else { error = L("Could not load map"); return }
            let problems = NewGameScreen.rulesetIncompatibilities(map)
            if !problems.isEmpty { error = L("Map is incompatible with the chosen ruleset!") + "\n" + problems.map { L($0) }.joined(separator: "\n"); return }
        }
        if let message = fixUndesiredSizes() { error = L(message); return }
        if settings.mapMainType == "Scenario" { startScenario(); return }
        if settings.mapSizeName != "Custom" || settings.mapMainType != "Generated" { applySize() }
        busy = true
        var s = settings
        // Unciv: "Random Generated" only picks into the map parameters when a box is ticked; the game is generated from
        // the map parameters as they are, and they are remembered as a generated map
        if s.mapMainType == "Random Generated" { s.mapMainType = "Generated" }
        // (lastGameSetup is written by GameState.newGame once the start succeeded, as Unciv's GameStarter does)
        if s.isOnline {
            Task {
                // Unciv NewGameScreen.getErrorMessage for an online game: the server answers, every human seat has a valid
                // player ID, and without "Allow anyone to spectate" we must hold one of the seats
                if !(await Multiplayer.isAlive()) { error = L("Couldn't connect to Multiplayer Server!"); busy = false; return }
                // `IdChecker.checkAndReturnPlayerUuid(player.playerId)?.playerID?.isUUID()` for every human seat
                if s.players.contains(where: { $0.isHuman && !IdChecker.isValidPlayerId($0.playerId) }) { error = L("Invalid player ID!"); busy = false; return }
                if !s.anyoneCanSpectate && !s.players.contains(where: { $0.playerId == Multiplayer.userId }) { error = L("You are not allowed to spectate!"); busy = false; return }
                do {
                    var online = s; online.humanPlayers = max(2, online.players.filter { $0.isHuman }.count)
                    let st = try await Multiplayer.create(settings: online)
                    try? SaveManager.save(st, name: "online-\(st.settings.gameId ?? "")")
                    // Unciv NewGameScreen.startNewGame: an online game falls through to `game.loadGame(newGame)` and
                    // `worldScreen.autoSave()` too (after its own plain requestAutoSave) - the numbered turn-0 copy included
                    SaveManager.autosave(st, nextTurn: true)
                    busy = false
                    // Unciv startNewGame after game.loadGame: "Save gameId to clipboard because you have to do it anyway",
                    // and a toast on the world screen says so
                    UIPasteboard.general.string = st.settings.gameId
                    GameController.pendingToast = "Game ID copied to clipboard!"
                    start(st)
                } catch let failure as Multiplayer.GameStartFailure {
                    mapFailure = failure.description; busy = false   // GameStarter threw before anything was uploaded
                } catch {
                    // Unciv: FileStorageRateLimitReached ("Server limit reached! ...") comes only from Dropbox storage; our
                    // UncivServer upload fails every other way, as "Could not upload game!"
                    self.error = L("Could not upload game!"); busy = false
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Unciv startNewGame: GameStarter throwing shows the map failure and "Start game!" works again
            let state: GameState
            do { state = try GameState.newGame(settings: s) } catch { mapFailure = String(describing: error); busy = false; return }
            // Unciv NewGameScreen.startNewGame: `game.loadGame(newGame)` then `worldScreen.autoSave()`, which is
            // `requestAutoSave(gameInfo, true)` - the numbered "Autosave-<civ>-0" and purgeOldAutosaves as after a turn
            SaveManager.autosave(state, nextTurn: true)
            busy = false
            start(state)
        }
    }

    /// Unciv NewGameScreen.startNewGame with a scenario: the saved game itself (the last game setup is not remembered)
    private func startScenario() {
        // Unciv startNewGame's catch: any failure, the scenario's loadGameFromFile among them, reuses the "Working..." popup
        // for "It looks like we can't make a map..." with the exception for "Copy to clipboard" (mapFailure)
        guard let entry = scenarioEntries.first(where: { $0.name == scenarioChoice }) else { mapFailure = "FileNotFoundException: \(scenarioChoice ?? "")"; return }
        do {
            let st = try SaveManager.load(data: Data(contentsOf: entry.url))
            assignScenarioPlayers(st)
            SaveManager.autosave(st, nextTurn: true)   // Unciv: the scenario goes through the same startNewGame tail, worldScreen.autoSave()
            start(st)
        } catch { mapFailure = "\(error)" }
    }
    /// Unciv NewGameScreen.startNewGame: the Spectator leaves the scenario and every civilization becomes AI; then the
    /// players take their type - explicit nation choices first, then each "Random" seat a random major civilization
    /// still free
    private func assignScenarioPlayers(_ st: GameState) {
        let spectators = Set(st.civs.filter { $0.isSpectator }.map(\.id))
        st.civs.removeAll { $0.isSpectator }
        for i in st.civs.indices {
            st.civs[i].isPlayer = false
            st.civs[i].metCivs.subtract(spectators); st.civs[i].metOrder.removeAll { spectators.contains($0) }
        }
        var pool = st.civs.filter { $0.isMajor }.map(\.nation)
        let players = settings.players.filter { $0.chosenCiv != "Spectator" }
        for p in players where p.chosenCiv != "Random" {
            guard let i = st.civs.firstIndex(where: { $0.nation == p.chosenCiv }) else { continue }
            st.civs[i].isPlayer = p.isHuman; pool.removeAll { $0 == p.chosenCiv }
        }
        for p in players where p.chosenCiv == "Random" {
            guard let nation = pool.randomElement(), let i = st.civs.firstIndex(where: { $0.nation == nation }) else { continue }
            st.civs[i].isPlayer = p.isHuman; pool.removeAll { $0 == nation }
        }
    }

    // MARK: map options actions
    /// Unciv MapOptionsTable init: the map and scenario lists; a remembered "Custom" stays only with a map to choose
    private func setUpMapOptions() {
        mapEntries = NewGameScreen.loadMapEntries()
        scenarioEntries = NewGameScreen.loadScenarioEntries()
        // Unciv ScenarioSelectTable: the select box starts on the first key of its HashMap
        scenarioChoice = NewGameScreen.javaHashMapFirst(scenarioEntries.map(\.name))
        if settings.mapMainType == "Custom" {
            if mapEntries.isEmpty { settings.mapMainType = "Generated"; settings.customMap = nil } else { activateCustomMaps() }
        }
    }
    /// Unciv MapOptionsTable.updateOnMapTypeChange
    private func changeMapMainType(_ type: String) {
        settings.mapMainType = type
        switch type {
        case "Custom": activateCustomMaps()
        case "Scenario": settings.customMap = nil; selectScenario()
        case "Random Generated": settings.customMap = nil
        default: settings.customMap = nil; settings.mapType = generatedMapType
        }
        settings.godMode = false
        updateTables()
    }
    /// Unciv NewGameScreen.updateTables: playerPickerTable.update(), then the game options table rebuilt
    private func updateTables() { updatePlayerPicker(); rebuildGameOptions() }
    /// Unciv MapFileSelectTable.activateCustomMaps: the maps are read afresh; the category is the newest map's the first
    /// time and the previous one afterwards; a map is preselected by the name chosen before (none after another type)
    private func activateCustomMaps() {
        mapEntries = NewGameScreen.loadMapEntries()
        failedMaps = []
        preselectedMapName = settings.customMap.flatMap { id in mapEntries.first { $0.id == id }?.name }
        if mapCategory == nil || !mapEntries.contains(where: { $0.category == mapCategory }) { mapCategory = mapEntries.first?.category }
        categoryChanged()
    }
    /// Unciv MapFileSelectTable.onCategorySelectBoxChange / getPreselect: the mod's "Mod preselects map [file]", else a
    /// map saved in the last quarter hour (unless all were written at once, like a mod unzip), else the map chosen
    /// before, else the first
    private func categoryChanged() {
        guard let category = mapCategory else { return }
        let files = mapFiles(in: category)
        guard let first = files.first else { return }
        var pick: MapFileEntry? = nil
        if let preset = Ruleset.modOptionUniques(of: category).first(where: { $0.pattern == "Mod preselects map []" })?.param(0) {
            pick = files.first { $0.name == preset }
        } else {
            let recent = files.filter { $0.modified > Date().addingTimeInterval(-900) }.max { $0.modified < $1.modified }
            let oldest = files.map(\.modified).min() ?? .distantPast
            if let r = recent, r.modified.timeIntervalSince(oldest) > 0.1 { pick = r } else if files.count == 1 { pick = first }
        }
        if pick == nil, let name = preselectedMapName { pick = files.first { $0.name == name } }
        selectMapFile(pick ?? first)
    }
    /// Unciv MapFileSelectTable.onFileSelectBoxChange: the map's base ruleset and mods replace the chosen ones unless
    /// those already satisfy it; its major nations with a player or human starting location offer "Select players from
    /// starting locations"; a map whose ruleset cannot be loaded resets the options and leaves the list
    private func selectMapFile(_ entry: MapFileEntry) {
        let info = NewGameScreen.mapFileInfo(entry)
        let required = info.mods.filter { !Ruleset.baseRulesets.contains($0) }
        let mapBase = info.mods.first { Ruleset.baseRulesets.contains($0) } ?? info.baseRuleset
        var success = true
        if settings.baseRuleset != mapBase || !required.allSatisfy({ settings.mods.contains($0) }) {
            settings.mods = required; settings.baseRuleset = mapBase
            success = tryUpdateRuleset()
        }
        let custom = success ? NewGameScreen.loadMapQuietly(entry.id) : nil
        Ruleset.activate(mods: settings.mods, baseRuleset: settings.baseRuleset)   // loading an Unciv map activates its own ruleset
        let majors = Set(Ruleset.shared.majorNations.map(\.name))
        let declared = (custom?.startingLocations ?? []).filter { $0.usage != .normal }
        mapNations = NewGameScreen.distinct(declared.map(\.nation)).filter { majors.contains($0) }
        mapHumanPick = NewGameScreen.distinct(declared.filter { $0.usage == .human }.map(\.nation)).filter { majors.contains($0) }.randomElement()
        nationsFromMapUsed = false
        settings.customMap = entry.id
        updateTables()   // Unciv onFileSelectBoxChange: newGameScreen.updateTables() before the preview
        previewMap = custom?.map
        previewDescription = custom == nil ? "" : info.description
        if !success {
            failedMaps.insert(entry.id)
            if let next = mapFiles(in: entry.category).first { selectMapFile(next) }
        }
    }
    /// Unciv NewGameScreen.tryUpdateRuleset: a base ruleset or mod that cannot be loaded resets them to the defaults
    @discardableResult private func tryUpdateRuleset() -> Bool {
        let installed = Set(Ruleset.availableMods())
        if Ruleset.baseRulesets.contains(settings.baseRuleset) && settings.mods.allSatisfy({ installed.contains($0) }) {
            Ruleset.activate(mods: settings.mods, baseRuleset: settings.baseRuleset)
            return true
        }
        error = L("Your previous options needed to be reset to defaults.")
        settings.mods = []; settings.baseRuleset = Ruleset.baseRulesetName
        Ruleset.activate(mods: [], baseRuleset: Ruleset.baseRulesetName)
        return false
    }
    /// Unciv NewGameScreen.resetIfInitialModsAreBroken (only for a screen opened on the last game setup): a mod
    /// combination that is broken falls back to Gods & Kings without mods, silently. Unciv asks checkCombinedModLinks
    /// for Error severity; we have no RulesetErrorList, so "broken" is what our loader can tell - a mod no longer
    /// installed, or a combination that does not load.
    private func resetIfInitialModsAreBroken() {
        if settings.mods.isEmpty { return }
        let installed = Set(Ruleset.availableMods())
        let base = Ruleset.baseRulesets.contains(settings.baseRuleset) ? settings.baseRuleset : Ruleset.baseRulesetName
        if settings.mods.allSatisfy({ installed.contains($0) }), (try? Ruleset(named: base, mods: settings.mods)) != nil { return }
        settings.mods = []
        settings.baseRuleset = Ruleset.baseRulesetName
    }
    /// Unciv NewGameScreen init / GameOptionsTable.reloadRuleset: "remove the victory types which are not in the rule
    /// set", and every selectable victory when none is left
    private func filterVictoryTypes() {
        let names = rs.victories.map(\.name)
        settings.victoryTypes = settings.victoryTypes.filter { names.contains($0) }
        if settings.victoryTypes.isEmpty { settings.victoryTypes = Set(names) }
    }
    /// Unciv GameOptionsTable.numberOfMajorCivs: the major nations without "Will not be chosen for new games"
    private var numberOfMajorCivs: Int { rs.majorNations.filter { !$0.uniques.contains("Will not be chosen for new games") }.count }
    /// Unciv GameOptionsTable.numberOfCityStates: the city-states without "Will not be chosen for new games"
    private var numberOfCityStates: Int { rs.cityStateNations.filter { !$0.uniques.contains("Will not be chosen for new games") }.count }
    /// Unciv PlayerPickerTable.update newRulesetPlayableCivs: the nations a seat may take - `(isMajorCiv || isSpectator)
    /// && !hasUnique(WillNotBeChosenForNewGames)`
    private var playableCivs: Int {
        numberOfMajorCivs + (rs.nations["Spectator"].map { $0.uniques.contains("Will not be chosen for new games") ? 0 : 1 } ?? 0)
    }
    /// Unciv GameOptionsTable.onChooseMod (a base ruleset chosen, or a mod ticked or unticked): reloadRuleset; a mod
    /// just ticked picks one of its own major nations as the desired civ and plays its theme (else that nation's); then
    /// PlayerPickerTable.update(desiredCiv).
    private func chooseMod(_ mod: String) {
        reloadRuleset()
        var desiredCiv = ""
        // Unciv `GameContext(gameInfo = UncivGame.Current.gameInfo).stateBasedRandom("GameOptionsTable.onChooseMod",
        // mod.hashCode())`: with no game loaded the context is empty - the stream below. Once a game has been loaded its
        // GameInfo's identity hash joins the seed, which no port can reproduce.
        var rng = mapGenCivStateRandom("GameOptionsTable.onChooseMod", seed: javaStringHash(mod))
        if settings.mods.contains(mod) {
            let modNations = NewGameScreen.modMajorNations(mod)
            if !modNations.isEmpty { desiredCiv = rng.randomElement(modNations) ?? "" }
            let music = MusicController.shared
            if !music.chooseTrack(prefix: mod, suffix: MusicMood.theme, flags: .setSelectNation) && !desiredCiv.isEmpty {
                music.chooseTrack(prefix: desiredCiv, suffixes: MusicMood.themeOrPeace, flags: .setSelectNation)
            }
        }
        updatePlayerPicker(desiredCiv: desiredCiv)
    }
    /// Unciv GameOptionsTable.reloadRuleset: the ruleset rebuilt from the base ruleset and mods; victory types it lacks
    /// dropped (all of its selectable victories when none is left); "Mod choices will change the number of available
    /// civs" - the civilization and city-state counts lowered to what it can supply; then update()
    private func reloadRuleset() {
        Ruleset.activate(mods: settings.mods, baseRuleset: settings.baseRuleset)   // RulesetCache.getComplexRuleset(gameParameters)
        filterVictoryTypes()
        let maxMajorCivs = numberOfMajorCivs
        if settings.maxNumberOfPlayers > maxMajorCivs { settings.maxNumberOfPlayers = maxMajorCivs }
        if settings.minNumberOfPlayers > maxMajorCivs { settings.minNumberOfPlayers = maxMajorCivs }
        let maxCityStates = numberOfCityStates
        if settings.maxNumberOfCityStates > maxCityStates { settings.maxNumberOfCityStates = maxCityStates }
        if settings.minNumberOfCityStates > maxCityStates { settings.minNumberOfCityStates = maxCityStates }
        // numberOfCityStates (ours keeps -1 for Unciv's default of 6)
        if (settings.cityStateCount < 0 ? 6 : settings.cityStateCount) > maxCityStates { settings.cityStateCount = maxCityStates }
        rebuildGameOptions()
    }
    /// Unciv PlayerPickerTable.update: reassignRemovedModReferences - a seat whose nation the ruleset lacks, is a
    /// city-state or "Will not be chosen for new games" goes back to Random; the seats past the choosable nations (the
    /// Spectator counted) are removed, whoever holds them; assignDesiredCiv - the first human Random seat takes the
    /// desired civ unless a seat already has it; the table is rebuilt
    private func updatePlayerPicker(desiredCiv: String = "") {
        for i in settings.players.indices {
            if let n = rs.nations[settings.players[i].chosenCiv], !n.isCityState, !n.uniques.contains("Will not be chosen for new games") { continue }
            if settings.players[i].chosenCiv != "Random" { settings.players[i].chosenCiv = "Random" }
        }
        let playable = playableCivs
        if settings.players.count > playable { settings.players.removeSubrange(playable...) }
        if !desiredCiv.isEmpty, !settings.players.contains(where: { $0.chosenCiv == desiredCiv }),
           let i = settings.players.firstIndex(where: { $0.chosenCiv == "Random" && $0.isHuman }) {
            settings.players[i].chosenCiv = desiredCiv
        }
        playerTableRevision += 1
    }
    /// Unciv PlayerPickerTable.popupFriendPicker: FriendSelectionPopup over getAvailableFriends; the friend chosen (by
    /// name) gives the seat its ID and the table is updated. update() also runs as the popup opens.
    private func popupFriendPicker(_ seat: UUID) {
        picker = OptionPicker(title: L("Select friend"), options: availableFriends().map(\.name), selected: "", onPick: { name in
            guard let friend = UserSettings.friends.first(where: { $0.name == name }), let k = settings.players.firstIndex(where: { $0.id == seat }) else { return }
            settings.players[k].playerId = friend.id
            updatePlayerPicker()
        })
        activeSheet = .options
        updatePlayerPicker()
    }
    /// Unciv PlayerPickerTable.getAvailableFriends: the friends list less the friend (getFriendById) of every seat's ID
    private func availableFriends() -> [(name: String, id: String)] {
        let friends = UserSettings.friends
        var available = friends
        for p in settings.players {
            guard let friend = friends.first(where: { $0.id == p.playerId }),
                  let k = available.firstIndex(where: { $0.name == friend.name && $0.id == friend.id }) else { continue }
            available.remove(at: k)
        }
        return available
    }
    /// Unciv MapFileSelectTable.onUseNationsFromMap: one player per nation, the human pick first and human, the others AI
    /// by translated name; the button stays disabled until another map is chosen
    private func useNationsFromMap() {
        nationsFromMapUsed = true
        let human = mapHumanPick
        let sorted = mapNations.sorted { a, b in
            if (a == human) != (b == human) { return a == human }
            return LocaleCode.compare(L(a), L(b)) == .orderedAscending
        }
        settings.players = sorted.map { PlayerSetup(chosenCiv: $0, isHuman: $0 == human) }
        updatePlayerPicker()   // Unciv: newGameScreen.playerPickerTable.update()
    }
    /// Unciv ScenarioSelectTable.selectScenario: the scenario's players (without the Spectator), base ruleset and mods
    private func selectScenario() {
        guard let name = scenarioChoice, let entry = scenarioEntries.first(where: { $0.name == name }) else { return }
        guard let preview = NewGameScreen.scenarioPreview(entry.url) else { error = L("Scenario file [\(name)] is invalid."); return }
        settings.players = preview.players.filter { $0.chosenCiv != "Spectator" }
        settings.baseRuleset = preview.baseRuleset
        settings.mods = preview.mods
        tryUpdateRuleset()
        updatePlayerPicker()   // Unciv: newGameScreen.playerPickerTable.update()
    }

    // MARK: small controls
    private func selectRow(_ title: String, value: String, options: [String], onPick: @escaping (String) -> Void) -> some View {
        HStack {
            Text(title).font(Theme.heading(14))
            Spacer()
            Button { picker = OptionPicker(title: title, options: options, selected: value, onPick: onPick); activeSheet = .options } label: {
                HStack(spacing: 4) { Text(L(value)).font(Theme.caption.bold()).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                    .padding(.horizontal, 10).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelDark)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.gold, lineWidth: 1))
            }.buttonStyle(.plain)
        }
    }
    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(Theme.caption).foregroundStyle(Theme.creamDim); Spacer(); Text(format(value.wrappedValue)).font(Theme.caption.bold()).foregroundStyle(Theme.gold) }
            EpochsSlider(value: value, range: range, step: step)
        }
    }
    private func checkbox(_ title: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) { Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(Theme.gold); Text(title).font(Theme.body).foregroundStyle(Theme.cream) }
        }.buttonStyle(.plain)
    }
}

/// Unciv ExpanderTab.
struct Expander<Content: View>: View {
    let title: String
    @Binding var open: Bool
    var compact = false
    @ViewBuilder var content: () -> Content
    init(_ title: String, open: Binding<Bool>, compact: Bool = false, @ViewBuilder content: @escaping () -> Content) { self.title = title; _open = open; self.compact = compact; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Unciv ExpanderTab: the BackArrow turns from pointing left (closed) to pointing down (open), linearly in 0.2 s
            Button { withAnimation(.linear(duration: 0.2)) { open.toggle() } } label: {
                HStack {
                    Text(title).font(compact ? Theme.heading(14) : Theme.heading(16)).foregroundStyle(Theme.gold)
                    Spacer()
                    ArtIcon(name: "BackArrow", folder: "OtherIcons", fallback: "chevron.left", size: 18)
                        .rotationEffect(.degrees(open ? -90 : 0))
                }
            }.buttonStyle(.plain)
            if open { content() }
        }
        .padding(compact ? 8 : 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Theme.panelLight, Theme.panel], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Unciv NationPickerPopup: Random first, then nations sorted by name, with details on the right.
/// Unciv NationPickerPopup: the choosable nations on the left - Random (unless a random number of players leaves an AI
/// no random), Spectator for a human, then the nations nobody else took, by translated name - as a list or as icons (the
/// switch button), the highlighted one's NationTable on the right (tap: take it); a double tap or the check mark takes
/// the highlighted nation, close leaves the seat as it was.
struct NationPickerSheet: View {
    let current: String
    let taken: Set<String>
    let onPick: (String) -> Void
    let onClose: () -> Void
    let allowSpectator: Bool
    let noRandom: Bool
    @State private var selected: String?
    @State private var listMode = UserSettings.nationPickerListMode
    init(current: String, taken: Set<String>, allowSpectator: Bool = false, noRandom: Bool = false, onPick: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.current = current; self.taken = taken; self.allowSpectator = allowSpectator; self.noRandom = noRandom; self.onPick = onPick; self.onClose = onClose; _selected = State(initialValue: current)
    }
    private var entries: [String] {
        let rs = Ruleset.shared
        let first = (noRandom ? [] : ["Random"]) + (allowSpectator && rs.nations["Spectator"] != nil ? ["Spectator"] : [])
        let nations = rs.majorNations.filter { !$0.uniques.contains("Will not be chosen for new games") && ($0.name == current || !taken.contains($0.name)) }
            .map(\.name).sorted { LocaleCode.compare(L($0), L($1)) == .orderedAscending }
        return first + nations
    }
    var body: some View {
        let rs = Ruleset.shared
        ZStack {
            Theme.background
            HStack(alignment: .top, spacing: 12) {
                ScrollViewReader { proxy in
                    ScrollView {
                        if listMode == "Icons" {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 5)], spacing: 5) {
                                ForEach(entries, id: \.self) { key in
                                    icon(key, rs).padding(3)
                                        .overlay(Circle().stroke(selected == key ? (rs.nations[key].map { Color(uiColor: UIColor(rgb: $0.outerColor)) } ?? Theme.gold) : .clear, lineWidth: 3))
                                        .id(key).contentShape(Rectangle())
                                        .uncivTaps(onTap: { selected = key }, onDoubleTap: { onPick(key) })
                                }
                            }.padding(.bottom, 70)
                        } else {
                            VStack(spacing: 6) {
                                ForEach(entries, id: \.self) { key in
                                    HStack(spacing: 8) {
                                        icon(key, rs)
                                        VStack(alignment: .leading, spacing: 1) { Text(L(key)).font(Theme.caption.bold()); if let l = rs.nations[key]?.leaderName { Text(L(l)).font(Theme.small) } }
                                        Spacer()
                                    }
                                    .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(selected == key ? Theme.gold.opacity(0.2) : Theme.fill))
                                    .id(key).contentShape(Rectangle())
                                    .uncivTaps(onTap: { selected = key }, onDoubleTap: { onPick(key) })
                                }
                            }.padding(.bottom, 70)
                        }
                    }
                    .onAppear { if let c = selected { proxy.scrollTo(c, anchor: .center) } }
                }
                .frame(maxWidth: .infinity)
                ScrollView {
                    if let key = selected { details(key, rs).contentShape(Rectangle()).onTapGesture { onPick(key) } }
                }.frame(maxWidth: .infinity)
            }
            .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 10) {
                roundButton("xmark", Color(red: 0.7, green: 0.13, blue: 0.13)) { onClose() }
                Button { listMode = listMode == "Icons" ? "List" : "Icons"; UserSettings.nationPickerListMode = listMode } label: {
                    ArtIcon(name: "NationSwap", folder: "OtherIcons", fallback: "square.grid.2x2", size: 34).frame(width: 56, height: 56).background(Circle().fill(Color.black.opacity(0.67)))
                }.buttonStyle(.plain)
            }.padding(14)
        }
        .overlay(alignment: .bottomTrailing) { roundButton("checkmark", .green) { if let key = selected { onPick(key) } }.padding(14) }
        .foregroundStyle(Theme.cream)
    }
    private func roundButton(_ symbol: String, _ color: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: symbol).font(.system(size: 22, weight: .bold)).foregroundStyle(color).frame(width: 56, height: 56).background(Circle().fill(Color.black.opacity(0.67))) }.buttonStyle(.plain)
    }
    @ViewBuilder private func icon(_ key: String, _ rs: Ruleset) -> some View {
        if let n = rs.nations[key] { NationBadge(nation: n, size: 46) }
        else { Text("?").font(Theme.title(20)).foregroundStyle(.black).frame(width: 46, height: 46).background(Circle().fill(Color.white)).overlay(Circle().stroke(Color.black, lineWidth: 2)) }
    }
    /// Unciv NationTable(nation, width, minHeight, ruleset): the title - Nation.getLeaderDisplayName ("[leader] of [nation]",
    /// a city-state's name; Random and Spectator their name) - over the nation's Civilopedia lines without the header-3
    /// leader line, rendered with MarkupRenderer and no link action (IconDisplay.NoLink)
    @ViewBuilder private func details(_ key: String, _ rs: Ruleset) -> some View {
        if let n = rs.nations[key] {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    NationBadge(nation: n, size: 50)
                    let isPlain = n.name == "Random" || n.name == "Spectator" || n.isCityState
                    Text(isPlain ? L(n.name) : L("[\(n.leaderName ?? "")] of [\(n.name)]")).font(Theme.heading(16)).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(ObjectDescriptions.nation(n, rs: rs, s: nil, withoutHeader3: true).enumerated()), id: \.offset) { _, l in
                    if l.text.isEmpty { Color.clear.frame(height: 6) }   // FormattedLine(): an empty line
                    else { Text(l.text).font(Theme.small).foregroundStyle(l.text.hasPrefix(" ") ? Theme.creamDim : Theme.cream).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill))
        } else {
            Text(L(key)).font(Theme.heading(16)).padding(10)
        }
    }
}

/// Unciv "Set available nations for random pool" picker.
/// Unciv RandomNationPickerPopup: "Banned nations" beside "Available nations" (the pool), every selectable major nation by
/// translated name, a tap moving it across; the swap button exchanges the sides, the check mark keeps the pool (an empty
/// pool switches the option off), close keeps the old one.
struct RandomNationsPoolSheet: View {
    @Binding var pool: [String]
    @Binding var enabled: Bool
    let onClose: () -> Void
    @State private var selected: Set<String> = []
    @State private var loaded = false
    var body: some View {
        let rs = Ruleset.shared
        let nations = rs.majorNations.filter { !$0.uniques.contains("Will not be chosen for new games") }
            .sorted { LocaleCode.compare(L($0.name), L($1.name)) == .orderedAscending }
        ZStack {
            Theme.background
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    column(L("Banned nations"), nations.filter { !selected.contains($0.name) }) { selected.insert($0) }
                    column(L("Available nations"), nations.filter { selected.contains($0.name) }) { selected.remove($0) }
                }
                HStack {
                    Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 20, weight: .bold)).foregroundStyle(Color(red: 0.7, green: 0.13, blue: 0.13)).frame(width: 50, height: 50).background(Circle().fill(Color.black.opacity(0.67))) }.buttonStyle(.plain)
                    Spacer()
                    Button { selected = Set(nations.map(\.name)).subtracting(selected) } label: {
                        ArtIcon(name: "NationSwap", folder: "OtherIcons", fallback: "arrow.left.arrow.right", size: 34).frame(width: 50, height: 50).background(Circle().fill(Color.black.opacity(0.67)))
                    }.buttonStyle(.plain)
                    Spacer()
                    Button {
                        pool = nations.map(\.name).filter { selected.contains($0) }
                        if pool.isEmpty { enabled = false }
                        onClose()
                    } label: { Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.green).frame(width: 50, height: 50).background(Circle().fill(Color.black.opacity(0.67))) }.buttonStyle(.plain)
                }.padding(.horizontal, 20)
            }.padding(12)
        }
        .foregroundStyle(Theme.cream)
        .onAppear { if !loaded { loaded = true; selected = Set(pool).intersection(nations.map(\.name)) } }
    }

    private func column(_ title: String, _ list: [NationDef], _ tap: @escaping (String) -> Void) -> some View {
        VStack(spacing: 6) {
            Text(title).font(Theme.heading(15))
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(list) { n in
                        Button { tap(n.name) } label: {
                            HStack(spacing: 8) { NationBadge(nation: n, size: 30); VStack(alignment: .leading, spacing: 1) { Text(L(n.name)).font(Theme.caption.bold()); Text(L(n.leaderName ?? "")).font(Theme.small) }; Spacer() }
                                .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.frame(maxWidth: .infinity)
    }
}

/// A wrapping row of on/off chips for boolean game options.
struct FlowToggles: View {
    let items: [(String, Bool, () -> Void)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                Button { items[i].2() } label: {
                    HStack(spacing: 6) { Image(systemName: items[i].1 ? "checkmark.square.fill" : "square").foregroundStyle(Theme.gold); Text(items[i].0).font(Theme.caption).lineLimit(1).foregroundStyle(Theme.cream) }
                }.buttonStyle(.plain)
            }
        }
    }
}

/// Slider for integer settings; keeps its own Double state so the binding never round-trips through a transform (which loops SwiftUI's layout).
struct IntSliderRow: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    /// Unciv UncivSlider.setSnapToValues (libGDX Slider.snap): the closest snap value within the threshold wins
    var snapValues: [Int] = []
    var snapThreshold: Int = 0
    let onChange: (Int) -> Void
    @State private var local: Double = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(Theme.caption).foregroundStyle(Theme.creamDim); Spacer(); Text("\(Int(local))").font(Theme.caption.bold()).foregroundStyle(Theme.gold) }
            EpochsSlider(value: $local, range: Double(range.lowerBound)...Double(max(range.lowerBound, range.upperBound)), step: Double(step))
        }
        .onAppear { local = Double(min(max(value, range.lowerBound), range.upperBound)) }
        // Unciv MapParametersTable "Reset to defaults" sets the sliders' values from outside
        .onChange(of: value) { _, v in if Int(local) != v { local = Double(min(max(v, range.lowerBound), range.upperBound)) } }
        .onChange(of: local) { _, v in
            let near = snapValues.filter { abs(Double($0) - v) <= Double(snapThreshold) }.min { abs(Double($0) - v) < abs(Double($1) - v) }
            if let n = near, Double(n) != v { local = Double(n); return }
            onChange(Int(v))
        }
    }
}

/// Pure-SwiftUI slider (UISlider inside a presented ScrollView can lock SwiftUI into a layout loop).
struct EpochsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - 20)
            let span = max(0.000001, range.upperBound - range.lowerBound)
            let frac = min(1, max(0, (value - range.lowerBound) / span))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.panelDark).frame(height: 6).padding(.horizontal, 10)
                Capsule().fill(Theme.gold).frame(width: w * frac + 10, height: 6).padding(.leading, 10)
                Circle().fill(Theme.cream).frame(width: 20, height: 20).overlay(Circle().stroke(Theme.gold, lineWidth: 1.5)).offset(x: w * frac)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(1, max(0, (g.location.x - 10) / w))
                var v = range.lowerBound + f * span
                if step > 0 { v = (v / step).rounded() * step }
                value = min(range.upperBound, max(range.lowerBound, v))
            })
        }
        .frame(height: 24)
    }
}

/// Unciv "select box" replacement: a themed list of options (UIKit Menus inside a presented ScrollView lock SwiftUI into a layout loop).
struct OptionPicker: Identifiable {
    let id = UUID()
    let title: String
    let options: [String]
    let selected: String
    let onPick: (String) -> Void
}
struct OptionPickerSheet: View {
    let picker: OptionPicker
    let onClose: () -> Void
    var body: some View {
        ThemedSheet(picker.title, subtitle: nil, onClose: onClose) {
            Panel(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(picker.options, id: \.self) { o in
                        ThemedRow(title: L(o), detail: nil, selected: o == picker.selected, action: { picker.onPick(o); onClose() }, leading: { EmptyView() }, trailing: { EmptyView() })
                    }
                }
            }
        }
    }
}

// MARK: - Map options data (Unciv MapShape / MapSize / MapResourceSetting / MapFileSelectTable / ScenarioSelectTable)
extension NewGameScreen {
    /// Unciv MapShape.allValues
    static let mapShapes = ["Rectangular", "Hexagonal", "Flat Earth Hexagonal"]
    /// Unciv MapSize.names(): the predefined sizes, then Auto
    static let worldSizeNames = MapSizePreset.allCases.map { $0.rawValue } + ["Auto"]
    /// Unciv MapResourceSetting.activeLabels()
    static let resourceSettings = ["Sparse", "Default", "Abundant"]
    /// Unciv UncivSlider tip format: two decimals for a step under 0.1, one for a step under 1 - Kotlin's String.format,
    /// i.e. the JVM's default (the device's) locale, "0,30" on a Turkish device
    static let tip2: (Double) -> String = { String(format: "%.2f", locale: Locale.current, $0) }
    static let tip1: (Double) -> String = { String(format: "%.1f", locale: Locale.current, $0) }

    /// Unciv MapParameters.reseed: System.currentTimeMillis()
    static func freshSeed() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    /// Unciv's "RNG Seed" field (UncivTextField.Numeric(integerOnly = true)): it takes digits and the number format's
    /// symbols, and `mapParameters.seed = seedTextField.value?.toLong() ?: 0L`, where NumberFormat.parse reads the longest
    /// leading number - a minus, grouping commas skipped, nothing from a decimal point on - and fails (0) on none; a
    /// number past Long comes back a Double that toLong() clamps. MapParameters.seed is a Long: ours keeps its bits.
    static func parseSeed(_ text: String) -> UInt64? {
        var digits = "", negative = false
        for (i, c) in text.enumerated() {
            if i == 0 && c == "-" { negative = true; continue }
            if c == "," && !digits.isEmpty { continue }
            guard c.isASCII && c.isNumber else { break }
            digits.append(c)
        }
        guard !digits.isEmpty else { return nil }
        let value: Int64
        if let v = Int64((negative ? "-" : "") + digits) { value = v } else { value = negative ? Int64.min : Int64.max }
        return UInt64(bitPattern: value)
    }
    /// A seed as Unciv shows MapParameters.seed, a signed Long
    static func seedString(_ seed: UInt64) -> String { String(Int64(bitPattern: seed)) }

    /// Kotlin Float.roundToInt: Math.round, NaN is 0, clamped to Int
    static func roundToInt(_ f: Float) -> Int {
        if f.isNaN { return 0 }
        if f >= Float(Int32.max) { return Int(Int32.max) }
        if f <= Float(Int32.min) { return Int(Int32.min) }
        return Int((f + 0.5).rounded(.down))
    }
    /// Unciv HexMath.getNumberOfTilesInHexagon
    static func tilesInHexagon(_ r: Int) -> Int { r < 0 ? 0 : 1 &+ 3 &* r &* (r &+ 1) }
    /// Unciv HexMath.getEquivalentRectangularSize, ratio 0.65
    static func rectSize(_ r: Int) -> (Int, Int) {
        if r < 0 { return (0, 0) }
        let w = roundToInt((Float(tilesInHexagon(r)) / 0.65).squareRoot())
        return (w, roundToInt(Float(w) * 0.65))
    }
    /// Unciv HexMath.getEquivalentHexagonalRadius
    static func hexRadius(_ w: Int, _ h: Int) -> Int {
        let n = w &* h
        return n < 1 ? 0 : roundToInt(((12 * Float(n) - 3).squareRoot() - 3) / 6)
    }
    /// Unciv MapParametersTable: the custom size fields start from the map size's radius, width and height (Auto
    /// carries Medium's; a custom size keeps its own and the other shape's equivalent)
    static func customSizeFields(_ s: GameSettings) -> (radius: Int, width: Int, height: Int) {
        if let p = MapSizePreset(rawValue: s.mapSizeName) { return (p.radius, p.width, p.height) }
        if s.mapSizeName == "Custom" {
            if s.mapShape == "Rectangular" { return (hexRadius(s.mapWidth, s.mapHeight), s.mapWidth, s.mapHeight) }
            let r = max(0, (s.mapWidth - 1) / 2)
            let (w, h) = rectSize(r)
            return (r, w, h)
        }
        let m = MapSizePreset.Medium
        return (m.radius, m.width, m.height)
    }

    /// JVM HashMap / HashSet iteration: by bucket `(h ^ h >>> 16) & (capacity - 1)`, insertion order within a bucket
    static func javaHashOrder(_ keys: [String], capacity: Int) -> [String] {
        var buckets = [[String]](repeating: [], count: capacity)
        for k in keys {
            let h = javaStringHash(k)
            let spread = h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 16)
            buckets[Int(spread & Int32(capacity - 1))].append(k)
        }
        return buckets.flatMap { $0 }
    }
    /// Kotlin toHashSet(): HashSet(mapCapacity(n)), the table the next power of two, grown past three quarters
    static func kotlinHashSetCapacity(_ n: Int) -> Int {
        let initial = n < 3 ? n + 1 : Int(Float(n) / 0.75 + 1)
        var capacity = 1
        while capacity < initial { capacity <<= 1 }
        while Float(n) > Float(capacity) * 0.75 { capacity <<= 1 }
        return capacity
    }
    /// java.util.HashMap(): 16 buckets, doubled past three quarters
    static func javaHashMapCapacity(_ n: Int) -> Int {
        var capacity = 16
        while n > capacity * 3 / 4 { capacity <<= 1 }
        return capacity
    }
    static func javaHashMapFirst(_ keys: [String]) -> String? {
        let unique = distinct(keys)
        return javaHashOrder(unique, capacity: javaHashMapCapacity(unique.count)).first
    }
    static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
    static func flip(_ set: inout Set<String>, _ value: String) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
    /// Unciv MultiCheckboxTable onUpdate: a random ticked value, or any value when none is ticked
    static func randomPick(_ ticked: Set<String>, all: [String]) -> String? {
        ticked.isEmpty ? all.randomElement() : ticked.randomElement()
    }

    /// Unciv `RulesetCache[mod]?.nations?.values?.filter { it.isMajorCiv }`: the mod's own major nations (its Nations.json
    /// alone, not merged into a base ruleset), in its file order
    static func modMajorNations(_ mod: String) -> [String] {
        let root = Ruleset.modsDirectory.appendingPathComponent(mod)
        let candidates = [root.appendingPathComponent("jsons/Nations.json"), root.appendingPathComponent("jsons/Civ V - Vanilla/Nations.json"), root.appendingPathComponent("Nations.json")]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }), let raw = try? Data(contentsOf: url),
              let cleaned = Ruleset.cleanedModJSON(raw), let nations = try? JSONDecoder().decode([NationDef].self, from: cleaned) else { return [] }
        return NewGameScreen.distinct(nations.filter { $0.isMajor }.map(\.name))
    }

    /// Unciv MapFileSelectTable.getMapFilesSequence: the saved maps and every installed mod's maps, newest first. A mod
    /// map's category is its mod; a saved map's is its base ruleset - ours do not record one, so Unciv's
    /// MapParameters default (Gods & Kings)
    static func loadMapEntries() -> [MapFileEntry] {
        var out: [MapFileEntry] = []
        for name in MapStore.list() {
            let url = MapStore.directory.appendingPathComponent("\(name).json")
            out.append(MapFileEntry(id: name, name: name, category: Ruleset.baseRulesetName, url: url, modified: modificationDate(url)))
        }
        for id in MapStore.modMaps(mods: Ruleset.availableMods()) {
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let url = Ruleset.modsDirectory.appendingPathComponent(parts[0]).appendingPathComponent("maps").appendingPathComponent(parts[1])
            out.append(MapFileEntry(id: id, name: parts[1], category: parts[0], url: url, modified: modificationDate(url)))
        }
        return out.sorted { $0.modified > $1.modified }
    }
    static func modificationDate(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }
    /// Unciv TileMap.Preview: an Unciv map file's mods, base ruleset and description (MapParameters defaults: no mods,
    /// Gods & Kings); a map of ours records none of them
    static func mapFileInfo(_ entry: MapFileEntry) -> (mods: [String], baseRuleset: String, description: String) {
        // one of our own maps keeps Unciv's mapParameters.mods / baseRuleset and TileMap.description itself
        if !entry.id.contains("/") {
            guard let m = loadMapQuietly(entry.id) else { return ([], Ruleset.baseRulesetName, "") }
            return (m.mods, m.baseRuleset, m.description)
        }
        guard let text = try? String(contentsOf: entry.url, encoding: .utf8),
              let data = UncivSave.decodeToJSONData(text),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], Ruleset.baseRulesetName, "") }
        let params = root["mapParameters"] as? [String: Any] ?? [:]
        return ((params["mods"] as? [String]) ?? [], (params["baseRuleset"] as? String) ?? Ruleset.baseRulesetName, (root["description"] as? String) ?? "")
    }
    /// MapStore.load without its side effects on the running world: reading an Unciv map sets the wrap width and the
    /// coastal lookup of a throw-away game
    static func loadMapQuietly(_ id: String) -> CustomMap? {
        let wrap = HexCoord.wrapWidth, coastal = GameMap.coastalLandLookup
        defer { HexCoord.wrapWidth = wrap; GameMap.coastalLandLookup = coastal }
        return MapStore.load(name: id)
    }
    /// Unciv TileMap.getRulesetIncompatibility (Tile.getRulesetIncompatibility per tile, then the starting locations'
    /// nations), as the HashSet lists them. The nations are only looked at once `setTransients(ruleset)` went through,
    /// and it throws ("This can fail if the map contains a resource that isn't in the ruleset") on an unknown base
    /// terrain (Tile.setTerrainTransients), an unknown resource (Tile.tileResource) and on any unit the map carries
    /// (Tile.setUnitTransients assigns its owner from the map's lateinit gameInfo) - measured with a map of units and a
    /// starting location of a nation the ruleset lacks: no incompatibility
    static func rulesetIncompatibilities(_ custom: CustomMap) -> [String] {
        let rs = Ruleset.shared
        var out: [String] = []
        var setTransientsThrows = false
        for (i, tile) in custom.map.tiles.enumerated() where !custom.map.missing.contains(i) {
            if rs.terrains[tile.baseTerrain] == nil { out.append("Base terrain [\(tile.baseTerrain)] does not exist in ruleset!"); setTransientsThrows = true }
            for f in tile.features where rs.terrains[f] == nil { out.append("Terrain feature [\(f)] does not exist in ruleset!") }
            if let r = tile.resource, rs.resources[r] == nil { out.append("Resource [\(r)] does not exist in ruleset!"); setTransientsThrows = true }
            if let imp = tile.improvement, rs.improvements[imp] == nil { out.append("Improvement [\(imp)] does not exist in ruleset!") }
            if let w = tile.naturalWonder, rs.terrains[w] == nil { out.append("Natural Wonder [\(w)] does not exist in ruleset!") }
        }
        if !setTransientsThrows && custom.unitOwners.isEmpty {
            for sl in custom.startingLocations where !sl.nation.isEmpty && rs.nations[sl.nation] == nil {
                out.append("Nation [\(sl.nation)] does not exist in ruleset!")
            }
        }
        let unique = distinct(out)
        return javaHashOrder(unique, capacity: javaHashMapCapacity(unique.count))
    }

    /// Unciv UncivFiles.getScenarioFiles: our scenario folder, then every installed mod's "scenarios" folder; a name met
    /// again keeps its first place and takes the later file, as a HashMap put does
    static func loadScenarioEntries() -> [ScenarioEntry] {
        var out: [ScenarioEntry] = []
        func put(_ name: String, _ url: URL) {
            if let i = out.firstIndex(where: { $0.name == name }) { out[i] = ScenarioEntry(name: name, url: url) } else { out.append(ScenarioEntry(name: name, url: url)) }
        }
        for name in MapStore.listScenarios() { put(name, MapStore.scenarioDirectory.appendingPathComponent("\(name).json")) }
        for mod in Ruleset.availableMods() {
            let dir = Ruleset.modsDirectory.appendingPathComponent(mod).appendingPathComponent("scenarios")
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            for f in files { put(f, dir.appendingPathComponent(f)) }
        }
        return out
    }
    /// Unciv GameInfoPreview of a scenario: its players, base ruleset and mods (an Unciv save's gameParameters, or ours)
    static func scenarioPreview(_ url: URL) -> (players: [PlayerSetup], baseRuleset: String, mods: [String])? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if UncivSave.isUncivSave(data) {
            guard let text = String(data: data, encoding: .utf8), let json = UncivSave.decodeToJSONData(text),
                  let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
            let params = root["gameParameters"] as? [String: Any] ?? [:]
            let players = ((params["players"] as? [[String: Any]]) ?? []).map { p -> PlayerSetup in
                var player = PlayerSetup(chosenCiv: p["chosenCiv"] as? String ?? "Random", isHuman: (p["playerType"] as? String) == "Human")
                player.playerId = p["playerId"] as? String ?? ""
                return player
            }
            return (players, params["baseRuleset"] as? String ?? Ruleset.baseRulesetName, params["mods"] as? [String] ?? [])
        }
        guard let peek = try? JSONDecoder().decode(NewGameScenarioPeek.self, from: data) else { return nil }
        return (peek.settings.players, peek.settings.baseRuleset, peek.settings.mods)
    }
}

/// One map of Unciv's MapFileSelectTable (MapWrapper): shown by its file name under its category.
struct MapFileEntry: Equatable {
    let id: String
    let name: String
    let category: String
    let url: URL
    let modified: Date
}
/// One scenario of Unciv's ScenarioSelectTable (ScenarioData).
struct ScenarioEntry: Equatable {
    let name: String
    let url: URL
}
private struct NewGameScenarioPeek: Decodable { let settings: GameSettings }

/// Unciv ExpanderTab.persistedStates: open states of the expanders with a persistenceID, kept while the app runs.
enum NewGameExpanderMemory {
    nonisolated(unsafe) static var open: [String: Bool] = [:]
}

extension View {
    /// Unciv GameOptionsTable / PlayerPickerTable `locked`: the control is disabled (and dimmed) while a scenario is chosen.
    func newGameLocked(_ locked: Bool) -> some View { disabled(locked).opacity(locked ? 0.45 : 1) }
}

/// Unciv UncivTextField.Integer: free integer entry, an empty or unreadable field counting as 0; the value is only
/// checked when the game starts (MapSize.fixUndesiredSizes).
struct NewGameIntField: View {
    let hint: String
    let value: Int
    let onEdit: (Int) -> Void
    @State private var text = ""
    var body: some View {
        TextField(hint, text: $text).textFieldStyle(.roundedBorder).keyboardType(.numberPad).font(Theme.caption).frame(width: 90)
            .onAppear { text = String(value) }
            .onChange(of: text) { _, t in
                let v = Int32(t.trimmingCharacters(in: .whitespaces)).map { Int($0) } ?? 0
                if v != value { onEdit(v) }
            }
            .onChange(of: value) { _, v in
                if (Int32(text.trimmingCharacters(in: .whitespaces)).map { Int($0) } ?? 0) != v { text = String(v) }
            }
    }
}

/// Unciv LoadMapPreview: the whole map minimap-style (each tile its terrain colour halfway to grey), fitted into a square.
struct NewGameMapPreview: View {
    let map: GameMap
    let side: CGFloat
    var body: some View {
        let cols = CGFloat(max(1, map.width)), rows = CGFloat(max(1, map.height))
        let cell = min(side / (cols * 0.75 + 0.25), side / ((rows + 0.5) * 0.866))
        Canvas { ctx, _ in
            let rs = Ruleset.shared
            for (i, tile) in map.tiles.enumerated() where !map.missing.contains(i) {
                let c = tile.coord
                let x = CGFloat(c.offsetCol) * cell * 0.75
                let y = (CGFloat(c.offsetRow) + (c.offsetCol & 1 == 1 ? 0.5 : 0)) * cell * 0.866
                var color = Color.gray
                if let t = rs.terrains[tile.baseTerrain], t.rgb.count >= 3 {
                    color = Color(red: (Double(t.rgb[0]) / 255 + 0.5) / 2, green: (Double(t.rgb[1]) / 255 + 0.5) / 2, blue: (Double(t.rgb[2]) / 255 + 0.5) / 2)
                }
                ctx.fill(Path(CGRect(x: x, y: y, width: cell * 0.95, height: cell * 0.85)), with: .color(color))
            }
        }
        .frame(width: cell * (cols * 0.75 + 0.25), height: cell * (rows + 0.5) * 0.866)
    }
}

/// Unciv GameOptionsTable.addDurationSelectBox / DurationSelector: the title and three select boxes - days 0-11, hours
/// 0,1,2,3,4,5,6,8,10,12,16,20, minutes 0,3,5,10,...,50 - that open on the given defaults, not on the parameter's
/// value, and write nothing until one of them changes: then 0d 0h 0m becomes 3m (preventNullTime) and the parameter
/// takes d*1440 + h*60 + m. The boxes are built anew with the options table, back on their defaults.
struct DurationSelectorRow: View {
    static let dayValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    static let hourValues = [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20]
    static let minuteValues = [0, 3, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50]
    let title: String
    let present: (OptionPicker) -> Void
    let onChange: (Int) -> Void
    @State private var day: Int
    @State private var hour: Int
    @State private var minute: Int
    init(title: String, defaultDays: Int, defaultHours: Int, defaultMinutes: Int, present: @escaping (OptionPicker) -> Void, onChange: @escaping (Int) -> Void) {
        self.title = title; self.present = present; self.onChange = onChange
        // Unciv createTimeCell: `timeBox.selected = "$initialValue$suffix"` (libGDX selects the first item for a value it lacks)
        _day = State(initialValue: Self.dayValues.firstIndex(of: defaultDays) ?? 0)
        _hour = State(initialValue: Self.hourValues.firstIndex(of: defaultHours) ?? 0)
        _minute = State(initialValue: Self.minuteValues.firstIndex(of: defaultMinutes) ?? 0)
    }
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.creamDim)
            Spacer()
            box(Self.dayValues, "d", day) { select(day: $0, hour: hour, minute: minute) }
            box(Self.hourValues, "h", hour) { select(day: day, hour: $0, minute: minute) }
            box(Self.minuteValues, "m", minute) { select(day: day, hour: hour, minute: $0) }
        }
    }
    private func box(_ values: [Int], _ suffix: String, _ selected: Int, onSelect: @escaping (Int) -> Void) -> some View {
        let labels = values.map { "\($0)\(suffix)" }
        return Button {
            present(OptionPicker(title: title, options: labels, selected: labels[selected], onPick: { pick in
                // libGDX SelectBox: a change event only when the selection changes
                guard let i = labels.firstIndex(of: pick), i != selected else { return }
                onSelect(i)
            }))
        } label: {
            HStack(spacing: 3) { Text(labels[selected]).font(Theme.caption.bold()).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
                .padding(.horizontal, 8).padding(.vertical, 5).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelDark)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.gold, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    /// Unciv DurationSelector box.onChange: preventNullTime, then updateGameParameter
    private func select(day d: Int, hour h: Int, minute m: Int) {
        var m = m
        if Self.dayValues[d] == 0 && Self.hourValues[h] == 0 && Self.minuteValues[m] == 0 { m = Self.minuteValues.firstIndex(of: 3) ?? m }
        day = d; hour = h; minute = m
        onChange(Self.dayValues[d] * 24 * 60 + Self.hourValues[h] * 60 + Self.minuteValues[m])
    }
}

/// Unciv PlayerPickerTable.addPlayerTableMultiplayerControls: an online human seat's "Please input Player ID!" field with
/// a ✔/✘ mark (IdChecker), "Set current user", "Player ID from clipboard" and, when there are friends, "Player ID from
/// friends list". Only a valid ID is stored - the field's text trimmed; an invalid one leaves the stored ID as it was.
/// The field starts from the stored ID whenever the player table is rebuilt.
struct PlayerIdControls: View {
    @Binding var playerId: String
    let onFriends: (() -> Void)?
    @State private var text: String
    @State private var valid: Bool
    init(playerId: Binding<String>, onFriends: (() -> Void)?) {
        _playerId = playerId; self.onFriends = onFriends
        _text = State(initialValue: playerId.wrappedValue)
        _valid = State(initialValue: IdChecker.isValidPlayerId(playerId.wrappedValue))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField(L("Please input Player ID!"), text: $text).textFieldStyle(.roundedBorder).font(Theme.caption)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: text) { _, _ in onPlayerIdTextUpdated() }
                Text(valid ? "✔" : "✘").font(Theme.heading(15)).foregroundStyle(valid ? Color.green : Color.red)   // U+2714 / U+2718
            }
            HStack(spacing: 6) {
                Button(L("Set current user")) { text = Multiplayer.userId; onPlayerIdTextUpdated() }.buttonStyle(ThemedButtonStyle(compact: true))
                Button(L("Player ID from clipboard")) { text = UIPasteboard.general.string ?? ""; onPlayerIdTextUpdated() }.buttonStyle(ThemedButtonStyle(compact: true))
                if let friends = onFriends { Button(L("Player ID from friends list")) { friends() }.buttonStyle(ThemedButtonStyle(compact: true)) }
            }
        }
    }
    /// Unciv onPlayerIdTextUpdated
    private func onPlayerIdTextUpdated() {
        if IdChecker.isValidPlayerId(text) {
            playerId = text.trimmingCharacters(in: .whitespacesAndNewlines)
            valid = true
        } else { valid = false }
    }
}
