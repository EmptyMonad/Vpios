// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import UIKit

/// Save files (Unciv UncivFiles): named saves, the rolling "Autosave" set, clipboard and custom-location transfer.
enum SaveManager {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Saves")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static let autosaveName = "autosave"
    static func isAutosave(_ name: String) -> Bool { name.hasPrefix(autosaveName) }

    /// Ours are written as "<name>.json"; an Unciv save carries no extension at all, and one put into the folder
    /// (Files app) is listed and loaded under its own file name, as Unciv lists every file of its saves folder.
    static func url(for name: String) -> URL {
        let plain = directory.appendingPathComponent(name)
        var isDir: ObjCBool = false
        if !name.hasSuffix(".json"), FileManager.default.fileExists(atPath: plain.path, isDirectory: &isDir), !isDir.boolValue { return plain }
        return directory.appendingPathComponent("\(name).json")
    }

    static func save(_ state: GameState, name: String) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: url(for: name), options: .atomic)
    }

    /// Unciv Autosaves.autoSave: write "autosave", and after a turn also "autosave-[civ]-[turn]"; keep the newest `maxAutosavesStored`.
    /// Here and now (the main menu reads it next); it waits for an autosave still being written on autosaveQueue.
    static func autosave(_ state: GameState, nextTurn: Bool) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let civ = state.player.nation, turns = state.uncivTurns, keep = UserSettings.maxAutosavesStored
        autosaveQueue.sync { writeAutosave(data, civ: civ, uncivTurns: turns, nextTurn: nextTurn, keep: keep) }
    }
    /// Unciv Autosaves.requestAutoSaveUnCloned: a game nobody changes meanwhile (already encoded here) written on the
    /// autosave thread - "the save takes a long time ... and we can do it while the player continues his game" - `done`
    /// on the main thread afterwards (Unciv's job.invokeOnCompletion, which clears waitingForAutosave).
    static func requestAutoSave(_ data: Data, civ: String, uncivTurns: Int, nextTurn: Bool, done: @escaping @MainActor @Sendable () -> Void = {}) {
        let keep = UserSettings.maxAutosavesStored
        autosaveQueue.async {
            writeAutosave(data, civ: civ, uncivTurns: uncivTurns, nextTurn: nextTurn, keep: keep)
            DispatchQueue.main.async { done() }
        }
    }
    /// Unciv Concurrency.run("autoSaveUnCloned"): one autosave at a time, in the order they were asked for.
    private static let autosaveQueue = DispatchQueue(label: "epochs.autosave", qos: .utility)
    private static func writeAutosave(_ data: Data, civ: String, uncivTurns: Int, nextTurn: Bool, keep: Int) {
        guard (try? data.write(to: url(for: autosaveName), options: .atomic)) != nil else { return }
        guard nextTurn else { return }
        let civ = civ.replacingOccurrences(of: "/", with: "-")
        // Unciv UncivFiles: "$AUTOSAVE_FILE_NAME-${gameInfo.currentPlayer}-${gameInfo.turns}" - the zero-based turn
        try? FileManager.default.removeItem(at: url(for: "\(autosaveName)-\(civ)-\(uncivTurns)"))
        try? FileManager.default.copyItem(at: url(for: autosaveName), to: url(for: "\(autosaveName)-\(civ)-\(uncivTurns)"))
        purgeOldAutosaves(max: keep)
    }

    /// Unciv Autosaves.purgeOldAutosaves: `getSaves().filter { it.name().startsWith(AUTOSAVE_FILE_NAME) }
    /// .sortedByDescending { it.lastModified() }.drop(maxAutosavesStored + 1).asIterable().reversed()` - the names and the
    /// files' dates only. Ours read and decoded every file of the folder, the player's own saves included, every turn.
    private static func purgeOldAutosaves(max keep: Int) {
        let dated = list().filter(isAutosave).map { name in
            (name: name, date: (try? FileManager.default.attributesOfItem(atPath: url(for: name).path)[.modificationDate] as? Date) ?? .distantPast)
        }
        for old in dated.sorted(by: { $0.date > $1.date }).dropFirst(keep + 1).reversed() { delete(name: old.name) }
    }

    static func load(name: String) throws -> GameState { try load(data: try Data(contentsOf: url(for: name))) }

    /// Unciv: the ruleset belongs to the GameInfo being loaded (GameInfo.setTransients), and LoadGameScreen.onLoadGame
    /// catches a load that fails and shows its message, so the game being played keeps its ruleset and its map. Ours had
    /// already made the save's ruleset the shared one, and the map wrap and coastal lookup the dropped copy's, by the
    /// time a check threw (IncompatibleSave, a decoding error): the game on screen then asked that ruleset for units it
    /// does not have (MapUnit.def) and stopped the app. A failed load puts all four back as they were.
    static func restoringGlobalsOnFailure<T>(_ body: () throws -> T) throws -> T {
        let ruleset = Ruleset.shared, base = Ruleset.currentBaseRuleset
        let wrap = HexCoord.wrapWidth, coastal = GameMap.coastalLandLookup
        do { return try body() } catch {
            if Ruleset.shared !== ruleset { Ruleset.shared = ruleset; Art.shared.reloadModRoots(mods: ruleset.mods) }
            Ruleset.currentBaseRuleset = base
            HexCoord.wrapWidth = wrap; GameMap.coastalLandLookup = coastal
            throw error
        }
    }

    static func load(data: Data) throws -> GameState { try restoringGlobalsOnFailure { try loadActivatingRuleset(data: data) } }

    private static func loadActivatingRuleset(data: Data) throws -> GameState {
        // Unciv save (plain JSON or gzip+base64)? Convert it.
        if UncivSave.isUncivSave(data), let text = String(data: data, encoding: .utf8) { return try UncivSave.importGame(from: text) }
        // Mods must be active before units/buildings are resolved.
        if let peek = try? JSONDecoder().decode(SettingsPeek.self, from: data) {
            let installed = Set(Ruleset.availableMods())
            let missing = peek.settings.mods.filter { !installed.contains($0) }
                + (Ruleset.baseRulesets.contains(peek.settings.baseRuleset) || peek.settings.baseRuleset.isEmpty ? [] : [peek.settings.baseRuleset])
            if !missing.isEmpty { throw MissingMods(names: missing) }
            // Unciv GameInfo.setTransients: `ruleset = RulesetCache.getComplexRuleset(gameParameters)` - the save's
            // own base ruleset, not whichever one happens to be active
            Ruleset.activate(mods: peek.settings.mods, baseRuleset: peek.settings.baseRuleset)
        }
        let state = try JSONDecoder().decode(GameState.self, from: data)
        // Unciv's JSON save writes a PeaceProposal giver's one Peace Treaty offer in both lists as two equal offers, so
        // the loaded copy counts down as any other treaty's (the undo checkpoint and the Next Turn clone keep it one):
        // both at the duration it had left - theirOffers no longer one ahead until `ourOffers.union(theirOffers)` has
        // taken ourOffers' a turn down (peaceTreatyStartDuration)
        for i in state.civs.indices {
            let done = state.diplomacyTurnDoneThisRound.contains(state.civs[i].id) ? 1 : 0
            for other in state.civs[i].peaceTreatySharedOffer {
                guard let until = state.civs[i].peaceTreatyUntil[other] else { continue }
                let left = max(0, until - state.turn - done)   // worked out before the write (exclusive access to civs)
                state.civs[i].peaceTreatyStartDuration[other] = left
            }
            state.civs[i].peaceTreatySharedOffer = []
        }
        // Unciv TechManager / PolicyManager / CityConstructions.setTransients: a load walks techsResearched,
        // adoptedPolicies and builtBuildings in HashSet order - the barbarians' researchedTechnologies rebuilt from
        // techsResearched, a second copy of a building (a resurrected civ's Palace) gone. Ours kept every other civ's
        // research and adoption order and every city's build order.
        state.reapplyJavaHashSetOrders()
        // Unciv's save reader fills every city's tiles, workedTiles and lockedTiles into new HashSets in the saved walk
        state.rebuildCityTileSetsAsLoaded()
        // Unciv: a loaded City.unitToPromotions holds its own UnitPromotions, written from the saving unit as it stood
        // when the game was saved - no longer that MapUnit's object.
        state.freezeSavedUnitPromotions()
        // Saves written before Civilization.exploredRegion was kept
        state.seedMissingExploredRegions()
        // Saves written before the pressure key became Unciv's noReligionName
        for i in state.cities.indices {
            if let old = state.cities[i].religionPressure.removeValue(forKey: "No religion") {
                state.cities[i].religionPressure[noReligionName, default: 0] += old
            }
        }
        let rs = Ruleset.shared
        var unknown = Set<String>()
        for u in state.units where rs.units[u.name] == nil { unknown.insert(u.name) }
        for c in state.cities { for b in c.buildings where rs.buildings[b] == nil { unknown.insert(b) } }
        for c in state.civs { for t in c.techs where rs.techs[t] == nil { unknown.insert(t) } }
        if !unknown.isEmpty { throw IncompatibleSave(names: Array(unknown.prefix(3))) }
        // Unciv GameInfo.setTransients ends every load in updateCivilizationState: the resources, the capital
        // connections and every city's happiness and stats are rebuilt before anyone reads them.
        state.updateCivilizationState()
        return state
    }
    /// Unciv MissingModsException: the save names mods this installation does not have.
    struct MissingMods: LocalizedError {
        let names: [String]
        /// Unciv MissingModsException: `missingMods.joinToString(limit = 5)` - five names, then ", ..." when there are more.
        var errorDescription: String? {
            L("Missing mods: [\(names.prefix(5).joined(separator: ", ") + (names.count > 5 ? ", ..." : ""))]")
        }
    }
    struct IncompatibleSave: LocalizedError {
        let names: [String]
        var errorDescription: String? { "\(L("This save uses an older ruleset and cannot be loaded")) (\(names.joined(separator: ", ")))" }
    }
    /// Unciv-format export (what UncivServer and Unciv's "Load copied data" expect).
    static func exportUncivToCustomLocation(_ state: GameState, name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json")
        guard let data = UncivSave.exportString(state, zipped: true).data(using: .utf8) else { return }
        try? data.write(to: url)
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first, let root = scene.keyWindow?.rootViewController {
            var top = root
            while let p = top.presentedViewController { top = p }
            vc.popoverPresentationController?.sourceView = top.view
            top.present(vc, animated: true)
        }
    }
    private struct SettingsPeek: Decodable { let settings: GameSettings }

    /// Unciv loadLatestAutosave: the plain autosave, else the newest numbered one - `getSaves().filter { it.name() !=
    /// AUTOSAVE_FILE_NAME && it.name().startsWith(AUTOSAVE_FILE_NAME) }.maxBy { it.lastModified() }` (UncivFiles.kt:559-570),
    /// the plain one left out: the turn's copy is made right after it and carries its date, so a plain autosave that does
    /// not load (an app stopped as it was written) was picked again and Resume failed with the turn's copy beside it.
    static func loadLatestAutosave() throws -> GameState {
        try latestAutosave(saves: list(includeAutosaves: true).map { ($0.name, $0.date) }, load: { try load(name: $0) })
    }
    static func latestAutosave<G>(saves: [(name: String, date: Date)], load: (String) throws -> G) throws -> G {
        if let s = try? load(autosaveName) { return s }
        guard let newest = saves.filter({ $0.name != autosaveName && isAutosave($0.name) }).max(by: { $0.date < $1.date }) else { throw CocoaError(.fileNoSuchFile) }
        return try load(newest.name)
    }

    static func exists(name: String) -> Bool { FileManager.default.fileExists(atPath: url(for: name).path) }
    static var hasAutosave: Bool { exists(name: autosaveName) }

    static func delete(name: String) { try? FileManager.default.removeItem(at: url(for: name)) }
    /// Unciv LoadOrSaveScreen.onDeleteClicked: the line the description shows afterwards
    static func deleteWithResult(name: String) -> String {
        do { try FileManager.default.removeItem(at: url(for: name)) }
        catch let e as CocoaError where e.code == .fileWriteNoPermission { return L("Insufficient permissions to delete [\(name)].") }
        catch { return L("Failed to delete [\(name)].") }
        return L("[\(name)] deleted successfully.")
    }
    /// Unciv LoadOrSaveScreen.Helpers.getLoadExceptionMessage: the primary text, a new line, then what went wrong;
    /// the flag says whether the player can fix it (a missing mod, a denied permission) or the file itself is bad.
    static func loadExceptionMessage(_ error: Error, primary: String = "Could not load game!") -> (text: String, userFixable: Bool) {
        let head = L(primary) + "\n"
        switch error {
        case let e as MissingMods: return (head + (e.errorDescription ?? ""), true)            // UncivShowableException
        case let e as IncompatibleSave: return (head + (e.errorDescription ?? ""), true)
        case is DecodingError, is UncivSave.ImportError: return (head + L("The file data seems to be corrupted."), false)  // SerializationException
        case let e as CocoaError where e.code == .fileReadNoPermission || e.code == .fileWriteNoPermission:
            return (head + L("You do not have sufficient permissions to access the file."), true)
        default: return (head + L("Unhandled problem, [\(type(of: error)) \(error.localizedDescription)]"), false)
        }
    }

    static func list() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .compactMap { f -> String? in
                if f.hasSuffix(".json") { return String(f.dropLast(5)) }
                // Unciv getSaves: every file of the folder - here the ones without an extension, hidden files aside
                if f.hasPrefix(".") || f.contains(".") { return nil }
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: directory.appendingPathComponent(f).path, isDirectory: &isDir) && !isDir.boolValue ? f : nil
            }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.sorted()
    }

    /// Unciv save-list row data (name, saved at, players, difficulty, turns, mods).
    struct SaveInfo: Identifiable {
        var id: String { name }
        let name: String
        let date: Date
        var turn: Int = 0
        var year: String = ""
        var civs: [String] = []
        var difficulty: String = ""
        var mods: [String] = []
        var baseRuleset: String = ""
        var summary: String {
            var s = civs.joined(separator: ", ")
            if !difficulty.isEmpty { s += " (\(difficulty))" }
            return s
        }
    }
    private struct InfoPeek: Decodable {
        let settings: GameSettings
        let turn: Int
        let civs: [CivPeek]
        struct CivPeek: Decodable { let nation: String; let isPlayer: Bool?; let isCityState: Bool?; let isBarbarian: Bool? }
    }

    static func list(includeAutosaves: Bool) -> [SaveInfo] {
        list().filter { includeAutosaves || !isAutosave($0) }.map { info(for: $0) }.sorted { $0.date > $1.date }
    }

    static func info(for name: String) -> SaveInfo {
        let u = url(for: name)
        let date = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast
        var info = SaveInfo(name: name, date: date)
        guard let data = try? Data(contentsOf: u) else { return info }
        // An Unciv save (plain or zipped JSON): Unciv's preview fields - turns, difficulty, the human civs, mods
        if UncivSave.isUncivSave(data), let text = String(data: data, encoding: .utf8), let json = UncivSave.decodeToJSONData(text),
           let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] {
            info.turn = root["turns"] as? Int ?? 0
            info.difficulty = root["difficulty"] as? String ?? ""
            let civs = root["civilizations"] as? [[String: Any]] ?? []
            info.civs = civs.filter { ($0["playerType"] as? String) == "Human" }.compactMap { $0["civName"] as? String }
            if let params = root["gameParameters"] as? [String: Any] { info.mods = params["mods"] as? [String] ?? []; info.baseRuleset = params["baseRuleset"] as? String ?? "" }
            return info
        }
        if let peek = try? JSONDecoder().decode(InfoPeek.self, from: data) {
            info.turn = max(0, peek.turn - 1)   // Unciv prints gameInfo.turns, which is zero-based
            info.civs = peek.civs.filter { $0.isPlayer == true }.map { $0.nation }
            if info.civs.isEmpty { info.civs = peek.civs.filter { $0.isCityState != true && $0.isBarbarian != true }.prefix(1).map { $0.nation } }
            info.difficulty = peek.settings.difficulty
            info.mods = peek.settings.mods
            info.baseRuleset = peek.settings.baseRuleset
        }
        return info
    }

    // MARK: Unciv "Copy saved game to clipboard" / "Load copied data"
    /// Unciv SaveGameScreen "Copy to clipboard": the current game zipped (UncivFiles.gameInfoToString(forceZip = true)),
    /// in Unciv's own format so either program can load it
    static func copyToClipboard(_ state: GameState) -> Bool {
        UIPasteboard.general.string = UncivSave.exportString(state, zipped: true)
        return true
    }
    /// Unciv LoadGameScreen.copySavedGameToClipboard: the save file's text, zipped when it is plain JSON
    static func copySaveFileToClipboard(name: String) -> Bool {
        guard let data = try? Data(contentsOf: url(for: name)), let first = data.first else { return false }
        UIPasteboard.general.string = first == UInt8(ascii: "{") ? UncivSave.gzip(data).base64EncodedString() : String(decoding: data, as: UTF8.self)
        return true
    }
    /// Unciv "Load copied data" (UncivFiles.gameInfoFromString): an Unciv game, zipped or not, or one of ours
    static func loadFromClipboard() throws -> GameState {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return try restoringGlobalsOnFailure { try gameFromClipboardText(text) }
    }
    private static func gameFromClipboardText(_ text: String) throws -> GameState {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("H4sI") {
            if let st = try? UncivSave.importGame(from: trimmed) { return st }
            if let zipped = Data(base64Encoded: trimmed), let json = UncivSave.gunzip(zipped) { return try load(data: json) }
        }
        if let st = try? UncivSave.importGame(from: trimmed) { return st }
        if let data = Data(base64Encoded: trimmed) { return try load(data: data) }
        return try load(data: Data(text.utf8))
    }

    /// Unciv "Save to custom location": hands a copy of the save to the share sheet.
    static func exportToCustomLocation(_ state: GameState, name: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        shareFile(data, fileName: "\(name).json")
    }
    /// Unciv "Save to custom location": hand a file to the system share sheet.
    static func shareFile(_ data: Data, fileName: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? data.write(to: url)
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first, let root = scene.keyWindow?.rootViewController {
            var top = root
            while let p = top.presentedViewController { top = p }
            vc.popoverPresentationController?.sourceView = top.view
            top.present(vc, animated: true)
        }
    }

    /// Unciv default save name: "[Civ] - [turns] turns".
    static func defaultName(for state: GameState) -> String { "\(state.player.nation) - \(state.uncivTurns) turns" }   // Unciv gameInfo.turns (zero-based)
}
