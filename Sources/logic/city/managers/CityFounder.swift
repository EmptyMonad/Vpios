// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/city/managers/CityFounder.kt`: founding a city, and choosing where a city may be founded.
extension GameState {
    /// Unciv Tile.canBeSettled: land, passable, no city within minimalCityDistance on the same continent
    /// (minimalCityDistanceOnDifferentContinents across continents), not inside another civ's territory
    func canFoundCity(at c: HexCoord, civId: Int? = nil) -> Bool {
        guard let tile = map[c], tile.isLand, !tile.isImpassable else { return false }
        if let owner = tile.ownerCivId, owner != civId { return false }
        let continent = continentId(of: c)
        for city in cities {
            let d = city.coord.distance(to: c)
            if d <= (continentId(of: city.coord) == continent ? rs.constants.minimalCityDistance : rs.constants.minimalCityDistanceOnDifferentContinents) { return false }
        }
        return true
    }

    /// Score of a tile as a potential city site (used by the AI and the settler hint).
    func citySiteScore(_ c: HexCoord, civId: Int) -> Double {
        guard canFoundCity(at: c, civId: civId), let tile = map[c] else { return -1 }
        var score = 0.0
        for n in map.tilesWithin(c, radius: 2) {
            guard let t = map[n], t.ownerCivId == nil else { continue }
            let y = yields(of: t, for: civId)
            score += y.food * 1.4 + y.production * 1.2 + y.gold * 0.6
            if t.resource != nil { score += 2 }
            if t.isWater { score += 0.4 }
        }
        if tile.isHill { score += 3 }
        if map.neighbors(of: c).contains(where: { map[$0]?.baseTerrain == "Coast" || map[$0]?.baseTerrain == "Lakes" }) { score += 3 }
        if tile.baseTerrain == "Snow" || tile.baseTerrain == "Desert" { score -= 6 }
        return score
    }
    /// Unciv CityFounder.generateNewCityName: the nation's first unused name (cities of living civs), a borrowed one
    /// for a nation that borrows, else "New [x]" / "Neo [x]" / ... with up to ten prefixes; null → the fallback.
    private func generateNewCityName(_ civId: Int) -> String? {
        guard let civ = civ(civId) else { return nil }
        let names = civ.nationDef?.cities ?? []
        let usedNames = Set(cities.map { $0.name })
        if let free = names.first(where: { !usedNames.contains($0) }) { return free }
        if borrowsCityNames(civId) { return borrowedCityName(for: civId) }   // Unciv returns the borrowed name, or null
        for number in 1...10 {
            for prefix in ["New ", "Neo ", "Nova ", "Altera "] {   // Unciv: the same four prefixes, in this order
                let head = String(repeating: prefix + "[", count: number), tail = String(repeating: "]", count: number)
                for base in names where !usedNames.contains(head + base + tail) { return head + base + tail }
            }
        }
        return nil
    }

    /// Unciv Civilization.addCity → CityFounder.foundCity, then `chooseNextConstruction()`; the found-city action
    /// destroys the settler afterwards (UnitActionsFromUniques.getFoundCityAction). In CityFounder's order:
    /// the city's fields and name, isOriginalCapital / citiesCreated, the city joins civ.cities, expansion.reset()
    /// (takeOwnership of the centre, then of every unowned tile of the first ring - each one autoAssignPopulation,
    /// updateOurTiles and cityStats.update), tryUpdateRoadStatus, the removable features off the centre,
    /// setImprovement(City center) with its updateCity, stopWorkingOnImprovement, the worked tiles cleared,
    /// setPopulation(starting era's settlerPopulation), the pantheon pressure, autoAssignPopulation, proximity,
    /// triggerCitiesSettledNearOtherCiv, addStartingBuildings (the capital indicator and the starting era's buildings
    /// through addBuilding(tryAddFreeBuildings = false), then tryAddFreeBuildings), resetDisabledConstructions,
    /// resetSpecialistsControl and the founding triggers.
    /// Ours claimed the tiles and wrote the buildings straight into the city, took the settler population and
    /// buildings from the civ's CURRENT era instead of the game's starting era (a Medieval civ got a free Shrine and
    /// Monument in every new city), and assigned the citizens only once at the end.
    @discardableResult
    func foundCity(with unitId: Int) -> City? {
        guard let ui = unitIndex(unitId) else { return nil }
        let unit = units[ui]
        guard unit.def.isSettler, unit.movementLeft > 0, canFoundCity(at: unit.coord, civId: unit.civId), civIndex(unit.civId) != nil else { return nil }
        if settings.oneCityChallenge, let owner = civ(unit.civId), owner.isPlayer, owner.hasEverOwnedOriginalCapital { return nil }   // Unciv isOneCityChallenger
        // Unciv getFoundCityAction: `if (unit.civ.playerType != PlayerType.AI) addCompletedTutorialTask("Found city")` first
        if civ(unit.civId)?.isPlayer == true { Tutorial.markTaskDone("Found city") }
        guard let cityId = foundCity(civId: unit.civId, at: unit.coord, unitId: unitId) else { return nil }
        // Unciv Civilization.addCity: `foundCity(...)` then `chooseNextConstruction()` - while the settler still
        // exists; the found-city action destroys the unit only afterwards.
        chooseNextConstructionIfAutomated(cityId: cityId)   // humans without auto-assign: "Pick construction"
        // Unciv UnitActionsFromUniques.getFoundCityAction: `if (hasActionModifiers) activateSideEffects(unit, unique)
        // else unit.destroy()` - the G&K Settler's "<by consuming this unit>" makes it unit.consume(), with its
        // "upon expending" triggers, then MapUnit.destroy().
        let actionModifiers: Set<String> = ["by consuming this unit", "for [] movement", "requires [] movement", "for all movement", "[] times", "once",
                                            "after which this unit is consumed", "[] additional time(s)", "costs [] stats", "costs [] []", "removing the [] promotion/status"]
        if let foundUnique = unit.def.uniqueObjects.first(where: { $0.pattern == "Founds a new city" || $0.pattern == "Founds a new puppet city" }),
           foundUnique.conditionals.contains(where: { actionModifiers.contains($0.pattern) }) {
            activateActionSideEffects(unitId: unitId, unique: foundUnique)
        } else {
            destroyUnit(unitId)
        }
        // Unciv FoundPuppetCity: the city is made a puppet after the settler is gone
        if unit.def.uniques.contains(where: { $0.hasPrefix("Founds a new puppet city") }), let cx = cityIndex(cityId) { cities[cx].isPuppet = true }
        return self.city(cityId)
    }

    /// Unciv CityFounder.foundCity(civInfo, cityLocation, unit): everything from the new city's fields to the founding
    /// triggers (the unit's own "upon founding a city" ones only when a unit founds it). The console's `city add`
    /// (Unciv Civilization.addCity) calls it without a unit, on any tile.
    @discardableResult
    func foundCity(civId: Int, at center: HexCoord, unitId: Int?) -> Int? {
        guard let ci = civIndex(civId) else { return nil }
        let civ = civs[ci]
        var city = City(id: newId(), civId: civId, name: "", coord: center)
        city.acquiredTurn = turn - 1   // Unciv CityFounder: turnAcquired = gameInfo.turns (our turn is Unciv's + 1)
        // Unciv City.setTransients assigns the id before the city joins civ.cities, so the seed is the count without it.
        city.uncivId = pseudoRandomCityId(civId: civId)
        city.name = generateNewCityName(civId) ?? "City Without A Name"   // Unciv NamingConstants.fallback
        city.foundedTurn = turn
        city.originalOwner = civId
        city.religionPressure[noReligionName] = 100   // Unciv CityReligionManager.clearAllPressures
        // Unciv CityFounder.kt:32 decides "original capital" from the lifetime counter, so a civ that loses every
        // city and settles again never gets a second original capital.
        if civ.citiesCreated == 0 { city.isOriginalCapital = true; civs[ci].hasEverOwnedOriginalCapital = true; civs[ci].shouldOpenPolicyPicker = true }
        civs[ci].citiesCreated += 1
        cities.append(city)
        registerCity(city.id, with: civId)   // Unciv `civInfo.cities = civInfo.cities.withItem(city)`
        if GameState.evlogOn { ev(civId, "CITY_NEW", EvLog.name(city.name), evPos(center)) }
        let cityId = city.id
        let startingEra = rs.era(named: settings.startingEra) ?? rs.ancientEra   // Unciv: ruleset.eras[gameParameters.startingEra]

        // Unciv CityExpansionManager.reset(): takeOwnership(centre), then forEachTileInDistance(1) { getCity() == null }.
        // The centre goes through takeOwnership's own steps here, because the centre becomes the city centre the
        // moment Tile.setOwningCity runs, which our takeOwnership (it refuses a city centre) cannot model.
        if let cx = cityIndex(cityId) {
            // Unciv takeOwnership: `if (tile.getCity() != null) tile.getCity()!!.expansion.relinquishOwnership(tile)` -
            // a city founded inside a sister city's borders first takes the tile away from that city (its tiles,
            // the citizen working it, the "Creates one improvement" marker, updateOurTiles, cityStats.update).
            // `isCityCenter()` is still false at that point: the owning city's location is elsewhere.
            if let prev = map[center]?.ownerCivId,
               let pc = cities.first(where: { $0.id != cityId && $0.civId == prev && $0.tiles.contains(center) })?.id {
                relinquishOwnership(cityId: pc, center)
            }
            cities[cx].tilesWithItem(center, walk: uncivTileWalk(cities[cx]))   // `city.tiles = city.tiles.withItem(tile.position)`
            map[center]?.ownerCivId = civId
            map[center]?.workingCityId = nil
            setOwningCityRoadOwner(at: center, civId: civId)   // Tile.setOwningCity: the previous neutral road owner lets the tile go
            map[center]?.cityId = cityId   // Tile.setOwningCity: isCityCenterInternal
            assignWorkers(cityId: cityId, onlyFreePopulation: true, why: "CityFounder:reset")   // autoAssignPopulation
            updateExploration(for: civId); updateCivResources(civId)   // updateOurTiles
            invalidateHappiness(civId)
            updateCityStats(cityId, reason: "CityFounder:reset")
        }
        for n in map.tilesWithin(center, radius: 1) where n != center && map[n]?.ownerCivId == nil {
            takeOwnership(cityId: cityId, n)
        }
        tryUpdateRoadStatus(cityId: cityId)   // Unciv CityFounder: right after expansion.reset()
        // Unciv: every terrain feature that has a "Remove [feature]" improvement is removed from the centre
        map[center]?.features.removeAll { rs.improvements["Remove \($0)"] != nil }
        // Unciv: `tile.setImprovement(Constants.cityCenter, civInfo)` - "Ensures a minimum tile yield of [+2 Food,
        // +1 Production]" lives on that improvement - and setImprovement's updateVisibility and updateCity
        // (cityStats.update, updateCivResources, reassignPopulationDeferred).
        if rs.improvements["City center"] != nil {
            map.update(center) { $0.improvement = "City center"; $0.pillaged = false }
            for j in civs.indices where civs[j].isMajor && civs[j].isAlive && !isDefeated(civs[j]) && (civs[j].id == civId || visibleTiles(for: civs[j].id).contains(center)) {
                civs[j].lastSeenImprovement[center] = "City center"
            }
            updateCityStats(cityId, reason: "CityFounder:setImprovement")
            updateCivResources(civId)
            if let cx = cityIndex(cityId) { reassignPopulationDeferred(cx) }
        }
        stopWorkingOnImprovement(at: center)   // Unciv tile.stopWorkingOnImprovement()
        // Unciv `city.workedTiles = hashSetOf()` - "reassign 1st working tile"
        if let cx = cityIndex(cityId) {
            for t in cities[cx].workedTiles where map[t]?.workingCityId == cityId { map[t]?.workingCityId = nil }
            cities[cx].workedTiles = []; cities[cx].workedTilesTable = 0   // a new, empty HashSet
            // Unciv population.setPopulation(settlerPopulation) = addPopulation(-population + count)
            addPopulation(cityIndex: cx, startingEra.settlerPopulation - cities[cx].population)
        }
        // Unciv: `if (religionState == Pantheon) city.religion.addPressure(religion.name, 200 * population)` -
        // addPressure updates the followers, which on a new majority refreshes the civ's resources, and on a
        // changed following the city's stats.
        if religionEnabled, let p = civs[ci].pantheonBelief, civs[ci].religionName == nil, civs[ci].pendingReligion != "founding", let cx = cityIndex(cityId) {   // ReligionState.Pantheon, not FoundingReligion
            addPressure(cityIndex: cx, p, 200 * cities[cx].population)
        }
        assignWorkers(cityId: cityId, onlyFreePopulation: true, why: "CityFounder:autoAssign")   // Unciv population.autoAssignPopulation()
        updateProximityAfterFounding(civId)   // Unciv CityFounder: "Update proximity rankings for all civs"
        if let c = self.city(cityId) { triggerCitiesSettledNearOtherCiv(c) }   // the founder need not be a major civ
        // Unciv CityFounder.addStartingBuildings
        if cities(of: civId).count == 1, let cx = cityIndex(cityId), let indicator = capitalCityIndicator(civId, city: cities[cx]) {
            civs[ci].capitalCityId = cityId
            addBuilding(cityIndex: cx, indicator, tryAddFreeBuildings: false)
        }
        for b in startingEra.settlerBuildings where rs.buildings[b] != nil {
            // Unciv getEquivalentBuilding: the nation's replacement stands in for the building it replaces
            let own = rs.buildings.values.first { $0.replaces == b && $0.uniqueTo == civs[ci].nation }?.name ?? b
            if let cx = cityIndex(cityId), canProduce(.building(own), in: cities[cx]) { addBuilding(cityIndex: cx, own, tryAddFreeBuildings: false) }   // Unciv: `if (uniqueBuilding.isBuildable(city.cityConstructions))`
        }
        tryAddFreeBuildings(civId)   // Unciv addStartingBuildings ends in civConstructions.tryAddFreeBuildings()
        // Unciv CityFounder: `city.resetDisabledConstructions()` then `city.resetSpecialistsControl()`, right after
        // addStartingBuildings - until then the new city has no disabled constructions and automatic specialists.
        if let cx = cityIndex(cityId) {
            cities[cx].disabledConstructions = civs[ci].isPlayer ? civs[ci].disabledCivConstructions : []
            resetSpecialistsControl(cityIndex: cx)
        }
        // Unciv: TriggerUponFoundingCity - the civ's uniques (cities included), then the settler's own
        triggerConditionalUniques(civId: civId, cityId: cityId, unitId: unitId, triggerText: "due to founding a city") { $0.pattern == "upon founding a city" }
        return cityId
    }
}
