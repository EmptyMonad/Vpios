// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import SpriteKit

struct GameView: View {
    @ObservedObject var controller: GameController
    let onQuit: () -> Void
    var onStart: (GameState) -> Void = { _ in }
    @State private var showSave = false
    @State private var showLoad = false
    @State private var showNewGame = false
    @Environment(\.scenePhase) private var scenePhase   // Unciv UncivGame.pause: autosave when the app is backgrounded
    @State private var showOptions = false
    @State private var optionsWithDebug = false
    /// Unciv WorldScreen.update's coveredNotificationsTop = `stage.height - statusButtons.y`: where the status buttons end, in
    /// the world screen's coordinates (worldSpace)
    @State private var statusButtonsBottom: CGFloat? = nil
    /// Unciv WorldScreen.update's coveredNotificationsBottom = `bottomTileInfoTable.height + bottomTileInfoTable.y`: the frames
    /// of the views in the bottom right corner - the tile info, the minimap and its buttons (coversNotificationsBottom) - in
    /// worldSpace; the pane's bottom spacer reaches up to the highest of those that run across it
    @State private var notificationsBottomCovers: [CGRect] = []
    /// The notification layer's frame in worldSpace: the pane runs its full height at its right edge (NotificationsScroll
    /// `height = worldScreen.stage.height * inverseScaleFactor` in a pane scaled by 0.5), and the covered parts are measured
    /// from its ends
    @State private var notificationsLayerFrame: CGRect = .zero
    /// The notification entries' own size: the pane is framed to its width (Unciv NotificationsScroll.updateLayout)
    @State private var notificationsSize: CGSize = .zero
    /// The frames of the views over the notification pane (coversNotifications), in worldSpace: the pane takes no touch there
    @State private var notificationsCovers: [CGRect] = []
    /// WorldMapView's frame in worldSpace (it ignores the safe area): the notification pane, which it holds, is placed in its
    /// coordinates
    @State private var mapFrame: CGRect = .zero
    /// The coordinate space the notification pane, the status buttons and the tile info are measured in: the world screen's
    private static let worldSpace = "GameView.world"
    /// Unciv NotificationsScroll.rightPadToScreenEdge: the gap between an entry or a category header and the screen's right
    /// edge is padding inside the ListItem and the CategoryHeader, both `Touchable.enabled`, so a touch there is theirs and
    /// not the map's. Ours is 10 points, as far in as the status buttons.
    private static let notificationsEdgePad: CGFloat = 10
    /// Unciv NotificationsScroll.listItemPad (3 in a pane scaled by 0.5): the ListItem's padding on its left, top and bottom
    /// and the category caption's, inside their click areas
    private static let notificationsItemPad: CGFloat = 1.5
    /// Unciv AutoPlayStatusButton: a long press starts AutoPlay and its lift is no tap (uncivLongPress)
    @State private var autoPlayLongPressFired = false
    /// Unciv's stage.width: the window's width on the virtual canvas (VirtualCanvas), the screen's off it
    @Environment(\.stageWidth) private var canvasStageWidth
    private var stageWidth: CGFloat { canvasStageWidth > 0 ? canvasStageWidth : Theme.canvasWidth }

    var body: some View {
        let _ = UIMeasure.count("GameView.body")
        let notifications = notificationsModel
        ZStack {
            // Unciv WorldScreen.init: the WorldMapHolder, then `stage.addActor(notificationsScroll) // very low in z-order, so
            // we're free to let it extend _below_ tile info and minimap if we want` - right above the map, under everything
            // else the world screen shows: the tutorial task ("behind topBar!"), the top bar, the status buttons, the unit
            // table, the tile info, the minimap and the battle table lie over it, and take the touches where they are. The
            // pane is a UIKit sibling right above the map's SKView (WorldMapView), so what it turns down reaches the map.
            WorldMapView(scene: controller.scene, notifications: notificationsPane(notifications))
                .ignoresSafeArea().bleedIntoCutout()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.worldSpace)) } action: { mapFrame = $0 }
            notificationsLayer(notifications)
            // Everything under the top bar shares one ZStack rather than a column. In a column the status
            // buttons, the notification list and the tutorial task each claim their own height, and on a phone
            // their sum passes the screen: SwiftUI then centres the column and clips the top bar off the top and
            // the unit card off the bottom. Unciv has no such problem because Scene2D positions each cluster
            // absolutely - a cluster that grows never moves its neighbours. This is that, in SwiftUI terms.
            VStack(spacing: 0) {
                TopBar(controller: controller) {
                    GameMenu(controller: controller, onQuit: onQuit,
                             onSave: { controller.showMenu = false; showSave = true },
                             onLoad: { controller.showMenu = false; showLoad = true },
                             onNewGame: { controller.showMenu = false; showNewGame = true },
                             onOptions: { controller.showMenu = false; optionsWithDebug = false; showOptions = true },   // the options task completes in OptionsView.onAppear
                             onOptionsDebug: { controller.showMenu = false; optionsWithDebug = true; showOptions = true },
                             onQuicksave: { controller.showMenu = false; quicksave() },
                             onQuickload: { guard !controller.isProcessing else { return }; if let loaded = try? SaveManager.load(name: "QuickSave") { controller.showMenu = false; controller.flash("Quickload successful."); controller.afterSheetDismiss { onStart(loaded) } } else { controller.flash("Could not load game!") } })
                }
                .opacity(controller.uiEnabled ? 1 : 0)   // Unciv toggleUI: topBar and techPolicyAndDiplomacy
                .coversNotifications(in: Self.worldSpace)
                worldHUD
            }
            if let text = controller.banner {
                VStack { Spacer(); bannerView(text).padding(.bottom, 130) }
                    .transition(.opacity).allowsHitTesting(false)
            }
            // (Unciv WorldScreen.nextTurn puts nothing over the world while the turn runs on its clone: the NextTurnButton
            // says "Working..." with NextTurnProgress, and the map can be explored meanwhile - ours had a dark overlay here
            // that swallowed every touch until the turn was over)
            if let alert = controller.currentAlert, controller.state.outcome == nil { AlertPopupView(controller: controller, alert: alert).transition(.opacity) }
            else if let t = controller.tradeThanksFrom { TradeThanksView(controller: controller, civId: t).transition(.opacity) }
            if controller.state.outcome == nil { TutorialPopup(controller: controller) }   // opened before the alert popups, so it is on top (Unciv Popup stacking)
            if let outcome = controller.state.outcome { outcomeView(outcome) }
            if let next = controller.handoffTo {
                // Unciv PlayerReadyScreen: the whole screen is tinted with the civ's colour, "[civ] ready?" – tap anywhere to start.
                let nation = controller.state.rs.nations[next]
                let outer = nation?.outerColor ?? [30, 30, 30], inner = nation?.innerColor ?? [255, 255, 255]
                ZStack {
                    Color(red: Double(outer[0]) / 255, green: Double(outer[1]) / 255, blue: Double(outer[2]) / 255)
                    VStack(spacing: 16) {
                        Text(L("[\(next)] ready?")).font(Theme.title(30)).foregroundStyle(Color(red: Double(inner[0]) / 255, green: Double(inner[1]) / 255, blue: Double(inner[2]) / 255)).multilineTextAlignment(.center)
                    }
                }
                .ignoresSafeArea().bleedIntoCutout()
                .contentShape(Rectangle())
                .onTapGesture { controller.beginHandedOffTurn() }
                .overlay {
                    // Unciv PlayerReadyScreen: table.keyShortcuts.add(KeyboardBinding.NextTurnAlternate)
                    if let key = KeyBindings.spec("Next turn alternate").equivalent {
                        Button("") { controller.beginHandedOffTurn() }
                            .keyboardShortcut(key, modifiers: KeyBindings.spec("Next turn alternate").mods)
                            .frame(width: 0, height: 0).opacity(0)
                    }
                }
            }
        }
        .coordinateSpace(.named(Self.worldSpace))
        .onPreferenceChange(NotificationsCoverKey.self) { notificationsCovers = $0 }
        .onPreferenceChange(NotificationsBottomCoverKey.self) { notificationsBottomCovers = $0 }
        // Unciv's CityScreen is a full screen of its own; presenting it in place (not as a UIKit sheet) avoids the iOS 26 sheet
        // transition getting stuck on this large view.
        .overlay { if controller.showCity, let c = controller.selectedCity { CityScreen(controller: controller, cityId: c.id).overlay { TutorialPopup(controller: controller) }.transition(.move(edge: .bottom)).zIndex(10) } }
        .overlay { if controller.showUpgradeMenu, let u = controller.selectedUnit { UnitUpgradeMenuView(controller: controller, unit: u).zIndex(11) } }
        // Unciv CityPresenter: tapping the selected city's name on the world screen opens CityRenamePopup (the city screen has its own)
        .overlay { if controller.showRenameCity, !controller.showCity, let c = controller.selectedCity { RenamePopup(title: L("Please enter a new name for your city"), initial: c.name, onDone: { n in if let n { controller.renameCity(n) }; controller.showRenameCity = false }).zIndex(12) } }
        .overlay { if controller.showVotePicker { DiplomaticVotePickerView(controller: controller).zIndex(12) } }
        .overlay { if controller.showVoteResult { DiplomaticVoteResultView(controller: controller).zIndex(12) } else if controller.showCongress { VPCongressView(controller: controller).zIndex(12) } }   // VP: the Congress shares this overlay (one more modifier is too much for the type checker)
        .modifier(OnlineWorldPopups(controller: controller, onQuit: onQuit))
        .animation(.easeInOut(duration: 0.25), value: controller.showCity)
        .animation(UserSettings.animateUnitActionsMenu ? .easeOut(duration: 0.2) : nil, value: controller.selectedUnitId)
        // (Load game and New Game wait for the next turn as the menu's do: both go on to rebuild the shared ruleset the turn's
        // thread reads - Unciv's belongs to the game)
        .background(WorldKeyboardShortcuts(controller: controller, onOptions: { optionsWithDebug = false; showOptions = true }, onSave: { if !controller.state.settings.isOnline { showSave = true } }, onLoad: { if !controller.isProcessing { showLoad = true } },   // Unciv WorldScreen.openSaveGameScreen: `if (gameInfo.gameParameters.isOnlineMultiplayer) return`
                                           onNewGame: { if !controller.isProcessing { showNewGame = true } }, onQuickSave: { quicksave() }, onQuickLoad: { quickloadFromKey() }))
        .foregroundStyle(Theme.cream)
        .onChange(of: scenePhase) { phase in
            // Unciv UncivGame.pause: `autosaves.requestAutoSave(gameInfo)` - the game as the world screen shows it (while a
            // turn runs, the original the clone was taken from), written in the background; the app keeps the background
            // time it takes, or iOS may suspend it halfway through the write
            if phase == .background, controller.state.outcome == nil, controller.editorPaint == nil, let data = try? JSONEncoder().encode(controller.state) {
                let background = BackgroundTime("Autosave")
                SaveManager.requestAutoSave(data, civ: controller.state.player.nation, uncivTurns: controller.state.uncivTurns, nextTurn: false) { background.end() }
            }
        }
        // Unciv UncivGame.loadGame (the next turn's WorldScreen): the save, load, new-game and options screens opened over
        // the old one are gone with it
        .onChange(of: controller.worldScreenGeneration) { _, _ in showSave = false; showLoad = false; showNewGame = false; showOptions = false }
        .modifier(ReportsPushedScreens(controller: controller, save: showSave, load: showLoad, newGame: showNewGame, worldPushed: controller.screenPushedOverWorld))
        .fullScreenCover(isPresented: $controller.showTech, onDismiss: controller.flushPendingSheet) { VirtualCanvas { TechScreen(controller: controller) }.immersiveSystemUI() }   // on the stage, scaled with the screen as Unciv's TechPickerScreen
        .fullScreenCover(isPresented: $controller.showDiplomacy, onDismiss: controller.diplomacyDismissed) { VirtualCanvas { DiplomacyScreen(controller: controller) }.immersiveSystemUI() }   // Unciv's DiplomacyScreen is on the stage, scaled with the screen like the world screen
        // Unciv CityButton.foreignCityInfoPopup: what is known about a foreign city, and a way into diplomacy.
        .sheet(item: $controller.foreignCityInfo) { ForeignCityInfoView(controller: controller, cityId: $0.value).immersiveSystemUI() }
        .fullScreenCover(isPresented: $showSave, onDismiss: controller.flushPendingSheet) { SaveGameScreen(controller: controller, onClose: { showSave = false }).onStage().immersiveSystemUI() }
        .fullScreenCover(isPresented: $showLoad, onDismiss: controller.flushPendingSheet) { LoadGameScreen(onLoad: { s in showLoad = false; onStart(s) }, onClose: { showLoad = false }).onStage().immersiveSystemUI() }
        // Unciv WorldScreen.openNewGameScreen: GameSetupInfo(gameInfo) - the clone keeps the online flag; the game id is the game's
        .fullScreenCover(isPresented: $showNewGame, onDismiss: controller.flushPendingSheet) { NewGameScreen(initial: { var s = controller.state.settings; s.seed = 0; s.gameId = nil; return s }(), onStart: { s in showNewGame = false; onStart(s) }, onClose: { showNewGame = false }).onStage().immersiveSystemUI() }
        .stageSheet(isPresented: $showOptions, onDismiss: controller.flushPendingSheet) { OptionsView(controller: controller, withDebug: optionsWithDebug, onClose: { showOptions = false }).immersiveSystemUI() }
        .confirmationDialog(L("Are you sure you want to pillage this [\(controller.confirmPillage ?? "")]?"), isPresented: Binding(get: { controller.confirmPillage != nil }, set: { if !$0 { controller.confirmPillage = nil } }), titleVisibility: .visible) {
            Button(L("Pillage"), role: .destructive) { controller.confirmPillage = nil; controller.pillageSelected() }
            // Unciv ConfirmPopup's own "Cancel" button: without it SwiftUI adds the system's, which the app's English-only
            // bundle never shows in the game's language
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("Do you want to break your promise to [\(controller.confirmBreakPromise?.names ?? "")]?"), isPresented: Binding(get: { controller.confirmBreakPromise != nil }, set: { if !$0 { controller.confirmBreakPromise = nil } }), titleVisibility: .visible) {
            // Unciv ConfirmPopup(action = foundAction): the settler the popup was opened for founds the city
            Button(L("Break promise"), role: .destructive) { if let p = controller.confirmBreakPromise { controller.foundCity(unitId: p.unitId) } }
            Button(L("Cancel"), role: .cancel) {}   // Unciv ConfirmPopup's "Cancel" (the system's stays in English)
        }
        .confirmationDialog(controller.confirmDisband ?? "", isPresented: Binding(get: { controller.confirmDisband != nil }, set: { if !$0 { controller.confirmDisband = nil } }), titleVisibility: .visible) {
            Button(L("Disband unit"), role: .destructive) { controller.disbandUnit() }
            Button(L("Cancel"), role: .cancel) {}   // Unciv ConfirmPopup's "Cancel" (the system's stays in English)
        }
        .confirmationDialog(L("Confirm next turn"), isPresented: $controller.confirmNextTurn, titleVisibility: .visible) {
            Button(L("Next turn")) { controller.completeTask("turn"); controller.endTurn() }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("Next turn"), isPresented: $controller.showNextTurnMenu, titleVisibility: .visible) {
            Button(L("Next Turn")) { controller.completeTask("turn"); controller.endTurn() }   // NextTurnMenu: worldScreen.nextTurn(), no confirmation
            if controller.canMoveAutomatedUnits { Button(L("Move automated units")) { controller.moveAutomatedUnits() } }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("AutoPlay"), isPresented: $controller.showAutoPlayMenu, titleVisibility: .visible) {
            // Unciv AutoPlayMenu: isOnlineMultiplayer ise "Start AutoPlay" maddesi hic eklenmez
            if !controller.state.settings.isOnline { Button(L("Start AutoPlay")) { controller.startAutoPlay() } }
            Button(L("AutoPlay End Turn")) { controller.autoPlayEndTurn() }
            Button(L("AutoPlay Military Once")) { controller.autoPlayMilitaryOnce() }
            Button(L("AutoPlay Civilians Once")) { controller.autoPlayCiviliansOnce() }
            Button(L("AutoPlay Economy Once")) { controller.autoPlayEconomyOnce() }
            Button(L("Cancel"), role: .cancel) {}
        }
        .fullScreenCover(isPresented: $controller.showPolicies, onDismiss: controller.flushPendingSheet) { PolicyScreen(controller: controller).overlay { TutorialPopup(controller: controller) }.onAppear { controller.displayTutorial("CultureAndPolicies") }.onStage().immersiveSystemUI() }
        .fullScreenCover(isPresented: $controller.showPromotions, onDismiss: controller.promotionsDismissed) { PromotionSheet(controller: controller).overlay { TutorialPopup(controller: controller) }.onAppear { controller.displayTutorial("Experience") }.onStage().immersiveSystemUI() }
        // ("Start new game" of a game won in one-more-turn mode waits for the next turn, as the menu's does)
        .fullScreenCover(isPresented: $controller.showVictory, onDismiss: controller.flushPendingSheet) { VictoryScreen(controller: controller, onNewGame: { guard !controller.isProcessing else { return }; controller.showVictory = false; controller.afterSheetDismiss { showNewGame = true } }).onStage().immersiveSystemUI() }
        .fullScreenCover(isPresented: $controller.showCivilopedia, onDismiss: controller.civilopediaDismissed) { VirtualCanvas { CivilopediaScreen(controller: controller) }.immersiveSystemUI() }   // on the stage, scaled with the screen as Unciv's CivilopediaScreen
        .fullScreenCover(isPresented: $controller.showReligion, onDismiss: controller.flushPendingSheet) { ReligionScreen(controller: controller).onStage().immersiveSystemUI() }
        .fullScreenCover(isPresented: $controller.showEspionage, onDismiss: controller.flushPendingSheet) { EspionageScreen(controller: controller).onStage().immersiveSystemUI() }
        .fullScreenCover(isPresented: $controller.showOverview, onDismiss: controller.overviewDismissed) { OverviewScreen(controller: controller, initialTab: controller.overviewPage, initialSelect: controller.overviewSelect).onStage().immersiveSystemUI() }
        .sheet(isPresented: $controller.showChat, onDismiss: controller.flushPendingSheet) { ChatPopup(controller: controller, onClose: { controller.showChat = false }).immersiveSystemUI() }
        .sheet(isPresented: $controller.showMultiplayerStatus, onDismiss: controller.flushPendingSheet) { MultiplayerStatusPopup(controller: controller, onOpen: { s in onStart(s) }, onClose: { controller.showMultiplayerStatus = false }).immersiveSystemUI() }
        .overlay { if controller.showMusic { MusicPopup(onClose: { controller.showMusic = false }).zIndex(12) } }
        .sheet(isPresented: $controller.showDevConsole, onDismiss: controller.flushPendingSheet) { DevConsoleView(controller: controller, onClose: { controller.showDevConsole = false }).immersiveSystemUI() }
        .fullScreenCover(isPresented: $controller.showGreatPersonPicker, onDismiss: controller.flushPendingSheet) { GreatPersonPickerScreen(controller: controller).onStage().immersiveSystemUI() }
        .overlay { if controller.showMayaCalendar { MayaCalendarPopup(controller: controller).zIndex(12) } }
        .fullScreenCover(isPresented: $controller.showImprovementPicker, onDismiss: controller.flushPendingSheet) { ImprovementPickerSheet(controller: controller).onStage().immersiveSystemUI() }
        .overlay { if controller.showRenameUnit { RenamePopup(title: L("Choose name for [\(controller.selectedUnit?.name ?? "")]"), initial: controller.selectedUnit.map { $0.customName ?? L($0.name) } ?? "", validate: { $0 != controller.selectedUnit?.name }, onDone: { n in if let n { controller.renameUnit(n) }; controller.showRenameUnit = false }).zIndex(12) } }
        .fullScreenCover(isPresented: $controller.showFoundReligion, onDismiss: controller.flushPendingSheet) { FoundReligionSheet(controller: controller, enhance: false).onStage().immersiveSystemUI() }
        .fullScreenCover(isPresented: $controller.showEnhanceReligion, onDismiss: controller.flushPendingSheet) { FoundReligionSheet(controller: controller, enhance: true).onStage().immersiveSystemUI() }
        .fullScreenCover(isPresented: $controller.showFreeBeliefs, onDismiss: controller.flushPendingSheet) { FoundReligionSheet(controller: controller, enhance: false, freeBeliefs: true).onStage().immersiveSystemUI() }
    }

    /// Unciv QuickSave.save: `if (gameInfo.gameParameters.isOnlineMultiplayer) return` - "we don't support locally saving
    /// an online multiplayer game" (#10353): no file, no toast
    private func quicksave() {
        guard !controller.state.settings.isOnline else { return }
        do { try SaveManager.save(controller.state, name: "QuickSave"); controller.flash("Quicksave successful.") } catch { controller.flash("Could not save game!") }
    }
    /// Unciv QuickSave.load from the Quick Load binding: `screen.autoPlay.stopAutoPlay()`, then the QuickSave loaded
    /// (no menu to close first); no online guard, as QuickSave.load has none
    private func quickloadFromKey() {
        guard !controller.isProcessing else { return }   // the load would rebuild the ruleset the turn's thread is reading
        controller.stopAutoPlay()
        if let loaded = try? SaveManager.load(name: "QuickSave") { controller.flash("Quickload successful."); onStart(loaded) } else { controller.flash("Could not load game!") }
    }

    /// Unciv WorldScreen.displayTutorialTaskOnUpdate: the floating tutorial task. tutorialTaskTable is `pack()`ed around its
    /// RenderEvent, whose text wraps at half the stage width (RenderEvent: WrappableLabel(text, stageWidth * 0.5f)), and
    /// `centerX(stage)` just under the top bar; its onClick, on the table alone, collapses it to the HiddenTutorialTask icon
    /// and back. Stretched across the screen it had taken every tap on the map's top band.
    @ViewBuilder private var tutorialTaskView: some View {
        if let task = controller.currentTask {
            if controller.tutorialTaskCollapsed {
                Image(systemName: "checklist").foregroundStyle(Theme.gold).padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel.opacity(0.9)))
                    .onTapGesture { controller.tutorialTaskCollapsed = false }
                    .padding(.top, 6)
            } else if let choices = controller.tutorialTaskChoices(task) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checklist").foregroundStyle(Theme.gold)
                    WrapWidth(width: stageWidth * 0.5) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L(task.title)).font(Theme.caption).foregroundStyle(Theme.cream).fixedSize(horizontal: false, vertical: true)
                            Text(L(task.hint)).font(Theme.small).foregroundStyle(Theme.creamDim).fixedSize(horizontal: false, vertical: true)
                            // Unciv RenderEvent.addChoice: a button per matching choice ("Got it")
                            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                                Button(L(choice.text)) { controller.chooseTutorialTaskChoice(choice) }
                                    .buttonStyle(ThemedButtonStyle(filled: false, compact: true)).padding(.top, 4)
                            }
                        }
                    }
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel.opacity(0.9))).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.gold.opacity(0.6), lineWidth: 1))
                .contentShape(Rectangle()).onTapGesture { controller.tutorialTaskCollapsed = true }
                .padding(.top, 6)
            }
        }
    }

    private func bannerView(_ text: String) -> some View {
        Text(text).font(Theme.heading(14)).foregroundStyle(Theme.cream)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Theme.panelDark.opacity(0.92)))
            .overlay(Capsule().stroke(Theme.gold, lineWidth: 1))
    }

    /// What the notification pane and its RestoreButton are built from on this update
    private struct NotificationsModel {
        /// UserSettings.notificationScroll: Visible, Permanent, Hidden or Disabled
        let scrollSetting: String
        /// The player's notifications and the one-time notification the list does not hold (index -1)
        let all: [NotificationItem]
        /// `all` grouped by category in enum order
        let ordered: [NotificationItem]
        /// Unciv: Hidden is the pane scrolled out of sight to the right (it keeps its scrollY and comes back where it was) and
        /// Disabled leaves it `isVisible = false`; both show the RestoreButton instead
        let listShown: Bool
        /// The pane's left edge in worldSpace: it is as wide as its widest entry at the layer's right edge
        let paneMinX: CGFloat
        let coveredTop: CGFloat
        let coveredBottom: CGFloat
    }

    /// Unciv NotificationsScroll: every notification grouped by category in enum order (General without a header, the other headers
    /// collapse their group), scrollable. "Visible" can be hidden and a bell with the count brings it back, "Permanent" cannot be hidden,
    /// "Hidden" shows only the bell, "Disabled" shows a bell that opens the overview.
    ///
    /// The pane runs the screen's full height down its right edge, as Unciv's does (`height = worldScreen.stage.height *
    /// inverseScaleFactor`, `setPosition(stage.width - width * scaleFactor, 0f)`), under the status buttons, the tile info and
    /// the minimap. Its content opens with the room the status buttons cover (coveredNotificationsTop) and closes with the
    /// room the tile info and the minimap cover (coveredNotificationsBottom), both measured here on every layout as
    /// WorldScreen.update measures them on every update - so the band between them can show any entry, the last one included.
    private var notificationsModel: NotificationsModel {
        let scrollSetting = UserSettings.notificationScroll
        let current = controller.state.player.notificationItems
        // Unciv NotificationsScroll.updateContent: the one-time notification the list does not hold is added to the rows it
        // was last rebuilt with, tinted (its -1 row), until the next rebuild - ahead of them, `(additionalNotification +
        // notifications).groupBy { it.category }`, so first in its category
        let all = (controller.additionalNotification.map { [$0] } ?? []) + current
        let order = NotificationCategory.allCases
        let ordered = all.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: a.element.meta.category) ?? 0, ib = order.firstIndex(of: b.element.meta.category) ?? 0
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map { $0.element }
        // WorldScreen.update: `coveredNotificationsTop = stage.height - statusButtons.y` and `coveredNotificationsBottom =
        // bottomTileInfoTable.height + bottomTileInfoTable.y` - the TileInfoTable's top edge, which stands on the minimap
        // (`y = minimapWrapper.height + 5f` when it is shown) and is only its padding high with no tile selected. Ours are the
        // status buttons' bottom and the top of the highest view of the bottom right corner that runs across the pane - the
        // minimap and its buttons, and the tile info only where it reaches in over the entries, since it stands beside the
        // minimap (WorldHUDLayout) - from the pane's own ends; with none of them, the corner's padding (Unciv's empty
        // TileInfoTable, `pad(5f)`). The toggled-off UI keeps its room, as Unciv's hidden actors keep their size.
        let paneMinX = notificationsLayerFrame.maxX - notificationsSize.width
        let coveredTop = statusButtonsBottom.map { max(0, $0 - notificationsLayerFrame.minY) } ?? 0
        // (a view reaching less than half a point in over the entries' edge - the tile info beside a minimap as wide as the
        // pane, on the smallest canvases - does not run across it)
        let bottomCoversTop = notificationsBottomCovers
            .filter { $0.width >= 1 && $0.height >= 1 && $0.maxX > paneMinX + 0.5 && $0.minX < notificationsLayerFrame.maxX - 0.5 }
            .map(\.minY).min()
        let coveredBottom = bottomCoversTop.map { max(0, notificationsLayerFrame.maxY - $0) } ?? WorldHUDLayout.pad
        return NotificationsModel(scrollSetting: scrollSetting, all: all, ordered: ordered,
                                  listShown: scrollSetting != "Disabled" && scrollSetting != "Hidden",
                                  paneMinX: paneMinX, coveredTop: coveredTop, coveredBottom: coveredBottom)
    }

    /// The notification pane WorldMapView holds right above the map: Unciv NotificationsScroll `touchable =
    /// Touchable.childrenOnly` and updateLayout's `width = notificationsTable.packIfNeeded().width` - the pane is as wide as
    /// its widest entry and only the entries and category headers take a touch, the rest - the spacers above and below them
    /// included - reaching the map. They scroll in a NotificationsScrollPane framed to their width, whose hit test holds only
    /// the areas the entries and headers report (a SwiftUI ScrollView took every touch in its frame).
    private func notificationsPane(_ n: NotificationsModel) -> NotificationsScrollPane<some View> {
        // The entries wrap at NotificationsScroll.maxWidthOfStage = 0.333f: maxEntryWidth = stage.width * maxWidthOfStage *
        // inverseScaleFactor in a pane scaled by 0.5, a third of the stage on screen (stage.width / 2 is only the pane's first
        // width, WorldScreen.init) - the entry, that is, not the padding around it, which the offer adds back. WrapWidth
        // ignores what it is offered, and `fixedSize` measures the list at its own size whatever the host view holding it is.
        let list = VStack(alignment: .trailing, spacing: 3) {
            WrapWidth(width: stageWidth * 0.333 + Self.notificationsItemPad + Self.notificationsEdgePad) {
                VStack(alignment: .trailing, spacing: 0) { notificationRows(n.ordered) }
            }
            .animation(.easeInOut(duration: 0.18), value: n.ordered.count)
            if n.scrollSetting != "Permanent" && !n.all.isEmpty {
                // Unciv: the list scrolled away to the right - RestoreButton.show() → updateUserSetting(Hidden)
                Button { controller.setNotificationScrollFromList("Hidden") } label: {
                    Image(systemName: "chevron.up.circle").font(.system(size: 14)).foregroundStyle(Theme.creamDim).padding(.horizontal, 6)
                }.buttonStyle(.plain)
                .notificationTouchArea()
                .padding(.trailing, Self.notificationsEdgePad)
            }
        }
        // the first entry keeps the gap under the status buttons it always had
        .padding(.top, 6)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { notificationsSize = $0 }
        // Scene2D's z-order: the views over the pane keep their touches (coversNotifications), and a popup over the world
        // screen - Unciv's Popup covers the stage - leaves the pane none, as does the list hidden or toggled off
        let paneOrigin = CGPoint(x: n.paneMinX, y: notificationsLayerFrame.minY)
        let covers = notificationsCovers.map { $0.offsetBy(dx: -paneOrigin.x, dy: -paneOrigin.y) }
        let touchable = n.listShown && controller.uiEnabled && !controller.worldShortcutsVetoed && controller.handoffTo == nil
        // the pane at the layer's right edge, as high as the layer, in the coordinates of the map view that holds it
        let frame = CGRect(x: paneOrigin.x - mapFrame.minX, y: paneOrigin.y - mapFrame.minY, width: notificationsSize.width, height: notificationsLayerFrame.height)
        return NotificationsScrollPane(contentSize: notificationsSize, coveredTop: n.coveredTop, coveredBottom: n.coveredBottom, reveal: controller.notificationReveal,
                                       covers: covers, touchable: touchable, frame: frame,
                                       shown: n.listShown && controller.uiEnabled,   // Unciv toggleUI: notificationsScroll
                                       // Unciv startNewScreenJob: the next turn's WorldScreen has a NotificationsScroll of its own, at its top
                                       worldScreen: controller.worldScreenGeneration) { list }
    }

    /// The notification layer over the map: the frame the pane (WorldMapView's) is placed in and the RestoreButton
    @ViewBuilder private func notificationsLayer(_ n: NotificationsModel) -> some View {
        ZStack(alignment: .topTrailing) {
            // the room the layer spans; the pane itself lies under it, in WorldMapView
            Color.clear.allowsHitTesting(false)
            if !n.listShown && !n.all.isEmpty {
                Button {
                    // Unciv RestoreButton.clicked: Disabled → worldScreen.openEmpireOverview(EmpireOverviewCategories.Notifications)
                    // (selection defaults to ""), otherwise `scrollX = maxX; hide()`
                    if n.scrollSetting == "Disabled" { controller.overviewPage = "Notifications"; controller.overviewSelect = ""; controller.showOverview = true } else { controller.setNotificationScrollFromList("Visible") }
                } label: {
                    // Unciv RestoreButton.updateCount: "+" from 100, else count.tr() (toMayaNumerals for a Long Count civ is not drawn -
                    // this port writes the Long Count date in plain digits as well)
                    HStack(spacing: 3) { BellIcon(count: n.all.count, flashOnAppear: n.scrollSetting == "Disabled"); Text(n.all.count >= 100 ? "+" : Translations.shared.numberTr(n.all.count)).font(Theme.small.bold()).foregroundStyle(Theme.gold) }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.panelDark.opacity(0.9)))
                }.buttonStyle(.plain)
                // Unciv RestoreButton.setPosition(coveredNotificationsBottom): `setPosition(stage.width - restoreButtonPad,
                // coveredNotificationsBottom + restoreButtonPad, Align.bottomRight)` - its bottom right corner just above the
                // minimap (or the tile info, where that reaches in over the entries), at the screen's edge (restoreButtonPad:
                // ours the entries' 10-point edge gap). The button is an actor of the stage's root
                // (`addActorAfter(this@NotificationsScroll, this)`), not of the pane, so toggleUI leaves it shown.
                .padding(.trailing, Self.notificationsEdgePad).padding(.bottom, n.coveredBottom + Self.notificationsEdgePad)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.worldSpace)) } action: { notificationsLayerFrame = $0 }
    }

    /// Unciv's NotificationsScroll fades its entries in and out rather than having them appear and vanish; the
    /// animation is ours but the fact of one is theirs - a line that arrives without warning is easy to miss.
    @ViewBuilder private func notificationRows(_ ordered: [NotificationItem]) -> some View {
        ForEach(Array(ordered.enumerated()), id: \.element.id) { i, n in
            let cat = n.meta.category
            if cat != .General, i == 0 || ordered[i - 1].meta.category != cat {
                Button {
                    if controller.collapsedNotificationCategories.contains(cat.rawValue) { controller.collapsedNotificationCategories.remove(cat.rawValue) } else { controller.collapsedNotificationCategories.insert(cat.rawValue) }
                } label: {
                    // Unciv CategoryHeader: `touchable = Touchable.enabled // stop clicks going through to map`, the caption
                    // padded by listItemPad and the right line by `categoryHorizontalPad + rightPadToScreenEdge`, all inside it
                    Text(L(cat.rawValue)).font(Theme.small.bold()).foregroundStyle(categoryColor(cat)).padding(.trailing, 6)
                        .padding(.vertical, Self.notificationsItemPad).padding(.trailing, Self.notificationsEdgePad)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .notificationTouchArea()
            }
            if cat == .General || !controller.collapsedNotificationCategories.contains(cat.rawValue) {
                let enlarged = UserSettings.enlargeSelectedNotifications && controller.enlargedNotification == n.id   // Unciv "Enlarge selected notifications"
                HStack(spacing: 6) {
                    Rectangle().fill(categoryColor(cat)).frame(width: 2, height: enlarged ? 20 : 14)
                    Text(L(n.text)).font(enlarged ? Theme.body : Theme.caption).foregroundStyle(n.index == -1 ? Color(white: 0x11 / 255) : Theme.cream).fixedSize(horizontal: false, vertical: true)   // Unciv stores notifications in English and translates on display
                    ForEach(Array(n.meta.icons.reversed().enumerated()), id: \.offset) { _, icon in
                        let parts = notificationIconPath(icon, controller.state.rs).split(separator: "/", maxSplits: 1).map(String.init)
                        ArtIcon(name: parts.count == 2 ? parts[1] : icon, folder: parts.count == 2 ? parts[0] : "OtherIcons", fallback: "circle", size: enlarged ? 20 : 14)
                    }   // Unciv: icons to the right of the text
                }
                .padding(.horizontal, enlarged ? 12 : 8).padding(.vertical, enlarged ? 7 : 4)
                // Unciv ListItem: the one-time notification on OneTimeNotificationColor (#fceea8), its label ImageGetter.CHARCOAL
                .background(RoundedRectangle(cornerRadius: 5).fill(n.index == -1 ? Color(red: 0xfc / 255, green: 0xee / 255, blue: 0xa8 / 255) : Theme.panelDark.opacity(enlarged ? 0.97 : 0.85)))
                // Unciv ListItem: "using a large click area with no gap in between each message item. this avoids accidentally
                // clicking in between the messages, resulting in a map click" - the padding around the entry is its own:
                // `add(listItem).pad(topBottomPad, listItemPad, topBottomPad, rightPadToScreenEdge)` in a Touchable.enabled
                // ListItem, so from a hair left of the entry to the screen's edge
                .padding(.vertical, Self.notificationsItemPad).padding(.leading, Self.notificationsItemPad)
                .padding(.trailing, Self.notificationsEdgePad).contentShape(Rectangle())
                .notificationTouchArea(entry: n.id)
                .onTapGesture { controller.clickNotification(n) }   // Unciv ListItem.onClick
            }
        }
    }

    private func categoryColor(_ c: NotificationCategory) -> Color {
        switch c {
        case .General: return Theme.gold
        case .Trade: return Color(red: 0.9, green: 0.75, blue: 0.3)
        case .Diplomacy: return Theme.accent
        case .Production: return Color(red: 0.8, green: 0.5, blue: 0.3)
        case .Units: return Theme.cream
        case .War: return Theme.danger
        case .Religion: return Color(red: 0.8, green: 0.8, blue: 1)
        case .Espionage: return Color(red: 0.6, green: 0.4, blue: 0.8)
        case .Cities: return Theme.good
        }
    }

    /// Unciv WorldScreenTopBarStats.rateLabel: a rounded, signed rate, with zero written as a plus-minus.
    static func rateLabel(_ v: Double) -> String {
        let n = Stats.roundToInt(v)   // Kotlin Float.roundToInt: -2.5 reads -2, not -3
        return n == 0 ? "±0" : (n > 0 ? "+\(n)" : "\(n)")
    }

    /// Unciv MinimapHolder.getToggleIcons: movements, yields, worked tiles, resources, improvements -
    /// `toggleIconTable.add(button).row()`, i.e. a vertical column to the left of the minimap.
    private var overlayToggles: some View {
        VStack(spacing: 4) {
            overlayToggle("arrow.triangle.turn.up.right.diamond", { UserSettings.showUnitMovements }, { UserSettings.showUnitMovements = $0 })
            overlayToggle("leaf", { UserSettings.showTileYields }, { UserSettings.showTileYields = $0 })
            overlayToggle("person.fill", { UserSettings.showWorkedTiles }, { UserSettings.showWorkedTiles = $0 })
            overlayToggle("cube", { UserSettings.showResourcesAndImprovements }, { UserSettings.showResourcesAndImprovements = $0 })   // resourceImageButton
            overlayToggle("hammer", { UserSettings.showPixelImprovements }, { UserSettings.showPixelImprovements = $0 })                 // improvementsImageButton
        }
    }
    private func overlayToggle(_ icon: String, _ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> some View {
        let on = get()
        return Button { set(!on); controller.overlaysChanged() } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(on ? Theme.panelDark : Theme.gold)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? AnyShapeStyle(Theme.gold) : AnyShapeStyle(Theme.panelDark.opacity(0.9))))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline, lineWidth: 1))
        }
    }
    /// Unciv ZoomButtonPair.
    private var zoomButtons: some View {
        VStack(spacing: 4) {
            Button { controller.zoomIn() } label: { Text("+").font(.system(size: 16, weight: .bold)).frame(width: 30, height: 28) }.buttonStyle(ThemedButtonStyle(compact: true))
            Button { controller.zoomOut() } label: { Text("–").font(.system(size: 16, weight: .bold)).frame(width: 30, height: 28) }.buttonStyle(ThemedButtonStyle(compact: true))
        }
    }

    /// Unciv StatusButtons, positioned by WorldScreen.updateGameplayButtons at the top right of the stage.
    /// Unciv falls back to `update(verticalWrap = true)` as soon as the row would be wider than the stage;
    /// an iPhone never has the width for the row, so we always use the wrapped form - and Unciv's wrapped
    /// order puts the next-turn button first, the small unit button, AutoPlay and multiplayer under it.
    private var statusButtons: some View {
        VStack(alignment: .trailing, spacing: 6) {
            NextTurnButton(controller: controller)
            // Unciv NextTurnAction.Waiting: another player's turn is only the next-turn button's "Waiting for [civ]...", no
            // panel over the map; the manual refresh (Unciv only polls) and the last refresh error hang under the button
            if controller.waitingFor != nil, let gameId = controller.state.settings.gameId {
                Button { Task { await controller.syncFromServer(gameId: gameId) } } label: {
                    Label(L("Refresh now"), systemImage: "arrow.clockwise")
                }.buttonStyle(ThemedButtonStyle(compact: true))
                if let m = controller.syncMessage {
                    Text(m).font(Theme.small).foregroundStyle(Theme.danger).multilineTextAlignment(.trailing)
                        .frame(maxWidth: 160, alignment: .trailing).fixedSize(horizontal: false, vertical: true).allowsHitTesting(false)
                }
            }
            // Unciv SmallUnitButton: a compact Skip / Next-unit button beside the next-turn button.
            if UserSettings.showSmallUnitButton, controller.isMyTurn, controller.nextTurnAction == .nextUnit,
               let sel = controller.selectedUnit {
                let due = controller.idleUnits.contains { $0.id == sel.id }
                Button { controller.switchToNextUnit(resetDue: UserSettings.checkForDueUnitsCycles) } label: {   // SmallUnitButton.onActivation
                    HStack(spacing: 4) { Image(systemName: UserSettings.checkForDueUnitsCycles ? "forward.end.fill" : "arrow.triangle.2.circlepath"); Text(L(UserSettings.checkForDueUnitsCycles ? "Skip" : "Cycle")).font(.system(size: 10, weight: .bold)) }
                }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(!due)
                // SmallUnitButton.update: `keyShortcuts.add(KeyboardBinding.Cycle)` in its "Next" form only (the Skip form
                // leaves the key to the unit action); a disabled button does not answer
                .modifier(BindingShortcut(name: UserSettings.checkForDueUnitsCycles || controller.worldShortcutsVetoed ? nil : "Cycle"))
            }
            if UserSettings.showAutoPlayButton || controller.isAutoPlaying {
                // Unciv AutoPlayStatusButton: onActivation -> calisiyorsa durdur, degilse menu; onRightClick -> dogrudan AutoPlay
                Button {
                    if autoPlayLongPressFired { autoPlayLongPressFired = false; return }   // the lift after a long press is no tap
                    if controller.isAutoPlaying { controller.stopAutoPlay() } else if controller.isMyTurn { controller.showAutoPlayMenu = true }
                } label: {
                    // Unciv AutoPlayStatusButton is an image alone (OtherIcons/NationSwap) - no "AutoPlay" / "Stop AutoPlay" text
                    Image(systemName: controller.isAutoPlaying ? "stop.fill" : "forward.end.fill").accessibilityLabel(L("AutoPlay"))
                }
                .buttonStyle(ThemedButtonStyle(filled: controller.isAutoPlaying, compact: true))
                .uncivLongPress(fired: $autoPlayLongPressFired) { if !controller.isAutoPlaying && !controller.state.settings.isOnline && controller.isMyTurn { controller.startAutoPlay() } }
            }
        }
    }

    /// Unciv BattleTable: its own actor, `setPosition(stage.width / 2 - width / 2, 5f)` - horizontally centred at the bottom.
    @ViewBuilder private var battleArea: some View {
        if let u = controller.selectedUnit, let t = controller.battleTarget, controller.unitBattleTableShown(u, t) {
            BattleTableView(controller: controller, attacker: u, target: t)
        } else if let c = controller.selectedCity, controller.selectedUnit == nil, !controller.showCity, c.civId == controller.state.playerId, let t = controller.battleTarget, controller.cityBattleTableShown(t) {
            CityBattleTableView(controller: controller, city: c, target: t)
        }
    }

    /// Unciv bottomUnitTable: the bottom left corner (x = 0, y = 0), with unitActionsTable stacked on top of it (WorldHUDLayout).
    @ViewBuilder private var unitTableArea: some View {
        if let spy = controller.selectedSpy { SpyPanel(controller: controller, spy: spy) }
        else if let u = controller.selectedUnit { UnitPanel(controller: controller, unit: u).id(u.id).transition(UserSettings.animateUnitActionsMenu ? .move(edge: .leading).combined(with: .opacity) : .identity) }   // Unciv "Animate Unit actions menu"
        // Unciv CityPresenter: our city, or anyone's for a spectator (UnitTable.tileSelected: isOwnerOf || isSpectator)
        else if let c = controller.selectedCity, !controller.showCity, c.civId == controller.state.playerId || controller.state.player.isSpectator { CityPanel(controller: controller, city: c) }
        // Unciv UnitTable.update: the summary is hidden only when the civ has no units
        else if !controller.state.units(of: controller.state.playerId).isEmpty { SummaryPanel(controller: controller) }
    }

    /// Unciv's bottom right corner: `minimapWrapper.x = stage.width - width` with y = 0 and the ZoomButtonPair to the left
    /// of the whole minimap wrapper (`stage.width - minimapWrapper.width - 10, 10, Align.bottomRight`) - which, since the
    /// wrapper's width includes the overlay toggles, puts the zoom buttons left of the toggle column. The tile info stands
    /// beside them (WorldHUDLayout).
    private var minimapCluster: some View {
        HStack(alignment: .bottom, spacing: 5) {
            if UserSettings.showZoomButtons { zoomButtons.coversNotificationsBottom(in: Self.worldSpace) }   // Unciv toggleUI leaves the zoomController alone
            if controller.showMinimap {
                Group {
                    overlayToggles.coversNotificationsBottom(in: Self.worldSpace)
                    MinimapView(controller: controller).coversNotificationsBottom(in: Self.worldSpace)
                }.opacity(controller.uiEnabled ? 1 : 0)   // toggleUI: minimapWrapper
            }
        }
    }

    /// Unciv bottomTileInfoTable: the selected tile - only one its civView (getGameViewConsideringForOfWar's) has explored
    /// (TileInfoTable.updateTileTable), none under the city screen
    @ViewBuilder private var tileInfoArea: some View {
        if let t = controller.infoTile, (controller.state.civ(controller.viewCivId) ?? controller.player).explored.contains(t), !controller.showCity {
            // a new table for each tile, as Unciv's updateTileTable fills its table anew (`clearChildren()`): a scrolled capital's lines do not
            // leave the next tile's scrolled, nor an open breakdown popup the next tile's open
            TileInfoTableView(controller: controller, coord: t).id(t)
                .opacity(controller.uiEnabled ? 1 : 0)   // toggleUI: bottomTileInfoTable
                .coversNotificationsBottom(in: Self.worldSpace)
        }
    }

    /// Everything under the top bar, each on its own as Scene2D places Unciv's actors (WorldHUDLayout): the tutorial task
    /// (behind the others, as it is behind the top bar), the status buttons, the unit table, the minimap with its buttons,
    /// the tile info beside them and the battle table on top
    private var worldHUD: some View {
        WorldHUDLayout(stageHeight: notificationsLayerFrame.height) {
            tutorialTaskView
                .opacity(controller.uiEnabled ? 1 : 0)   // Unciv toggleUI: tutorialTaskTable
                .coversNotifications(in: Self.worldSpace)
                .layoutValue(key: WorldHUDLayout.SlotKey.self, value: .tutorialTask)
            // Unciv WorldScreen.updateGameplayButtons: statusButtons.setPosition(stage.width - width - 10, topBar.y - height -
            // 10) - the next-turn button and its companions hang from the top right just under the top bar
            statusButtons
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.worldSpace)).maxY } action: { statusButtonsBottom = $0 }
                .coversNotifications(in: Self.worldSpace)
                .opacity(controller.uiEnabled ? 1 : 0)   // Unciv toggleUI: statusButtons
                .layoutValue(key: WorldHUDLayout.SlotKey.self, value: .statusButtons)
            unitTableArea.opacity(controller.uiEnabled ? 1 : 0)   // toggleUI: bottomUnitTable and unitActionsTable (their keys still answer)
                .coversNotifications(in: Self.worldSpace)
                .layoutValue(key: WorldHUDLayout.SlotKey.self, value: .unitTable)
            minimapCluster
                .layoutValue(key: WorldHUDLayout.SlotKey.self, value: .cluster)
            tileInfoArea
                .layoutValue(key: WorldHUDLayout.SlotKey.self, value: .tileInfo)
            // Unciv BattleTable: its own actor at the bottom centre (y = 5), apart from the unit table and the minimap, so a
            // tall table never pushes them
            battleArea.coversNotifications(in: Self.worldSpace)
                .opacity(controller.uiEnabled ? 1 : 0)   // Unciv toggleUI: `battleTable.isVisible = false`
                .layoutValue(key: WorldHUDLayout.SlotKey.self, value: .battle)
        }
        // Unciv ConsoleCivCommands `civ remove`: ConfirmPopup(msg, "Yes", action = ::annihilate) on the world screen
        // (hung here, off the body's long modifier chain)
        .confirmationDialog(controller.confirmAnnihilation?.message ?? "", isPresented: Binding(get: { controller.confirmAnnihilation != nil }, set: { if !$0 { controller.confirmAnnihilation = nil } }), titleVisibility: .visible) {
            Button(L("Yes"), role: .destructive) { if let a = controller.confirmAnnihilation, !controller.isProcessing { controller.state.annihilateCiv(a.civId); controller.refresh() }; controller.confirmAnnihilation = nil }
            Button(L("Cancel"), role: .cancel) {}   // Unciv ConfirmPopup's "Cancel" (the system's stays in English)
        }
    }

    /// Unciv VictoryScreen opened at the end of the game, with its "One more turn...!" and "Start new game"
    private func outcomeView(_ outcome: GameOutcome) -> some View {
        VictoryScreen(controller: controller, onNewGame: { showNewGame = true })
            .onAppear { GameEvents.post(.gameEnded(controller.state)) }
    }
}

/// Unciv WorldScreenMenuPopup: Main menu, Civilopedia, Save game, Load game, Start new game, Victory status, Options.
/// Unciv WorldScreenMenuPopup: the game menu is a short list of actions, so it opens over the button that raised
/// it rather than taking the whole screen. The long items behind it (Civilopedia, Options, Victory) are still
/// their own screens - only the menu that leads to them stopped being one.
struct GameMenu: View {
    @ObservedObject var controller: GameController
    let onQuit: () -> Void
    let onSave: () -> Void
    let onLoad: () -> Void
    let onNewGame: () -> Void
    let onOptions: () -> Void
    /// Unciv WorldScreenMenuPopup: a long press on Options opens it with the Debug tab
    var onOptionsDebug: () -> Void = {}
    var onQuicksave: () -> Void = {}
    var onQuickload: () -> Void = {}
    /// The long press on Options opened it with the Debug tab; its lift is no tap (uncivLongPress)
    @State private var optionsLongPressFired = false
    private func close() { controller.showMenu = false }
    var body: some View {
        let s = controller.state
        // (Unciv's menu has no header line - the nation and turn are the top bar's)
        // Unciv WorldScreenMenuPopup order: Main menu, Civilopedia, Save game, Load game, Start new game, Victory status,
        // Options, Music, Developer Console; the quick save/load (Unciv's keyboard bindings) and sharing follow
        // (While the next turn runs on its clone, Main menu, Load game, Start new game and Quickload wait for it: each goes
        // on to rebuild the shared ruleset and map globals the turn's thread reads - Unciv's belong to the game itself.)
        MenuRow(title: L("Main menu"), systemImage: "house.fill") { SaveManager.autosave(s, nextTurn: false); close(); onQuit() }
            .disabled(controller.isProcessing)
        MenuRow(title: L("Civilopedia"), systemImage: "books.vertical.fill") { close(); controller.showCivilopedia = true }
        if !s.settings.isOnline { MenuRow(title: L("Save game"), systemImage: "scroll.fill", action: onSave) }
        MenuRow(title: L("Load game"), systemImage: "tray.and.arrow.down.fill", action: onLoad).disabled(controller.isProcessing)
        MenuRow(title: L("Start new game"), systemImage: "globe.europe.africa.fill", action: onNewGame).disabled(controller.isProcessing)
        MenuRow(title: L("Victory status"), systemImage: "trophy.fill") { close(); controller.showVictory = true }
        MenuRow(title: L("Options"), systemImage: "gearshape.fill") { if optionsLongPressFired { optionsLongPressFired = false } else { onOptions() } }
            .uncivLongPress(fired: $optionsLongPressFired) { onOptionsDebug() }
        MenuRow(title: L("Music"), systemImage: "music.note") { close(); controller.showMusic = true }
        // Unciv WorldScreenMenuPopup: showConsole = showSave && expertMode; openDeveloperConsole refuses a game with several humans
        if !s.settings.isOnline && controller.menuExpertMode { MenuRow(title: L("Developer Console"), systemImage: "terminal") { close(); controller.openDeveloperConsole() }.disabled(controller.isProcessing) }
        MenuDivider()
        // Unciv QuickSave.save does nothing for an online game (showSave = !isOnlineMultiplayer hides Save game the same way);
        // QuickSave.load has no such guard
        if !s.settings.isOnline { MenuRow(title: L("Quicksave"), systemImage: "bolt.fill", action: onQuicksave) }
        MenuRow(title: L("Quickload"), systemImage: "bolt.horizontal.fill", action: onQuickload).disabled(controller.isProcessing)
        MenuRow(title: L("Share save file"), systemImage: "square.and.arrow.up") { close(); controller.exportSave() }
        if s.settings.isOnline {
            MenuRow(title: L("Sync online game"), systemImage: "arrow.triangle.2.circlepath", note: s.settings.gameId) {
                if let g = s.settings.gameId { Task { await controller.syncFromServer(gameId: g) } }; close()
            }
        }
    }
}

/// Unciv WorldScreenTopBar: stats row (gold, science, happiness, culture, faith), strategic resources, turn/year, Overview; then the tech/policy/diplomacy/espionage/undo row.
struct TopBar<Menu: View>: View {
    @ObservedObject var controller: GameController
    /// The game menu opens over the button that raises it (Unciv WorldScreenMenuPopup), so its content is handed
    /// in from the screen that owns the save/load/options state rather than presented as a sheet from there.
    @ViewBuilder var menu: () -> Menu
    @State private var overviewTab: String? = nil
    /// The long press on the menu button opened the menu in expert mode; its lift is no tap (uncivLongPress)
    @State private var menuLongPressFired = false
    var body: some View {
        let s = controller.state
        // Unciv WorldScreenTopBar.update(selectedCiv): the stats, resources, year, supply and nation shown are the selected
        // civ's (a spectator's pick); TechPolicyDiplomacyButtons keeps the viewing civ's own for its tech, policy and
        // diplomacy buttons (`viewingCiv = worldScreen.selectedGameView.civView` when it was built)
        let viewing = s.player
        let civ = controller.selectedCiv
        let gold = s.netGoldPerTurn(civ.id)
        let science = s.scienceForNextTurn(civ.id)   // Unciv WorldScreenTopBarStats / turnsToTech: statsForNextTurn.science
        let happy = s.happiness(of: civ.id)
        let culture = s.cultureForNextTurn(civ.id)   // Unciv WorldScreenTopBarStats: statsForNextTurn.culture
        // Unciv getCultureText: enough banked already reads (!), no culture at all reads (infinity).
        let policyTurns: String = {
            // Unciv: (Int - Int) / Float statsForNextTurn.culture, a Float division
            let turns = Double(Float(s.policyCost(civ) - civ.cultureStored) / Float(culture))
            if turns <= 0 { return "!" }
            if culture <= 0 { return "∞" }
            return "⏳\u{2009}\(Int(turns.rounded(.up)))"   // Unciv: "(" + Fonts.turn + thin space + turns + ")"
        }()
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                // Unciv WorldScreenMenuPopup init opens with `worldScreen.autoPlay.stopAutoPlay()` - tap and long press alike
                Button {
                    if menuLongPressFired { menuLongPressFired = false; return }   // the lift after a long press is no tap
                    controller.stopAutoPlay(); controller.menuExpertMode = false; controller.showMenu = true
                } label: {
                    HStack(spacing: 4) { Image(systemName: "line.3.horizontal").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.gold); NationBadge(nation: civ.nationDef, size: 26) }
                }
                // Unciv WorldScreenTopBar: menuButton.onRightClick (a long press) opens the menu in expert mode
                .uncivLongPress(fired: $menuLongPressFired) { controller.stopAutoPlay(); controller.menuExpertMode = true; controller.showMenu = true }
                .themedMenu(isPresented: $controller.showMenu) { menu() }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button { overviewTab = "Stats" } label: { stat("💰", "\(Int(civ.gold)) (\(GameView.rateLabel(gold)))", color: civ.gold < 0 ? Theme.danger : Theme.cream) }
                        Button { controller.showTech = true } label: { stat("🔬", GameView.rateLabel(science), color: Theme.cream) }
                        Button { overviewTab = "Resources" } label: { stat(happy >= 0 ? "😊" : "😠", (s.vpCachedApproval(civ.id).map { "\($0)%" } ?? "\(happy)") + (civ.isInGoldenAge ? "    " + L("GOLDEN AGE") + "(\(civ.goldenAgeTurns))" : " (\(Int(civ.goldenAgePoints))/\(Int(s.goldenAgeThreshold(civ))))"), color: happy < 0 ? Theme.danger : Theme.cream) }
                        Button { controller.showPolicies = true } label: { stat("🎵", "\(GameView.rateLabel(culture)) (\(policyTurns))", color: Theme.cream) }
                        if s.vpLeague.founded { Button { controller.showCongress = true } label: { stat("🏛", "\(s.vpLeagueTurnsToSession())" + (s.vpLeague.pendingProposers.contains(civ.id) ? " ✎" : ""), color: Theme.cream) } }   // VP: World Congress
                        if s.religionEnabled { Button { overviewTab = "Religion" } label: { stat("🕊", "\(Int(civ.faithStored)) (\(GameView.rateLabel(s.faithForNextTurn(civ.id))))", color: Theme.cream) } }   // Unciv: statsForNextTurn.faith
                        else { Text(L("Religion: Off")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.creamDim) }   // Unciv WorldScreenTopBarStats
                    }
                }
                Button { if s.isLongCountDisplay(civ.id) { controller.showMayaCalendar = true } else { controller.showVictory = true } } label: {   // Unciv WorldScreenTopBarResources: the Maya year opens the Long Count popup
                    VStack(spacing: 0) {
                        Text("⏳ " + Translations.shared.numberTr(s.uncivTurns)).font(.system(size: 12, weight: .bold, design: .serif)).foregroundStyle(Theme.gold)   // Unciv WorldScreenTopBarResources: Fonts.turn + gameInfo.turns, zero-based
                        Text(s.yearString(for: civ.id)).font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.creamDim)
                    }
                }
                // Unciv WorldScreenTopBar.OverviewAndSupplyTable: arz unlemi kendi dugmesidir ve Units sayfasini acar
                HStack(spacing: 3) {
                    if s.unitSupplyDeficit(civ.id) > 0 {
                        Button { overviewTab = "Units" } label: { Text("!").font(.system(size: 13, weight: .black)).foregroundStyle(Theme.danger) }.buttonStyle(.plain)
                    }
                    // Unciv WorldScreenTopBar overviewButton: openEmpireOverview() with no category - the last page viewed
                    Button { overviewTab = UserSettings.overviewLastPage } label: {
                        Text(L("Overview")).font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 7).padding(.vertical, 5).background(RoundedRectangle(cornerRadius: 7).fill(Theme.panelDark)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1))
                    }
                }
            }
            let counts = s.resourceCounts(civ.id)
            // Unciv WorldScreenTopBarResources: strategicResources = Strategic && !isCityWide
            let strategic: [(key: String, value: Int)] = s.rs.resourceOrder.compactMap { name in
                guard let def = s.rs.resources[name], def.resourceType == "Strategic", !def.isCityWide,
                      !def.uniques.contains("Not shown on world screen") else { return nil }
                let amount = counts[name] ?? 0
                let canSee = def.revealedBy == nil || civ.techs.contains(def.revealedBy!)
                guard canSee || amount != 0 else { return nil }
                return (name, amount)
            }
            // Unciv WorldScreenTopBarResources: stoklanan kaynagin etiketi "12 (+3)" olur (tur basi 0 ise yalniz miktar)
            let stockpileSupply: [String: Int] = strategic.contains { s.rs.resources[$0.key]?.isStockpiled == true } ? s.civResourceSupply(civ.id) : [:]
            if !strategic.isEmpty {
                Button { overviewTab = "Resources" } label: {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(strategic, id: \.key) { r in
                                let perTurn = s.rs.resources[r.key]?.isStockpiled == true ? (stockpileSupply[r.key] ?? 0) : 0
                                HStack(spacing: 2) { ArtIcon(name: r.key, folder: "ResourceIcons", fallback: "cube", size: 13); Text(perTurn == 0 ? "\(r.value)" : "\(r.value) (\(GameView.rateLabel(Double(perTurn))))").font(.system(size: 10, weight: .bold)).foregroundStyle(r.value < 0 ? Theme.danger : Theme.cream) }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                // Unciv TechPolicyDiplomacyButtons.updateFogOfWarButton: "Fog of War" above the tech button, a spectator's only
                // (UncivSound.Paper, KeyboardBinding.TechnologyTree)
                if viewing.isSpectator {
                    Button { controller.toggleFogOfWar() } label: {
                        Text(L("Fog of War")).font(.system(size: 11, weight: .bold)).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(controller.fogOfWar ? Theme.accent.opacity(0.35) : Theme.panelDark))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.accent, lineWidth: 1))
                    }
                }
                if !s.rs.techs.isEmpty && !s.cities(of: viewing.id).isEmpty && (viewing.currentTech != nil || !s.researchableTechs(for: viewing).isEmpty || !viewing.techs.isEmpty) {
                Button { controller.showTech = true } label: {
                    HStack(spacing: 5) {
                        if let t = viewing.currentTech { ArtIcon(name: t, folder: "TechIcons", fallback: "book", size: 18) } else { Image(systemName: "book").font(.system(size: 13)) }
                        Text(viewing.currentTech.map { "\(L($0))\(techTurns(s, viewing, s.scienceForNextTurn(viewing.id)))" } ?? (s.researchableTechs(for: viewing).isEmpty ? L("Technologies") : L("{Pick a tech}!"))).font(.system(size: 11, weight: .bold)).lineLimit(1)   // Unciv updateTechButton: "{Pick a tech}!".tr()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.accent, lineWidth: 1))
                }
                }
                // Unciv updatePolicyButton: only once the viewing civ has adopted policies or can adopt one; it opens
                // PolicyPickerScreen(worldScreen.selectedCiv, canChangeState)
                if !viewing.policies.isEmpty || (s.canAffordPolicy(viewing) && (s.rs.policyBranches.contains(where: { s.canOpenBranch(viewing, $0) }) || s.rs.policies.values.contains(where: { s.canAdopt(viewing, policy: $0) }))) {
                    Button { controller.showPolicies = true } label: { iconButton("scroll", highlighted: s.canAffordPolicy(viewing)) }
                }
                // Unciv updateDiplomacyButton: hidden when defeated, a spectator or `!hasMetAnyMajorCiv()` - which is
                // `getKnownCivs().any { it != civ && !it.isBarbarian }`: any known civ alive and no spectator, city-states too
                if viewing.isAlive && !viewing.isSpectator && s.civs.contains(where: { $0.id != viewing.id && !$0.isBarbarian && $0.isAlive && !$0.isSpectator && viewing.metCivs.contains($0.id) }) {
                    Button { controller.showDiplomacy = true } label: { iconButton("person.2.fill", highlighted: !s.pendingOffers.filter { $0.to == viewing.id }.isEmpty || !s.pendingDemands.filter { $0.to == viewing.id }.isEmpty) }
                }
                // Unciv updateEspionageButton: the selected civ's spies, and EspionageOverviewScreen(worldScreen.selectedCiv)
                if s.espionageEnabled && civ.spies.contains(where: { $0.alive }) { Button { controller.selectedSpyId = nil; controller.showEspionage = true } label: { iconButton("eye.fill", highlighted: civ.spies.contains { $0.alive && $0.cityId == nil }) } }
                if controller.canUndo { Button { controller.undo() } label: { iconButton("arrow.uturn.backward", highlighted: false) } }
                if s.settings.isOnline { ChatButton(controller: controller); MultiplayerStatusButton(controller: controller) }
                else if UserSettings.multiplayerStatusInSingleplayer { MultiplayerStatusButton(controller: controller) }   // Unciv "Enable multiplayer status button in singleplayer games"
                Spacer()
            }
        }
        .foregroundStyle(Theme.cream).padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            LinearGradient(colors: [Theme.panelDark.opacity(0.95), Theme.panel.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.gold.opacity(0.7)).frame(height: 1) }
        .fullScreenCover(isPresented: Binding(get: { overviewTab != nil }, set: { if !$0 { overviewTab = nil } }), onDismiss: controller.flushPendingSheet) { OverviewScreen(controller: controller, initialTab: overviewTab).onStage().immersiveSystemUI() }
        .onChange(of: overviewTab != nil) { _, on in controller.viewScreen("topBarOverview", pushed: on) }   // holds the AutoPlay (screenPushedOverWorld)
        .onChange(of: controller.worldScreenGeneration) { _, _ in overviewTab = nil }   // Unciv UncivGame.loadGame: screenStack.clear()
    }
    private func techTurns(_ s: GameState, _ civ: Civilization, _ science: Double) -> String {
        guard let t = civ.currentTech else { return "" }
        let turns = s.turnsToTech(civ, t, science: science)   // Unciv TechManager.turnsToTech
        return turns == "∞" ? " · ∞" : " · \(turns)t"
    }
    private func stat(_ icon: String, _ text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(icon).font(.system(size: 12))
            Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(color).lineLimit(1)
        }
    }
    private func iconButton(_ name: String, highlighted: Bool) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .bold)).foregroundStyle(highlighted ? Theme.panelDark : Theme.gold)
            .frame(width: 30, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? AnyShapeStyle(Theme.gold) : AnyShapeStyle(Theme.panelDark)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Unciv NextTurnButton: shows the current NextTurnAction, "[n] units idle" as subtext, long-press for the Next-turn menu.
struct NextTurnButton: View {
    @ObservedObject var controller: GameController
    /// The long press opened NextTurnMenu; its lift is no tap (uncivLongPress)
    @State private var longPressFired = false
    var body: some View {
        let action = controller.nextTurnAction
        let primary = action == .nextTurn || action == .autoPlay
        Button {
            // NextTurnButton: onActivation and addContextMenu (Longpress) are separate - the lift after a long press is no tap
            if longPressFired { longPressFired = false; return }
            controller.performNextTurnAction()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon(action)).font(.system(size: 20, weight: .bold))
                Text(L(action.text)).font(.system(size: 10, weight: .bold, design: .serif)).lineLimit(1).minimumScaleFactor(0.6)
                if let sub = controller.idleUnitsText, action == .nextUnit || action == .nextTurn { Text(sub).font(.system(size: 8, weight: .semibold)).lineLimit(1) }
                if controller.isProcessing, let civ = controller.turnProgressCiv { Text(L(civ)).font(.system(size: 8, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6) }
            }
            .foregroundStyle(primary || isLightAction(action) ? Theme.panelDark : Theme.cream)
            .frame(width: 96, height: 62)
            .overlay(alignment: .bottom) {
                // Unciv NextTurnProgress: a thin bar filling as the AI civilizations take their turns - on the button whatever
                // it says meanwhile ("Working...", "AutoPlay", "Retry Upload")
                if controller.isProcessing && controller.turnProgressMax > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(red: 0.38, green: 0, blue: 0))
                            Capsule().fill(Color(red: 0.13, green: 0.55, blue: 0.13)).frame(width: g.size.width * CGFloat(min(controller.turnProgress, controller.turnProgressMax)) / CGFloat(controller.turnProgressMax))
                        }
                    }
                    .frame(height: 4).padding(.horizontal, 12).padding(.bottom, 3)
                    .animation(.linear(duration: 0.1), value: controller.turnProgress)
                    .modifier(FadeInOnAppear(duration: 1))   // Unciv NextTurnProgress: Actions.fadeIn(1f) when it is first added
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(primary ? AnyShapeStyle(LinearGradient(colors: [Theme.gold, Theme.goldDim], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(color(action).opacity(0.9))))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.gold, lineWidth: 1.2))
            .shadow(color: .black.opacity(0.5), radius: 5, y: 3)
        }
        // Unciv NextTurnButton.update: `isEnabled = text == "AutoPlay" || ((isPlayersTurn || failedUpload) &&
        // !waitingForAutosave && !isNextTurnUpdateRunning())`
        .disabled(!controller.nextTurnButtonEnabled)
        .uncivLongPress(fired: $longPressFired) { if controller.isMyTurn && !controller.isProcessing && !controller.isAutoPlaying { controller.showNextTurnMenu = true } }
    }
    private func icon(_ a: GameController.NextTurnAction) -> String {
        switch a {
        case .retryUpload: return "arrow.up.circle"
        case .autoPlay: return "stop.fill"
        case .working, .waiting: return "hourglass"
        case .pickGreatPerson: return "person.crop.circle.badge.plus"
        case .pickConstruction: return "hammer.fill"
        case .pickTech: return "book.fill"
        case .pickPolicy: return "scroll"
        case .moveSpies: return "eye.fill"
        case .foundPantheon, .expandPantheon, .foundReligion, .enhanceReligion, .reformReligion: return "sparkles"
        case .worldCongressVote: return "building.columns.fill"
        case .nextUnit: return "figure.walk"
        case .moveAutomatedUnits: return "gearshape.2.fill"
        case .nextTurn: return "hourglass"
        }
    }
    private func color(_ a: GameController.NextTurnAction) -> Color {
        switch a {
        case .retryUpload: return Color(red: 0.8, green: 0.15, blue: 0.12)   // Unciv Color.RED
        case .pickGreatPerson: return Color(red: 0.6, green: 0.5, blue: 0.15)   // Unciv Color.GOLD
        case .pickConstruction: return Color(red: 0.6, green: 0.35, blue: 0.25)   // Unciv Color.CORAL
        case .pickTech: return Color(red: 0.25, green: 0.4, blue: 0.6)   // Unciv Color.SKY
        case .pickPolicy: return Color(red: 0.45, green: 0.3, blue: 0.6)   // Unciv Color.VIOLET
        case .moveSpies: return Color(white: 0.9)   // Unciv Color.WHITE
        // Unciv BeliefType colours (Pantheon #44c6cc, Founder #c00000, Enhancer #72cc45), toned like the others
        case .foundPantheon, .expandPantheon: return Color(red: 0.16, green: 0.47, blue: 0.48)
        case .foundReligion: return Color(red: 0.45, green: 0, blue: 0)
        case .enhanceReligion, .reformReligion: return Color(red: 0.27, green: 0.48, blue: 0.16)
        case .worldCongressVote: return Color(red: 0.5, green: 0.15, blue: 0.2)   // Unciv Color.MAROON
        case .nextUnit, .moveAutomatedUnits: return Color(white: 0.78)   // Unciv Color.LIGHT_GRAY
        case .working, .waiting: return Color(white: 0.45)   // Unciv Color.GRAY
        default: return Theme.panelDark
        }
    }
    /// Unciv'in WHITE / LIGHT_GRAY zeminli eylemlerinde etiket koyu olmali, yoksa okunmaz.
    private func isLightAction(_ a: GameController.NextTurnAction) -> Bool {
        switch a {
        case .moveSpies, .nextUnit, .moveAutomatedUnits: return true
        default: return false
        }
    }
}

/// Unciv SpyPresenter in the UnitTable: the spy icon, the spy's name and its effective rank as stars (brown, silver, gold)
struct SpyPanel: View {
    @ObservedObject var controller: GameController
    let spy: Spy
    var body: some View {
        let rank = controller.state.effectiveSpyRank(spy, action: GameState.spyActionDisplay[spy.action] ?? spy.action)
        let rankColor: Color = rank == 1 ? Color(red: 0.55, green: 0.27, blue: 0.07) : rank == 2 ? Color(white: 0.75) : rank == 3 ? Theme.gold : Color(white: 0.2)
        HStack(spacing: 8) {
            IdleUnitArrow(controller: controller, previous: true)   // Unciv UnitTable: the idle buttons stay with the spy
            ArtIcon(name: "Spy_White", folder: "OtherIcons", fallback: "person.fill.viewfinder", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(spy.name)).font(Theme.heading(15)).foregroundStyle(Theme.gold)
                HStack(spacing: 2) { ForEach(0..<max(0, rank), id: \.self) { _ in Image(systemName: "star.fill").font(.system(size: 14)).foregroundStyle(rankColor) } }
            }
            IdleUnitArrow(controller: controller, previous: false)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelDark.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
        // Unciv UnitTable: a tap on the table centres the map on the spy's city (SpyPresenter.position - none in the
        // hideout; setCenterPosition, selectUnit = false)
        .contentShape(Rectangle())
        .onTapGesture { if let c = spy.cityId.flatMap({ controller.state.city($0) }) { controller.setCenterPosition(c.coord, selectUnit: false); controller.refresh(full: false) } }
        // Unciv UnitTable closeButton: back to the summary
        .overlay(alignment: .topTrailing) { Button { controller.selectedSpyId = nil; controller.refresh(full: false) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gold) }.buttonStyle(.plain).offset(x: 6, y: -6) }
        .frame(maxWidth: 320)
    }
}


/// Unciv SummaryPresenter: with nothing selected the unit table shows "Units" and how many are idle / skipping.
struct SummaryPanel: View {
    @ObservedObject var controller: GameController
    var body: some View {
        let mine = controller.state.units(of: controller.state.playerId)
        let idle = controller.idleUnits.count
        let waiting = mine.filter { !$0.due && controller.state.isIdle($0) }.count   // Unciv CivView.idleUnitsCount(due = false)
        HStack(spacing: 8) {
            IdleUnitArrow(controller: controller, previous: true)   // Unciv UnitTable: the idle buttons stay with the summary
            Image(systemName: "person.3.fill").foregroundStyle(Theme.gold)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Units")).font(Theme.heading(14)).foregroundStyle(Theme.gold)
                let parts = [idle > 0 ? L("[\(idle)] idle") : nil, waiting > 0 ? L("[\(waiting)] skipping") : nil].compactMap { $0 }
                if !parts.isEmpty { Text(parts.joined(separator: ", ")).font(Theme.small).foregroundStyle(Theme.creamDim) }
            }
            IdleUnitArrow(controller: controller, previous: false)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelDark.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.card, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Unciv TutorialRender.showDialog: a tutorial popup showing one step at a time; Close moves on to the next step.
struct TutorialPopup: View {
    @ObservedObject var controller: GameController
    var body: some View {
        if let steps = controller.currentTip?.steps, !steps.isEmpty {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea().bleedIntoCutout()
                VStack(spacing: 12) {
                    ScrollView {
                        Text(steps[min(controller.tipStep, steps.count - 1)]).font(Theme.body).foregroundStyle(Theme.cream)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: 240)
                    Button(L("Close")) { controller.dismissTip() }.buttonStyle(ThemedButtonStyle(filled: true))
                }
                .padding(16).frame(maxWidth: 520)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.gold, lineWidth: 1))
                .padding(24)
            }
            .transition(.opacity)
        }
    }
}

/// Unciv's fade-in of a widget the first time it is added to the stage
struct FadeInOnAppear: ViewModifier {
    let duration: Double
    @State private var shown = false
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).onAppear { withAnimation(.linear(duration: duration)) { shown = true } }
    }
}

/// Unciv NotificationsScroll restore button: the bell fades in (1 s); ButtonFlashAction flashes it white-red six times over
/// 4 s whenever the count changes while it shows (and on showing with the list disabled)
struct BellIcon: View {
    let count: Int
    var flashOnAppear = false
    @State private var flashStart: Date? = nil
    @State private var shown = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: flashStart == nil)) { tl in
            let pct = flashStart.map { min(1, tl.date.timeIntervalSince($0) / 4) } ?? 1
            let shift = (1 - cos(12 * pct * .pi)) / 2
            Image(systemName: "bell.fill").foregroundStyle(Color(red: 1, green: 1 - shift, blue: 1 - shift))
        }
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.linear(duration: 1)) { shown = true }; if flashOnAppear { flashStart = Date() } }
        .onChange(of: count) { _, _ in flashStart = Date() }
        .task(id: flashStart) { guard let st = flashStart else { return }; try? await Task.sleep(nanoseconds: 4_000_000_000); if flashStart == st { flashStart = nil } }
    }
}

/// The screens GameView pushes over the world itself (save, load, new game) hold the multi-turn AutoPlay as the
/// controller's own do (GameController.screenPushedOverWorld) - Unciv's AutoPlay goes on only while the WorldScreen renders.
private struct ReportsPushedScreens: ViewModifier {
    let controller: GameController
    let save: Bool
    let load: Bool
    let newGame: Bool
    /// GameController.screenPushedOverWorld as GameView last drew it
    let worldPushed: Bool
    func body(content: Content) -> some View {
        content
            .onChange(of: save) { _, on in controller.viewScreen("save", pushed: on) }
            .onChange(of: load) { _, on in controller.viewScreen("load", pushed: on) }
            .onChange(of: newGame) { _, on in controller.viewScreen("newGame", pushed: on) }
            // Unciv UncivGame.setScreen: the world screen shown again after a screen pushed over it updates in its next render
            .onChange(of: worldPushed) { _, _ in controller.noteWorldScreenShown() }
    }
}
