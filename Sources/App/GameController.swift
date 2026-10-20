// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import SpriteKit
import Combine
import UIKit

/// A game handed between the main thread and the turn's thread (GameController.endTurn): the original stays the main
/// thread's, the clone is the turn thread's until it is handed back - never used by both at once, which the compiler
/// cannot see.
private struct HandedOver<T>: @unchecked Sendable { let value: T }
/// AutoPlay's hand-over (GameController.showWhileAutomating): the turn's thread waits for the main thread to show the
/// copy before it touches the game; `taken` is written before `done` is signalled and read after the wait.
private final class AutomationHandOver: @unchecked Sendable {
    var taken = false
    let done = DispatchSemaphore(value: 0)
}

/// UIApplication's background time for one piece of work that must outlive a trip to the background - a turn and its
/// autosave (Unciv's NextTurn is a non-daemon thread), the autosave written as the app is sent away (UncivGame.pause).
/// It is ended once, by whichever comes first - the work's end or iOS's expiration - and by whoever holds it: the
/// controller that asked for it may be gone by then (another game loaded, the main menu), and a task left open gets
/// the app terminated.
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid
    init(_ name: String) { id = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in end() } }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Bridges the immutable-ish GameState to SwiftUI and the SpriteKit scene.
@MainActor
final class GameController: ObservableObject {
    @Published var state: GameState
    /// Unciv UncivGame.Current.gameInfo: the game the app shows - RootView's controller. A turn whose world screen is no
    /// longer this one is dropped as Unciv's `if (game.gameInfo != originalGameInfo) return` drops it (turnArrived).
    static weak var current: GameController? = nil
    /// Unciv UnitActionsTable.update: another unit (or none) starts on page 0; UnitPresenter.selectUnit ends swapping and road connecting,
    /// and resets the Paradrop / Air Sweep action the unit was preparing (a per-unit action there, so another unit never inherits it)
    @Published var selectedUnitId: Int? = nil { didSet { if oldValue != selectedUnitId { unitActionPage = 0; resetSelectUnitModes() } } }
    /// Unciv UnitPresenter.selectUnit: `selectedUnitIsSwapping = false; selectedUnitIsConnectingRoad = false`, and a unit
    /// isPreparingParadrop / isPreparingAirSweep gets tryResetAction - also when the same unit is selected again.
    func resetSelectUnitModes() { swapMode = false; connectRoadMode = false; sweepMode = false; paradropMode = false }
    @Published var selectedCityId: Int? = nil
    @Published var reachable: Set<HexCoord> = []
    @Published var attackable: Set<HexCoord> = []
    /// Unciv WorldMapTileUpdater Z-6: the tiles that carry a crosshair for the selected unit - every visible target
    /// getAttackableEnemies finds for a military unit, even one that cannot attack any more this turn (`attackable`
    /// holds the targets it may attack now). Air units and cities keep `attackable`.
    var attackCrosshairs: Set<HexCoord> = []
    /// Unciv AttackableTile.tileToAttackFrom of the first getAttackableEnemies entry per target (refreshed with `attackable`):
    /// the BattleTable simulates from it, and the crosshair is half strength when it is not the unit's own tile.
    var attackOrigins: [HexCoord: HexCoord] = [:]
    @Published var banner: String? = nil
    /// Unciv CityScreen.exit → popScreen: a city opened from the overview goes back to it (popToOverview), and the world
    /// screen shown again updates in its next render - UncivGame.setScreen: `if (newScreen is WorldScreen) newScreen.shouldUpdate
    /// = true` - with the selection the exit dropped (CityButton.update moves the button up) and what was changed meanwhile.
    /// Unciv CityScreen.init: `addCompletedTutorialTask("Enter city screen")` whichever way the screen is opened
    @Published var showCity = false {
        didSet {
            epochsCityScreenOpen = showCity
            if !oldValue && showCity { completeTask("city") }
            // Unciv CityScreen.init: `cityView.updateCityStats()` before the screen is drawn (CityScreen.kt:164)
            if !oldValue && showCity, let id = selectedCityId { state.cityScreenOpened(id) }
            guard oldValue && !showCity else { return }
            popToOverview(from: "city", afterSheet: false)
            let updates = worldUpdates
            DispatchQueue.main.async { [weak self] in self?.updateWorldAfterCityScreen(since: updates) }
        }
    }
    @Published var showTech = false
    var techPickerCenterOn: String? = nil   // Unciv TechPickerScreen(centerOnTech): the tech a notification points at
    @Published var showDiplomacy = false
    @Published var showMenu = false
    @Published var showPolicies = false
    @Published var showPromotions = false
    @Published var showVictory = false
    @Published var showCivilopedia = false
    /// Unciv ICivilopediaText.makeLink(): "Category/Name", the entry the pedia should open on.
    var civilopediaEntry: String? = nil
    var civilopediaSearch = false   // Unciv "Open the Search Dialog" (Ctrl+F): open the pedia straight into its search popup
    @Published var infoTile: HexCoord? = nil
    @Published var handoffTo: String? = nil     // hot-seat: nation whose turn is about to start
    var editorPaint: ((HexCoord) -> Void)? = nil
    /// Unciv EditorMapHolder's drag-paint listener: `editorScreen.tabs.edit.paintTilesWithBrush(tile)`
    var editorDragPaint: ((HexCoord) -> Void)? = nil
    /// Unciv MapEditorScreen.highlightTile for a continent (MapEditorViewTab's "Continent" link): the tiles tinted
    /// Color.BROWN.darken(0.5f) - while there are any, the tapped tile's own highlight is hidden (hideSelection)
    var editorHighlight: [HexCoord] = []
    @Published var sweepMode = false
    /// Unciv WorldScreen.fogOfWar: UI state only, true by default, toggled by a spectator's "Fog of War" button
    @Published var fogOfWar = true
    /// The civ whose view the scene's tiles were last drawn from: switching views redraws every tile (the cached tile
    /// nodes of tiles that civ never explored must go).
    private var drawnViewCivId: Int? = nil
    @Published var showReligion = false
    /// Unciv WorldScreenMenuPopup(expertMode): the menu opened by a long press offers the Developer Console
    var menuExpertMode = false
    /// Unciv WorldScreen.openDeveloperConsole: no cheating unless you're by yourself (a spectator aside)
    func openDeveloperConsole() {
        guard !isProcessing else { return }
        if state.civs.filter({ $0.isPlayer && !$0.isSpectator }).count > 1 { return }
        showDevConsole = true
    }
    /// Unciv WorldScreen.deferFreeGreatPersonPicker: the picker was closed without a choice, so it is not reopened by itself
    var deferFreeGreatPersonPicker = false
    @Published var showEspionage = false
    @Published var showTrade = false
    @Published var showOverview = false   // "See your stats breakdown" completes on the Stats page only (OverviewScreen)
    /// Unciv OverviewAction: the page (and the row) the notification points at.
    var overviewPage: String? = nil
    var overviewSelect: String = ""
    /// Unciv ReligionTabPersistableData.selectedReligion: the religion the Religion page shows, kept while the app runs
    var overviewReligionSelection: String? = nil
    /// Unciv game.pushScreen over the EmpireOverviewScreen: CityScreen, DiplomacyScreen, PromotionPickerScreen and the
    /// Civilopedia are pushed over it, and popping one (EmpireOverviewScreen.resume → the page's activated("")) shows it
    /// again on the same page, refreshed; a jump to the map (resetToWorldScreen) drops it. Ours closes the overview
    /// under them, so it remembers the screen it pushed ("city", "diplomacy", "promotions", "civilopedia"), the page and
    /// the row to select (Unciv overviewScreen.select) - worked out when the screen is popped.
    struct OverviewReturn { let screen: String; let page: String?; var select: () -> String = { "" } }
    var overviewReturn: OverviewReturn? = nil
    /// `screen` was popped: back to the overview it was pushed from. `afterSheet`: a sheet still being dismissed, so the
    /// overview waits for flushPendingSheet; a screen already queued behind it (another push) keeps the way back.
    func popToOverview(from screen: String, afterSheet: Bool = true) {
        guard let r = overviewReturn, r.screen == screen, pendingAfterDismiss == nil else { return }
        overviewReturn = nil
        let reopen = { [weak self] in
            guard let self else { return }
            self.overviewPage = r.page; self.overviewSelect = r.select(); self.showOverview = true
        }
        if afterSheet { afterSheetDismiss(reopen) } else { reopen() }
    }
    /// The sheets' onDismiss (GameView), each a screen Unciv pops
    func overviewDismissed() { overviewPage = nil; overviewSelect = ""; religionHighlight = nil; flushPendingSheet() }
    func diplomacyDismissed() {
        showTrade = false
        if reopenDiplomacyOn == nil { popToOverview(from: "diplomacy") }   // not on its way to the Civilopedia
        flushPendingSheet()
    }
    func promotionsDismissed() { promotionUnitId = nil; popToOverview(from: "promotions"); flushPendingSheet() }
    func civilopediaDismissed() {
        civilopediaEntry = nil; civilopediaSearch = false
        if let d = reopenDiplomacyOn {
            reopenDiplomacyOn = nil
            afterSheetDismiss { [weak self] in self?.diplomacyCiv = d >= 0 ? d : nil; self?.showDiplomacy = true }
        } else { popToOverview(from: "civilopedia") }
        flushPendingSheet()
    }
    /// Unciv PromotionPickerScreen(unit): the overview opens the picker for its row's unit, the map's selection untouched
    var promotionUnitId: Int? = nil
    var promotionUnit: Unit? { promotionUnitId.flatMap { state.unit($0) }.flatMap { $0.civId == state.playerId || state.player.isSpectator ? $0 : nil } ?? selectedUnit }
    /// Unciv PolicyAction: the policy the notification points at.
    var policyHighlight: String? = nil
    /// Unciv ReligionAction: the religion the notification points at.
    var religionHighlight: String? = nil
    @Published var tradePartner: Int? = nil
    @Published var showChat = false
    @Published var showMultiplayerStatus = false
    @Published var showMusic = false
    @Published var showDevConsole = false
    /// Unciv ConsoleCivCommands `civ remove`: the ConfirmPopup "... Do you really want to annihilate the poor buggers?" -
    /// set by the console, shown once the console is out of the way (or over it when it is kept open).
    var pendingAnnihilation: (civId: Int, message: String)? = nil
    @Published var confirmAnnihilation: IdentifiedAnnihilation? = nil
    struct IdentifiedAnnihilation: Identifiable { let civId: Int; let message: String; var id: Int { civId } }
    @Published var showGreatPersonPicker = false   // Unciv GreatPersonPickerScreen (freeGreatPeople > 0)
    @Published var showMayaCalendar = false        // Unciv MayaCalendar.openPopup (tap the year while the Long Count is displayed)
    @Published var foreignCityInfo: IdentifiedInt? = nil   // Unciv CityButton.foreignCityInfoPopup
    @Published var diplomacyCiv: Int? = nil      // Unciv: the diplomacy screen opens on the civilization you asked about
    @Published var minimapMaximized = false   // Unciv MinimapHolder.maximized
    @Published var showImprovementPicker = false
    @Published var showDetailedStats = false
    @Published var showGPPBreakdown = false
    var gppBreakdownPerson: String? = nil   // GreatPersonPointsBreakdownPopup(greatPerson): one great person, or nil for all
    @Published var showRenameCity = false
    @Published var showRenameUnit = false
    @Published var roadOverlay: (tile: HexCoord, path: [HexCoord])? = nil   // Unciv ConnectRoadOverlayButtonData + unitConnectRoadPaths
    @Published var swapOverlayTile: HexCoord? = nil   // Unciv SwapWithOverlayButtonData: the tile carrying the swap button
    @Published var spyOverlayTile: HexCoord? = nil   // Unciv addMovingSpyOverlay: the tile carrying the move-spy button
    /// Unciv WorldMapHolder.addTileOverlays: the tapped tile whose units of ours are offered as round icons to tap
    /// (a city centre, or a tile with one of our air units); removeUnitActionOverlay drops it on the next tap.
    @Published var unitIconsTile: HexCoord? = nil
    @Published var battleTarget: HexCoord? = nil   // Unciv BattleTable: the enemy tile whose fight is being previewed
    @Published var selectedSpyId: Int? = nil { didSet { if selectedSpyId == nil { spyOverlayTile = nil } } }      // Unciv SpyPresenter: a spy picked in the espionage overview, waiting for a city tap
    var foreignCityTapped: HexCoord? = nil   // Unciv CityButton.moveButtonDown: the city whose banner the last tap lowered
    /// Unciv MoveHereOverlayButton: first tap shows it, second tap moves. `path` is Unciv's unitMovementPaths entry -
    /// the tile the unit stands on at the end of each turn on the way there, painted sky blue under the badge.
    @Published var pendingMove: (tile: HexCoord, turns: Int, unitId: Int, path: [HexCoord])? = nil
    @Published var showUpgradeMenu = false        // Unciv UnitUpgradeMenu (long-press on Upgrade)
    /// Unciv CityScreen.pickTileData: a CreatesOneImprovement building waits for its tile before it is queued (or bought)
    struct PickTileForImprovement: Equatable { let building: Production; let improvement: String; let isBuying: Bool; let stat: String }
    @Published var cityPickTile: PickTileForImprovement? = nil
    @Published var showVotePicker = false         // Unciv DiplomaticVotePickerScreen
    @Published var showVoteResult = false         // Unciv DiplomaticVoteResultScreen
    @Published var showCongress = false           // VP: UI/VPCongressView.swift
    @Published var cityTile: HexCoord? = nil       // Unciv CityScreenTileTable: tile picked on the city map
    @Published var connectRoadMode = false { didSet { if !connectRoadMode { roadOverlay = nil } } }        // Unciv "Connect road": next tapped tile is the road target
    @Published var unitActionPage = 0             // Unciv UnitActionsTable paging ("Show more" / "Back")
    /// Unciv NotificationsScroll.oneTimeNotification: an entry from the overview to show once more in the world's list,
    /// waiting for the next update, which takes it (updateContent sets it back to null once it is the highlight)
    private(set) var oneTimeNotification: NotificationItem? = nil
    /// whether the one-time entry is one of the list's own (Unciv's `this in notifications`, an identity test): a tapped
    /// row or this turn's entry picked in the overview, not an earlier turn's or one made up for the pick
    private var oneTimeNotificationInList = false
    /// Unciv NotificationsScroll.clickedNotification: the entry a tap asked to highlight, waiting for the next update
    /// (which makes it the oneTimeNotification when there is none: "reselecting can keep a one-time in the list")
    private var clickedNotification: NotificationItem? = nil
    /// Unciv updateContent's additionalNotification: the one-time entry the list does not hold (`this !in notifications`),
    /// added to the rows the list was last rebuilt with - tinted, as its -1 row - and gone with the next rebuild
    @Published private(set) var additionalNotification: NotificationItem? = nil
    /// Unciv ListItem's `isSelected`: the entry the list was last rebuilt with as highlightNotification (its row, -1 for
    /// the additional one) - enlarged when "Enlarge selected notifications" is on - until the next rebuild, which the
    /// next update is: updateContent forgets the highlight once drawn, so the hash it compares changes back
    @Published var enlargedNotification: Int? = nil
    /// Unciv CategoryHeader.onClick: the categories collapsed since the list was last rebuilt - updateContent fills every
    /// category table again (fillNotificationCategoryTable), so each rebuild opens them all
    @Published var collapsedNotificationCategories: Set<String> = []
    /// Unciv NotificationsScroll.update's selectedCell: the highlighted entry to scroll into the band, with a serial of its own
    /// for every rebuild that has one - counted on across world screens, so a pane made for a new one, which takes the serial
    /// it finds as seen, never mistakes a later request for it
    @Published private(set) var notificationReveal: NotificationReveal? = nil
    /// Unciv NotificationsScroll.userSetting as the last update() read it - nil on a fresh WorldScreen, whose lateinit
    /// field is not initialised yet, so its first update() counts as a setting change - and notificationsHash.
    private var notificationsScrollSetting: String? = nil
    private var notificationsHash = 0
    /// Unciv NotificationsScroll.update without the layout: getUserSetting (a changed setting resets notificationsHash),
    /// updateContent, then `if (!userSetting.static) { if (contentChanged && !userSettingChanged && isHidden) isHidden =
    /// false }` - a hidden list rebuilt scrolls back in (`scrollX = maxX`), and scrollX → RestoreButton.checkScrollX →
    /// hide() → updateUserSetting(Visible) stores the setting. Unciv's WorldScreen.update runs it, at most once a frame
    /// (requestNotificationsUpdate) - while the next turn runs on its clone too, on the original game the old WorldScreen
    /// keeps showing.
    private func updateNotificationsScroll() {
        let setting = UserSettings.notificationScroll
        let userSettingChanged = setting != notificationsScrollSetting
        if userSettingChanged { notificationsScrollSetting = setting; notificationsHash = 0 }
        if setting == "Disabled" { return }   // update(): the Disabled list returns before updateContent, which keeps the click
        let items = player.notificationItems
        let contentChanged = updateNotificationsContent(items)
        // Visible and Permanent are shown already (Permanent is `static`); scrollX(px) does nothing while `maxX < 5`,
        // which an empty list is
        guard setting == "Hidden", contentChanged, !userSettingChanged, !items.isEmpty || additionalNotification != nil else { return }
        // The setting is a plain UserDefault GameView reads as it draws: the frame's update comes after the refresh that
        // drew the world, and a rebuild for a new entry changes nothing GameView watches, so the list is told to draw again
        objectWillChange.send()
        UserSettings.notificationScroll = "Visible"; notificationsScrollSetting = "Visible"
    }
    /// Unciv NotificationsScroll.updateContent: the click becomes the oneTimeNotification when there is none; the hash is
    /// `notifications.hashCode().withHash(oneTimeNotification.hashCode())` - Unciv hashes the Notification objects, ours
    /// what each one shows; the one-time entry is the highlight - added to the rows, tinted, when the list does not hold it
    /// - and both it and the click are forgotten. `if (notificationsHash == newHash && highlightNotification == null)
    /// return false`, otherwise the list is rebuilt: every category table filled again, the highlight's ListItem the one
    /// enlarged and its cell the selectedCell update() scrolls into view, and `true` returned. As the hash of the update
    /// that drew a highlight holds the one-time entry, the next update rebuilds the list without it.
    private func updateNotificationsContent(_ items: [NotificationItem]) -> Bool {
        if oneTimeNotification == nil, let clicked = clickedNotification { oneTimeNotification = clicked; oneTimeNotificationInList = true }
        var h = Hasher()
        for n in items { h.combine(n.text); h.combine(n.meta.category.rawValue); h.combine(n.meta.icons) }
        h.combine(oneTimeNotification?.text); h.combine(oneTimeNotification?.meta.category.rawValue)
        let newHash = h.finalize()
        var additional: NotificationItem? = nil
        var highlight: Int? = nil
        if let one = oneTimeNotification {
            // `this !in notifications`: Unciv's Notification has no equality of its own, so this is the very object - a tapped
            // row, or a pick of this turn's in the overview, is the list's own entry at its row; an earlier turn's entry
            // (TurnManager.endTurn moved it to the log), getExploredResourcesNotification's and the console's new ones are
            // never in the list, whatever they say
            if oneTimeNotificationInList, one.index >= 0, one.index < items.count, items[one.index].text == one.text { highlight = one.index }
            else { additional = NotificationItem(index: -1, text: one.text, meta: one.meta); highlight = -1 }
            oneTimeNotification = nil
        }
        clickedNotification = nil
        if notificationsHash == newHash && highlight == nil { return false }
        notificationsHash = newHash
        if !collapsedNotificationCategories.isEmpty { collapsedNotificationCategories = [] }
        if additionalNotification?.text != additional?.text || additionalNotification?.meta.category != additional?.meta.category { additionalNotification = additional }
        if enlargedNotification != highlight { enlargedNotification = highlight }
        if let highlight { notificationReveal = NotificationReveal(id: highlight, serial: (notificationReveal?.serial ?? 0) + 1) }
        return true
    }
    /// Unciv WorldScreen.shouldUpdate: render() runs update() once a frame, however many times it was asked for since the
    /// last one, and not while another screen is pushed over the world (only the screen shown renders) - the request waits
    /// for it to go. One action here runs refresh() several times, so the notification list's update - whose highlight
    /// lasts until the update after the one that drew it - is asked for by refresh() and run on the display's next frame,
    /// once: a highlight is drawn and on screen before an update can take it away.
    private var notificationsShouldUpdate = false
    /// the display link that runs it, there only while an update is asked for and the world screen is shown
    private var notificationsFrame: CADisplayLink? = nil
    private func requestNotificationsUpdate() {
        notificationsShouldUpdate = true
        guard notificationsFrame == nil else { return }
        let link = CADisplayLink(target: NotificationsFrameTarget(self), selector: #selector(NotificationsFrameTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        notificationsFrame = link
    }
    fileprivate func notificationsFrameTick() {
        notificationsFrame?.invalidate(); notificationsFrame = nil
        // under a pushed screen the request is kept and the link let go - no frame polled while the screen is up - and
        // the world screen shown again asks for its update anyway (noteWorldScreenShown)
        if screenPushedOverWorld { worldScreenWasPushed = true; return }
        guard notificationsShouldUpdate else { return }
        notificationsShouldUpdate = false
        updateNotificationsScroll()
    }
    /// `--notif-selftest`: whether the display link is running
    var notificationsFramePolling: Bool { notificationsFrame != nil }
    /// Whether a screen was last seen pushed over the world (noteWorldScreenShown)
    private var worldScreenWasPushed = false
    /// Unciv UncivGame.setScreen: `if (newScreen is WorldScreen) newScreen.shouldUpdate = true` - the world screen shown
    /// again after any screen pushed over it (the city screen, the pickers, the overview, the Civilopedia, save / load...)
    /// updates in its next render, a request left waiting under the screen included. Told of every change of
    /// screenPushedOverWorld - by GameView as it draws and by viewScreen - and acting once, as the screen goes. (The city
    /// screen's own map update, updateWorldAfterCityScreen, asks for the same update; both come to one in the frame.)
    func noteWorldScreenShown() {
        let pushed = screenPushedOverWorld
        defer { worldScreenWasPushed = pushed }
        if worldScreenWasPushed && !pushed { requestNotificationsUpdate() }
    }
    /// Unciv ListItem.onClick: `notification.execute(worldScreen); clickedNotification = notification;
    /// GUI.setUpdateWorldOnNextRender()` - the update that follows highlights the entry. Ours is asked for before the
    /// actions run, as they refresh the world screen themselves; one update comes of them all.
    func clickNotification(_ item: NotificationItem) {
        clickedNotification = item
        executeNotification(item)
        if item.meta.actions.isEmpty { refresh(full: false) }   // executeNotification refreshes only when it acts
    }
    /// Unciv `worldScreen.notificationsScroll.oneTimeNotification = notification`: the next update shows the entry in the
    /// list - added and tinted when the list does not hold it (`this !in notifications`) - highlighted and scrolled into
    /// view, each time it is set, the same entry again included. `inList`: the entry is the list's own - this turn's,
    /// picked in the overview, at its row - rather than an earlier turn's or a new one (the resource finder's, the console's)
    func setOneTimeNotification(_ item: NotificationItem, inList: Bool) {
        oneTimeNotification = item
        oneTimeNotificationInList = inList
    }
    /// Unciv RestoreButton.show() / hide(): the list scrolled away (Hidden) or brought back (Visible) by the player -
    /// updateUserSetting stores it as userSetting too, so the next update() sees no setting change - and nothing more:
    /// neither asks for WorldScreen.update, so the list is drawn again (GameView reads the setting) and not rebuilt
    func setNotificationScrollFromList(_ setting: String) {
        objectWillChange.send()
        UserSettings.notificationScroll = setting; notificationsScrollSetting = setting
    }
    /// Unciv startNewScreenJob / UncivGame.loadGame: the game comes back on a new WorldScreen, whose NotificationsScroll
    /// starts over - no one-time entry, click or highlight, every category open - and whose UI is on. (notificationReveal
    /// keeps its serial.)
    func freshWorldScreen() {
        notificationsScrollSetting = nil; notificationsHash = 0; uiEnabled = true
        oneTimeNotification = nil; oneTimeNotificationInList = false; clickedNotification = nil; additionalNotification = nil; enlargedNotification = nil; collapsedNotificationCategories = []
    }
    /// Unciv KeyShortcutDispatcherVeto.createPopupBasedDispatcherVetoer: while a Popup is open the world screen's global
    /// shortcuts are skipped and so is every actor outside the popup, and a screen pushed over the world (the CityScreen,
    /// the pickers, the overview...) brings shortcuts of its own only. The world's keys - WorldKeyboardShortcuts, the unit
    /// action keys, the small unit button's Cycle - answer only while none of these is up; the sheets and covers the views
    /// present themselves (save, load, options, the top bar's overview) are caught as the key is pressed (worldKeysBlocked).
    var worldShortcutsVetoed: Bool {
        // popups over the world screen (the tutorial popup, the alerts and the trade popups, menus, confirmations)
        if state.outcome == nil && (currentAlert != nil || tradeThanksFrom != nil || !(currentTip?.steps.isEmpty ?? true)) { return true }
        if showMenu || showAutoPlayMenu || showNextTurnMenu || showUpgradeMenu || showRenameCity || showRenameUnit || showMusic
            || showMayaCalendar || confirmNextTurn || confirmPillage != nil || confirmDisband != nil || confirmBreakPromise != nil
            || confirmAnnihilation != nil || uploadErrorPopup != nil || authRequest != nil || loadingLatestState || latestStateError != nil
            || loadGameError != nil { return true }
        // screens pushed over it (the VictoryScreen of a finished game among them)
        if state.outcome != nil || showCity || showTech || showDiplomacy || showPolicies || showPromotions || showVictory || showCivilopedia
            || showReligion || showEspionage || showOverview || showChat || showMultiplayerStatus || showDevConsole || showGreatPersonPicker
            || showImprovementPicker || showFoundReligion || showEnhanceReligion || showFreeBeliefs || showVotePicker || showVoteResult || showCongress
            || foreignCityInfo != nil { return true }
        // Not the next turn: Unciv's keys answer while it runs "so the user can explore their world" (KeyboardPanningListener,
        // the global shortcuts, the AutoPlay button's). The ones that load, quick-load or start a game refuse it themselves
        // (GameView), as they rebuild the shared ruleset the turn's thread reads; the rest are closed by canChangeState.
        return false
    }
    /// The veto at the moment a key is pressed: the states above, or anything presented over the root view.
    var worldKeysBlocked: Bool { worldShortcutsVetoed || FunctionKeys.rootIsCovered }
    /// Unciv: the multi-turn AutoPlay goes on only from NextTurnButton.update, which WorldScreen.render reaches - while a
    /// screen is pushed over the world (the city screen, the pickers, the overview, the Civilopedia, save / load / new
    /// game, the vote screens...) no AutoPlay turn starts, and it goes on once the world is back; a popup leaves it going.
    var screenPushedOverWorld: Bool {
        showCity || showTech || showDiplomacy || showPolicies || showPromotions || showVictory || showCivilopedia || showReligion
            || showEspionage || showOverview || showGreatPersonPicker || showImprovementPicker || showFoundReligion
            || showEnhanceReligion || showFreeBeliefs || showVotePicker || showVoteResult || showCongress || !viewScreensPushed.isEmpty
    }
    /// The screens the views present themselves, reported here: GameView's save, load and new game, the top bar's overview.
    var viewScreensPushed: Set<String> = []
    func viewScreen(_ name: String, pushed: Bool) {
        if pushed { viewScreensPushed.insert(name) } else { viewScreensPushed.remove(name) }
        noteWorldScreenShown()   // the set is no published state: GameView may not draw again for it
    }
    /// Unciv WorldScreen.uiEnabled (toggleUI, the Toggle UI binding): off hides the top bar, the status buttons, the
    /// tech / policy / diplomacy buttons, the tutorial task, the tile info, the unit table and its actions, the
    /// notifications, the minimap and the battle table. The zoom buttons stay, and the keys still answer.
    @Published var uiEnabled = true
    func toggleUI() { uiEnabled.toggle() }
    /// Unciv NotificationsTabPersistableData: the count seen last time in this turn, and the turns the player closed
    var overviewNotificationsLastCount: (turn: Int, count: Int)? = nil
    @Published var overviewClosedTurns: Set<Int> = []
    /// Unciv DiplomacyTabPersistableData: the diagram instead of the table, city-states in it
    @Published var overviewShowDiagram = false
    @Published var overviewDiagramCityStates = false
    /// Unciv CityTabPersistableData / UnitTabPersistableData (SortableGrid.ISortState): each grid keeps its own column and
    /// direction, and the overview opens on them again. An empty column is SortDirection.None - the data's own order
    /// (civ.cities, getCivUnits) - which a header click never goes back to.
    struct OverviewSort: Equatable { var column = ""; var descending = false }
    var overviewCitySort = OverviewSort()
    var overviewUnitSort = OverviewSort()
    var notificationRoundRobin: [String: Int] = [:]  // Unciv Notification.execute cycles through its actions
    var autoPromote: Bool {
        get { UserDefaults.standard.bool(forKey: "epochs.autoPromote") }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.autoPromote") }
    }
    /// Unciv: the trade table only lives inside DiplomacyScreen (a counteroffer pushes DiplomacyScreen(viewingCiv, requestingCiv, trade))
    func openTrade(with civId: Int) { diplomacyCiv = civId; tradePartner = civId; showTrade = true; showDiplomacy = true }
    @Published var tradeThanksFrom: Int? = nil   // Unciv TradePopup.TradeThanksPopup after an accepted trade request
    @Published var counterOfferSeed: TradeOffer? = nil   // Unciv TradePopup "How about something else...": the AI's offer pre-loaded on the trade table
    func propose(_ proposed: TradeOffer) -> Bool {
        guard !isProcessing else { return false }
        let offer = proposed   // the research agreement gold top-up happens on the table (TradeScreen.offerTrade), as in Unciv
        // Unciv TradeTable: every offer becomes a trade request the other civilization answers on its turn ("Retract offer" until then)
        guard offer.to != state.playerId else { return false }
        var request = TradeOffer(id: state.newId(), from: offer.from, to: offer.to, turnCreated: state.turn)
        request.give = offer.give; request.want = offer.want
        request.evTailGive = offer.evTailGive; request.evTailWant = offer.evTailWant   // the offer lists' order (TradeOffersList)
        // our earlier trade request to them goes (Unciv's table retracts it first); a friendship offer is a popupAlert there, not a trade request
        state.pendingOffers.removeAll { $0.from == offer.from && $0.to == offer.to && !$0.isFriendshipRequest }
        // Unciv TradeView.tryProposeStagedTrade: `otherCiv.tradeRequests.add(...)` - a human recipient (hot-seat,
        // multiplayer) gets its TradePopup on its own turn, as an AI's request to a human does
        state.queueOffer(request)
        // TradeView.tryProposeStagedTrade then runs `civ.cache.updateCivResources()` - a trade cancelled since (a war
        // declared on the trade screen's partner) shows in the supply and the happiness from here on
        state.updateCivResources(offer.from)
        GameEvents.post(.tradeProposed(turn: state.turn))
        refresh(full: false)
        return true
    }
    /// TradeView.tryRetractOffer: the request goes, then `civ.cache.updateCivResources()`
    func retractOffer(_ id: Int) {
        guard !isProcessing else { return }
        let from = state.pendingOffers.first { $0.id == id }?.from
        state.pendingOffers.removeAll { $0.id == id }
        if let from { state.updateCivResources(from) }
        refresh(full: false)
    }
    /// Unciv TradeView.hasPendingOfferFromUs: `otherCiv.tradeRequests.any { it.requestingCiv == civ.civID }` - not a friendship offer
    func hasPendingOffer(to partner: Int) -> Bool { state.pendingOffers.contains { $0.from == state.playerId && $0.to == partner && !$0.isFriendshipRequest } }
    func cancelCoup(_ spyId: Int) { guard !isProcessing else { return }; state.cancelCoup(civId: state.playerId, spyId: spyId); refresh(full: false) }
    func attemptCoup(_ spyId: Int) { guard !isProcessing else { return }; let ok = state.attemptCoup(civId: state.playerId, spyId: spyId); Audio.shared.play(ok ? "chimes" : "click"); refresh(full: false) }
    func stageAutoPromotions() {
        guard autoPromote else { return }
        GameController.promoteAutomatedUnits(state)
    }
    @Published var showFoundReligion = false
    @Published var showEnhanceReligion = false
    @Published var showFreeBeliefs = false   // Unciv ReformReligion picker
    @Published var waitingFor: String? = nil          // online: another player's turn
    @Published var syncMessage: String? = nil
    /// Unciv WorldScreen.failedUpload: the next-turn button becomes "Retry Upload" until it succeeds.
    @Published var uploadFailed = false
    /// Unciv WorldScreen.nextTurn's popups after a failed upload: "Could not upload game! Reason: [..]" (with "Copy to
    /// clipboard") - shown over the game, which stays on the turn that could not be uploaded.
    @Published var uploadErrorPopup: String? = nil
    /// Unciv AuthPopup raised by a MultiplayerAuthException: answered with whether authentication succeeded.
    @Published var authRequest: ((Bool) -> Void)? = nil
    /// Unciv loadLatestMultiplayerState: "Loading latest game state..." while the newer game downloads, and the
    /// popup that replaces it when the download failed ("Couldn't download the latest game state!", Retry, Main menu).
    @Published var loadingLatestState = false
    @Published var latestStateError: String? = nil
    /// Unciv MultiplayerHelpers.loadMultiplayerGame from the world screen (the MultiplayerStatusPopup's "Load [game]"): its
    /// "Loading latest game state..." popup (loadingLatestState's) stays over the world until the download ends - no Next
    /// Turn starts meanwhile - and is reused for the failure's message with a close button (`reuseWith(message, true)`).
    @Published var loadGameError: String? = nil
    func loadMultiplayerGame(_ gameId: String, onOpen: @escaping (GameState) -> Void) {
        guard !isProcessing, !loadingLatestState else { return }
        loadingLatestState = true
        Task { @MainActor in
            do {
                let st = try await MultiplayerHelpers.downloadGame(gameId)
                loadingLatestState = false
                onOpen(st)
            } catch {
                loadingLatestState = false
                loadGameError = MultiplayerHelpers.loadExceptionMessage(error)
            }
        }
    }
    /// Unciv UncivGame.loadGame's UncivShowableException on a load the world screen started (startNewScreenJob): back
    /// to the main menu, which shows this.
    @Published var mainMenuMessage: String? = nil
    private var pollTask: Task<Void, Never>?
    private var featureSetWatch: AnyCancellable? = nil

    var isOnline: Bool { state.settings.isOnline }
    /// Unciv WorldScreen.isPlayersTurn: our turn - not while the next turn is being played (nextTurn sets it false, and
    /// canChangeState with it, until the new turn's WorldScreen arrives), and not after a failed upload, which leaves it
    /// false until the turn is uploaded (only "Retry Upload" is left to press).
    var isMyTurn: Bool { !isProcessing && Multiplayer.isMyTurn(state) && !(isOnline && uploadFailed) }

    func replaceState(_ s: GameState) {
        // Unciv UncivGame.loadGame (an undo, the latest online state): `for (screen in screenStack) screen.dispose();
        // screenStack.clear()` - the city screen and whatever else was opened over the old WorldScreen go with it, and the
        // new one starts with nothing selected; the world it shows is updated at once (the city screen owes it nothing)
        closeScreensForNewWorldScreen()
        state = s
        freshWorldScreen()
        scene.resetTiles()
        refresh()
        // Unciv UncivGame.loadGame of the same game (an undo, the latest online state): the rebuilt WorldScreen selects the
        // capital's tile and restore() puts the old scroll and zoom back, so the camera stays where it was
        selectTurnStartTile(centerCamera: false)
        updateOnlineStatus()
    }

    func updateOnlineStatus() {
        guard isOnline else { waitingFor = nil; return }
        if Multiplayer.isMyTurn(state) { waitingFor = nil; selectTurnStartTile(centerCamera: false) }
        else {
            let p = state.currentHuman
            waitingFor = p.nation   // Unciv NextTurnAction.Waiting: "Waiting for [${gameInfo.currentPlayerCiv}]..." - the civID
        }
        // Unciv Multiplayer's update loop refreshes the current game whoever's turn it is: `usesCustomServer() ||
        // preview == null || !preview.isUsersTurn()`, and every server Epochs talks to is an UncivServer, not Dropbox.
        // Ours stopped polling on our own turn, so a skip or force-resign done meanwhile was never seen and our upload
        // at the end of the turn wrote over it.
        startPolling()
    }

    /// Unciv Multiplayer's update loop: every 500 ms, `throttle(lastCurGameRefresh, currentGameRefreshDelay)` - the
    /// first check at once, then one each time the delay (read afresh each round) has passed - runs the current
    /// game's requestUpdate. Ours waited a fixed 20 s before its first check.
    func startPolling() {
        guard pollTask == nil, let gameId = state.settings.gameId else { return }
        pollTask = Task { [weak self] in
            var last: Date? = nil
            while !Task.isCancelled {
                // Unciv Multiplayer.multiplayerGameUpdater: every 500 ms, `throttle(lastCurGameRefresh, currentGameRefreshDelay,
                // ...) { currentGame.requestUpdate() }` - the setting as it stands now (10 s unless changed), not a fixed 20 s
                let delay = TimeInterval(max(1, Multiplayer.currentGameRefreshSeconds))
                if last.map({ Date().timeIntervalSince($0) > delay }) ?? true {
                    last = Date()
                    guard await self?.syncFromServer(gameId: gameId) != nil else { return }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Unciv: the current game's MultiplayerGamePreview.requestUpdate (the preview only), then WorldScreen's
    /// MultiplayerGameUpdated receiver - `if (isNextTurnUpdateRunning() || hasLatestGameState(gameInfo, preview)) return`,
    /// else loadLatestMultiplayerState(). The poll plays no sound and flashes nothing: Unciv's update() is silent, and
    /// loadLatestMultiplayerState's notifyTurnStarted only flashes a desktop window. (Ours downloaded the whole game
    /// every time, played the current-game sound and flashed an invented "Your turn!".)
    func syncFromServer(gameId: String) async {
        guard let preview = await MultiplayerStatus.shared.requestUpdate(gameId) else {
            syncMessage = MultiplayerStatus.shared.refreshErrors[gameId]; return
        }
        syncMessage = nil
        guard !isProcessing, !loadingLatestState, state.settings.gameId == gameId, !Multiplayer.hasLatestGameState(state, preview) else { return }
        await loadLatestMultiplayerState(gameId)
    }

    /// Unciv WorldScreen.loadLatestMultiplayerState: "Loading latest game state...", the game downloaded
    /// (MultiplayerServer.downloadGame) and opened on a new world screen (startNewScreenJob → UncivGame.loadGame: a
    /// player who may not spectate is sent to the main menu with the message; the autosave follows turnsBetweenAutosaves).
    /// A failed download shows "Couldn't download the latest game state!" with Retry and Main menu.
    func loadLatestMultiplayerState(_ gameId: String) async {
        // Unciv's MultiplayerGameUpdated receiver: `if (isNextTurnUpdateRunning() || ...) return` - and the load would rebuild
        // the ruleset the turn's thread reads; loadLatestMultiplayerState itself: `if (game.screen != this@WorldScreen) return
        // // User already went somewhere else` - nothing is loaded under the city screen or another screen pushed over the world
        guard !isProcessing, !screenPushedOverWorld else { return }
        loadingLatestState = true
        do {
            let latest = try await Multiplayer.download(gameId)
            loadingLatestState = false
            guard state.settings.gameId == gameId, !isProcessing else { return }
            do { try Multiplayer.checkSpectate(latest) } catch { mainMenuMessage = MultiplayerHelpers.loadExceptionMessage(error); return }
            uploadFailed = false   // the new WorldScreen starts with failedUpload = false
            replaceState(latest)
            if latest.uncivTurns % max(1, UserSettings.turnsBetweenAutosaves) == 0 { SaveManager.autosave(latest, nextTurn: true) }
        } catch {
            loadingLatestState = false
            latestStateError = MultiplayerHelpers.loadExceptionMessage(error, primary: "Couldn't download the latest game state!")
        }
    }

    /// Unciv ChatButton.refreshVisibility (at the world screen's start and on every MultiplayerServer.setFeatureSet): an
    /// online game on a server with chat (`featureSet.chatVersion > 0`) joins its chat, which starts the socket;
    /// anything else stops the socket - ChatWebSocket.stop() leaves the chats themselves alone.
    func refreshChatVisibility() {
        if state.settings.isOnline && ServerFeatures.shared.featureSet.chatVersion > 0, let g = state.settings.gameId {
            ChatStore.shared.join(gameId: g); ChatStore.shared.start()
        } else { ChatStore.shared.stop() }
    }

    /// Unciv AuthPopup(...).open(true), awaited: true once authentication succeeded, false when the popup was closed.
    func requestAuthentication() async -> Bool {
        await withCheckedContinuation { cont in authRequest = { ok in cont.resume(returning: ok) } }
    }
    func answerAuthentication(_ ok: Bool) { let r = authRequest; authRequest = nil; r?(ok) }
    @Published var currentTip: TutorialTip? = nil
    @Published var tipStep: Int = 0
    @Published var tutorialTaskCollapsed = false   // Unciv UncivGame.isTutorialTaskCollapsed
    /// Unciv TutorialController.tutorialQueue: a triggered tutorial waits here until its popup is closed.
    private var tutorialQueue: [String] = []
    /// Unciv TutorialRender: Close shows the next step; after the last one the tutorial is marked as shown.
    func dismissTip() {
        guard let t = currentTip else { return }
        if tipStep + 1 < t.steps.count { tipStep += 1; return }
        Tutorial.seen = Tutorial.seen.union([t.id]); tutorialQueue.removeAll { $0 == t.id }
        currentTip = nil; tipStep = 0
        showNextTutorial()
    }
    /// Unciv BaseScreen.displayTutorial: queue a tutorial that has not been shown yet. Its AutoPlay check only applies to the
    /// WorldScreen (updateTip); the callers here mirror PolicyPickerScreen, PromotionPickerScreen and CityScreen.
    func displayTutorial(_ id: String) {
        guard Tutorial.enabled, !Tutorial.seen.contains(id), !tutorialQueue.contains(id) else { return }
        tutorialQueue.append(id)
        showNextTutorial()
    }
    private func showNextTutorial() {
        guard Tutorial.enabled, currentTip == nil, let id = tutorialQueue.first else { return }
        guard let t = Tutorial.tips.first(where: { $0.id == id }), !t.steps.isEmpty else {   // Unciv showDialog: no text closes at once
            Tutorial.seen = Tutorial.seen.union([id]); tutorialQueue.removeFirst(); showNextTutorial(); return
        }
        currentTip = t; tipStep = 0
    }
    func updateTip() {
        guard editorPaint == nil, !state.civs.isEmpty else { return }
        Tutorial.detectTasks(state)
        currentTask = Tutorial.nextTask(state)
        // Unciv WorldScreen.showTutorialsOnNextTurn `if (!game.settings.showTutorials || autoPlay.isAutoPlaying()) return` and
        // BaseScreen.displayTutorial `if (this is WorldScreen && this.autoPlay.isAutoPlaying()) return`: the world screen's
        // tutorials are neither queued nor shown while the player's AutoPlay runs
        guard Tutorial.enabled, !epochsAutoplay, !isAutoPlaying else { return }
        let seen = Tutorial.seen
        for t in Tutorial.tips where !seen.contains(t.id) && !tutorialQueue.contains(t.id) && t.condition(state) { tutorialQueue.append(t.id) }
        showNextTutorial()
    }
    @Published var currentTask: Tutorial.Task? = nil
    func completeTask(_ id: String) { Tutorial.complete(id); currentTask = Tutorial.nextTask(state) }
    /// Unciv RenderEvent: the task's Event.getMatchingChoices(currentPlayerCiv) - [] when it has no choices, nil when it
    /// has some and none matches, which hides the task (displayTutorialTaskOnUpdate: `!renderEvent.isValid`).
    func tutorialTaskChoices(_ task: Tutorial.Task) -> [EventChoiceDef]? {
        guard let e = task.event, !e.choices.isEmpty else { return [] }
        let matching = state.matchingChoices(e, civId: state.playerId)
        return matching.isEmpty ? nil : matching
    }
    /// Unciv RenderEvent.addChoice's button ("Got it"): onChoice (the world screen updates), then
    /// choice.triggerChoice(currentPlayerCiv) - "Mark tutorial [] complete" records the task.
    func chooseTutorialTaskChoice(_ choice: EventChoiceDef) {
        guard !isProcessing else { return }
        state.triggerChoice(choice, civId: state.playerId)
        refresh()
    }
    @Published var showMinimap: Bool = UserDefaults.standard.object(forKey: "epochs.minimap") as? Bool ?? true { didSet { UserDefaults.standard.set(showMinimap, forKey: "epochs.minimap") } }
    @Published var isProcessing = false
    /// Unciv NextTurnProgress: AI civs processed so far / total, and the civ being processed.
    @Published var turnProgress = 0
    @Published var turnProgressMax = 0
    @Published var turnProgressCiv: String? = nil
    @Published var revision = 0

    let scene: MapScene
    private var bannerTask: Task<Void, Never>?

    init(state: GameState) {
        self.state = state
        // Debug: `--debug-un` puts the United Nations into the player's capital and starts the vote next turn (UI test for the vote screens).
        if CommandLine.arguments.contains("--debug-un"), let un = state.rs.buildings.values.first(where: { $0.uniques.contains("Triggers voting for the Diplomatic Victory") }), let cap = state.capital(of: state.playerId), let ci = state.cityIndex(cap.id) {
            if !state.cities[ci].buildings.contains(un.name) { state.cities[ci].buildings.append(un.name) }
            for i in state.civs.indices where state.civs[i].isAlive && !state.civs[i].isBarbarian { state.civs[i].civFlags["TurnsTillNextDiplomaticVote"] = 1 }
        }
        scene = MapScene(size: CGSize(width: 400, height: 800))
        scene.scaleMode = .resizeFill
        scene.controller = self
        // Unciv UncivGame.loadGame: a game on one device with more than one human opens on the ready
        // screen, whether it has just been started or just been loaded.
        if state.isHotSeat && !state.settings.isOnline { handoffTo = state.currentHuman.nation }
        MusicController.shared.chooseTrack(prefix: state.player.nation, suffixes: [MusicMood.peaceOrWar(!state.player.atWarWith.isEmpty), MusicMood.theme, MusicMood.ambient], flags: .slowFade)
        defer { updateOnlineStatus() }
        if state.civs.allSatisfy({ $0.isSpectator }) {
            // the map editor's state holds only its Spectator: nothing to select, the camera on the middle of the map
            scene.scrollToMiddle()
            refresh(full: false)
        } else {
            // Unciv UncivGame.loadGame: a fresh WorldScreen (a new game, a loaded one) restores no scroll - the camera
            // goes to the capital, else the first unit, and that tile is selected
            selectTurnStartTile(centerCamera: true)
        }
        MultiplayerStatus.shared.currentGameId = state.settings.gameId   // Unciv UncivGame.isCurrentGame
        if state.settings.isOnline {
            ChatStore.shared.currentGameId = state.settings.gameId
            ChatStore.shared.currentPlayerCiv = state.player.nation
            MultiplayerStatus.shared.startPolling(currentGameId: state.settings.gameId)
        }
        // Unciv NewGameScreen.startNewGame: ToastPopup("Game ID copied to clipboard!", worldScreen, 2500) on the world
        // screen the new online game was loaded into
        if let toast = GameController.pendingToast { GameController.pendingToast = nil; flash(toast, time: 2500) }   // NewGameScreen: ToastPopup("Game ID copied to clipboard!".tr(), worldScreen, 2500)
        // Unciv ChatButton.init → refreshVisibility, and again whenever the server's feature set changes
        refreshChatVisibility()
        featureSetWatch = ServerFeatures.shared.$featureSet.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshChatVisibility() }
        }
    }
    /// A toast for the next world screen: the new-game screen builds the game, and the controller only exists after it.
    nonisolated(unsafe) static var pendingToast: String? = nil

    // MARK: derived
    var player: Civilization { state.player }
    /// Unciv UnitPresenter.update: a unit that is no longer ours (captured) is dropped - unless we are a spectator,
    /// whose UnitTable.tileSelected takes anyone's units (isEligible: isOwnerOf || isSpectator)
    var selectedUnit: Unit? { selectedUnitId.flatMap { state.unit($0) }.flatMap { $0.civId == state.playerId || state.player.isSpectator ? $0 : nil } }
    var selectedCity: City? { selectedCityId.flatMap { state.city($0) } }
    /// Unciv WorldScreen.selectedCiv (updateSelectedCiv, on every update): the owner of the selected unit, else of the
    /// selected city, else the viewing civ. Only a spectator ever selects another civ's unit or city on the map (a city
    /// looked into through a spy is not the bottom table's selectedCity), so everyone else always gets their own civ.
    var selectedCivId: Int {
        guard player.isSpectator else { return state.playerId }
        return selectedUnit?.civId ?? selectedCity?.civId ?? state.playerId
    }
    /// Unciv WorldScreen.getGameViewConsideringForOfWar: the selectedGameView while fogOfWar, else the spectator's own
    /// (spectatorGameView) - the civ whose map, minimap, tile table and movement arrows the world screen draws.
    var viewCivId: Int { player.isSpectator && !fogOfWar ? state.playerId : selectedCivId }
    /// The selectedCiv the top bar shows and the tech, policy, espionage and overview screens open with
    var selectedCiv: Civilization { state.civ(selectedCivId) ?? player }
    /// Unciv TechPolicyDiplomacyButtons "Fog of War" (a spectator's only): the selected civ's map when on, the spectator's
    /// unrestricted one when off. Unciv WorldScreen.RestoreState keeps it with the selected civ across world screens.
    func toggleFogOfWar() {
        guard player.isSpectator else { return }
        Audio.shared.play("paper")   // UncivSound.Paper
        fogOfWar.toggle()
        refresh()   // worldScreen.shouldUpdate = true
    }
    /// SwiftUI supports one sheet at a time: a sheet requested while another is dismissing gets dropped and leaves the old one stuck.
    /// Screens that switch sheets store the follow-up here; GameView runs it from the dismissed sheet's `onDismiss`.
    var pendingAfterDismiss: (() -> Void)?
    func afterSheetDismiss(_ action: @escaping () -> Void) { pendingAfterDismiss = action }
    /// Unciv: the Civilopedia is pushed over the DiplomacyScreen and popping it returns there, on the same civilization
    var reopenDiplomacyOn: Int? = nil
    func openCivilopediaFromDiplomacy(_ link: String) {
        reopenDiplomacyOn = diplomacyCiv ?? -1
        showDiplomacy = false
        afterSheetDismiss { [weak self] in self?.civilopediaEntry = link; self?.showCivilopedia = true }
    }
    func flushPendingSheet() { guard let a = pendingAfterDismiss else { return }; pendingAfterDismiss = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { a() } }
    /// Unciv UnitManager.getDueUnits: due and idle
    var idleUnits: [Unit] { state.units(of: state.playerId).filter { $0.due && state.isIdle($0) } }
    /// Unciv IdleUnitButton: every idle unit (due or not); from a unit outside that list both arrows go to the first
    func idleArrow(previous: Bool) {
        let idle = state.units(of: state.playerId).filter { state.isIdle($0) }
        guard !idle.isEmpty else { return }
        var target = idle[0]
        if let cur = selectedUnitId, let i = idle.firstIndex(where: { $0.id == cur }) { target = idle[(i + (previous ? -1 : 1) + idle.count) % idle.count] }
        setCenterPosition(target.coord)   // selectUnit: tileSelected runs on the unit's tile before selectUnit(unitToSelect)
        selectedSpyId = nil; selectedUnitId = target.id; selectedCityId = nil
        resetSelectUnitModes()   // Unciv IdleUnitButton: unitTable.selectUnit(unitToSelect), the same unit included
        refresh(full: false)
    }
    var hasIdleUnits: Bool { state.units(of: state.playerId).contains { state.isIdle($0) } }
    var notifications: [String] { Array(player.notifications.suffix(4)) }

    func refresh(full: Bool = true) {
        revision += 1
        state.invalidateHappiness()
        updateTip()
        // Unciv WorldScreen.update's order: the vote results, then the free Great Person picker, and only then the alert
        // popups - a pending alert waits under the picker, the picker does not wait for the alerts
        if !state.freeGreatPersonOptions(state.playerId).isEmpty && !deferFreeGreatPersonPicker && !isAutoPlaying && !epochsAutoplay && !showGreatPersonPicker && !showVoteResult { showGreatPersonPicker = true }
        // ...and before a TradePopup, with no other alert to show, the requests that became invalid meanwhile are dropped
        if isMyTurn && !isProcessing && !(isAutoPlaying && autoPlayTurnsLeft > 0) && !showGreatPersonPicker
            && !player.popupAlerts.contains(where: { $0.type != .TradeRequest && state.alertShouldOpen($0) }) { state.sweepInvalidTradeRequests(state.playerId) }
        attackOrigins = [:]
        // Unciv WorldMapTileUpdater.updateTiles: with no unit, city or spy selected the unit action overlays (the Move
        // here button - the Paradrop one included - and the unit icons) are removed; while a city is selected they stay.
        if selectedUnitId == nil && selectedCityId == nil && selectedSpyId == nil {
            if pendingMove != nil { pendingMove = nil }
            if paradropOverlay != nil { paradropOverlay = nil }
            if unitIconsTile != nil { unitIconsTile = nil }
        }
        if let u = selectedUnit {
            if u.def.isAir {
                reachable = Set(state.rebaseTargets(for: u))
                attackable = Set(state.airTargets(for: u)); attackCrosshairs = attackable
            } else {
                // Unciv WorldMapTileUpdater Z-1: of getReachableTilesInCurrentTurn, the tiles the unit canMoveTo and - not being
                // an air unit - every tile its civ has not explored (isUnknownTileWeShouldAssumeToBePassable), whatever is there.
                // While it prepares a paradrop getReachableTilesInCurrentTurn is the canParadropOn tiles (UnitMovement.kt:357-360),
                // all of them visible now (:773) and so explored: of those, the ones it canMoveTo (drawn BLUE by MapScene).
                reachable = paradropMode ? Set(state.paradropTargets(u).filter { state.canMoveTo(u, $0) }) : state.moveHighlightTiles(u)
                // Unciv WorldMapTileUpdater Z-6 / BattleTable / WorldMapHolder.onTileRightClicked: TargetHelper.getAttackableEnemies
                // over the unit's getDistanceToTiles - every tile it can still reach this turn is a place to attack from, the
                // range is getRange() (promotions included) and a unit that must set up does so on arrival (movePreparingAttack).
                // The first AttackableTile per target is the one `firstOrNull { tileToAttack == ... }` picks.
                let enemies = u.isMilitary ? state.attackableEnemies(u, distanceToTiles: state.distanceToTiles(u)) : []
                for a in enemies where attackOrigins[a.tileToAttack] == nil { attackOrigins[a.tileToAttack] = a.tileToAttackFrom }
                // Unciv WorldMapTileUpdater Z-6 marks, for any military unit, the targets
                // `.filter { isNuclearWeapon || tileToAttack.isVisible() }` - whether or not it can still attack this turn;
                // MapUnit.canAttack (hasMovement, not a civilian, attacksThisTurn < maxAttacksPerTurn) gates only the Attack
                // button and the right-click attack.
                let isNuke = state.unitHasUnique(u, "Nuclear weapon of Strength []")
                let seen = state.visibleTiles(for: state.playerId)
                attackCrosshairs = Set(enemies.filter { isNuke || seen.contains($0.tileToAttack) }.map { $0.tileToAttack })
                if u.isMilitary && u.movementLeft > 0 && u.attacksThisTurn < 1 + state.extraAttacks(of: u) {
                    attackable = attackCrosshairs
                } else { attackable = [] }
            }
        } else if let c = selectedCity, !showCity, c.civId == state.playerId || player.isSpectator, state.canBombard(c) {
            // Unciv BattleTable: a selected city may bombard (no table against another city); a spectator selects anyone's
            reachable = []; attackable = Set(state.bombardableTiles(c).filter { state.city(at: $0) == nil }); attackCrosshairs = []
        } else { reachable = []; attackable = []; attackCrosshairs = [] }
        // Unciv: the world screen does not update under a screen pushed over it - its update runs from WorldScreen.render,
        // which only the screen shown gets - so under the city screen the map and the notifications wait for it to go
        // (showCity's didSet): entering a city redraws nothing behind it, and neither does an action taken in the city
        if showCity { worldUpdateBehindCityScreen = max(worldUpdateBehindCityScreen, full ? 3 : 2); return }
        updateWorld(full: full)
    }
    /// Unciv WorldScreen.update's `if (!hasOpenPopups() && !autoPlay.isAutoPlaying() && isPlayersTurn)` branch, first the
    /// vote results and then `!oneMoreTurnMode && (viewingCiv.isDefeated() || gameInfo.checkForVictory()) -> VictoryScreen`
    /// (WorldScreen.kt:446-451): run with every update of the world screen - after each action of the player and each popup
    /// closed - so a victory the player's own action completes is recorded then (GameState.worldScreenVictoryCheck). The
    /// check comes before the alerts in that `when`, so an alert queued by the same action (CityConquered) does not hold it.
    /// While a multi-turn AutoPlay goes on, the same condition is asked first - `if (autoPlay.isAutoPlaying() &&
    /// !gameInfo.oneMoreTurnMode && (viewingCiv.isDefeated() || gameInfo.checkForVictory())) autoPlay.stopAutoPlay()`
    /// (WorldScreen.kt:441-443), popups and the vote results notwithstanding - and stops it. Never while the turn is processed
    /// (isMyTurn): the screen then shows a copy, which Unciv's update did not have (it read the game automateTurn changed).
    private func worldScreenVictoryCheck() {
        guard isMyTurn, handoffTo == nil, state.outcome == nil else { return }
        if isAutoPlaying && autoPlayTurnsLeft > 0 {
            if state.worldScreenVictoryCheck() { stopAutoPlay() }
        } else if !showVoteResult {
            state.worldScreenVictoryCheck()
        }
    }
    /// The world updates owed while the city screen covers it: 1 the units and banners (entering changed the selection
    /// only), 2 their overlays too (an action in the city: its worked tiles, a building's yields), 3 every tile
    private var worldUpdateBehindCityScreen = 0
    /// How many times the world screen's map was updated (updateWorld), so a deferred update already overtaken is skipped
    private var worldUpdates = 0
    /// Unciv WorldScreen.update's map and notifications
    private func updateWorld(full: Bool) {
        worldScreenVictoryCheck()
        // what the city screen left owing is paid here, whatever asked for this update - a partial one coming before the
        // deferred update (which it overtakes) must not swallow every tile or the yield overlays
        let owed = worldUpdateBehindCityScreen
        worldUpdateBehindCityScreen = 0
        worldUpdates += 1
        let full = full || owed >= 3
        // Unciv WorldScreen.update: updateSelectedCiv(), then mapHolder.updateTiles(getGameViewConsideringForOfWar().civView)
        // - a spectator's selection of another civ's unit or city (or the Fog of War toggle) redraws the map in that view
        let viewer = viewCivId
        if drawnViewCivId != viewer {
            let first = drawnViewCivId == nil
            drawnViewCivId = viewer
            if !first { scene.resetTiles(); scene.refreshAll(); return }
        }
        if full { scene.refreshAll() } else { scene.refreshUnits(); if owed == 2 { scene.refreshYieldOverlay() } }
        requestNotificationsUpdate()   // Unciv WorldScreen.update: notificationsScroll.update(viewingCiv.notifications, ..)
    }
    /// The world screen shown again after the city screen (UncivGame.setScreen's shouldUpdate), unless it was updated
    /// since (a new turn's world screen, or any refresh after the exit - updateWorld pays what is owed whoever calls it)
    /// or the city screen is back: the units and banners always - the exit dropped the selection - every tile only when
    /// an action in the city asked for it (a tile bought, the city renamed), and the worked-tile and yield overlays when
    /// an action may have changed the city's tiles
    private func updateWorldAfterCityScreen(since updates: Int) {
        guard !showCity, worldUpdates == updates else { return }
        updateWorld(full: false)
    }

    /// Unciv ToastPopup(message, screen, time = 2000): the key translated, closed after `time` milliseconds
    func flash(_ text: String, time: UInt64 = 2000) {
        banner = L(text)
        bannerTask?.cancel()
        bannerTask = Task { try? await Task.sleep(nanoseconds: time * 1_000_000); if !Task.isCancelled { banner = nil } }
    }

    // MARK: input
    /// Unciv WorldMapHolder.onTileClicked: the overlays go, the tile becomes the selected tile, UnitTable.tileSelected
    /// picks what stands there, and - during our turn - the unit selected before the tap gets its move, swap or road
    /// button on the tile (or acts at once with Single tap move). A long press is `tileLongPressed`.
    func tapTile(_ hex: HexCoord) {
        if InputTrace.on { traceTapStart(hex) }
        defer { if InputTrace.on { traceTapEnd() } }
        // Unciv EditorMapHolder: a tap on a tile plays UncivSound.Click, then onTileClick
        if let paint = editorPaint { if state.map.contains(hex) { Audio.shared.play("click"); paint(hex) }; return }
        // Unciv WorldMapHolder: every tile group takes the tap - TileGroup.update hides the layers of a tile the viewer has not
        // explored, not the group - so an unknown tile clicks, drops the overlays and becomes the selected tile too, whatever
        // is selected (no unit, an air unit, a spy, a city); only UnitTable.tileSelected picks nothing there.
        guard state.outcome == nil, state.map.contains(hex) else { return }
        Audio.shared.play("click")   // Unciv WorldMapHolder.kt:123: every tap on a tile clicks
        // Unciv WorldMapHolder.onTileClicked: removeUnitActionOverlay is the first thing it does, before
        // it asks whose turn it is, and a badge whose unit has died or has nothing left is not redrawn.
        if let pm = pendingMove, pm.tile != hex || (state.unit(pm.unitId)?.movementLeft ?? 0) <= 0 { pendingMove = nil }
        // The Paradrop button goes the same way (it stays inert rather than going while its unit has no movement left)
        if let po = paradropOverlay, po.tile != hex || state.unit(po.unitId) == nil { paradropOverlay = nil }
        // Unciv addTileOverlays: the tapped tile's units of ours as round icons - on a city centre, or with our air units
        unitIconsTile = unitIconUnits(at: hex).isEmpty ? nil : hex
        // Unciv WorldScreen.canChangeState = isPlayersTurn && !viewingCiv.isSpectator(): only the overlays that act need it
        let canChangeState = isMyTurn && !isProcessing && !player.isSpectator
        // Unciv WorldMapHolder.onTileClicked: `selectedTile = tileView` (WorldMapHolder.kt:159) comes before it asks whether
        // a spy is being moved, so every tap - a spy's too - makes the tapped tile the selected one: the TileInfoTable's
        // (empty on an unexplored one: GameView), the white highlight's (WorldMapTileUpdater.updateTiles' last line) and
        // the one BattleTable.update weighs the selected unit (or city) against; unitBattleTableShown decides whether it shows.
        battleTarget = hex
        infoTile = hex
        // Unciv WorldMapHolder.onTileClicked with a spy selected: nothing picked on the tile, only addMovingSpyOverlay - a
        // button on the tapped tile (MoveSpyOverlayButtonData), the movement icon over a city the spy canMoveTo, else a red
        // cross. Tapping the tile again presses it - while the state may change (addTileOverlays: `worldScreen.canChangeState`).
        if let spyId = selectedSpyId {
            if spyOverlayTile == hex, canChangeState { pressMoveSpyButton(spyId, at: hex); return }
            spyOverlayTile = hex; refresh(full: false); return
        }
        // Unciv onTileClicked outside our turn, or as a spectator: tileSelected still selects what is on the tile (a
        // spectator anyone's units and cities); `isPlayersTurn` only gates the move, swap and road overlays.
        guard canChangeState else {
            foreignCityTapped = nil   // a tap on the map raises a banner the city button lowered
            tileSelected(hex)
            refresh(full: false); return
        }
        // Unciv MoveHereOverlayButtonData: the button is inert while the unit has no movement left. Its onActivation is bound
        // when the button is made - moveUnitToTargetTile, which asks nothing more of the tile: getTileToMoveToThisTurn goes
        // next to a tile the unit cannot enter (a tile it had not explored turning out to be water, say), or nowhere.
        if let pm = pendingMove, pm.tile == hex, let mover = state.unit(pm.unitId), mover.civId == state.playerId,
           !swapMode, !paradropMode, !connectRoadMode, !sweepMode, mover.movementLeft > 0,
           !mover.def.isAir || state.rebaseTargets(for: mover).contains(hex) {
            if mover.def.isAir { rebaseMove(mover, to: hex) } else { performMove(mover, to: hex) }
            return
        }
        // Unciv MoveHereOverlayButtonData with the Paradrop icon: pressing it (tapping its tile again) is
        // moveUnitToTargetTile for the unit that raised it, whatever tileSelected picked since (our city, our civilian on
        // that tile); inert (no onActivation) while that unit has no movement left.
        if let po = paradropOverlay, po.tile == hex, let mover = state.unit(po.unitId), mover.civId == state.playerId {
            if mover.movementLeft > 0 { paradropSelected(to: hex, unit: mover) } else { refresh(full: false) }
            return
        }
        if let u = selectedUnit {
            // Unciv WorldMapHolder: a tap offers the drop only onto a tile the unit canMoveTo (onTileClicked's
            // canPerformActionsOnTile) and canReach (canParadropOn): addTileOverlaysWithUnitMovement counts it as one turn
            // and, with Single tap move, drops at once (tryHeadTowards); otherwise it raises MoveHereOverlayButtonData with
            // the Paradrop icon (pressed above), and - tileSelected having run first there - the tap still selects our city
            // or our civilian on that tile, the button staying up for the paratrooper. Any other tile offers no movement at
            // all, and the Paradrop action stays on: only UnitPresenter.selectUnit (or the action button) resets it. A long
            // press is tileLongPressed (onTileRightClicked).
            if paradropMode {
                if hex != u.coord, state.paradropTargets(u).contains(hex), state.canMoveTo(u, hex) {
                    if UserSettings.singleTapMove { paradropSelected(to: hex, singleTap: true); return }
                    paradropOverlay = (hex, u.id)
                }
            }
            // Unciv WorldMapHolder.onTileClicked: while connecting a road the tapped tile gets only the ConnectRoad button
            // (addTileOverlaysWithUnitRoadConnecting) - a land, passable, explored tile with a road path; tapping it again
            // presses the button. The mode stays on until a unit is selected or the button is pressed.
            if connectRoadMode {
                if let ro = roadOverlay, ro.tile == hex { pressConnectRoad(u, to: hex); return }
                roadOverlay = nil
                if hex != u.coord, let t = state.map[hex], t.isLand, !t.isImpassable, player.explored.contains(hex) {
                    if let path = state.roadPath(civId: u.civId, from: u.coord, to: hex) { roadOverlay = (hex, path); refresh(full: false); return }
                } else if hex != u.coord { unitIconsTile = nil }   // addTileOverlaysWithUnitRoadConnecting: no overlay at all on such a tile
            }
            // Unciv: while swapping, a tile the unit canSwapTo keeps the selection (tileSelected returns) and gets the
            // "swap with" button (SwapWithOverlayButtonData) - pressed at once with Single tap move, else by tapping again.
            if swapMode {
                if hex != u.coord, state.canUnitSwapTo(u, hex) {
                    if UserSettings.singleTapMove || swapOverlayTile == hex { swapMoveUnit(u, to: hex); return }
                    swapOverlayTile = hex; refresh(full: false); return
                }
                swapOverlayTile = nil
            }
            // Unciv: in either mode no movement overlay is offered; the tap only selects what is on the tile
            if !swapMode && !connectRoadMode {
            if u.def.isAir {
                // Unciv UnitTable.tileSelected: no other unit is selected while preparing an Air Sweep
                if sweepMode { refresh(full: false); return }
                if state.airTargets(for: u).contains(hex) { refresh(full: false); return }
                // Unciv addTileOverlaysWithUnitMovement: an air unit reaches a place it may land in one turn - with Single
                // tap move it flies there at once (tryHeadTowards, the unit kept selected), otherwise the Move here button
                // goes up and the tap selects what is there (our city, our carrier) like any other tap.
                if state.rebaseTargets(for: u).contains(hex) {
                    if UserSettings.singleTapMove {
                        let exploredBefore = state.player.explored.count
                        unitIconsTile = nil
                        state.rebase(unitId: u.id, to: hex)
                        if state.player.explored.count > exploredBefore { clearUndo() }   // Unciv Tile.setExplored clears the undo checkpoints
                        selectedUnitId = u.id; selectedCityId = nil
                        refresh(); return
                    }
                    pendingMove = (hex, 1, u.id, [])   // Unciv: an air unit's unitMovementPaths entry is empty
                }
            }
            // Unciv BattleTable: tapping an enemy previews the fight, only the Attack button attacks
            // (a long press attacks straight away: tileLongPressed). onTileClicked asks canMoveTo, not the targets: an
            // unguarded civilian we are at war with is both, and its tile also gets the Move here button below (with Single
            // tap move the unit walks in and captures it); an enemy unit or city is never a tile to move to.
            if attackable.contains(hex) && !state.canMoveTo(u, hex) { refresh(full: false); return }
            let ownUnitHere = state.units(at: hex).contains { $0.civId == u.civId && $0.id != u.id }
            let ownCityHere = state.city(at: hex)?.civId == state.playerId
            // Unciv WorldMapHolder.onTileClicked: canPerformActionsOnTile = canMoveTo(tile) ||
            // (isUnknownTileWeShouldAssumeToBePassable(tile) && !isAirUnit) - a tile the unit's civ has not explored is offered
            // whatever really stands there, so no button's absence gives away hidden water, a mountain, a unit or a city.
            // Unciv addTileOverlaysWithUnitMovement / onTileRightClicked: while preparing a paradrop, canReach is canParadropOn
            // (handled above) - no ordinary move is offered
            let unknownTile = !(state.civ(u.civId)?.explored.contains(hex) ?? true)
            if !paradropMode, !u.def.isAir, hex != u.coord, unknownTile || state.canMoveTo(u, hex) {
                // Unciv addTileOverlaysWithUnitMovement: turnsToGetThere = getShortestPath(tile).size, asked on every tap -
                // 0 (no path; for an automated civilian, no way into land of a civ it is at war with) leaves the tile
                // with the plain overlays. The same path is unitMovementPaths[unit], drawn as the sky trail.
                let path = state.shortestPath(u, to: hex)
                if !path.isEmpty {
                    let turns = path.count
                    // Unciv WorldMapHolder.addTileOverlaysWithUnitMovement: a one-turn move goes straight through
                    // when Single tap move is on, whatever is standing on the target.
                    if u.movementLeft > 0, UserSettings.singleTapMove && turns <= 1 {
                        performMove(u, to: hex, singleTap: true); return
                    }
                    // Otherwise the first tap raises the badge. A tile holding one of our own units, or our city, also
                    // selects what is standing there, as Unciv's tileSelected does, so it falls through.
                    if pendingMove?.tile != hex {
                        pendingMove = (hex, turns, u.id, path)
                        if !ownUnitHere && !ownCityHere { refresh(full: false); return }
                    }
                }
            }
            }
        }
        // Unciv BattleTable with a selected city: the bombard is previewed; the Bombard button fires
        if selectedUnit == nil, let sc = selectedCity, !showCity, sc.civId == state.playerId, attackable.contains(hex) {
            refresh(full: false)
            return
        }
        foreignCityTapped = nil   // a tap on the map raises a banner the city button lowered
        // The badge raised above belongs to the unit that raised it: it stays while our city is selected
        // (WorldMapTileUpdater keeps the overlays), and goes when nothing is (refresh).
        tileSelected(hex)
        refresh(full: false)
    }

    /// Unciv UnitTable.tileSelected: nothing on a tile we have not explored; the selection stays while a swapping unit
    /// taps a tile it canSwapTo, or an air unit prepares an Air Sweep. Otherwise our city on the tile comes first (not
    /// while connecting a road), then the military unit, then the civilian - eligible meaning ours (anyone's for a
    /// spectator) and not the one already selected; air units are never picked here (their icons are). The civilian
    /// tapped again beside an eligible military unit, or the selected unit's own tile with nothing else to pick, deselects.
    /// `forceSelectUnit` (setCenterPosition's) is selected before all of them - past the same two early returns. A unit or
    /// city selected takes the unit table from a selected spy (UnitTable.presenter).
    func tileSelected(_ hex: HexCoord, forceSelectUnit: Int? = nil) {
        guard player.explored.contains(hex) else { return }
        let cur = selectedUnit
        if swapMode, let u = cur, state.canUnitSwapTo(u, hex) { return }
        if sweepMode, cur?.def.isAir == true { return }
        let spectator = player.isSpectator
        func isEligible(_ u: Unit) -> Bool { (u.civId == state.playerId || spectator) && u.id != cur?.id }
        // Unciv TileView.militaryUnit / civilianUnit: the tile's two ground slots, as far as the viewer can see them
        let seen = Set(state.visibleUnits(for: state.playerId).map(\.id))
        let ground = state.units(at: hex).filter { !$0.def.isAir && seen.contains($0.id) }
        let mil = ground.first { $0.isMilitary }, civilian = ground.first { $0.isCivilian }
        let priority: Unit? = mil.flatMap { isEligible($0) ? $0 : nil } ?? civilian.flatMap { isEligible($0) ? $0 : nil }
        let next: Unit?
        if cur == nil { next = priority }
        else if cur?.id == civilian?.id, let m = mil, isEligible(m) { next = nil }
        else if cur?.id == mil?.id, let c = civilian, isEligible(c) { next = c }
        else { next = priority }
        if let f = forceSelectUnit {
            // UnitTable.selectUnit(forceSelectUnitView): UnitPresenter.selectUnit's resets, the unit already selected included
            selectedSpyId = nil; selectedUnitId = f; selectedCityId = nil; resetSelectUnitModes()
        } else if let city = state.city(at: hex), city.civId == state.playerId || spectator, !connectRoadMode {
            selectedSpyId = nil; selectCityOnMap(city)
        } else if let n = next {
            selectedSpyId = nil; selectedUnitId = n.id; selectedCityId = nil
        } else if let c = cur, c.coord == hex {
            selectedUnitId = nil   // Unciv: toggle selection if the same unit is clicked again by player
        }
    }

    /// Unciv WorldMapHolder.addTileOverlays: `tileView.getVisibleUnits().mapNotNull { it.tryGetMapUnitView() }` - the
    /// units on the tile we can see and command (a spectator: all of them), in Tile.getUnits order - offered as icons
    /// only on a city centre or when one of them is an air unit.
    func unitIconUnits(at t: HexCoord) -> [Unit] {
        let seen = Set(state.visibleUnits(for: state.playerId).map(\.id))
        let owned = state.units(at: t).filter { seen.contains($0.id) && ($0.civId == state.playerId || player.isSpectator) }
        guard state.map[t]?.isCityCenter == true || owned.contains(where: { $0.def.isAir }) else { return [] }
        return owned
    }
    /// Unciv addTileOverlays unit icon (ClickableCircle.onClickSuppressive, the Click sound): selectUnit(unit), then
    /// removeUnitActionOverlay.
    func tapUnitIcon(_ unitId: Int) {
        Audio.shared.play("click")
        guard let u = state.unit(unitId), u.civId == state.playerId || player.isSpectator else { return }
        selectedSpyId = nil
        selectedUnitId = u.id; selectedCityId = nil
        resetSelectUnitModes()   // UnitPresenter.selectUnit's resets, the unit already selected included
        pendingMove = nil; paradropOverlay = nil; unitIconsTile = nil; swapOverlayTile = nil; roadOverlay = nil
        refresh(full: false)
    }

    /// Unciv WorldMapHolder longPress ("Move units with a long tap", a unit selected) -> onTileRightClicked: it never
    /// selects anything. The unit's own tile does nothing at all; otherwise the overlays go and the tile is selected, and
    /// while the state may change a swapping unit swaps onto a tile it canSwapTo (else nothing), any other unit attacks
    /// an attackable enemy there, else moves when it canReach the tile - connecting a road is not consulted.
    func tileLongPressed(_ hex: HexCoord) {
        InputTrace.log("tileLongPressed \(InputTrace.hex(hex)) selected=\(selectedUnit.map { "\($0.name)#\($0.id)" } ?? "none")")
        guard editorPaint == nil, state.outcome == nil, state.map.contains(hex), UserSettings.longTapMove, let u = selectedUnit else { return }
        if hex == u.coord { return }
        pendingMove = nil; paradropOverlay = nil; swapOverlayTile = nil; roadOverlay = nil; unitIconsTile = nil   // removeUnitActionOverlay
        battleTarget = hex   // selectedTile
        infoTile = hex   // selectedTile: the TileInfoTable, empty on an unexplored tile (GameView)
        guard isMyTurn, !isProcessing, !player.isSpectator else { refresh(full: false); return }   // `if (!worldScreen.canChangeState) return`
        if swapMode {
            // "If we are in unit-swapping mode and didn't find a swap partner, we don't want to move or attack"
            if state.canUnitSwapTo(u, hex) { swapMoveUnit(u, to: hex) } else { refresh(full: false) }
            return
        }
        // `unitView.canAttack() && attackableTile != null`: `attackable` holds exactly those targets. The attack is
        // tryMovePreparingAttack + attackOrNuke without the BattleTable button's clearUndoCheckpoints. An aircraft never
        // asks about the Air Sweep here: attackOrNuke strikes the unit or city (a sweeping one with its Air Sweep
        // strength, still preparing the sweep afterwards) or detonates a nuke.
        if attackable.contains(hex) {
            if u.def.isAir {
                if state.unitHasUnique(u, "Nuclear weapon of Strength []") {
                    Audio.shared.playAttack(u.def)
                    scene.nukeAnimation = hex
                    state.airStrike(unitId: u.id, target: hex); refresh()
                } else { performAirStrike(u, hex, clearsUndo: false) }
            } else { performAttack(u, hex, clearsUndo: false) }
            return
        }
        // Unciv TargetHelper.getAttackableEnemies: an aircraft preparing an Air Sweep (that canAttack) finds every other
        // tile in its range attackable; with no enemy combatant there movePreparingAttack is false and the press ends.
        if u.def.isAir, sweepMode, u.movementLeft > 0, u.attacksThisTurn < 1 + state.extraAttacks(of: u),
           u.coord.distance(to: hex) <= state.airRange(u) { refresh(full: false); return }
        // canReach: canParadropOn while preparing a paradrop, the landing spots of an air unit, the path finder otherwise
        if paradropMode { if state.paradropTargets(u).contains(hex) { paradropSelected(to: hex) } else { refresh(full: false) }; return }
        if u.def.isAir { if state.rebaseTargets(for: u).contains(hex) { rebaseMove(u, to: hex) } else { refresh(full: false) }; return }
        if state.canReach(u, hex) { performMove(u, to: hex); return }
        refresh(full: false)
    }

    /// Unciv WorldMapHolder.moveUnitToTargetTile for an air unit (its Move here button, a long press): the tutorial task,
    /// the undo checkpoint, the flight - a dud when it gets nowhere - then the whoosh, the unit reselected while it can
    /// still move, the overlays closed, and with Auto Unit Cycle the next unit once it cannot.
    private func rebaseMove(_ u: Unit, to hex: HexCoord) {
        pendingMove = nil; unitIconsTile = nil
        completeTask("air")   // Unciv markUnitMoveTutorialComplete: "Move an air unit"
        let from = u.coord
        let exploredBefore = state.player.explored.count
        rememberForUndo()
        state.rebase(unitId: u.id, to: hex)
        guard let moved = state.unit(u.id), moved.coord != from else { refresh(); return }
        Audio.shared.play("whoosh")
        if state.player.explored.count > exploredBefore { clearUndo() }   // Unciv Tile.setExplored clears the undo checkpoints
        if moved.movementLeft > 0 { selectedUnitId = moved.id; selectedCityId = nil }
        refresh()
        if UserSettings.autoUnitCycle && moved.movementLeft <= 0 { switchToNextUnit() }
    }

    /// Unciv WorldMapHolder.moveUnitToTargetTile: the tutorial task, getTileToMoveToThisTurn - a tile the unit has no way
    /// to (UnreachableDestinationException) leaves everything as it was, the Move here button up and no undo checkpoint -
    /// then the checkpoint and the move, and the sound and the reselection only when the unit actually got somewhere,
    /// since a move that cannot get any nearer is a dud that just drops the badge.
    private func performMove(_ mover: Unit, to hex: HexCoord, singleTap: Bool = false) {
        let traceFrom = mover.coord, traceMP = mover.movementLeft
        let traceStop = InputTrace.on ? state.tileToMoveToThisTurn(mover, hex) : nil
        defer {
            if InputTrace.on {
                let after = state.unit(mover.id)
                InputTrace.log("MOVE \(mover.name)#\(mover.id) \(InputTrace.hex(traceFrom))->\(InputTrace.hex(hex)) mp=\(traceMP) stopThisTurn=\(traceStop.map(InputTrace.hex) ?? "nil") => now at \(after.map { InputTrace.hex($0.coord) } ?? "gone") mpLeft=\(after?.movementLeft ?? -1) order=\(after.map { "\($0.order)" } ?? "-") arrived=\(after?.coord == hex)")
            }
        }
        let from = mover.coord
        let exploredBefore = state.player.explored.count
        // Unciv addTileOverlaysWithUnitMovement: the single-tap branch is a bare tryHeadTowards - UnitMovement.headTowards,
        // getTileToMoveToThisTurn then moveToTile, which leaves an Explore or move order in place (only
        // moveUnitToTargetTile drops it and sets a new one) - then selectUnit. No tutorial task, no undo checkpoint.
        if singleTap {
            pendingMove = nil; unitIconsTile = nil   // removeUnitActionOverlay; the single-tap branch never adds overlays
            state.headTowards(mover.id, hex)
            if state.player.explored.count > exploredBefore { clearUndo() }   // Unciv Tile.setExplored clears the undo checkpoints
            selectedUnitId = mover.id; selectedCityId = nil   // Unciv: keep moved unit selected
            refresh()
            return
        }
        completeTask(mover.def.isAir ? "air" : "move")   // Unciv moveUnitToTargetTile: markUnitMoveTutorialComplete
        // Unciv moveUnitToTargetTile (WorldMapHolder.kt:294-311): getTileToMoveToThisTurn comes first, and its
        // UnreachableDestinationException ("can't move here") returns before recordUndoCheckpoint and before any
        // removeUnitActionOverlay - the button stays up, the undo checkpoint is the one there was (paradropSelected alike).
        // The tile was reachable when the tap asked getShortestPath; this is the rare case of the board changing since.
        guard let stop = state.tileToMoveToThisTurn(mover, hex) else { refresh(full: false); return }
        rememberForUndo()   // worldScreen.recordUndoCheckpoint()
        pendingMove = nil; unitIconsTile = nil   // removeUnitActionOverlay - on a dud as well as once done
        // Unciv WorldMapHolder.moveUnitToTargetTile hands the path it walked to animateMovement; ours is read
        // before the move, because afterwards the unit is already standing at the far end of it.
        // Unciv moveUnitToTargetTile hands animateMovement getDistanceToTiles().getPathToTile(tileToMoveToThisTurn):
        // every hex crossed this turn. getShortestPath returns only the tile each TURN ends on, so animating along
        // that made a unit with two movement points teleport over the hex in between instead of walking it.
        var intended: [HexCoord] = []
        if !epochsAutoplay { intended = state.turnPaths(mover).path(to: stop) }
        _ = state.playerMove(mover.id, to: hex)
        guard let moved = state.unit(mover.id), moved.coord != from else { refresh(); return }
        // The unit may have stopped short of the tile that was asked for; walk only as far as it actually got.
        if let end = intended.firstIndex(of: moved.coord) {
            let path = Array(intended[...end])
            scene.moveAnimations = [(unitId: moved.id, from: from, path: path)]
            // Unciv: an escorting pair walks together
            if state.isEscorting(moved), let other = state.otherEscortUnit(moved) { scene.moveAnimations.append((unitId: other.id, from: from, path: path)) }
        }
        Audio.shared.play("whoosh")
        if state.player.explored.count > exploredBefore { clearUndo() }   // Unciv Tile.setExplored clears the undo checkpoints
        // Unciv: the unit that moved stays selected while it can still do something.
        if moved.movementLeft > 0 { selectedUnitId = moved.id; selectedCityId = nil }
        refresh()
        if UserSettings.autoUnitCycle && moved.movementLeft == 0 { switchToNextUnit() }   // Unciv WorldMapHolder.moveUnitToTargetTile
    }

    /// Unciv Automate action: unit.automated = true, then UnitAutomation.automateUnitMoves (workers use the worker automation)
    func automateSelected() {
        guard !isProcessing, let u = selectedUnit else { return }
        state.setAutomated(unitId: u.id)   // `unit.automated = true` - the action is left as it is
        if let fresh = state.unit(u.id) { if fresh.def.isWorker { AI(state: state, civId: state.playerId).actWorker(fresh) } else { state.automateUnitMoves(fresh.id) } }
        refresh()
    }
    // Unciv CityScreen.canChangeState: nothing on the screen of a city we do not own can be changed.
    func toggleRaze() { guard isMyTurn, let c = selectedCity, c.civId == state.playerId else { return }; state.setRazing(cityId: c.id, !c.razing); refresh(full: false) }
    func annexSelected() { guard isMyTurn, let c = selectedCity, c.civId == state.playerId else { return }; state.annex(cityId: c.id); refresh(full: false) }
    func puppetSelected() { guard isMyTurn, let c = selectedCity, c.civId == state.playerId else { return }; state.puppet(cityId: c.id); refresh(full: false) }
    /// Unciv CityScreen.askToBuyTile's Yes: tryBuyTile, then the Coin sound and the city screen again with nextTileToOwn preselected
    func buyTile(_ c: HexCoord) {
        guard isMyTurn, let city = selectedCity, city.civId == state.playerId else { return }
        if state.buyTile(cityId: city.id, c) {
            Audio.shared.play("coin")
            if let updated = state.city(city.id) { cityTile = state.chooseNewTileToOwn(updated) }
        }
        refresh()
    }
    func toggleLock(_ c: HexCoord) { guard isMyTurn, let city = selectedCity, city.civId == state.playerId, !city.isPuppet else { return }; state.toggleLockedTile(cityId: city.id, c); completeTask("tiles"); refresh(full: false) }
    /// Unciv CityScreen.tileWorkedIconOnClick
    func toggleWorkedTile(_ c: HexCoord) { guard let city = selectedCity, isMyTurn, city.civId == state.playerId else { return }; state.toggleWorkedTile(cityId: city.id, c); completeTask("tiles"); refresh(full: false) }
    /// Unciv CityScreen.tileWorkedIconDoubleClick: work the tile if needed, then lock it
    func workAndLockTile(_ c: HexCoord) {
        guard let city = selectedCity, isMyTurn, city.civId == state.playerId else { return }
        if state.city(city.id)?.workedTiles.contains(c) != true { state.toggleWorkedTile(cityId: city.id, c) }
        if let now = state.city(city.id), now.workedTiles.contains(c), !now.lockedTiles.contains(c) { state.toggleLockedTile(cityId: city.id, c) }
        refresh(full: false)
    }

    /// Description of a tile for the info panel, as plain text (the map editor's tile panel).
    func tileDescription(_ c: HexCoord) -> [String] { tileDescriptionLines(c).map(\.text) }
    /// Unciv TileDescription.toMarkup: city (health) and, for our own city, CityConstructions.getProductionMarkup; terrain,
    /// features, resource (+amount / "Requires [tech]"), wonder, road, improvement, work in progress, the civilian then the
    /// military unit (never the air units), defence, impassable, fresh water. Each line carries the Civilopedia link its
    /// FormattedLine has (nil: none) - Terrain/, Resource/, the tech's makeLink, Improvement/, Unit/.
    /// `viewer`: TileDescription.toMarkup's viewingCiv - the world screen's tile table passes getGameViewConsideringForOfWar's
    /// civ (a spectator's selected civ); nil is our own.
    func tileDescriptionLines(_ c: HexCoord, viewer: Int? = nil) -> [(text: String, link: String?)] {
        guard let t = state.map[c] else { return [] }
        let viewerId = viewer ?? state.playerId
        let viewerCiv = state.civ(viewerId) ?? player
        var lines: [(text: String, link: String?)] = []
        let visible = state.visibleTiles(for: viewerId).contains(c)
        if let city = state.city(at: c) {
            lines.append((L(city.name) + (visible ? " (\(city.health))" : ""), nil))
            if city.civId == viewerId, let production = productionMarkup(city) { lines.append(production) }
        }
        lines.append((L(t.baseTerrain), "Terrain/\(t.baseTerrain)"))
        for f in t.features { lines.append((L(f), "Terrain/\(f)")) }
        if let r = t.resource, let rd = state.rs.resources[r], rd.revealedBy == nil || viewerCiv.techs.contains(rd.revealedBy!) {
            lines.append((rd.resourceType == "Strategic" ? "\(L(r)) (\(t.resourceAmount))" : L(r), "Resource/\(r)"))   // Unciv TileDescription: strategic "{resource} (amount)"
            if let tech = needsResearchTech(t, rd, civId: viewerId) { lines.append((L("Requires [\(tech)]"), "Technology/\(tech)")) }
        }
        if let nw = t.naturalWonder { lines.append((L(nw), "Terrain/\(nw)")) }
        if (t.roads || t.railroad) && !t.isCityCenter {
            let road = t.railroad ? "Railroad" : "Road"
            // Unciv: "[${roadStatus.name}]$pillageText" translated whole, so the "[improvement] (Pillaged!)" key finds its translation
            lines.append((L("[\(road)]" + (t.roadPillaged ? " (Pillaged!)" : "")), "Improvement/\(road)"))
        }
        // Unciv: "[$shownImprovement]$pillageText" - the fog's last seen improvement, but TileView.improvementIsPillaged is
        // the tile's live tile.improvementIsPillaged, with no visibility check
        if let imp = state.shownImprovement(c, for: viewerId) { lines.append((L("[\(imp)]" + (t.pillaged ? " (Pillaged!)" : "")), "Improvement/\(imp)")) }
        if let ip = t.improvementInProgress, visible { lines.append((L(ip) + (t.improvementTurnsLeft > 0 ? " - \(t.improvementTurnsLeft)⏳" : " (" + L("Under construction") + ")"), "Improvement/\(ip)")) }
        if visible {
            // Unciv TileView.civilianUnit, then TileView.militaryUnit - each only when the viewer can see it (a submarine
            // hidden from us, a unit "Invisible to others", is not listed); tile.airUnits are never listed
            let seen = state.visibleUnits(for: viewerId).filter { $0.coord == c && !$0.def.isAir }
            if let u = seen.first(where: { $0.isCivilian }) {
                lines.append((L(u.name) + " - " + L(state.civ(u.civId)?.nation ?? "?"), "Unit/\(u.name)"))
            }
            if let u = seen.first(where: { $0.isMilitary }) {
                lines.append((L(u.name) + (u.health < 100 ? "(\(u.health))" : "") + " - " + L(state.civ(u.civId)?.nation ?? "?"), "Unit/\(u.name)"))
            }
        }
        if t.defenceBonus != 0 { lines.append((L("[\(t.defenceBonus > 0 ? "+" : "")\(Int(t.defenceBonus * 100))%] to unit defence"), nil)) }
        if t.isImpassable { lines.append((L("Impassable"), nil)) }
        if t.isLand && state.hasFreshWater(t) { lines.append((L("Fresh water"), nil)) }
        return lines
    }
    /// Unciv TileDescription.addNeedsResearchLine: nothing when any of the resource's improvements (TileResource.getImprovements:
    /// improvement, improvedBy, then the ruleset's "Improves [] resource" improvements in its order) can be built here; else
    /// the cheapest unresearched techRequired among the improvements whose only problem, OutsideBorders aside, is MissingTech.
    private func needsResearchTech(_ t: Tile, _ rd: ResourceDef, civId: Int) -> String? {
        let set = state.rs.resourceImprovements[rd.name] ?? []
        var names: [String] = []
        if let i = rd.improvement { names.append(i) }
        for i in rd.improvedBy where !names.contains(i) { names.append(i) }
        for i in state.rs.improvementOrder where set.contains(i) && !names.contains(i) { names.append(i) }
        let imps = names.compactMap { state.rs.improvements[$0] }
        if imps.contains(where: { state.canBuildImprovement($0, on: t, civId: civId) }) { return nil }
        let researchable = imps.filter { imp in
            let problems = state.improvementBuildingProblems(imp, civId: civId, tile: t).filter { $0 != .outsideBorders }
            return !problems.isEmpty && problems.allSatisfy { $0 == .missingTech }
        }
        // minByOrNull { it.cost }: the first of the cheapest
        return researchable.compactMap { $0.techRequired.flatMap { state.rs.techs[$0] } }
            .filter { !(state.civ(civId)?.techs.contains($0.name) ?? false) }   // viewingCiv.isResearched, not the player's
            .min(by: { $0.cost < $1.cost })?.name
    }
    /// Unciv CityConstructions.getProductionMarkup: "{construction} - {turnsToConstruction}⏳", only the name for a perpetual
    /// construction (Gold, Science...), linked to its Wonder / Building / Unit entry; nothing while nothing is being built.
    private func productionMarkup(_ city: City) -> (text: String, link: String?)? {
        guard let p = city.currentProduction else {   // Unciv currentConstructionName(): a perpetual construction, or ""
            return city.convertProductionTo.isEmpty ? nil : (L(city.convertProductionTo), nil)
        }
        // Unciv turnsToConstruction: `ceil((workLeft - overflow) / productionForConstruction).toInt()` - a city making no
        // production divides by zero there, and the infinite quotient converts to Int.MAX_VALUE
        let turns = state.turnsToConstruction(p, in: city) ?? Int(Int32.max)
        let link: String
        switch p {
        case .unit(let n): link = "Unit/\(n)"
        case .building(let n): link = state.rs.buildings[n]?.isAnyWonder == true ? "Wonder/\(n)" : "Building/\(n)"
        }
        return (L(p.name) + " - \(turns)⏳", link)
    }

    func performAttackFromTable(_ u: Unit, _ hex: HexCoord, clearsUndo: Bool = true) { guard !isProcessing else { return }; performAttack(u, hex, clearsUndo: clearsUndo) }
    /// Unciv CityButton.onButtonClick: the first tap lowers the button (and selects our city when no unit that can
    /// still move is selected); a tap on the lowered button enters our city, or opens a known foreign city's info
    func tapCityButton(_ cityId: Int, isLowered: Bool) {
        guard let city = state.city(cityId) else { return }
        Audio.shared.play("click")
        var entered = false
        if isLowered {
            // Unciv CityButton.enterCityOrInfoPopup: the city screen when foreignCityView.tryGetCityView() is not null - a
            // spectator, the owner, a spy of ours set up there (ForeignCityView.spyIsSetUpAtCity: Spy.isSetUp()) or the
            // debug visible map - and isIteratingUnits, `tileView.getVisibleUnits().none { it == unitTable.selectedUnit }`:
            // any selected unit on the tile that we see (MapUnit.isVisibleTo), whatever its type, keeps us out
            let spyIsSetUp = player.spies.contains { $0.cityId == city.id && $0.alive && GameState.spySetUpActions.contains($0.action) }
            let canSeeCityData = player.isSpectator || city.civId == state.playerId || spyIsSetUp || UserSettings.debugVisibleMap
            let selectedOnTile = selectedUnit.map { u in
                u.coord == city.coord && (UserSettings.debugVisibleMap || u.civId == state.playerId || state.visibleUnits(for: state.playerId).contains { $0.id == u.id })
            } ?? false
            if canSeeCityData && !selectedOnTile {
                selectedUnitId = nil; selectedCityId = city.id; foreignCityTapped = nil; showCity = true
                entered = true
            } else if player.metCivs.contains(city.civId) {
                // enterCityOrInfoPopup → foreignCityInfoPopup (isKnownTo): diplomacy, or the religion / espionage info first -
                // espionageVisible = isEspionageEnabled && spyIsSetUpAtCity
                foreignCityTapped = nil
                diplomacyCiv = city.civId
                let espionageVisible = state.espionageEnabled && spyIsSetUp
                if state.religionEnabled || espionageVisible { foreignCityInfo = IdentifiedInt(value: city.id) } else { showDiplomacy = true }
            }
        } else {
            foreignCityTapped = city.coord   // moveButtonDown
            if (selectedUnit == nil || (selectedUnit?.movementLeft ?? 0) <= 0) && city.civId == state.playerId {
                selectedUnitId = nil; selectedCityId = city.id; showCity = false   // unitTable.citySelected
            }
        }
        refresh(full: false)
        // Unciv enterCityOrInfoPopup pushes the CityScreen and redraws nothing behind it: the world screen owes only the
        // selection this changed - its units and banners - when it is shown again
        if entered { worldUpdateBehindCityScreen = 1 }
    }
    /// Unciv CityScreen.exit: `game.popScreen()` - back to the world screen, `setCenterPosition(city, immediately = true)`
    /// (the city's tile selected, the city picked by tileSelected) and `bottomUnitTable.selectUnit()` - nothing selected;
    /// back to the overview when that opened it (`if (newScreen is WorldScreen)` guards both)
    func exitCityScreen() {
        let toWorld = overviewReturn?.screen != "city"
        let coord = selectedCity?.coord
        showCity = false
        selectedCityId = nil
        cityTile = nil
        if toWorld, let coord {
            setCenterPosition(coord, immediately: true)
            selectedSpyId = nil; selectedUnitId = nil; selectedCityId = nil; resetSelectUnitModes()
            refresh(full: false)
        }
    }
    /// Unciv UnitTable.citySelected -> CityPresenter.selectCity: the unit selection is cleared and the city selected (its
    /// strength and bombard strength); selecting the same city again changes nothing - only a tap on the lowered
    /// CityButton (tapCityButton) enters the city. The caller refreshes.
    func selectCityOnMap(_ city: City) {
        selectedUnitId = nil; selectedCityId = city.id; showCity = false
    }
    func performCityBombard(_ city: City, _ hex: HexCoord) {
        guard !isProcessing else { return }
        clearUndo()
        Audio.shared.play("bombard")   // Unciv CityCombatant.getAttackSound()
        battleTarget = nil
        // Unciv runs a city's bombardment through the same battleAnimation as a unit's attack: the city's centre
        // icon lunges (getMapActorsForCombatant), the target flashes and wears the damage figure. No unit id.
        let defenderId = state.units(at: hex).first { $0.civId != city.civId }?.id
        let defenderIsAir = defenderId.flatMap { state.unit($0)?.def.isAir } ?? false
        let defenderBefore = defenderId.flatMap { state.unit($0)?.health } ?? state.city(at: hex)?.health ?? 0
        state.cityBombard(cityId: city.id, target: hex)
        let defenderAfter = defenderId.flatMap { state.unit($0)?.health } ?? state.city(at: hex)?.health ?? 0
        scene.battleAnimation = (attackerId: -1, attacker: city.coord, defender: hex,
                                 toAttacker: 0, toDefender: max(0, defenderBefore - defenderAfter),
                                 defenderId: defenderId, attackerIsAir: false, defenderIsAir: defenderIsAir, hideDefenderDamage: false)
        refresh()
    }
    func bombardBattleTarget() { guard !isProcessing, selectedUnit == nil, let c = selectedCity, let t = battleTarget, attackable.contains(t) else { return }; performCityBombard(c, t) }
    /// Unciv BattleTable.onAttackButtonClicked / WorldMapHolder.onTileRightClicked: the AttackableTile getAttackableEnemies
    /// finds for the target, MapUnitView.tryMovePreparingAttack (tryHealPillage = false) - move to the tile to attack from,
    /// set up a siege unit - and only when an attack is still possible the sound and attackOrNuke. Only the button
    /// (`clearsUndo`) calls worldScreen.clearUndoCheckpoints, right after the move and before the can-still-attack return.
    private func performAttack(_ u0: Unit, _ hex: HexCoord, clearsUndo: Bool) {
        guard let at = state.attackableEnemies(u0, distanceToTiles: state.distanceToTiles(u0)).first(where: { $0.tileToAttack == hex }) else { return }
        let canStillAttack = state.movePreparingAttack(u0.id, at)
        if clearsUndo { clearUndo() }
        guard canStillAttack, let u = state.unit(u0.id) else { refresh(); return }
        GameEvents.post(.unitAttacked(unit: u.name))
        attackWithAnimation(u, hex) { state.attack(unitId: u.id, at) }
    }
    /// Unciv BattleTable.onAttackButtonClicked / WorldMapHolder.onTileRightClicked for an aircraft that is no nuke: it
    /// attacks from its own tile, so MapUnitView.tryMovePreparingAttack moves nothing and an attack is still possible.
    /// Only the button (`clearsUndo`) calls worldScreen.clearUndoCheckpoints; then the attack sound, attackOrNuke
    /// (Battle.attack) and battleAnimationDeferred. A unit preparing an Air Sweep (`sweepMode` - only the long press
    /// strikes then, the table shows simulateAirsweep) attacks with BattleDamage.getAttackModifiers' "[]% Strength when
    /// performing Air Sweep", and its action stays AirSweep: Battle.attack never clears it.
    func performAirStrike(_ u: Unit, _ hex: HexCoord, clearsUndo: Bool) {
        guard !isProcessing else { return }
        if clearsUndo { clearUndo() }
        attackWithAnimation(u, hex) {
            if sweepMode { state.airSweepingUnitId = u.id }   // Unciv MapUnit.isPreparingAirSweep()
            defer { state.airSweepingUnitId = nil }
            return state.airStrike(unitId: u.id, target: hex)
        }
    }
    /// Unciv onAttackButtonClicked / onTileRightClicked once an attack is still possible: the attacker's sound, the attack,
    /// then worldScreen.battleAnimationDeferred with the damage each side took.
    private func attackWithAnimation(_ u: Unit, _ hex: HexCoord, _ attack: () -> String) {
        Audio.shared.playAttack(u.def)
        // Unciv BattleTableHelpers.battleAnimation is handed the damage each side took; ours is the health each
        // side lost, read either side of the attack, so a unit that dies counts the whole of what it had left.
        // The defender is Battle.getMapCombatantOfTile's: the city on its centre, else the military unit, else the civilian.
        let defenderId: Int?
        if case .unit(let id)? = state.getMapCombatantOfTile(hex) { defenderId = id } else { defenderId = nil }
        let defenderIsAir = defenderId.flatMap { state.unit($0)?.def.isAir } ?? false
        let defenderBefore = defenderId.flatMap { state.unit($0)?.health } ?? state.city(at: hex)?.health ?? 0
        let attackerBefore = u.health
        _ = attack()
        let defenderAfter = defenderId.flatMap { state.unit($0)?.health } ?? state.city(at: hex)?.health ?? 0
        let attackerAfter = state.unit(u.id)?.health ?? 0
        scene.battleAnimation = (attackerId: u.id, attacker: u.coord, defender: hex,
                                 toAttacker: max(0, attackerBefore - attackerAfter),
                                 toDefender: max(0, defenderBefore - defenderAfter),
                                 defenderId: defenderId, attackerIsAir: u.def.isAir, defenderIsAir: defenderIsAir,
                                 // Unciv: no defender figure when it was defeated and the attacker moved onto its tile
                                 hideDefenderDamage: (defenderId.map { state.unit($0) == nil } ?? (state.city(at: hex)?.civId == u.civId)) && state.unit(u.id)?.coord == hex)
        refresh()
        // Unciv BattleTable.onAttackButtonClicked leaves the selection alone
    }

    /// Unciv TileView.getCombatant: nothing on a tile we have not explored; on a city centre the city (seen now or not),
    /// else the tile's military unit when it isVisibleTo us, else its civilian when it is - never an aircraft, and never
    /// an undetected submarine, even when something else on its tile can be seen.
    func visibleCombatant(at hex: HexCoord) -> Combatant? {
        guard player.explored.contains(hex) else { return nil }
        if let c = state.city(at: hex) { return .city(c.id) }
        let seen = state.visibleUnits(for: state.playerId).filter { $0.coord == hex && !$0.def.isAir }
        guard let u = seen.first(where: { $0.isMilitary }) ?? seen.first else { return nil }
        return .unit(u.id)
    }
    /// Unciv BattleTable.tryGetDefenderAtTile(includeFriendly = false): the tile's combatant, when it is not ours.
    func foreignCombatantVisible(at hex: HexCoord) -> Bool {
        guard let c = visibleCombatant(at: hex) else { return false }
        return state.cCivId(c) != state.playerId
    }
    /// Unciv BattleTable.update with a selected unit: tryGetAttackerUnit (not a civilian, no "Cannot attack"), then a nuke
    /// against any other tile, an Air Sweep against any tile, anything else against a foreign combatant.
    func unitBattleTableShown(_ u: Unit, _ t: HexCoord) -> Bool {
        guard u.isMilitary, !u.def.cannotAttack, !state.unitHasUnique(u, "Cannot attack") else { return false }
        if state.unitHasUnique(u, "Nuclear weapon of Strength []") { return t != u.coord }
        if u.def.isAir && sweepMode { return true }
        return foreignCombatantVisible(at: t)
    }
    /// Unciv BattleTable.update with a selected city: a foreign combatant that is not a city
    func cityBattleTableShown(_ t: HexCoord) -> Bool { foreignCombatantVisible(at: t) && state.city(at: t) == nil }

    var selectedSpy: Spy? { selectedSpyId.flatMap { id in player.spies.first { $0.id == id } } }
    /// Unciv EspionageOverviewScreen "Move" button: show the spy in the unit table and wait for a city tap.
    /// Unciv MoveSpyOverlayButtonData: the city on the tile when the spy may move there
    func spyOverlayCity(_ hex: HexCoord) -> City? {
        guard let spy = selectedSpy, let c = state.city(at: hex), state.spyCanMoveTo(spy, c, civId: state.playerId) else { return nil }
        return c
    }
    /// Unciv MoveSpyOverlayButtonData.onActivation: move the spy (or give up), open the espionage overview either way, drop
    /// the overlay and the selected tile, deselect the spy
    private func pressMoveSpyButton(_ spyId: Int, at hex: HexCoord) {
        if isMyTurn, !player.isSpectator, let c = spyOverlayCity(hex) { state.assignSpy(civId: state.playerId, spyId: spyId, to: c.id) }
        spyOverlayTile = nil; infoTile = nil; battleTarget = nil; selectedSpyId = nil   // `worldMapHolder.selectedTile = null`
        showEspionage = true
        refresh(full: false)
    }
    /// Unciv EspionageOverviewScreen.onSpyRightClicked: `bottomUnitTable.selectSpy(spy)` and back to the map, which
    /// stays where it was
    func selectSpy(_ id: Int) {
        selectedUnitId = nil; selectedCityId = nil; battleTarget = nil; spyOverlayTile = nil
        selectedSpyId = id
        refresh(full: false)
    }
    /// Unciv PrevIdleButton (',' key).
    /// Unciv DeselectOrQuit (Escape / Back): clear every selection.
    func deselectAll() {
        selectedUnitId = nil; selectedCityId = nil; battleTarget = nil; infoTile = nil; selectedSpyId = nil; pendingMove = nil
        refresh(full: false)
    }
    /// Unciv WorldScreen init: `mapHolder.setCenterPosition(capital ?: the first unit's tile ?: HexCoord.Zero, immediately =
    /// true, selectUnit = !viewingCiv.isSpectator())` - the tile becomes the selected tile (the tile table, the battle table,
    /// the blinking highlight) and UnitTable.tileSelected picks what stands there on a fresh screen: our capital, else our
    /// military unit, else our civilian. A screen rebuilt for the same game and viewer (the next turn, an undo, the latest
    /// online state) then restores the old scroll and zoom, so only a fresh one (a load, a hot-seat hand-over) moves the camera.
    func selectTurnStartTile(centerCamera: Bool) {
        let me = state.playerId
        let target = state.capital(of: me)?.coord ?? state.units(of: me).first?.coord ?? HexCoord.fromOffset(col: state.map.width / 2, row: state.map.height / 2)
        selectedUnitId = nil; selectedCityId = nil; selectedSpyId = nil
        guard state.map.contains(target) else { refresh(full: false); return }   // setCenterPosition: no tile group, nothing happens
        // a fresh screen's map starts elsewhere, so its scrollTo always moves and blinks - even onto where the camera stood
        if !centerCamera || !scene.center(on: target, animated: false) { scene.blinkTile(target) }
        battleTarget = target; infoTile = target
        if !player.isSpectator { tileSelected(target) }
        refresh(full: false)
    }

    /// Unciv WorldMapHolder.setCenterPosition(vector, immediately, selectUnit, forceSelectUnit): the tile becomes the
    /// selected tile first - the TileInfoTable shows it, the BattleTable weighs the selected unit or city against it, it
    /// carries the white highlight - and with selectUnit, or a unit to force, UnitTable.tileSelected picks what stands
    /// there (the forced unit when there is one); then the map scrolls there (at once when `immediately`) and the tile
    /// blinks. `false` when the tile is not on the map, or when the map is already there (nothing scrolls or blinks, the
    /// tile is selected all the same). The caller refreshes (`worldScreen.shouldUpdate = true`).
    @discardableResult
    func setCenterPosition(_ hex: HexCoord, immediately: Bool = false, selectUnit: Bool = true, forceSelectUnit: Int? = nil) -> Bool {
        guard state.map.contains(hex) else { return false }   // `tileGroups.values.firstOrNull { .. } ?: return false`
        battleTarget = hex; infoTile = hex
        if selectUnit || forceSelectUnit != nil { tileSelected(hex, forceSelectUnit: forceSelectUnit) }
        return scene.center(on: hex, animated: !immediately)
    }
    /// Unciv KeyboardBinding.ViewCapitalCity: `if (capital != null && !mapHolder.setCenterPosition(capital.location))
    /// game.pushScreen { CityScreen(capital) }` - the map goes to the capital, selecting it; already there, the city
    /// screen opens.
    func viewCapitalCity() {
        guard let c = state.capital(of: state.playerId) else { return }
        if !setCenterPosition(c.coord) { selectedUnitId = nil; selectedCityId = c.id; showCity = true }
        refresh(full: false)
    }

    /// Unciv UnitTable.selectUnit (WorldScreen.switchToNextUnit): UnitPresenter.selectUnit's resets apply even when the
    /// unit was already the selected one. It moves no map - the callers that show the unit go through setCenterPosition.
    func select(unitId: Int) { InputTrace.log("select unit #\(unitId) \(state.unit(unitId)?.name ?? "")"); unitActionPage = 0; pendingMove = nil; paradropOverlay = nil; selectedSpyId = nil; selectedUnitId = unitId; resetSelectUnitModes(); selectedCityId = nil; refresh(full: false) }

    // MARK: unit actions
    /// The settler whose founding waits on "Break promise", and the leaders it would break the promise to. Unciv's
    /// ConfirmPopup runs the `foundAction` closure, which captured that settler - not whichever unit Auto Unit Cycle
    /// selected once the Found city press went through activateAction.
    @Published var confirmBreakPromise: (unitId: Int, names: String)? = nil
    @Published var confirmDisband: String? = nil        // Unciv "Disband this unit for [n] gold?" / "Do you really want to disband this unit?"
    /// Unciv UnitActionsFromUniques.getLeadersWePromisedNotToSettleNear: every known major civ we are not at war with
    /// whose diplomacy manager toward us holds AgreedToNotSettleNearUs (agreeToDemand sets it on the demander's side)
    /// and that has a city within 6 tiles of the spot. The leaders' display names go into a HashSet<String>, which
    /// joinToString walks in its bucket order.
    func civsPromisedNotToSettleNear(_ coord: HexCoord) -> [String] {
        var names: [String] = []
        for other in state.knownCivs(state.playerId) where other.isMajor && !state.areAtWar(state.playerId, other.id) {
            guard state.hasFlag(other.id, state.playerId, "AgreedToNotSettleNearUs") else { continue }
            guard state.cities(of: other.id).contains(where: { $0.coord.distance(to: coord) <= 6 }) else { continue }
            let name = L(LeaderIntroView.displayName(other)) + LeaderIntroView.suffix(other, state)   // Civilization.getLeaderDisplayName
            if !names.contains(name) { names.append(name) }
        }
        return javaHashMapOrder(names)
    }
    /// Unciv getFoundCityAction's action: found at once, or - when a promise would be broken - open the ConfirmPopup
    /// whose "Break promise" runs foundAction for this settler.
    func foundCity() {
        guard !isProcessing else { return }
        guard let u = selectedUnit else { return }
        let promised = civsPromisedNotToSettleNear(u.coord)
        if !promised.isEmpty && !epochsAutoplay { confirmBreakPromise = (u.id, promised.joined(separator: ", ")); return }
        foundCity(unitId: u.id)
    }
    /// Unciv getFoundCityAction's foundAction: the captured settler founds the city on its tile.
    func foundCity(unitId: Int) {
        guard !isProcessing else { return }
        confirmBreakPromise = nil
        clearUndo()
        guard state.foundCity(with: unitId) != nil else { return }
        GameEvents.post(.cityFounded(turn: state.turn, cityCount: state.cities(of: state.playerId).count))
        Audio.shared.play("chimes")   // Unciv UnitActionsFromUniques getFoundCityAction: SoundPlayer.play(UncivSound.Chimes)
        // After a confirmed "Break promise" Unciv keeps the unit Auto Unit Cycle already moved on to.
        if selectedUnitId == unitId { selectedUnitId = nil }
        refresh()
    }
    /// Unciv UnitActionsTable.activateAction after the action ran: nothing more with Auto Unit Cycle off; otherwise the
    /// next unit when this one is gone, or when the type skips and the unit is not moving or has no movement left.
    func afterUnitAction(_ unitId: Int?, skipping: Bool) {
        guard UserSettings.autoUnitCycle, let id = unitId else { refresh(full: false); return }
        guard let u = state.unit(id), u.civId == state.playerId else { switchToNextUnit(); return }
        let isMoving: Bool = { if case .moveTo = u.order { return true }; return false }()
        if skipping && (!isMoving || u.movementLeft <= 0) { switchToNextUnit() } else { refresh(full: false) }
    }
    func order(_ o: UnitOrder) {
        guard !isProcessing, let u = selectedUnit else { return }
        state.setOrder(unitId: u.id, o)
        refresh()
        
    }
    /// Unciv UnitActions explore: `unit.action = Explore; if (unit.hasMovement()) UnitAutomation.automatedExplore(unit)` -
    /// this unit only
    func explore(_ unitId: Int) {
        guard isMyTurn, state.unit(unitId)?.civId == state.playerId else { return }
        state.setOrder(unitId: unitId, .explore)
        if (state.unit(unitId)?.movementLeft ?? 0) > 0 { state.automatedExplore(unitId) }
        refresh()
        
    }
    /// Unciv ImprovementPickerScreen "Pick now!" on a queueable row: the removal first, then the improvement
    func orderQueued(_ first: String, then second: String) {
        guard !isProcessing, let u = selectedUnit else { return }
        state.setOrderWithQueuedImprovement(unitId: u.id, first: first, then: second)
        refresh()
        
    }
    /// Unciv getBuildingImprovementsActions: `ImprovementPickerScreen(tile, unit) { if (autoUnitCycle) switchToNextUnit() }` -
    /// ImprovementPickerScreen.accept runs that onAccept for every pick but "Cancel improvement order", after the
    /// order went in, and the screen closes.
    func improvementPicked() {
        showImprovementPicker = false
        if UserSettings.autoUnitCycle { switchToNextUnit() }
    }
    /// Unciv "Cancel improvement order": the queue is cleared and the worker stays selected
    func cancelImprovementOrder() {
        guard !isProcessing, let u = selectedUnit else { return }
        state.stopWorkingOnImprovement(at: u.coord)
        refresh()
    }
    func skipUnit() {
        guard !isProcessing, let u = selectedUnit, let i = state.unitIndex(u.id) else { return }
        state.units[i].due.toggle()   // Unciv UnitActions.addSkipAction
        if !state.units[i].due && !UserSettings.autoUnitCycle { switchToNextUnit() }; refresh(full: false)   // Unciv addSkipAction
    }
    func disbandUnit() {
        guard !isProcessing, let u = selectedUnit, u.movementLeft > 0 else { return }   // Unciv: hasMovement
        if confirmDisband == nil && !epochsAutoplay {
            let refund = state.map[u.coord]?.ownerCivId == u.civId ? state.disbandGold(u.def, civId: u.civId) : 0
            confirmDisband = refund > 0 ? L("Disband this unit for [\(refund)] gold?") : L("Do you really want to disband this unit?")
            return
        }
        confirmDisband = nil
        // Unciv addDisbandAction's ConfirmPopup: unit.disband(); unit.civ.updateStatsForNextTurn() // less upkeep!;
        // setUpdateWorldOnNextRender(); if (autoUnitCycle) worldScreen.switchToNextUnit()
        state.disband(unitId: u.id)
        state.updateStatsForNextTurn(u.civId)
        refresh()
        // (under autoplay there was no popup: the press itself disbanded, and afterUnitAction moves on from the gone unit)
        if UserSettings.autoUnitCycle && !epochsAutoplay { switchToNextUnit() }
    }

    // MARK: city / tech
    /// Unciv CityConstructionsTable queue buttons: queue row i is entry i + 1 behind the current construction
    func removeQueued(_ index: Int) { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }; state.removeFromCombinedQueue(cityId: c.id, index: index + 1); tryReassignPopulation(c.id); refresh(full: false) }
    func demoteQueued(_ index: Int) { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }; state.lowerQueuePriority(cityId: c.id, index: index + 1); tryReassignPopulation(c.id); refresh(full: false) }
    func promoteQueued(_ index: Int) { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }; state.raiseQueuePriority(cityId: c.id, index: index + 1); tryReassignPopulation(c.id); refresh(full: false) }
    /// Unciv getLowerPriorityButton on queue entry 0
    func demoteCurrent() { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }; state.lowerQueuePriority(cityId: c.id, index: 0); tryReassignPopulation(c.id); refresh(full: false) }
    func clearCurrentProduction() { guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }; state.removeFromCombinedQueue(cityId: c.id, index: 0); tryReassignPopulation(c.id); refresh(full: false) }
    /// Unciv CityConstructionsTable.addConstructionToQueue
    func addToQueue(_ p: Production, top: Bool = false) {
        guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }
        Audio.shared.play(p.isUnit ? "promote" : "construction")
        completeTask("build")
        state.addToQueue(cityId: c.id, p, addToTop: top)
        GameEvents.post(.productionChosen(item: p.name, isUnit: p.isUnit))
        // Unciv addConstructionToQueue: the city is reassigned when the new entry became the current construction
        if state.city(c.id)?.currentProduction == p { tryReassignPopulation(c.id) }
        refresh(full: false)
    }
    /// Unciv CityView.tryReassignPopulation (resetLocked = false): run after every queue change from the city screen
    func tryReassignPopulation(_ cityId: Int) { state.assignWorkers(cityId: cityId, why: "tryReassignPopulation") }

    // MARK: undo
    private var undoSnapshot: Data? = nil
    @Published var canUndo = false
    func rememberForUndo() { undoSnapshot = state.undoCheckpoint(); canUndo = undoSnapshot != nil }
    func clearUndo() { undoSnapshot = nil; canUndo = false }
    func undo() {
        // Unciv's checkpoint shares the live game's neutralRoads (Civilization.clone), which its setTransients works on
        guard !isProcessing, let data = undoSnapshot, let restored = GameState.restoreUndoCheckpoint(data, sharing: state.neutralRoads) else { return }
        clearUndo()
        // Unciv UndoHandler restores a GameInfo.clone(), and City.clone SHARES unitShouldUseSavedPromotion and
        // unitToPromotions: the restored cities keep the maps as they are now, their records frozen on the units undone.
        state.freezeSavedUnitPromotions()
        for ci in restored.cities.indices {
            guard let now = state.city(restored.cities[ci].id) else { continue }
            restored.cities[ci].useDefaultPromotions = now.useDefaultPromotions
            restored.cities[ci].defaultPromotions = now.defaultPromotions
        }
        // Unciv UndoHandler.restoreCheckpoint -> UncivGame.loadGame: the rebuilt screen selects the capital's tile, the
        // unit that was selected is not selected again
        replaceState(restored)
    }
    /// Unciv CityScreenConstructionMenu actions run through here so the screen refreshes.
    func queueAction(_ body: (GameState) -> Void) { guard isMyTurn else { return }; body(state); if let c = selectedCity { tryReassignPopulation(c.id) }; refresh(full: false) }   // Unciv CityScreenConstructionMenu → tryReassignPopulation
    /// Debug tab "View entire map": explore everything for the player.
    func revealForDebug() { guard !isProcessing else { return }; if UserSettings.debugVisibleMap, let i = state.civIndex(state.playerId) { state.civs[i].explored = Set(state.map.tiles.map { $0.coord }); state.checkExploredRegionForWholeMap(i) } }
    /// Debug tab "Get all strategic resources": one improved source of every strategic resource next to the capital is not possible without terrain, so the
    /// counts are granted through a permanent temporary unique instead.
    func grantStrategicResourcesForDebug() {
        guard !isProcessing else { return }
        for r in state.rs.resources.values where r.resourceType == "Strategic" { state.addTemporaryUnique(Unique("Provides [100] [\(r.name)]"), turns: -1, civId: state.playerId, source: "Debug") }
        refresh()
    }
    /// Unciv CityScreenConstructionMenu's disable / enable entries: CivView.tryDisable/EnableCivConstruction (no state check)
    /// or CityView.tryDisable/EnableConstruction (canChangeState), then the popup's onButtonClicked -
    /// cityView.tryReassignPopulation() - as for every other entry of the menu
    func setConstructionDisabled(_ name: String, cityWide: Bool, _ disabled: Bool) {
        guard !isProcessing else { return }
        if cityWide { state.setCivConstructionDisabled(name, civId: state.playerId, disabled) }
        else if isMyTurn, let c = selectedCity, c.civId == state.playerId { state.setConstructionDisabled(name, cityId: c.id, disabled) }
        if isMyTurn, let c = selectedCity, c.civId == state.playerId { tryReassignPopulation(c.id) }
        refresh(full: false)
    }
    /// Unciv CityConstructionsTable.addConstructionToQueue for a PerpetualConstruction - a stat conversion or Idle's "Nothing"
    /// (ours keeps it in convertProductionTo, the queue's trailing entry): cannotAddConstructionToQueue (a full queue with
    /// the perpetual counted, a puppet, not buildable, this perpetual already queued), its sound, CityConstructions.addToQueue
    /// (an empty or idle queue starts it, a trailing perpetual is replaced, otherwise it goes last; the player set it), the
    /// reassignment when it became the current construction, and the "Pick construction" tutorial task.
    func setProductionConversion(_ stat: String) {
        guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }
        guard state.canAddPerpetualToQueue(stat, in: c), c.convertProductionTo != stat else { return }
        Audio.shared.play(["Gold": "coin", "Science": "paper", "Culture": "policy", "Faith": "choir"][stat] ?? "click")   // getConstructionSound
        state.addPerpetualToQueue(cityId: c.id, stat)   // `currentConstructionIsUserSet = true` - automation keeps a perpetual the player chose
        if state.city(c.id)?.currentProduction == nil { tryReassignPopulation(c.id) }   // constructionQueue.first() == construction.name
        completeTask("build")
        refresh(full: false)
    }
    /// Unciv TechPickerScreen.previousSelectedTech / selectedTech
    private var selectedTechInPicker: String? = nil
    func setResearch(_ tech: String) {
        guard !isProcessing else { return }
        let previousSelectedTech = selectedTechInPicker
        selectedTechInPicker = tech
        if state.settings.godMode && tech == previousSelectedTech { state.godModeAddTechnology(civId: state.playerId, tech: tech) }
        state.chooseResearch(civId: state.playerId, tech: tech)
        state.updateResearchProgress(civId: state.playerId)   // Unciv TechPickerScreen.tryExit
        GameEvents.post(.techChosen(tech))
        Audio.shared.play("paper")
        completeTask("tech")
        refresh(full: false)
    }
    /// Unciv TechPickerScreen.tryExit: techsToResearch = tempTechsToResearch (or the free tech), updateResearchProgress, close -
    /// on the screen's civInfo, the selected civ it was opened with (TechPickerScreen(worldScreen.selectedCiv))
    func confirmTechPicker(freeTech: String?, queue: [String]) {
        guard !isProcessing else { showTech = false; return }
        let civId = selectedCivId
        guard let i = state.civIndex(civId) else { return }
        if let t = freeTech {
            guard state.researchableTechs(for: state.civs[i]).contains(where: { $0.name == t }) else { return }
            state.claimFreeTech(civId: civId, tech: t)
        } else if let j = state.civIndex(civId) {
            state.civs[j].currentTech = queue.first
            state.civs[j].techQueue = Array(queue.dropFirst())
        }
        state.updateResearchProgress(civId: civId)
        if let t = freeTech ?? queue.first { GameEvents.post(.techQueued(t, free: freeTech != nil)) }
        completeTask("tech")   // the paper sound is the caller's click (TechScreen.tryExit)
        showTech = false
        refresh(full: false)
    }
    /// Unciv selectTechnology: in god mode selecting the same unresearched tech twice researches it
    func godModeAddTech(_ tech: String) { guard !isProcessing else { return }; state.godModeAddTechnology(civId: selectedCivId, tech: tech); refresh(full: false) }   // the screen's civInfo

    // MARK: expanded unit actions
    func setUseDefaultPromotions(_ on: Bool) { guard !isProcessing, let u = selectedUnit else { return }; state.setUseDefaultPromotions(unitId: u.id, on); refresh(full: false) }
    /// Unciv CityView.trySetUnitShouldUseSavedPromotion: sehir ekranindaki "Use default promotions" onay kutusu.
    func setCityUseDefaultPromotions(_ unitName: String, _ on: Bool) {
        guard isMyTurn, let c = selectedCity, c.civId == state.playerId, let ci = state.cityIndex(c.id) else { return }
        if on { state.cities[ci].useDefaultPromotions.insert(unitName) } else { state.cities[ci].useDefaultPromotions.remove(unitName) }
        refresh(full: false)
    }
    func promote(_ name: String) {
        guard !isProcessing else { showPromotions = false; return }
        guard let u = selectedUnit else { return }
        state.promote(unitId: u.id, name); Audio.shared.playRepeated("promote", count: 1); showPromotions = false; refresh(full: false)
        
    }
    /// Unciv PromotionPickerScreen.acceptPromotion: every promotion on the path, the picker staying open while more can be bought
    func promotePath(_ name: String, saveDefault: Bool = false) {
        guard isMyTurn, !player.isSpectator, let u = promotionUnit, u.hasMovement, u.attacksThisTurn == 0, let info = state.promotionPath(to: name, for: u), state.canPickPromotionPath(info, for: u) else { return }
        for p in info.path { state.promote(unitId: u.id, p) }
        Audio.shared.playRepeated("promote", count: min(2, info.path.count))
        // Unciv checkSaveUnitPromotion: the city owning the tile remembers the promotions the unit has after the pick
        if saveDefault, let nu = state.unit(u.id), let city = state.owningCity(nu.coord), let ci = state.cityIndex(city.id) {
            state.saveUnitPromotions(unitId: nu.id, cityIndex: ci)   // `unitToPromotions[name] = unit.promotions` - the live object, XP included
        }
        // Unciv acceptPromotion: the picker stays open while the unit canBePromoted
        showPromotions = state.unit(u.id).map { !state.availablePromotions(for: $0).isEmpty } ?? false
        refresh(full: false)
    }
    /// Unciv UpgradeUnitAction.action (`unit.upgrade.performUpgrade`): the unit the action was built for - the selected
    /// one on the world screen, the menu's own from the overview - and the map's selection is left alone. No sound and no
    /// toast here: the Upgrade sound is the button's (onActivation(unitAction.uncivSound), UnitUpgradeMenu.doUpgrade), and
    /// performUpgrade says nothing, not even when the new unit finds no place and the old one is put back.
    func upgradeUnit(_ unitId: Int, to chosen: UnitDef? = nil) {
        guard !isProcessing else { showUpgradeMenu = false; return }
        guard let u = state.unit(unitId), u.civId == state.playerId else { return }
        _ = state.upgradeUnit(u.id, to: chosen)
        showUpgradeMenu = false
        refresh(full: false)
    }
    /// Unciv UnitUpgradeMenu "Upgrade all [n] [unit]": every eligible unit of the menu's unit's type, gold permitting -
    /// silently, the menu having played the sound (doAllUpgrade).
    func upgradeAllLike(_ unitId: Int) {
        guard !isProcessing else { showUpgradeMenu = false; return }
        guard let u = state.unit(unitId), u.civId == state.playerId else { return }
        for other in state.allUpgradableUnits(like: u) { _ = state.upgradeUnit(other.id) }
        showUpgradeMenu = false
        refresh(full: false)
    }
    /// Unciv CityView.tryAddToQueueWithTile (from CityScreen.tileGroupOnClick while picking a tile)
    func addToQueueWithTile(_ p: Production, tile: HexCoord) {
        guard isMyTurn, let c = selectedCity, c.civId == state.playerId, !c.isPuppet else { return }
        state.addToQueueWithTile(cityId: c.id, p, tile: tile)
        if state.city(c.id)?.currentProduction == p { tryReassignPopulation(c.id) }
        refresh(full: false)
    }
    func pillageSelected() { guard !isProcessing, let u = selectedUnit else { return }; state.pillage(unitId: u.id); refresh() }
    @Published var confirmPillage: String? = nil   // Unciv ConfirmPopup "Are you sure you want to pillage this [x]?"
    /// Unciv: the Paradrop action is the unit's own (isPreparingParadrop). Reset while that unit is selected (its action
    /// button, the drop, selectUnit of the same unit) it takes the unit's Paradrop button with it; selecting something
    /// else leaves the button of the unit selected before on the map, as every unit action overlay stays
    /// (UnitActionsTable.activateAction: "We keep the unit action/selection overlay from the previous unit open").
    @Published var paradropMode = false { didSet { if !paradropMode, let po = paradropOverlay, po.unitId == selectedUnitId { paradropOverlay = nil } } }
    /// Unciv MoveHereOverlayButtonData for a unit preparing a paradrop: the tile carrying the Paradrop button (no turn
    /// count) and the unit it drops - the button belongs to that unit, not to the selection.
    @Published var paradropOverlay: (tile: HexCoord, unitId: Int)? = nil
    @Published var swapMode = false { didSet { if !swapMode { swapOverlayTile = nil } } }
    func swappableNeighbors(of u: Unit) -> [Unit] { state.units.filter { state.canSwap(u, with: $0) } }
    /// Unciv WorldMapHolder.swapMoveUnitToTargetTile: swap (keeping an escort), drop explore or a move order, the swap
    /// sound, reselect the unit while it can still move, close the overlay. It records no undo checkpoint (only
    /// moveUnitToTargetTile does), but a tile explored on the way clears it as always (Tile.setExplored).
    func swapMoveUnit(_ u: Unit, to hex: HexCoord) {
        guard !isProcessing else { return }
        completeTask("move")   // Unciv markUnitMoveTutorialComplete
        let exploredBefore = state.player.explored.count
        state.swapMoveToTileKeepingEscort(u.id, hex)
        if state.player.explored.count > exploredBefore { clearUndo() }
        if let i = state.unitIndex(u.id) {
            switch state.units[i].order { case .explore, .moveTo: state.units[i].order = .none; default: break }
        }
        Audio.shared.play("swap")
        if state.unit(u.id)?.hasMovement == true { swapMode = false }   // selectUnit(selectedUnitView)
        swapOverlayTile = nil; unitIconsTile = nil   // removeUnitActionOverlay
        refresh()
    }
    /// Unciv ConnectRoadOverlayButtonData.connectRoadToTargetTile: the order, a first automation step, the wagon sound,
    /// the overlay closed and the mode ended
    func pressConnectRoad(_ u: Unit, to hex: HexCoord) {
        guard !isProcessing else { return }
        roadOverlay = nil; unitIconsTile = nil   // removeUnitActionOverlay
        connectRoad(to: hex)
        Audio.shared.play("wagon")
        connectRoadMode = false
        refresh()
    }
    /// Unciv WorldMapHolder.moveUnitToTargetTile for a unit preparing a paradrop (the Paradrop button, or a long press):
    /// the tutorial task, getTileToMoveToThisTurn (unreachable: nothing happens, the overlays stay), the undo checkpoint,
    /// the drop - a drop that gets nowhere is a dud that only closes the overlays, and the Paradrop action stays on;
    /// otherwise moveToTile cleared it, the Whoosh sound, a unit that landed short of the target is given a move order to
    /// it (trySetMoveToAction), the unit is selected while it can still move (selectUnit - also when our city or a
    /// civilian on the target was selected since), the overlays close, and with Auto Unit Cycle a unit left without
    /// movement hands over to the next one. `unit` is the unit whose button was pressed (the selected one by default).
    /// `singleTap` is addTileOverlaysWithUnitMovement's Single tap move branch instead: a bare tryHeadTowards and no
    /// overlay, then selectUnit, which resets the action.
    func paradropSelected(to c: HexCoord, singleTap: Bool = false, unit: Unit? = nil) {
        guard !isProcessing, let u = unit ?? selectedUnit else { return }
        let exploredBefore = state.player.explored.count
        if singleTap {
            paradropOverlay = nil; unitIconsTile = nil
            _ = state.paradrop(unitId: u.id, to: c)
            if state.player.explored.count > exploredBefore { clearUndo() }   // Unciv Tile.setExplored clears the undo checkpoints
            paradropMode = false
            refresh()
            return
        }
        completeTask("move")   // Unciv markUnitMoveTutorialComplete
        guard state.tileToMoveToThisTurn(u, c, preparingParadrop: true) != nil else { refresh(full: false); return }   // UnreachableDestinationException
        rememberForUndo()   // worldScreen.recordUndoCheckpoint()
        paradropOverlay = nil; unitIconsTile = nil   // removeUnitActionOverlay - on a dud as well as once done
        guard state.paradrop(unitId: u.id, to: c) else { refresh(); return }
        if state.player.explored.count > exploredBefore { clearUndo() }
        Audio.shared.play("whoosh")
        if selectedUnitId == u.id { paradropMode = false }
        if let i = state.unitIndex(u.id), state.units[i].coord != c { state.units[i].order = .moveTo(c) }
        if (state.unit(u.id)?.movementLeft ?? 0) > 0 { selectedUnitId = u.id; selectedCityId = nil }   // Unciv: `if (hasMovement()) selectUnit(unit)`
        refresh()
        if UserSettings.autoUnitCycle && (state.unit(u.id)?.movementLeft ?? 0) <= 0 { switchToNextUnit() }
    }
    func setUpSelected() { guard !isProcessing, let u = selectedUnit else { return }; state.setUp(unitId: u.id); Audio.shared.play("setup"); refresh(full: false) }
    func greatPersonAction(_ a: GameState.GreatPersonAction) {
        guard !isProcessing, let u = selectedUnit else { return }
        state.performGreatPersonAction(unitId: u.id, a); refresh()
    }
    func addSpaceshipPart() {
        guard !isProcessing, let u = selectedUnit else { return }
        state.addSpaceshipPart(unitId: u.id); selectedUnitId = nil
        // the part that completes the spaceship wins at once: refresh's WorldScreen.update victory check
        refresh()
    }
    func adopt(branch: String? = nil, policy: String? = nil) {
        guard isMyTurn, !player.isSpectator else { return }
        if state.adopt(civId: state.playerId, branch: branch, policy: policy) {
            GameEvents.post(.policyAdopted(item: policy ?? branch ?? "", isBranch: policy == nil))
            Audio.shared.play("policy"); refresh()
        }
    }
    // Religion
    /// Unciv ReligionPickerScreenCommon.setOKAction: the Choir sound on the button, then chooseBeliefs - no message
    func foundPantheon(_ b: String) { guard !isProcessing else { return }; if state.foundPantheon(civId: state.playerId, belief: b) { Audio.shared.play("choir") }; refresh(full: false) }
    /// Unciv UnitActionsReligion FoundReligion: ReligionManager.foundReligion(prophet) then the prophet is consumed;
    /// nothing is founded until the beliefs are chosen (NextTurnAction.FoundReligion opens the picker)
    func useProphetForFoundingReligion() {
        guard isMyTurn, let u = selectedUnit else { return }
        state.useProphetForFoundingReligion(unitId: u.id); refresh()
    }
    /// Unciv UnitActionsReligion EnhanceReligion: useProphetForEnhancingReligion then consume
    func useProphetForEnhancingReligion() {
        guard isMyTurn, let u = selectedUnit else { return }
        state.useProphetForEnhancingReligion(unitId: u.id); refresh()
    }
    /// Unciv ReligiousBeliefsPickerScreen (Choir on confirm): foundReligion(displayName, name) and chooseBeliefs
    func foundReligion(name: String, displayName: String? = nil, beliefs: [String]) {
        guard !isProcessing else { showFoundReligion = false; return }
        if state.completeFoundingReligion(civId: state.playerId, name: name, displayName: displayName, beliefs: beliefs) { Audio.shared.play("choir") }
        showFoundReligion = false; refresh()
    }
    func applyFreeBeliefs(_ beliefs: [String]) { guard !isProcessing else { showFreeBeliefs = false; return }; if state.applyFreeBeliefs(civId: state.playerId, beliefs: beliefs) { Audio.shared.play("choir") }; showFreeBeliefs = false; refresh() }
    func enhanceReligion(beliefs: [String]) {
        guard !isProcessing else { showEnhanceReligion = false; return }
        if state.completeEnhancingReligion(civId: state.playerId, beliefs: beliefs) { Audio.shared.play("choir") }
        showEnhanceReligion = false; refresh()
    }
    func spreadReligion() {
        guard !isProcessing else { return }
        guard let u = selectedUnit, let c = state.owningCity(u.coord).flatMap({ state.canSpread(u, at: $0.coord) ? $0 : nil }) else { return }
        state.spreadReligion(unitId: u.id, to: c.id); refresh()
    }
    func removeHeresy() {
        guard !isProcessing else { return }
        guard let u = selectedUnit, let c = state.owningCity(u.coord).flatMap({ state.canRemoveHeresy(u, at: $0.coord) ? $0 : nil }) else { return }
        state.removeHeresy(unitId: u.id, cityId: c.id); refresh()
    }
    /// Unciv BuyButtonFactory: a purchase with any stat the construction accepts.
    func buyWithStat(_ p: Production, stat: String) { _ = purchaseConstruction(p, stat: stat, queuePosition: nil) }
    /// Unciv BuyButtonFactory.purchaseConstruction: the stat's purchase sound, then CityConstructions.purchaseConstruction
    /// with the selected queue entry (nil = -1, "not from the queue"). False when nothing could be placed.
    func purchaseConstruction(_ p: Production, stat: String, queuePosition: Int?, tile: HexCoord? = nil) -> Bool {
        guard isMyTurn, let c = selectedCity, c.civId == state.playerId else { return false }
        // Unciv purchaseConstruction(tile): the chosen tile is marked before the building is bought
        if let t = tile, let imp = state.improvementToCreate(p), let ci = state.cityIndex(c.id) { state.cities[ci].reservedImprovementTile = t; state.cities[ci].reservedImprovement = imp }
        Audio.shared.play(["Gold": "coin", "Science": "chimes", "Culture": "paper", "Faith": "choir"][stat] ?? "click")   // Stat.purchaseSound
        let ok: Bool
        if stat == "Gold" { ok = state.purchase(cityId: c.id, p, queuePosition: queuePosition, fromList: queuePosition == nil, automatic: false) }   // CityConstructionsView: automatic = false
        else {
            switch p {
            case .unit(let n): ok = state.buyWithStat(cityId: c.id, unit: n, stat: stat, queuePosition: queuePosition)
            case .building(let n): ok = state.buyWithStat(cityId: c.id, building: n, stat: stat, queuePosition: queuePosition)
            }
        }
        if ok { GameEvents.post(.productionBought(item: p.name, isUnit: p.isUnit, stat: stat)) }
        refresh()
        return ok
    }
    // Espionage
    func assignSpy(_ spyId: Int, to cityId: Int?) { guard !isProcessing else { return }; state.assignSpy(civId: state.playerId, spyId: spyId, to: cityId); refresh(full: false) }
    /// Unciv EspionageOverviewScreen closeButton (KeyCharAndCode.BACK too): civInfo.cache.updateViewableTiles(), then
    /// game.popScreen() - a spy moved out of a set-up city stops showing its ring at once. The screen's other exits (a
    /// spy picking its city on the map, a location label) only pop, and Spy.moveTo touches no view.
    func closeEspionage() {
        state.visGen &+= 1   // the view includes the set-up spies' city rings (computeVisibleTiles), so the cached view is stale
        state.updateExploration(for: selectedCivId)   // the screen's civInfo: EspionageOverviewScreen(worldScreen.selectedCiv, ...)
        showEspionage = false
        refresh()
    }
    // Diplomacy
    /// Unciv: the AI answers a Declaration of Friendship with DiplomacyAutomation.wantsToSignDeclarationOfFriendship.
    func declareFriendship(_ other: Int) {
        guard !isProcessing else { return }
        let me = state.playerId
        guard let o = state.civ(other), !state.pendingOffers.contains(where: { $0.from == me && $0.to == other && $0.give.friendship && $0.want.friendship }) else { return }
        if o.isPlayer { state.addAlert(other, .DeclarationOfFriendship, "\(me)") }
        else { var offer = TradeOffer(id: state.newId(), from: me, to: other, turnCreated: state.turn); offer.give.friendship = true; offer.want.friendship = true; state.queueOffer(offer) }
        refresh(full: false)
    }
    func denounce(_ other: Int) { guard !isProcessing else { return }; state.denounce(state.playerId, other); refresh(full: false) }
    func demand(_ d: Demand, of other: Int) { guard !isProcessing else { return }; state.makeDemand(d, from: state.playerId, to: other); refresh(full: false) }
    func answerDemand(_ r: DemandRequest, accept: Bool) { guard !isProcessing else { return }; if accept { state.agreeToDemand(r.demand, from: r.from, by: r.to) } else { state.refuseDemand(r.demand, from: r.from, by: r.to) }; refresh(full: false) }
    func pledgeProtection(_ cs: Int) { guard !isProcessing else { return }; state.pledgeProtection(state.playerId, cs); refresh(full: false) }
    /// Unciv CityStateDiplomacyTable's Diplomatic Marriage button: `newCities = otherCiv.cities`, diplomaticMarriage, and then a
    /// DiplomaticMarriage popup per city - added by the button, so the AI's marriage (UseGoldAutomation, the player's under
    /// AutoPlay too) brings none.
    func marry(_ cs: Int) {
        guard !isProcessing else { return }
        let newCities = state.cities(of: cs).map { $0.id }
        state.marry(state.playerId, cs)
        for c in newCities { state.addAlert(state.playerId, .DiplomaticMarriage, "\(c)") }
        refresh()
    }
    func withdrawProtection(_ cs: Int) { guard !isProcessing else { return }; state.withdrawProtection(state.playerId, cs); refresh(full: false) }

    func makePeace(with civId: Int) {
        guard isMyTurn else { return }
        GameEvents.post(.peaceMade(turn: state.turn, withCityState: state.civ(civId)?.isCityState == true))
        // Unciv CityStateDiplomacyTable.getNegotiatePeaceCityStateButton: a peace-for-peace trade run through
        // TradeLogic.acceptTrade by the viewing civ (the button is disabled while DeclaredWar runs or the
        // city-state's known ally is at war with us)
        if state.civ(civId)?.isCityState == true {
            var o = TradeOffer(id: -1, from: civId, to: state.playerId, turnCreated: state.turn)
            o.give.peace = true; o.want.peace = true
            state.executeTrade(o)
            refresh(); return
        }
        // A major civilization's peace goes through the trade table (MajorCivDiplomacyTable Negotiate Peace)
        refresh()
    }
    func giftGold(to cs: Int, _ amount: Double) { guard !isProcessing else { return }; state.giftGold(from: state.playerId, to: cs, amount: amount); refresh(full: false) }
    func demandTribute(from cs: Int) { guard !isProcessing else { return }; state.demandTribute(from: state.playerId, cs); refresh(full: false) }
    func demandWorker(from cs: Int) { guard !isProcessing else { return }; state.tributeWorker(from: state.playerId, cs); refresh(full: false) }
    func giftImprovement(to cs: Int, at c: HexCoord, improvement: String) { guard !isProcessing else { return }; state.giftImprovement(from: state.playerId, to: cs, at: c, improvement: improvement); refresh() }

    // MARK: turn
    /// Unciv WorldScreen.nextTurn: `isPlayersTurn = false` (ours: isProcessing, which isMyTurn reads), then on a separate
    /// thread "so the user can explore their world while we're passing the turn": `originalGameInfo.clone()`,
    /// setTransients and `gameInfoClone.nextTurn(progressBar, true)`, the upload of an online game, and startNewScreenJob
    /// with the clone. The world screen keeps showing the original, unchanged, until then - the map can be panned, zoomed
    /// and tapped for what stands there, the screens opened to look, but nothing that changes the game is offered
    /// (canChangeState). Ours played the turn on the game itself, one civilization per main run-loop turn under a dark
    /// overlay that swallowed every touch for the seconds it took.
    ///
    /// The clone is the game encoded here, on the main thread (the screens read - and fill caches in - the original, so
    /// nothing else may read it meanwhile), and decoded on the turn's queue.
    func endTurn() { endTurn(automatingPlayer: false) }

    /// `automatingPlayer`: AutoPlay's turn - the multi-turn AutoPlay (NextTurnButton.update's "MultiturnAutoPlay" job) and
    /// "AutoPlay End Turn" (AutoPlayMenu.autoPlayEndTurn). Unciv runs `TurnManager(viewing civ).automateTurn()` -
    /// NextTurnAutomation.automateCivMoves, the whole AI, whatever the AutoPlay settings say - in
    /// AutoPlay.runAutoPlayJobInNewThread, on a thread of its own (`isPlayersTurn = false` meanwhile) and on the game
    /// itself, worldScreen.gameInfo, not on a clone; then worldScreen.nextTurn() clones that game and plays the turn on the
    /// clone. Ours does it on the turn's thread in the same order: the game itself - its caches as the turn and the screen
    /// left them, which the automation reads as Unciv's does - goes to the turn's thread, automated there (automatePlayer),
    /// and the clone is taken of it there; the world screen shows a copy of the game meanwhile (showWhileAutomating),
    /// decoded on that thread from the game encoded here. The main thread used to run the automation itself before Next
    /// Turn, frozen for as long as it took.
    private func endTurn(automatingPlayer automate: Bool) {
        InputTrace.log("NEXT TURN pressed (turn \(state.turn), processing=\(isProcessing))")
        // (Multiplayer.isMyTurn, not isMyTurn: "Retry Upload" plays the turn again while a failed upload holds isMyTurn false.)
        // Unciv NextTurnButton: disabled while an autosave is being written or the latest online state is loading.
        guard handoffTo == nil, !isProcessing, !waitingForAutosave, !loadingLatestState, state.outcome == nil, Multiplayer.isMyTurn(state) else { return }
        clearUndo()
        // the automated units' promotions come after AutoPlay's automation, on the turn's thread
        let promote = automate && autoPromote
        // Unciv's multi-turn AutoPlay counts the turn down before the clone's walk starts, so `isAutoPlaying()` holds
        // through the walk while turns are left (GameState.autoPlayGoesOn); autoPlayStep has counted it down already, and
        // "AutoPlay End Turn" calls stopAutoPlay first
        let goesOn = automate && isAutoPlaying && autoPlayTurnsLeft > 0
        if !automate { stageAutoPromotions() }
        Audio.shared.play("click")
        isProcessing = true
        // Unciv WorldScreen.nextTurn: `isPlayersTurn = false; shouldUpdate = true` - the old WorldScreen updates once more on
        // the original game, which drops a highlight drawn before the button was pressed
        requestNotificationsUpdate()
        // Unciv startNewScreenJob: the next turn arrives on a freshly built WorldScreen, so every
        // transient selection and pick-a-tile mode is gone by the time the player sees the map again.
        selectedUnitId = nil; selectedCityId = nil
        pendingMove = nil; battleTarget = nil; infoTile = nil; selectedSpyId = nil; foreignCityTapped = nil; unitIconsTile = nil; paradropOverlay = nil
        swapMode = false; paradropMode = false; connectRoadMode = false; sweepMode = false
        // Unciv NextTurnProgress: the bar on the button, filled as the civilizations are played
        turnProgress = 0; turnProgressMax = 0; turnProgressCiv = nil
        let original = state
        // Read here, once: what the turn's thread would otherwise read from the main thread's globals
        let bombard = UserSettings.citiesAutoBombardAtEndOfTurn
        let autosaveEvery = max(1, UserSettings.turnsBetweenAutosaves)
        HexCoord.wrapWidth = original.map.wrapX ? original.map.width : nil
        original.rs.buildLazyTables()
        L10n.ensureLoaded()
        guard let data = try? JSONEncoder().encode(original) else {
            // A game that cannot be encoded (a non-finite number somewhere) cannot be cloned: it is played in place, on
            // the main thread, as the turn always was before
            if automate { GameController.automatePlayer(original, promote: promote) }
            original.autoPlayGoesOn = goesOn
            let result = original.playWorldScreenNextTurn(citiesAutoBombard: bombard)
            original.autoPlayGoesOn = false
            turnPlayed(original, original: original, result: result, autosave: nil)
            return
        }
        let carry = original.nextTurnCloneCarry
        // compared on its way back (Unciv `game.gameInfo != originalGameInfo`); with AutoPlay also the game automated
        let originalRef = HandedOver(value: original)
        let background = BackgroundTime("NextTurn")
        turnBackgroundTime?.end()
        turnBackgroundTime = background
        let showsProgress = GameController.turnProgressShown
        // Unciv WorldScreen.nextTurnUpdateJob: `Concurrency.runOnNonDaemonThreadPool("NextTurn")` - one thread per turn (only
        // one runs at a time: isProcessing), with the stack the main thread gave the turn before (8 MB), which the walk's
        // deepest automation needs; a dispatch queue's 512 KB is not enough for it. A controller gone meanwhile (another
        // game, the main menu) takes nothing of the turn, and its background time ends here.
        let thread = Thread { [weak self] in
            // the game the world screen shows while the turn runs, and the encoded game the turn's clone is decoded from
            var shown = originalRef.value
            var cloneOf = (data: data, carry: carry)
            if automate {
                // Unciv AutoPlay.runAutoPlayJobInNewThread: automateTurn on the game itself - once the world screen shows
                // a copy of it, so that from here on nobody else reads it
                let copy: GameState
                do { copy = try GameState.nextTurnClone(of: data, carrying: carry) }
                catch { DispatchQueue.main.async { if let self { self.turnCouldNotStart(originalRef.value) } else { background.end() } }; return }
                let copyRef = HandedOver(value: copy)
                let handOver = AutomationHandOver()
                DispatchQueue.main.async {
                    handOver.taken = self?.showWhileAutomating(copyRef.value, insteadOf: originalRef.value) ?? false
                    if !handOver.taken { background.end() }
                    handOver.done.signal()
                }
                handOver.done.wait()
                guard handOver.taken else { return }   // another game is shown: the turn goes, its game untouched
                let game = originalRef.value
                GameController.automatePlayer(game, promote: promote)
                shown = copy
                // Unciv WorldScreen.nextTurn: `originalGameInfo.clone()` - of the game the automation has just played
                guard let automated = try? JSONEncoder().encode(game) else {
                    // played in place, as a game that cannot be encoded always is - on the main thread, given back to it
                    DispatchQueue.main.async { if let self { self.playAutomatedInPlace(originalRef.value, shown: copyRef.value, citiesAutoBombard: bombard, autoPlayGoesOn: goesOn) } else { background.end() } }
                    return
                }
                cloneOf = (automated, game.nextTurnCloneCarry)
            }
            let shownRef = HandedOver(value: shown)
            let clone: GameState
            // EVLOG (`--replay-human`): Unciv's clone and its setTransients print nothing (EvLog.muted), and the turn's events
            // are the clone's - the log follows the clone from here on
            if EvLog.on { EvLog.game = nil }
            do { clone = try GameState.nextTurnClone(of: cloneOf.data, carrying: cloneOf.carry) }
            catch { DispatchQueue.main.async { if let self { self.turnCouldNotStart(shownRef.value) } else { background.end() } }; return }
            clone.autoPlayGoesOn = goesOn
            // Unciv's clone shares the trades' offers with the game it was cloned from, which an online game shows again
            // when the upload fails (SharedTradeOffers)
            if clone.settings.isOnline { clone.sharedTradeOffers = SharedTradeOffers(of: clone) }
            var done = 0
            let result = clone.playWorldScreenNextTurn(citiesAutoBombard: bombard, walkLength: { n in
                // the civs walked, the wrap, and the next human's start
                guard showsProgress else { return }
                DispatchQueue.main.async { self?.turnProgressMax = n + 2 }
            }, progress: { step in
                done += 1
                guard showsProgress else { return }
                let civName: String?
                if case .played(let id) = step { civName = clone.civ(id)?.nation } else { civName = nil }   // read here: the clone is this thread's
                let count = done
                DispatchQueue.main.async { self?.turnStepped(civ: civName, done: count) }
            }, afterTransients: { if EvLog.on { EvLog.game = clone } })   // the clone's setTransients is muted, as PopupDump has it
            clone.autoPlayGoesOn = false   // the walk's alone: the world screen's game is not AutoPlay's turn
            // Unciv startNewScreenJob → WorldScreen.autoSave: the new turn's autosave is Autosaves.requestAutoSave's clone
            // serialised off the GL thread; ours is encoded now, while the clone is still nobody else's, and written once shown
            let autosave = clone.uncivTurns % autosaveEvery == 0 ? try? JSONEncoder().encode(clone) : nil
            let played = HandedOver(value: clone)   // from here on the main thread's
            DispatchQueue.main.async {
                if let self { self.turnPlayed(played.value, original: shownRef.value, result: result, autosave: autosave) } else { background.end() }
            }
        }
        thread.name = "NextTurn"
        thread.stackSize = TurnThread.stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
    }
    /// Unciv NextTurnProgress.increment: the civ being played and how far the walk has got.
    private func turnStepped(civ: String?, done: Int) {
        guard isProcessing else { return }
        turnProgressCiv = civ
        turnProgress = min(done, turnProgressMax)
    }
    /// The clone could not be decoded: nothing was played, the world screen stays on the turn it was on - AutoPlay's
    /// automation, when it ran, stays done (Unciv's ran on worldScreen.gameInfo).
    private func turnCouldNotStart(_ original: GameState) {
        endTurnBackgroundTask()
        guard state === original, isProcessing else { automatedGame = nil; return }
        restoreAutomatedGame()
        isProcessing = false
        turnProgress = 0; turnProgressMax = 0; turnProgressCiv = nil
        flash("Could not load game!")
        refresh()
    }
    /// The walk is over on the clone: an online game is uploaded before anything of the new turn is shown or saved.
    private func turnPlayed(_ clone: GameState, original: GameState, result: GameState.EndTurnResult, autosave: Data?) {
        guard isProcessing else { endTurnBackgroundTask(); return }
        turnProgressCiv = nil
        turnProgress = turnProgressMax
        if clone.settings.isOnline { Task { await self.uploadTurn(clone, original: original, result: result, autosave: autosave) }; return }
        turnArrived(clone, original: original, result: result, autosave: autosave)
    }
    /// Unciv WorldScreen.nextTurn, after the upload: `if (game.gameInfo != originalGameInfo) return` - "while this was
    /// turning we loaded another game" - the game the app shows (GameController.current's), not this world screen's own;
    /// then startNewScreenJob. (Every way to another game is closed while the turn runs; should one get through, its game
    /// stays and the turn goes, without touching the globals or the autosave of the game shown.)
    @discardableResult
    private func turnArrived(_ clone: GameState, original: GameState, result: GameState.EndTurnResult, autosave: Data?) -> Bool {
        guard state === original, GameController.current === self else {
            endTurnBackgroundTask()
            automatedGame = nil
            isProcessing = false
            turnProgress = 0; turnProgressMax = 0; turnProgressCiv = nil
            return false
        }
        showNextTurn(clone, result: result, autosave: autosave)
        return true
    }
    /// The turn's background time (BackgroundTime): a turn left running when the app is sent to the background finishes
    /// (and is saved) before the app is suspended - Unciv's NextTurn is a non-daemon thread.
    private var turnBackgroundTime: BackgroundTime? = nil
    private func endTurnBackgroundTask() { turnBackgroundTime?.end(); turnBackgroundTime = nil }
    /// `--bg-turn-selftest --no-progress`: the turn's thread sends no NextTurnProgress to the main thread, so ThreadSanitizer
    /// sees its accesses without the happens-before those dispatches add.
    static var turnProgressShown = true
    /// Unciv WorldScreen.waitingForAutosave: the new turn's autosave is still being written - only the Next Turn button
    /// (and the multi-turn AutoPlay) waits for it.
    @Published var waitingForAutosave = false

    /// Unciv WorldScreen.nextTurn, online: `onlineMultiplayer.updateGame(gameInfoClone)` (the upload, then
    /// updatePreview with its turn sound), tried again for as long as an AuthPopup raised by a MultiplayerAuthException
    /// succeeds; closing that popup ends the retrying with no exception, and the turn goes on as if uploaded - Unciv's
    /// own loop does that. Any other failure opens "Could not upload game! Reason: [..]" (with "Copy to clipboard"),
    /// sets failedUpload and returns before startNewScreenJob: the player stays on the turn they ended - the original,
    /// which the clone touched only through the trade offers they share (SharedTradeOffers: each one the clone counted
    /// down is a turn shorter) - it is not saved, and "Retry Upload" plays it again from there (NextTurnAction.RetryUpload
    /// → worldScreen.nextTurn()).
    private func uploadTurn(_ s: GameState, original: GameState, result: GameState.EndTurnResult, autosave: Data?) async {
        var retryUpload: Bool
        repeat {
            do {
                try await Multiplayer.upload(s)
                if let g = s.settings.gameId { MultiplayerStatus.shared.updatePreview(g, GamePreview(s)) }
                retryUpload = false
            } catch Multiplayer.MPError.auth {
                // true only if authentication succeeds, false when the popup is closed
                retryUpload = await requestAuthentication()
            } catch {
                endTurnBackgroundTask()
                isProcessing = false
                turnProgress = 0; turnProgressMax = 0; turnProgressCiv = nil
                uploadFailed = true   // Since we couldn't push the new game clone, then we need to try again
                uploadErrorPopup = L("Could not upload game! Reason: [\(error.localizedDescription)]")
                let source = automatedGame?.game ?? original   // the game the clone was cloned from
                restoreAutomatedGame()   // Unciv's automateTurn changed worldScreen.gameInfo, which Retry Upload clones again
                if let shared = s.sharedTradeOffers, state === source { state.applySharedTradeCountdown(shared) }
                refresh()
                return
            }
        } while retryUpload
        uploadFailed = false   // the new WorldScreen startNewScreenJob opens has no failed upload
        s.sharedTradeOffers = nil   // the clone is the game now: no other holds its offers
        guard turnArrived(s, original: original, result: result, autosave: autosave) else { return }
        updateOnlineStatus()
    }

    /// Unciv startNewScreenJob → UncivGame.loadGame: the clone becomes the game, shown on a new WorldScreen - the screens
    /// and popups opened over the old one while the turn ran are gone (`screenStack.clear()`) - and then, every
    /// turnsBetweenAutosaves turns, WorldScreen.autoSave.
    private func showNextTurn(_ s: GameState, result: GameState.EndTurnResult, autosave: Data?) {
        do {
            closeScreensForNewWorldScreen()
            // the globals the old game set (GameState.init(from:) leaves them alone for a clone)
            HexCoord.wrapWidth = s.map.wrapX ? s.map.width : nil
            s.registerCoastalLookup()
            automatedGame = nil
            GameEvents.post(.turnArrived(old: state, new: s))
            if s !== state { state = s }
            GameEvents.post(.turnShown(self))
            // Unciv WorldScreen.autoSave: `gameInfo.turns % settings.turnsBetweenAutosaves == 0` (the zero-based turn),
            // written in the background while the player goes on (Autosaves.requestAutoSave); only Next Turn waits for it
            if let data = autosave {
                waitingForAutosave = true
                // the turn's background time goes with the autosave, which ends it even if this controller is gone by then
                let background = turnBackgroundTime
                turnBackgroundTime = nil
                SaveManager.requestAutoSave(data, civ: s.player.nation, uncivTurns: s.uncivTurns, nextTurn: true) { [weak self] in
                    self?.waitingForAutosave = false
                    background?.end()
                }
            } else { endTurnBackgroundTask() }
            self.isProcessing = false
            // Unciv WorldScreen.update: DiplomaticVoteResultScreen at turn start - `!autoPlay.isAutoPlaying()` among its
            // conditions, so a multi-turn AutoPlay going on is not held under it
            if !(isAutoPlaying && autoPlayTurnsLeft > 0) && s.shouldShowDiplomaticVotingResults(s.playerId) { self.showVoteResult = true }
            // Unciv GameInfo.startTurn: "Play some nice music" - her 10 turda bir, setNextTurn bayraklariyla
            if s.turn % 10 == 0 {
                MusicController.shared.chooseTrack(prefix: s.player.nation, suffixes: [MusicMood.peaceOrWar(!s.player.atWarWith.isEmpty)], flags: .setNextTurn)
            }
            let notes = s.player.notifications
            if let researched = notes.first(where: { $0.hasPrefix("Research of [") }) {
                let tech = researched.replacingOccurrences(of: "Research of [", with: "").components(separatedBy: "]").first ?? ""
                MusicController.shared.chooseTrack(prefix: tech, suffixes: [MusicMood.researched], flags: .setSpecific)
            }
            if notes.contains(where: { $0.contains("entered a Golden Age") }) { MusicController.shared.chooseTrack(prefix: s.player.nation, suffixes: [MusicMood.golden], flags: .setSpecific) }
            if let wonder = s.player.popupAlerts.first(where: { $0.type == .WonderBuilt })?.value { MusicController.shared.chooseTrack(prefix: wonder, suffixes: [MusicMood.wonder], flags: .setSpecific) }
            if s.player.popupAlerts.contains(where: { $0.type == .WarDeclaration }) { MusicController.shared.chooseTrack(prefix: s.player.nation, suffixes: [MusicMood.war], flags: .setSpecific) }
            if s.outcome != nil { let won: Bool = { if case .victory = s.outcome! { return true }; return false }(); MusicController.shared.chooseTrack(prefix: s.player.nation, suffixes: [won ? MusicMood.victory : MusicMood.defeat, won ? MusicMood.theme : MusicMood.defeat], flags: .suffixMustMatch) }
            self.freshWorldScreen()   // startNewScreenJob: the new turn is shown on a new WorldScreen
            if s.isHotSeat && !s.settings.isOnline {
                self.handoffTo = s.currentHuman.nation
                self.scene.resetTiles()
            } else { self.scene.resetTiles(); self.refresh() }
            _ = result
            // Unciv startNewScreenJob -> UncivGame.loadGame: the next turn is a new WorldScreen that selects the capital's tile,
            // its scroll restored from the old one - no unit is picked and the camera does not move (switchToNextUnit never runs)
            // Unciv TurnManager.startTurn moves a human's automated units (doAction) once, and only with "Automated units
            // move on turn start" on - startHumanTurn did that for this civ; moving them again here was a second doAction.
            self.movedAutomatedUnitsThisTurn = false
            if !s.isHotSeat { self.selectTurnStartTile(centerCamera: false) }
            self.continueAutoPlayIfNeeded()
        }
    }
    /// GameView closes the sheets it presents itself (save, load, new game, options) when this moves.
    @Published var worldScreenGeneration = 0
    /// Unciv UncivGame.loadGame: `for (screen in screenStack) screen.dispose(); screenStack.clear()` - the city screen,
    /// the pickers, the overview, the Civilopedia, the diplomacy screen and every popup opened over the old WorldScreen
    /// while the turn ran showed the game the turn replaced, and go with it - as they go before an undo or the latest
    /// online state (replaceState).
    private func closeScreensForNewWorldScreen() {
        overviewReturn = nil; pendingAfterDismiss = nil; reopenDiplomacyOn = nil
        showCity = false; cityTile = nil; cityPickTile = nil
        showTech = false; techPickerCenterOn = nil
        showDiplomacy = false; showTrade = false; tradePartner = nil; counterOfferSeed = nil; tradeThanksFrom = nil
        showPolicies = false; policyHighlight = nil
        showPromotions = false; promotionUnitId = nil
        showVictory = false
        showCivilopedia = false; civilopediaEntry = nil; civilopediaSearch = false
        showReligion = false; religionHighlight = nil
        showEspionage = false
        showOverview = false; overviewPage = nil; overviewSelect = ""
        showChat = false; showMultiplayerStatus = false; showMusic = false; showDevConsole = false
        showGreatPersonPicker = false; showMayaCalendar = false; foreignCityInfo = nil
        showImprovementPicker = false; showDetailedStats = false; showGPPBreakdown = false
        showRenameCity = false; showRenameUnit = false; showUpgradeMenu = false
        showVotePicker = false; showVoteResult = false; showCongress = false
        showFoundReligion = false; showEnhanceReligion = false; showFreeBeliefs = false
        showMenu = false; showAutoPlayMenu = false; showNextTurnMenu = false; confirmNextTurn = false
        confirmPillage = nil; confirmDisband = nil; confirmBreakPromise = nil; confirmAnnihilation = nil; pendingAnnihilation = nil
        // the new WorldScreen's map carries none of the old one's overlays: the taps made while the turn ran (tileSelected
        // and addTileOverlays answer them - our units' icons on a tile, a city button moved down, a tile selected) go too
        selectedUnitId = nil; selectedCityId = nil
        pendingMove = nil; battleTarget = nil; infoTile = nil; selectedSpyId = nil; foreignCityTapped = nil; unitIconsTile = nil; paradropOverlay = nil
        swapOverlayTile = nil; roadOverlay = nil; spyOverlayTile = nil
        swapMode = false; paradropMode = false; connectRoadMode = false; sweepMode = false
        worldScreenGeneration += 1
    }

    // MARK: Unciv PopupAlert queue
    /// Unciv WorldScreen.update: `popupAlerts.any() -> AlertPopup(popupAlerts.first())`, and only once none is left
    /// `tradeRequests.isNotEmpty() -> TradePopup` (tradeRequests.first()). Ours keeps a trade request as a
    /// .TradeRequest alert in the same list, so every other alert comes first and the requests keep their own order.
    var currentAlert: PopupAlert? {
        // WorldScreen.update opens them only `!autoPlay.isAutoPlaying()`: while a multi-turn AutoPlay has turns left the
        // alerts wait - and its next automated turn answers and clears them (respondToPopupAlerts)
        guard isMyTurn && !isProcessing && handoffTo == nil && !(isAutoPlaying && autoPlayTurnsLeft > 0) else { return nil }
        let ok: (PopupAlert) -> Bool = { ($0.type != .GameHasBeenWon || self.state.oneMoreTurnMode) && self.state.alertShouldOpen($0) }
        return player.popupAlerts.first { $0.type != .TradeRequest && ok($0) } ?? player.popupAlerts.first { $0.type == .TradeRequest && ok($0) }
    }
    func dismissAlert(_ a: PopupAlert) {
        guard !isProcessing else { return }
        state.dismissAlert(state.playerId, a)
        refresh(full: false)
    }
    func declareWar(on civId: Int) { guard !isProcessing, state.canDeclareWar(state.playerId, on: civId) else { return }; state.declareWar(state.playerId, on: civId); GameEvents.post(.warDeclared(turn: state.turn, onCityState: state.civ(civId)?.isCityState == true)); MusicController.shared.chooseTrack(prefix: state.civ(civId)?.nation ?? "", suffixes: [MusicMood.war], flags: .setSpecific); refresh() }
    /// AlertPopup / TradePopup: the player presses `option` - GameState.answerAlert does what Unciv's button does, the
    /// same function the headless POPUPLOG driver presses - and the screen follows: TradePopup's TradeThanksPopup after
    /// "Sounds good!", the DiplomacyScreen on the request's trade after "How about something else...", the VictoryScreen
    /// after "Victory status".
    func answerAlert(_ a: PopupAlert, option: String) {
        guard !isProcessing else { return }
        let offer = a.type == .TradeRequest ? Int(a.value).flatMap { id in state.pendingOffers.first { $0.id == id } } : nil
        guard state.answerAlert(state.playerId, a, option: option) else { return }
        switch (a.type, option) {
        case (.TradeRequest, "Sounds good!"): tradeThanksFrom = offer?.from; GameEvents.post(.tradeAccepted)
        case (.TradeRequest, "How about something else..."): if let o = offer { counterOfferSeed = o; openTrade(with: o.from) }
        case (.GameHasBeenWon, "Victory status"): showVictory = true
        default: break
        }
        refresh()
    }
    /// Unciv Popup.getBehindClickListener: a tap behind the popup closes it and runs its last close button's action
    /// (onCloseCallback) - unless forbidPopupClickBehindToClose, or the popup has no close button.
    func alertTappedBehind(_ a: PopupAlert) {
        guard !UserSettings.neverCloseByTapOutside, let option = state.alertOptions(a, for: state.playerId).clickBehind else { return }
        answerAlert(a, option: option)
    }
    func raze(cityId: Int) { guard !isProcessing else { return }; state.setRazing(cityId: cityId, true); refresh(full: false) }

    // MARK: Unciv NextTurnButton state machine
    enum NextTurnAction: Equatable {
        case retryUpload, autoPlay, working, waiting(String), pickGreatPerson, pickConstruction, pickTech, pickPolicy, moveSpies, foundPantheon, expandPantheon, foundReligion, enhanceReligion, reformReligion, worldCongressVote, nextUnit, moveAutomatedUnits, nextTurn
        var text: String {
            switch self {
            case .retryUpload: return "Retry Upload"
            case .autoPlay: return "AutoPlay"
            case .working: return "Working..."
            case .waiting(let who): return who.isEmpty ? "Waiting for other players..." : "Waiting for [\(who)]..."
            case .pickGreatPerson: return "Choose a free great person"
            case .pickConstruction: return "Pick construction"
            case .pickTech: return "Pick a tech"
            case .pickPolicy: return "Pick a policy"
            case .moveSpies: return "Move Spies"
            case .foundPantheon: return "Found Pantheon"
            case .expandPantheon: return "Expand Pantheon"
            case .foundReligion: return "Found Religion"
            case .enhanceReligion: return "Enhance a Religion"
            case .reformReligion: return "Reform Religion"
            case .worldCongressVote: return "Vote for World Leader"
            case .nextUnit: return "Next unit"
            case .moveAutomatedUnits: return "Move automated units"
            case .nextTurn: return "Next turn"
            }
        }
        var isWaiting: Bool { if case .waiting = self { return true }; return false }
        var isChoice: Bool { self != .nextTurn && self != .working && !isWaiting && self != .autoPlay && self != .retryUpload }
    }
    var movedAutomatedUnitsThisTurn = false
    @Published var isAutoPlaying = false
    var autoPlayTurnsLeft = 0
    @Published var showAutoPlayMenu = false
    @Published var showNextTurnMenu = false
    @Published var confirmNextTurn = false

    /// Unciv: cities without production, no research, policy affordable, pantheon/religion choices, votes, due units, automated units, then next turn.
    var nextTurnAction: NextTurnAction {
        let s = state, civ = player
        if uploadFailed && isOnline { return .retryUpload }   // Unciv NextTurnAction.RetryUpload
        if isAutoPlaying { return .autoPlay }
        if isProcessing { return .working }
        if !isMyTurn { return .waiting(s.settings.isOnline ? (s.civ(s.currentHumanId)?.nation ?? s.currentHuman.nation) : "") }
        if civ.isSpectator { return .nextTurn }
        if civ.freeGreatPeople > 0 { return .pickGreatPerson }   // Unciv WorldScreen.hasPendingFreeGreatPerson
        // Unciv getCityWithNoProductionSet: `currentConstructionName().isEmpty()` - a city left Idle ("Nothing") does not stop the turn
        if s.cities(of: civ.id).contains(where: { !$0.isPuppet && $0.currentProduction == nil && $0.convertProductionTo.isEmpty }) { return .pickConstruction }
        if civ.currentTech == nil && !s.cities(of: civ.id).isEmpty && !s.researchableTechs(for: civ).isEmpty { return .pickTech }
        if civ.freeTechs > 0 && !s.researchableTechs(for: civ).isEmpty { return .pickTech }
        if (civ.shouldOpenPolicyPicker || civ.freePolicies > 0) && s.canAdoptPolicyNow(civ) { return .pickPolicy }   // Unciv PolicyManager.shouldShowPolicyPicker
        // Unciv EspionageManager.shouldShowMoveSpies: `!dismissedShouldMoveSpies && spyList.any { it.isIdle() }` - Spy.isIdle
        // is `action == SpyAction.None`, a living spy in the hideout; no city is looked at
        if s.espionageEnabled && !civ.dismissedShouldMoveSpies && civ.spies.contains(where: { $0.action == "None" }) { return .moveSpies }
        if s.canFoundPantheon(civ) { return .foundPantheon }
        if s.canExpandPantheon(civ) { return .expandPantheon }   // Unciv NextTurnAction.ExpandPantheon
        if civ.pendingReligion == "founding" { return .foundReligion }     // isFoundingReligion
        if civ.pendingReligion == "enhancing" { return .enhanceReligion }  // isEnhancingReligion
        if civ.freeBeliefsByType.values.reduce(0, +) > 0 { return .reformReligion }   // ReformReligion: hasFreeBeliefs
        if s.mayVoteForDiplomaticVictory(civ.id) { return .worldCongressVote }   // Unciv NextTurnAction.WorldCongressVote
        if UserSettings.checkForDueUnits && !idleUnits.isEmpty { return .nextUnit }
        if canMoveAutomatedUnits { return .moveAutomatedUnits }
        return .nextTurn
    }
    /// Unciv NextTurnButton.update: `isEnabled = text == "AutoPlay" || ((isPlayersTurn || failedUpload) &&
    /// !waitingForAutosave && !isNextTurnUpdateRunning())` - "Retry Upload" too is off while its own turn runs. A disabled
    /// button's key bindings do nothing either (ActorAttachments.activate: "Skip if disabled").
    var nextTurnButtonEnabled: Bool {
        if nextTurnAction == .autoPlay { return true }
        return (isMyTurn || (isOnline && uploadFailed)) && !waitingForAutosave && !isProcessing
    }
    /// Unciv NextTurnAction.getIdleUnitsText: "[$count] units idle", the count filled in before tr()
    var idleUnitsText: String? { idleUnits.isEmpty ? nil : L("[\(idleUnits.count)] units idle") }

    /// Unciv CivView.hasUnitsReadyToAutomate: `currentMovement > Constants.minimumMovementEpsilon && (isAutomated() ||
    /// isExploring() || isMoving())` - a worker connecting a road is automated there (ConnectRoad sets `automated = true`)
    var canMoveAutomatedUnits: Bool {
        if player.isSpectator || UserSettings.automatedUnitsMoveOnTurnStart || movedAutomatedUnitsThisTurn { return false }
        return state.units(of: state.playerId).contains { u in
            Float(u.movementLeft) > Float(GameState.minimumMovementEpsilon)
                && (u.isAutomated || u.order == .explore || { if case .moveTo = u.order { return true }; return false }())
        }
    }

    func moveAutomatedUnits() {
        guard isMyTurn, !isProcessing else { return }
        movedAutomatedUnitsThisTurn = true
        state.continueOrders(for: state.playerId)
        refresh()
    }

    /// The Next-turn button was tapped: perform the current state's action (Unciv NextTurnAction.action).
    func performNextTurnAction() {
        guard handoffTo == nil else { return }
        switch nextTurnAction {
        case .pickGreatPerson: deferFreeGreatPersonPicker = false; showGreatPersonPicker = true   // Unciv openGreatPersonPicker
        case .autoPlay: stopAutoPlay()
        case .working, .waiting: break
        case .retryUpload: endTurn()   // Unciv NextTurnAction.RetryUpload: worldScreen.nextTurn() - the turn is played again from the game as it stood
        case .pickConstruction:
            if let c = state.cities(of: state.playerId).first(where: { !$0.isPuppet && $0.currentProduction == nil && $0.convertProductionTo.isEmpty }) { selectedCityId = c.id; showCity = true }
        case .pickTech: showTech = true
        case .pickPolicy: showPolicies = true; if let ci = state.civIndex(state.playerId) { state.civs[ci].shouldOpenPolicyPicker = false }   // tryDismissPolicyPicker
        case .moveSpies: showEspionage = true; if let ci = state.civIndex(state.playerId) { state.civs[ci].dismissedShouldMoveSpies = true }   // tryDismissMoveSpies
        case .foundPantheon, .expandPantheon: showReligion = true
        case .foundReligion: showFoundReligion = true
        case .enhanceReligion: showEnhanceReligion = true
        case .reformReligion: showFreeBeliefs = true
        case .worldCongressVote: showVotePicker = true
        case .nextUnit: switchToNextUnit(resetDue: !UserSettings.checkForDueUnitsCycles)
        case .moveAutomatedUnits: moveAutomatedUnits()
        case .nextTurn: confirmedNextTurn()
        }
    }

    /// Unciv UnitManager.nextPotentiallyDueAt lives in the game state (`state.nextPotentiallyDueAt`, per civ): the
    /// civ's unit list turns to start there on the next unit added or removed.
    /// Unciv WorldScreen.switchToNextUnit + UnitManager.cycleThroughDueUnits: the selected unit stops being due (unless the
    /// button cycles), then the next due idle unit after the last one found is selected — the selected one only if it is the last left.
    func switchToNextUnit(resetDue: Bool = true) {
        guard !isProcessing else { return }
        let skip = selectedUnitId
        if resetDue, let cur = skip, let i = state.unitIndex(cur), state.units[i].civId == state.playerId { state.units[i].due = false }
        let list = state.units(of: state.playerId)
        let dueIds = Set(idleUnits.map { $0.id })
        var next: Unit? = nil
        if !list.isEmpty {
            if UserSettings.cycleIdleUnitsByDistance {
                // Unciv alternateCycleThroughDueUnits: the due unit closest to the selected unit (or the capital), never the selected one
                let center = skip.flatMap { state.unit($0)?.coord } ?? state.capital(of: state.playerId)?.coord ?? list[0].coord
                if let e = list.enumerated().filter({ dueIds.contains($0.element.id) && $0.element.id != skip }).min(by: { $0.element.coord.distance(to: center) < $1.element.coord.distance(to: center) }) {
                    state.nextPotentiallyDueAt[state.playerId] = (e.offset + 1) % list.count; next = e.element
                }
            } else {
                let start = (state.nextPotentiallyDueAt[state.playerId] ?? 0) % list.count   // below the count: add/remove reset it
                var at = start, fallback = -1
                repeat {
                    if dueIds.contains(list[at].id) {
                        if list[at].id != skip { state.nextPotentiallyDueAt[state.playerId] = (at + 1) % list.count; next = list[at]; break }
                        fallback = at
                    }
                    at = (at + 1) % list.count
                } while at != start
                if next == nil && fallback >= 0 { state.nextPotentiallyDueAt[state.playerId] = (fallback + 1) % list.count; next = list[fallback] }
            }
        }
        // Unciv: `setCenterPosition(nextDueUnit's tile, immediately = false, selectUnit = false)` then selectUnit(it); with
        // none, the blink stops, `mapHolder.selectedTile = null` and selectUnit() - nothing selected
        if let u = next { setCenterPosition(u.coord, selectUnit: false); select(unitId: u.id) }
        else { scene.stopBlink(); battleTarget = nil; infoTile = nil; selectedUnitId = nil; selectedCityId = nil; selectedSpyId = nil; refresh(full: false) }
    }

    func confirmedNextTurn() {
        if UserSettings.confirmNextTurn { confirmNextTurn = true } else { completeTask("turn"); endTurn() }
    }

    // MARK: Unciv AutoPlay
    func startAutoPlay(turns: Int? = nil) {
        guard !isAutoPlaying, isMyTurn else { return }
        autoPlayTurnsLeft = turns ?? (UserSettings.autoPlayUntilEnd ? Int.max : UserSettings.autoPlayMaxTurns)
        isAutoPlaying = true
        showAutoPlayMenu = false
        autoPlayStep()
    }
    func stopAutoPlay() { isAutoPlaying = false; autoPlayTurnsLeft = 0 }
    private func autoPlayStep() {
        // Unciv NextTurnButton.update: the multi-turn AutoPlay goes on `if (autoPlay.shouldContinueAutoPlaying() &&
        // worldScreen.isPlayersTurn && !worldScreen.waitingForAutosave && !worldScreen.isNextTurnUpdateRunning())` - and
        // update runs only while the WorldScreen renders, never under a screen pushed over it (screenPushedOverWorld).
        // (Ours also waits out a game download, whose modal "Loading latest game state..." holds Next Turn.)
        if isAutoPlaying && (waitingForAutosave || screenPushedOverWorld || loadingLatestState) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.autoPlayStep() }; return
        }
        guard isAutoPlaying, autoPlayTurnsLeft > 0, state.outcome == nil, isMyTurn else { stopAutoPlay(); return }
        autoPlayTurnsLeft -= 1
        // Unciv: `TurnManager(worldScreen.selectedGameView.civView.getCiv()).automateTurn()` and then, on the GL thread,
        // `worldScreen.nextTurn()` - the whole AI every time: automateTurn reads none of the per-domain AutoPlay settings
        // (autoPlayMilitary, autoPlayCivilian...; their AutomationTab switches are commented out in 4.22.1). fullAutoPlayAI
        // (no switch either, true by default) is read on the way, by the rules that ask isAutoPlayingAndFullAutoPlayAI
        // (GameState.autoPlayingFullAI) - in the automation and in the clone's walk while turns are left.
        endTurn(automatingPlayer: true)
    }
    private func continueAutoPlayIfNeeded() {
        guard isAutoPlaying else { return }
        if autoPlayTurnsLeft <= 0 || state.outcome != nil { stopAutoPlay(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.autoPlayStep() }
    }
    /// Unciv AutoPlayMenu.autoPlayEndTurn ("AutoPlay End Turn"): `TurnManager(civ).automateTurn()`, stopAutoPlay and
    /// worldScreen.nextTurn() - on the AutoPlay job's thread from 30 units and cities on, on the GL thread below that (the
    /// game comes out the same); ours always on the turn's thread, as the multi-turn AutoPlay's.
    func autoPlayEndTurn() { guard isMyTurn, !isProcessing else { return }; endTurn(automatingPlayer: true) }

    /// Unciv TurnManager.automateTurn for the viewing civ while AutoPlay plays it (`autoPlay.autoPlayTurnInProgress`, which
    /// makes isAIOrAutoPlaying true): NextTurnAutomation.automateCivMoves - and then, as Next Turn did for every turn, the
    /// automated military units' promotions (GameController.stageAutoPromotions, read from the setting beforehand). Runs on
    /// whatever thread holds the game: the turn's, or the main thread for a game played in place.
    nonisolated static func automatePlayer(_ game: GameState, promote: Bool) {
        game.autoPlayTurnInProgress = true
        AI(state: game, civId: game.playerId).takeTurn()
        game.autoPlayTurnInProgress = false
        if promote { promoteAutomatedUnits(game) }
    }
    nonisolated static func promoteAutomatedUnits(_ game: GameState) {
        let ai = AI(state: game, civId: game.playerId)
        for u in game.units(of: game.playerId) where u.isMilitary && u.isAutomated && game.promotionsAvailable(u) > 0 { ai.promoteIfPossible(u) }
    }

    /// AutoPlay's turn, the world screen's copy of the game decoded: from now on the screen shows the copy and the game
    /// itself belongs to the turn's thread, which automates the player on it (Unciv's world screen kept drawing
    /// worldScreen.gameInfo while automateTurn changed it on another thread). Nothing changes the game meanwhile
    /// (isProcessing), so the copy shows the turn as it was when Next Turn was pressed. False when the game is no longer the
    /// one shown (another game, the main menu): the turn is dropped and its game left untouched.
    private func showWhileAutomating(_ copy: GameState, insteadOf game: GameState) -> Bool {
        guard state === game, isProcessing, GameController.current === self else {
            endTurnBackgroundTask()
            if state === game { isProcessing = false; turnProgress = 0; turnProgressMax = 0; turnProgressCiv = nil }
            return false
        }
        copy.registerCoastalLookup()
        state = copy
        automatedGame = (game, copy)
        automationHandOvers += 1
        return true
    }
    /// The game AutoPlay automates on the turn's thread, and the copy shown instead of it meanwhile.
    private var automatedGame: (game: GameState, shown: GameState)? = nil
    /// Times the world screen has gone over to the copy (the self-test's frame monitor names the frame it happens in).
    private(set) var automationHandOvers = 0
    /// A turn that does not arrive after AutoPlay's automation ran - the clone not decoded, the upload failed: the player
    /// stays on the automated game (Unciv's automateTurn changed worldScreen.gameInfo itself), which the turn's thread has
    /// done with by now.
    private func restoreAutomatedGame() {
        guard let a = automatedGame else { return }
        automatedGame = nil
        guard state === a.shown else { return }
        a.game.registerCoastalLookup()
        state = a.game
        scene.resetTiles()
    }
    /// The automated game could not be encoded for its clone: the turn is played in place on it, on the main thread.
    private func playAutomatedInPlace(_ game: GameState, shown: GameState, citiesAutoBombard: Bool, autoPlayGoesOn: Bool) {
        guard isProcessing, state === shown else { turnCouldNotStart(shown); return }
        automatedGame = nil
        game.registerCoastalLookup()
        state = game
        game.autoPlayGoesOn = autoPlayGoesOn
        let result = game.playWorldScreenNextTurn(citiesAutoBombard: citiesAutoBombard)
        game.autoPlayGoesOn = false
        turnPlayed(game, original: game, result: result, autosave: nil)
    }
    /// Unciv AutoPlayMenu.autoPlayMilitary ("AutoPlay Military Once"): the military units, sorted by
    /// NextTurnAutomation.getUnitPriority, each run automateUnitMoves - then UnitAutomation.tryBombardEnemy for every city.
    /// Under `autoPlay.autoPlayTurnInProgress` (runAutoPlayJobInNewThread, or set around the call below 30 units): the
    /// player stays a human (isAI() false - a civilian recaptured from barbarians still asks), automated as AutoPlay is
    /// (isAIOrAutoPlaying, isAutoPlayingAndFullAutoPlayAI). Ours played it as an AI (epochsAutoplay).
    func autoPlayMilitaryOnce() {
        guard !isProcessing else { return }
        state.autoPlayTurnInProgress = true
        for id in autoPlayOrder(state.units(of: state.playerId).filter { $0.isMilitary }) where state.unit(id) != nil { state.automateUnitMoves(id) }
        state.automateCityBombardment(state.playerId)
        state.autoPlayTurnInProgress = false; refresh()
    }
    /// Unciv AutoPlayMenu.autoPlayCivilian: the civilian units in getUnitPriority order, automateUnitMoves each, under
    /// autoPlayTurnInProgress as autoPlayMilitary.
    func autoPlayCiviliansOnce() {
        guard !isProcessing else { return }
        state.autoPlayTurnInProgress = true
        for id in autoPlayOrder(state.units(of: state.playerId).filter { $0.isCivilian }) where state.unit(id) != nil { state.automateUnitMoves(id) }
        state.autoPlayTurnInProgress = false; refresh()
    }
    /// Unciv AutoPlayMenu.autoPlayEconomy: NextTurnAutomation.automateCities and nothing else - no research, no policy -
    /// with no AutoPlay flag at all: the cities are a human's, not automated ones (their construction picks halve the
    /// units' value - isAIOrAutoPlaying false - and say "has started working on").
    func autoPlayEconomyOnce() { guard !isProcessing else { return }; state.automateCitiesAI(state.playerId); refresh() }
    /// Unciv `sortedBy { NextTurnAutomation.getUnitPriority(unit, civInfo.isAtWar()) }`: a stable sort, the war state read once.
    private func autoPlayOrder(_ list: [Unit]) -> [Int] {
        let atWar = state.isAtWarAtAll(state.playerId)
        return list.enumerated().sorted { a, b in
            let pa = state.unitPriority(a.element, atWar: atWar), pb = state.unitPriority(b.element, atWar: atWar)
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map { $0.element.id }
    }

    /// Hot-seat: the next player taps to reveal their map.
    func beginHandedOffTurn() {
        handoffTo = nil
        scene.resetTiles()
        refresh()
        // Unciv TurnManager.startTurn moved this civ's automated units already (startHumanTurn, setting on) - not again here
        // Unciv PlayerReadyScreen: the WorldScreen was built for this civ, a different viewer, so no scroll is restored -
        // the camera is on its capital (else its first unit) and that tile is selected
        selectTurnStartTile(centerCamera: true)
    }

    /// Hands the current save to the share sheet (AirDrop, Files, Messages…) for pass-and-play across devices.
    func exportSave() {
        let name = "epochs-\(state.settings.gameId ?? "game")-turn\(state.turn).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url)
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first, let root = scene.keyWindow?.rootViewController {
            var top = root
            while let p = top.presentedViewController { top = p }
            vc.popoverPresentationController?.sourceView = top.view
            top.present(vc, animated: true)
        }
    }
}

// MARK: - Diplomatic vote (Unciv DiplomaticVotePickerScreen / DiplomaticVoteResultScreen)
extension GameController {
    func castDiplomaticVote(for chosen: Int?) {
        guard !isProcessing else { showVotePicker = false; return }
        state.diplomaticVoteForCiv(state.playerId, chosen)
        showVotePicker = false
        Audio.shared.play("chimes")
        refresh(full: false)
    }
    /// Continue on the result screen: Unciv adds the flag with -1 so the results are not shown again.
    func dismissVoteResult() {
        guard !isProcessing else { showVoteResult = false; return }
        if let i = state.civIndex(state.playerId) { state.civs[i].civFlags["ShowDiplomaticVotingResults"] = -1 }
        showVoteResult = false
        refresh(full: false)
    }
}


// MARK: - --trace-input
extension GameController {
    fileprivate func traceTapStart(_ hex: HexCoord) {
        let t = state.map[hex]
        let explored = player.explored.contains(hex)
        let units = state.units(at: hex).map { "\($0.name)#\($0.id)(civ\($0.civId))" }.joined(separator: ",")
        var line = "tapTile \(InputTrace.hex(hex)) explored=\(explored) terrain=\(explored ? (t?.terrainNames.joined(separator: "/") ?? "-") : "?") units=[\(units)] myTurn=\(isMyTurn) processing=\(isProcessing)"
        if let u = selectedUnit {
            line += " | selected \(u.name)#\(u.id) at \(InputTrace.hex(u.coord)) mp=\(u.movementLeft)/\(state.maxMovement(of: u))"
            if hex != u.coord {
                line += " highlighted=\(reachable.contains(hex)) canMoveTo=\(state.canMoveTo(u, hex)) turnsToReach=\(state.shortestPath(u, to: hex).count) stopThisTurn=\(state.tileToMoveToThisTurn(u, hex).map(InputTrace.hex) ?? "nil") reachableCount=\(reachable.count)"
            }
        } else { line += " | no unit selected" }
        if let pm = pendingMove { line += " | badge was on \(InputTrace.hex(pm.tile)) (\(pm.turns)t)" }
        InputTrace.log(line)
    }
    fileprivate func traceTapEnd() {
        var line = "  -> selected=\(selectedUnit.map { "\($0.name)#\($0.id)" } ?? "none") city=\(selectedCityId.map(String.init) ?? "none")"
        if let pm = pendingMove { line += " badge on \(InputTrace.hex(pm.tile)) turns=\(pm.turns) path=\(pm.path.map(InputTrace.hex).joined())" } else { line += " no badge" }
        InputTrace.log(line)
    }
}

/// The display link's target for GameController's notification update: the link holds its target, so the controller is
/// held weakly here, and a link whose controller has gone stops itself.
@MainActor
private final class NotificationsFrameTarget: NSObject {
    weak var controller: GameController?
    init(_ c: GameController) { controller = c }
    @objc func tick(_ link: CADisplayLink) {
        guard let c = controller else { link.invalidate(); return }
        c.notificationsFrameTick()
    }
}
