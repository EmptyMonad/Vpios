// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import UIKit
import Foundation
/// Unciv GameSettings (user options), persisted in UserDefaults.
enum UserSettings {
    private static let d = UserDefaults.standard
    /// Settings a self-test pins for its run (MoveReachSelfTest), held in memory only, so a run that crashes or is killed
    /// leaves the stored settings as they were. Behind a lock: the Next Turn thread reads settings as well.
    private static let pinLock = NSLock()
    private nonisolated(unsafe) static var pinned: [String: Bool] = [:]
    /// `pin(key, nil)` lets the stored setting show again.
    static func pin(_ key: String, _ value: Bool?) { pinLock.lock(); pinned[key] = value; pinLock.unlock() }
    private static func bool(_ key: String, _ def: Bool) -> Bool {
        pinLock.lock(); let p = pinned[key]; pinLock.unlock()
        return p ?? d.object(forKey: "epochs.\(key)") as? Bool ?? def
    }
    private static func set(_ key: String, _ v: Any?) { d.set(v, forKey: "epochs.\(key)") }
    static var checkForDueUnits: Bool { get { bool("checkForDueUnits", true) } set { set("checkForDueUnits", newValue) } }
    static var checkForDueUnitsCycles: Bool { get { bool("checkForDueUnitsCycles", false) } set { set("checkForDueUnitsCycles", newValue) } }
    static var autoUnitCycle: Bool { get { bool("autoUnitCycle", true) } set { set("autoUnitCycle", newValue) } }
    static var confirmNextTurn: Bool { get { bool("confirmNextTurn", false) } set { set("confirmNextTurn", newValue) } }
    static var orderTradeOffersByAmount: Bool { get { bool("orderTradeOffersByAmount", true) } set { set("orderTradeOffersByAmount", newValue) } }
    static var autoAssignCityProduction: Bool { get { bool("autoAssignCityProduction", false) } set { set("autoAssignCityProduction", newValue) } }
    static var automatedWorkersReplaceImprovements: Bool { get { bool("automatedWorkersReplaceImprovements", true) } set { set("automatedWorkersReplaceImprovements", newValue) } }
    static var automatedUnitsMoveOnTurnStart: Bool { get { bool("automatedUnitsMoveOnTurnStart", false) } set { set("automatedUnitsMoveOnTurnStart", newValue) } }
    static var automatedUnitsCanUpgrade: Bool { get { bool("automatedUnitsCanUpgrade", false) } set { set("automatedUnitsCanUpgrade", newValue) } }
    static var automatedUnitsChoosePromotions: Bool { get { bool("autoPromote", false) } set { set("autoPromote", newValue) } }
    static var citiesAutoBombardAtEndOfTurn: Bool { get { bool("citiesAutoBombardAtEndOfTurn", false) } set { set("citiesAutoBombardAtEndOfTurn", newValue) } }
    /// Unciv GameSettings.autoAssignSpecialistsInNewCities (read by City.resetSpecialistsControl)
    static var autoAssignSpecialistsInNewCities: Bool { get { bool("autoAssignSpecialistsInNewCities", true) } set { set("autoAssignSpecialistsInNewCities", newValue) } }
    static var showAutoPlayButton: Bool { get { bool("showAutoPlayButton", false) } set { set("showAutoPlayButton", newValue) } }
    static var autoPlayUntilEnd: Bool { get { bool("autoPlayUntilEnd", false) } set { set("autoPlayUntilEnd", newValue) } }
    static var autoPlayMaxTurns: Int { get { d.object(forKey: "epochs.autoPlayMaxTurns") as? Int ?? 10 } set { set("autoPlayMaxTurns", newValue) } }
    static var showMinimap: Bool { get { bool("minimap", true) } set { set("minimap", newValue) } }
    static var minimapSize: Int { get { d.object(forKey: "epochs.minimapSize") as? Int ?? 6 } set { set("minimapSize", newValue) } }
    static var showZoomButtons: Bool { get { d.object(forKey: "epochs.showZoomButtons") as? Bool ?? false } set { set("showZoomButtons", newValue) } }
    // Unciv GameplayTab / DisplayTab / AdvancedTab leftovers
    static var cycleIdleUnitsByDistance: Bool { get { bool("cycleIdleUnitsByDistance", false) } set { set("cycleIdleUnitsByDistance", newValue) } }
    static var mapPanningSpeed: Double { get { d.object(forKey: "epochs.mapPanningSpeed") as? Double ?? 6 } set { set("mapPanningSpeed", newValue) } }
    static var animateUnitActionsMenu: Bool { get { bool("animateUnitActionsMenu", false) } set { set("animateUnitActionsMenu", newValue) } }
    static var animateUnitMovementButton: Bool { get { bool("animateUnitMovementButton", false) } set { set("animateUnitMovementButton", newValue) } }
    static var showLongPressIndicators: Bool { get { bool("showLongPressIndicators", false) } set { set("showLongPressIndicators", newValue) } }
    /// Unciv AdvancedTab "Long press delay" (ms; Unciv GameSettings.longPressDelay = 1.1s).
    static var longPressDelay: Int { get { d.object(forKey: "epochs.longPressDelay") as? Int ?? 1100 } set { set("longPressDelay", newValue) } }
    static var longPressSeconds: Double { Double(longPressDelay) / 1000 }
    static var showPixelImprovements: Bool { get { bool("showPixelImprovements", true) } set { set("showPixelImprovements", newValue) } }
    /// Epochs' own sharp map art (HDTiles) instead of the FantasyHex pixel art
    static var hdMapArt: Bool { get { bool("hdMapArt", true) } set { set("hdMapArt", newValue) } }
    static var civilopediaUnitArtSize: Double { get { d.object(forKey: "epochs.civilopediaUnitArtSize") as? Double ?? 0 } set { set("civilopediaUnitArtSize", newValue) } }
    static var maxWorldZoomOut: Double { get { d.object(forKey: "epochs.maxWorldZoomOut") as? Double ?? 2 } set { set("maxWorldZoomOut", newValue) } }
    static var fontSizeMultiplier: Double { get { d.object(forKey: "epochs.fontSizeMultiplier") as? Double ?? 1 } set { set("fontSizeMultiplier", newValue); Theme.recomputeScale() } }
    /// Unciv GameSettings.screenSize: which virtual canvas the UI is laid out on. Default Small, as in Unciv.
    /// Unciv defaults every device to Small, which on a tablet works out to a 2.1x UI - its own menus scroll,
    /// so nothing is lost, but ours would push a button off the edge. A tablet starts on Huge (1.27x on an
    /// iPad Pro 11) instead: comfortable targets, more map, and the player can pick any of the eight.
    static var screenSize: String {
        get { d.string(forKey: "epochs.screenSize") ?? (UIDevice.current.userInterfaceIdiom == .pad ? "Huge" : "Small") }
        set { set("screenSize", newValue); Theme.recomputeScale() }
    }
    static var fontFamily: String { get { d.string(forKey: "epochs.fontFamily") ?? "" } set { set("fontFamily", newValue); Theme.fontFamily = newValue } }
    static var enlargeSelectedNotifications: Bool { get { bool("enlargeSelectedNotifications", true) } set { set("enlargeSelectedNotifications", newValue) } }
    static var useDisplayCutout: Bool { get { bool("useDisplayCutout", false) } set { set("useDisplayCutout", newValue) } }
    static var hideSystemBars: Bool { get { bool("hideSystemBars", true) } set { set("hideSystemBars", newValue) } }
    static var showWorkedTiles: Bool { get { d.object(forKey: "epochs.showWorkedTiles") as? Bool ?? false } set { set("showWorkedTiles", newValue) } }
    /// Unciv GameSettings.showResourcesAndImprovements (default true): the resource and improvement icon layers. It replaced
    /// the separate showResources / showImprovements switches, which an older install carries over (both had to be on).
    static var showResourcesAndImprovements: Bool {
        get { d.object(forKey: "epochs.showResourcesAndImprovements") as? Bool ?? (bool("showResources", true) && bool("showImprovements", true)) }
        set { set("showResourcesAndImprovements", newValue) }
    }
    static var showUnitMovements: Bool { get { d.object(forKey: "epochs.showUnitMovements") as? Bool ?? false } set { set("showUnitMovements", newValue) } }
    static var enableDevConsole: Bool { get { d.object(forKey: "epochs.enableDevConsole") as? Bool ?? false } set { set("enableDevConsole", newValue) } }
    static var enableEasterEggs: Bool { get { d.object(forKey: "epochs.enableEasterEggs") as? Bool ?? true } set { set("enableEasterEggs", newValue) } }
    /// Unciv GameSettings.singleTapMove: false = the first tap shows the "Move here" button, the second moves.
    /// Unciv DebugUtils: VISIBLE_MAP / SHOW_TILE_COORDS / SHOW_SETTLER_SCORES (Debug options tab).
    static var debugVisibleMap: Bool { get { d.object(forKey: "epochs.debugVisibleMap") as? Bool ?? false } set { set("debugVisibleMap", newValue) } }
    static var debugShowTileCoords: Bool { get { d.object(forKey: "epochs.debugShowTileCoords") as? Bool ?? false } set { set("debugShowTileCoords", newValue) } }
    static var debugShowSettlerScores: Bool { get { d.object(forKey: "epochs.debugShowSettlerScores") as? Bool ?? false } set { set("debugShowSettlerScores", newValue) } }
    static var longTapMove: Bool { get { d.object(forKey: "epochs.longTapMove") as? Bool ?? true } set { set("longTapMove", newValue) } }
    static var showSmallUnitButton: Bool { get { d.object(forKey: "epochs.showSmallUnitButton") as? Bool ?? true } set { set("showSmallUnitButton", newValue) } }
    static var showSettlersSuggestedCityLocations: Bool { get { d.object(forKey: "epochs.suggestCityLocations") as? Bool ?? true } set { set("suggestCityLocations", newValue) } }
    static var useCirclesToIndicateMovableTiles: Bool { get { d.object(forKey: "epochs.circlesMovable") as? Bool ?? false } set { set("circlesMovable", newValue) } }
    static var unitIconOpacity: Double { get { d.object(forKey: "epochs.unitIconOpacity") as? Double ?? 1.0 } set { d.set(newValue, forKey: "epochs.unitIconOpacity") } }
    /// Unciv NotificationsScroll.UserSetting: Disabled / Hidden / Visible / Permanent.
    static var notificationScroll: String { get { d.string(forKey: "epochs.notificationScroll") ?? "Visible" } set { d.set(newValue, forKey: "epochs.notificationScroll") } }
    static var neverCloseByTapOutside: Bool { get { d.object(forKey: "epochs.neverCloseByTapOutside") as? Bool ?? false } set { set("neverCloseByTapOutside", newValue) } }
    static var autoBuildRoads: Bool { get { d.object(forKey: "epochs.autoBuildRoads") as? Bool ?? true } set { set("autoBuildRoads", newValue) } }
    static var automatedWorkersRemoveVegetation: Bool { get { d.object(forKey: "epochs.workersRemoveVegetation") as? Bool ?? true } set { set("workersRemoveVegetation", newValue) } }
    static var fullAutoPlayAI: Bool { get { d.object(forKey: "epochs.fullAutoPlayAI") as? Bool ?? true } set { set("fullAutoPlayAI", newValue) } }
    static var autoPlayMilitary: Bool { get { d.object(forKey: "epochs.autoPlayMilitary") as? Bool ?? true } set { set("autoPlayMilitary", newValue) } }
    static var autoPlayCivilian: Bool { get { d.object(forKey: "epochs.autoPlayCivilian") as? Bool ?? true } set { set("autoPlayCivilian", newValue) } }
    static var autoPlayEconomy: Bool { get { d.object(forKey: "epochs.autoPlayEconomy") as? Bool ?? true } set { set("autoPlayEconomy", newValue) } }
    static var autoPlayTechnology: Bool { get { d.object(forKey: "epochs.autoPlayTechnology") as? Bool ?? true } set { set("autoPlayTechnology", newValue) } }
    static var autoPlayPolicies: Bool { get { d.object(forKey: "epochs.autoPlayPolicies") as? Bool ?? true } set { set("autoPlayPolicies", newValue) } }
    static var autoPlayReligion: Bool { get { d.object(forKey: "epochs.autoPlayReligion") as? Bool ?? true } set { set("autoPlayReligion", newValue) } }
    static var autoPlayDiplomacy: Bool { get { d.object(forKey: "epochs.autoPlayDiplomacy") as? Bool ?? true } set { set("autoPlayDiplomacy", newValue) } }
    static var multiplayerStatusInSingleplayer: Bool { get { d.object(forKey: "epochs.mpStatusSingleplayer") as? Bool ?? false } set { set("mpStatusSingleplayer", newValue) } }
    static var singleTapMove: Bool { get { bool("singleTapMove", false) } set { set("singleTapMove", newValue) } }
    /// Unciv GameSettings.continuousRendering: fireworks over celebrating cities.
    static var continuousRendering: Bool { get { d.object(forKey: "epochs.continuousRendering") as? Bool ?? false } set { set("continuousRendering", newValue) } }
    /// Unciv GameSettings.visualMods: mods whose music/sounds stay active in every game ("Permanent audiovisual mod").
    static var visualMods: [String] { get { d.stringArray(forKey: "epochs.visualMods") ?? [] } set { d.set(newValue, forKey: "epochs.visualMods") } }
    static var consoleCommandHistory: [String] { get { d.stringArray(forKey: "epochs.consoleHistory") ?? [] } set { d.set(Array(newValue.suffix(42)), forKey: "epochs.consoleHistory") } }
    static var notificationsByCategory: Bool { get { d.object(forKey: "epochs.notificationsByCategory") as? Bool ?? false } set { set("notificationsByCategory", newValue) } }
    static var showTileYields: Bool { get { bool("showTileYields", false) } set { set("showTileYields", newValue) } }
    static var showAutosaves: Bool { get { bool("showAutosaves", false) } set { set("showAutosaves", newValue) } }
    static var maxAutosavesStored: Int { get { d.object(forKey: "epochs.maxAutosavesStored") as? Int ?? 10 } set { set("maxAutosavesStored", newValue) } }
    static var turnsBetweenAutosaves: Int { get { d.object(forKey: "epochs.turnsBetweenAutosaves") as? Int ?? 1 } set { set("turnsBetweenAutosaves", newValue) } }
    /// Unciv OverviewPersistableData.last: the empire overview reopens on the page last used.
    static var overviewLastPage: String { get { d.string(forKey: "epochs.overviewLastPage") ?? "Cities" } set { set("overviewLastPage", newValue) } }
    /// Unciv CivilopediaScreen.lastCategory: the pedia reopens on the category last used.
    static var civilopediaLastCategory: String { get { d.string(forKey: "epochs.pediaLastCategory") ?? "Units" } set { set("pediaLastCategory", newValue) } }
    /// Unciv GameSettings.nationPickerListMode: the nation picker as a list or as a grid of icons.
    static var nationPickerListMode: String { get { d.string(forKey: "epochs.nationPickerListMode") ?? "List" } set { set("nationPickerListMode", newValue) } }
    /// Unciv GameSettings.keepConsoleOpen: the developer console stays open after a command.
    static var keepConsoleOpen: Bool { get { bool("keepConsoleOpen", false) } set { set("keepConsoleOpen", newValue) } }
    /// Unciv GameSettings.multiTapInterval: how long a second tap still counts as a double tap (seconds).
    static var multiTapInterval: Double { get { d.object(forKey: "epochs.multiTapInterval") as? Double ?? 0.25 } set { set("multiTapInterval", newValue) } }
    static var notificationsLogMaxTurns: Int { get { d.object(forKey: "epochs.notificationsLogMaxTurns") as? Int ?? 5 } set { set("notificationsLogMaxTurns", newValue) } }
    /// Unciv FriendList: name -> playerID, used to fill online seats.
    static var friends: [(name: String, id: String)] {
        get { ((d.array(forKey: "epochs.friends") as? [[String]]) ?? []).compactMap { $0.count == 2 ? (name: $0[0], id: $0[1]) : nil } }
        set { set("friends", newValue.map { [$0.name, $0.id] }) }
    }
    /// Unciv lastGameSetup: the new-game screen remembers the previous setup.
    static var lastGameSetup: GameSettings? {
        get { (d.data(forKey: "epochs.lastGameSetup")).flatMap { try? JSONDecoder().decode(GameSettings.self, from: $0) } }
        set { set("lastGameSetup", newValue.flatMap { try? JSONEncoder().encode($0) }) }
    }
}
