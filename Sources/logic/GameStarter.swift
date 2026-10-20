// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv GameStarter.getStartingLocations: `throw Exception("Didn't manage to get starting tiles even with distance of 1?")`
/// when even a minimum distance of 0 leaves a civilization without a tile; NewGameScreen.startNewGame catches it and
/// shows "It looks like we can't make a map with the parameters you requested!"
struct StartingTilesError: Error, CustomStringConvertible {
    var description: String { "Didn't manage to get starting tiles even with distance of 1?" }
}
/// A game started on a map file with units on it throws in Unciv's GameStarter (see there), and NewGameScreen.startNewGame
/// shows the same "It looks like we can't make a map with the parameters you requested!": the exception names the
/// lateinit the first such unit reads, its `civ` when some unit's owner is not in the game, else its civ's `gameInfo`.
struct MapUnitsError: Error, CustomStringConvertible {
    var ownerMissing: Bool
    var description: String { "lateinit property \(ownerMissing ? "civ" : "gameInfo") has not been initialized" }
}

extension GameState {
    /// Unciv's GameStarter builds the game with a ruleset and a map of its own, so a start that throws (the map
    /// generation's MapGenerationError, StartingTilesError) leaves nothing behind; ours activates the shared ruleset and
    /// sets the map wrap and coastal lookup as it goes, so a failed start puts them back as they were, as a failed load does
    /// (SaveManager.restoringGlobalsOnFailure) - the new game screen is opened from a game being played, too.
    static func newGame(settings: GameSettings) throws -> GameState {
        try SaveManager.restoringGlobalsOnFailure { try startNewGame(settings: settings) }
    }
    private static func startNewGame(settings: GameSettings) throws -> GameState {
        var s = settings
        s.godMode = false   // Unciv GameParameters.clone: godMode intentionally reset for a new game
        // Unciv GameStarter's init fixes gameSetupInfo itself, so the lastGameSetup it saves at the end carries them:
        // `mods.removeAll { !RulesetCache.containsKey(it) }` and an unknown base ruleset becoming
        // RulesetCache.getVanillaRuleset() (ours kept whichever base ruleset was active)
        let installed = Set(Ruleset.availableMods())
        s.mods.removeAll { !installed.contains($0) }
        if !Ruleset.baseRulesets.contains(s.baseRuleset) { s.baseRuleset = "Civ V - Vanilla" }
        if s.seed == 0 { s.seed = UInt64.random(in: 1...UInt64.max) }
        Ruleset.activate(mods: s.mods, baseRuleset: s.baseRuleset)   // Unciv: the game is played on the base ruleset it was set up with
        // Unciv: "Make sure that a valid game speed is loaded" - `speed = ruleset.speeds.keys.first()`
        if !Ruleset.shared.speeds.contains(where: { $0.name == s.speed }), let first = Ruleset.shared.speeds.first { s.speed = first.name }
        var remembered = settings
        remembered.mods = s.mods; remembered.baseRuleset = s.baseRuleset; remembered.speed = s.speed
        resolveMapParameters(&s)
        // (A world-wrap map's odd width is rounded down by the generator, as Unciv's TileMap does - mapSize keeps it.)
        if s.randomNation, let pick = Ruleset.shared.majorNations.randomElement() { s.playerNation = pick.name }
        let rs = Ruleset.shared
        // Unciv GameStarter: "The MapGen needs to know what civs are in the game" - the civilizations and city-states are
        // chosen before the map is generated. They draw from their own stream, which map generation never touches, and
        // the game keeps that stream as it was before the choice.
        var rng = SeededRandom(seed: s.seed ^ 0xABCDEF)
        let gameRng = rng
        // Unciv GameStarter: an existing map is loaded first (MapSaver.loadMap) and the civilizations are chosen
        // with existingMap = true - the nations it has starting locations for go first. MapFileSelectTable: "Custom"
        // uses the chosen file, else a mod's preselected map, else the first map listed.
        let customMap: CustomMap? = (s.customMap ?? (s.mapMainType == "Custom" ? (MapStore.preselectedMap(forMods: s.mods) ?? MapStore.list(mods: s.mods).first) : nil)).flatMap { MapStore.load(name: $0) }
        let customStarts: [StartingLocation] = customMap?.startingLocations ?? []
        // Unciv chooseCivilizations(existingMap = true) reads `gameInfo.tileMap.startingLocationsByNation.keys`, but the
        // loaded map is only in GameStarter's own `tileMap` then - gameInfo.tileMap is still GameInfo's blank TileMap()
        // until addCivilizations (GameStarter.kt:78-95, 262-264), and startingLocationsByNation is filled by
        // setStartingLocationsTransients later still (GameStarter.kt:118) - so no nation is preferred for having a
        // location on the map: a Random seat draws from the whole pool and the city-states are a plain shuffle. Ours
        // took the map's nations first, so a city-state or a random major with a marked start was always in the game.
        let civNamesWithStartingLocations: Set<String> = []
        // Unciv GameStarter.chooseCivilizations: chosen nations first, then random picks (humans before AI).
        let chosenPlayers = chooseCivilizations(&s, rng: &rng, rs: rs, civNamesWithStartingLocations: civNamesWithStartingLocations)
        // the map generation, the regions and the starting units only see the major civs; the Spectator seats become
        // civilizations of their own (Unciv addCivilizations: `civ.isMajorCiv() || civ.isSpectator()`)
        let spectatorSeats = chosenPlayers.filter { $0.nation == spectatorNation }
        let chosen = chosenPlayers.filter { $0.nation != spectatorNation }
        let nations = chosen.map { $0.nation }
        let csCount: Int = {
            if s.randomNumberOfCityStates {
                let lo = min(s.minNumberOfCityStates, s.maxNumberOfCityStates), hi = max(s.minNumberOfCityStates, s.maxNumberOfCityStates)
                return min(rs.cityStateNations.count, rng.int(lo...hi))
            }
            return min(rs.cityStateNations.count, s.cityStateCount >= 0 ? s.cityStateCount : 6)   // Unciv GameParameters.numberOfCityStates default
        }()
        // Unciv GameStarter.chooseCivilizations: city-states without "Will not be chosen for new games", shuffled, then
        // `.sortedByDescending { it.name in civNamesWithStartingLocations }  // please those with location first`
        let csShuffled = rng.shuffled(rs.cityStateNations.filter { !$0.uniques.contains("Will not be chosen for new games") })
        let csNations: [NationDef] = Array((csShuffled.filter { civNamesWithStartingLocations.contains($0.name) } + csShuffled.filter { !civNamesWithStartingLocations.contains($0.name) }).prefix(csCount))
        var gen = MapGenerator(seed: s.seed)
        gen.mapType = s.mapType
        gen.wrapX = s.worldWrap
        gen.configure(s)
        gen.placeResourcesEnabled = false; gen.placeWondersEnabled = false; gen.placeRuinsEnabled = false
        gen.normalizeAtEnd = false   // Unciv normalizes once, after regions, wonders, resources and ruins (below)
        var map: GameMap
        if let custom = customMap {
            // Unciv GameStarter: a loaded map (`mapParameters.name != ""`) goes to MapSaver.loadMap and never to
            // MapGenerator.generateMap, so an Auto size is not resolved for it - ours generated a map to throw away
            map = custom.map
            s.mapWidth = map.width; s.mapHeight = map.height
            s.mapDescription = custom.description   // Unciv: the game plays on the map itself, TileMap.description included
            // and on its own MapParameters: gameInfo.tileMap.mapParameters are the file's, the screen's map settings unused
            // (measured: a map file of Perlin, Sparse, Strategic Balance, Legendary Start, no ruins started from a screen of
            // Fractal and Abundant exports the file's)
            if let p = custom.parameters { s.takeMapParameters(p) }
        } else {
            // throws as Unciv's resolveAutoMapSize does (roundToInt of NaN) for an Auto map with no major civ and at
            // most two city-states - a lone Spectator - which NewGameScreen.startNewGame shows as a map it cannot make
            gen.mapSize = try uncivMapSize(&s, majorCivs: chosen.count, cityStates: csNations.count)
            map = try gen.generate(width: s.mapWidth, height: s.mapHeight)
        }
        // the map's own wrap for the continents' neighbours (a generated map has just set the same; a loaded one would
        // have found the last game's)
        HexCoord.wrapWidth = map.wrapX ? map.width : nil
        // Unciv GameStarter: `if (tileMap.continentSizes.isEmpty()) tileMap.assignContinents(Ensure)` - a saved map
        // without continent data gets its ids here; a generated map already has them from MapGenerator
        map.assignContinents(.ensure)
        if rs.modOptionUniques.contains(where: { $0.pattern == "Can only start games from the starting era" }) { s.startingEra = rs.eras.first?.name ?? s.startingEra }
        let startEra = rs.era(named: s.startingEra) ?? rs.ancientEra
        let startEraIdx = rs.eraIndex(startEra.name)
        if startEra.uniques.contains("Starting in this era disables religion") { s.religionEnabled = false }
        let state = GameState(settings: s, map: map, rng: gameRng)
        state.settings = s
        // Unciv GameStarter "Remove units" then TileMap.setTransients: a map file's units never make it into the game.
        // Remove units calls `unit.setTransients(ruleset)` on each unit whose owner is not among the civilizations, and
        // tileMap.setTransients(ruleset) on every other one, both before GameInfo.setTransients gives the civilizations
        // their gameInfo - MapUnitCache.updateUniques reads the unit's lateinit `civ`, or that civ's `gameInfo`, and
        // throws (measured: the probe's map with Rome, Greece and Barbarian units fails as the one with Egypt's does)
        if let owners = customMap?.unitOwners, !owners.isEmpty {
            let inGame = Set(nations + csNations.map { $0.name } + (s.barbarians ? [Names.barbarians] : [])
                             + (spectatorSeats.isEmpty && chosen.contains { $0.isHuman } ? [] : [spectatorNation]))
            throw MapUnitsError(ownerMissing: owners.contains { !inGame.contains($0) })
        }

        // Start positions, city-states and resources: Unciv MapRegions on a generated map; a loaded map keeps its own
        // starting locations. Either way Unciv GameStarter.addCivStartingUnits then runs getStartingLocations twice
        // over tileMap.startingLocationsByNation (uncivCivStartingLocations below).
        // Unciv allCivs = gameInfo.civilizations less the barbarians: the spectator (a Human player), the majors in
        // their chosen order, then the city-states
        // Unciv addCivilizations: one Spectator civilization for every Spectator seat, a human seat with its playerId;
        // a game set up with no human seat at all (legacy settings, autoplay) gets one Spectator to watch it
        let humanCount = chosen.filter { $0.isHuman }.count
        let spectators: [(isHuman: Bool, playerId: String)] = !spectatorSeats.isEmpty ? spectatorSeats.map { ($0.isHuman, $0.playerId) } : (humanCount == 0 ? [(true, "")] : [])
        let allCivs: [StartCiv] = spectators.map { StartCiv(name: spectatorNation, isCityState: false, isHuman: $0.isHuman, isSpectator: true) }
            + chosen.map { StartCiv(name: $0.nation, isCityState: false, isHuman: $0.isHuman, isSpectator: false) }
            + csNations.map { StartCiv(name: $0.name, isCityState: true, isHuman: false, isSpectator: false) }
        var located: [String: HexCoord] = [:]
        if customMap == nil {
            let regions = MapRegions(map: map, rng: SeededRandom(seed: s.seed ^ 0x5EED), ruleset: rs, resourceSetting: s.resourceSetting, strategicBalance: s.strategicBalance, legendaryStart: s.legendaryStart, gameHash: uncivMapGenGameHash(gameId: s.gameId, seed: s.seed))
            regions.generateRegions(numRegions: nations.count)
            regions.assignRegions(civs: nations, noStartBias: s.noStartBias)
            // Unciv: natural wonders go before resources (minimum distance) and avoid the start locations.
            if s.naturalWonders { try gen.spawnNaturalWonders(&regions.map, startLocations: Array(regions.startingLocations.values)) }
            try regions.placeResourcesAndMinorCivs(minorCivs: csNations.map { $0.name })
            map = regions.map
            if s.ancientRuins { gen.spreadAncientRuins(&map) }
            gen.normalizeToRuleset(&map)   // Unciv MapGenerator.generateMap ends with TileNormalizer.normalizeToRuleset
            located = regions.startingLocations
            // Unciv GameStarter: "MapGen can silently fail to place some city states, so then we'll use the old fallback
            // method to place those" - every civ MapRegions placed keeps its one location through both passes
            if allCivs.contains(where: { !$0.isSpectator && regions.startingLocations[$0.name] == nil }) {
                var marks: [String: [HexCoord]] = [:]
                for c in allCivs { if let at = regions.startingLocations[c.name] { marks[c.name] = [at] } }
                for (name, at) in try uncivCivStartingLocations(allCivs, map: map, marks: &marks, regions: regions, noStartBias: s.noStartBias, rng: &rng) { located[name] = at }
            }
        } else {
            let helper = MapRegions(map: map, rng: SeededRandom(seed: s.seed ^ 0x5EED), ruleset: rs, resourceSetting: s.resourceSetting, strategicBalance: s.strategicBalance, legendaryStart: s.legendaryStart, gameHash: uncivMapGenGameHash(gameId: s.gameId, seed: s.seed))
            // Unciv TileMap.setStartingLocationsTransients: the map's locations by nation, "Any Civ" under the Spectator
            var marks: [String: [HexCoord]] = [:]
            for sl in customStarts {
                let key = sl.nation.isEmpty ? spectatorNation : sl.nation
                if !(marks[key]?.contains(sl.position) ?? false) { marks[key, default: []].append(sl.position) }   // addToMapOfSets: a set per nation
            }
            located = try uncivCivStartingLocations(allCivs, map: map, marks: &marks, regions: helper, noStartBias: s.noStartBias, rng: &rng)
        }
        // Unciv determineStartingUnitsAndLocations: `startingLocations[civ]!!` - every civilization has its tile by now
        // (getStartingLocations threw otherwise), and a missing one fails the start the same way
        var starts: [HexCoord] = []
        for nation in nations {
            guard let at = located[nation] else { throw StartingTilesError() }
            starts.append(at)
        }
        var csPlacements: [(NationDef, HexCoord)] = []
        for n in csNations {
            guard let at = located[n.name] else { throw StartingTilesError() }
            csPlacements.append((n, at))
        }
        let diff = rs.difficulty(s.difficulty)
        // Unciv draws the starting units' random picks from its GameStarter rng after every other draw of the start
        // (addCivStartingUnits comes last); ours, whose rng is not Unciv's, gives them a stream of their own so the
        // draws before them stay as they were
        var unitRng = SeededRandom(seed: s.seed ^ 0x57A27)
        // Unciv GameStarter.addCivStartingUnits `settlerLikeUnits = ruleset.units.filter { it.value.isCityFounder() }`
        let settlerLike = Set(rs.unitOrder.filter { rs.units[$0]?.hasFoundCityUnique == true })
        // Unciv getStartingUnitsForEraAndDifficulty: Era.getStartingUnits (settlers, workers, military units by name),
        // then the difficulty's bonus units for a human, an AI major or a city-state
        let eraStartingUnits = try startEra.startingUnits(rs)
        // Unciv GameStarter.getEquivalentUnit: "Era Starting Unit" is the era's military unit; a "Settler" or "Worker" the
        // ruleset lacks is a random civilian city founder / improvement builder the civilization can build (nil - none
        // placed - when there is none); otherwise Civilization.getEquivalentUnit(name), which throws for an unknown name
        func startingUnit(_ civId: Int, _ name: String) throws -> String? {
            let unit = name == "Era Starting Unit" ? startEra.startingMilitaryUnit : name
            func buildable(_ n: String) -> Bool { guard let u = rs.units[n] else { return false }; return u.isCivilian && state.unitRejections(u, civId: civId, city: nil).isEmpty }
            if unit == Names.settler && rs.units[Names.settler] == nil {
                guard let pick = unitRng.pick(rs.unitOrder.filter { settlerLike.contains($0) && buildable($0) }) else { return nil }
                return state.equivalentUnitName(civId, pick)
            }
            if unit == "Worker" && rs.units["Worker"] == nil {
                guard let pick = unitRng.pick(rs.unitOrder.filter { n in buildable(n) && rs.units[n]!.rulesetUniqueObjects.contains { $0.pattern == "Can build [] improvements on tiles" } }) else { return nil }
                return state.equivalentUnitName(civId, pick)
            }
            guard rs.units[unit] != nil else { throw EraUnitError(message: "Unit \(unit) doesn't seem to exist!") }
            return state.equivalentUnitName(civId, unit)
        }
        // Clear ruins that sit right on a start position, and (Unciv GameStarter.removeAncientRuinsNearStartingLocation) those exactly 3 tiles away.
        for start in starts {
            for raw in start.ring(radius: 3) where raw.distance(to: start) == 3 { let c = map.normalize(raw); if map[c]?.hasRuins == true { map[c]?.improvement = nil } }
        }
        state.map = map
        // Unciv GameStarter.addCivTechs for one civilization: addTechSilently - `tech.addTechnology(name, false)` for a
        // technology the ruleset has and the civ has not researched - on the StartingTech techs, the difficulty's
        // aiFreeTechs (not for a human), the StartsWithTech uniques, every tech for a spectator, and the techs of the
        // eras before the starting one that are not unresearchable, the ruleset's in ruleset.technologies order; then
        // `popupAlerts.clear()` ("adding technologies generates popups"), the notifications staying. Ours set the techs
        // directly, so nothing a tech triggers happened - Babylon's free Great Scientist upon discovering Writing, the
        // Maya's Long Count notice - and the majors were moved into the starting era in one step.
        let techOrder = rs.techOrder
        func addCivTechs(_ civId: Int, isHuman: Bool) {
            func addTechSilently(_ name: String) {
                guard rs.techs[name] != nil, let c = state.civ(civId), !c.techs.contains(name) else { return }
                state.addTechnology(civId: civId, tech: name, showNotification: false)
            }
            for t in techOrder where rs.techs[t]?.uniques.contains("Starting tech") == true { addTechSilently(t) }
            if !isHuman { for t in diff.aiFreeTechs { addTechSilently(t) } }
            // generic start with technology unique
            for u in state.civ(civId)?.nationDef?.uniqueObjects ?? [] where u.pattern == "Starts with []" { addTechSilently(u.param(0)) }
            // add all techs to spectators
            if state.civ(civId)?.isSpectator == true { for t in techOrder { addTechSilently(t) } }
            // Add techs for advanced starting era
            for t in techOrder {
                guard let def = rs.techs[t], rs.eraIndex(def.era) < startEraIdx, let c = state.civ(civId), !state.isUnresearchable(c, def) else { continue }
                addTechSilently(t)
            }
            if let ci = state.civIndex(civId) { state.civs[ci].popupAlerts.removeAll() }
        }
        var majorIds: [Int] = []
        for (i, nation) in nations.enumerated() {
            var civ = Civilization(id: state.newId(), nation: nation, isPlayer: chosen[i].isHuman)
            if chosen[i].isHuman && !chosen[i].playerId.isEmpty { civ.playerUserId = chosen[i].playerId }
            civ.playerMinutesBeforeForceResign = s.minutesUntilForceResign   // Unciv addCivilizations: every major civ and spectator
            civ.startingLocation = starts[i]
            state.civs.append(civ)
            majorIds.append(civ.id)
            let start = starts[i]
            let era = startEra
            // Unciv getStartingUnitsForEraAndDifficulty: Era.getStartingUnits (settlers, workers, military units) and
            // then the difficulty's bonus units, placed in that list order by placeStartingUnits.
            let bonus = chosen[i].isHuman ? diff.playerBonusStartingUnits : diff.aiMajorCivBonusStartingUnits
            var startingUnits = eraStartingUnits + bonus
            // Unciv adjustStartingUnitsForCityStatesAndOneCityChallenge: a human in One-City Challenge has every
            // settler-like unit taken out and ONE of them added back at the END of the list - the workers and the
            // military units are placed first, so in an era with workers the Worker takes the start tile's civilian
            // slot and the Settler lands on a neighbour. Ours kept the first settler at the front.
            if chosen[i].isHuman && s.oneCityChallenge {
                let settlers = startingUnits.filter { settlerLike.contains($0) }
                startingUnits.removeAll { settlerLike.contains($0) }
                // Unciv `startingSettlers.random(rng)`: random() of an empty list throws
                guard let one = unitRng.pick(settlers) else { throw EraUnitError(message: "Collection is empty.") }
                startingUnits.append(one)
            }
            for name in startingUnits { if let u = try startingUnit(civ.id, name) { state.spawnUnit(u, civId: civ.id, at: start) } }
            if let ci = state.civIndex(civ.id) {
                for u in civ.nationDef?.uniqueObjects ?? [] where u.pattern == "Starts with []" || u.pattern == "Starts with [] adopted" {   // Unciv StartsWithPolicy (StartsWithTech is addCivTechs')
                    if rs.techs[u.param(0)] != nil { continue }
                    if let startPolicy = rs.policies[u.param(0)] {
                        state.civs[ci].policies.insert(startPolicy.name)
                        if let b = rs.policyBranchOf[startPolicy.name] { state.civs[ci].openBranches.insert(b) }
                        // Unciv policies.adopt: the policy is adopted, so whatever it triggers happens now
                        state.triggerUniques(startPolicy.uniqueObjects, civId: civ.id, cityId: nil, triggerText: "due to adopting [\(startPolicy.name)]", sourcePolicy: startPolicy.name)
                    }
                }
                // Unciv GameStarter: `gameInfo.getGlobalUniques().uniqueObjects + civ.nation.uniqueObjects` - the
                // global uniques FIRST - are triggered once at the start of the game
                let startPool = rs.globalUniques + (civ.nationDef?.uniqueObjects ?? [])
                // `if (unique.hasTriggerConditional() || !unique.conditionalsApply(civ.state)) continue`, then
                // `repeat(unique.getUniqueMultiplier(civ.state)) { triggerUnique(unique, civ, tile = startingLocation) }`
                if !startPool.isEmpty { _ = state.triggerUniques(state.multiplied(startPool, UniqueContext(civId: civ.id)), civId: civ.id, cityId: nil, unitId: nil, triggerText: nil, tile: start) }
            }
            state.updateExploration(for: civ.id)
        }
        // Unciv GameStarter.addCivilizations: every Spectator seat is a civilization (playerType, playerId,
        // minutesUntilForceResign), with the whole map in view; no starting units, location or starting stats.
        for seat in spectators {
            var spec = Civilization(id: state.newId(), nation: "Spectator", isPlayer: seat.isHuman)
            if !seat.playerId.isEmpty { spec.playerUserId = seat.playerId }
            spec.explored = Set(map.tiles.map { $0.coord })
            spec.playerMinutesBeforeForceResign = s.minutesUntilForceResign   // Unciv addCivilizations
            state.civs.append(spec)
            addCivTechs(spec.id, isHuman: seat.isHuman)   // Unciv addCivTechs: "add all techs to spectators"
        }
        // City-states: placed by MapRegions (or the fallback above), each founded immediately with a defender.
        var csStarts: [HexCoord] = []
        var csIds: [Int] = []
        for (nation, start) in csPlacements {
            var civ = Civilization(id: state.newId(), nation: nation.name, isPlayer: false)
            civ.startingLocation = start
            civ.isCityState = true; civ.cityStateType = nation.cityStateType
            // Unciv: the nation's own personality when it names one of the four, otherwise a draw
            let personalities = ["Friendly", "Neutral", "Hostile", "Irrational"]
            civ.cityStatePersonality = personalities.contains(nation.personality ?? "") ? nation.personality! : (rng.pick(personalities) ?? "Neutral")
            // Unciv initCityState: a city-state type with "Provides a unique luxury" picks one of the "Can only be created by Mercantile City-States" resources
            if let t = nation.cityStateType, let type = rs.cityStateTypes[t], (type.friendBonusUniques + type.allyBonusUniques).contains("Provides a unique luxury") {
                civ.cityStateResource = rng.pick(rs.resources.values.filter { $0.uniques.contains("Can only be created by Mercantile City-States") }.map { $0.name }.sorted())
            }
            // Unciv CityStateFunctions.initCityState: militaristic city-states pick a unique land military unit of a major civ that is not in the game (and not from the starting era or before).
            if let t = nation.cityStateType, let type = rs.cityStateTypes[t], (type.friendBonusUniques + type.allyBonusUniques).contains(where: { $0.hasPrefix("Provides military units every") }) {
                let inGame = Set(state.civs.map { $0.nation })
                let candidates = rs.units.values.filter { u in
                    guard let owner = u.uniqueTo, let n = rs.nations[owner], n.isMajor, !inGame.contains(owner) else { return false }
                    guard u.isLand, !u.isCivilian, u.strength > 0 || u.rangedStrength > 0 else { return false }
                    // Unciv availableInEra: no required technology means available from the start, so it is not eligible
                    guard let tech = u.requiredTech, let era = rs.techs[tech]?.era, rs.eraIndex(era) > startEraIdx else { return false }
                    return true
                }.sorted { $0.name < $1.name }
                civ.cityStateUniqueUnit = rng.pick(candidates)?.name
            }
            state.civs.append(civ)
            csStarts.append(start)
            for raw in start.ring(radius: 3) where raw.distance(to: start) == 3 { let c = state.map.normalize(raw); if state.map[c]?.hasRuins == true { state.map[c]?.improvement = nil } }
            // Unciv getStartingUnitsForEraAndDifficulty then adjustStartingUnitsForCityStatesAndOneCityChallenge: a
            // city-state keeps one settler-like unit of its list (the city it founds on its own first turn) unless the
            // ruleset's ModOptions "Allow City States to spawn with additional units" - then the whole list, the era's
            // units and aiCityStateBonusStartingUnits, each through getEquivalentUnit as a major's
            var csUnits = eraStartingUnits + diff.aiCityStateBonusStartingUnits
            if !rs.modOptionUniques.contains(where: { $0.pattern == "Allow City States to spawn with additional units" }) {
                guard let one = unitRng.pick(csUnits.filter { settlerLike.contains($0) }) else { throw EraUnitError(message: "Collection is empty.") }
                csUnits = [one]
            }
            for name in csUnits { if let u = try startingUnit(civ.id, name) { state.spawnUnit(u, civId: civ.id, at: start) } }
            // Unciv determineStartingUnitsAndLocations walks every civilization but the barbarians and spectators, so a
            // city-state too has `gameInfo.getGlobalUniques().uniqueObjects + civ.nation.uniqueObjects` triggered once its
            // units are placed (none of the shipped rulesets' global or city-state uniques is an unconditional trigger;
            // a mod's would have reached only the majors in ours)
            let csStartPool = rs.globalUniques + nation.uniqueObjects
            if !csStartPool.isEmpty { _ = state.triggerUniques(state.multiplied(csStartPool, UniqueContext(civId: civ.id)), civId: civ.id, cityId: nil, unitId: nil, triggerText: nil, tile: start) }
            csIds.append(civ.id)
        }
        // Unciv GameStarter.addCivTechs runs after addCivStartingUnits and addCivPolicies, once every civilization is in
        // the game: each addTechnology(tech, false) moves the civ on through the eras - the Renaissance spy goes to every
        // alive major civilization when the first of them enters it
        for (i, civId) in majorIds.enumerated() {
            addCivTechs(civId, isHuman: chosen[i].isHuman)
            // Unciv: nobody starts with a chosen technology — a human is asked, and the AI picks on its first turn
            // by personality (NextTurnAutomation.chooseTechToResearch). Autoplay stands in for the human here.
            if chosen[i].isHuman && epochsAutoplay, let ci = state.civIndex(civId) { state.civs[ci].currentTech = state.researchableTechs(for: state.civs[ci]).first?.name }
        }
        // Unciv addCivTechs covers city-states too, after the majors (gameInfo.civilizations order): every non-human civ
        // gets the difficulty's aiFreeTechs
        for civId in csIds { addCivTechs(civId, isHuman: false) }
        // Unciv GameStarter.addCivStats, after addCivTechs: era starting gold/culture scaled by the speed's cost
        // modifiers, through civInfo.addGold and policies.addCulture - which raises shouldOpenPolicyPicker when the
        // culture makes a policy adoptable (a Classical start has enough before the capital is founded)
        for civId in majorIds + csIds {
            guard let ci = state.civIndex(civId) else { continue }
            state.addGold(civId, Int(Double(startEra.startingGold) * state.speed.goldCostModifier))
            state.addCulture(ci, Double(Int(Double(startEra.startingCulture) * state.speed.cultureCostModifier)))
        }
        for civId in csIds { if let ci = state.civIndex(civId) { state.civs[ci].clearNotifications() } }   // Unciv: a city-state picks its research on its own turn
        // Unciv: encampments are only placed by BarbarianManager.updateEncampments during the barbarian turn
        if s.barbarians { state.createBarbarianCiv() }
        // Unciv GameStarter.addCivilizations: the barbarians go into gameInfo.civilizations first, then chosenPlayers in
        // their order - chooseCivilizations puts the Spectator first ("ensure Spectators always first players"), then the
        // major civs, then the city-states in the order they were drawn. Ours were built majors, Spectator, city-states,
        // barbarians, so every position read off `civs` was one or two short of Unciv's - DiplomacyAutomation.offerPeaceTreaty
        // seeds its roll with `civilizations.indexOf(enemy)`, DeclareWar's team-war notice goes out from the earlier civ.
        // Only the positions move: every civ keeps the id it was created with.
        let csOrder = csNations.map { $0.name }
        state.civs = state.civs.filter { $0.isBarbarian } + state.civs.filter { $0.isSpectator }
            + state.civs.filter { !$0.isBarbarian && !$0.isSpectator && !$0.isCityState }
            + state.civs.filter { $0.isCityState }.sorted { (csOrder.firstIndex(of: $0.nation) ?? Int.max) < (csOrder.firstIndex(of: $1.nation) ?? Int.max) }
        // Unciv GameInfo.setTransients, a new game's currentPlayer: online the first human who is not a Spectator ("For
        // MP, spectator doesn't get a 'turn'"), otherwise the first human - a Spectator seat's, in a hot-seat game
        if s.isOnline, let first = state.humans.firstIndex(where: { !$0.isSpectator }) { state.currentHumanIndex = first }
        // Unciv GameStarter.kt:142 "remove starting locations once we're done" (tileMap.clearStartingLocations): a new
        // game's save has none - ours wrote every civilization's start into the exported tileMap
        for ci in state.civs.indices { state.civs[ci].startingLocation = nil }
        // Unciv GameStarter.kt:144-147 "set max starting movement for units loaded from map": every unit on the map gets
        // its full movement - a starting unit a ruin upgraded as it was placed (UpgradeUnit makes the new unit with none
        // left) starts with its movement in Unciv, where ours kept 0, so a human's upgraded Spearman could not move on
        // the first turn
        for i in state.units.indices { let full = state.maxMovement(of: state.units[i]); state.units[i].movementLeft = full }
        // Unciv addPlayerIntros, after addCivTechs cleared the popups: the one-time greeting for every human whose
        // nation has intro text ("isNotEmpty should also exclude a spectator")
        for c in state.civs where c.isPlayer && !(c.nationDef?.startIntroPart1.isEmpty ?? true) { state.addAlert(c.id, .StartIntro) }
        state.map.assignMissingDepositAmounts(rs, setting: s.resourceSetting, seed: s.seed)
        state.historyStartTurn = state.turn
        state.recordTileHistoryChanges()
        for civ in state.civs { state.updateCivResources(civ.id) }   // the stored supply's first value
        // Unciv GameStarter.kt:152-155, the last step of a start that did not throw: `UncivGame.Current.settings.apply {
        // lastGameSetup = gameSetupInfo; save() }` - New game, Quickstart and an online game's creation alike; ours was
        // written by the new-game screen before the start, so a start that failed was remembered and a Quickstart never
        UserSettings.lastGameSetup = remembered   // with GameStarter's own fixes, as Unciv's gameSetupInfo is
        return state
    }
}


extension GameState {
    /// Unciv NewGameScreen/MapParameters: resolve the map main type, named size and random choices into concrete generator inputs.
    static func resolveMapParameters(_ s: inout GameSettings) {
        var rng = SeededRandom(seed: s.seed ^ 0x3A9D)
        if s.mapMainType == "Random Generated" {
            // Unciv MapParameters.randomizeSeed-style choices from the enabled pools (empty pool = everything).
            let shapes = s.randomMapShapes.isEmpty ? ["Rectangular", "Hexagonal", "Flat Earth Hexagonal"] : s.randomMapShapes
            s.mapShape = rng.pick(shapes) ?? "Rectangular"
            let types = s.randomMapTypes.isEmpty ? MapTypeInfo.generatedTypes : s.randomMapTypes
            s.mapType = rng.pick(types) ?? "Pangaea"
            let sizes = s.randomMapSizes.isEmpty ? MapSizePreset.allCases.map { $0.rawValue } : s.randomMapSizes
            s.mapSizeName = rng.pick(sizes) ?? "Medium"
            let res = s.randomMapResources.isEmpty ? ["Sparse", "Default", "Abundant"] : s.randomMapResources
            s.resourceSetting = rng.pick(res) ?? "Default"
            s.customMap = nil
        }
        if s.mapMainType != "Custom" && s.mapMainType != "Scenario" { s.customMap = nil }
        // Auto is resolved once the civilizations are chosen (uncivMapSize, Unciv MapGenerator.resolveAutoMapSize)
        if let preset = MapSizePreset(rawValue: s.mapSizeName) {
            if s.mapShape != "Rectangular" {
                // Unciv hexagonal maps use the radius (the settings carry it as a 2r+1 width and height; mapSize keeps the preset).
                s.mapWidth = preset.radius * 2 + 1; s.mapHeight = preset.radius * 2 + 1
            } else { s.mapWidth = preset.width; s.mapHeight = preset.height }
        }
        if s.mapType == "Random" { s.mapType = rng.pick(MapTypeInfo.generatedTypes) ?? "Pangaea" }
    }

    /// Unciv MapParameters.mapSize of a generated map: a predefined size as it is; a custom one as MapSize(width, height)
    /// or MapSize(radius) builds it (the new-game screen has already run fixUndesiredSizes); Auto as
    /// MapGenerator.resolveAutoMapSize works it out from the civilizations just chosen - it writes all three back and
    /// keeps the name "Auto".
    static func uncivMapSize(_ s: inout GameSettings, majorCivs: Int, cityStates: Int) throws -> UncivMapSize {
        if let preset = MapSizePreset(rawValue: s.mapSizeName) { return UncivMapSize(preset: preset, shape: s.mapShape) }
        if s.mapSizeName == "Auto" {
            // "This is mostly just vibes, tries to make the average distance between a civ and its closest neighbor as close to 13 tiles as possible"
            let majorCivContribution = 384 * majorCivs - 134
            let targetNumberOfTiles = majorCivContribution + cityStates * 60
            // Calculates mapsize from tile number, simple algebra reversing area formulas
            let aspectRatio = 1.55   // This is around the default aspect ratios
            // Kotlin roundToInt, radius first: with no major civ and at most two city-states the tiles are fewer than
            // none and the square root is NaN, which Unciv throws on where Swift's Int() stopped the app
            let radius = try Stats.kotlinRoundToInt((1.0 / 3 * Double(targetNumberOfTiles) - 1.0 / 12).squareRoot() + 1.0 / 2)
            let height = try Stats.kotlinRoundToInt((Double(targetNumberOfTiles) / aspectRatio).squareRoot())
            let width = try Stats.kotlinRoundToInt((Double(targetNumberOfTiles) / aspectRatio).squareRoot() * aspectRatio)
            if s.mapShape == "Rectangular" { s.mapWidth = width; s.mapHeight = height } else { s.mapWidth = radius * 2 + 1; s.mapHeight = radius * 2 + 1 }
            return UncivMapSize(name: "Auto", radius: radius, width: width, height: height, shape: s.mapShape)
        }
        if s.mapShape == "Rectangular" { return UncivMapSize(width: s.mapWidth, height: s.mapHeight, shape: s.mapShape) }
        return UncivMapSize(radius: (s.mapWidth - 1) / 2, shape: s.mapShape)
    }

    /// Unciv GameStarter.chooseCivilizations (single device: at least one human is guaranteed): the Spectator seats
    /// first, then the major civs in the order they play; the city-states are drawn by the caller.
    /// `civNamesWithStartingLocations` is Unciv's `tileMap.startingLocationsByNation.keys` when the game starts on an
    /// existing map, empty otherwise.
    static func chooseCivilizations(_ s: inout GameSettings, rng: inout SeededRandom, rs: Ruleset, civNamesWithStartingLocations: Set<String> = []) -> [(nation: String, isHuman: Bool, playerId: String)] {
        var players = s.players
        if players.isEmpty {
            // Legacy settings (nation + opponent count + human count).
            players = [PlayerSetup(chosenCiv: s.randomNation ? "Random" : s.playerNation, isHuman: true)]
            for _ in 1..<max(1, s.humanPlayers) { players.append(PlayerSetup(chosenCiv: "Random", isHuman: true)) }
            for _ in 0..<s.opponentCount { players.append(PlayerSetup(chosenCiv: "Random", isHuman: false)) }
        }
        let setupPlayers = players
        let majorNames = Set(rs.majorNations.map { $0.name })
        var available = rng.shuffled(rs.majorNations.filter { !$0.uniques.contains("Will not be chosen for new games") }.map { $0.name })
        let chosenNames = Set(players.map { $0.chosenCiv })
        available.removeAll { chosenNames.contains($0) }
        // Unciv chooseCivilizations: with a pool enabled the pool *is* the list. If it runs dry, the remaining
        // random players are simply dropped - falling back to every nation lets civs in that were excluded.
        if s.enableRandomNationsPool {
            let pool = Set(s.randomNationsPool)
            available = available.filter { pool.contains($0) }
        }
        // Unciv presetRandomNationsPool: the random pool's nations the map has starting locations for, shuffled and
        // taken out of it - a random seat takes one of those first (`presetRandomNationsPool.removeLast()`)
        var preset: [String] = []
        if !civNamesWithStartingLocations.isEmpty {
            preset = rng.shuffled(available.filter { civNamesWithStartingLocations.contains($0) })
            available.removeAll { civNamesWithStartingLocations.contains($0) }
        }
        // Unciv chooseCivilizations, randomNumberOfPlayers: the draw runs between min and max, both raised to the seats
        // that are not AI (`playerType === Human || chosenCiv === spectator`), so a human is never dropped. Above the
        // seats that are not Spectators, the difference joins as extra random AI players; below them, `extraPlayers =
        // players.size - desired` - the Spectator seats counted - AI seats are left out, shuffled with the Random ones
        // first (`sortedByDescending`, a stable sort), and `filterNot { it in selectedAIToSkip }` drops those very
        // seats. Ours matched the skipped seats by playerId, which is "" for every AI seat, and so dropped them all.
        var extraRandomAIPlayers = 0
        if s.randomNumberOfPlayers {
            let nonAI = players.filter { $0.isHuman || $0.chosenCiv == "Spectator" }.count
            let lo = max(min(s.minNumberOfPlayers, s.maxNumberOfPlayers), nonAI)
            let hi = max(max(s.minNumberOfPlayers, s.maxNumberOfPlayers), nonAI)
            let desired = rng.int(lo...hi)
            let numberOfNonSpectatorPlayers = players.filter { $0.chosenCiv != "Spectator" }.count
            if desired > numberOfNonSpectatorPlayers {
                extraRandomAIPlayers = desired - numberOfNonSpectatorPlayers
            } else if desired < numberOfNonSpectatorPlayers {
                let extraPlayers = players.count - desired
                let shuffledAI = rng.shuffled(players.indices.filter { !players[$0].isHuman })
                let aiSeats = shuffledAI.filter { players[$0].chosenCiv == "Random" } + shuffledAI.filter { players[$0].chosenCiv != "Random" }
                let selectedAIToSkip = Set(aiSeats.prefix(extraPlayers))
                players = players.indices.filter { !selectedAIToSkip.contains($0) }.map { players[$0] }
            }
        }
        // Unciv: a Spectator seat resolves to the Spectator nation with its playerType and playerId, and "ensure
        // Spectators always first players" puts every one of them ahead of the others (shufflePlayerOrder shuffles
        // only the others). Ours dropped them all, so a Spectator picked next to a human never came into the game.
        let spectators = players.filter { $0.chosenCiv == "Spectator" }.map { (nation: "Spectator", isHuman: $0.isHuman, playerId: $0.playerId) }
        players.removeAll { $0.chosenCiv == "Spectator" }
        var result: [(nation: String, isHuman: Bool, playerId: String)] = []
        // Unciv chooseCivilizations: `sortedWith(compareBy { it.chosenCiv == Constants.random }.thenBy { it.playerType == PlayerType.AI })`
        // - a stable sort: nonrandom before random, humans before AI, otherwise the players' own order. The civs are
        // created, and play, in this order. Ours kept the chosen nations in the setup's order (an AI with a chosen
        // nation ahead of a chosen human) and sorted the random ones with an unstable sort.
        func isRandom(_ p: PlayerSetup) -> Bool { p.chosenCiv == "Random" || !majorNames.contains(p.chosenCiv) }
        let ordered = players.enumerated().sorted { a, b in
            (isRandom(a.element) ? 1 : 0, a.element.isHuman ? 0 : 1, a.offset) < (isRandom(b.element) ? 1 : 0, b.element.isHuman ? 0 : 1, b.offset)
        }.map { $0.element }
        for p in ordered where !isRandom(p) { result.append((p.chosenCiv, p.isHuman, p.playerId)) }
        // Humans before AI (the sort above) so a random human is never squeezed out by the pool; then Unciv's
        // `(0 until extraRandomAIPlayers).map { Player() }` - random AI players.
        let randomPlayers = ordered.filter { isRandom($0) }
        let numberOfRandom = randomPlayers.count + extraRandomAIPlayers
        var i = 0
        while i < numberOfRandom, !(preset.isEmpty && available.isEmpty) {
            let human = i < randomPlayers.count ? randomPlayers[i].isHuman : false
            let pid = i < randomPlayers.count ? randomPlayers[i].playerId : ""
            result.append((preset.isEmpty ? available.removeFirst() : preset.removeFirst(), human, pid)); i += 1
        }
        // Unciv: nonrandom players first, then random; shufflePlayerOrder mixes everyone.
        if s.shufflePlayerOrder { result = rng.shuffled(result) }
        s.playerNation = result.first(where: { $0.isHuman })?.nation ?? result.first?.nation ?? rs.majorNations.first?.name ?? "Random"
        s.humanPlayers = max(1, result.filter { $0.isHuman }.count)
        s.opponentCount = result.count - s.humanPlayers
        // Unciv chooseCivilizations is @Readonly: gameParameters.players stays the setup as it was chosen - "Random" seats,
        // the Spectator seat where the player put it - which the save writes, TileMap.isWaterMap counts and
        // GameSetupInfo(gameInfo) clones for "Start new game" (ours put the drawn nations there, so a new game started
        // from a finished one kept its nations). Legacy settings without seats get the seats they stand for.
        s.players = setupPlayers
        return spectators + result
    }
}

/// Unciv MapType names for the generated map types and their example previews.
enum MapTypeInfo {
    static let generatedTypes = ["Pangaea", "Small Continents", "Perlin", "Fractal", "Continent and Islands", "Archipelago", "Two Continents", "Three Continents", "Inner Sea", "Lakes", "Four Corners", "Spiral", "Boreal"]
}

/// Unciv Constants.spectator: the spectator's nation, and the key the map editor's "Any Civ" locations are stored under.
fileprivate let spectatorNation = "Spectator"
/// One of Unciv's `allCivs` (gameInfo.civilizations less the barbarians) as GameStarter.getStartingLocations sees it.
fileprivate struct StartCiv { let name: String; let isCityState: Bool; let isHuman: Bool; let isSpectator: Bool }

/// Unciv GameStarter.addCivStartingUnits' placement. getCandidateLand once, for `allCivs.size` civilizations (the
/// spectator included); then getStartingLocations over `bestCivs` - the majors and the city-states that have a
/// location - whose starts each become that nation's only location (removeStartingLocations + addStartingLocation),
/// and getStartingLocations again over every civilization. `marks` is tileMap.startingLocationsByNation, the "Any Civ"
/// locations under the Spectator. getStartingLocations: the civilizations in getCivsOrderedByAvailableLocations
/// order, a minimum distance counting down from tileMatrix.size / 6 (halved after a city-state), the tiles far enough
/// from the edge by start score, and getCivStartingLocation - one of the civ's own locations, else one of the "Any
/// Civ" ones (used up), else getOneStartingLocation's bias filters with a random pick.
fileprivate func uncivCivStartingLocations(_ allCivs: [StartCiv], map: GameMap, marks: inout [String: [HexCoord]], regions: MapRegions, noStartBias: Bool, rng: inout SeededRandom) throws -> [String: HexCoord] {
    guard !allCivs.isEmpty else { return [:] }
    let rs = Ruleset.shared
    // getCandidateLand: tileMap.assignContinents(Ensure), then continents by size (continentsSortedBySize) until 90%
    // of the land area, or one per civilization - over the ids stored on the tiles at map generation
    var map = map
    map.assignContinents(.ensure)
    let civCount = allCivs.count   // Unciv getCandidateLand(allCivs.size, …)
    let totalArea = map.continentSizes.values.reduce(0, +)
    var candidateArea = 0
    var candidates: Set<Int> = []
    for (index, id) in map.continentsSortedBySize.enumerated() {
        candidateArea += map.continentSizes[id]!; candidates.insert(id)
        if Float(candidateArea) >= Float(totalArea) * 0.9 { break }   // Unciv: Int >= Int * 0.9f, in Float
        if index >= civCount { break }
    }
    // TileStatFunctions.getTileStartScore
    let centerMinimum: Stats = rs.improvements["City center"]?.uniqueObjects.first(where: { $0.pattern == "Ensures a minimum tile yield of []" })?.stats ?? { var st = Stats(); st.food = 2; st.production = 1; return st }()
    // TileStatFunctions.getTileStartYield: getTerrainStatsBreakdown().toStats() - base, natural wonder, then features;
    // a nullifying terrain alone, an overriding one replacing everything before it - then the resource, then what is
    // missing from the minimum. No river (getTileStats adds that, the breakdown does not), no improvement.
    func startYield(_ t: Tile, _ minimum: Stats?) -> Double {
        var st = Stats()
        for name in [t.baseTerrain] + (t.naturalWonder.map { [$0] } ?? []) + t.features {
            guard let terrain = rs.terrains[name] else { continue }
            var terrainStats = terrain.stats   // getSingleTerrainStats: the terrain, then its Stats uniques (empty context)
            for u in terrain.uniqueObjects where u.pattern == "[]" && u.conditionals.isEmpty { if let extra = u.stats { terrainStats += extra } }
            if terrain.uniques.contains("Nullifies all other stats this tile provides") { st = terrainStats; break }
            if terrain.overrideStats { st = terrainStats } else { st += terrainStats }
        }
        if let r = t.resource.flatMap({ rs.resources[$0] }) { st += r.stats }   // `add(tile.tileResource!!)`, seen or not
        if let m = minimum { st.food = max(st.food, m.food); st.production = max(st.production, m.production); st.gold = max(st.gold, m.gold) }
        return st.food + st.production + st.gold
    }
    func adjacentToCoast(_ c: HexCoord) -> Bool { map.isAdjacentToCoast(c) }   // Unciv Tile.isAdjacentToCoast (a lazy, see GameMap)
    func startScore(_ c: HexCoord) -> Double {
        guard let t = map[c] else { return 0 }
        let around = Set(map.neighbors(of: c))
        var sum = 0.0
        for n in map.tilesWithin(c, radius: 2) {
            guard let nt = map[n] else { continue }
            let y = startYield(nt, n == c ? centerMinimum : nil)
            sum += y
            if around.contains(n) { sum += y }
        }
        if t.isHill { sum -= 2 }
        if t.riverAdjacent { sum += 2 }
        if around.contains(where: { map[$0]?.isMountain == true }) { sum += 2 }
        let coastal = adjacentToCoast(c)
        if coastal { sum += 3 }
        if !coastal && around.contains(where: { adjacentToCoast($0) }) { sum -= 7 }
        return sum
    }
    // HexMath.getDistanceFromEdge(tile.position, tileMap.mapParameters): on Unciv's own positions, against the map's
    // shape and mapSize (a map saved without it falls back to what its grid stands for)
    let edgeSize = map.uncivSize ?? (map.hexRadius.map { UncivMapSize(radius: $0, shape: "Hexagonal") } ?? UncivMapSize(width: map.width, height: map.height, shape: "Rectangular"))
    func distanceFromEdge(_ c: HexCoord) -> Int { HexMath.distanceFromEdge(map.uncivPosition(c), mapSize: edgeSize, worldWrap: map.wrapX) }
    let land = map.tiles.indices.filter { candidates.contains(map.tiles[$0].continent) }.map { (map.tiles[$0].coord, startScore(map.tiles[$0].coord)) }
    // Unciv tileMap.naturalWonders: the natural wonders on this map
    let mapWonders = Set(map.tiles.compactMap { $0.naturalWonder })
    var byNation = marks
    // getCivsOrderedByAvailableLocations: shuffled ("Order should be random since it determines who gets best start"),
    // sorted by how hard the start is to find, then humans first ("More important for humans to get their start biases!")
    func orderedByAvailableLocations(_ civs: [StartCiv]) -> [StartCiv] {
        let shuffled = rng.shuffled(civs)
        return shuffled.enumerated().map { (pos, c) -> (Int, Int, Int, StartCiv) in
            let bias = regions.startBias(nation: c.name)
            let category = byNation[c.name] != nil ? 1   // `civ.civID in tileMap.startingLocationsByNation`: harshest requirements
                : !noStartBias && bias.contains(where: { mapWonders.contains($0) }) ? 2
                : !noStartBias && bias.contains("Tundra") ? 3   // Tundra starts are hard to find, so let's do them first
                : !noStartBias && !bias.isEmpty ? 4 : 5
            return (c.isHuman ? 0 : 1, category, pos, c)
        }.sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }.map { $0.3 }
    }
    // getOneStartingLocation
    func oneStartingLocation(_ c: StartCiv, _ free: [HexCoord]) -> HexCoord {
        if noStartBias { return rng.pick(free)! }
        let biases = regions.startBias(nation: c.name)
        if biases.contains(where: { mapWonders.contains($0) }) {
            // startPref wants Natural wonder neighbor: `sortedByDescending { startScores[it] }.firstOrNull()` over every tile
            if let wonder = map.tiles.filter({ t in t.naturalWonder.map { biases.contains($0) } ?? false }).max(by: { startScore($0.coord) < startScore($1.coord) }) {
                return wonder.coord
            }
        }
        var preferred = free
        for bias in biases {
            if bias.hasPrefix("Avoid ["), bias.hasSuffix("]") {
                let avoid = String(bias.dropFirst(7).dropLast())
                preferred = preferred.filter { c in !map.tilesWithin(c, radius: 1).contains { map[$0].map { regions.terrainMatches($0, avoid) } ?? false } }
            } else if mapWonders.contains(bias) {
                continue   // passthrough: already failed
            } else {
                preferred = preferred.filter { c in map.tilesWithin(c, radius: 1).contains { map[$0].map { regions.terrainMatches($0, bias) } ?? false } }
            }
        }
        return rng.pick(preferred) ?? rng.pick(free)!
    }
    // getCivStartingLocation
    func civStartingLocation(_ c: StartCiv, _ free: [HexCoord]) -> HexCoord? {
        if let own = byNation[c.name], let pick = rng.pick(own) { return pick }   // `startingLocationsByNation[civ.civID]?.randomOrNull(rng)`
        if let anyCiv = byNation[spectatorNation], let pick = rng.pick(anyCiv), let at = anyCiv.firstIndex(of: pick) {
            byNation[spectatorNation]!.remove(at: at)   // an "Any Civ" location is used up
            return pick
        }
        return free.isEmpty ? nil : oneStartingLocation(c, free)
    }
    // getStartingLocations: nil where Unciv throws "Didn't manage to get starting tiles even with distance of 1?"
    func startingLocations(_ civs: [StartCiv]) -> [String: HexCoord]? {
        let ordered = orderedByAvailableLocations(civs)
        // Unciv: `for (minimumDistanceBetweenStartingLocations in tileMap.tileMatrix.size / 6 downTo 0)`
        for minimumDistance in stride(from: map.uncivTileMatrixSize / 6, through: 0, by: -1) {
            // getFreeTiles: far enough from the edge, by start score (a stable sortedBy)
            var free = land.enumerated().filter { distanceFromEdge($0.element.0) >= (minimumDistance * 2) / 3 }
                .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map { $0.element.0 }
            // getStartingLocationsForCivs: a HashMap<Civilization, Tile>, so every Spectator counts on its own
            var placed: [String: HexCoord] = [:]
            var placedCount = 0
            for c in ordered {
                guard let at = civStartingLocation(c, free) else { break }
                placed[c.name] = at
                placedCount += 1
                // "We allow city states to squeeze in tighter"
                let near = Set(map.tilesWithin(at, radius: minimumDistance / (c.isCityState ? 2 : 1)))
                free.removeAll { near.contains($0) }
            }
            if placedCount == ordered.count { return placed }
        }
        return nil
    }
    // "First we get start locations for the major civs, on the second pass the city states (without predetermined
    // starts) can squeeze in wherever"
    let bestCivs = allCivs.filter { (!$0.isCityState || byNation[$0.name] != nil) && !$0.isSpectator }
    // Unciv getStartingLocations throws on either pass (StartingTilesError), and the game is not started
    guard let best = startingLocations(bestCivs) else { throw StartingTilesError() }
    for (name, at) in best { byNation[name] = [at] }   // "Mark the best start locations so we remember them for the second pass"
    guard let result = startingLocations(allCivs) else { throw StartingTilesError() }
    marks = byNation
    return result
}
