// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The complete, serialisable game state plus all rules queries that read it.
/// Unciv ThreatManager.ClosestEnemyTileData - a mutable object held by reference in the cache.
final class ThreatClosestEnemyTileData {
    var distanceSearched: Int
    var tilesWithEnemies: [(tile: HexCoord, distance: Int)]
    init(_ distanceSearched: Int, _ tilesWithEnemies: [(tile: HexCoord, distance: Int)]) { self.distanceSearched = distanceSearched; self.tilesWithEnemies = tilesWithEnemies }
}

final class GameState: Codable {
    var settings: GameSettings
    var map: GameMap
    var civs: [Civilization]
    var cities: [City] { didSet { visGen &+= 1 } }
    var units: [Unit] { didSet { visGen &+= 1 } }
    /// Bumped on every unit/city mutation; keys the visibility and reachability caches below.
    var visGen: Int = 0
    var visibleCache: [Int: (Int, Set<HexCoord>)] = [:]
    var unitIndexGen: Int = -1
    var unitsByTile: [HexCoord: [Int]] = [:]
    var settlerBaseTileMap: [Int: [HexCoord: Double]] = [:]
    var reachCache: [Int: (Int, HexCoord, Set<HexCoord>)] = [:]
    var enemyProximityCache: [ProximityKey: Set<HexCoord>] = [:]
    var electionsHeldCount = 0, revoltSpawnCount = 0   // transient autoplay diagnostics (not saved)
    /// Unciv GameInfo.unitNamesTaken: a historical name is used once (UniqueTriggerActivation OneTimeUnitGetsName). A
    /// saved field there, so ours is saved too - a load, the undo checkpoint, the online download and the Next Turn clone
    /// all come back through init(from:); a save from before it has none (Unciv's `ArrayList<String>()` default).
    var unitNamesTaken: Set<String> = []
    /// Unciv UnitManager.nextPotentiallyDueAt (per civ id): where the "Next unit" round-robin continues in the civ's
    /// unit list. Only that button moves it, so an AI's stays 0; UnitManager.addUnit/removeUnit turn the list to start
    /// there and reset it (rotateCivUnitsToNextDue). A private field Unciv never saves: 0 after a load. Not saved.
    var nextPotentiallyDueAt: [Int: Int] = [:]
    var turn: Int = 1
    var nextId: Int = 1
    var outcome: GameOutcome? = nil
    var rng: SeededRandom
    var combatTrace: [(String, Double)]? = nil   // transient: filled by combatModifiers()
    /// Unciv MapUnit.destroy() leaves the object alive for whoever still holds it: Battle keeps asking a
    /// destroyed defender for its health (0), civ, tile and name after `takeDamage` killed it. Units removed
    /// by `destroyUnit` are kept here, as they were at that moment, so a Combatant can still answer. Transient.
    var battleGraveyard: [Int: Unit] = [:]
    /// Unciv MapUnit.isPreparingAirSweep() (action == AirSweep) while AirInterception.airSweep fights. Transient.
    var airSweepingUnitId: Int? = nil
    /// Unciv Battle.automateCityConquer decides whether to liberate BEFORE the city changes hands; the
    /// decision is handed to the capture through this. Transient.
    var conquestLiberationDecision: Bool? = nil
    var deals: [Deal] = []
    /// Unciv DiplomacyManager.trades, whole, for the Trades overview (TradeRecord)
    var tradeRecords: [TradeRecord] = []
    var unVoteTurn: Int = 0
    var diplomaticVictoryVotesCast: [Int: Int] = [:]   // Unciv GameInfo.diplomaticVictoryVotesCast: voter -> chosen civ (-1 = abstained)
    var diplomaticVictoryVotesProcessed = false
    var victoryData: VictoryRecord? = nil   // Unciv GameInfo.victoryData: winner, victory type and turn
    var oneMoreTurnMode = false   // Unciv GameInfo.oneMoreTurnMode: keep playing after a victory, no further victory checks
    var currentHumanIndex: Int = 0
    /// Unciv `CivInfoStatsForNextTurn.happiness`: ONE field, `var happiness = 0`, written only by
    /// updateStatsForNextTurn and read by everything a conditional asks about happiness. We had two of them
    /// holding the same number, and a reader that computed the value when neither had been written.
    var happinessCache: [Int: Int] = [:]
    /// VP: CvGame yield medians for needs-based happiness (VP/VPNeeds.swift). Saved; zero in a save from before them.
    var vpMedians = VPMedians()
    var vpLeague = VPLeagueState()   // VP: VP/VPLeague.swift
    /// Guards the stats refresh that a resource change triggers, so the breakdown it computes - which reads the
    /// resources again - cannot re-enter it.
    var resourceStatsUpdateInProgress = false
    var civUniquesCache: [Int: [Unique]] = [:]
    /// Unciv CityReligionManager.followers (transient, per city id): see `followers(of:)`. Not saved.
    var religionFollowersCache: [Int: [String: Int]] = [:]
    /// Unciv `followers` is a Counter too: its insertion order (the pressures walk, then each extra citizen appended) is what getMajorityReligionName breaks a tie with.
    /// validateConstructions' city under test, with its queue as far as it has been rebuilt (see countConstructedObjects).
    /// The game's own, not saved: Unciv's validateConstructionQueue works on its CityConstructions, so a turn played on a
    /// clone in the background never sees a probe the world screen's game made, nor the other way round.
    var constructionProbe: City? = nil
    /// Unciv Unique.getMultiplied's guard against counting that collects uniques again (see `multiplied`). The game's own,
    /// not saved, for the same reason as constructionProbe.
    var expandingMultipliers = false
    /// Guards trigger chains such as "Free [Warrior] appears <upon gaining a [Warrior] unit>" against endless recursion
    /// (see unitGainedTriggers). The game's own, not saved.
    var triggerDepth = 0
    /// Unciv AutoPlay.autoPlayTurnInProgress, for the game being automated: true while AutoPlay plays the player's own
    /// turn on it (TurnManager.automateTurn, GameController.automatePlayer) - on the turn's thread, while the main thread
    /// shows a copy of the game. The game's own, so the main thread's reads of the copy and the turn thread's of this game
    /// never share a flag. Not saved: Next Turn's clone starts without it.
    var autoPlayTurnInProgress = false
    /// Unciv `AutoPlay.turnsToAutoPlay > 0` while Next Turn's clone plays the turn: the multi-turn AutoPlay has turns left
    /// after this one - its job counts the turn down (endTurnMultiturnAutoPlay) before the GL thread's worldScreen.nextTurn()
    /// starts the clone's walk (NextTurnButton.kt:46-50), and "AutoPlay End Turn" stops AutoPlay before it (AutoPlayMenu.kt:
    /// 44-50). GameController.endTurn sets it on the game that plays the turn for the walk only; the game handed to the world
    /// screen has it false again. Read once as the turn starts: a Stop pressed during the walk counts from the next turn on
    /// (Unciv's walk reads turnsToAutoPlay as it goes, so there a Stop takes from wherever the walk has got to). Not saved.
    var autoPlayGoesOn = false
    /// Unciv `civInfo.isAIOrAutoPlaying()` for a human civ, asked beside `isPlayer`: the headless `--autoplay` run
    /// (epochsAutoplay, where the player is played as an AI) or this game's AutoPlay turn in progress - the viewing civ while
    /// AutoPlay automates it. Never the civs of the clone a turn is played on: Unciv compares the world screen's own civ
    /// object (`selectedGameView.civView.getCiv() == this`, Civilization.kt:426), which the clone's are not.
    var automatingPlayer: Bool { epochsAutoplay || autoPlayTurnInProgress }
    /// Unciv `Civilization.isAIOrAutoPlaying()` (Civilization.kt:422-427), asked of the civ: an AI; every civ in the
    /// headless run (epochsAutoplay, `gameInfo.isSimulation()`'s counterpart: the player is played as an AI); otherwise
    /// only the world screen's viewing civ - `selectedGameView.civView.getCiv() == this`, the player of this game - while
    /// AutoPlay plays its turn on it (autoPlayTurnInProgress). A hot-seat human AutoPlay does not automate is a human
    /// meanwhile, and no civ of the clone a turn is walked on counts (its civs are not the world screen's).
    func isAIOrAutoPlaying(_ civId: Int) -> Bool {
        guard let c = civ(civId) else { return true }
        if !c.isPlayer || epochsAutoplay { return true }
        return autoPlayTurnInProgress && civId == playerId
    }
    /// Unciv `worldScreen.autoPlay.isAutoPlaying()` (AutoPlay.kt:68, `turnsToAutoPlay > 0 || autoPlayTurnInProgress`), which
    /// asks no civ: also true through the clone's walk while the multi-turn AutoPlay has turns left (autoPlayGoesOn).
    var autoPlaying: Bool { epochsAutoplay || autoPlayTurnInProgress || autoPlayGoesOn }
    /// Unciv `isAutoPlayingAndFullAutoPlayAI()` (AutoPlay.kt:70): autoPlaying and the fullAutoPlayAI setting (true unless a
    /// stored setting says otherwise - its AutomationTab switch is commented out in 4.22.1). The headless run counts as full.
    var autoPlayingFullAI: Bool { epochsAutoplay || ((autoPlayTurnInProgress || autoPlayGoesOn) && UserSettings.fullAutoPlayAI) }
    // (Sites whose Unciv counterpart asks only `isHuman()` / `isAI()` / `isCurrentPlayer()` - which AutoPlay never changes -
    // ask `epochsAutoplay` alone: in the headless run the player is an AI, under AutoPlay it stays a human.)
    var religionFollowersOrderCache: [Int: [String]] = [:]
    /// Unciv Religion.buildingsPurchasableByBeliefs (`by lazy`, per religion name): fixed at the first read after a
    /// load or after the last human Next Turn (WorldScreen.nextTurn clones GameInfo, which makes new Religion objects -
    /// uncivNextTurnTransients), so a belief added since (enhancing, free beliefs) does not show in it. Not saved.
    var religionBuildingsPurchasableCache: [String: [String]] = [:]
    /// Unciv TechManager.researchedTechnologies (transient, per civ id): addTechnology appends the tech every time,
    /// so a continually researched one (Future Tech) repeats in it, while setTransients rebuilds it from the
    /// techsResearched set - one each - after a load, and after WorldScreen.nextTurn's clone (uncivNextTurnTransients).
    /// The turn dump's city-state line and the Technologies ranking (statForRanking) read it. Not saved.
    var researchedTechnologyRepeats: [Int: [String: Int]] = [:]
    /// Unciv `tech.researchedTechnologies.size`: the researched set plus every repeat added since the last load.
    func researchedTechnologiesSize(_ civ: Civilization) -> Int { civ.techs.count + (researchedTechnologyRepeats[civ.id]?.values.reduce(0, +) ?? 0) }
    /// Unciv Civilization.viewableInvisibleUnitsTiles (transient, per civ id): see canSeeInvisibleUnit. Not saved.
    var viewableInvisibleUnitsTilesCache: [Int: [HexCoord: Set<String>]] = [:]
    /// Unciv MapUnit.viewableTiles as updateVisibleTiles last stored it (transient, per unit id): the "before" of
    /// its skip rule, kept apart from unitViewCache, which any read refreshes to the unit's current tile.
    var unitStoredViewableTiles: [Int: Set<HexCoord>] = [:]
    /// Unciv Civilization.viewableTiles as updateViewableTiles last stored it (transient, per civ id): updateExploration
    /// writes it where Unciv runs updateViewableTiles, and visibleTiles(for:) - every `tile.isVisible(civ)` and
    /// `civ.viewableTiles` reader - returns it, so a city-state sees its ally's cities only from its next update, not
    /// the moment the ally takes one. Not saved; every load and Next Turn writes it again (updateCivilizationState).
    var civStoredViewableTiles: [Int: Set<HexCoord>] = [:]
    /// Unciv MapUnitCache.cannotEnterOceanTiles (transient, per unit id): see updateUnitUniquesCache. Not saved.
    var unitCannotEnterOceanTiles: [Int: Bool] = [:]
    /// Unciv `Civilization.summarizedCivResourceSupply`: the per-resource supply as `updateCivResources` last
    /// left it. `getCivResourceSupply()` returns this FIELD and everything else - "can we build this unit",
    /// the happiness luxuries, the trade offers, the stockpile banking - reads it through that. It is
    /// deliberately stale between the twenty-odd events that rebuild it. By name here, in order below.
    var storedResourceSupply: [Int: [String: Int]] = [:]
    var storedSummarizedSupply: [Int: ResourceSupplyList] = [:]
    /// Unciv `Civilization.detailedCivResources`: the same supply with each entry's ORIGIN kept, so a trade
    /// can be told from a city. Also written only by `updateCivResources`, which compares its new list with
    /// this one (List equality - resource, origin and amount, row by row) to decide whether anything changed.
    var storedDetailedSupply: [Int: ResourceSupplyList] = [:]
    var storedDetailedResources: [Int: [(resource: String, origin: String, amount: Int)]] = [:]
    /// Unciv `Civilization.detailedCivResources`: the supply as `updateCivResources` last left it, and the
    /// thing its "did anything change?" test compares against. Ours used the live cache for that, and the live
    /// cache is keyed on a generation counter that any mutation bumps - so "before" was usually missing and the
    /// test fired on a cold cache rather than on a change, five times a turn.
    ///
    /// The reference compares the DETAILED list - `resource, origin, amount` per row, with List equality - so
    /// supply moving between origins at an unchanged total still counts as a change. Ours compared the
    /// summarized totals and slept through those. One row per entry, in order, is that comparison.
    var lastCivResourceCounts: [Int: [String]] = [:]
    /// Unciv `Civilization.hasActiveEnemyMovementPenalty`: `hasUnique(EnemyUnitsSpendExtraMovement)` as
    /// updateHasActiveEnemyMovementPenalty last found it - on load, when a building with it is added, and at the
    /// end of the civ's turn. MovementCost asks it before it looks at the uniques themselves.
    var hasActiveEnemyMovementPenalty: [Int: Bool] = [:]
    var goldOutputCache: [Int: Double] = [:]
    var cityTileUniqueCache: [Int: (String, [Unique])] = [:]
    var netGoldCache: [Int: (Int, Double)] = [:]
    /// Unciv City.cityStats.currentCityStats: THE city's stats. One object per city, written by
    /// `cityStats.update()` at the points Unciv calls it - the city's turn start, a building, a border, a
    /// population reassignment, a policy, a golden age, a conquest - and read by everyone else in between.
    /// It is deliberately stale for everything else: the gold that buys a building and the construction the
    /// city automation queues do not touch it, so the turn spends the yields it had when the turn began.
    /// We used to recompute on demand and emulate one axis of that staleness; this is the cache itself.
    var storedCityStats: [Int: CityStats] = [:]
    /// Unciv City.neighboringCities is `by lazy` and `@delegate:Transient`: the list is built the first time a
    /// city is asked for it and then FROZEN for the life of that City object - it does not notice cities founded
    /// or explored later, and it comes back only when a save is loaded. Ours recomputed it on every call, so
    /// France counted 14 neighbouring foreign cities where Unciv still counted 5, and `tryPrepare` was deciding
    /// which cities to defend from a different list.
    var neighboringCitiesCache: [Int: [Int]] = [:]
    /// The City objects Unciv's lazy `neighboringCities` lists still hold after the city was destroyed: frozen as
    /// they were at destruction (their civ is whoever razed them). Transient, like the lists themselves.
    var destroyedCitySnapshots: [Int: City] = [:]
    /// Unciv MapUnit.viewableTiles is a stored set, recomputed by updateVisibleTiles only when the unit is put on a
    /// tile, promoted, captured, upgraded or loaded - never when the terrain around it changes. A forest cleared
    /// next to a fortified archer stays opaque to it until it moves. Keyed on the unit's tile and promotion count;
    /// entering a tile drops the entry (MapUnit.putInTile).
    var unitViewCache: [Int: (coord: HexCoord, promotions: Int, tiles: Set<HexCoord>)] = [:]
    /// Units inside MapUnit.moveThroughTile before its closing updateVisibleTiles: Unciv's `unit.viewableTiles` is a
    /// field, still the tiles seen from where the unit came from, so a civ-wide view refreshed in that window (a camp
    /// cleared completes a quest, the city-state allies us) does not yet see what the unit sees from its new tile.
    var unitViewFrozen: Set<Int> = []
    /// Unciv UnitMovement.pathfindingCache (one PathfindingCache per MapUnit, transient): see UnitMovement.swift.
    var pathfindingCache: [Int: UnitPathfindingCache] = [:]
    /// Unciv CivInfoTransientCache.cityStateBonusUniqueMaps: the friend/ally bonuses a major civ enjoys are a
    /// STORED list, rebuilt only by `updateCivResources()` - the civ's turn start, a technology, a policy, a
    /// building, a trade, an ally changing. Influence crossing 30 mid-turn does not change what the cities are
    /// earning until one of those happens. We recomputed the list on every read, so Persepolis was fed by a
    /// Maritime city-state a full turn before Unciv's was.
    var cityStateBonusCache: [Int: [Unique]] = [:]
    /// Unciv Civilization.cachedMilitaryMight: the Force ranking is computed once and kept until
    /// `resetMilitaryMightCache()`, which runs at the END of that civilization's turn and again when the world
    /// turn records its ranking history. So while a civ is taking its turn it reads LAST turn's strength - the
    /// unit its city finished this morning is not in the number yet. We recomputed it on every call.
    var militaryMightCache: [Int: Int] = [:]
    /// Unciv Civilization.threatManager.distanceToClosestEnemyTiles: per civ, keyed by tile; cleared only in
    /// TurnManager.startTurn. Transient, as in Unciv.
    var threatManagerCache: [Int: [HexCoord: ThreatClosestEnemyTileData]] = [:]
    /// Unciv TileMap.tileMatrix.size, sized once in setTransients; keyed on the map's grid so a replaced map
    /// recomputes it. Transient.
    var uncivTileMatrixSizeCache: (width: Int, height: Int, missing: Int, size: Int)? = nil

    func goldTrace(_ civId: Int, _ amount: Double, caller: String = #function) {
        if ProcessInfo.processInfo.environment["GOLDX"] != nil, amount != 0 { print("GOLDX t=\(turn) \(civ(civId)?.nation ?? "?") \(amount) by=\(caller)") }
    }

    private enum CodingKeys: String, CodingKey { case settings, map, civs, cities, units, turn, nextId, outcome, rng, deals, tradeRecords, unVoteTurn, currentHumanIndex, pendingOffers, pendingDemands, encampments, historyStartTurn, attackEvents, currentTurnStartTime, diplomaticVictoryVotesCast, diplomaticVictoryVotesProcessed, oneMoreTurnMode, victoryData, unitNamesTaken, diplomacyTurnDoneThisRound, vpMedians, vpLeague }
    var pendingDemands: [DemandRequest] = []
    /// Unciv GameInfo.historyStartTurn: the first turn the replay can show.
    var historyStartTurn: Int = 1
    /// Unciv AttackEvent log (AttackRecorder), newest last, capped.
    var attackEvents: [AttackEvent] = []
    /// Unciv GameInfo.currentTurnStartTime: when the player whose turn it is received it, in milliseconds.
    /// Multiplayer uses it to decide when an absent player may be skipped or made to resign.
    var currentTurnStartTime: Double = 0
    /// Transient per-turn timing (PROFILE output) and the split end-turn state.
    var turnAITime = 0.0, turnProcessTime = 0.0
    /// Unciv GameInfo.nextTurn's `playerIndex` while a turn is being walked (an index into uncivTurnOrder(), -1 right
    /// after the wrap), and whether this walk has wrapped the round. Transient: nil outside endTurnBegin...endTurnStep.
    var turnWalkIndex: Int? = nil
    var turnWalkWrapped = false
    var exploredBoundsCache: [Int: (Int, ExploredBounds)] = [:]
    var proximityCache: [Int: (Int, Int, Proximity)] = [:]
    var railroadCache: [Int: (Int, Set<Int>)] = [:]
    /// Unciv CivInfoTransientCache.citiesConnectedToCapitalToMediums (keys, as the reach of the capital's routes):
    /// written only by updateCitiesConnectedToCapital, read by isCapitalConnectedToCity. Transient, like Unciv's.
    var capitalReachCache: [Int: Set<HexCoord>] = [:]
    /// Unciv Civilization.neutralRoads (`@Transient HashSet<HexCoord>`), per civ: the unowned tiles whose roads the
    /// civ pays for. A STORED set, not "unowned tiles naming us as road owner": only Tile.setRoadStatus and
    /// Tile.setOwningCity(city) change it, and TileMap.setNeutralTransients rebuilds it on load. So a civ that
    /// upgrades another's neutral Road to Railroad joins it while the first builder stays in it until the next load.
    var neutralRoads: [Int: Set<HexCoord>] = [:]
    var encampments: [Encampment] = []
    var pendingOffers: [TradeOffer] = []
    /// Unciv bumps gameInfo.turns when the player cycle wraps, so every civ plays a round already carrying the new
    /// number. We run the barbarian turn at the END of the round, before our own counter moves, which leaves our
    /// `turn` one behind what Unciv reads there - and the state-based RNG is seeded with it. Measured, not guessed:
    /// on the same wander, with the same four candidate tiles, Unciv draws index 2 and `turn - 1` draws 0 while
    /// `turn` draws 2. Set only while the barbarians act.
    @Lenient var barbarianPhase: Bool = false
    /// Civs whose DiplomacyManager.nextTurn (their own endTurn) has already run in the round being played.
    /// A timed deal struck now starts counting down for them one round later than for the others. Unciv has no such set:
    /// each side's copy of the Peace Treaty trade counts its own ends of turn (DiplomacyTurnManager.nextTurnTrades), which
    /// its save keeps, where our peaceTreatyUntil is a turn number - so this is the other half of what that save keeps, and
    /// it is saved with the game (a load, the undo checkpoint, the online download and the Next Turn clone go on from it
    /// as Unciv's go on from the saved durations). A game whose file does not have it - an Unciv save, one of ours from
    /// before it was saved - reads it from where the walk stands (diplomacyTurnsDoneBeforeCurrentPlayer).
    var diplomacyTurnDoneThisRound: Set<Int> = []
    /// Unciv GameInfo.clone's trades: the Next Turn clone's copies hold the shown game's very TradeOffer objects (see
    /// SharedTradeOffers), so what the clone counts down the original reads counted down. Set on the clone an online game's
    /// turn is played on (GameController.endTurn) - the only original that stays shown after the clone has played, when
    /// its upload fails. Not saved.
    var sharedTradeOffers: SharedTradeOffers? = nil
    // Transient per-turn AI caches (not saved).
    /// Unciv Civilization.workerAutomationCache: one WorkerAutomation per civ, remade when the turn number moves on
    var workerAutomationCaches: [Int: WorkerAutomationState] = [:]
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decode(GameSettings.self, forKey: .settings)
        map = try c.decode(GameMap.self, forKey: .map)
        // Saves from before Tile.continent carry no ids: Unciv GameStarter's "saved map without continent data" -
        // assignContinents(Ensure), which only counts the stored ids when there are any
        map.assignContinents(.ensure)
        civs = try c.decode([Civilization].self, forKey: .civs)
        // Saves from before techsInProgress kept a single science pool for the current tech.
        for i in civs.indices where civs[i].scienceStored > 0 {
            if civs[i].techsInProgress.isEmpty, let cur = civs[i].currentTech { civs[i].techsInProgress[cur] = Int(civs[i].scienceStored) }
            civs[i].scienceStored = 0
        }
        // Saves from before cityStateResource: Mercantile city-states get their unique luxury
        let mercantileResources = Ruleset.shared.resources.values.filter { $0.uniques.contains("Can only be created by Mercantile City-States") }.map { $0.name }.sorted()
        for i in civs.indices where civs[i].isCityState && civs[i].cityStateResource == nil && !mercantileResources.isEmpty {
            if let t = civs[i].cityStateType, let type = Ruleset.shared.cityStateTypes[t], (type.friendBonusUniques + type.allyBonusUniques).contains("Provides a unique luxury") {
                civs[i].cityStateResource = mercantileResources[abs(civs[i].id) % mercantileResources.count]
            }
        }
        for i in civs.indices where civs[i].freeBeliefs > 0 {
            if civs[i].freeBeliefsByType.isEmpty { civs[i].freeBeliefsByType[civs[i].religionName == nil ? "Pantheon" : "Any"] = civs[i].freeBeliefs }
            civs[i].freeBeliefs = 0
        }
        cities = try c.decode([City].self, forKey: .cities)
        units = try c.decode([Unit].self, forKey: .units)
        turn = try c.decode(Int.self, forKey: .turn)
        nextId = try c.decode(Int.self, forKey: .nextId)
        outcome = try c.decodeIfPresent(GameOutcome.self, forKey: .outcome)
        rng = try c.decode(SeededRandom.self, forKey: .rng)
        deals = try c.decodeIfPresent([Deal].self, forKey: .deals) ?? []
        tradeRecords = (try? c.decodeIfPresent([TradeRecord].self, forKey: .tradeRecords)) ?? []   // a save from before them has none
        unVoteTurn = try c.decodeIfPresent(Int.self, forKey: .unVoteTurn) ?? 0
        diplomaticVictoryVotesCast = try c.decodeIfPresent([Int: Int].self, forKey: .diplomaticVictoryVotesCast) ?? [:]
        diplomaticVictoryVotesProcessed = try c.decodeIfPresent(Bool.self, forKey: .diplomaticVictoryVotesProcessed) ?? false
        oneMoreTurnMode = try c.decodeIfPresent(Bool.self, forKey: .oneMoreTurnMode) ?? false
        victoryData = try c.decodeIfPresent(VictoryRecord.self, forKey: .victoryData)
        vpMedians = (try? c.decodeIfPresent(VPMedians.self, forKey: .vpMedians)) ?? VPMedians()   // VP
        vpLeague = (try? c.decodeIfPresent(VPLeagueState.self, forKey: .vpLeague)) ?? VPLeagueState()   // VP
        unitNamesTaken = Set(try c.decodeIfPresent([String].self, forKey: .unitNamesTaken) ?? [])   // a save from before it has none
        pendingOffers = try c.decodeIfPresent([TradeOffer].self, forKey: .pendingOffers) ?? []
        pendingDemands = try c.decodeIfPresent([DemandRequest].self, forKey: .pendingDemands) ?? []
        encampments = try c.decodeIfPresent([Encampment].self, forKey: .encampments) ?? []
        // A Next Turn clone (nextTurnClone) is decoded on the turn's own thread while the world screen still shows the
        // original: it leaves the two globals alone, and GameController hands them over when the clone becomes the game
        let isNextTurnClone = decoder.userInfo[GameState.nextTurnCloneKey] as? Bool == true
        if !isNextTurnClone { HexCoord.wrapWidth = map.wrapX ? map.width : nil }
        currentHumanIndex = try c.decodeIfPresent(Int.self, forKey: .currentHumanIndex) ?? 0
        historyStartTurn = try c.decodeIfPresent(Int.self, forKey: .historyStartTurn) ?? 1
        attackEvents = try c.decodeIfPresent([AttackEvent].self, forKey: .attackEvents) ?? []
        currentTurnStartTime = try c.decodeIfPresent(Double.self, forKey: .currentTurnStartTime) ?? 0
        // Saved; a save from before it has the walk's position to go by (civs and currentHumanIndex are read by now)
        if let done = try c.decodeIfPresent([Int].self, forKey: .diplomacyTurnDoneThisRound) { diplomacyTurnDoneThisRound = Set(done) }
        else { diplomacyTurnDoneThisRound = diplomacyTurnsDoneBeforeCurrentPlayer() }
        if !isNextTurnClone { registerCoastalLookup() }
        // Unciv civInfo.setTransients → CityExpansionManager.setTransients: setOwningCity per tile. Not on a Next Turn clone
        // or an undo restore: those take over the game's neutralRoads (Civilization.clone shares the set) and run the pass
        // on it themselves (uncivNextTurnTransients, restoreUndoCheckpoint), where setOwningCity takes a road off the set
        // of the road owner the tile was saved with - run here first, the tile would already name its city's civ, and that
        // civ's carried set would lose the tile instead
        if !isNextTurnClone && decoder.userInfo[GameState.sharedNeutralRoadsKey] as? Bool != true { setOwningCityTransients() }
        setNeutralTransients()   // Unciv GameInfo.setTransients: tileMap.setNeutralTransients(), after the owners are known
        legacyResearchAgreementCosts()
        // Unciv GameInfo.setTransients → TileMap.setTransients: every civ's unit list is rebuilt from the tiles - on a load,
        // on WorldScreen.nextTurn's clone, on the undo checkpoint's restore
        orderUnitsAsTileTransients()
    }
    /// Tile.coastalLand ("Can only be built on [Coastal] tiles") needs the neighbours of the active map.
    func registerCoastalLookup() {
        GameMap.coastalLandLookup = { [weak self] c in
            guard let self else { return false }
            return self.map.isAdjacentToCoast(c)   // Unciv Tile.isAdjacentToCoast (a lazy, see GameMap)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if vpMedians != VPMedians() { try c.encode(vpMedians, forKey: .vpMedians) }   // VP
        if vpLeague != VPLeagueState() { try c.encode(vpLeague, forKey: .vpLeague) }   // VP
        try c.encode(settings, forKey: .settings); try c.encode(map, forKey: .map); try c.encode(civs, forKey: .civs)
        try c.encode(cities, forKey: .cities); try c.encode(units, forKey: .units); try c.encode(turn, forKey: .turn)
        try c.encode(nextId, forKey: .nextId); try c.encodeIfPresent(outcome, forKey: .outcome); try c.encode(rng, forKey: .rng)
        try c.encode(deals, forKey: .deals); try c.encode(tradeRecords, forKey: .tradeRecords); try c.encode(unVoteTurn, forKey: .unVoteTurn); try c.encode(currentHumanIndex, forKey: .currentHumanIndex); try c.encode(pendingOffers, forKey: .pendingOffers)
        try c.encode(pendingDemands, forKey: .pendingDemands); try c.encode(encampments, forKey: .encampments)
        try c.encode(historyStartTurn, forKey: .historyStartTurn); try c.encode(attackEvents, forKey: .attackEvents)
        try c.encode(currentTurnStartTime, forKey: .currentTurnStartTime)
        try c.encode(diplomaticVictoryVotesCast, forKey: .diplomaticVictoryVotesCast); try c.encode(diplomaticVictoryVotesProcessed, forKey: .diplomaticVictoryVotesProcessed); try c.encode(oneMoreTurnMode, forKey: .oneMoreTurnMode); try c.encodeIfPresent(victoryData, forKey: .victoryData)
        try c.encode(unitNamesTaken.sorted(), forKey: .unitNamesTaken)   // sorted: the file does not depend on the Set's hashing
        try c.encode(diplomacyTurnDoneThisRound.sorted(), forKey: .diplomacyTurnDoneThisRound)
    }

    var rs: Ruleset { Ruleset.shared }

    init(settings: GameSettings, map: GameMap, rng: SeededRandom) {
        self.settings = settings; self.map = map; self.civs = []; self.cities = []; self.units = []; self.rng = rng
        registerCoastalLookup()
    }

    func newId() -> Int { defer { nextId += 1 }; return nextId }

    // MARK: lookups
    var humans: [Civilization] { civs.filter { $0.isPlayer } }
    /// The human whose turn it is (hot-seat and online games cycle through several).
    var currentHuman: Civilization {
        let h = humans
        guard !h.isEmpty else { return civs[0] }
        return h[min(currentHumanIndex, h.count - 1)]
    }
    var currentHumanId: Int { currentHuman.id }
    /// The civ this device looks at and acts for: in online games always the local seat, otherwise the current human.
    var player: Civilization {
        if settings.isOnline, let mine = humans.first(where: { $0.playerUserId == Multiplayer.userId }) { return mine }
        return currentHuman
    }
    var playerId: Int { player.id }
    var isHotSeat: Bool { humans.count > 1 }
    func civ(_ id: Int) -> Civilization? { civs.first { $0.id == id } }
    func civIndex(_ id: Int) -> Int? { civs.firstIndex { $0.id == id } }
    func city(_ id: Int) -> City? { cities.first { $0.id == id } }
    func cityIndex(_ id: Int) -> Int? { cities.firstIndex { $0.id == id } }
    func unit(_ id: Int) -> Unit? { units.first { $0.id == id } }
    func unitIndex(_ id: Int) -> Int? { units.firstIndex { $0.id == id } }
    func city(at c: HexCoord) -> City? { cities.first { $0.coord == c } }
    /// Units on a tile via a lazily rebuilt index (rebuilt whenever the units array changed).
    func units(at c: HexCoord) -> [Unit] {
        if unitIndexGen != visGen {
            unitsByTile.removeAll(keepingCapacity: true)
            for (i, u) in units.enumerated() { unitsByTile[u.coord, default: []].append(i) }
            // Unciv Tile.getUnits: militaryUnit, then civilianUnit, then airUnits - not the order the units were made in.
            // (Our air units keep the global order; Unciv's list is in the order they landed.)
            for (c, idx) in unitsByTile where idx.count > 1 {
                func rank(_ u: Unit) -> Int { u.def.isAir ? 2 : u.isCivilian ? 1 : 0 }
                unitsByTile[c] = idx.enumerated().sorted { a, b in
                    let ra = rank(units[a.element]), rb = rank(units[b.element])
                    return ra != rb ? ra < rb : a.offset < b.offset
                }.map { $0.element }
            }
            unitIndexGen = visGen
        }
        guard let idx = unitsByTile[c] else { return [] }
        return idx.map { units[$0] }
    }
    func units(of civId: Int) -> [Unit] { units.filter { $0.civId == civId } }
    /// Unciv TileMap.setTransients → Tile.setUnitTransients → MapUnit.assignOwner → UnitManager.addUnit: a civ's unit list
    /// (UnitManager.unitList, which getCivUnits() and so every automation walks) is a transient, rebuilt on each load and
    /// each clone the game is played on - WorldScreen.nextTurn's every human turn, the undo checkpoint's - in tileList
    /// order, on each tile its militaryUnit, then its civilianUnit, then its airUnits as they landed (Tile.getUnits); a unit
    /// made since is added at the end. Ours keeps all civs' units in one list and reads a civ's off it in order, so the
    /// whole list is put in that order (stable: the air units of a tile keep theirs).
    func orderUnitsAsTileTransients() {
        guard units.count > 1 else { return }
        let order = map.uncivTileListOrder()
        var rank = [Int](repeating: Int.max, count: map.tiles.count)
        for (r, i) in order.enumerated() where i >= 0 && i < rank.count { rank[i] = r }
        let keyed = units.enumerated().map { (i, u) -> (tile: Int, slot: Int, i: Int) in
            let tile = map.index(of: u.coord).map { rank[$0] } ?? Int.max
            return (tile, u.def.isAir ? 2 : u.isCivilian ? 1 : 0, i)
        }
        let sorted = keyed.sorted { a, b in a.tile != b.tile ? a.tile < b.tile : a.slot != b.slot ? a.slot < b.slot : a.i < b.i }
        if sorted.enumerated().contains(where: { $0.offset != $0.element.i }) { units = sorted.map { units[$0.i] } }
    }
    /// Unciv `Civilization.cities`: the civ's own list, in its own order.
    func cities(of civId: Int) -> [City] {
        guard let ci = civIndex(civId) else { return [] }
        return civs[ci].cityIds.compactMap { city($0) }
    }

    /// Unciv `oldCiv.cities = oldCiv.cities.withoutItem(city)` then `newCiv.cities = newCiv.cities.withItem(city)`.
    func registerCity(_ cityId: Int, with civId: Int) {
        for i in civs.indices { civs[i].cityIds.removeAll { $0 == cityId } }
        if let i = civIndex(civId) { civs[i].cityIds.append(cityId) }
    }

    /// Unciv `civ.cities = civ.cities.withoutItem(city)` when a city is destroyed.
    func unregisterCity(_ cityId: Int) {
        for i in civs.indices { civs[i].cityIds.removeAll { $0 == cityId } }
    }

    func capital(of civId: Int) -> City? { cities.first { $0.civId == civId && $0.isCapital } ?? cities(of: civId).first }

    func areAtWar(_ a: Int, _ b: Int) -> Bool { a != b && (civ(a)?.isAtWar(with: b) ?? false) }

    /// A stable summary of the whole game state, for telling two runs apart turn by turn. Everything is
    /// read in a fixed order and hashed with FNV-1a, since Swift's own hashing is seeded per process.
    static func fingerprint(_ s: GameState) -> String {
        let p = fingerprintParts(s)
        return "\(p.civs)/\(p.cities)/\(p.units)"
    }

    /// The same, split three ways, so a divergence can be pinned to civs, cities or units.
    static func fingerprintParts(_ s: GameState) -> (civs: String, cities: String, units: String) {
        var h: UInt64 = 0xcbf29ce484222325
        func feed(_ text: String) {
            for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        }
        func feed(_ value: Int) { feed(String(value)) }
        func feed(_ value: Double) { feed(String(Int((value * 100).rounded()))) }
        func take() -> String { let out = String(h, radix: 16); h = 0xcbf29ce484222325; return out }
        feed(s.turn)
        for civ in s.civs.sorted(by: { $0.id < $1.id }) {
            feed(civ.id); feed(civ.gold); feed(civ.scienceStored); feed(civ.cultureStored); feed(civ.faithStored)
            feed(civ.techs.sorted().joined(separator: ",")); feed(civ.policies.sorted().joined(separator: ","))
            feed(civ.atWarWith.sorted().map(String.init).joined(separator: ","))
        }
        let civsHash = take()
        for city in s.cities.sorted(by: { $0.id < $1.id }) {
            feed(city.id); feed(city.civId); feed(city.population); feed(city.foodStored); feed(city.productionStored)
            feed(city.coord.q); feed(city.coord.r)
            feed(city.buildings.sorted().joined(separator: ","))
            feed(city.workedTiles.sorted { ($0.q, $0.r) < ($1.q, $1.r) }.map { "\($0.q):\($0.r)" }.joined(separator: ","))
            feed(city.currentProduction?.name ?? "-")
        }
        let citiesHash = take()
        for unit in s.units.sorted(by: { $0.id < $1.id }) {
            feed(unit.id); feed(unit.civId); feed(unit.name); feed(unit.coord.q); feed(unit.coord.r)
            feed(unit.health); feed(unit.movementLeft); feed(unit.promotions.sorted().joined(separator: ","))
        }
        return (civsHash, citiesHash, take())
    }

    // MARK: city stats
    struct CityStats {
        var tileYields = Stats()
        var buildingYields = Stats()
        var total = Stats()
        var foodSurplus: Double = 0
        var foodForNextTurn: Double = 0   // Unciv City.foodForNextTurn: the surplus as the turn will actually bank it
        var maintenance: Int = 0
        var growthTurns: Int? = nil
        var happinessPenalty = false
        var growthPercent: Double = 0
        var nullifiesGrowth = false   // Unciv NullifiesGrowth: the city cannot grow, so surplus food has no growth value
        var percentBonus = Stats()   // Unciv CityStats.statPercentBonusTree totals
        var tradeRoutes = Stats()
        /// Unciv `City.cityStats.happinessList`: this city's contribution to the empire's happiness, written
        /// when the city's stats are updated and read by `getHappinessBreakdown` as it is. A row only reaches
        /// the empire when the city it belongs to is next updated, which is why the order of the city loop
        /// decides what any given city sees.
        var happinessRows: [(String, Double)] = []
        /// Unciv `City.cityStats.finalStatList`: the city's final stats by source, in the order they were put in,
        /// as its last `update()` left them. getStatMapForNextTurn adds these, entry by entry, into the empire's map.
        var finalStatList: [(String, Stats)] = []
    }
}

extension GameState {
    /// Unciv GameInfo.updateCivilizationState, the end of every load (GameInfo.setTransients). The city-states go
    /// first ("the happiness of major civ depends on it"), and for each civ: updateSightAndResources and
    /// updateCitiesConnectedToCapital(initialSetup = true); then every city's updateTileStats and
    /// updateCityHappiness ("we need to determine the GLOBAL happiness state in order to determine the city stats");
    /// then, city by city, an empty construction queue is refilled, a demanded resource the ruleset does not know is
    /// cleared, and cityStats.update() runs - updateCivStats included, so the civ's happiness and statsForNextTurn
    /// follow each city. Ours stopped after the connections: every city's stored stats were filled lazily by
    /// whoever asked first, at whatever happiness the civ had then (none of the cities' rows), and a puppet saved
    /// with an empty queue stayed idle until its turn.
    /// Each civ's turn in the walk opens with its units' updateVisibleTiles(false), updateOurTiles and the sight half
    /// of updateSightAndResources, as Unciv's does; the importer used to run updateExploration for every civ, in list
    /// order, before the walk began. Run on every load and on every Next Turn (uncivNextTurnTransients).
    func updateCivilizationState() {
        for civ in civs.filter({ $0.isCityState }) + civs.filter({ !$0.isCityState }) {   // Unciv sortedByDescending { isCityState }: stable
            // `for (unit in civInfo.units.getCivUnits()) unit.updateVisibleTiles(false)`: each unit's viewableTiles is
            // worked out again from where it stands, and stored - with no civ-wide update (updateCivViewableTiles = false)
            let civSight = civUniques(civ.id).filter { $0.pattern == "[] Sight" }
            for u in units(of: civ.id) {
                unitViewCache[u.id] = nil
                unitStoredViewableTiles[u.id] = unitViewableTiles(u, civSight: civSight)
            }
            visibleCache[civ.id] = nil   // the civ's view is built from its units' (visibleTiles(for:))
            updateOurTiles(civ.id)   // Unciv civInfo.cache.updateOurTiles(): updateViewableTiles, then updateCivResources
            // Unciv civInfo.cache.updateSightAndResources(): updateViewableTiles, updateHasActiveEnemyMovementPenalty, updateCivResources
            updateExploration(for: civ.id)
            updateHasActiveEnemyMovementPenalty(civ.id)   // updateSightAndResources: before updateCivResources
            updateCivResources(civ.id)
            updateCitiesConnectedToCapital(civ.id, initialSetup: true)
            // `city.cityStats.updateTileStats(); city.cityStats.updateCityHappiness(city.cityConstructions.getStats())`:
            // only the tile stats and the happiness list are written - the city's currentCityStats is left as it is
            // (a fresh load's is empty), and happinessBreakdown reads every city's list from the next update on.
            for city in cities(of: civ.id) {
                guard let m = Epochs.CityStats(city: city, state: self) else { continue }
                m.updateTileStatsAndHappiness()
                var stored = storedCityStats[city.id] ?? CityStats()
                stored.happinessRows = m.happinessList
                stored.tileYields = m.statsFromTiles   // Unciv CityStats.statsFromTiles
                storedCityStats[city.id] = stored
            }
            for city in cities(of: civ.id) {
                guard let ci = cityIndex(city.id) else { continue }
                // Unciv `constructionQueue.isEmpty()`: nothing being built, no perpetual, nothing queued behind
                if cities[ci].currentProduction == nil && cities[ci].convertProductionTo.isEmpty && cities[ci].productionQueue.isEmpty {
                    chooseNextConstructionIfAutomated(cityId: city.id)   // Unciv CityConstructions.chooseNextConstruction, gate included
                }
                if let cj = cityIndex(city.id), rs.resources[cities[cj].demandedResource] == nil { cities[cj].demandedResource = "" }
                updateCityStats(city.id, updateCivStats: true, reason: "updateCivilizationState")   // Unciv cityStats.update()
            }
        }
    }

    /// A load only: Unciv's save writes City.tiles, workedTiles and lockedTiles as arrays in their walk order, and the
    /// reader fills a new HashSet from each, tile by tile - the table the size implies, whatever larger table a
    /// `withoutItem` copy had left the saved set in. The Next Turn clone keeps the very sets (`toReturn.tiles = tiles`,
    /// `workedTiles`, `lockedTiles`), so reapplyJavaHashSetOrders leaves them alone.
    func rebuildCityTileSetsAsLoaded() {
        for i in cities.indices {
            let city = cities[i]
            cities[i].tilesOrder = uncivTileWalk(city); cities[i].tilesTable = 0
            cities[i].workedTiles = workedTilesWalk(city); cities[i].workedTilesTable = 0
            cities[i].lockedTilesOrder = lockedTilesWalk(city); cities[i].lockedTilesTable = 0
        }
    }

    /// Unciv PolicyManager / TechManager / CityConstructions.setTransients, run on every load and on every Next Turn's
    /// clone: policyUniques and techUniques are filled walking the `HashSet<String>` of adoptedPolicies and
    /// techsResearched, and builtBuildingObjects is rebuilt from the builtBuildings set the same way - one copy each, so
    /// a second Palace does not survive. addTechnology, adoption and addBuilding append from there. The barbarians'
    /// researchedTechnologies (techUniqueOrder, see transientTechs) is that walk of whatever techsResearched
    /// BarbarianManager last wrote. Ours kept research, adoption and build order in every list until the game was
    /// imported again, so a Socialism maintenance sum or a tie between specialists walked another order than Unciv's.
    /// javaHashMapOrder sorts stably by bucket and our lists are in insertion order, so two names sharing a bucket keep
    /// their order, as HashSet.addAll (the clone) and the save reader's one-by-one add do.
    func reapplyJavaHashSetOrders() {
        for i in civs.indices {
            civs[i].techUniqueOrder = civs[i].isBarbarian ? Civilization.ordered([], civs[i].techs) : javaHashMapOrder(civs[i].orderedTechs)
            civs[i].policyUniqueOrder = javaHashMapOrder(civs[i].orderedPolicies)
        }
        for i in cities.indices {
            let order = javaHashMapOrder(cities[i].buildings)
            if order != cities[i].buildings { cities[i].buildings = order }
            if !cities[i].duplicateBuildingObjects.isEmpty { cities[i].duplicateBuildingObjects = [] }
        }
    }

    /// Unciv WorldScreen.nextTurn: `val gameInfoClone = originalGameInfo.clone(); gameInfoClone.setTransients()`, then
    /// `gameInfoClone.nextTurn(progressBar, true)` - every press of Next Turn plays the turn on a copy that holds only the
    /// saved fields, setTransients builds its transients again, and the copy becomes the game. GameController.endTurn
    /// runs this before the turn; GameState.endTurn does not, since Unciv's turn-dump harness, Simulation and
    /// Multiplayer.skipCurrentPlayerTurn call GameInfo.nextTurn on the game itself, with no clone.
    ///
    /// First what the clone starts afresh (the Unciv field each of ours stands for), then GameInfo.setTransients in its
    /// own order: the open borders, the civs' setTransients (HashSet orders, the cities' followers), the neutral roads, and
    /// updateCivilizationState. Ours carried all of it from turn to turn: a garrison moved into a city mid-turn reached
    /// its "[+1 Happiness, +2 Culture] [in all cities with a garrison]" only at the city's next stats update, where
    /// Unciv's Next Turn had already recomputed every city before the turn ended.
    func uncivNextTurnTransients() {
        orderUnitsAsTileTransients()                                // UnitManager.unitList, rebuilt from the tiles
        for i in cities.indices where cities[i].hasJustBeenConquered { cities[i].hasJustBeenConquered = false }   // @Transient, not in City.clone
        map.resetCoastAdjacency()                                   // Tile._isAdjacentToCoast (by lazy): fresh Tile objects
        // TechManager.researchedTechnologies: setTransients rebuilds it from the techsResearched set, one entry per tech,
        // so the repeats of a continually researched tech only count within this next turn
        researchedTechnologyRepeats = [:]
        // City.unitToPromotions (shared by City.clone) keeps pointing at this turn's MapUnits, which the clone no longer
        // plays: every saved default promotion freezes as its unit stands now.
        freezeSavedUnitPromotions()
        neighboringCitiesCache = [:]; destroyedCitySnapshots = [:]  // City.neighboringCities (by lazy): fresh City objects
        religionBuildingsPurchasableCache = [:]                     // Religion.buildingsPurchasableByBeliefs (by lazy): Religion.clone()
        happinessCache = [:]                                        // CivInfoStatsForNextTurn: `var happiness = 0`
        for i in civs.indices { civs[i].statsForNextTurn = Stats() } // ...and `var statsForNextTurn = Stats()`
        storedCityStats = [:]                                       // City.cityStats = CityStats(this): stats and happinessList empty
        storedDetailedSupply = [:]; storedDetailedResources = [:]   // Civilization.detailedCivResources = ResourceSupplyList()
        storedSummarizedSupply = [:]; storedResourceSupply = [:]    // Civilization.summarizedCivResourceSupply
        hasActiveEnemyMovementPenalty = [:]                         // Civilization.hasActiveEnemyMovementPenalty = false
        viewableInvisibleUnitsTilesCache = [:]                      // Civilization.viewableInvisibleUnitsTiles
        militaryMightCache = [:]                                    // Civilization.cachedMilitaryMight = -1
        threatManagerCache = [:]                                    // Civilization.threatManager = ThreatManager(this)
        workerAutomationCaches = [:]                                // Civilization.workerAutomationCache = null
        nextPotentiallyDueAt = [:]                                  // UnitManager.nextPotentiallyDueAt = 0
        pathfindingCache = [:]                                      // MapUnit.movement: a fresh PathfindingCache
        unitCannotEnterOceanTiles = [:]                             // MapUnit.cache = MapUnitCache(this)
        religionFollowersCache = [:]; religionFollowersOrderCache = [:]   // CityReligionManager.followers (a transient Counter)
        invalidateHappiness()                                       // the caches derived from the above
        // GameInfo.setTransients: every DiplomacyManager's updateHasOpenBorders, from a hasOpenBorders that starts false
        updateAllHasOpenBorders()
        // Civilization.setTransients: PolicyManager, TechManager and every city's CityConstructions walk their HashSets
        reapplyJavaHashSetOrders()
        // Civilization.setTransients → City.setTransients → CityReligionManager.setTransients: updateNumberOfFollowers(false)
        for city in cities { _ = followers(of: city) }
        // civInfo.setTransients → CityExpansionManager.setTransients: every owned tile's setOwningCity (the road owner), on
        // the neutralRoads carried over, with the road owners the tiles were saved with (the decoder leaves them so)
        setOwningCityTransients()
        // TileMap.setNeutralTransients: the clone keeps the very same neutralRoads set (`toReturn.neutralRoads =
        // neutralRoads`), and each tile no city owns is added to its road owner's again - nothing is taken out
        addNeutralTransients()
        updateCivilizationState()
    }

    /// Marks a decode as WorldScreen.nextTurn's clone (see init(from:)).
    static let nextTurnCloneKey = CodingUserInfoKey(rawValue: "epochs.nextTurnClone")!
    /// Marks a decode whose neutralRoads the caller replaces with the live game's (an undo restore): the decoder leaves the
    /// road owners as saved, for the caller's setOwningCity pass on that set.
    static let sharedNeutralRoadsKey = CodingUserInfoKey(rawValue: "epochs.sharedNeutralRoads")!

    /// What Unciv GameInfo.clone carries over and our save does not write: Civilization.clone's `toReturn.neutralRoads =
    /// neutralRoads` (the very set; setNeutralTransients only adds to it). (GameInfo.clone's `unitNamesTaken.addAll` and
    /// the civs whose DiplomacyManager.nextTurn already ran this round come with the saved fields now.) Taken on the main
    /// thread together with the encoded game.
    struct NextTurnCloneCarry {
        let neutralRoads: [Int: Set<HexCoord>]
    }
    var nextTurnCloneCarry: NextTurnCloneCarry {
        NextTurnCloneCarry(neutralRoads: neutralRoads)
    }

    /// Unciv WorldScreen.nextTurn: `val gameInfoClone = originalGameInfo.clone()` - here the saved fields decoded from the
    /// game encoded on the main thread (every struct and class made afresh, so nothing is shared with the original the
    /// world screen keeps showing), plus what GameInfo.clone copies that the save leaves out. Not SaveManager.load: that
    /// activates the ruleset, rebuilds the cities' tile sets as a load does and runs updateCivilizationState, none of which
    /// Unciv's clone does. The caller runs uncivNextTurnTransients (setTransients) next, as the in-place turn did.
    static func nextTurnClone(of data: Data, carrying carry: NextTurnCloneCarry) throws -> GameState {
        let decoder = JSONDecoder()
        decoder.userInfo[nextTurnCloneKey] = true
        let clone = try decoder.decode(GameState.self, from: data)
        clone.neutralRoads = carry.neutralRoads
        return clone
    }

    /// Unciv UndoHandler: `preActionGameInfo = worldScreen.gameInfo.clone()` before an undoable action, restored by
    /// restoreCheckpoint's `game.loadGame(preActionGameInfo)` - ours the game encoded at the checkpoint and decoded when it
    /// is restored (GameController.rememberForUndo / undo; the save-carry self-test goes the same way).
    func undoCheckpoint() -> Data? { try? JSONEncoder().encode(self) }
    /// `sharing`: the live game's neutralRoads at the restore (GameController.undo). Unciv's checkpoint is a
    /// GameInfo.clone, whose civs share the live game's neutralRoads (Civilization.clone `toReturn.neutralRoads =
    /// neutralRoads`, Civilization.kt:332), so restoreCheckpoint's `preActionGameInfo.setTransients()` (UndoHandler.kt:20-25)
    /// works on the set as the actions since the checkpoint left it: every owned tile's setOwningCity takes a road off its
    /// saved road owner's set (Tile.kt:884-899), then setNeutralTransients adds each unowned tile to its road owner's
    /// (GameInfo.kt:789-790) - a set rebuilt from scratch would drop what neither pass touches. Without it, a copy with
    /// its own set (the self-tests' copies).
    static func restoreUndoCheckpoint(_ data: Data, sharing live: [Int: Set<HexCoord>]? = nil) -> GameState? {
        guard let live else { return try? JSONDecoder().decode(GameState.self, from: data) }
        let decoder = JSONDecoder()
        decoder.userInfo[sharedNeutralRoadsKey] = true
        guard let restored = try? decoder.decode(GameState.self, from: data) else { return nil }
        restored.neutralRoads = live
        restored.setOwningCityTransients()
        restored.addNeutralTransients()
        return restored
    }

    /// Unciv WorldScreen.nextTurn's job on the clone: setTransients, then `gameInfoClone.nextTurn(progressBar, true)` -
    /// TurnManager.endTurn opening with the cities' bombardment, the human's own end of turn regaining time, and the walk
    /// civilization by civilization: `walkLength` gets the number of civilizations the walk expects to play before it
    /// starts (NextTurnProgress's range), `progress` each step (NextTurnProgress.increment). Runs on whatever thread the
    /// caller is on; GameController runs it on its turn thread, the self-test also in place.
    func playWorldScreenNextTurn(citiesAutoBombard: Bool, walkLength: (Int) -> Void = { _ in }, progress: (TurnWalkStep) -> Void = { _ in }, afterTransients: () -> Void = {}) -> EndTurnResult {
        uncivNextTurnTransients()
        afterTransients()
        if citiesAutoBombard { automateCityBombardment(playerId) }
        if let over = endTurnBegin(shouldGainTime: true) { return over }
        walkLength(turnWalkPreview().count)
        while true {
            let step = endTurnStep()
            progress(step)
            if case .finished(let result) = step { return result }
        }
    }

    /// Unciv GameInfo.updateMinutesBeforeForceResign, from nextTurn in an online game for the player whose turn is
    /// ending: the whole minutes since currentTurnStartTime (Duration.toMinutes truncates) come off the pool, a
    /// human's own end of turn (`shouldGainTime`) gives minutesRecoveredPerTurn back, and the pool stays within
    /// 0...minutesUntilForceResign.
    func updateMinutesBeforeForceResign(_ civId: Int, shouldGainTime: Bool) {
        guard let i = civIndex(civId) else { return }
        let timeUsed = Int(((Date().timeIntervalSince1970 * 1000 - currentTurnStartTime) / 60000).rounded(.towardZero))
        let timeRegained = shouldGainTime ? settings.minutesRecoveredPerTurn : 0
        let rawNewTime = civs[i].playerMinutesBeforeForceResign - timeUsed + timeRegained
        civs[i].playerMinutesBeforeForceResign = min(max(rawNewTime, 0), settings.minutesUntilForceResign)
    }
}
