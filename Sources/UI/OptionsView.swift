// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import GameController

/// Unciv OptionsPopup: About, Display, Gameplay, Automation, Language, Sound, Multiplayer, Keys, Advanced, Locate mod errors
/// and Debug, in that order (OptionsPopupPages), opening on Gameplay. Works from the main menu (controller nil) and in-game.
struct OptionsView: View {
    let controller: GameController?
    /// Unciv openOptionsPopup(withDebug): the main menu's Options button, long pressed, adds the Debug tab
    var withDebug = false
    let onClose: () -> Void
    @State private var tab = "Gameplay"   // Unciv OptionsPopup.defaultPage
    @State private var tick = 0
    /// Unciv OptionsPopupPages.visible: Keys only with a hardware keyboard (GUI.keyboardAvailable), "Locate mod errors" only
    /// once a mod is installed (RulesetCache.size > BaseRuleset.entries.size), Debug only for openOptionsPopup(withDebug).
    private var tabs: [String] {
        ["About", "Display", "Gameplay", "Automation", "Language", "Sound", "Multiplayer"]
        + (GCKeyboard.coalesced != nil ? ["Keys"] : [])
        + ["Advanced"]
        + (Ruleset.availableMods().isEmpty ? [] : ["Locate mod errors"])
        + (withDebug ? ["Debug"] : [])
    }

    /// Unciv Popup / ConfirmPopup raised from an options page: a message with "Close", or a question with "Cancel" and a confirm button.
    private struct PagePopup {
        var text: String
        var color: Color = Theme.cream
        var confirm: String? = nil
        var action: (() -> Void)? = nil
    }
    @State private var popup: PagePopup? = nil
    @State private var openSelect: String? = nil   // the select box whose list is open

    // Display
    @State private var tutorialsReset = false
    // Sound
    @State private var soundVolume = Double(Audio.shared.soundEffectsVolume)
    @State private var cityVolume = Double(Audio.shared.citySoundsVolume)
    @State private var musicVolume = Double(MusicController.shared.musicVolume)
    @State private var musicPausePos = OptionsView.lengthToPos(Double(MusicController.shared.pauseBetweenTracks))
    @State private var currentTrack = MusicController.shared.currentTrack
    // Multiplayer
    @State private var serverText = Multiplayer.serverURL
    @State private var serverValid: Bool? = nil
    @State private var serverError: String? = nil
    @State private var password = Multiplayer.password
    @State private var authStatus = "Set a password to secure your userId"
    /// Unciv MultiplayerTab reads `mpServer.getFeatureSet().authVersion` once, when the tab is laid out
    @State private var authVersion = 0
    /// Unciv AuthPopup opened over the tab, with what its answer does
    @State private var authRetry: ((Bool) -> Void)? = nil
    // Keys
    @State private var rebinding: String? = nil   // Unciv KeyCapturingButton: the binding waiting for a key
    @State private var functionKeyCaptureId = UUID()
    @State private var openKeyGroups: Set<String> = OptionsView.keyGroupsOpen
    nonisolated(unsafe) private static var keyGroupsOpen: Set<String> = []   // Unciv ExpanderTab persistenceID
    // Advanced
    @State private var autosaveText = "\(UserSettings.maxAutosavesStored)"
    @State private var testAreaText = "Test area"
    @State private var testAreaToken = UUID()
    /// The test area's long press has fired, so its lift is no tap (uncivLongPress)
    @State private var testAreaLongPressFired = false
    @State private var idSetLabel: (text: String, ok: Bool)? = nil
    // Locate mod errors
    @State private var modResults: [(mod: String, errors: [RulesetError])] = []
    @State private var modSearch = ""
    @State private var modChecking = false
    @State private var openMods: Set<String> = []
    // Debug
    @State private var simulateTurn = ""
    @State private var simulateInvalid = false

    var body: some View {
        ThemedSheet(L("Options"), subtitle: nil, onClose: onClose) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { ForEach(tabs, id: \.self) { t in
                    // the store build's Multiplayer and mod pages are not open yet: faded with the "Soon" badge beside them
                    if StoreBuild.onlineAndModsComingSoon && (t == "Multiplayer" || t == "Locate mod errors") {
                        HStack(spacing: 4) { Button(L(t)) {}.buttonStyle(ThemedButtonStyle(compact: true)).opacity(0.45).allowsHitTesting(false); SoonBadge() }
                            .contentShape(Rectangle()).onTapGesture { GameEvents.post(.unavailableTapped(mods: t != "Multiplayer", place: "options")) }
                    } else {
                        Button(L(t)) { tab = t; openSelect = nil }.buttonStyle(ThemedButtonStyle(filled: tab == t, compact: true))
                    }
                } }
            }
            let _ = tick
            switch tab {
            case "Display": display
            case "Gameplay": gameplay
            case "Automation": automation
            case "Sound": sound
            case "Multiplayer": multiplayer
            case "Advanced": advanced
            case "Language": language
            case "Keys": keys
            case "Locate mod errors": modErrors
            case "Debug": debug
            default: about
            }
        }
        .overlay { popupOverlay }
        .overlay { if let retry = authRetry { AuthPopupView { ok in authRetry = nil; retry(ok) } } }
        // Unciv OptionsPopup init: `settings.addCompletedTutorialTask("Open the options table")` for every OptionsPopup -
        // the main menu's, the world screen's, with or without the Debug page, from a button or a key; the tasks are global
        .onAppear { if let c = controller { c.completeTask("options") } else { Tutorial.complete("options") } }
        .screenShown("options")
        .onChange(of: tab) { _, t in GameEvents.post(.screen("options_" + (t))) }
    }

    private func refresh() { tick += 1; controller?.refresh(full: false) }

    // MARK: helpers (Unciv OptionsPopupHelpers)

    /// Unciv OptionsPopupHelpers.addCheckbox.
    func check(_ title: String, _ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Button { set(!get()); refresh() } label: {
            HStack(spacing: 8) { Image(systemName: get() ? "checkmark.square.fill" : "square").foregroundStyle(Theme.gold); Text(title).font(Theme.body).foregroundStyle(Theme.cream).multilineTextAlignment(.leading); Spacer() }
        }.buttonStyle(.plain)
    }

    /// Unciv OptionsPopupHelpers.addHeader: a separator (unless first) and a centered heading.
    private func groupHeader(_ title: String, first: Bool = false) -> some View {
        VStack(spacing: 6) {
            if !first { Divider2() }
            Text(L(title)).font(Theme.heading(15)).foregroundStyle(Theme.gold).frame(maxWidth: .infinity)
        }.padding(.top, first ? 0 : 6)
    }

    /// Unciv OptionsPopupHelpers.addSlider: label left, slider right; the tip shows the value (precision from the step) or a custom text.
    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, tip: ((Double) -> String)? = nil) -> some View {
        let digits = step >= 1 ? 0 : max(1, Int((-log10(step)).rounded(.up)))
        let text = tip?(value.wrappedValue) ?? String(format: "%.\(digits)f", value.wrappedValue)
        return HStack(spacing: 8) {
            Text(title).font(Theme.body).foregroundStyle(Theme.cream).multilineTextAlignment(.leading)
            Spacer()
            Text(text).font(Theme.caption).foregroundStyle(Theme.creamDim).frame(minWidth: 40, alignment: .trailing)
            EpochsSlider(value: value, range: range, step: step).frame(width: 150, height: 24)
        }
    }

    /// Unciv OptionsPopupHelpers.addSelectBox / addTranslatedSelectBox: label left, the chosen value right; the list opens in place.
    private func selectBox(_ title: String, _ options: [String], selected: String, display: @escaping (String) -> String = { L($0) }, onPick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L(title)).font(Theme.body).foregroundStyle(Theme.cream).multilineTextAlignment(.leading)
                Spacer()
                Button { openSelect = openSelect == title ? nil : title } label: {
                    HStack(spacing: 4) { Text(display(selected)).lineLimit(1); Image(systemName: openSelect == title ? "chevron.up" : "chevron.down") }
                }.buttonStyle(ThemedButtonStyle(compact: true))
            }
            if openSelect == title {
                let list = VStack(spacing: 0) {
                    ForEach(options, id: \.self) { o in
                        Button { onPick(o); openSelect = nil; refresh() } label: {
                            HStack { Image(systemName: o == selected ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.gold); Text(display(o)).font(Theme.body).foregroundStyle(Theme.cream); Spacer() }
                                .padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(8)
                Group {
                    if options.count > 10 { ScrollView { list }.frame(maxHeight: 240) } else { list }
                }.background(RoundedRectangle(cornerRadius: Theme.R.row).fill(Theme.panelDark))
            }
        }
    }

    private var popupOverlay: some View {
        ZStack {
            if let p = popup {
                Color.black.opacity(0.45).ignoresSafeArea().bleedIntoCutout().onTapGesture { if !UserSettings.neverCloseByTapOutside { popup = nil } }
                Panel(highlighted: true) {
                    VStack(spacing: 12) {
                        Text(L(p.text)).font(Theme.body).foregroundStyle(p.color).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            if let c = p.confirm {
                                Button(L("Cancel")) { popup = nil }.buttonStyle(ThemedButtonStyle(compact: true))
                                Button(L(c)) { popup = nil; p.action?(); refresh() }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                            } else {
                                Button(L("Close")) { popup = nil }.buttonStyle(ThemedButtonStyle(compact: true))
                            }
                        }
                    }
                }.frame(maxWidth: 420).padding(24)
            }
        }
    }

    // MARK: About

    /// Unciv AboutTab: banner, version, "See online Readme", "Visit repository", "Visit the wiki" (Epochs' own name and version).
    private var about: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return Panel {
            VStack(spacing: 10) {
                Text("Unciv 4X").font(Theme.title(30)).foregroundStyle(Theme.gold)
                Text(L("Epochs is built on the open-source Unciv ruleset (MPL-2.0); see UNCIV_CREDITS.md. All art and sound in Epochs are original."))
                    .font(Theme.caption).foregroundStyle(Theme.creamDim).multilineTextAlignment(.center)
                Text("\(L("Version")): \(L("[\(version)] (Build [\(build)])"))").font(Theme.body)
                Link(L("See online Readme"), destination: URL(string: "https://github.com/yairm210/Unciv/blob/master/README.md#unciv---foss-civ-v-for-androiddesktop")!).font(Theme.body).foregroundStyle(Theme.accent)
                Link(L("Visit repository"), destination: URL(string: "https://github.com/yairm210/Unciv/")!).font(Theme.body).foregroundStyle(Theme.accent)
                Link(L("Visit the wiki"), destination: URL(string: "https://yairm210.github.io/Unciv/")!).font(Theme.body).foregroundStyle(Theme.accent)
            }.frame(maxWidth: .infinity)
        }
    }

    // MARK: Display

    /// Unciv DisplayTab.addPediaUnitArtSizeSlider: setSnapToValues(threshold = 60f, 0, 32, 48, 64, 96, 120, 180, 240, 360).
    private static let pediaArtSnaps: [Double] = [0, 32, 48, 64, 96, 120, 180, 240, 360]

    /// Unciv DisplayTab: Screen, Graphics, UI, Visual Hints, Performance and Experimental.
    /// On a phone Unciv (Android) has no mouse auto-scroll or panning speed (Desktop only) and no UI skin choice beyond the default.
    private var display: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                groupHeader("Screen", first: true)
                // Unciv DisplayTab.addScreenSizeSelectBox
                selectBox("UI Scale", Theme.ScreenSize.allCases.map(\.rawValue), selected: UserSettings.screenSize) { UserSettings.screenSize = $0; controller?.refresh() }

                groupHeader("Graphics")
                // Unciv DisplayTab.addTileSetSelectBox: the unit set follows the tileset while both are the same and a unit set of that name exists
                selectBox("Tileset", Art.shared.availableSets(), selected: Art.shared.tileSet, display: { $0 }) { new in
                    let old = Art.shared.tileSet
                    Art.shared.tileSet = new
                    if old == Art.shared.unitSet && Art.shared.availableSets(units: true).contains(new) { Art.shared.unitSet = new }
                    controller?.overlaysChanged()
                }
                // Unciv DisplayTab.addUnitSetSelectBox
                selectBox("Unitset", Art.shared.availableSets(units: true), selected: Art.shared.unitSet, display: { $0 }) { Art.shared.unitSet = $0; controller?.overlaysChanged() }
                // Epochs' own vector map art (no Unciv counterpart; a design choice kept at the user's request)
                check(L("Sharp map art"), { UserSettings.hdMapArt }, { UserSettings.hdMapArt = $0; controller?.scene.resetTiles(); controller?.refresh() })

                groupHeader("UI")
                // Unciv DisplayTab.addNotificationScrollSelect: NotificationsScroll.UserSetting entries
                selectBox("Notifications on world screen", ["Disabled", "Hidden", "Visible", "Permanent"], selected: UserSettings.notificationScroll) { UserSettings.notificationScroll = $0 }
                check(L("Show minimap"), { UserSettings.showMinimap }, { UserSettings.showMinimap = $0; controller?.showMinimap = $0 })
                // Unciv DisplayTab: "Show tutorials" and "Reset tutorials" (ConfirmPopup, then "Done!") share a row
                HStack {
                    check(L("Show tutorials"), { Tutorial.enabled }, { on in Tutorial.enabled = on; if !on { controller?.currentTip = nil; controller?.currentTask = nil } })
                    Button(L(tutorialsReset ? "Done!" : "Reset tutorials")) {
                        popup = PagePopup(text: "Do you want to reset completed tutorials?", confirm: "Reset") { Tutorial.reset(); Tutorial.tasksDone = []; tutorialsReset = true }
                    }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(tutorialsReset)
                }
                check(L("Show long-press indicators"), { UserSettings.showLongPressIndicators }, { UserSettings.showLongPressIndicators = $0 })
                check(L("Show zoom buttons in world screen"), { UserSettings.showZoomButtons }, { UserSettings.showZoomButtons = $0 })
                check(L("Never close popups by clicking outside"), { UserSettings.neverCloseByTapOutside }, { UserSettings.neverCloseByTapOutside = $0 })
                check(L("Use circles to indicate movable tiles"), { UserSettings.useCirclesToIndicateMovableTiles }, { UserSettings.useCirclesToIndicateMovableTiles = $0; controller?.refresh() })
                sliderRow(L("Size of Unitset art in Civilopedia"), value: Binding(get: { UserSettings.civilopediaUnitArtSize }, set: { v in
                    UserSettings.civilopediaUnitArtSize = OptionsView.pediaArtSnaps.min { abs($0 - v) < abs($1 - v) } ?? v; tick += 1
                }), range: 0...360, step: 1)

                groupHeader("Visual Hints")
                check(L("Show unit movement arrows"), { UserSettings.showUnitMovements }, { UserSettings.showUnitMovements = $0; controller?.refresh(full: false) })
                check(L("Show suggested city locations for units that can found cities"), { UserSettings.showSettlersSuggestedCityLocations }, { UserSettings.showSettlersSuggestedCityLocations = $0; controller?.refresh() })
                check(L("Show tile yields"), { UserSettings.showTileYields }, { UserSettings.showTileYields = $0; controller?.overlaysChanged() })
                check(L("Show worked tiles"), { UserSettings.showWorkedTiles }, { UserSettings.showWorkedTiles = $0; controller?.overlaysChanged() })
                check(L("Show resources and improvements"), { UserSettings.showResourcesAndImprovements }, { UserSettings.showResourcesAndImprovements = $0; controller?.overlaysChanged() })
                check(L("Show pixel improvements"), { UserSettings.showPixelImprovements }, { UserSettings.showPixelImprovements = $0; controller?.overlaysChanged() })
                // Unciv DisplayTab.addUnitIconAlphaSlider: 0..1 step 0.1, tip in percent
                sliderRow(L("Unit icon opacity"), value: Binding(get: { UserSettings.unitIconOpacity }, set: { UserSettings.unitIconOpacity = $0; tick += 1; controller?.refresh() }),
                          range: 0...1, step: 0.1, tip: { String(format: "%.0f", $0 * 100) + "%" })

                groupHeader("Performance")
                check(L("Continuous rendering"), { UserSettings.continuousRendering }, { UserSettings.continuousRendering = $0; controller?.refresh() })
                Text(L("When disabled, saves battery life but certain animations will be suspended")).font(Theme.small).foregroundStyle(Color(red: 1, green: 0.8, blue: 0.5)).frame(maxWidth: .infinity)

                groupHeader("Experimental")
                check(L("Animate Unit movement button"), { UserSettings.animateUnitMovementButton }, { UserSettings.animateUnitMovementButton = $0 })
                check(L("Animate Unit actions menu"), { UserSettings.animateUnitActionsMenu }, { UserSettings.animateUnitActionsMenu = $0 })
            }
        }
    }

    // MARK: Gameplay

    /// Unciv GameplayTab.lateInitialize, in its order.
    private var gameplay: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                check(L("Check for idle units"), { UserSettings.checkForDueUnits }, { UserSettings.checkForDueUnits = $0 })
                check(L("'Next unit' button cycles idle units"), { UserSettings.checkForDueUnitsCycles }, { UserSettings.checkForDueUnitsCycles = $0 })
                check(L("Show Small Skip/Cycle Unit Button"), { UserSettings.showSmallUnitButton }, { UserSettings.showSmallUnitButton = $0 })
                check(L("Auto Unit Cycle"), { UserSettings.autoUnitCycle }, { UserSettings.autoUnitCycle = $0 })
                check(L("Cycle idle units by distance"), { UserSettings.cycleIdleUnitsByDistance }, { UserSettings.cycleIdleUnitsByDistance = $0 })
                check(L("Move units with a single tap"), { UserSettings.singleTapMove }, { UserSettings.singleTapMove = $0 })
                check(L("Move units with a long tap"), { UserSettings.longTapMove }, { UserSettings.longTapMove = $0 })
                check(L("Order trade offers by amount"), { UserSettings.orderTradeOffersByAmount }, { UserSettings.orderTradeOffersByAmount = $0 })
                check(L("Ask for confirmation when pressing next turn"), { UserSettings.confirmNextTurn }, { UserSettings.confirmNextTurn = $0 })
                sliderRow(L("Notifications log max turns"), value: Binding(get: { Double(UserSettings.notificationsLogMaxTurns) }, set: { UserSettings.notificationsLogMaxTurns = Int($0); tick += 1 }), range: 3...15, step: 1)
            }
        }
    }

    // MARK: Automation

    /// Unciv AutomationTab: "Automation" and "AutoPlay" headers; the per-domain AutoPlay switches are commented out there.
    private var automation: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                groupHeader("Automation", first: true)
                // Unciv AutomationTab.allCitiesChooseNextConstruction
                check(L("Auto-assign city production"), { UserSettings.autoAssignCityProduction }, { on in
                    UserSettings.autoAssignCityProduction = on
                    if on, let c = controller, c.isMyTurn {
                        // every city: chooseNextConstruction itself keeps a real construction or a perpetual the player set
                        for city in c.state.cities(of: c.state.playerId) { c.state.chooseNextConstruction(cityId: city.id) }
                        c.refresh(full: false)
                    }
                })
                check(L("Auto-build roads"), { UserSettings.autoBuildRoads }, { UserSettings.autoBuildRoads = $0 })
                check(L("Automated workers replace improvements"), { UserSettings.automatedWorkersReplaceImprovements }, { UserSettings.automatedWorkersReplaceImprovements = $0 })
                check(L("Stop automated workers from removing vegetation terrain"), { !UserSettings.automatedWorkersRemoveVegetation }, { UserSettings.automatedWorkersRemoveVegetation = !$0 })
                check(L("Automated units move on turn start"), { UserSettings.automatedUnitsMoveOnTurnStart }, { UserSettings.automatedUnitsMoveOnTurnStart = $0 })
                check(L("Automated units can upgrade"), { UserSettings.automatedUnitsCanUpgrade }, { UserSettings.automatedUnitsCanUpgrade = $0 })
                check(L("Automated units choose promotions"), { UserSettings.automatedUnitsChoosePromotions }, { UserSettings.automatedUnitsChoosePromotions = $0 })
                check(L("Cities auto-bombard at end of turn"), { UserSettings.citiesAutoBombardAtEndOfTurn }, { UserSettings.citiesAutoBombardAtEndOfTurn = $0 })
                check(L("Auto-assign specialists in new cities"), { UserSettings.autoAssignSpecialistsInNewCities }, { UserSettings.autoAssignSpecialistsInNewCities = $0 })

                groupHeader("AutoPlay")
                check(L("Show AutoPlay button"), { UserSettings.showAutoPlayButton }, { UserSettings.showAutoPlayButton = $0; controller?.stopAutoPlay() })
                check(L("AutoPlay until victory"), { UserSettings.autoPlayUntilEnd }, { UserSettings.autoPlayUntilEnd = $0 })
                if !UserSettings.autoPlayUntilEnd {
                    sliderRow(L("Multi-turn AutoPlay amount"), value: Binding(get: { Double(UserSettings.autoPlayMaxTurns) }, set: { UserSettings.autoPlayMaxTurns = Int($0); tick += 1 }), range: 1...200, step: 1)
                }
            }
        }
    }

    // MARK: Language

    /// Unciv LanguageTab + LanguageTable.addLanguageTables: the disclaimer, then English, the system language and the rest by completion
    /// (L10n.languageTables, shared with the first-launch picker); a tap selects the language at once.
    private var language: some View {
        let tables = L10n.languageTables()
        let chosen = L10n.language
        return Panel {
            VStack(alignment: .leading, spacing: 6) {
                LanguageDisclaimer()   // Unciv LanguageTable translationDisclaimer
                ForEach(tables, id: \.language) { row in
                    let lang = row.language
                    // (not while a turn runs on its clone: the turn's thread reads the translations the reload replaces)
                    Button { if lang != chosen, controller?.isProcessing != true { L10n.override = lang; GameEvents.post(.languageChanged(lang, source: nil)); controller?.refresh() }; tick += 1 } label: {
                        // LanguageTable: "$spaceSplitLang ($percentComplete%)".toLabel()
                        Text(L("\(lang.replacingOccurrences(of: "_", with: " ")) (\(row.percent)%)")).font(Theme.body).foregroundStyle(Theme.cream)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: Theme.R.row).fill(chosen == lang ? Theme.panelLight : Theme.panelDark))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(controller?.isProcessing == true)
                }
            }
        }
    }

    // MARK: Sound

    /// Unciv MusicControls.addMusicPauseSlider: slider positions 0..30 map to 0-1-2..10-12-14..30-35-40..60-75-90-105-120 seconds.
    static func posToLength(_ pos: Double) -> Double {
        switch pos {
        case 0...10: return pos
        case 11...20: return pos * 2 - 10
        case 21...26: return pos * 5 - 70
        default: return pos * 15 - 330
        }
    }
    static func lengthToPos(_ length: Double) -> Double {
        switch length {
        case 0...10: return floor(length)
        case 11...30: return floor((length + 10) / 2)
        case 31...60: return floor((length + 10) / 5)
        default: return floor((length + 330) / 15)
        }
    }

    /// Unciv SoundTab: effect and city ambience volumes, then (with music available) MusicControls.addMusicControls. Unciv's
    /// "Download music" (a third-party track from Dropbox) is left out: the app plays only its own music and the player's.
    /// Leader voices only appear when voice files exist (music.isVoicesAvailable), which Epochs has none of.
    private var sound: some View {
        let music = MusicController.shared
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                VolumeRow(title: L("Sound effects volume"), value: $soundVolume) { Audio.shared.soundEffectsVolume = Float($0); Audio.shared.play("slider", volume: 0.5) }
                VolumeRow(title: L("City ambient sound volume"), value: $cityVolume) { Audio.shared.citySoundsVolume = Float($0); Audio.shared.play("slider", volume: 0.5) }
                if music.isMusicAvailable {
                    // Unciv MusicControls.addMusicVolumeSlider: silent slider, starts a track when nothing plays
                    VolumeRow(title: L("Music volume"), value: $musicVolume) { v in
                        music.musicVolume = Float(v)
                        if !music.isPlaying { music.chooseTrack(flags: .setPlayDefault) }
                    }
                    sliderRow(L("Pause between tracks"), value: $musicPausePos, range: 0...30, step: 1, tip: { String(format: "%.0f", OptionsView.posToLength($0)) })
                        .onChange(of: musicPausePos) { _, v in music.pauseBetweenTracks = Int(OptionsView.posToLength(v)) }
                    // Unciv MusicControls.addMusicCurrentlyPlaying
                    Text(L("Currently playing: [\(currentTrack.display)]")).font(Theme.body).foregroundStyle(Color(red: 0.82, green: 0.69, blue: 1)).padding(.top, 10)
                    // Unciv MusicControls.addSimplePlayerControls: pause, resume, next track
                    HStack(spacing: 25) {
                        Button { music.pause(speedFactor: 0.5) } label: { Image(systemName: "pause.fill").foregroundStyle(Theme.gold) }
                        Button { music.resume(speedFactor: 0.5) } label: { Image(systemName: "play.fill").foregroundStyle(Color.green) }
                        Button { music.skip() } label: { Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.purple) }
                    }.buttonStyle(ThemedButtonStyle(compact: true)).frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { music.onChange = { t in currentTrack = t } }
        .onDisappear { music.onChange = nil }   // Unciv: the popup's close listener clears music.onChange
    }

    // MARK: Multiplayer

    /// Unciv IMediaFinder.LabeledSounds: the prettified names first (also their order), the other bundled UncivSounds title-cased,
    /// then the base ruleset's unit attack sounds; "nuke", "fire" and "slider" are left out.
    private static var labeledSounds: [(sound: String, label: String)] {
        var out: [(String, String)] = [("", "None"), ("notification1", "Notification [1]"), ("notification2", "Notification [2]"), ("coin", "Buy"),
                                      ("construction", "Create"), ("paper", "Pick a tech"), ("policy", "Adopt policy"), ("setup", "Set up"), ("swap", "Swap units")]
        func put(_ s: String, _ label: String) { if let i = out.firstIndex(where: { $0.0 == s }) { out[i].1 = label } else { out.append((s, label)) } }
        for s in ["bombard", "chimes", "choir", "click", "coin", "construction", "fire", "fortify", "notification1", "notification2", "paper", "policy", "promote", "setup", "", "slider", "swap", "upgrade", "whoosh"]
            where !out.contains(where: { $0.0 == s }) { out.append((s, s.prefix(1).uppercased() + s.dropFirst())) }
        var seen = Set<String>()
        for name in Ruleset.shared.unitOrder {
            guard let s = Ruleset.shared.units[name]?.attackSound, seen.insert(s).inserted else { continue }
            put(s, "[\(name)] Attack Sound")
        }
        return out.filter { !["nuke", "fire", "slider"].contains($0.0) }
    }

    /// Unciv Duration.format for a refresh delay: "[n] Minutes", "[n] Seconds", joined by ", " when both are there.
    static func refreshDelayLabel(_ seconds: Int) -> String {
        var parts: [String] = []
        if seconds / 60 > 0 { parts.append(L("[\(seconds / 60)] Minutes")) }
        if seconds % 60 > 0 { parts.append(L("[\(seconds % 60)] Seconds")) }
        return parts.joined(separator: ", ")
    }

    /// Unciv MultiplayerTab: status button, the two refresh intervals, turn notification sounds, then the server options.
    /// The out-of-game turn checker ("Enable out-of-game turn notifications" …) is Android only in Unciv.
    private var multiplayer: some View {
        let sounds = OptionsView.labeledSounds
        let soundLabel = { (s: String) in L(sounds.first { $0.sound == s }?.label ?? s) }
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                check(L("Enable multiplayer status button in singleplayer games"), { UserSettings.multiplayerStatusInSingleplayer }, { UserSettings.multiplayerStatusInSingleplayer = $0 })
                Divider2()
                // Unciv MultiplayerTab: two RefreshSelectOptions, each offering its extraCustomServerOptions ahead of the Dropbox
                // ones when Multiplayer.usesCustomServer() - always, as ours never talks to Dropbox.
                // currentGameRefreshDelay: SECONDS 3, 5 + SECONDS 10, 20, 30, 60; the poll reads it afresh each round
                selectBox("Update status of currently played game every:", ["3", "5", "10", "20", "30", "60"], selected: "\(Multiplayer.currentGameRefreshSeconds)", display: { OptionsView.refreshDelayLabel(Int($0) ?? 0) }) { Multiplayer.currentGameRefreshSeconds = Int($0) ?? 10 }
                // allGameRefreshDelay: SECONDS 15, 30 + MINUTES 1, 2, 5, 15
                selectBox("In-game, update status of all games every:", ["15", "30", "60", "120", "300", "900"], selected: "\(Multiplayer.allGameRefreshSeconds)", display: { OptionsView.refreshDelayLabel(Int($0) ?? 0) }) { Multiplayer.allGameRefreshSeconds = Int($0) ?? 300 }
                Divider2()
                selectBox("Sound notification for when it's your turn in your currently open game:", sounds.map(\.sound), selected: Multiplayer.currentGameTurnNotificationSound, display: soundLabel) { s in
                    Multiplayer.currentGameTurnNotificationSound = s; if !s.isEmpty { Audio.shared.play(s) }
                }
                selectBox("Sound notification for when it's your turn in any other game:", sounds.map(\.sound), selected: Multiplayer.otherGameTurnNotificationSound, display: soundLabel) { s in
                    Multiplayer.otherGameTurnNotificationSound = s; if !s.isEmpty { Audio.shared.play(s) }
                }
                Divider2()
                serverOptions
            }
        }
    }

    /// Unciv MultiplayerTab.fixTextFieldUrlOnType + the onChange check: repeated slashes collapse (except after ':'),
    /// the address must be http(s), and only a valid address is stored.
    private func serverChanged(_ text: String) {
        let fixed = text.replacingOccurrences(of: "(?<!:)/{2,}", with: "/", options: .regularExpression)
        if fixed != text { serverText = fixed; return }
        var trimmed = fixed
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme, scheme == "http" || scheme == "https" else {
            serverError = "URL must start with http:// or https://"; serverValid = false; return
        }
        guard url.host?.isEmpty == false else { serverError = nil; serverValid = false; return }
        Multiplayer.serverURL = url.absoluteString
        password = Multiplayer.password
        serverError = nil; serverValid = true
    }

    /// Unciv MultiplayerTab.addMultiplayerServerOptions: "Server address" (a tap pastes the clipboard), the address field,
    /// "Check connection", and the password block for servers with authentication.
    private var serverOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { if let s = UIPasteboard.general.string { serverText = s } } label: { Text(L("Server address")).font(Theme.body).foregroundStyle(Theme.cream).frame(maxWidth: .infinity) }.buttonStyle(.plain)
            if let e = serverError { Text(L(e)).font(Theme.caption).foregroundStyle(Theme.danger).frame(maxWidth: .infinity) }
            HStack(spacing: 8) {
                TextField(L("Server address"), text: $serverText).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never).font(Theme.body)
                    .foregroundStyle(serverValid == nil ? Color.primary : (serverValid! ? Color.green : Color.red))
                    .onChange(of: serverText) { _, v in serverChanged(v) }
                Button(L("Check connection")) {
                    popup = PagePopup(text: "Awaiting response...")
                    Task {
                        // Unciv successfullyConnectedToServer: mpServer.checkServerStatus() (the feature set too), then
                        // authenticate(null) with the stored password - a MultiplayerAuthException makes it false, any other
                        // failure leaves it null
                        let ok = await Multiplayer.checkServerStatus()
                        var authOK: Bool? = nil
                        if ok {
                            do { authOK = try await Multiplayer.authenticate(password: Multiplayer.password) }
                            catch Multiplayer.MPError.auth { authOK = false }
                            catch {}
                        }
                        if authOK == false {
                            // the popup closes for AuthPopup, and comes back with its answer
                            popup = nil
                            authRetry = { success in popup = PagePopup(text: success ? "Success!" : "Failed!") }
                        } else if ok {
                            popup = PagePopup(text: authOK == true ? "Success!" : "Auth rejected for unknown reasons, please try again.")
                        } else {
                            popup = PagePopup(text: "Failed!")
                        }
                        if ok { serverText = Multiplayer.serverURL }
                    }
                }.buttonStyle(ThemedButtonStyle(compact: true))
            }
            // Unciv: the password block only `if (mpServer.getFeatureSet().authVersion > 0)`
            if authVersion > 0 {
                Text(L("Set password")).font(Theme.body).frame(maxWidth: .infinity).padding(.top, 16)
                SecureField(L("Password"), text: $password).textFieldStyle(.roundedBorder).font(Theme.body)
                HStack(spacing: 16) {
                    Text(L(authStatus)).font(Theme.caption).foregroundStyle(Theme.creamDim)
                    Button(L("Set password")) { setPassword(password) }.buttonStyle(ThemedButtonStyle(compact: true))
                }.frame(maxWidth: .infinity)
            }
        }
        .task {
            authVersion = ServerFeatures.shared.featureSet.authVersion
            if authVersion > 0 { await validateAuth() }
        }
    }

    /// Unciv MultiplayerTab: with a stored password the auth status is checked against the server.
    private func validateAuth() async {
        guard !Multiplayer.password.isEmpty else { authStatus = "Set a password to secure your userId"; return }
        authStatus = "Validating your authentication status..."
        switch await Multiplayer.checkAuthStatus() {
        case .unauthorized: authStatus = "Your current password was rejected from the server"
        case .unregistered: authStatus = "You userId is unregistered! Set password to secure your userId"
        case .verified: authStatus = "Your current password has been succesfully verified"
        case .unknown: authStatus = "Your authentication status could not be determined"
        }
    }

    /// Unciv MultiplayerTab.setPassword: blank does nothing, fewer than 6 characters is refused, a server without
    /// authentication says so, otherwise the server is asked. A MultiplayerAuthException opens AuthPopup: authenticated,
    /// the popup closes and the same password is set again; refused, "Failed to set password!". The Dropbox-only
    /// FileStorageRateLimitReached message never comes up, as ours talks to UncivServer-style servers only.
    private func setPassword(_ newPassword: String) {
        guard !newPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        popup = PagePopup(text: "Awaiting response...")
        guard newPassword.count >= 6 else { popup = PagePopup(text: "Password must be at least 6 characters long"); return }
        guard ServerFeatures.shared.featureSet.authVersion != 0 else { popup = PagePopup(text: "This server does not support authentication"); return }
        Task {
            do {
                let ok = try await Multiplayer.setPassword(newPassword)
                popup = PagePopup(text: ok ? "Password set successfully for server [\(Multiplayer.serverURL)]" : "Failed to set password!")
            } catch Multiplayer.MPError.auth {
                authRetry = { authSuccess in
                    if authSuccess { popup = nil; setPassword(newPassword) } else { popup = PagePopup(text: "Failed to set password!") }
                }
            } catch { popup = PagePopup(text: "Failed to set password!") }
        }
    }

    // MARK: Keys

    /// Unciv KeyboardBinding.Category.checkConflictsIn: World screen keys clash with panning and unit action keys, panning with World screen,
    /// unit actions only with World screen (not among themselves); every other category only within itself.
    private static let conflictScopes: [String: [String]] = [
        "World screen": ["World screen", "Map panning", "Unit actions"], "Map panning": ["Map panning", "World screen"], "Unit actions": ["World screen"],
    ]
    /// Unciv KeyBindingsTab.onKeyHit: the bindings whose key is used twice within their conflict scope.
    private func keyConflicts() -> Set<String> {
        let groups = Dictionary(KeyBindings.groups.map { ($0.0, $0.1.map { $0.0 }) }, uniquingKeysWith: { a, _ in a })
        var out = Set<String>()
        for (category, names) in groups {
            var used = Set<String>(), conflicting = Set<String>()
            for scopeCategory in OptionsView.conflictScopes[category] ?? [category] {
                for n in groups[scopeCategory] ?? [] {
                    let key = KeyBindings.spec(n).stored
                    if used.contains(key) || scopeCategory != category { conflicting.insert(key) } else { used.insert(key) }
                }
            }
            for n in names where conflicting.contains(KeyBindings.spec(n).stored) { out.insert(n) }
        }
        return out
    }

    /// Unciv KeyBindingsTab: the work-in-progress disclaimer with the tutorial link, then one collapsed expander per category
    /// (categories and bindings sorted by translated label). A KeyCapturingButton shows the key grey while it is the default and
    /// red on a conflict; tap it and hit the key, double tap resets it to the default.
    private var keys: some View {
        let conflicts = keyConflicts()
        let groups = KeyBindings.groups
            .map { g in (g.0, g.1.map { $0.0 }.sorted { LocaleCode.compare(L(KeyBindings.label($0)), L(KeyBindings.label($1))) == .orderedAscending }) }
            .sorted { LocaleCode.compare(L($0.0), L($1.0)) == .orderedAscending }
        return Panel {
            VStack(alignment: .leading, spacing: 6) {
                VStack(spacing: 6) {
                    Text(L("This is a work in progress.")).font(Theme.body).foregroundStyle(Color(red: 0.7, green: 0.13, blue: 0.13))
                    if let c = controller {
                        Button(L("Please see the Tutorial.")) {
                            onClose()
                            c.afterSheetDismiss { c.civilopediaEntry = "Tutorial/Keyboard Bindings"; c.showCivilopedia = true }
                        }.buttonStyle(.plain).font(Theme.body).foregroundStyle(Theme.accent)
                    } else {
                        Text(L("Please see the Tutorial.")).font(Theme.body)
                    }
                    Divider2()
                }.frame(maxWidth: .infinity)
                ForEach(groups, id: \.0) { group, names in
                    Button {
                        if openKeyGroups.contains(group) { openKeyGroups.remove(group) } else { openKeyGroups.insert(group) }
                        OptionsView.keyGroupsOpen = openKeyGroups
                    } label: {
                        HStack { Text(L(KeyBindings.groupLabel(group))).font(Theme.heading(14)).foregroundStyle(Theme.gold); Spacer(); Image(systemName: openKeyGroups.contains(group) ? "chevron.up" : "chevron.down").foregroundStyle(Theme.gold) }
                            .padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if openKeyGroups.contains(group) {
                        ForEach(names, id: \.self) { name in keyRow(name, conflict: conflicts.contains(name)) }
                    }
                }
            }
            .focusable()
            .onKeyPress { press in
                guard let name = rebinding else { return .ignored }
                let text = KeySpec.namedKeys.first { $0.value == press.key }?.key ?? String(press.key.character)
                guard !text.isEmpty else { rebinding = nil; return .handled }
                KeyBindings.set(name, KeySpec(text, press.modifiers))
                rebinding = nil; refresh()
                return .handled
            }
            // The function keys never reach onKeyPress: FunctionKeys hands them over while a binding waits for its key
            .onAppear {
                FunctionKeys.register(functionKeyCaptureId) { spec in
                    guard let name = rebinding else { return false }
                    KeyBindings.set(name, spec); rebinding = nil; refresh()
                    return true
                }
            }
            .onDisappear { FunctionKeys.unregister(functionKeyCaptureId) }
        }
    }

    private func keyRow(_ name: String, conflict: Bool) -> some View {
        let spec = KeyBindings.spec(name)
        let isDefault = !KeyBindings.isChanged(name)
        let capturing = rebinding == name
        return VStack(alignment: .trailing, spacing: 2) {
            HStack {
                Text(L(KeyBindings.label(name))).font(Theme.body).foregroundStyle(Theme.cream)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "keyboard").foregroundStyle(capturing ? Color.green : Theme.creamDim)
                    Text(spec.key == "Esc" ? "ESC/Back" : spec.label).font(Theme.caption.bold())
                        .foregroundStyle(conflict ? Color.red : (isDefault ? Color.gray : Theme.cream))
                        .frame(minWidth: 90)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Theme.R.chip).fill(capturing ? Theme.fillStrong : Theme.fill))
                .contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded { KeyBindings.set(name, nil); rebinding = nil; refresh() }
                    .exclusively(before: TapGesture().onEnded { rebinding = capturing ? nil : name }))
            }
            if capturing { Text(L("Hit the desired key now")).font(Theme.small).foregroundStyle(Theme.creamDim) }
        }
    }

    // MARK: Advanced

    /// Unciv Display.hasCutout on a phone: the screen has a notch or island intruding into the safe area.
    private static var hasCutout: Bool {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
        let insets = window?.safeAreaInsets ?? .zero
        return max(insets.left, insets.right) > 0 || insets.top > 24
    }

    /// Unciv AdvancedTab.autosaveFieldEnterClicked: 0 is refused, 200 or more is stored with a warning.
    private func autosaveEnter() {
        guard let n = Int(autosaveText) else { return }
        if n <= 0 { popup = PagePopup(text: "Autosave turns must be larger than 0!", color: Theme.danger); return }
        UserSettings.maxAutosavesStored = n
        if n >= 200 { popup = PagePopup(text: "Autosave turns over 200 may take a lot of space on your device.", color: .orange) }
        tick += 1
    }

    /// Unciv AdvancedTab.addGestureControls: the test area names the gesture it saw, and reverts after 3 seconds.
    private func testArea(_ text: String) {
        testAreaText = text
        let token = UUID(); testAreaToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if testAreaToken == token { testAreaText = "Test area" } }
    }

    /// Unciv AdvancedTab.lateInitialize, in its order. "Generate translation files" is Desktop only; "Enable experimental A* pathing",
    /// "Update Mod categories" and "Generate screenshots" have no Epochs counterpart.
    private var advanced: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                // Unciv AdvancedTab.addAutosaveField
                HStack {
                    Text(L("Number of autosave files stored")).font(Theme.body)
                    Spacer()
                    TextField("", text: $autosaveText).keyboardType(.numberPad).textFieldStyle(.roundedBorder).font(Theme.body).frame(width: 90)
                        .onChange(of: autosaveText) { _, v in let f = String(v.filter(\.isNumber).prefix(8)); if f != v { autosaveText = f } }
                    Button(L("Enter")) { autosaveEnter() }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(Int(autosaveText) == UserSettings.maxAutosavesStored)
                }
                selectBox("Turns between autosaves", ["1", "2", "5", "10", "20", "50", "100", "1000"], selected: "\(UserSettings.turnsBetweenAutosaves)", display: { $0 }) { UserSettings.turnsBetweenAutosaves = Int($0) ?? 1 }
                Divider2()
                if OptionsView.hasCutout {
                    check(L("Enable using display cutout areas"), { UserSettings.useDisplayCutout }, { UserSettings.useDisplayCutout = $0; controller?.refresh(full: false) })
                }
                check(L("Hide system status and navigation bars"), { UserSettings.hideSystemBars }, { UserSettings.hideSystemBars = $0 })
                // Unciv AdvancedTab.addFontFamilySelect: the default font, then the system fonts
                selectBox("Font family", [""] + UIFont.familyNames.sorted(), selected: UserSettings.fontFamily, display: { $0.isEmpty ? L("Default Font") : $0 }) { UserSettings.fontFamily = $0 }
                sliderRow(L("Font size multiplier"), value: Binding(get: { UserSettings.fontSizeMultiplier }, set: { UserSettings.fontSizeMultiplier = $0; tick += 1 }), range: 0.7...1.5, step: 0.05)
                Divider2()
                // Unciv AdvancedTab.addGestureControls
                sliderRow(L("Long press delay"), value: Binding(get: { Double(UserSettings.longPressDelay) / 1000 }, set: { UserSettings.longPressDelay = Int(($0 * 1000).rounded()); tick += 1 }), range: 0.2...4, step: 0.1)
                    .padding(.top, 20)
                sliderRow(L("Double tap interval"), value: Binding(get: { UserSettings.multiTapInterval }, set: { UserSettings.multiTapInterval = $0; tick += 1 }), range: 0.15...1, step: 0.05)
                Text(L(testAreaText)).font(Theme.body).frame(minWidth: 240).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: Theme.R.control).fill(Theme.fillStrong))
                    .contentShape(Rectangle())
                    // Unciv AdvancedTab.addGestureControls: the test button's onActivation(Tap / Doubletap / Longpress) goes through
                    // the same ActivationListener as every other actor, so it answers the two sliders above - Tap at once,
                    // Doubletap within multiTapInterval, no tap after a long press
                    .uncivTaps(longPressFired: $testAreaLongPressFired, onTap: { testArea("Single tap") }, onDoubleTap: { testArea("Double-click") })
                    .uncivLongPress(fired: $testAreaLongPressFired) { testArea("Long press") }
                    .frame(maxWidth: .infinity)
                Divider2()
                // Unciv AdvancedTab.addMaxZoomSlider: 2..6 step 1
                sliderRow(L("Max zoom out"), value: Binding(get: { UserSettings.maxWorldZoomOut }, set: { UserSettings.maxWorldZoomOut = $0; tick += 1 }), range: 2...6, step: 1)
                    .padding(.top, 20)
                check(L("Enable Easter Eggs"), { UserSettings.enableEasterEggs }, { UserSettings.enableEasterEggs = $0 })
                check(L("Enlarge selected notifications"), { UserSettings.enlargeSelectedNotifications }, { UserSettings.enlargeSelectedNotifications = $0 })
                Divider2()
                privacySection
                Divider2()
                // Unciv AdvancedTab.addSetUserId
                VStack(spacing: 4) {
                    Button(L("Take user ID from clipboard")) {
                        if let id = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), UUID(uuidString: id) != nil {
                            popup = PagePopup(text: "Doing this will reset your current user ID to the clipboard contents - are you sure?", confirm: "Take user ID from clipboard") {
                                Multiplayer.setUserId(id); idSetLabel = ("ID successfully set!", true)
                            }
                        } else { idSetLabel = ("Invalid ID!", false) }
                    }.buttonStyle(ThemedButtonStyle(compact: true))
                    if let l = idSetLabel { Text(L(l.text)).font(Theme.caption).foregroundStyle(l.ok ? Theme.cream : Theme.danger) }
                }.frame(maxWidth: .infinity).padding(5)
            }
        }
    }

    // MARK: Locate mod errors

    /// Unciv ModCheckTab.runModChecker: re-read the mods and validate each one; opened expanders first, then by name.
    private func runModCheck() {
        modChecking = true
        DispatchQueue.main.async {
            Ruleset.clearModOptionsCache()
            modResults = Ruleset.availableMods()
                .sorted { a, b in openMods.contains(a) != openMods.contains(b) ? openMods.contains(a) : a < b }
                .map { mod in
                    // Unciv: sorted by severity, a blank line after any results, "No problems found." when nothing is wrong
                    var lines = RulesetValidator.validate(mod: mod).sorted { $0.severity > $1.severity }
                    if !lines.isEmpty { lines.append(RulesetError(text: "", severity: .OK)) }
                    if RulesetValidator.finalSeverity(lines) == .OK { lines.append(RulesetError(text: L("No problems found."), severity: .OK)) }
                    return (mod, lines)
                }
            modChecking = false
        }
    }

    private static func severityColor(_ s: RulesetErrorSeverity) -> Color {
        switch s { case .OK: return .green; case .WarningOptionsOnly, .Warning: return .yellow; case .ErrorOptionsOnly: return .orange; case .Error: return .red }
    }

    /// Unciv ModCheckTab: "Reload mods", a search field once there are more than 10 rulesets, and one collapsed expander per mod
    /// headed by its severity, listing the lines in their severity colour, with "Copy to clipboard" when something is wrong.
    private var modErrors: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer().frame(width: 30)
                Spacer()
                Button(L("Reload mods")) { runModCheck() }.buttonStyle(ThemedButtonStyle(compact: true))
                Spacer()
                ProgressView().tint(Color.red).opacity(modChecking ? 1 : 0).frame(width: 30)
            }
            if Ruleset.availableMods().count + 2 > 10 {   // Unciv: RulesetCache.size > 10 (the two base rulesets count)
                TextField(L("Search mods"), text: $modSearch).textFieldStyle(.roundedBorder).font(Theme.body)
            }
            ForEach(modResults.filter { modSearch.isEmpty || $0.mod.localizedCaseInsensitiveContains(modSearch) }, id: \.mod) { result in
                let worst = RulesetValidator.finalSeverity(result.errors)
                Panel(padding: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            if openMods.contains(result.mod) { openMods.remove(result.mod) } else { openMods.insert(result.mod) }
                        } label: {
                            HStack {
                                Image(systemName: worst == .OK ? "checkmark" : worst == .Error ? "xmark.octagon.fill" : "exclamationmark")
                                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.black.opacity(0.75))
                                    .frame(width: 26, height: 26).background(Circle().fill(OptionsView.severityColor(worst)))
                                Text(result.mod).font(Theme.heading(14)).foregroundStyle(Theme.cream)
                                Spacer()
                                Image(systemName: openMods.contains(result.mod) ? "chevron.up" : "chevron.down").foregroundStyle(Theme.gold)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if openMods.contains(result.mod) {
                            ForEach(result.errors) { e in
                                Text(e.text).font(Theme.small).foregroundStyle(OptionsView.severityColor(e.severity)).fixedSize(horizontal: false, vertical: true)
                            }
                            if worst != .OK {
                                Button(L("Copy to clipboard")) { UIPasteboard.general.string = result.errors.map(\.text).joined(separator: "\n") }.buttonStyle(ThemedButtonStyle(compact: true))
                            }
                        }
                    }
                }
            }
        }
        .onAppear { runModCheck() }
    }

    // MARK: Debug

    /// Unciv DebugTab.unlockAllTechs: every missing tech for the current player, without the tech popups.
    private func unlockAllTechs(_ c: GameController) {
        guard !c.isProcessing else { return }   // Unciv canChangeState: the turn is being played on a clone
        let pid = c.state.playerId
        guard let i = c.state.civIndex(pid) else { return }
        for tech in c.state.rs.techs.keys.sorted() where !c.state.civs[i].techs.contains(tech) {
            c.state.addTechnology(civId: pid, tech: tech)
            if !c.state.civs[i].popupAlerts.isEmpty { c.state.civs[i].popupAlerts.removeLast() }
        }
        c.state.updateCivResources(pid)
        c.refresh()
    }

    /// Unciv DebugTab: the simulation controls (with a game), the map overlays, god mode, and the tech / resource cheats.
    private var debug: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                if let c = controller {
                    // Unciv DebugTab.addSimulationControls
                    HStack {
                        Button(L("Simulate until turn:")) {
                            guard let t = Int(simulateTurn) else { simulateInvalid = true; return }
                            simulateInvalid = false
                            if t > c.state.turn { onClose(); c.startAutoPlay(turns: t - c.state.turn) }
                        }.buttonStyle(ThemedButtonStyle(compact: true))
                        TextField(L("Turn"), text: $simulateTurn).keyboardType(.numberPad).textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                    if simulateInvalid { Text(L("This is not a valid integer!")).font(Theme.caption) }
                }
                check(L("View entire map"), { UserSettings.debugVisibleMap }, { UserSettings.debugVisibleMap = $0; controller?.revealForDebug(); controller?.scene.resetTiles(); controller?.refresh() })
                check(L("Show coordinates on tiles"), { UserSettings.debugShowTileCoords }, { UserSettings.debugShowTileCoords = $0; controller?.refresh() })
                check(L("Show settler scores on tiles"), { UserSettings.debugShowSettlerScores }, { UserSettings.debugShowSettlerScores = $0; controller?.refresh() })
                if let c = controller {
                    check(L("God mode (current game)"), { c.state.settings.godMode }, { if !c.isProcessing { c.state.settings.godMode = $0 }; c.refresh() })
                    Button(L("Unlock all techs")) { unlockAllTechs(c); refresh() }.buttonStyle(ThemedButtonStyle(compact: true)).frame(maxWidth: .infinity)
                    Button(L("Get all strategic resources")) { c.grantStrategicResourcesForDebug(); refresh() }.buttonStyle(ThemedButtonStyle(compact: true)).frame(maxWidth: .infinity)
                }
            }
        }
    }
}
