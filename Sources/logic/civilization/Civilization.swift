// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Part of the mirror of Unciv `logic/civilization/Civilization.kt`: destroy / isDefeated, a civilization leaving the game.
extension GameState {
    /// Unciv Battle.destroyIfDefeated, once the caller has found the civ defeated: a city-state's protectors
    /// react (cityStateDestroyed, which ends in every city-state's cityStateConquered quests), destroy(), and
    /// the attacker's Defeated popup.
    func eliminate(civId: Int, by conqueror: Int, at location: HexCoord? = nil) {
        guard let i = civIndex(civId) else { return }
        if civs[i].isCityState { cityStateDestroyed(civId, by: conqueror); questsCityStateConquered(target: civId, attacker: conqueror) }
        destroyCiv(civId, notificationLocation: location)
        if !civs[i].isBarbarian { addAlert(conqueror, .Defeated, "\(civId)") }
        if espionageEnabled { removeAllSpies(civId: civId) }   // Unciv Civilization.destroy ends in espionageManager.removeAllSpies()
    }

    /// Unciv Civilization.destroy: the map revealed to a defeated human, "destroyed" told to every civ still in the
    /// game, the units gone, and the trades and trade requests with it cleared on both sides. Nothing else:
    /// the diplomatic status stays what it was - Unciv's wars with a dead civ are still wars, which the readers
    /// that care (isAtWar(), getCivsAtWarWith) skip by `isDefeated()`, and which a city-state liberated back into
    /// the game still has. Ours ended every war with the dead civ here.
    func destroyCiv(_ civId: Int, notificationLocation: HexCoord? = nil) {
        guard let i = civIndex(civId) else { return }
        civs[i].isAlive = false   // isDefeated() is computed there; here it is the stored flag, set where it changes
        revealMapWhenDefeated(civId)
        let name = civs[i].nation
        let text = civs[i].isMajor ? "The civilization of [\(name)] has been destroyed!" : "The City-State of [\(name)] has been destroyed!"
        // `if (civ.isDefeated()) continue`: the barbarians are never defeated (Civilization.isDefeated), so they are told
        // too - addNotification then drops it for them as for every AI, after the notification log has it
        for j in civs.indices where civs[j].isAlive || civs[j].isBarbarian {
            // `tile.isVisible(civ) || tile.isExplored(civ) && tile.getShownImprovement(civ) == Constants.cityCenter`:
            // an explored tile out of sight gives the location only where that civ knows of a city there.
            // isVisible reads the civ's STORED viewableTiles: a city-state allied with the conqueror does not see the
            // city it just took until its own view is updated (a test game, t=117, Yerevan and Greece's Ragusa)
            let at = notificationLocation.flatMap { c -> HexCoord? in
                if visibleTiles(for: civs[j].id).contains(c) { return c }   // tile.isVisible(civ)
                guard civs[j].explored.contains(c) else { return nil }       // tile.isExplored(civ)
                // Tile.getShownImprovement: an AI or a spectator sees the real improvement, a human its lastSeenImprovement
                // (ours records one for the AI too, which Unciv's setLastSeenImprovement never does)
                let shown = (!civs[j].isPlayer || civs[j].isSpectator) ? map[c]?.improvement : civs[j].lastSeenImprovement[c]
                return shown == "City center" ? c : nil                      // == Constants.cityCenter
            }
            notify(civs[j].id, text, category: .General, icons: [name, "Death"], coord: at)
        }
        for id in units.filter({ $0.civId == civId }).map({ $0.id }) { destroyUnit(id) }   // units.getCivUnits().forEach { it.destroy() }
        clearDealsOf(civId)   // tradeRequests.clear(), both sides' trades, and the requests it had made
        // ...the peace treaty's trade among them: no "[Peace Treaty] from [..] will end / has ended" about a dead civ
        for j in civs.indices { civs[j].peaceTreatyUntil[civId] = nil; civs[j].peaceTreatySharedOffer.remove(civId); civs[j].peaceTreatyStartDuration[civId] = nil }
        civs[i].peaceTreatyUntil = [:]; civs[i].peaceTreatySharedOffer = []; civs[i].peaceTreatyStartDuration = [:]
        if espionageEnabled { removeAllSpies(civId: civId) }   // espionageManager.removeAllSpies()
    }

    /// Unciv Civilization.hasSpectatorVision: `isSpectator() || (isDefeated() && isCurrentPlayer() &&
    /// !gameInfo.gameParameters.isOnlineMultiplayer && gameInfo.turns > 0)` - a human who lost a game that is not
    /// online keeps playing as a de-facto spectator and sees the whole map. Unciv's currentPlayerCiv only moves once
    /// the AI civs have played, so during their turns it is still the human, as our currentHumanId is.
    func hasSpectatorVision(_ c: Civilization) -> Bool {
        c.isSpectator || (isDefeated(c) && c.id == currentHumanId && !settings.isOnline && uncivTurns > 0)
    }

    /// Unciv CivView.isMapRevealed: `!isOnlineMultiplayer && civ.isCurrentPlayer() && civ.isDefeated()` - a human
    /// defeated in a game that is not online, watching it play out. Unlike hasSpectatorVision it has no turn check and
    /// no spectator (a spectator is never defeated). TileView.isForceVisible adds DebugUtils.VISIBLE_MAP to it.
    func isMapRevealed(_ c: Civilization) -> Bool {
        !settings.isOnline && c.id == currentHumanId && isDefeated(c)
    }

    /// Unciv's `isDefeated()` / `isAlive()` are computed from the cities and units; ours is the stored isAlive,
    /// written by destroyCiv and by moveToCiv (a city handed to a dead civ brings it back). A civ can also come
    /// to be defeated outside those - a unit-only civ losing its last unit to anything but a battle - and Unciv
    /// simply reads it as defeated from then on, destroying nothing. This brings the flag back in line.
    func refreshDefeatedFlags() {
        for i in civs.indices where !civs[i].isBarbarian && !civs[i].isSpectator {
            let alive = !isDefeated(civs[i])
            if civs[i].isAlive != alive { civs[i].isAlive = alive }
        }
    }

    var difficulty: DifficultyDef { rs.difficulty(settings.difficulty) }
    var speed: SpeedDef { rs.speed(settings.speed) }
    var year: Int { speed.year(forTurn: turn + startTurnOffset) }
    /// Unciv GameInfo.getEquivalentTurn: games started in a later era show the year of that era's startPercent.
    var startTurnOffset: Int { speed.lastTurn * (rs.era(named: settings.startingEra)?.startPercent ?? 0) / 100 }

    /// Unciv Civilization.getDifficulty: humans use the game difficulty, AIs use its aiDifficultyLevel (else Chieftain, else the first).
    func difficulty(for civId: Int) -> DifficultyDef {
        if civ(civId)?.isPlayer != false { return difficulty }
        if let n = difficulty.aiDifficultyLevel, let d = rs.difficulties.first(where: { $0.name == n }) { return d }
        return rs.difficulties.first { $0.name == "Chieftain" } ?? rs.difficulties.first ?? difficulty
    }
    var yearString: String { let y = year; return y < 0 ? "\(-y) BC" : "\(y) AD" }

    // MARK: resources

    /// Unciv Civilization.getEquivalentBuilding: our own version of a building, or the generic one when we have none.
    func equivalentBuilding(_ civId: Int, _ name: String) -> String {
        guard let nation = civ(civId)?.nation, let def = rs.buildings[name] else { return name }
        let root = def.replaces ?? def.name
        if let mine = rs.buildings.values.first(where: { $0.replaces == root && $0.uniqueTo == nation }) { return mine.name }
        return def.uniqueTo == nil ? def.name : root   // another nation's unique building becomes the building it replaces
    }

    /// Unciv Civilization.getEquivalentUnit by name.
    func equivalentUnitName(_ civId: Int, _ name: String) -> String {
        guard let base = rs.units[name] else { return name }
        return equivalentUnit(civId, base).name
    }

    /// Unciv Civilization.getEquivalentUnit(BaseUnit): a unique unit stands for the unit it replaces (followed
    /// down the `replaces` chain), then the first of the civ's own unique units that replaces it -
    /// CivInfoTransientCache.uniqueUnits is ruleset.units in order with `uniqueTo` read as a civ filter, in a
    /// HashSet of identity-hash-1 objects, which walks in insertion order. We walked the unordered dictionary
    /// and stopped at the unit we were given.
    func equivalentUnit(_ civId: Int, _ base: UnitDef) -> UnitDef {
        if let r = base.replaces, let replaced = rs.units[r] { return equivalentUnit(civId, replaced) }
        guard let c = civ(civId) else { return base }
        for name in rs.unitOrder {
            guard let u = rs.units[name], u.replaces == base.name, let to = u.uniqueTo, civMatches(c, to, viewer: civId) else { continue }
            return u
        }
        return base
    }

    /// Unciv Civilization.capitalCityIndicator: of the buildings (ruleset order) that "Indicates the capital city",
    /// the one unique to this civ first, else the first.
    func capitalCityIndicator(_ civId: Int, city: City? = nil) -> String? {
        let ctx = UniqueContext(civId: civId, city: city?.civId == civId ? city : nil)
        let indicators = rs.buildingOrder.compactMap { rs.buildings[$0] }.filter { b in
            b.uniqueObjects.contains { $0.pattern == "Indicates the capital city" && conditionalsHold($0, ctx) }
        }
        let nation = civ(civId)?.nation
        return (indicators.first { $0.uniqueTo != nil && $0.uniqueTo == nation } ?? indicators.first)?.name
    }

    /// Unciv Civilization.moveCapitalToNextLargest (oldCapital nil when destroying): the largest city that is not a
    /// capital and not a puppet (the first of equals, in the civ's own list), else the largest puppet, annexed. Both
    /// callers (moveToCiv, destroyCity) call this while the old capital is still in the list; it is skipped because it
    /// is still the capital.
    func moveCapitalToNextLargest(civId: Int, oldCapital: City?) {
        guard let ci = civIndex(civId) else { return }
        let available = cities(of: civId).filter { !$0.isCapital }
        guard !available.isEmpty else { moveCapitalTo(civId: civId, newCapitalId: nil, oldCapitalId: oldCapital?.id); return }
        var newCapital = available.filter { !$0.isPuppet }.max { $0.population < $1.population }   // max(by:) keeps the first, as maxByOrNull
        if newCapital == nil { newCapital = available.max { $0.population < $1.population }; if let n = newCapital { annexCity(cityId: n.id) } }
        guard let target = newCapital, let ti = cityIndex(target.id) else { return }
        // Unciv easter egg (#11486): `currentCapital = getCapital()`; a city-state whose current capital is its eponymous original capital renames the new one.
        if civs[ci].isCityState, let current = cities(of: civId).first(where: { $0.isCapital }),
           current.isOriginalCapital, current.name == civs[ci].nation {
            cities[ti].name = "New [\(civs[ci].nation)]\n(formerly known as [\(cities[ti].name)])"
        }
        moveCapitalTo(civId: civId, newCapitalId: target.id, oldCapitalId: oldCapital?.id)
    }

    func moveCapitalTo(civId: Int, city newCapital: City?, oldCapital: City?) {
        moveCapitalTo(civId: civId, newCapitalId: newCapital?.id, oldCapitalId: oldCapital?.id)
    }

    /// Unciv Civilization.moveCapitalTo: the new capital gets its indicator FIRST (addBuilding, every side effect) and
    /// stops being razed, the "Moves to new capital" buildings follow it (removeBuilding, then addBuilding), and only
    /// then does the old capital lose its own indicator through removeBuilding.
    func moveCapitalTo(civId: Int, newCapitalId: Int?, oldCapitalId: Int?) {
        guard let ci = civIndex(civId) else { return }
        if let n = newCapitalId, let ni = cityIndex(n), let indicator = capitalCityIndicator(civId, city: cities[ni]) {
            civs[ci].capitalCityId = n
            addBuilding(cityIndex: ni, indicator)
            if let nx = cityIndex(n) { cities[nx].razing = false }
            if let o = oldCapitalId, let oi = cityIndex(o) {
                let moving = cities[oi].buildings.filter { rs.buildings[$0].map { $0.uniques.contains("Moves to new capital when capital changes") || $0.uniques.contains("Moves to new capital") } ?? false }   // Unciv MovesToNewCapital
                for b in moving { if let ox = cityIndex(o) { removeBuilding(cityIndex: ox, b) } }
                for b in moving { if let nx = cityIndex(n) { addBuilding(cityIndex: nx, b) } }
            }
        } else if newCapitalId == nil {
            civs[ci].capitalCityId = nil
        }
        if let o = oldCapitalId, let oi = cityIndex(o), let indicator = capitalCityIndicator(cities[oi].civId, city: cities[oi]) {
            removeBuilding(cityIndex: oi, indicator)
        }
        invalidateHappiness(civId)
    }
}

/// Unciv Civilization.HistoricalAttackMemory: an attack kept for the movement-arrow overlay after the attacker can no
/// longer hold it itself - a city's bombardment (`attackingUnit` null), or a unit's attacks once the unit is gone.
struct HistoricalAttackMemory: Codable, Equatable {
    var attackingUnit: String?
    var source: HexCoord
    var target: HexCoord
}

// MARK: - the order a civ's policy and tech uniques are held in

struct Civilization: Codable, Identifiable {
    let id: Int
    let nation: String
    var isPlayer: Bool
    var isAlive: Bool = true
    var gold: Double = 0 { didSet { if EvLog.on { EvLog.gold(nation, oldValue, gold) } } }   // EVLOG: GOLD at every change
    var scienceStored: Double = 0   // legacy pool, migrated into techsInProgress on load
    var currentTech: String? = nil
    var techs: Set<String> = [] { didSet { Civilization.syncOrder(&techUniqueOrder, from: oldValue, to: techs) } }
    var explored: Set<HexCoord> = []
    /// Unciv Civilization.exploredRegion: grown by Tile.setExplored for human players only (the minimap and the camera read it)
    @Lenient var exploredRegion: ExploredRegion = ExploredRegion()
    var atWarWith: Set<Int> = []
    var metCivs: Set<Int> = []
    /// Unciv `Civilization.diplomacy` is a `HashMap<String, DiplomacyManager>` keyed by civ NAME, and
    /// `getKnownCivs()` walks its VALUES - so the order is the JVM's bucket order, with a bucket's own
    /// entries in the order they were put in. `metCivs` is a Set and cannot hold that, so this is the
    /// insertion half of it; `GameState.knownCivs` computes the bucket half from the names.
    var metOrder: [Int] = []
    var notifications: [String] = []
    @Lenient var notificationCountAtStartTurn: Int? = nil   // Unciv: set when the turn starts, highlights the new entries in the overview
    /// Unciv Civilization.attacksSinceTurnStart: attacks this civ made since the start of its most recent turn that no
    /// living unit tracks in its own MapUnit.attacksSinceTurnStart (movement-arrow overlay only).
    @Lenient var attacksSinceTurnStart: [HistoricalAttackMemory] = []
    var notificationCoords: [HexCoord?] = []      // parallel to notifications
    @Lenient var notificationMeta: [NotificationMeta] = []   // parallel: Unciv category / icons / actions
    @Lenient var citiesCreated: Int = 0   // Unciv Civilization.citiesCreated: cities ever founded (never decreases); Kotlin default 0
    /// Unciv `Civilization.cities`: this civ's cities, in the order they joined it - founding appends, and
    /// `moveToCiv` removes the city from the old owner's list and appends it to the new owner's. The order is
    /// not decoration: the turn-end city loop walks it, `sortedByDescending { isBeingRazed }` is stable over
    /// it, ties in `citiesByStatBoost` fall back to it, and `cities.take(amount)` reads off its front.
    var cityIds: [Int] = []
    var capitalCityId: Int? = nil
    var totalCulture: Double = 0
    // --- expanded systems
    var cultureStored: Double = 0                 // banked toward the next social policy
    var policies: Set<String> = [] { didSet { Civilization.syncOrder(&policyUniqueOrder, from: oldValue, to: policies) } }   // adopted policies and completed-branch markers
    var openBranches: Set<String> = []
    var freePolicies: Int = 0
    var goldenAgePoints: Double = 0
    var goldenAgeTurns: Int = 0
    var goldenAgesHad: Int = 0
    var greatPersonPoints: [String: Double] = [:]
    /// Unciv Civilization.stats.statsForNextTurn: a FIELD, written by updateStatsForNextTurn() at the fifteen
    /// places where something that feeds it changes, and read - never recomputed - by every AI call site.
    ///
    /// We had no field: every reader summed statMapForNextTurn, which computes every city's stats from scratch.
    /// Removing the old turn-keyed cache in r98 was right about the key and wrong about the shape, and the
    /// autoplay went from 293s to 1012s. `nil` means "not computed since the last change".
    @Lenient var statsForNextTurn: Stats? = nil
    /// --verify-stats only: the gold of each row of the last computed breakdown, so a stale read can name the
    /// row that went stale ("Tiles", "Unit upkeep", ...) instead of only the total.
    @Lenient var statRowsDebug: [String: Double] = [:]
    var greatPeopleSpawned: Int = 0
    var freeTechs: Int = 0
    var spaceshipParts: [String: Int] = [:]
    /// Unciv VictoryManager.currentsSpaceshipParts is a Counter (a LinkedHashMap): the order its keys were first added,
    /// which the victory screen's step list walks. Older saves have none; spaceshipPartsInOrder falls back to by name.
    @Lenient var spaceshipPartOrder: [String] = []
    var seenNaturalWonders: Set<String> = []
    var leaderTitle: String? = nil
    var isBarbarian: Bool = false
    var lastPeaceTurn: [Int: Int] = [:]           // civ id -> turn a peace was made (no war for 10 turns)
    var isCityState: Bool = false
    var cityStateType: String? = nil
    var influence: [Int: Double] = [:]            // city-state only: major civ id -> influence
    var openBorders: Set<Int> = []                // civs whose units may enter our land
    var warStartTurn: [Int: Int] = [:]
    @Lenient var cityStateUniqueUnit: String? = nil   // Unciv: militaristic city-states gift one major civ's unique unit (a nation not in the game)
    @Lenient var cityStateResource: String? = nil   // Unciv Civilization.cityStateResource (Mercantile unique luxury)
    var playerUserId: String? = nil               // online games: which device controls this human
    var playerName: String? = nil
    /// Unciv Civilization.playerMinutesBeforeForceResign: the online player's pool of time before they may be forced
    /// to resign - drained by the time a turn took, refilled by minutesRecoveredPerTurn (GameInfo.updateMinutesBeforeForceResign).
    /// Stored optional so a save without it reads Kotlin's field default, 3*24*60.
    @Lenient var playerMinutesBeforeForceResignField: Int? = nil
    var playerMinutesBeforeForceResign: Int {
        get { playerMinutesBeforeForceResignField ?? 3 * 24 * 60 }
        set { playerMinutesBeforeForceResignField = newValue }
    }
    /// Unciv Civilization.totalTurnTimeSeconds / turnsPlayedAsHuman: GameInfo.nextTurn adds the seconds each of a living
    /// human's turns took and counts the turn; the multiplayer description shows the average (Kotlin defaults 0).
    @Lenient var totalTurnTimeSeconds: Int = 0
    @Lenient var turnsPlayedAsHuman: Int = 0
    // --- religion
    var faithStored: Double = 0
    var pantheonBelief: String? = nil
    var religionName: String? = nil               // founded religion (only founders have this set)
    @Lenient var religionDisplayName: String? = nil   // Unciv Religion.displayName (nil = the religion name)
    var religionBeliefs: [String] = []            // founder + follower + enhancer beliefs of the founded religion
    var holyCityId: Int? = nil
    var prophetsEarned: Int = 0
    var religionEnhanced: Bool = false
    /// Unciv ReligionState.FoundingReligion / EnhancingReligion: the prophet has been used ("founding" / "enhancing"),
    /// the beliefs are chosen later - for the AI after all its units moved (NextTurnAutomation.chooseReligiousBeliefs).
    @Lenient var pendingReligion: String? = nil
    @Lenient var foundingCityId: Int? = nil       // Unciv ReligionManager.foundingCityId
    var freeBeliefs: Int = 0                      // legacy untyped count, migrated into freeBeliefsByType on load
    @Lenient var freeBeliefsByType: [String: Int] = [:]   // Unciv ReligionManager.freeBeliefs (Counter by BeliefType name)
    // --- espionage
    var spies: [Spy] = []
    var spiesGranted: Set<String> = []            // eras that already granted a spy
    // --- extended diplomacy
    var opinions: [Int: [String: Double]] = [:] { didSet { Civilization.syncOpinionOrder(&opinionOrder, opinions) } }   // other civ id -> named modifiers
    /// Unciv DiplomacyManager.diplomaticModifiers is a HashMap: walked bucket by bucket, and within a bucket in the order the
    /// keys were put in (a key written again keeps its place, one removed and added again goes last). opinionOfOtherCiv sums
    /// the Floats in that walk, so two modifiers sharing a bucket sum in their insertion order (a state comparison, a test game turn
    /// 88: Babylon>France's BulliedProtectedMinor and OpenBorders, 30.368309 there and 30.368307 alphabetically).
    @Lenient var opinionOrder: [Int: [String]] = [:]
    var friendships: [Int: Int] = [:]             // other civ id -> turn declared
    var denouncements: [Int: Int] = [:]           // other civ id -> turn denounced
    var defensivePacts: Set<Int> = []
    var embassiesWith: Set<Int> = []              // we have an embassy in their capital
    var protectedCityStates: Set<Int> = []
    @Lenient var protectionPledgedTurn: [Int: Int] = [:]   // city-state id -> turn the pledge was made (Unciv: 10-turn minimum)
    @Lenient var hasEverWonDiplomaticVote: Bool = false    // Unciv VictoryManager.hasEverWonDiplomaticVote
    @Lenient var hasEverOwnedOriginalCapital: Bool = false  // Unciv Civilization.hasEverOwnedOriginalCapital
    @Lenient var lastRuinRewards: [String] = ["", ""]   // Unciv RuinsManager.lastChosenRewards: the two most recent rewards are not offered again
    @Lenient var unitsToKillForCiv: [Int: Int] = [:]          // Unciv QuestManager war-with-major pseudo-quest (city-states): attacker -> kills wanted
    @Lenient var unitsToKillPutOrder: [Int] = []              // the order unitsToKillForCiv's keys were put in: a Java HashMap bucket keeps its keys so
    @Lenient var unitsKilledFromCiv: [Int: [Int: Int]] = [:]  // attacker -> (helper -> kills so far)
    @Lenient var scienceFromResearchAgreements: Double = 0   // Unciv TechManager.scienceFromResearchAgreements: paid out (÷3 × 50%) on the next turn
    @Lenient var lastSeenImprovement: [HexCoord: String] = [:]   // Unciv Civilization.lastSeenImprovement: what the fog still shows on tiles we cannot see
    var quests: [Quest] = []
    @Lenient var globalQuestCountdown: Int = -1                 // Unciv QuestManager.globalQuestCountdown (UNSET = -1)
    @Lenient var individualQuestCountdown: [Int: Int] = [:]      // Unciv QuestManager.individualQuestCountdown per major
    @Lenient var totalCultureForContests: Int = 0                // Unciv Civilization.totalCultureForContests
    @Lenient var totalFaithForContests: Int = 0                  // Unciv Civilization.totalFaithForContests                      // city-state only: quests handed to majors
    @Lenient var allySince: [Int: Int] = [:]      // city-state only: major id -> turn the alliance began
    @Lenient var faithGreatPeopleBought: Int = 0     // legacy counter (pre per-item tracking)
    @Lenient var boughtWithIncreasingPrice: [String: Int] = [:]   // Unciv boughtItemsWithIncreasingPrice: item name -> times bought
    @Lenient var marriedCityStates: Int = 0
    @Lenient var futureTechs: Int = 0
    @Lenient var techsInProgress: [String: Int] = [:]   // Unciv TechManager.techsInProgress (science put into each tech)
    @Lenient var overflowScience: Int = 0               // Unciv TechManager.overflowScience
    @Lenient var scienceOfLast8Turns: [Int] = [0, 0, 0, 0, 0, 0, 0, 0]   // Unciv TechManager.scienceOfLast8Turns (Great Scientist)
    @Lenient var peaceTreatyUntil: [Int: Int] = [:]   // other civ -> turn until which war cannot be redeclared
    /// The other civs whose Peace Treaty trade in OUR copy holds one TradeOffer object in both its lists: Unciv
    /// TradeLogic.acceptTrade's PeaceProposal adds `peaceOffer` to ourOffers and to theirOffers of the trade it gives the
    /// proposal's giver (TradeLogic.kt:205-224; the third civ's copy, `trade.reverse()`, has two). GameInfo.clone keeps it
    /// one (Trade.clone's addAll), Unciv's JSON save writes it twice - so the Next Turn clone and the undo checkpoint keep
    /// this set and a load drops it (SaveManager.load; the Unciv file has no such entry). Written with peaceTreatyUntil.
    @Lenient var peaceTreatySharedOffer: Set<Int> = []
    /// The duration both Peace Treaty offers of OUR copy of the treaty's trade started at - TradeOffer's
    /// peaceDealDuration, or what remakePeaceTreaty gives the copies of a treaty cut short with its trade. Unciv's
    /// `ourOffers.union(theirOffers)` holds one of two equal offers, so theirOffers keeps that duration until our second
    /// end of turn and is one ahead of ourOffers only from then on (peaceTreatyTheirOffersLeft); a copy remade at 0 is
    /// listed with both offers at 0 until our next end of turn drops it. Absent for a treaty from a save that did not
    /// keep it (read as one ahead from the start). Written with peaceTreatyUntil.
    @Lenient var peaceTreatyStartDuration: [Int: Int] = [:]
    @Lenient var techQueue: [String] = []             // research order chosen by the player
    @Lenient var aiOfferTurn: [Int: Int] = [:]        // AI: last turn we proposed a trade to each human
    @Lenient var notificationLog: [NotificationLogEntry] = []   // Unciv notificationsLog: past turns, per turn
    @Lenient var startingLocation: HexCoord? = nil    // Unciv TileMap.startingLocations: where this civilization began
    @Lenient var gpPointsRequired: Int = 100          // Unciv: doubles after every great person from the shared pool
    @Lenient var gpGeneralRequired: Int = 200
    @Lenient var pointsForNextGreatPersonCounter: [String: Int] = [:]   // Unciv GreatPersonManager: per GP pool key ("" = no pool), base points before speed
    @Lenient var pointsForNextGreatGeneralCounter: [String: Int] = [:]  // Unciv: per combat great person, 200 then +50
    @Lenient var greatGeneralPoints: [String: Int] = [:]                // Unciv greatGeneralPointsCounter
    @Lenient var greatGeneralOrder: [String] = []                       // Unciv Counter is a LinkedHashMap: first-added order
    @Lenient var greatPersonOrder: [String] = []
    @Lenient var diploFlags: [Int: [String: Int]] = [:]     // Unciv DiplomacyFlags per other civ -> turns left
    @Lenient var smoothedOpinion: [Int: Double] = [:]      // Unciv EMA of opinion, used for denouncements
    /// Unciv DiplomacyManager.hasOpenBorders: a CACHE, per other civ, of "our units may enter their land",
    /// refreshed only by updateHasOpenBorders (acceptTrade, each side's own nextTurn, onWarDeclared, load).
    @Lenient var hasOpenBordersWith: Set<Int> = []
    @Lenient var totalOfScienceDuringRA: [Int: Int] = [:]   // Unciv DiplomacyManager.totalOfScienceDuringRA per other civ
    @Lenient var cachedSmoothedOpinion: [Int: Double] = [:]   // Unciv cachedSmoothedOpinionOfOtherCiv (one turn ahead)
    @Lenient var numMinorCivsAttacked: Int = 0             // Unciv: city-states attacked (aggressor ≥ 2, warmonger ≥ 4)
    @Lenient var freeGreatPeople: Int = 0                  // Unciv GreatPersonManager.freeGreatPeople (picked on the GreatPersonPickerScreen)
    @Lenient var mayaLimitedFreeGP: Int = 0                // Maya Long Count grants limited to the once-only pool
    @Lenient var longCountGPPool: [String] = []
    @Lenient var lastBaktun: Int = -1
    @Lenient var everEarnedUnits: Set<String> = []        // unit names this civ has ever produced/earned (Carthage: first Great General)
    @Lenient var builtItemsWithIncreasingCost: [String: Int] = [:]   // Unciv CivConstructions.builtItemsWithIncreasingCost ("Cost increases by [] when built")
    @Lenient var freeBuildingsOfCities: [Int: [String]] = [:]         // Unciv CivConstructions.freeBuildings: city id -> buildings the civ gave it (never cleared)
    @Lenient var freeStatBuildingsProvided: [String: [Int]] = [:]     // Unciv CivConstructions.freeStatBuildingsProvided: stat -> city ids served
    @Lenient var freeSpecificBuildingsProvided: [String: [Int]] = [:] // Unciv CivConstructions.freeSpecificBuildingsProvided: building -> city ids served
    /// Unciv CivInfoTransientCache.citiesConnectedToCapitalToMediums (its keys): written only by
    /// updateCitiesConnectedToCapital; nil until the first update.
    @Lenient var citiesConnectedToCapital: [Int]? = nil
    @Lenient var citiesConnectedByRailroad: [Int]? = nil   // ...of those, the ones reached by a railroad medium
    @Lenient var citiesConnectedByRoad: [Int]? = nil       // ...of those, the ones holding a medium whose roadType is not None (the capital only once a route from another city reaches it back)
    @Lenient var proximityTo: [Int: Int] = [:]   // Unciv Civilization.proximity: other civ id -> Proximity (stored, see updateProximity)
    @Lenient var resourceStockpiles: [String: Int] = [:]              // Unciv Civilization.resourceStockpiles ("Stockpiled" resources)
    @Lenient var goldPercentConvertedToScience: Double = 0.6          // Unciv TechManager.goldPercentConvertedToScience (ModOptions "Can convert gold to science with sliders")
    @Lenient var cultureOfLast8Turns: [Int] = []   // Unciv PolicyManager.cultureOfLast8Turns (Great Writer "Hurry Policy")
    @Lenient var popupAlerts: [PopupAlert] = []            // Unciv PopupAlert queue (humans)
    @Lenient var shouldOpenPolicyPicker: Bool = false      // Unciv PolicyManager.shouldOpenPolicyPicker
    @Lenient var dismissedShouldMoveSpies: Bool = false    // Unciv EspionageManager.dismissedShouldMoveSpies
    @Lenient var temporaryUniques: [TemporaryUnique] = []  // Unciv TemporaryUnique: timed triggered uniques
    /// Unciv TechManager.techUniques / PolicyManager.policyUniques are UniqueMaps filled in the order techs were
    /// researched and policies adopted - after a load, in the iteration order of the saved `HashSet<String>`
    /// (`setTransients`), then appended one by one. `techs` and `policies` are Sets, whose order changes with every
    /// launch, so the insertion order is kept here and maintained by their `didSet`.
    @Lenient var techUniqueOrder: [String] = []
    @Lenient var policyUniqueOrder: [String] = []
    @Lenient var disabledCivConstructions: Set<String> = [] // Unciv "Disable in all cities"
    @Lenient var civFlags: [String: Int] = [:]            // Unciv CivFlags countdowns (TurnsTillCallForBarbHelp, …)
    @Lenient var statsHistory: [Int: [String: Int]] = [:]  // Unciv CivRankingHistory: turn -> ranking type -> value
    @Lenient var cityStatePersonality: String = "Neutral"   // Unciv CityStatePersonality: Friendly / Neutral / Hostile / Irrational         // Unciv: +50 after every combat-earned great person
    var questRewards: [Int: Double] = [:]         // (unused placeholder for future)

    var nationDef: NationDef? { Ruleset.shared.nations[nation] }
    var displayName: String { nation }
    /// Unciv Spectator: a human seat that only watches (added when no player is human).
    var isSpectator: Bool { nation == "Spectator" }
    var isMajor: Bool { !isBarbarian && !isCityState && !isSpectator }
    var completedBranches: Int { Ruleset.shared.policyBranches.filter { policies.contains($0.completion?.name ?? "") }.count }
    /// The keys of spaceshipParts in Unciv's Counter order (spaceshipPartOrder); a key it lacks follows, by name.
    var spaceshipPartsInOrder: [String] {
        let known = spaceshipPartOrder.filter { spaceshipParts[$0] != nil }
        return known + spaceshipParts.keys.filter { !known.contains($0) }.sorted()
    }
    /// Unciv: every branch is also an entry of ruleset.policies, so opening a branch counts as an adopted
    /// policy; only the automatic branch-completion policies are excluded.
    var adoptedPolicyCount: Int {
        policies.filter { name in
            if let p = Ruleset.shared.policies[name] { return !p.isBranchCompletion }
            return Ruleset.shared.policyBranches.contains { $0.name == name }
        }.count
    }
    /// Unciv PolicyManager.numberOfAdoptedPolicies: only policies paid with culture raise the next cost (-1 = older save, fall back to adoptedPolicyCount)
    @Lenient var numberOfAdoptedPolicies: Int = -1
    var paidPolicyCount: Int { numberOfAdoptedPolicies >= 0 ? numberOfAdoptedPolicies : adoptedPolicyCount }
    var isInGoldenAge: Bool { goldenAgeTurns > 0 }
    var leaderName: String { nationDef?.leaderName ?? nation }

    /// Keeps an insertion-ordered list in step with a Set: removed names leave it, added ones are appended. Several
    /// names added at once (a load, a start-of-game grant) go in the order a Java `HashSet<String>` holding them walks.
    /// opinionOrder kept with `opinions`: a removed key leaves, a new one goes last (several at once - a load - by name)
    static func syncOpinionOrder(_ order: inout [Int: [String]], _ opinions: [Int: [String: Double]]) {
        for (other, mods) in opinions {
            let current = order[other] ?? []
            if current.count == mods.count && current.allSatisfy({ mods[$0] != nil }) { continue }
            var o = current.filter { mods[$0] != nil }
            for k in mods.keys.sorted() where !o.contains(k) { o.append(k) }
            order[other] = o
        }
        if order.count > opinions.count { for other in Array(order.keys) where opinions[other] == nil { order[other] = nil } }
    }
    static func syncOrder(_ order: inout [String], from old: Set<String>, to new: Set<String>) {
        if new.count < old.count || !old.isSubset(of: new) { order.removeAll { !new.contains($0) } }
        let added = new.subtracting(old)
        if added.count == 1 { order.append(added.first!) }
        else if !added.isEmpty { order += javaHashMapOrder(added.sorted()) }
    }
    /// `order` repaired against `set` - a save written before the order was kept has none.
    static func ordered(_ order: [String], _ set: Set<String>) -> [String] {
        if order.count == set.count && Set(order) == set { return order }
        var out = order.filter { set.contains($0) }
        var seen = Set<String>(); out = out.filter { seen.insert($0).inserted }
        out += javaHashMapOrder(set.subtracting(out).sorted())
        return out
    }
    /// Unciv techUniques insertion order.
    var orderedTechs: [String] { Civilization.ordered(techUniqueOrder, techs) }
    /// Unciv TechManager.researchedTechnologies - the transient list techUniques, unitsCanEmbark, the road speed,
    /// bridges and the era are read from. It is rebuilt from techsResearched on load and grows with addTechnology;
    /// BarbarianManager.updateBarbarianTech replaces the barbarians' techsResearched alone, so theirs stays what the
    /// load (or the game start) left - the barbarians of a game running since before Optics never embark.
    var transientTechs: [String] { isBarbarian ? techUniqueOrder : orderedTechs }
    /// Unciv policyUniques insertion order (branches, policies and branch completions alike - all are Policies there).
    var orderedPolicies: [String] { Civilization.ordered(policyUniqueOrder, policies) }

    func isAtWar(with other: Int) -> Bool { atWarWith.contains(other) }
    func hasTech(_ t: String?) -> Bool { t == nil || techs.contains(t!) }

    /// Unciv TechManager.updateEra: the era of the latest researched tech, or the era of the earliest unresearched tech when that is later
    var eraName: String {
        let rs = Ruleset.shared
        let known = isBarbarian ? Set(transientTechs) : techs   // Unciv updateEra walks researchedTechnologies
        guard !known.isEmpty else { return rs.eras.first?.name ?? "" }
        var best = 0
        var minUnresearched: Int? = nil
        for (name, d) in rs.techs {
            guard let i = rs.eras.firstIndex(where: { $0.name == d.era }) else { continue }
            if known.contains(name) { best = max(best, i) } else { minUnresearched = min(minUnresearched ?? i, i) }
        }
        return rs.eras[max(best, minUnresearched ?? best)].name
    }
    /// Notifications with their Unciv metadata (the legacy parallel arrays are padded when out of step).
    var notificationItems: [NotificationItem] {
        notifications.enumerated().map { i, t in
            var meta = i < notificationMeta.count ? notificationMeta[i] : NotificationMeta()
            if meta.actions.isEmpty, i < notificationCoords.count, let c = notificationCoords[i] { meta.actions = [.location(c)] }
            return NotificationItem(index: i, text: t, meta: meta)
        }
    }
    mutating func clearNotifications() { notifications.removeAll(); notificationCoords.removeAll(); notificationMeta.removeAll(); notificationCountAtStartTurn = nil }

}
