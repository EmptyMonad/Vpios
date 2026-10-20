// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/CivConstructions.kt`: the buildings a civ is given rather than builds.
///
/// Unciv keeps three maps on the civ and one on each city, and every free building goes up through
/// `city.cityConstructions.completeConstruction` - the same completion a built building gets, notifications,
/// queue bookkeeping and the nested `tryAddFreeBuildings` included:
/// - `freeBuildings` (city id -> names): what the civ's own free-building uniques gave that city;
/// - `freeStatBuildingsProvided` (stat -> city ids) and `freeSpecificBuildingsProvided` (building -> city ids):
///   which cities have already been served, so each is served once per game;
/// - `CityConstructions.freeBuildingsProvidedFromThisCity` (GainFreeBuildings), kept on the city.
/// Every reader (maintenance, resource upkeep, selling, capture) asks `getFreeBuildingNames(city)` of the city's
/// CURRENT owner - `freeBuildingNames` below: a city taken from a Legalism civ keeps that civ's free Monument, and
/// pays for it, while the old owner's entry waits for the day the city comes back.
extension GameState {
    /// Unciv CivConstructions.getFreeBuildingNames(city) = getFreeBuildingNamesSequence(city.id).toSet(): the owner's
    /// `freeBuildings[city.id]`, then each owner city's `freeBuildingsProvidedFromThisCity[city.id]` - only the city
    /// itself ever files under its own id - each a HashSet walked in its bucket order, the union in first-seen order.
    func freeBuildingNames(_ city: City) -> [String] {
        var names: [String] = []
        let fromCiv = civIndex(city.civId).map { civs[$0].freeBuildingsOfCities[city.id] ?? [] } ?? []
        for n in javaHashMapOrder(fromCiv) + javaHashMapOrder(city.freeBuildingsProvidedFromThisCity) where !names.contains(n) { names.append(n) }
        return names
    }

    /// Unciv CivConstructions.hasFreeBuilding(city, building)
    func hasFreeBuilding(_ city: City, _ name: String) -> Bool {
        if let cv = civIndex(city.civId), civs[cv].freeBuildingsOfCities[city.id]?.contains(name) == true { return true }
        return city.freeBuildingsProvidedFromThisCity.contains(name)
    }

    /// Unciv CityConstructions.containsBuildingOrEquivalent: the nation's own version of a building counts as that building.
    func containsBuildingOrEquivalent(_ city: City, _ name: String) -> Bool {
        if city.buildings.contains(name) { return true }
        return city.buildings.contains { rs.buildings[$0]?.replaces == name }
    }

    /// Unciv Unique.hasTriggerConditional: a unique carrying an "upon ..." trigger is fired by that trigger, never
    /// read as a standing unique.
    func hasTriggerConditional(_ u: Unique) -> Bool {
        u.conditionals.contains { $0.pattern.hasPrefix("upon ") }
    }

    /// Unciv CivConstructions.startTurn → tryAddFreeBuildings.
    func tryAddFreeBuildings(_ civId: Int) {
        addFreeStatsBuildings(civId)
        addFreeSpecificBuildings(civId)
        addFreeBuildings(civId)
    }

    /// Unciv CivConstructions.addFreeBuilding: remembered on the civ under the nation's own version of the name.
    private func addFreeBuilding(civId: Int, cityIndex ci: Int, _ building: String) {
        guard let cv = civIndex(civId) else { return }
        let name = equivalentBuilding(civId, building)
        let cityId = cities[ci].id
        if !(civs[cv].freeBuildingsOfCities[cityId] ?? []).contains(name) { civs[cv].freeBuildingsOfCities[cityId, default: []].append(name) }
    }

    /// Unciv CivConstructions.addFreeStatsBuildings: the standing FreeStatBuildings uniques (no trigger), grouped by
    /// stat in the order the stats first appear, their city counts summed.
    private func addFreeStatsBuildings(_ civId: Int) {
        var order: [String] = []
        var amounts: [String: Int] = [:]
        let ctx = UniqueContext(civId: civId)
        for u in civUniques(civId) where u.pattern == "Provides the cheapest [] building in your first [] cities for free" && !hasTriggerConditional(u) && conditionalsHold(u, ctx) {
            let stat = u.param(0)
            guard ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith"].contains(stat) else { continue }   // Unciv Stat.valueOf
            if amounts[stat] == nil { order.append(stat) }
            amounts[stat, default: 0] += u.int(1)
        }
        for stat in order { addFreeStatBuildings(civId, stat: stat, amount: amounts[stat] ?? 0) }
    }

    /// Unciv CivConstructions.addFreeStatBuildings: the first `amount` cities of the civ's list each get the cheapest
    /// building related to the stat, once per game.
    func addFreeStatBuildings(_ civId: Int, stat: String, amount: Int) {
        guard amount > 0 else { return }
        for c in cities(of: civId).prefix(amount) {
            guard let cv = civIndex(civId), let ci = cityIndex(c.id), cities[ci].civId == civId else { continue }
            if civs[cv].freeStatBuildingsProvided[stat]?.contains(c.id) == true { continue }
            guard let building = cheapestStatBuilding(cities[ci], stat: stat) else { continue }
            civs[cv].freeStatBuildingsProvided[stat, default: []].append(c.id)
            addFreeBuilding(civId: civId, cityIndex: ci, building)
            completeConstruction(cityIndex: ci, building: building)
        }
    }

    /// Unciv CityConstructions.cheapestStatBuilding: over the whole ruleset, in its order, the first of the cheapest
    /// non-wonder buildings related to the stat that the city can build or is already building. Unciv compares
    /// `Building.cost` after Ruleset.updateBuildingCosts has written the tech column's cost into every building
    /// without one, so the comparison goes through `rs.cost(of:)`, never the raw json -1.
    func cheapestStatBuilding(_ city: City, stat: String) -> String? {
        let ctx = UniqueContext(civId: city.civId, city: city)
        let cityPool = statRelatedCityPool(city, ctx)
        var best: BuildingDef? = nil
        var bestCost = 0
        for name in rs.buildingOrder {
            guard let b = rs.buildings[name], !b.isAnyWonder, isStatRelated(b, stat: stat, city: city, cityPool: cityPool, ctx: ctx) else { continue }
            guard canProduce(.building(b.name), in: city) || combinedQueue(city).contains(.building(b.name)) else { continue }
            let cost = rs.cost(of: b)   // Ruleset.updateBuildingCosts
            if best == nil || cost < bestCost { best = b; bestCost = cost }   // Unciv minByOrNull: the first minimum
        }
        return best?.name
    }

    /// The city's uniques Building.getStats / getStatPercentageBonuses read for a building.
    private func statRelatedCityPool(_ city: City, _ ctx: UniqueContext) -> [Unique] {
        cityUniques(city).filter { ["[] from every []", "[] from all [] buildings", "[]% [] from every []", "[]% Yield from every []"].contains($0.pattern) && scopeIncludes($0, city: city) && conditionalsHold($0, ctx) }
    }

    /// Unciv Building.isStatRelated(stat, city) for a single building.
    func isStatRelated(_ b: BuildingDef, stat: String, city: City) -> Bool {
        let ctx = UniqueContext(civId: city.civId, city: city)
        return isStatRelated(b, stat: stat, city: city, cityPool: statRelatedCityPool(city, ctx), ctx: ctx)
    }

    /// Unciv Building.isStatRelated(stat, city): the building's stats IN THIS CITY (its own, the city's "[stats] from
    /// every [building]", its own "[stats]", and for a non-wonder "[stats] from all [filter] buildings"), or its
    /// percentage bonuses there, or its own tile / population stat uniques - and removing the annexation
    /// unhappiness counts as Happiness. A belief paying culture for every Shrine makes the Shrine a culture
    /// building for Legalism; the bare stat line in the json does not see that.
    private func isStatRelated(_ b: BuildingDef, stat: String, city: City, cityPool: [Unique], ctx: UniqueContext) -> Bool {
        var stats = b.stats
        for u in cityPool where u.pattern == "[] from every []" && buildingMatches(b.name, u.param(1)) { if let st = u.stats { stats += st } }
        for u in b.uniqueObjects where u.pattern == "[]" && conditionalsHold(u, ctx) { if let st = u.stats { stats += st } }
        if !b.isWonder { for u in cityPool where u.pattern == "[] from all [] buildings" && buildingMatches(b.name, u.param(1)) { if let st = u.stats { stats += st } } }
        if stats[stat] > 0 { return true }
        var percent = b.percentStatBonus
        for u in cityPool where u.pattern == "[]% [] from every []" && buildingMatches(b.name, u.param(2)) { percent[u.param(1)] += u.double(0) }
        for u in cityPool where u.pattern == "[]% Yield from every []" && buildingMatches(b.name, u.param(1)) {
            for st in ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith"] { percent[st] += u.double(0) }
        }
        if percent[stat] > 0 { return true }
        for u in b.uniqueObjects where ["[] from [] tiles []", "[] from [] tiles", "[] per [] population []", "[] per [] population"].contains(u.pattern) {
            if let st = u.stats, st[stat] > 0 { return true }
        }
        return stat == "Happiness" && b.uniques.contains("Removes extra unhappiness from annexed cities")
    }

    /// Unciv CivConstructions.addFreeSpecificBuildings: the standing FreeSpecificBuildings uniques, grouped by building.
    private func addFreeSpecificBuildings(_ civId: Int) {
        var order: [String] = []
        var amounts: [String: Int] = [:]
        let ctx = UniqueContext(civId: civId)
        for u in civUniques(civId) where u.pattern == "Provides a [] in your first [] cities for free" && !hasTriggerConditional(u) && conditionalsHold(u, ctx) {
            let b = u.param(0)
            if amounts[b] == nil { order.append(b) }
            amounts[b, default: 0] += u.int(1)
        }
        for b in order where rs.buildings[b] != nil { addFreeBuildings(civId, building: equivalentBuilding(civId, b), amount: amounts[b] ?? 0) }
    }

    /// Unciv CivConstructions.addFreeBuildings(building, amount): the first `amount` cities each get the building
    /// once, unless they already have it or its equivalent.
    func addFreeBuildings(_ civId: Int, building: String, amount: Int) {
        guard amount > 0, rs.buildings[building] != nil else { return }
        let equivalent = equivalentBuilding(civId, building)
        for c in cities(of: civId).prefix(amount) {
            guard let cv = civIndex(civId), let ci = cityIndex(c.id), cities[ci].civId == civId else { continue }
            if civs[cv].freeSpecificBuildingsProvided[equivalent]?.contains(c.id) == true || containsBuildingOrEquivalent(cities[ci], building) { continue }
            civs[cv].freeSpecificBuildingsProvided[equivalent, default: []].append(c.id)
            addFreeBuilding(civId: civId, cityIndex: ci, equivalent)
            completeConstruction(cityIndex: ci, building: equivalent)
        }
    }

    /// Unciv CivConstructions.addFreeBuildings(): "Gain a free [building] [cityFilter]" from the civ and from each
    /// city's own buildings, re-applied to every city every turn; then the buildings that are "automatically built
    /// in all cities where it is buildable".
    private func addFreeBuildings(_ civId: Int) {
        let autoGranted = rs.buildingOrder.compactMap { rs.buildings[$0] }.filter { $0.uniques.contains("Automatically built in all cities where it is buildable") }
        let fromCiv = civUniques(civId).filter { $0.pattern == "Gain a free [] []" }
        for c in cities(of: civId) {
            guard let ci = cityIndex(c.id), cities[ci].civId == civId else { continue }
            let here = cities[ci]
            let fromCity = here.buildings.flatMap { b in (rs.buildings[b]?.uniqueObjects ?? []).filter { $0.pattern == "Gain a free [] []" && $0.isLocalEffect } }
                + religionUniques(for: here).filter { $0.pattern == "Gain a free [] []" }
            let ctx = UniqueContext(civId: civId, city: here)
            // "When adding a building, the list of applicable free buildings can change! Hence, toList()"
            let applicable = (fromCiv + fromCity).filter { cityMatchesFilter($0.param(1), city: here, viewer: civId) && conditionalsHold($0, ctx) && !hasTriggerConditional($0) }
            for u in applicable {
                guard rs.buildings[u.param(0)] != nil, let cx = cityIndex(c.id) else { continue }
                let free = equivalentBuilding(civId, u.param(0))
                if !cities[cx].freeBuildingsProvidedFromThisCity.contains(free) { cities[cx].freeBuildingsProvidedFromThisCity.append(free) }   // addToMapOfSets(city.id, ...)
                if containsBuildingOrEquivalent(cities[cx], free) { continue }
                completeConstruction(cityIndex: cx, building: free)
            }
            for b in autoGranted {
                guard let cx = cityIndex(c.id), canProduce(.building(b.name), in: cities[cx]) else { continue }
                completeConstruction(cityIndex: cx, building: b.name)
            }
        }
    }

    /// Unciv UniqueTriggerActivation GainFreeBuildings: the nation's version of the building, noted as provided by
    /// each applicable city and completed there unless the city already has it or its equivalent.
    func gainFreeBuilding(_ building: String, cityIndex ci: Int) {
        guard cities.indices.contains(ci), rs.buildings[building] != nil else { return }
        let free = equivalentBuilding(cities[ci].civId, building)
        if !cities[ci].freeBuildingsProvidedFromThisCity.contains(free) { cities[ci].freeBuildingsProvidedFromThisCity.append(free) }
        if containsBuildingOrEquivalent(cities[ci], free) { return }
        completeConstruction(cityIndex: ci, building: free)
    }

    /// Unciv CityConstructions.completeConstruction for a Building: `construct` - addBuilding with its
    /// tryAddFreeBuildings - then the construction leaves inProgressConstructions and, when it is the current one,
    /// the queue (`removeCurrentConstruction`, which picks the next one when the queue runs dry), and
    /// `validateConstructionQueue` drops whatever the new building made unbuildable and ends in
    /// chooseNextConstruction. The notifications come from completeProduction.
    func completeConstruction(cityIndex ci: Int, building name: String) {
        guard cities.indices.contains(ci), rs.buildings[name] != nil else { return }
        let cityId = cities[ci].id
        var notices: [() -> Void] = []
        defer { notices.forEach { $0() } }   // completeConstruction's notifications come after removeCurrentConstruction and validation
        completeProduction(cityId: cityId, .building(name), notices: &notices)
        guard let cx = cityIndex(cityId), let cv = civIndex(cities[cx].civId) else { return }
        let autoChooses = !civs[cv].isPlayer || UserSettings.autoAssignCityProduction || autoPlayingFullAI || cities[cx].isPuppet
        cities[cx].inProgressConstructions[name] = nil
        if cities[cx].currentProduction == .building(name) {
            // The work goes with the construction: clear it before City.currentProduction's didSet parks it.
            cities[cx].productionStored = 0
            cities[cx].workDoneOn = ""
            // removeCurrentConstruction = removeFromQueue(0, automatic = true): `currentConstructionIsUserSet = if
            // (constructionQueue.isEmpty()) { ...; false } else true` - our trailing perpetual is an entry of that queue
            let emptied = cities[cx].productionQueue.isEmpty && cities[cx].convertProductionTo.isEmpty
            cities[cx].currentProduction = nil
            advanceProductionQueue(cityId: cityId)
            cities[cx].currentConstructionIsUserSet = !emptied
            if cities[cx].currentProduction == nil, autoChooses { chooseNextConstruction(cityId: cityId) }
        }
        // validateConstructionQueue: every entry must still be buildable - rebuilt one entry at a time, as in
        // validateConstructions, so a "Limited to [N] per Civilization" entry is not counted against itself (a free
        // Broadcast Tower from the CN Tower in a city building the SS Cockpit dropped the Cockpit). Unciv's
        // completeConstruction calls only validateConstructionQueue: no wonder refund, no validateInProgressConstructions.
        let queue = combinedQueue(cities[cx])
        if EvLog.on { EvLog.probing = true }
        let kept = rebuildQueueIncrementally(cityIndex: cx, snapshot: queue)
        // the probe is cleared before the queue is stored and before the AI's pick: both see the real city
        if EvLog.on { EvLog.probing = false }
        constructionProbe = nil
        if kept != queue { setCombinedQueue(cx, kept) }
        if autoChooses && (cities[cx].currentProduction == nil || !cities[cx].convertProductionTo.isEmpty) { chooseNextConstruction(cityId: cityId) }
    }

    /// Unciv CityConstructions.validateInProgressConstructions / validateConstructionQueue: drop what can no longer be built,
    /// refunding wonder production as gold ("Excess production for [w] converted to [n] gold").
    func validateConstructions(cityId: Int) {
        guard let ci = cityIndex(cityId) else { return }
        let city = cities[ci]
        // Unciv validateConstructionQueue: `queueSnapshot = constructionQueue.toMutableList(); constructionQueue.clear()`,
        // then each entry in turn is re-added if `isBuildable(this)` - judged with only the entries kept BEFORE it in
        // the queue. So an entry never counts itself: "Limited to [5] per Civilization" sees this city's own Recycling
        // Center only once it is back in (fresh turn 269: France's fifth, in just-conquered Ragusa, was checked against
        // a count that included itself, dropped, re-chosen, dropped again, and never received a hammer).
        // The dropped entries' work stays in inProgressConstructions (our didSet parks it), settled by
        // validateInProgressConstructions below - a wonder refunded, an obsolete unit's work carried - on definitive
        // rejections only.
        let definitive: Set<String> = ["Obsoleted", "WonderAlreadyBuilt", "NationalWonderAlreadyBuilt", "CannotBeBuiltWith", "MaxNumberBuildable"]
        let snapshot = combinedQueue(city)
        if EvLog.on { EvLog.probing = true }
        defer { if EvLog.on { EvLog.probing = false }; constructionProbe = nil }
        let kept = rebuildQueueIncrementally(cityIndex: ci, snapshot: snapshot)
        // Unciv: validateConstructionQueue ends in chooseNextConstruction, and only then does validateInProgressConstructions
        // (which skips the current construction) refund a dropped wonder's work - so the next pick is made while that gold
        // is still out: Athens chose a Market at -12 gold, not a Colosseum at 165.
        var willRefund = false
        if case .building(let name)? = city.currentProduction, kept.first != city.currentProduction, let def = rs.buildings[name] {
            var probe = city; probe.currentProduction = nil; probe.productionQueue = []
            willRefund = def.isWonder && Int(city.productionStored) != 0 && buildingRejections(def, city: probe).contains { definitive.contains($0.type) }
        }
        if EvLog.on { EvLog.probing = false }
        constructionProbe = nil
        if kept != snapshot { setCombinedQueue(ci, kept) }   // City.currentProduction's didSet parks / resumes the banked work
        if willRefund, let civIdx = civIndex(city.civId), cities[ci].currentProduction == nil,
           !civs[civIdx].isPlayer || UserSettings.autoAssignCityProduction || autoPlayingFullAI || cities[ci].isPuppet {
            chooseNextConstruction(cityId: cityId)   // Unciv validateConstructionQueue ends in chooseNextConstruction()
        }
        validateInProgressConstructions(cityIndex: ci)
    }

    /// Unciv CityConstructions.validateConstructionQueue's rebuild: `queueSnapshot = constructionQueue.toMutableList();
    /// constructionQueue.clear()`, then each entry is re-added if `construction.isBuildable(this)` - judged with only
    /// the entries kept before it in the queue. Each step probes a copy of the city through the game's constructionProbe;
    /// the caller sets EvLog.probing and clears both afterwards (the last probe stays in place until then).
    private func rebuildQueueIncrementally(cityIndex ci: Int, snapshot: [Production]) -> [Production] {
        let city = cities[ci]
        var kept: [Production] = []
        for p in snapshot {
            var probe = cities[ci]   // the city as its queue stands at this point of the rebuild
            probe.currentProduction = kept.first
            probe.productionQueue = Array(kept.dropFirst())
            constructionProbe = probe
            let buildable: Bool
            if case .building(let name) = p { buildable = !probe.buildings.contains(name) && canProduce(p, in: probe) }
            else { buildable = canProduce(p, in: probe) }
            if buildable { kept.append(p) }
            else if ProcessInfo.processInfo.environment["VALDBG"] == city.name {
                let why: [String]
                switch p {
                case .building(let n): why = rs.buildings[n].map { buildingRejections($0, city: probe).map { "\($0.type):\($0.message)" } } ?? ["?"]
                case .unit(let n): why = rs.units[n].map { unitRejections($0, city: probe).map { "\($0.type):\($0.message)" } } ?? ["?"]
                }
                let counted = cities(of: city.civId).map { $0.id == probe.id ? probe : $0 }.compactMap { c -> String? in
                    if containsBuildingOrEquivalent(c, p.name) { return "\(c.name):built" }
                    if isBeingConstructedOrEnqueued(p.name, in: c) { return "\(c.name):queued" }
                    return nil
                }
                print("VALDBG t=\(uncivTurns) \(city.name) drop \(p.name) kept=\(kept.map { $0.name }) why=\(why) counted=\(counted)")
            }
        }
        return kept
    }

    /// Unciv CityConstructions.validateInProgressConstructions: production banked against anything that is not
    /// the current construction is settled here, whether or not it is still queued. Only the five definitive
    /// rejections count (RejectionReason.reasonsToDefinitivelyRemoveFromQueue) - a building we merely cannot
    /// start right now (missing prerequisite, missing resource) keeps its hammers.
    func validateInProgressConstructions(cityIndex ci: Int) {
        let definitive: Set<String> = ["Obsoleted", "WonderAlreadyBuilt", "NationalWonderAlreadyBuilt", "CannotBeBuiltWith", "MaxNumberBuildable"]
        let currentName = cities[ci].currentProduction?.name   // Unciv: `inProgressConstructions.keys.filter { it != currentConstructionName() }`
        for (name, banked) in cities[ci].inProgressConstructions.sorted(by: { $0.key < $1.key }) where name != currentName {
            let here = cities[ci]
            let reasons: [ConstructionRejection]
            if let def = rs.buildings[name] { reasons = buildingRejections(def, city: here) }
            else if let def = rs.units[name] { reasons = unitRejections(def, city: here) }
            else { cities[ci].inProgressConstructions[name] = nil; continue }   // not in the ruleset any more
            guard reasons.contains(where: { definitive.contains($0.type) }) else { continue }
            // Unciv: production put into wonders gets refunded
            if let def = rs.buildings[name], def.isWonder, banked != 0, let civIdx = civIndex(here.civId) {
                civs[civIdx].gold += Double(banked); goldTrace(here.civId, Double(banked))
                notify(here.civId, "Excess production for [\(name)] converted to [\(banked)] gold", category: .Production, icons: ["Gold", name], coord: here.coord)
            }
            // ...and production put into a unit that is merely obsolete moves to the unit it upgrades into. This is
            // the same rule the queue walk above applies; Unciv runs both from one loop over inProgressConstructions.
            carryObsoleteWork(cityIndex: ci, unit: name, work: banked)
            cities[ci].inProgressConstructions[name] = nil
        }
    }

    /// Unciv CityConstructions.validateInProgressConstructions: "Production put into upgradable units gets put into
    /// the upgraded version" - but only when obsolescence is the ONLY thing rejecting the unit.
    private func carryObsoleteWork(cityIndex ci: Int, unit name: String, work: Int) {
        guard work > 0, let def = rs.units[name] else { return }
        let city = cities[ci]
        guard unitRejections(def, city: city).allSatisfy({ $0.type == "Obsoleted" }) else { return }
        let upgrades = def.uniqueObjects.filter { $0.pattern == "Can upgrade to []" }.map { $0.param(0) }
            + (def.upgradesTo.map { [$0] } ?? [])
        guard let best: UnitDef = upgrades.compactMap({ (n: String) -> UnitDef? in rs.units[equivalentUnitName(city.civId, n)] })
            .filter({ canProduce(.unit($0.name), in: city) })
            .min(by: { $0.cost < $1.cost }) else { return }
        // Unciv keeps one map and the current construction is just an entry in it; we hold the current one in
        // productionStored instead, so the hammers have to land there or nothing ever spends them.
        if case .unit(let cur)? = city.currentProduction, cur == best.name {
            cities[ci].productionStored += Double(work)
        } else {
            cities[ci].inProgressConstructions[best.name, default: 0] += work
        }
    }
}
