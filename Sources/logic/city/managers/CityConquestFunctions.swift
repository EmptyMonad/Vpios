// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/city/managers/CityConquestFunctions.kt`: a city changing hands - by conquest (puppet,
/// annex, raze), by liberation, or by trade - plus the city part of Unciv `Battle.conquerCity` and
/// `Battle.automateCityConquer` that decides which of those happens.
///
/// Every function below is one Unciv function, in Unciv's order, calling the same side-effect chain: buildings come
/// and go through addBuilding / removeBuilding (updateUniques: capital connections, the city's stats and through them
/// the owner's updateStatsForNextTurn, the owner's resources), citizens through addPopulation / autoAssignPopulation /
/// reassignAllPopulation, and the owners' caches through updateOurTiles. WHO owns the city at each step decides whose
/// caches those updates touch, so the ownership change sits exactly where moveToCiv puts it.
extension GameState {

    // MARK: Battle.conquerCity (the city part) and Battle.automateCityConquer

    /// Unciv `Battle.conquerCity(city, attacker)`, from the notification on: the units in the centre, the plunder
    /// uniques, then the decision - retaking our own original capital (puppet + annex), a human's popup, or the AI's
    /// automateCityConquer - and last the "upon conquering a city" triggers. Barbarians never get here: Battle
    /// raids the city instead (Battle.handleCityDefeated).
    ///
    /// A human's conquest stays with the old owner until the CityConquered popup is answered - City.hasJustBeenConquered
    /// (set by Battle) lets the attacker move in meanwhile and keeps other attackers off it. The popup's options then
    /// call Unciv's functions (AlertPopup.addCityConquered): Annex, Puppet, Raze and Destroy begin with puppetCity,
    /// Liberate calls liberateCity while the loser still owns the city.
    /// The decision half of Unciv `Battle.conquerCity` - the units in the centre, the plunder uniques and the barbarian
    /// / one-city-challenger destruction happen first in Battle.swift's conquerCity, which then calls this.
    func conquerCityDecision(cityId: Int, by civId: Int, attackerUnitId: Int? = nil) {
        guard let ci = cityIndex(cityId), let attackerCiv = civ(civId) else { return }
        let city = cities[ci]
        let humanDecides = attackerCiv.isPlayer && !autoPlayingFullAI   // Battle.kt:717: isHuman() && isAutoPlayingAndFullAutoPlayAI() == false
        if city.isOriginalCapital && city.originalOwner == civId {
            // retaking our old capital: no question asked, and no "May not annex cities" check either
            puppetCity(cityId: cityId, by: civId)
            annexCity(cityId: cityId)
        } else if humanDecides {
            // Unciv: `attackerCiv.popupAlerts.add(PopupAlert(AlertType.CityConquered, city.id))` - nothing else; the
            // city stays the loser's until the player picks an option (see the note above)
            addAlert(civId, .CityConquered, "\(cityId)")
        } else {
            automateCityConquer(civId: civId, cityId: cityId)
        }
        // Unciv: `if (attackerCiv.isCurrentPlayer()) addCompletedTutorialTask("Conquer a city")` - currentPlayerCiv stays the
        // human while GameInfo.nextTurn walks the AIs, so only the current human's conquest completes it
        if civId == playerId { Tutorial.markTaskDone("Conquer a city") }
        // Unciv: `attackerCiv.getTriggeredUniques(TriggerUponConqueringCity) + attacker.unit.getTriggeredUniques(...)`,
        // each `triggerUnique(unique, attacker.unit)`.
        triggerConditionalUniques(civId: civId, unitId: attackerUnitId) { $0.pattern == "upon conquering a city" }
        // Unciv judges victory in TurnManager (startTurn / endTurn → updateWinningCiv), never here; a civ this
        // conquest defeated was already destroyed by conquerCity's Battle.destroyIfDefeated.
    }

    /// Unciv `Battle.automateCityConquer`: liberate a city-state's city when the alliance is worth it (more so while
    /// unhappy), otherwise puppet it - and raze it when it is small (or we are a city-state) and not ours to begin with.
    func automateCityConquer(civId: Int, cityId: Int) {
        guard let ci = cityIndex(cityId) else { return }
        let city = cities[ci]
        if !hasDiplomaticMarriage(city), let founder = civ(city.originalOwner) {
            var valueAlliance = founder.isCityState ? valueCityStateAlliance(civId, founder.id) : 0
            if happiness(of: civId) < 0 { valueAlliance -= happiness(of: civId) }   // put extra weight on liberating if unhappy
            if founder.isCityState && city.civId != civId && founder.id != civId && !areAtWar(civId, founder.id) && valueAlliance > 0 {
                liberateCity(cityId: cityId, by: civId)
                return
            }
        }
        puppetCity(cityId: cityId, by: civId)
        guard let ci2 = cityIndex(cityId) else { return }
        if (cities[ci2].population < 4 || civ(civId)?.isCityState == true)
            && cities[ci2].originalOwner != civId && canBeDestroyed(cities[ci2], justCaptured: true) {
            // raze if attacker is a city state
            if !mayNotAnnexCities(civId) { annexCity(cityId: cityId) }
            cities[ci2].razing = true
        }
    }

    // MARK: AlertPopup.addCityConquered - the human conqueror's answer

    /// Unciv AlertPopup.addCityConquered, Puppet: `city.puppetCity(conqueringCiv)`. Every option but Liberate starts
    /// here. (A save from before the popup waited already holds the city puppeted - nothing to conquer again.)
    func puppetConqueredCity(cityId: Int, by civId: Int) {
        guard let c = city(cityId), c.civId != civId else { return }
        puppetCity(cityId: cityId, by: civId)
    }

    /// Unciv AlertPopup.addAnnexOption: `annexAction()` (puppetCity), then `city.annexCity()`.
    func annexConqueredCity(cityId: Int, by civId: Int) {
        puppetConqueredCity(cityId: cityId, by: civId)
        annexCity(cityId: cityId)
    }

    /// Unciv AlertPopup.addRazeOption: puppetCity, annexCity when the civ may annex, then `isBeingRazed = true`.
    func razeConqueredCity(cityId: Int, by civId: Int) {
        puppetConqueredCity(cityId: cityId, by: civId)
        if !mayNotAnnexCities(civId) { annexCity(cityId: cityId) }
        if let ci = cityIndex(cityId) { cities[ci].razing = true }
    }

    /// Unciv AlertPopup.addCityConquered for a one-city challenger, Destroy: puppetCity, then destroyCity.
    func destroyConqueredCity(cityId: Int, by civId: Int) {
        puppetConqueredCity(cityId: cityId, by: civId)
        destroyCity(cityId: cityId)
    }

    // MARK: CityConquestFunctions

    /// Unciv City.hasDiplomaticMarriage: `foundingCivObject == null`.
    func hasDiplomaticMarriage(_ city: City) -> Bool { city.originalOwner < 0 || civ(city.originalOwner) == nil }

    func mayNotAnnexCities(_ civId: Int) -> Bool { civUniques(civId).contains { $0.pattern == "May not annex cities" } }

    /// Unciv City.canBeDestroyed(justCaptured)
    func canBeDestroyed(_ city: City, justCaptured: Bool = false) -> Bool {
        if settings.noCityRazing { return false }
        let allowRazeCapital = rs.modOptionUniques.contains { $0.pattern == "Allow raze capital" }
        let allowRazeHolyCity = rs.modOptionUniques.contains { $0.pattern == "Allow raze holy city" }
        if city.isOriginalCapital && !allowRazeCapital { return false }
        if city.isHolyCity && !allowRazeHolyCity { return false }
        if city.isCapital && !justCaptured && !allowRazeCapital { return false }
        return true
    }

    /// Unciv CityConquestFunctions.getGoldForCapturingCity, in Float, drawing the first number of the city's
    /// `tileBasedRandom` (`Random(centerTile.position.hashCode())`).
    private func goldForCapturingCity(cityIndex ci: Int, conqueringCiv: Int, rng: inout SeededRandom) -> Int {
        let city = cities[ci]
        let baseGold = 20 + 10 * city.population + rng.int(0...39)
        // Unciv: `max(0, min(50, gameInfo.turns - turnAcquired)) / 50f`; our `turn` is Unciv's turns + 1
        let turnModifier = Float(max(0, min(50, (turn - 1) - city.acquiredTurn))) / 50
        let cityModifier = Float(goldGivenToEnemyMultiplier(city))
        let conqueringCivModifier = Float(plunderMultiplier(conqueringCiv))
        let goldPlundered = Float(baseGold) * turnModifier * cityModifier * conqueringCivModifier
        return Int(goldPlundered)
    }

    /// Unciv CityConquestFunctions.destroyBuildingsOnCapture: always-destroyed buildings go, wonders / "Never
    /// destroyed" / capital markers / buildings that move to the new capital stay, the rest go with 34% chance - each
    /// through removeBuilding while the city is still the loser's.
    private func destroyBuildingsOnCapture(cityIndex ci: Int, rng: inout SeededRandom) {
        for name in cities[ci].builtBuildingObjects {   // Unciv iterates getBuiltBuildings() as it was; removeBuilding replaces it
            guard let b = rs.buildings[name] else { continue }
            if b.uniques.contains("Never destroyed when the city is captured") || b.isWonder { continue }
            if b.uniques.contains("Indicates the capital city") { continue }
            if b.uniques.contains("Moves to new capital when capital changes") || b.uniques.contains("Moves to new capital") { continue }
            if b.uniques.contains(Names.destroyedOnCapture) { removeBuilding(cityIndex: ci, name); continue }
            if rng.int(0...99) < 34 { removeBuilding(cityIndex: ci, name) }
        }
    }

    /// Unciv CityConquestFunctions.removeAutoPromotion
    private func removeAutoPromotion(cityIndex ci: Int) {
        cities[ci].defaultPromotions = [:]
        cities[ci].useDefaultPromotions = []
    }

    /// Unciv CityConquestFunctions.removeBuildingsOnMoveToCiv. It runs AFTER moveToCiv has changed the owner (Unciv's
    /// "has *not* yet moved" comment is stale: `city.civ = newCiv` comes first), so every removeBuilding updates the
    /// NEW owner, and `city.civ.civConstructions.getFreeBuildingNames(city)` is the NEW owner's view: its own
    /// freeBuildings entry for this city (none, unless the city is coming back to the civ that granted it) plus the
    /// city's own GainFreeBuildings. The old owner's Legalism / Tradition grants stay standing and are paid for from
    /// now on; its record is never cleared. Then national wonders, and anything the new owner would now have at or
    /// above its "Limited to [] per Civilization".
    private func removeBuildingsOnMoveToCiv(cityIndex ci: Int) {
        let freeNames = freeBuildingNames(cities[ci])   // Unciv `city.civ.civConstructions.getFreeBuildingNames(city)`
        for n in freeNames where cities[ci].buildings.contains(n) { removeBuilding(cityIndex: ci, n) }
        cities[ci].freeBuildingsProvidedFromThisCity = []   // freeBuildingsProvidedFromThisCity.clear()
        let civId = cities[ci].civId
        for name in cities[ci].builtBuildingObjects {   // Unciv getBuiltBuildings(), a snapshot
            guard let def = rs.buildings[name] else { continue }
            if def.isNationalWonder && !def.uniques.contains("Never destroyed when the city is captured") {
                removeBuilding(cityIndex: ci, name)
            }
            for u in def.uniqueObjects where u.pattern == "Limited to [] per Civilization" {
                let count = cities(of: civId).filter { c in
                    containsBuildingOrEquivalent(c, name) || c.currentProduction?.name == name || c.productionQueue.contains { $0.name == name }
                }.count
                if count >= u.int(0) { removeBuilding(cityIndex: ci, name) }   // "For now, just destroy in new city"
            }
        }
    }

    /// Unciv CityConquestFunctions.conquerCity: what happens on any capture, be it puppet, annex or liberate.
    private func conquerCity(cityId: Int, conqueringCiv: Int, conqueredCiv: Int, receivingCiv: Int) {
        guard let ci = cityIndex(cityId) else { return }
        spiesFlee(fromCity: cityId, cityName: cities[ci].name, reason: .conquered)   // removeAllPresentSpies(CityCaptured)
        // One generator per CityConquestFunctions instance: plunder draws first, the buildings after it.
        var tileBasedRandom = SeededRandom(kotlinSeed: uncivPositionHash(cities[ci].coord))
        let goldPlundered = goldForCapturingCity(cityIndex: ci, conqueringCiv: conqueringCiv, rng: &tileBasedRandom)
        if let ni = civIndex(conqueringCiv) { civs[ni].gold += Double(goldPlundered); goldTrace(conqueringCiv, Double(goldPlundered)) }
        notify(conqueringCiv, "Received [\(goldPlundered)] Gold for capturing [\(cities[ci].name)]", category: .General, icons: ["Gold"], coord: cities[ci].coord)

        let reconqueredCityWhileStillInResistance = cities[ci].previousOwner == receivingCiv && cities[ci].resistanceTurns > 0

        destroyBuildingsOnCapture(cityIndex: ci, rng: &tileBasedRandom)

        moveToCiv(cityId: cityId, newCiv: receivingCiv)
        vpInstantYield(.conquest, civId: receivingCiv, cityId: cityId)   // VP

        // Unciv Battle.destroyIfDefeated(conqueredCiv, conqueringCiv)
        if let lost = civ(conqueredCiv), lost.isAlive, isDefeated(lost) { eliminate(civId: conqueredCiv, by: conqueringCiv, at: cities[ci].coord) }

        guard let cx = cityIndex(cityId) else { return }
        cities[cx].isOccupied = cities[cx].originalOwner != receivingCiv   // ours only: lets the city screen offer Liberate later
        cities[cx].health = cityMaxHealth(cities[cx]) / 2
        cities[cx].avoidGrowth = false
        cities[cx].cityFocus = "NoFocus"   // City.setCityFocus only sets the field
        // "from 2-4 population, remove 1, from 5-8, remove 2, etc." - addPopulation: unassignExtraPopulation and
        // cityStats.update on a loss
        if cities[cx].population > 1 { addPopulation(cityIndex: cx, -1 - cities[cx].population / 4) }
        if epochsTradeDbg {
            let h = happinessBreakdown(receivingCiv)
            print("CONQH t=\(turn) \(civ(receivingCiv)?.nation ?? "?") happy=\(happiness(of: receivingCiv)) total=\(h.total) rows=[\(h.rows.map { "\($0.0):\($0.1)" }.joined(separator: ","))]")
        }
        reassignAllPopulation(cityId: cityId)

        if !reconqueredCityWhileStillInResistance && cities[cx].originalOwner != receivingCiv {
            cities[cx].resistanceTurns = cities[cx].population   // setFlag(Resistance, population) - even when puppeted
        } else {
            cities[cx].resistanceTurns = 0   // reconquering or liberating a city in resistance ends it
        }
        triggerConditionalUniques(civId: conqueredCiv) { $0.pattern == "upon losing a city" }
    }

    /// Unciv CityConquestFunctions.puppetCity: happens when we either puppet OR annex - whenever we conquer a city
    /// and do not liberate it.
    func puppetCity(cityId: Int, by conqueringCiv: Int) {
        guard let ci = cityIndex(cityId) else { return }
        let oldCiv = cities[ci].civId
        // must be before moving the city to the conquering civ, so the repercussions are properly checked
        repercussionsForConqueringCity(cities[ci], oldCiv: oldCiv, conqueror: conqueringCiv)
        conquerCity(cityId: cityId, conqueringCiv: conqueringCiv, conqueredCiv: oldCiv, receivingCiv: conqueringCiv)
        makePuppet(cityId: cityId)
        updateCityStats(cityId, reason: "puppetCity")
    }

    /// Unciv CityConquestFunctions.makePuppet: the city could be producing something a puppet should not, like units -
    /// `cityConstructions.removeAll()` empties the queue (the in-progress work stays), lets the automation choose, and
    /// clears currentConstructionIsUserSet.
    private func makePuppet(cityId: Int) {
        guard let ci = cityIndex(cityId) else { return }
        cities[ci].isPuppet = true
        invalidateHappiness(cities[ci].civId)
        if GameState.evlogOn {
            // EVLOG: Unciv removeAll is one removeFromQueue(0) per entry, each ending in evProdCheck - the next
            // entry, and "-" (Idle) once the queue is empty; chooseNextConstruction's pick is printed after that.
            var q = (cities[ci].currentProduction.map { [$0] } ?? []) + cities[ci].productionQueue
            while !q.isEmpty { q.removeFirst(); EvLog.productionStep(cities[ci], q.first) }
        }
        cities[ci].productionQueue = []
        cities[ci].currentProduction = nil   // parks the stored work under its name, as inProgressConstructions keeps it
        cities[ci].convertProductionTo = City.idleConstruction   // removeFromQueue(0, false) on the last entry leaves PerpetualConstruction.Idle
        cities[ci].reservedImprovementTile = nil; cities[ci].reservedImprovement = ""   // removeFromQueue: the CreatesOneImprovement marker
        chooseNextConstruction(cityId: cityId)
        if let cx = cityIndex(cityId) { cities[cx].currentConstructionIsUserSet = false }
    }

    /// Unciv CityConquestFunctions.annexCity
    func annexCity(cityId: Int) {
        guard let ci = cityIndex(cityId) else { return }
        cities[ci].isPuppet = false
        if cities[ci].resistanceTurns == 0 { cities[ci].shouldReassignPopulation = true }
        cities[ci].avoidGrowth = false
        cities[ci].cityFocus = "NoFocus"
        invalidateHappiness(cities[ci].civId)
        updateCityStats(cityId, reason: "annexCity")
    }

    /// Unciv CityConquestFunctions.liberateCity: the city goes back to its founder, resurrecting it if need be.
    ///
    /// The whole conquerCity runs in every case, as in Unciv - also for a city the liberator itself owns (the CityTraded
    /// popup's Liberate): the plunder goes to the liberator, the 34% roll, the lost population, the halved health and
    /// the "upon losing a city" triggers of the liberator all happen.
    func liberateCity(cityId: Int, by conqueringCiv: Int) {
        guard let ci = cityIndex(cityId) else { return }
        guard !hasDiplomaticMarriage(cities[ci]) else {   // "this should never happen but just in case..."
            puppetCity(cityId: cityId, by: conqueringCiv)
            annexCity(cityId: cityId)
            return
        }
        let foundingCiv = cities[ci].originalOwner
        let oldCiv = cities[ci].civId
        guard foundingCiv != oldCiv else { return }

        diplomaticRepercussionsForLiberatingCity(cityId: cityId, conqueringCiv: conqueringCiv, conqueredCiv: oldCiv)

        conquerCity(cityId: cityId, conqueringCiv: conqueringCiv, conqueredCiv: oldCiv, receivingCiv: foundingCiv)
        guard let cx = cityIndex(cityId) else { return }
        cities[cx].isOccupied = false

        if cities(of: foundingCiv).count == 1 {
            // Resurrection!
            addBuilding(cityIndex: cx, Names.palace)   // capitalCityIndicator
            let libName = civ(conqueringCiv)?.nation ?? "?", founderName = civ(foundingCiv)?.nation ?? "?"
            // Unciv walks every civ of gameInfo.civilizations, a defeated one included (it still knows the civs it met)
            for j in civs.indices where !civs[j].isBarbarian && civs[j].id != foundingCiv && civs[j].id != conqueringCiv {
                let knowsLib = civs[j].metCivs.contains(conqueringCiv), knowsFounder = civs[j].metCivs.contains(foundingCiv)
                if knowsLib && knowsFounder { notify(civs[j].id, "[\(libName)] has liberated [\(founderName)]", category: .Diplomacy, icons: [founderName, "Diplomacy", libName]) }
                else if knowsLib { notify(civs[j].id, "[\(libName)] has liberated [an unknown civilization]", category: .Diplomacy, icons: ["Diplomacy", libName]) }
                else if knowsFounder { notify(civs[j].id, "[An unknown civilization] has liberated [\(founderName)]", category: .Diplomacy, icons: ["Diplomacy", founderName]) }
            }
        }
        cities[cx].isPuppet = false
        invalidateHappiness(foundingCiv)
        updateCityStats(cityId, reason: "liberateCity")

        // Move units out of the city when liberated
        let centre = cities[cx].coord
        for u in units(at: centre) { teleportToClosestMoveableTile(u.id) }
        if let c = city(cityId) {
            for t in uncivTileWalk(c) {
                for u in units(at: t) where !canPassThrough(u, u.coord) { teleportToClosestMoveableTile(u.id) }
            }
        }
    }

    /// Unciv CityConquestFunctions.diplomaticRepercussionsForLiberatingCity, the resurrection part: a major founder
    /// that had been defeated makes peace with everyone and starts its diplomacy from scratch. The rest (respect,
    /// open borders, city-state influence and peace, the third parties) is repercussionsForLiberatingCity.
    private func diplomaticRepercussionsForLiberatingCity(cityId: Int, conqueringCiv: Int, conqueredCiv: Int) {
        guard let ci = cityIndex(cityId), let fi = civIndex(cities[ci].originalOwner) else { return }
        let founder = civs[fi].id
        if civs[fi].isMajor && !civs[fi].isAlive {
            for other in knownCivs(founder).map(\.id) {
                if areAtWar(founder, other) { makePeace(founder, other) }
                civs[fi].diploFlags[other] = nil
                civs[fi].opinions[other] = nil
                if let oi = civIndex(other) { civs[oi].diploFlags[founder] = nil; civs[oi].opinions[founder] = nil }
            }
        }
        repercussionsForLiberatingCity(cities[ci], founder: founder, liberator: conqueringCiv, conquered: conqueredCiv)
    }

    /// Unciv CityConquestFunctions.moveToCiv: everything that happens whenever a city changes hands, trades included.
    func moveToCiv(cityId: Int, newCiv: Int) {
        guard let ci0 = cityIndex(cityId), civIndex(newCiv) != nil else { return }
        let oldCiv = cities[ci0].civId

        // Remove/relocate the palace for the old civ BEFORE the city moves, so the capital indicator is judged
        // among the conquered civ's own buildings.
        if cities[ci0].isCapital { moveCapitalToNextLargest(civId: oldCiv, oldCapital: cities[ci0]) }

        guard let ci = cityIndex(cityId) else { return }
        cities[ci].civId = newCiv
        registerCity(cityId, with: newCiv)   // oldCiv.cities -= city; newCiv.cities += city (appended)
        if GameState.evlogOn { ev(newCiv, "CITY_NEW", EvLog.name(cities[ci].name), evPos(cities[ci].coord)) }
        if let ni = civIndex(newCiv) { civs[ni].isAlive = true }   // Unciv's isAlive is `!isDefeated()`, and it now has a city
        // The tiles belong to the city, so their owner is now the new civ; a tile counts as worked for the new owner
        // only when this city works it (Tile.getWorkingCity looks among the OWNER's cities).
        for t in cities[ci].tiles {
            map[t]?.ownerCivId = newCiv
            map[t]?.workingCityId = cities[ci].workedTiles.contains(t) ? cityId : nil
        }
        // Unciv City.isConnectedToCapital reads the OWNER's citiesConnectedToCapitalToMediums, which holds this city
        // only after the new owner's next updateCitiesConnectedToCapital.
        cities[ci].connectedToCapital = false
        railroadCache[newCiv] = nil
        cities[ci].hasJustBeenConquered = false   // Unciv moveToCiv
        cities[ci].acquiredTurn = turn - 1   // Unciv turnAcquired = gameInfo.turns
        cities[ci].previousOwner = oldCiv
        invalidateHappiness(oldCiv); invalidateHappiness(newCiv)

        // now that the tiles have changed, we need to reassign population
        for t in cities[ci].workedTiles.filter({ !cities[ci].tiles.contains($0) }) {
            stopWorkingTile(cityId: cityId, t)
            assignWorkers(cityId: cityId, onlyFreePopulation: true, why: "moveToCiv")   // autoAssignPopulation()
        }

        // Stop WLTKD if it's still going (City.resetWLTKD)
        cities[ci].wltkdTurns = 0; cities[ci].resourceDemandCooldown = -1; cities[ci].demandedResource = ""

        removeBuildingsOnMoveToCiv(cityIndex: ci)
        removeAutoPromotion(cityIndex: ci)
        // catch-all - should ideally not happen as we catch the individual cases with an appropriate notification
        spiesFlee(fromCity: cityId, cityName: cities[ci].name, reason: .other)

        // Place palace for newCiv if this is the only city they have (Civilization.moveCapitalTo(city, null))
        if cities(of: newCiv).count == 1 {
            addBuilding(cityIndex: ci, Names.palace)
            cities[ci].razing = false
            if let ni = civIndex(newCiv) { civs[ni].capitalCityId = cityId }
        }

        tryAddFreeBuildings(newCiv)
        cities[ci].razing = false

        // Transfer unique buildings
        for name in cities[ci].builtBuildingObjects {   // Unciv getBuiltBuildings(), a snapshot
            let equivalent = equivalentBuilding(newCiv, name)
            if equivalent != name {
                removeBuilding(cityIndex: ci, name)
                addBuilding(cityIndex: ci, equivalent)
            }
        }

        if religionEnabled { removeUnknownPantheons(cityIndex: ci, newOwner: newCiv) }

        if mayNotAnnexCities(newCiv) { makePuppet(cityId: cityId) }

        tryUpdateRoadStatus(cityId: cityId)
        updateCityStats(cityId, reason: "moveToCiv")

        // Update proximity rankings: `city.civ.updateProximity(oldCiv, oldCiv.updateProximity(city.civ))`
        updateProximity(newCiv, oldCiv, preCalculated: updateProximity(oldCiv, newCiv))

        // City.resetDisabledConstructions / resetSpecialistsControl
        cities[ci].disabledConstructions = civ(newCiv)?.isPlayer == true ? (civ(newCiv)?.disabledCivConstructions ?? []) : []
        resetSpecialistsControl(cityIndex: ci)

        updateOurTiles(newCiv)
        updateOurTiles(oldCiv)
    }

    /// Unciv CivInfoTransientCache.updateOurTiles: the tiles we own and border changed - viewable (and so explored)
    /// tiles are recomputed, and then updateCivResources, which on a changed supply runs updateStatsForNextTurn.
    func updateOurTiles(_ civId: Int) {
        guard civ(civId) != nil else { return }
        updateExploration(for: civId)
        updateCivResources(civId)
    }

    /// Unciv City.resetSpecialistsControl: a human's new or captured city starts with hand-placed specialists when
    /// "Auto-assign specialists in new cities" is off - unless it is an online game and another player's civ (a skipped
    /// turn must not apply our settings); every other city starts automatic.
    func resetSpecialistsControl(cityIndex ci: Int) {
        guard cities.indices.contains(ci), let owner = civ(cities[ci].civId) else { return }
        let isOfflineOrOurTurn = !settings.isOnline || (owner.playerUserId ?? "") == Multiplayer.userId   // civ.playerId == settings.multiplayer.getUserId()
        cities[ci].manualSpecialists = owner.isPlayer && isOfflineOrOurTurn ? !UserSettings.autoAssignSpecialistsInNewCities : false
        if owner.isPlayer && GameState.evlogOn { hbr(cities[ci].manualSpecialists ? "C5.manualSpecialists" : "C5.autoSpecialists", owner.id) }
    }

    /// Unciv City.reassignAllPopulation: specialists back to automatic and every citizen placed again, locks cleared.
    func reassignAllPopulation(cityId: Int) {
        guard let ci = cityIndex(cityId) else { return }
        cities[ci].manualSpecialists = false
        assignWorkers(cityId: cityId, resetLocked: true, why: "reassignAllPopulation")
    }
}
