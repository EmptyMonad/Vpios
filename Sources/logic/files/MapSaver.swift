// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv TileMap.StartingLocation: a position, the nation that starts there and how a new game may use it.
struct StartingLocation: Codable, Equatable {
    /// Unciv StartingLocation.Usage: how the new game "Select players" button may use this location.
    enum Usage: String, Codable, CaseIterable {
        case normal = "Normal", player = "Player", human = "Human"
        /// Unciv Usage.label - "Normal" means "starting location only".
        var label: String { self == .normal ? "None" : rawValue }
    }
    var position: HexCoord
    /// Nation name; empty is Unciv's Spectator entry, shown in the editor as "Any Civ".
    var nation: String = ""
    /// Unciv StartingLocation.Usage.default, which is also what maps saved before the feature get.
    var usage: Usage = .player

    private enum CodingKeys: String, CodingKey { case position, nation, usage }
    init(position: HexCoord, nation: String = "", usage: Usage = .player) {
        self.position = position; self.nation = nation; self.usage = usage
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(HexCoord.self, forKey: .position)
        nation = try c.decodeIfPresent(String.self, forKey: .nation) ?? ""
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage) ?? .player
    }
}

/// Custom maps made in the editor, stored under Documents/Maps.
struct CustomMap: Codable {
    var map: GameMap
    /// Unciv TileMap.startingLocations: several nations may share a tile, and one nation may have several tiles.
    var startingLocations: [StartingLocation]
    /// The positions alone, for everything that does not care which nation starts where.
    var starts: [HexCoord] { startingLocations.map { $0.position } }
    /// Unciv TileMap.description: the editor's "Enter a description for the users of this map", shown in New Game.
    var description: String = ""
    /// Unciv TileMap.mapParameters.seed: the RNG seed the map was generated with (0 when never generated).
    var seed: UInt64 = 0
    /// Unciv TileMap.mapParameters.baseRuleset / mods: the ruleset the map was made for.
    var baseRuleset: String = Ruleset.baseRulesetName
    var mods: [String] = []
    /// The rest of Unciv's TileMap.mapParameters (type, shape, resource setting, the generator's values...), as the
    /// settings they came from; nil for a map saved before they were kept
    var parameters: GameSettings? = nil
    /// The owners (civIDs) of the units a map file carries on its tiles (Unciv Tile.militaryUnit / civilianUnit /
    /// airUnits, in tile order). Unciv 4.22.1's editor has no unit tab, but a map file can hold units, and a game
    /// started on such a map throws in GameStarter (see MapUnitsError) - ours keeps who owns them to fail the same way.
    var unitOwners: [String] = []

    init(map: GameMap, startingLocations: [StartingLocation] = [], description: String = "", seed: UInt64 = 0,
         baseRuleset: String = Ruleset.baseRulesetName, mods: [String] = [], parameters: GameSettings? = nil) {
        self.map = map; self.startingLocations = startingLocations
        self.description = description; self.seed = seed; self.baseRuleset = baseRuleset; self.mods = mods; self.parameters = parameters
    }
    /// Maps that only know positions (Wesnoth import, tests): every location becomes an "Any Civ" one.
    init(map: GameMap, starts: [HexCoord]) {
        self.init(map: map, startingLocations: starts.map { StartingLocation(position: $0) })
    }

    // Maps saved before nation-specific starting locations stored a plain "starts" array of positions; maps saved
    // before the description, seed and ruleset were kept load with Unciv's defaults (empty, 0, Gods & Kings, no mods).
    private enum CodingKeys: String, CodingKey { case map, startingLocations, starts, description, seed, baseRuleset, mods, unitOwners, parameters }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        map = try c.decode(GameMap.self, forKey: .map)
        if let locations = try c.decodeIfPresent([StartingLocation].self, forKey: .startingLocations) {
            startingLocations = locations
        } else {
            startingLocations = (try c.decodeIfPresent([HexCoord].self, forKey: .starts) ?? []).map { StartingLocation(position: $0) }
        }
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        seed = (try? c.decodeIfPresent(UInt64.self, forKey: .seed)) ?? 0
        baseRuleset = (try? c.decodeIfPresent(String.self, forKey: .baseRuleset)) ?? Ruleset.baseRulesetName
        mods = (try? c.decodeIfPresent([String].self, forKey: .mods)) ?? []
        unitOwners = (try? c.decodeIfPresent([String].self, forKey: .unitOwners)) ?? []
        parameters = try? c.decodeIfPresent(GameSettings.self, forKey: .parameters)
    }
    /// Unciv TileMap.removeMissingTerrainModReferences(ruleset), against the active ruleset: every tile drops the
    /// features, resource, improvement (the whole queue when any entry is unknown) and natural wonder the ruleset lacks -
    /// an unknown base terrain stays - and starting locations of unknown nations go.
    func removingMissingTerrainModReferences() -> CustomMap {
        let rs = Ruleset.shared
        var m = self
        for i in m.map.tiles.indices {
            var t = m.map.tiles[i]
            t.features = t.features.filter { rs.terrains[$0] != nil }
            if let r = t.resource, rs.resources[r] == nil { t.resource = nil }
            if let imp = t.improvement, rs.improvements[imp] == nil { t.improvement = nil }
            if [t.improvementInProgress, t.queuedImprovement].compactMap({ $0 }).contains(where: { rs.improvements[$0] == nil }) {
                GameState.setImprovementQueue(&t, [])   // "Just get rid of everything, all bets are off"
            }
            if let w = t.naturalWonder, rs.terrains[w] == nil { t.naturalWonder = nil }
            m.map.tiles[i] = t
        }
        m.startingLocations.removeAll { !$0.nation.isEmpty && rs.nations[$0.nation] == nil }   // "" is the Spectator entry
        return m
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(map, forKey: .map)
        try c.encode(startingLocations, forKey: .startingLocations)
        try c.encode(description, forKey: .description)
        try c.encode(seed, forKey: .seed)
        try c.encode(baseRuleset, forKey: .baseRuleset)
        try c.encode(mods, forKey: .mods)
        if !unitOwners.isEmpty { try c.encode(unitOwners, forKey: .unitOwners) }
        if let parameters { try c.encode(parameters, forKey: .parameters) }
    }
}

enum MapStore {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Maps")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func save(_ m: CustomMap, name: String) throws {
        var m = m
        m.map.assignContinents(.reassign)   // Unciv MapSaver.saveMap: tileMap.assignContinents(Reassign) before writing
        try JSONEncoder().encode(m).write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }
    static func load(name: String) -> CustomMap? {
        if name.contains("/") {   // Unciv mod map "<mod>/<file>" (MapSaver format: plain or gzip+base64 JSON)
            let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
            let url = Ruleset.modsDirectory.appendingPathComponent(parts[0]).appendingPathComponent("maps").appendingPathComponent(parts[1])
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return try? UncivSave.importMap(from: text)
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(name).json")) else { return nil }
        return try? JSONDecoder().decode(CustomMap.self, from: data)
    }
    static func list() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }
    static func delete(name: String) { try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).json")) }

    // MARK: Unciv mod maps (MapFileSelectTable: Documents/Mods/<mod>/maps/<file>), listed as "<mod>/<file>"
    static func modMaps(mods: [String]) -> [String] {
        mods.flatMap { mod -> [String] in
            let dir = Ruleset.modsDirectory.appendingPathComponent(mod).appendingPathComponent("maps")
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted().map { "\(mod)/\($0)" }
        }
    }
    static func list(mods: [String]) -> [String] { list() + modMaps(mods: mods) }
    /// Unciv MapFileSelectTable.getPreselect: the first selected mod whose ModOptions say "Mod preselects map [file]" and ship that file.
    static func preselectedMap(forMods mods: [String]) -> String? {
        for mod in mods {
            guard let file = Ruleset.modOptionUniques(of: mod).first(where: { $0.pattern == "Mod preselects map []" })?.param(0) else { continue }
            if modMaps(mods: [mod]).contains("\(mod)/\(file)") { return "\(mod)/\(file)" }
        }
        return nil
    }

    // MARK: Unciv scenarios (a saved game state started as a new game), stored under Documents/Scenarios
    static var scenarioDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Scenarios")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func listScenarios() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: scenarioDirectory.path)) ?? []).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }
    static func saveScenario(_ state: GameState, name: String) throws {
        try JSONEncoder().encode(state).write(to: scenarioDirectory.appendingPathComponent("\(name).json"), options: .atomic)
    }
    static func loadScenario(name: String) throws -> GameState {
        try SaveManager.load(data: try Data(contentsOf: scenarioDirectory.appendingPathComponent("\(name).json")))
    }
}

extension GameState {
    /// A state used only to render and edit a map: one spectator civ that sees everything.
    static func editorState(map: GameMap) -> GameState {
        HexCoord.wrapWidth = map.wrapX ? map.width : nil
        let s = GameState(settings: GameSettings(), map: map, rng: SeededRandom(seed: 1))
        var civ = Civilization(id: s.newId(), nation: "Spectator", isPlayer: true)
        civ.explored = Set(map.tiles.map { $0.coord })
        // Unciv EditorMapHolder draws with TileMapView(tileMap, null), a viewer that sees every resource, and the View
        // tab describes tiles through MapEditorViewTab.createMockCiv, which knows every tech (techsResearched.addAll(ruleset.technologies.keys))
        civ.techs = Set(s.rs.techs.keys)
        s.civs = [civ]
        return s
    }
}
