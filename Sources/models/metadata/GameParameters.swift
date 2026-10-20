// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct GameSettings: Codable {
    /// Unciv MapParameters as a map file carries them, from `p` (the map's own) onto these settings: a game on a map file
    /// plays on `tileMap.mapParameters` as loaded (GameStarter's loadMap path never takes gameSetupInfo.mapParameters),
    /// and the editor saves the map's parameters. The seed and the map's size stay with the caller.
    mutating func takeMapParameters(_ p: GameSettings) {
        mapType = p.mapType; mapShape = p.mapShape
        ancientRuins = p.ancientRuins; naturalWonders = p.naturalWonders
        resourceSetting = p.resourceSetting; strategicBalance = p.strategicBalance; legendaryStart = p.legendaryStart
        tilesPerBiomeArea = p.tilesPerBiomeArea; maxCoastExtension = p.maxCoastExtension; elevationExponent = p.elevationExponent
        temperatureIntensity = p.temperatureIntensity; vegetationRichness = p.vegetationRichness
        rareFeaturesRichness = p.rareFeaturesRichness; waterThreshold = p.waterThreshold; temperatureShift = p.temperatureShift
        if p.uncivNumberOfTiles != nil { uncivNumberOfTiles = p.uncivNumberOfTiles }
    }

    var mapDescription: String = ""          // Unciv TileMap.description, carried in from a loaded custom map
    var mapWidth: Int = 44
    var mapHeight: Int = 30
    var playerNation: String = "Rome"
    var opponentCount: Int = 3
    var seed: UInt64 = 0
    var difficulty: String = "Prince"
    var speed: String = "Quick"   // Unciv Speed.DEFAULT
    var baseRuleset: String = Ruleset.baseRulesetName   // Unciv GameParameters.baseRuleset
    var mapType: String = "Pangaea"
    var barbarians: Bool = true
    var victoryTypes: Set<String> = ["Domination", "Scientific", "Cultural", "Time", "Diplomatic"]
    var religionEnabled: Bool = true
    var espionageEnabled: Bool = false   // Unciv GameParameters.espionageEnabled
    var worldWrap: Bool = false
    var humanPlayers: Int = 1
    var mods: [String] = []
    var customMap: String? = nil
    var isOnline: Bool = false
    var gameId: String? = nil
    var ragingBarbarians: Bool = false
    var oneCityChallenge: Bool = false
    var randomNation: Bool = false
    var cityStateCount: Int = -1          // -1 = automatic
    var noCityRazing: Bool = false
    var ancientRuins: Bool = true
    var naturalWonders: Bool = true
    var startingEra: String = ""          // empty = first era
    var mapShape: String = "Rectangular"  // or "Hexagonal"
    var seaLevel: String = "Normal"       // Low / Normal / High
    var temperature: String = "Normal"    // Cold / Normal / Hot
    var rainfall: String = "Normal"       // Dry / Normal / Wet
    var resourceSetting: String = "Default" // Sparse / Default / Abundant / Strategic Balance
    var maxTurns: Int = 500               // Unciv GameParameters.maxTurns
    // Unciv GameParameters
    var players: [PlayerSetup] = [PlayerSetup(chosenCiv: "Random", isHuman: true), PlayerSetup(), PlayerSetup(), PlayerSetup()]
    var randomNumberOfPlayers: Bool = false
    var minNumberOfPlayers: Int = 3
    var maxNumberOfPlayers: Int = 3
    var randomNumberOfCityStates: Bool = false
    var minNumberOfCityStates: Int = 6
    var maxNumberOfCityStates: Int = 6
    var enableRandomNationsPool: Bool = false
    var randomNationsPool: [String] = []
    var nuclearWeaponsEnabled: Bool = true
    var noStartBias: Bool = false
    var shufflePlayerOrder: Bool = false
    // Unciv GameParameters: civilization stats visibility and online timers
    var showCivilizationStats: Bool = true   // Unciv: showVictoryStats = true, getter `field ?: showVictoryStats`
    var showDemographics: Bool = false
    var showRankings: Bool = true
    var godMode: Bool = false   // Unciv GameParameters.godMode (Debug tab "God mode (current game)")
    var showCharts: Bool = true
    var hideOtherCivilizationStats: Bool = false
    var showAdditionalRankingTypes: Bool = false
    var anyoneCanSpectate: Bool = true
    var minutesUntilSkipTurn: Int = 60 * 24
    var minutesUntilForceResign: Int = 3 * 24 * 60
    var minutesRecoveredPerTurn: Int = 60 * 24
    // Unciv MapParameters
    var mapMainType: String = "Generated"   // Generated / Random Generated / Custom
    var mapSizeName: String = "Medium"       // Tiny / Small / Medium / Large / Huge / Custom
    /// Unciv MapParameters.numberOfTiles() as the save's mapSize gives it: `1 + 3r(r-1)` on a hexagonal map -
    /// not the real count, which is `1 + 3r(r+1)` - and width × height otherwise. The score scales with it.
    var uncivNumberOfTiles: Int? = nil
    var legendaryStart: Bool = false
    var strategicBalance: Bool = false
    var randomMapShapes: [String] = ["Rectangular", "Hexagonal", "Flat Earth Hexagonal"]
    var randomMapTypes: [String] = []
    var randomMapSizes: [String] = []
    var randomMapResources: [String] = []
    var tilesPerBiomeArea: Int = 6
    var maxCoastExtension: Int = 3   // Unciv MapParameters.maxCoastExtension = 3
    var elevationExponent: Double = 0.7
    var temperatureIntensity: Double = 0.6
    var vegetationRichness: Double = 0.4
    var rareFeaturesRichness: Double = 0.05
    var waterThreshold: Double = 0
    var temperatureShift: Double = 0
    private enum CodingKeys: String, CodingKey { case mapWidth, mapHeight, playerNation, opponentCount, seed, difficulty, speed, baseRuleset, mapType, barbarians, victoryTypes, humanPlayers, mods, customMap, isOnline, gameId, religionEnabled, espionageEnabled, worldWrap, ragingBarbarians, oneCityChallenge, randomNation, cityStateCount, noCityRazing, ancientRuins, naturalWonders, startingEra, mapShape, seaLevel, temperature, rainfall, resourceSetting, maxTurns, players, randomNumberOfPlayers, minNumberOfPlayers, maxNumberOfPlayers, randomNumberOfCityStates, minNumberOfCityStates, maxNumberOfCityStates, enableRandomNationsPool, randomNationsPool, nuclearWeaponsEnabled, noStartBias, shufflePlayerOrder, mapMainType, mapSizeName, uncivNumberOfTiles, mapDescription, legendaryStart, strategicBalance, randomMapShapes, randomMapTypes, randomMapSizes, randomMapResources, tilesPerBiomeArea, maxCoastExtension, elevationExponent, temperatureIntensity, vegetationRichness, rareFeaturesRichness, waterThreshold, temperatureShift, showCivilizationStats, showDemographics, showRankings, showCharts, hideOtherCivilizationStats, showAdditionalRankingTypes, anyoneCanSpectate, minutesUntilSkipTurn, minutesUntilForceResign, minutesRecoveredPerTurn, godMode }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        players = try c.decodeIfPresent([PlayerSetup].self, forKey: .players) ?? [PlayerSetup(chosenCiv: "Random", isHuman: true), PlayerSetup(), PlayerSetup(), PlayerSetup()]
        showCivilizationStats = try c.decodeIfPresent(Bool.self, forKey: .showCivilizationStats) ?? true
        showDemographics = try c.decodeIfPresent(Bool.self, forKey: .showDemographics) ?? false
        showRankings = try c.decodeIfPresent(Bool.self, forKey: .showRankings) ?? true
        godMode = try c.decodeIfPresent(Bool.self, forKey: .godMode) ?? false
        showCharts = try c.decodeIfPresent(Bool.self, forKey: .showCharts) ?? true
        hideOtherCivilizationStats = try c.decodeIfPresent(Bool.self, forKey: .hideOtherCivilizationStats) ?? false
        showAdditionalRankingTypes = try c.decodeIfPresent(Bool.self, forKey: .showAdditionalRankingTypes) ?? false
        anyoneCanSpectate = try c.decodeIfPresent(Bool.self, forKey: .anyoneCanSpectate) ?? true
        minutesUntilSkipTurn = try c.decodeIfPresent(Int.self, forKey: .minutesUntilSkipTurn) ?? 60 * 24
        minutesUntilForceResign = try c.decodeIfPresent(Int.self, forKey: .minutesUntilForceResign) ?? 3 * 24 * 60
        minutesRecoveredPerTurn = try c.decodeIfPresent(Int.self, forKey: .minutesRecoveredPerTurn) ?? 60 * 24
        randomNumberOfPlayers = try c.decodeIfPresent(Bool.self, forKey: .randomNumberOfPlayers) ?? false
        minNumberOfPlayers = try c.decodeIfPresent(Int.self, forKey: .minNumberOfPlayers) ?? 3
        maxNumberOfPlayers = try c.decodeIfPresent(Int.self, forKey: .maxNumberOfPlayers) ?? 3
        randomNumberOfCityStates = try c.decodeIfPresent(Bool.self, forKey: .randomNumberOfCityStates) ?? false
        minNumberOfCityStates = try c.decodeIfPresent(Int.self, forKey: .minNumberOfCityStates) ?? 6
        maxNumberOfCityStates = try c.decodeIfPresent(Int.self, forKey: .maxNumberOfCityStates) ?? 6
        enableRandomNationsPool = try c.decodeIfPresent(Bool.self, forKey: .enableRandomNationsPool) ?? false
        randomNationsPool = try c.decodeIfPresent([String].self, forKey: .randomNationsPool) ?? []
        nuclearWeaponsEnabled = try c.decodeIfPresent(Bool.self, forKey: .nuclearWeaponsEnabled) ?? true
        noStartBias = try c.decodeIfPresent(Bool.self, forKey: .noStartBias) ?? false
        shufflePlayerOrder = try c.decodeIfPresent(Bool.self, forKey: .shufflePlayerOrder) ?? false
        mapMainType = try c.decodeIfPresent(String.self, forKey: .mapMainType) ?? "Generated"
        mapSizeName = try c.decodeIfPresent(String.self, forKey: .mapSizeName) ?? "Medium"   // Unciv MapParameters.mapSize = MapSize.Medium
        uncivNumberOfTiles = try c.decodeIfPresent(Int.self, forKey: .uncivNumberOfTiles)
        mapDescription = try c.decodeIfPresent(String.self, forKey: .mapDescription) ?? ""
        legendaryStart = try c.decodeIfPresent(Bool.self, forKey: .legendaryStart) ?? false
        strategicBalance = try c.decodeIfPresent(Bool.self, forKey: .strategicBalance) ?? false
        randomMapShapes = try c.decodeIfPresent([String].self, forKey: .randomMapShapes) ?? ["Rectangular", "Hexagonal", "Flat Earth Hexagonal"]
        randomMapTypes = try c.decodeIfPresent([String].self, forKey: .randomMapTypes) ?? []
        randomMapSizes = try c.decodeIfPresent([String].self, forKey: .randomMapSizes) ?? []
        randomMapResources = try c.decodeIfPresent([String].self, forKey: .randomMapResources) ?? []
        tilesPerBiomeArea = try c.decodeIfPresent(Int.self, forKey: .tilesPerBiomeArea) ?? 6
        maxCoastExtension = try c.decodeIfPresent(Int.self, forKey: .maxCoastExtension) ?? 3
        elevationExponent = try c.decodeIfPresent(Double.self, forKey: .elevationExponent) ?? 0.7
        temperatureIntensity = try c.decodeIfPresent(Double.self, forKey: .temperatureIntensity) ?? 0.6
        vegetationRichness = try c.decodeIfPresent(Double.self, forKey: .vegetationRichness) ?? 0.4
        rareFeaturesRichness = try c.decodeIfPresent(Double.self, forKey: .rareFeaturesRichness) ?? 0.05
        waterThreshold = try c.decodeIfPresent(Double.self, forKey: .waterThreshold) ?? 0
        temperatureShift = try c.decodeIfPresent(Double.self, forKey: .temperatureShift) ?? 0
        mapWidth = try c.decodeIfPresent(Int.self, forKey: .mapWidth) ?? 44
        mapHeight = try c.decodeIfPresent(Int.self, forKey: .mapHeight) ?? 30
        playerNation = try c.decodeIfPresent(String.self, forKey: .playerNation) ?? "Rome"
        opponentCount = try c.decodeIfPresent(Int.self, forKey: .opponentCount) ?? 3
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0
        difficulty = try c.decodeIfPresent(String.self, forKey: .difficulty) ?? "Prince"
        speed = try c.decodeIfPresent(String.self, forKey: .speed) ?? "Quick"   // Unciv Speed.DEFAULT
        baseRuleset = try c.decodeIfPresent(String.self, forKey: .baseRuleset) ?? Ruleset.baseRulesetName   // Unciv GameParameters.baseRuleset = Civ_V_GnK
        mapType = try c.decodeIfPresent(String.self, forKey: .mapType) ?? "Pangaea"   // Unciv MapParameters.type = MapType.pangaea
        barbarians = try c.decodeIfPresent(Bool.self, forKey: .barbarians) ?? true
        victoryTypes = try c.decodeIfPresent(Set<String>.self, forKey: .victoryTypes) ?? ["Domination", "Scientific", "Cultural", "Time", "Diplomatic"]
        religionEnabled = try c.decodeIfPresent(Bool.self, forKey: .religionEnabled) ?? true
        espionageEnabled = try c.decodeIfPresent(Bool.self, forKey: .espionageEnabled) ?? false   // Unciv GameParameters.espionageEnabled
        worldWrap = try c.decodeIfPresent(Bool.self, forKey: .worldWrap) ?? false
        humanPlayers = try c.decodeIfPresent(Int.self, forKey: .humanPlayers) ?? 1
        mods = try c.decodeIfPresent([String].self, forKey: .mods) ?? []
        customMap = try c.decodeIfPresent(String.self, forKey: .customMap)
        isOnline = try c.decodeIfPresent(Bool.self, forKey: .isOnline) ?? false
        gameId = try c.decodeIfPresent(String.self, forKey: .gameId)
        ragingBarbarians = try c.decodeIfPresent(Bool.self, forKey: .ragingBarbarians) ?? false
        oneCityChallenge = try c.decodeIfPresent(Bool.self, forKey: .oneCityChallenge) ?? false
        randomNation = try c.decodeIfPresent(Bool.self, forKey: .randomNation) ?? false
        cityStateCount = try c.decodeIfPresent(Int.self, forKey: .cityStateCount) ?? -1
        noCityRazing = try c.decodeIfPresent(Bool.self, forKey: .noCityRazing) ?? false
        ancientRuins = try c.decodeIfPresent(Bool.self, forKey: .ancientRuins) ?? true
        naturalWonders = try c.decodeIfPresent(Bool.self, forKey: .naturalWonders) ?? true
        startingEra = try c.decodeIfPresent(String.self, forKey: .startingEra) ?? ""
        mapShape = try c.decodeIfPresent(String.self, forKey: .mapShape) ?? "Rectangular"
        seaLevel = try c.decodeIfPresent(String.self, forKey: .seaLevel) ?? "Normal"
        temperature = try c.decodeIfPresent(String.self, forKey: .temperature) ?? "Normal"
        rainfall = try c.decodeIfPresent(String.self, forKey: .rainfall) ?? "Normal"
        resourceSetting = try c.decodeIfPresent(String.self, forKey: .resourceSetting) ?? "Default"
        maxTurns = try c.decodeIfPresent(Int.self, forKey: .maxTurns) ?? 500
        if maxTurns <= 0 { maxTurns = 500 }   // older saves wrote 0 for "speed default"
    }
}
