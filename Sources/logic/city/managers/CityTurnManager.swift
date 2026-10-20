// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/city/managers/CityTurnManager.kt`: a city at the turn boundary.
extension GameState {
    /// Unciv CityConstructions.constructIfEnough: the stored production of a city that reached its cost becomes the finished item,
    /// with the overflow capped at max(cost, production) — Unciv keeps this out of endTurn so a new unit is not left exposed for a whole enemy round.
    func constructIfEnough(for civId: Int) {
        for city in cities(of: civId) { constructIfEnough(cityId: city.id, civId: civId) }
    }

    /// One city's share of Unciv CityTurnManager.startTurn. Unciv runs this and that city's citizen
    /// reassignment together, city by city; splitting them into two passes over all the cities is what let a
    /// later city read an earlier city's stale production.
    /// Unciv City.tryUpdateRoadStatus, called from CityTurnManager.startTurn (and at founding): the centre tile
    /// of every city carries the best road the civ's technology allows, for free and from the turn the
    /// technology lands. We had no equivalent at all. Measured on `fresh`, Greece: Unciv's map carried three
    /// roads from turn 22 (its three city centres, the turn The Wheel came in) and twelve by turn 52; ours
    /// carried none until turn 47 and two by 52. A worker crossing its own cities pays full movement for
    /// tiles Unciv crosses at a third of the cost, which is how a Greek worker that Unciv walked three tiles
    /// in one turn only got two.
    /// Unciv: `getCenterTile().setRoadStatus(requiredRoad, civ)` every time - Railroad, else Road, else None - so it also
    /// clears a pillaged road, takes a road away from a civ without the tech and downgrades a railroad to a road.
    func tryUpdateRoadStatus(cityId: Int) {
        guard let city = self.city(cityId), map[city.coord] != nil else { return }
        func allowed(_ name: String) -> Bool {
            guard let imp = rs.improvements[name] else { return false }
            guard let tech = imp.techRequired else { return true }
            return civ(city.civId)?.techs.contains(tech) == true
        }
        let requiredRoad = allowed("Railroad") ? 2 : allowed("Road") ? 1 : 0
        setRoadStatus(at: city.coord, requiredRoad, creatingCiv: city.civId)   // Tile.setRoadStatus; EVLOG ROAD through the subscript
    }

    /// Unciv City.getTriggeredUniques(trigger, includeCivUniques = false): the city's built buildings and its
    /// religion, the trigger modifier stripped, in that order.
    private func cityOwnTriggeredUniques(_ city: City, civId: Int, _ isTrigger: @escaping (Unique) -> Bool) -> [Unique] {
        var cityPool: [Unique] = []
        for b in city.buildings { cityPool += rs.buildings[b]?.uniqueObjects ?? [] }
        cityPool += religionUniques(for: city)
        return multiplied(cityPool, UniqueContext(civId: civId, city: city)).filter { $0.conditionals.contains(where: isTrigger) }.map { $0.withoutConditionals(where: isTrigger) }
    }

    /// Unciv CityTurnManager.startTurn for one city, in its order: the city-wide stockpiled resources the city
    /// generates, the city's own "upon turn start" triggers (its buildings and its religion), constructIfEnough,
    /// tryUpdateRoadStatus, tryWeLoveTheKing (unless celebrating) and nextTurnFlags - where the resistance ends - and
    /// only then the citizens: a puppet reassigns everything with Gold focus, an AI city (or one flagged for it)
    /// chooses its focus and reassigns, any other city just updates its stats.
    func cityStartTurn(cityId: Int, civId: Int) {
        guard let city0 = city(cityId) else { return }
        // Unciv: `for (resource in city.getResourcesGeneratedByCity()) if (isStockpiled && isCityWide) gainStockpiledResource`
        if rs.resources.values.contains(where: { $0.isStockpiled && $0.isCityWide }) {
            for (name, amount) in resourcesGeneratedByCity(city0) where amount != 0 {
                if let r = rs.resources[name], r.isStockpiled, r.isCityWide, let idx = cityIndex(cityId) { cities[idx].resourceStockpiles[name, default: 0] += amount }
            }
        }
        // Unciv: `city.getTriggeredUniques(TriggerUponTurnStart, includeCivUniques = false)` → triggerUnique(unique, city)
        if let city1 = city(cityId) {
            let triggered = cityOwnTriggeredUniques(city1, civId: civId) { $0.pattern == "upon turn start" }
            if !triggered.isEmpty { _ = triggerUniques(triggered, civId: civId, cityId: cityId, unitId: nil, triggerText: nil) }
        }
        constructIfEnough(cityId: cityId, civId: civId)
        tryUpdateRoadStatus(cityId: cityId)
        guard let ci0 = cityIndex(cityId) else { return }
        cities[ci0].attackedThisTurn = false   // Unciv `city.attackedThisTurn = false`
        updateDemands(cityId: cityId)   // tryWeLoveTheKing + nextTurnFlags (Resistance, WeLoveTheKing, ResourceDemand)
        guard let idx = cityIndex(cityId) else { return }
        let c2 = cities[idx]
        if epochsDebug {
            AI.profile["n.cityTurnStart", default: 0] += 1
            if c2.isPuppet || civ(c2.civId)?.isPlayer != true { AI.profile["n.branchReassign", default: 0] += 1 }
            else if c2.shouldReassignPopulation { AI.profile["n.branchShould", default: 0] += 1 }
            else { AI.profile["n.branchNone", default: 0] += 1 }
        }
        if c2.isPuppet {
            cities[idx].cityFocus = "GoldFocus"
            reassignAllPopulation(cityId: cityId)
        } else if c2.shouldReassignPopulation || civ(c2.civId)?.isPlayer != true {
            if civ(c2.civId)?.isPlayer == true && GameState.evlogOn { hbr("C4.deferredReassign", c2.civId) }
            if civ(c2.civId)?.isPlayer != true { cities[idx].cityFocus = chooseCityFocus(c2) }
            assignWorkers(cityId: cityId, why: "TurnManager:13741")   // City.reassignPopulation() - includes cityStats.update
        } else {
            if GameState.evlogOn { hbr("C4.keepsCitizens", c2.civId) }   // CityTurnManager.kt:50: a human's city is not reassigned
            updateCityStats(cityId, reason: "TurnManager:13908")
        }
        seedResourceDemand(cityId: cityId)   // Unciv: "Seed resource demand countdown", after the citizens
    }

    /// Unciv CityTurnManager.endTurn for one city, in its order: the city's own "upon turn end" triggers, the stored
    /// stats read once, CityConstructions.endTurn (validate the queue, re-choose, bank the production),
    /// CityExpansionManager.nextTurn (culture, border growth), then EITHER the razing step OR
    /// CityPopulationManager.nextTurn (food, starvation, growth), the city's religion, and - unless the city was
    /// razed away - the +20 health and unassignExtraPopulation.
    /// Ours healed the city before the razing step, never fired the city's own turn-end triggers, and unassigned
    /// the extra citizens a second time after addPopulation had already done it.
    func cityEndTurn(cityId: Int, civId: Int) {
        // Unciv: `for (unique in city.getTriggeredUniques(TriggerUponTurnEnd, includeCivUniques = false)) triggerUnique(unique, city)`
        if let city0 = self.city(cityId) {
            let triggered = cityOwnTriggeredUniques(city0, civId: civId) { $0.pattern == "upon turn end" }
            if !triggered.isEmpty { _ = triggerUniques(triggered, civId: civId, cityId: cityId, unitId: nil, triggerText: nil) }
        }
        guard let city = self.city(cityId), let idx = cityIndex(cityId), civIndex(civId) != nil else { return }
        let tStats = Date()
        // Unciv CityTurnManager.endTurn: `val stats = city.cityStats.currentCityStats`, read BEFORE
        // cityConstructions.endTurn(stats) validates the queue and re-chooses.
        let stats = currentCityStats(city.id)   // the cache from before the AI queued anything: a Settler queued this turn does not eat this turn's food
        // Unciv CityConstructions.endTurn opens with `validateConstructionQueue()` - which ends in
        // `chooseNextConstruction()` - and only then adds the turn's production. TurnManager.endTurn has
        // already run `tech.endTurn(science)` by this point, so a technology that lands THIS turn still
        // decides where THIS turn's production goes. Ours added production to whatever had been chosen in
        // the morning and, when that was nothing, to nowhere at all: measured on `t_45` turn 58, Carthage
        // finished Walls, bought a Shrine with gold, had nothing left it could build, and sat out the turn.
        // Unciv re-chose here, found the National College that Philosophy had just unlocked, and put the
        // turn's 16 production and the 15 that overflowed from the Walls into it.
        validateConstructions(cityId: city.id)
        if constructionIsAutomated(cityId: city.id) {
            chooseNextConstruction(cityId: city.id)
        }
        if epochsDebug { AI.profile["p.stats", default: 0] += Date().timeIntervalSince(tStats) }

        // Production
        let tVal = Date()
        validateConstructions(cityId: city.id)
        if epochsDebug { AI.profile["p.validate", default: 0] += Date().timeIntervalSince(tVal) }
        let tProd = Date()
        defer { if epochsDebug { AI.profile["p.production", default: 0] += Date().timeIntervalSince(tProd) } }
        if let p = cities[idx].currentProduction {
            if workDone(p, in: cities[idx]) == 0 { constructionBegun(cityId: city.id, p) }   // Unciv CityConstructions.endTurn: getWorkDone == 0
            // The reference prints the same line under CHOICE_CITY (CityConstructions.endTurn), so the two
            // can be read side by side: what the stats say, what overflowed, and what was already banked.
            if ProcessInfo.processInfo.environment["CHOICE_CITY"] == city.name {
                print("ENDE t=\(turn) \(city.name) prod=\(stats.total.production) ovf=\(cities[idx].productionOverflow) cur=\(p.name) done=\(Int(cities[idx].productionStored))")
            }
            // Unciv CityConstructions.endTurn: rounded production plus the last completion's overflow
            if GameState.evlogOn { ev(civId, "PROD_ADD", EvLog.name(cities[idx].name), EvLog.f1(Double(Float(stats.total.production))), String(cities[idx].productionOverflow)) }
            cities[idx].productionStored += (stats.total.production + 0.5).rounded(.down) + Double(cities[idx].productionOverflow)
            cities[idx].productionOverflow = 0
            cities[idx].workDoneOn = p.name
            // Unciv CityConstructions.endTurn stops here: what was paid for is finished at the start of the next turn (constructIfEnough)
        } else if !city.convertProductionTo.isEmpty, productionConversions(for: civId).contains(city.convertProductionTo) {
            // "Enables conversion of city production to [Gold]" – Wealth / Research processes at 25%.
            // Unciv CityStats.getStatConversionRate: 1/4, changed by "Production to [stat] conversion in cities changed by [x]%"
            // Unciv CityStats.getStatsFromProduction: already part of the city's stats (before the gold/science/culture %)
        } else if constructionIsAutomated(cityId: city.id) {
            chooseNextConstruction(cityId: city.id)
        } else {
            // Unciv: an idle city ("Nothing") wastes its production; the next-turn button says "Pick construction".
        }

        if epochsDebug { AI.profile["p.production", default: 0] += Date().timeIntervalSince(tProd); AI.profile["p.production", default: 0] -= Date().timeIntervalSince(tProd) }
        // Borders
        let tExp = Date()
        cities[idx].expansionCulture += stats.total.culture.rounded(.towardZero)   // Unciv cultureStored += culture.toInt()
        if cities[idx].expansionCulture >= expansionCost(for: cities[idx]) {
            expandBorders(cityId: city.id)
        }
        if epochsDebug { AI.profile["p.expand", default: 0] += Date().timeIntervalSince(tExp) }
        if cities[idx].razing {
            // Unciv CityTurnManager.endTurn: remove 1 + Σ(x − 1) citizens, destroyed when that is all of them; the granary drops below the new threshold
            let removed = 1 + civUniques(civId).filter { $0.pattern == "Cities are razed [] times as fast" }.reduce(0) { $0 + $1.int(0) - 1 }
            if cities[idx].population <= removed {
                spiesFlee(fromCity: city.id, cityName: city.name, reason: .other)   // Unciv: removeAllPresentSpies(Other), the notification, then destroyCity()
                notify(civId, "[\(city.name)] has been razed to the ground!", category: .General, icons: ["OtherIcons/Fire"], coord: city.coord)
                destroyCity(cityId: city.id)
                // Unciv does not return here: `city.religion.endTurn()` runs on the dead City object, and only the
                // health block is skipped (`city in city.civ.cities`). A city destroyCity refused carries on as a live one.
                if cityIndex(city.id) == nil { razedCityReligionEndTurn(cityId: city.id); return }
            } else {
                addPopulation(cityIndex: idx, -removed)   // Unciv CityTurnManager.endTurn → addPopulation(-removed), which unassigns the extra citizens itself
                if cities[idx].foodStored >= growthCost(cities[idx]) { cities[idx].foodStored = growthCost(cities[idx]) - 1 }
            }
        } else {
            // Unciv CityPopulationManager.nextTurn(foodForNextTurn = rounded food): only a city not being razed
            // Unciv CityTurnManager.endTurn asks City.foodForNextTurn() -> cityStats.currentCityStats
            // only here, AFTER the border step: a city that just took a tile has had its cache
            // refreshed by CityExpansionManager.takeOwnership and eats against the new stats.
            let foodStats = currentCityStats(cities[idx].id)
            let food = (foodStats.foodSurplus + 0.5).rounded(.down)   // Kotlin roundToInt (half up, also for negatives)
            if let kf = ProcessInfo.processInfo.environment["KFOOD"], city.name == kf || civ(civId)?.nation == kf {
                var wl: [String] = []
                for wc in cities[idx].workedTiles {
                    let p = uncivPosition(wc)
                    var nm = "?"
                    if let t = map[wc] {
                        nm = t.baseTerrain
                        for f in t.features { nm += "+" + f }
                        if let r = t.resource { nm += "/" + r }
                    }
                    wl.append("\(p.x),\(p.y)/" + nm)
                }
                var w = wl.sorted().joined(separator: " ")
                let cp = uncivPosition(city.coord)
                let cs = tileStats(map[city.coord]!, civId: city.civId, city: cities[idx])
                w += " wltkd=\(cities[idx].wltkdTurns) demand=\(cities[idx].demandedResource.isEmpty ? "-" : cities[idx].demandedResource) cool=\(cities[idx].resourceDemandCooldown) happy=\(happiness(of: city.civId)) lux=[\(resourceCounts(city.civId).filter { rs.resources[$0.key]?.resourceType == "Luxury" && $0.value > 0 }.keys.sorted().joined(separator: ","))]"
                w += " || CENTRE \(cp.x),\(cp.y)=\(cs.food)f\(cs.production)p"
                for wc in cities[idx].workedTiles.sorted(by: { ($0.q, $0.r) < ($1.q, $1.r) }) {
                    let p2 = uncivPosition(wc)
                    let ts = tileStats(map[wc]!, civId: city.civId, city: cities[idx])
                    w += " | \(p2.x),\(p2.y)=\(ts.food)f\(ts.production)p"
                }
                print("KFOOD t=\(turn) \(city.name) pop=\(cities[idx].population) surplus=\(foodStats.foodSurplus) banked=\(food) stored=\(cities[idx].foodStored) totalFood=\(foodStats.total.food) tileF=\(foodStats.tileYields.food) bldF=\(foodStats.buildingYields.food) growthPct=\(foodStats.growthPercent) worked=[\(w)]")
            }
            cities[idx].foodStored += food
            if food < 0 { notify(civId, "[\(city.name)] is starving!", category: .Cities, icons: ["Growth", "Death"], coord: city.coord) }
            if cities[idx].foodStored < 0 {
                if cities[idx].population > 1 { addPopulation(cityIndex: idx, -1) }   // Unciv CityPopulationManager.addPopulation(-1): unassigns the extra citizen itself
                cities[idx].foodStored = 0
            }
            let needed = growthCost(cities[idx])
            let growthCtx = UniqueContext(civId: civId, city: cities[idx])
            let nullifiesGrowth = cityUniques(cities[idx]).contains { ($0.pattern == "Nullifies Growth []" || $0.pattern == "Nullifies Growth") && scopeIncludes($0, city: cities[idx]) && conditionalsHold($0, growthCtx) }
            if cities[idx].foodStored >= needed && !nullifiesGrowth {
                if city.avoidGrowth { cities[idx].foodStored = needed }   // Unciv: avoid growth caps the store at the threshold
                else {
                    cities[idx].foodStored -= needed
                    var carry = 0.0
                    for u in cityUniques(city) where u.pattern == "[]% Food is carried over after population increases []" && scopeIncludes(u, city: city) { carry += u.double(0) }
                    cities[idx].foodStored += (needed * min(95, carry) / 100).rounded(.towardZero)   // Unciv caps carry-over at 95%, truncated
                    addPopulation(cityIndex: idx, 1)   // Unciv addPopulation(1) with the religion pressure update
                    cities[idx].shouldReassignPopulation = true   // Unciv CityPopulationManager.nextTurn, after addPopulation(1)
                    notify(civId, "[\(city.name)] has grown!", category: .Cities, icons: ["Growth"], coord: city.coord)
                }
            }
        }

        // Unciv: "This should go after the population change, as that might impact the amount of followers in this city"
        cityReligionEndTurn(cityId: city.id)   // Unciv: `if (isReligionEnabled()) city.religion.endTurn()`
        // Unciv: `if (city in city.civ.cities) { health += 20 (capped); population.unassignExtraPopulation() }`
        guard let hi = cityIndex(cityId), cities[hi].civId == civId else { return }
        cities[hi].health = min(cityMaxHealth(cities[hi]), cities[hi].health + 20)
        unassignExtraPopulation(cityId: cityId)
        let tWork = Date()
        if epochsDebug { AI.profile["p.workers", default: 0] += Date().timeIntervalSince(tWork) }
    }

    func constructIfEnough(cityId: Int, civId: Int) {
        for city in cities(of: civId) where city.id == cityId {
            validateConstructions(cityId: city.id)
            guard let idx = cityIndex(city.id) else { continue }
            guard let p = cities[idx].currentProduction else {
                // Unciv CityConstructions.constructIfEnough: `if (construction is PerpetualConstruction)
                // chooseNextConstruction()` - a city on Wealth/Research (or idle) re-decides here, at the
                // start of its turn and BEFORE the citizens are reassigned. Leaving it perpetual until
                // NextTurnAutomation made rankStatsForCityWork divide production by 6 for that one
                // reassignment, so the city worked gold tiles instead of its stone hills, and the turn's
                // production was still converted to gold on top.
                chooseNextConstructionIfAutomated(cityId: city.id)
                continue
            }
            let cost = Double(productionCost(p, for: civId))
            guard cities[idx].productionStored >= cost else { continue }
            let potentialOverflow = Int(cities[idx].productionStored - cost)
            var notices: [() -> Void] = []
            defer { notices.forEach { $0() } }   // completeConstruction's notifications, after the queue is settled
            if completeProduction(cityId: city.id, p, notices: &notices) {
                guard let idx2 = cityIndex(city.id) else { continue }
                // Unciv completeConstruction, after construct(): `if (name in inProgressConstructions) remove(name)` -
                // unconditionally - and only then `if (name == currentConstructionName()) removeCurrentConstruction()`.
                // construct() can change the current construction itself: The Great Library's free Library goes
                // through completeConstruction → validateConstructionQueue, which drops the finished wonder and
                // chooses the next thing. Its work must go with it, not be parked and later refunded as gold
                // (fresh turn 44: France +125 gold that Unciv never paid), and the new choice must stay.
                let stillCurrent = cities[idx2].currentProduction == p
                cities[idx2].inProgressConstructions[p.name] = nil
                if stillCurrent {
                    cities[idx2].productionStored = 0
                    cities[idx2].workDoneOn = ""
                }
                // Unciv reads `city.cityStats.currentCityStats.production` AFTER completeConstruction, so a building
                // that adds production (its addBuilding updated the stats) raises its own overflow cap.
                let production = currentCityStats(city.id).total.production
                cities[idx2].productionOverflow = min(max(Int(cost), Stats.roundToInt(production)), potentialOverflow)
                if GameState.evlogOn { ev(civId, "OVERFLOW", EvLog.name(cities[idx2].name), String(Int(cost)), String(cities[idx2].productionOverflow)) }
                // Unciv completeConstruction runs `construction.construct(this)` - which ends in
                // cityStats.update() - BEFORE removeCurrentConstruction(). So the stored stats every later
                // reader sees still carry the finished construction's production bonus, and the construction
                // automation that runs a moment later reads exactly that. Ours recomputed live with no
                // construction at all: measured on `settled`, Tokyo read itself as 7.0 against an average of
                // 7.1 instead of Unciv's 7.35 against 7.1875, so it was not an above-average producer, the
                // military building's experience term was divided by five, and it built a Worker where Unciv
                // built Barracks. The stored stats keep that value until the citizens are reassigned, which is
                // where Unciv's next cityStats.update() happens.
                // (No extra cityStats.update here: a building's addBuilding already ran it with the construction still
                // current, and a unit's addUnit only updates the civ - Unciv updates nothing else before
                // removeCurrentConstruction.)
                // Unciv completeConstruction: removeCurrentConstruction() - removeFromQueue(0, automatic = true), which
                // chooses the next construction when the queue ran empty - then validateConstructionQueue(), which
                // drops what the completion made unbuildable, settles the banked work (a wonder's refund lands now,
                // before this turn's purchases) and ends in chooseNextConstruction().
                // removeFromQueue ends in `currentConstructionIsUserSet = if (constructionQueue.isEmpty()) { ...; false } else
                // true` - "we're just continuing the regular queue". Our trailing perpetual (convertProductionTo) is an entry
                // of Unciv's queue: a wonder a Great Engineer pushed in front of an automated Gold (`constructionQueue.add(0,
                // wonder)`) leaves [Gold] behind it, and that Gold now counts as the player's, so chooseNextConstruction keeps
                // it for good instead of switching to a building a new technology unlocks.
                if stillCurrent {
                    let emptied = cities[idx2].productionQueue.isEmpty && cities[idx2].convertProductionTo.isEmpty
                    cities[idx2].currentProduction = nil
                    advanceProductionQueue(cityId: city.id)
                    if let idx3 = cityIndex(city.id) { cities[idx3].currentConstructionIsUserSet = !emptied }
                    if let idx3 = cityIndex(city.id), cities[idx3].currentProduction == nil { chooseNextConstructionIfAutomated(cityId: city.id) }
                }
                validateConstructionQueue(cityId: city.id)
            }
            // Unciv constructIfEnough: `city.civ.civConstructions.builtItemsWithIncreasingCost[construction.name] += 1` after
            // the completion - whether it succeeded or not, and for every construction, though only "Cost increases by []
            // when built" reads it (BaseUnitCost, Building.getProductionCost); a free building never comes this way
            if let cv = civIndex(civId) { civs[cv].builtItemsWithIncreasingCost[p.name, default: 0] += 1 }
        }
    }
}
