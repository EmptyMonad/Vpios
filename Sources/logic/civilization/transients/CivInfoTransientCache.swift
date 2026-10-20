// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/transients/CivInfoTransientCache.kt`: the derived state a civ keeps to hand - its resources, and what it is connected to.
extension GameState {
    /// Unciv Civilization.getCivResourcesByName: every resource's amount as the STORED supply has it
    /// (`summarizedCivResourceSupply`, written only by updateCivResources), stockpiled resources reporting the
    /// stockpile instead. Between two updateCivResources calls the answer does not move even when the map does.
    /// Ours recomputed the supply whenever a unit or a city changed.
    func resourceCounts(_ civId: Int) -> [String: Int] {
        guard let civ = civ(civId) else { return [:] }
        var counts: [String: Int] = [:]
        for e in civResourceSupplyList(civId) where rs.resources[e.resource]?.isStockpiled != true { counts[e.resource] = e.amount }
        for (key, value) in civ.resourceStockpiles { counts[key] = value }
        return counts
    }

    /// Per-turn resource supply (tiles, buildings, deals, city-states, minus consumption).
    /// Unciv TileResource.matchesSingleFilter
    func resourceMatches(_ r: ResourceDef, _ filter: String) -> Bool {
        if filter == r.name || filter == "any" || filter == "all" || filter == r.resourceType { return true }
        return r.improvementStats[filter] != 0   // Unciv: improvementStats?.any { filter == it.key.name }
    }

    /// Unciv CityResources.getResourceModifiers: `(modifiers[r] ?: 1f) + params[0].toFloat() / 100f`, in Float,
    /// for every "[x]% [resourceFilter] resource production" the city (civ-wide and local) holds.
    func cityResourceModifiers(_ city: City) -> [String: Float] {
        var modifiers: [String: Float] = [:]
        let ctx = UniqueContext(civId: city.civId, city: city)
        for u in cityUniques(city) where u.pattern == "[]% [] resource production" && conditionalsHold(u, ctx) {
            let bonus = Float(u.double(0)) / 100
            for r in rs.resourcesInOrder where resourceMatches(r, u.param(1)) { modifiers[r.name] = (modifiers[r.name] ?? 1) + bonus }
        }
        return modifiers
    }

    /// Unciv Tile.providesResources
    func tileProvidesResources(_ t: Tile, civ: Civilization) -> Bool {
        guard let res = t.resource, let r = rs.resources[res] else { return false }
        if let rev = r.revealedBy, !civ.techs.contains(rev) { return false }
        let possible = rs.resourceImprovements[res] ?? []
        if t.isCityCenter {
            if possible.isEmpty { return true }
            return possible.contains { name in
                guard let d = rs.improvements[name] else { return false }
                return d.turnsToBuild != -1 && (d.techRequired.map { civ.techs.contains($0) } ?? true)
            }
        }
        guard let imp = t.improvement, !t.pillaged, let d = rs.improvements[imp] else { return false }
        if possible.contains(imp) && (d.techRequired.map { civ.techs.contains($0) } ?? true) { return true }
        return r.resourceType == "Strategic" && d.isGreatImprovement
    }

    /// Unciv CityResources.getResourcesGeneratedByCity (`includeCivUniques = false`: what the city hands its civ)
    /// and getCityResourcesAvailableToCity's list (`true`). A ResourceSupplyList: the tiles as `city.getTiles()`
    /// walks them ("Tiles"), the improvements' own resources ("Improvements"), the buildings' requirements
    /// ("Buildings"), the Mercantile luxury, then the uniques under their source - each group merged by
    /// (resource, origin) and its modifiers applied in Float, as there. Ours summed a Dictionary and put the
    /// order back afterwards from a second walk.
    func resourceSupplyGeneratedByCity(_ city: City, includeCivUniques: Bool = false) -> ResourceSupplyList {
        let modifiers = cityResourceModifiers(city)
        var cityResources = resourcesGeneratedByCityNotIncludingBuildings(city, modifiers)
        if includeCivUniques {
            // getCityResourcesAvailableToCity: `cityResources.add(list)` merges entry by entry
            cityResources.add(cityResourcesGeneratedFromUniques(city, modifiers, includeCivUniques: true))
        } else {
            // getResourcesGeneratedByCity: `cityResources += list` is ArrayList.addAll - appended as they are
            cityResources.appendAll(cityResourcesGeneratedFromUniques(city, modifiers, includeCivUniques: false))
        }
        return cityResources
    }

    /// The same list summed by resource, for the readers that only want amounts.
    func resourcesGeneratedByCity(_ city: City, includeCivUniques: Bool = false) -> [String: Int] {
        var out: [String: Int] = [:]
        for e in resourceSupplyGeneratedByCity(city, includeCivUniques: includeCivUniques).entries { out[e.resource, default: 0] += e.amount }
        return out
    }

    /// Unciv CityResources.getResourcesGeneratedByCityNotIncludingBuildings
    private func resourcesGeneratedByCityNotIncludingBuildings(_ city: City, _ modifiers: [String: Float]) -> ResourceSupplyList {
        var cityResources = ResourceSupplyList()
        guard let civ = civ(city.civId) else { return cityResources }
        let walk = uncivTileWalk(city)
        // getResourcesFromTiles, with getTileResourceAmount
        var fromTiles = ResourceSupplyList()
        let extraLuxury = city.buildings.contains { rs.buildings[$0]?.uniques.contains("Provides 1 extra copy of each improved luxury resource near this City") == true }
        for c in walk {
            guard let t = map[c], let res = t.resource, let r = rs.resources[res], tileProvidesResources(t, civ: civ) else { continue }
            var amount = r.resourceType == "Strategic" ? t.resourceAmount : 1
            if r.resourceType == "Luxury" && extraLuxury { amount += 1 }
            if amount > 0 { fromTiles.add(res, "Tiles", amount) }
        }
        fromTiles.applyModifiers(modifiers)
        cityResources.add(fromTiles)
        // getResourceFromUniqueImprovedTiles: provided, modified, and only then consumed - one "Improvements" list
        var improved = ResourceSupplyList()
        let applicable: [(Tile, ImprovementDef)] = walk.compactMap { c in
            guard let t = map[c], let imp = t.improvement, !t.pillaged, let d = rs.improvements[imp] else { return nil }
            return (t, d)
        }
        for (t, d) in applicable {
            let ctx = UniqueContext(civId: city.civId, city: city, tile: t)
            for u in d.uniqueObjects where u.pattern == "Provides [] []" && rs.resources[u.param(1)] != nil && conditionalsHold(u, ctx) {
                improved.add(u.param(1), "Improvements", u.int(0))
            }
        }
        improved.applyModifiers(modifiers)
        for (t, d) in applicable {
            let ctx = UniqueContext(civId: city.civId, city: city, tile: t)
            for u in d.uniqueObjects where u.pattern == "Consumes [] []" && rs.resources[u.param(1)] != nil && conditionalsHold(u, ctx) {
                improved.add(u.param(1), "Improvements", -1 * u.int(0))
            }
        }
        cityResources.add(improved)
        // getNegativeCityResourcesRequiredByBuildings: a free building eats nothing
        var required = ResourceSupplyList()
        let cityCtx = UniqueContext(civId: city.civId, city: city)
        let freeBuildings = freeBuildingNames(city)   // Unciv `city.civ.civConstructions.getFreeBuildingNames(city)`
        for b in city.builtBuildingObjects where !freeBuildings.contains(b) {   // getBuiltBuildings()
            guard let d = rs.buildings[b] else { continue }
            required.subtractResourceRequirements(orderedResourceRequirements(requiredResource: d.requiredResource, uniques: d.uniqueObjects, ctx: cityCtx), rs: rs, origin: "Buildings")
        }
        cityResources.add(required)
        if civ.isCityState, city.isCapital, let r = civ.cityStateResource, rs.resources[r] != nil {
            cityResources.add(r, "Mercantile City-State")
        }
        return cityResources
    }

    /// Unciv CityResources.getCityResourcesGeneratedFromUniques: "Provides [n] [resource]" under its source's
    /// name, then "[x]% of [stat] from every [filter] in the city added to [resource]", then the modifiers.
    private func cityResourcesGeneratedFromUniques(_ city: City, _ modifiers: [String: Float], includeCivUniques: Bool) -> ResourceSupplyList {
        var buildingResources = ResourceSupplyList()
        let cityCtx = UniqueContext(civId: city.civId, city: city)
        // city.forEachMatchingUnique(type, includeCivUniques): the civ's and the local ones, or - without the
        // civ - every built building's uniques and the religion's; timed triggerables never.
        let pool: [Unique] = includeCivUniques ? cityUniques(city)
            : city.buildings.flatMap { b in (rs.buildings[b]?.uniqueObjects ?? []).from(rs.buildings[b]?.isAnyWonder == true ? .wonder : .building, b) } + religionUniques(for: city)
        for u in pool where u.pattern == "Provides [] []" && u.timedTurns == nil && rs.resources[u.param(1)] != nil && conditionalsHold(u, cityCtx) {
            buildingResources.add(u.param(1), u.sourceNameForUser, u.int(0))
        }
        for u in pool where u.pattern == "[]% of [] from every [] in the city added to []" && u.timedTurns == nil && rs.resources[u.param(3)] != nil && conditionalsHold(u, cityCtx) {
            let stat = u.param(1), filter = u.param(2)
            var amount = 0.0
            for b in city.buildings where buildingMatches(b, filter) { if let def = rs.buildings[b] { amount += max(0, def.stats[stat]) } }
            for c in city.workedTiles {
                guard let t = map[c], let imp = t.improvement, !t.pillaged, let idef = rs.improvements[imp], idef.stats[stat] > 0, improvementMatches(imp, filter) else { continue }
                amount += idef.stats[stat]
            }
            if amount > 0 {
                amount *= u.double(0) / 100
                buildingResources.add(u.param(3), u.sourceNameForUser, Int(amount))
            }
        }
        buildingResources.applyModifiers(modifiers)
        return buildingResources
    }

    /// Unciv IConstruction / MapUnit.getResourceRequirementsPerTurn: a Counter (a LinkedHashMap that drops a key
    /// whose count comes to 0) - the required resource first, then every "Consumes [n] [resource]" in order.
    func orderedResourceRequirements(requiredResource: String?, uniques: [Unique], ctx: UniqueContext) -> [(String, Int)] {
        var out: [(String, Int)] = []
        func add(_ k: String, _ v: Int) {
            if let i = out.firstIndex(where: { $0.0 == k }) { out[i].1 += v; if out[i].1 == 0 { out.remove(at: i) } }
            else if v != 0 { out.append((k, v)) }
        }
        if let r = requiredResource { add(r, 1) }
        for u in uniques where u.pattern == "Consumes [] []" && conditionalsHold(u, ctx) { add(u.param(1), u.int(0)) }
        return out
    }

    /// Unciv CityResources.getAvailableResourceAmount
    func availableResourceAmount(_ city: City, _ name: String) -> Int {
        guard let r = rs.resources[name] else { return 0 }
        if !r.isCityWide { return resourceCounts(city.civId)[name] ?? 0 }
        if r.isStockpiled { return city.resourceStockpiles[name] ?? 0 }
        return resourcesGeneratedByCity(city, includeCivUniques: true)[name] ?? 0
    }

    /// Unciv City.gainStockpiledResource
    func gainStockpiledResource(cityId: Int, _ name: String, _ amount: Int) {
        guard let r = rs.resources[name], let ci = cityIndex(cityId) else { return }
        if r.isCityWide { cities[ci].resourceStockpiles[name, default: 0] += amount }
        else if let civIdx = civIndex(cities[ci].civId) { civs[civIdx].resourceStockpiles[name, default: 0] += amount; invalidateHappiness(cities[ci].civId) }
    }

    /// Unciv ImprovementFunctions.getImprovementBuildingProblems → MissingResources
    func improvementResourcesAvailable(_ imp: ImprovementDef, civId: Int) -> Bool { improvementResourcesAvailable(uniques: imp.uniqueObjects, civId: civId) }

    func improvementResourcesAvailable(uniques: [Unique], civId: Int) -> Bool {
        let ctx = UniqueContext(civId: civId)
        let counts = resourceCounts(civId)
        for u in uniques where u.pattern == "Consumes [] []" && conditionalsHold(u, ctx) { if (counts[u.param(1)] ?? 0) < u.int(0) { return false } }
        for (res, amount) in stockpiledResourceRequirements(uniques, ctx: ctx) where (counts[res] ?? 0) < amount { return false }
        return true
    }

    /// Unciv Tile.startWorkingOnImprovement: stockpiled costs come out of the civ stockpile (city-wide ones are ignored)
    func payImprovementStockpileCosts(_ imp: String, unit: Unit) {
        guard let d = rs.improvements[imp], let ci = civIndex(unit.civId) else { return }
        for (res, amount) in stockpiledResourceRequirements(d.uniqueObjects, ctx: UniqueContext(civId: unit.civId, unit: unit)) {
            guard let r = rs.resources[res], !r.isCityWide else { continue }
            civs[ci].resourceStockpiles[res, default: 0] -= amount
        }
        invalidateHappiness(unit.civId)
    }

    /// Unciv CivInfoTransientCache.updateCivResources: the city-state bonus maps are rebuilt, then the detailed
    /// supply - every city's getResourcesGeneratedByCity, the allied city-states' resources (not for a
    /// city-state), the civ-wide "Provides" uniques, each diplomacy's trades, the units' upkeep, city-wide
    /// resources removed. When that list is EQUAL to the stored one (List equality: resource, origin and amount,
    /// entry by entry) nothing else happens; otherwise the detailed and summarized fields are replaced and
    /// updateStatsForNextTurn runs ("More or less resources = more or less happiness").
    ///
    /// Ours stored the fields and then went on computing the supply live wherever it was read, so the stored
    /// value was written and never looked at.
    func updateCivResources(_ civId: Int) {
        guard civ(civId) != nil else { return }
        // updateCityStateBonuses
        cityStateBonusCache[civId] = computeCityStateBonusUniques(for: civId)
        civUniquesCache[civId] = nil
        if epochsDebug { AI.profile["n.updateCivResources", default: 0] += 1 }
        // Unciv's `detailedCivResources` starts as an empty list, so a first call that finds nothing changes nothing.
        if storedDetailedSupply[civId] == nil { storeCivResources(civId, ResourceSupplyList()) }
        let newDetailed = computeDetailedCivResources(civId)
        if newDetailed == storedDetailedSupply[civId] { return }
        if let who = ProcessInfo.processInfo.environment["RESDIFF"], who == civ(civId)?.nation {
            let old = Set((storedDetailedSupply[civId]?.entries ?? []).map { "\($0.resource)/\($0.origin)=\($0.amount)" })
            let new = Set(newDetailed.entries.map { "\($0.resource)/\($0.origin)=\($0.amount)" })
            print("RESDIFF t=\(turn) \(who) +\(new.subtracting(old).sorted()) -\(old.subtracting(new).sorted()) by " + Thread.callStackSymbols.dropFirst(1).prefix(5).map { String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first ?? "") }.joined(separator: " < "))
        }
        let evOld = GameState.evlogOn ? (storedSummarizedSupply[civId]?.entries ?? []) : []
        storeCivResources(civId, newDetailed)
        if GameState.evlogOn { evResources(civId, old: evOld.map { ($0.resource, $0.amount) }) }
        if !resourceStatsUpdateInProgress {
            if epochsDebug { AI.profile["n.civResFired", default: 0] += 1 }
            resourceStatsUpdateInProgress = true
            updateStatsForNextTurn(civId)
            resourceStatsUpdateInProgress = false
        }
    }

    /// `civInfo.detailedCivResources = new; civInfo.summarizedCivResourceSupply = new.sumByResource("All")`
    private func storeCivResources(_ civId: Int, _ detailed: ResourceSupplyList) {
        storedDetailedSupply[civId] = detailed
        storedDetailedResources[civId] = detailed.entries.map { ($0.resource, $0.origin, $0.amount) }
        let summarized = detailed.sumByResource("All")
        storedSummarizedSupply[civId] = summarized
        var amounts: [String: Int] = [:]
        for e in summarized.entries { amounts[e.resource, default: 0] += e.amount }
        storedResourceSupply[civId] = amounts
    }

    /// The stored fields exist from the game's setTransients on (GameStarter, the Unciv importer); a native save
    /// loaded without them gets them here, the way setTransients would have filled them - without the stats update.
    private func ensureCivResources(_ civId: Int) {
        guard storedDetailedSupply[civId] == nil, civ(civId) != nil else { return }
        // Unciv's fields start empty, and that is what a reader asking while they are being computed (a
        // "with [resource]" conditional, the held resources' uniques) sees - also what stops this recursing.
        storeCivResources(civId, ResourceSupplyList())
        storeCivResources(civId, computeDetailedCivResources(civId))
    }

    /// The new detailed list, built in updateCivResources' order.
    private func computeDetailedCivResources(_ civId: Int) -> ResourceSupplyList {
        var newDetailed = ResourceSupplyList()
        guard let civ = civ(civId) else { return newDetailed }
        for city in cities(of: civId) { newDetailed.add(resourceSupplyGeneratedByCity(city)) }
        if !civ.isCityState {
            // First each allied city-state's resources separately, then combined as "City-States"
            var cityStateProvided = ResourceSupplyList()
            var resourceBonusPercentage: Float = 1
            let ctx = UniqueContext(civId: civId)
            for u in civUniques(civId) where u.pattern == "[]% resources gifted by City-States" && conditionalsHold(u, ctx) { resourceBonusPercentage += Float(u.double(0)) / 100 }
            for cityStateAlly in knownCivs(civId) where cityStateAlly.isCityState && ally(of: cityStateAlly.id) == civId {
                let csCtx = UniqueContext(civId: cityStateAlly.id)
                for supply in cityStateResourceSupplyForAlly(cityStateAlly.id).entries {
                    guard let def = rs.resources[supply.resource] else { continue }
                    if def.uniqueObjects.contains(where: { $0.pattern == "Cannot be traded" && conditionalsHold($0, csCtx) }) { continue }
                    cityStateProvided.add(supply.resource, supply.origin, Int(Float(supply.amount) * resourceBonusPercentage))
                }
            }
            newDetailed.addByResource(cityStateProvided, "City-States")
        }
        // civInfo.forEachMatchingUnique(ProvidesResources): not a building's or a wonder's ("already calculated in city")
        let ctx = UniqueContext(civId: civId)
        for u in civUniques(civId) where u.pattern == "Provides [] []" && u.sourceObjectType != .building && u.sourceObjectType != .wonder && conditionalsHold(u, ctx) {
            guard let def = rs.resources[u.param(1)] else { continue }
            newDetailed.add(def.name, u.sourceNameForUser, Int(Float(u.int(0)) * civResourceModifier(civId, def)))
        }
        // for (diplomacyManager in civInfo.diplomacy.values) add(diplomacyManager.resourcesFromTrade())
        for other in diplomacyOrder(civId) {
            var fromTrade = ResourceSupplyList()
            for d in deals where d.kind == .resource && ((d.from == civId && d.to == other) || (d.to == civId && d.from == other)) {
                guard let r = d.resource, let def = rs.resources[r], !def.isStockpiled else { continue }
                // This civ's own copy of the trade: the resource flows for as long as the trade is in it.
                guard d.exists(for: civId) else { continue }
                fromTrade.add(r, "Trade", d.from == civId ? -max(1, d.amount) : max(1, d.amount))
            }
            newDetailed.add(fromTrade)
        }
        for u in units(of: civId) {
            newDetailed.subtractResourceRequirements(orderedResourceRequirements(requiredResource: u.def.requiredResource, uniques: u.def.uniqueObjects, ctx: UniqueContext(civId: civId, unit: u)), rs: rs, origin: "Units")
        }
        newDetailed.removeAll { rs.resources[$0.resource]?.isCityWide == true }
        return newDetailed
    }

    /// Unciv `Civilization.detailedCivResources`: the stored list, with each entry's origin.
    func detailedCivResources(_ civId: Int) -> [(resource: String, origin: String, amount: Int)] {
        ensureCivResources(civId)
        return storedDetailedResources[civId] ?? []
    }

    /// Unciv `Civilization.getCivResourceSupply()` = `summarizedCivResourceSupply`: one entry per resource, in the
    /// order sumByResource left them, a resource netting to zero absent.
    func civResourceSupplyList(_ civId: Int) -> [ResourceSupply] {
        ensureCivResources(civId)
        return storedSummarizedSupply[civId]?.entries ?? []
    }

    /// The same stored supply by resource name.
    func civResourceSupply(_ civId: Int) -> [String: Int] {
        ensureCivResources(civId)
        return storedResourceSupply[civId] ?? [:]
    }

    /// Unciv Civilization.getResourceModifier: `1f + Σ params[0].toFloat() / 100f` over "[x]% [resourceFilter] resource production"
    func civResourceModifier(_ civId: Int, _ r: ResourceDef) -> Float {
        var modifier: Float = 1
        let ctx = UniqueContext(civId: civId)
        for u in civUniques(civId) where u.pattern == "[]% [] resource production" && resourceMatches(r, u.param(1)) && conditionalsHold(u, ctx) { modifier += Float(u.double(0)) / 100 }
        return modifier
    }

    /// Unciv getHappinessBreakdown "Luxury resources": the luxuries of the stored supply none of whose
    /// "Obsolete with [tech]" techs is researched.
    func luxuryTypesOwned(_ civId: Int) -> Int {
        guard let civ = civ(civId) else { return 0 }
        return civResourceSupplyList(civId).filter { e in
            guard let r = rs.resources[e.resource], r.resourceType == "Luxury" else { return false }
            return !r.uniqueObjects.contains { $0.pattern == "Obsolete with []" && civ.techs.contains($0.param(0)) }
        }.count
    }

    // MARK: happiness

    /// Unciv `getHappinessBreakdown(): HashMap<String, Float>` - named, SIGNED rows that are summed, not
    /// magnitudes in fixed fields. The names are Unciv's, so a breakdown printed here can be read straight
    /// against the reference's.
    struct HappinessBreakdown {
        /// The rows with a value, in the order their keys were first put in.
        private(set) var rows: [(String, Double)] = []
        /// Every key put in, zero or not: Unciv's `HashMap<String, Float>` holds them all, and how many there are
        /// decides its capacity and so the order `values.sum()` walks.
        private(set) var keys: [String] = []
        /// Unciv `statMap[key] = value + (statMap[key] ?: 0f)` - a Float per key.
        mutating func add(_ key: String, _ value: Double) {
            if !keys.contains(key) { keys.append(key) }
            guard value != 0 else { return }
            if let i = rows.firstIndex(where: { $0.0 == key }) { rows[i].1 = Stats.f32(rows[i].1 + value) } else { rows.append((key, Stats.f32(value))) }
        }
        subscript(_ key: String) -> Double { rows.first(where: { $0.0 == key })?.1 ?? 0 }
        /// Unciv: `stats.getHappinessBreakdown().values.sum().roundToInt()` - a Float fold, so it rounds at
        /// every row, over the HashMap's own order (bucket by bucket, then insertion). Ours summed Doubles and
        /// could land the other side of a `.5` when the caller rounds.
        var total: Double {
            var t = 0.0
            // Each row is a Float there as well: t_45 turn 79, Japan's Population row -28.500000476837 is -28.5
            // as a Float, the sum 3.5 rounds to 4, and the empire kept earning 4 golden age points, not 3.
            for k in javaHashMapOrder(keys) { t = Stats.f32(t + Stats.f32(self[k])) }
            return t
        }
    }

    /// Unciv CivInfoTransientCache.updateCitiesConnectedToCapital: the finder's map (every city, of any civ, the
    /// capital reaches - the capital included) is STORED, and read by isCapitalConnectedToCity and
    /// City.isConnectedToCapital until the next update: turn start, a building added or removed, the load.
    /// The notifications compare with the previous map (with the saved flags on the initial setup).
    func updateCitiesConnectedToCapital(_ civId: Int, initialSetup: Bool = false) {
        guard let cv = civIndex(civId), !cities(of: civId).isEmpty else { return }   // No cities to connect
        railroadCache[civId] = nil; _ = railroadConnectedCityIds(civId)
        // Unciv walks both key sets in their own order: the saved flags' `filterTo(mutableSetOf())` (a LinkedHashSet, in
        // civ.cities order), or the finder's `HashMap<City, ...>()`, which under the reference's identity hash 1 is
        // JavaHash1Set's walk of the insertion sequence - past ten cities the bin is a tree and a city reached later
        // walks in right after the first one. Ours walked the ids in ascending order (nuke t=180: America's eight
        // "disconnected" notices with Athens after Yerevan where Unciv's has it before Bucharest).
        let oldOrder: [Int] = (initialSetup || civs[cv].citiesConnectedToCapital == nil)
            ? cities(of: civId).filter { $0.connectedToCapital }.map { $0.id }
            : JavaHash1Set.iterationOrder(civs[cv].citiesConnectedToCapital ?? [])
        let old = Set(oldOrder)
        let found = findCapitalConnections(civId)
        let newConnected = found.map { $0.cityId }
        civs[cv].citiesConnectedToCapital = newConnected
        // CityStats.isConnectedToCapital(Railroad): a medium whose road type is the railroad.
        civs[cv].citiesConnectedByRailroad = found.filter { $0.mediums.contains { $0.isRailroad } }.map { $0.cityId }
        civs[cv].citiesConnectedByRoad = found.filter { $0.mediums.contains { $0.roadLevel > 0 } }.map { $0.cityId }
        let now = Set(newConnected)
        if ProcessInfo.processInfo.environment["DUMP_CONN"] == civ(civId)?.nation {
            print("CONNE t=\(turn) \(civ(civId)?.nation ?? "?") [\(cities(of: civId).map { "\($0.name)=\(now.contains($0.id))" }.joined(separator: ","))] found[\(found.map { f in "\(city(f.cityId)?.name ?? "?")=\(f.mediums.map { "\($0)" }.sorted().joined(separator: "+"))" }.joined(separator: ","))]")
        }
        let capitalId = capital(of: civId)?.id
        for id in JavaHash1Set.iterationOrder(newConnected) where !old.contains(id) {
            guard let city = city(id), city.civId == civId, city.id != capitalId else { continue }
            notify(civId, "[\(city.name)] has been connected to your capital!", category: .Cities, icons: ["Gold"], actions: [.location(city.coord)])   // Unciv: NotificationIcon.Gold
        }
        // "This may still contain cities that have just been destroyed by razing - thus the population test"
        for id in oldOrder where !now.contains(id) {
            guard let city = city(id), city.civId == civId, city.population > 0 else { continue }
            notify(civId, "[\(city.name)] has been disconnected from your capital!", category: .Cities, icons: ["Gold"], actions: [.location(city.coord)])   // Unciv addNotification(text, city.location, ...): a LocationAction
        }
        for i in cities.indices where cities[i].civId == civId { cities[i].connectedToCapital = now.contains(cities[i].id) }
    }

    /// Unciv CapitalConnectionsFinder.find, as the list of cities it reaches, the capital first.
    func findCitiesConnectedToCapital(_ civId: Int) -> [Int] { findCapitalConnections(civId).map { $0.cityId } }

    /// Unciv CapitalConnectionsFinder.find: from the capital, city by city and wave by wave, every city (of any civ
    /// whose borders we may enter) that a road, a railroad or - between our own unblockaded harbours - the water
    /// reaches, each with the mediums it was reached by. Each BFS walks tiles that pass the medium's filter or are a
    /// city centre, and never a tile owned by a civ whose borders are closed to us; the water walk is no exception,
    /// so a coast owned by a closed neighbour cuts a sea route, and a city between two waters joins them.
    /// Railroads are followed only from cities that were themselves reached from the capital by rail.
    func findCapitalConnections(_ civId: Int) -> [(cityId: Int, mediums: Set<CapitalConnectionMedium>)] {
        guard let me = civ(civId), let capital = capital(of: civId) else { return [] }
        func canEnterBordersOf(_ other: Int) -> Bool {
            if other == civId { return true }   // own borders are always open
            guard let o = civ(other), !o.isBarbarian, !me.isBarbarian, me.metCivs.contains(other) else { return false }
            if o.isCityState && !areAtWar(civId, other) { return true }
            return hasOpenBorders(civId, in: other)
        }
        var order: [Int] = [capital.id]
        var reached: [Int: Set<CapitalConnectionMedium>] = [capital.id: [.start]]
        var citiesToCheck: [Int] = [capital.id]
        var newCitiesToCheck: [Int] = []
        let openBordersCivCities = civs.flatMap { cities(of: $0.id) }.filter { canEnterBordersOf($0.civId) }
        func researched(_ improvement: String) -> Bool {
            guard let d = rs.improvements[improvement] else { return false }
            return d.techRequired.map { me.techs.contains($0) } ?? true
        }
        let roadIsResearched = researched("Road"), railroadIsResearched = researched("Railroad")
        let forestRoads = forestsAreRoads(civId)
        func containsHarbor(_ c: City) -> Bool { c.buildings.contains { rs.buildings[$0]?.uniques.contains("Connects trade routes over water") == true } }
        func wasPreviouslyReached(_ id: Int, _ t: CapitalConnectionMedium, _ overriding: CapitalConnectionMedium?) -> Bool {
            let m = reached[id] ?? []
            return m.contains(t) || (overriding.map { m.contains($0) } ?? false)
        }
        func check(_ from: City, _ transport: CapitalConnectionMedium, _ overriding: CapitalConnectionMedium?, tileFilter: (Tile) -> Bool, cityFilter: (City) -> Bool = { _ in true }) {
            if wasPreviouslyReached(from.id, transport, overriding) { return }
            var seen: Set<HexCoord> = [from.coord]
            var frontier = [from.coord]
            while let cur = frontier.popLast() {
                for n in map.neighbors(of: cur) where !seen.contains(n) {
                    guard let t = map[n], t.isCityCenter || tileFilter(t) else { continue }
                    if let owner = t.ownerCivId, !canEnterBordersOf(owner) { continue }
                    seen.insert(n); frontier.append(n)
                }
            }
            for rc in openBordersCivCities where seen.contains(rc.coord) && cityFilter(rc) {
                if reached[rc.id] == nil { newCitiesToCheck.append(rc.id); reached[rc.id] = []; order.append(rc.id) }   // addCityIfFirstEncountered
                if rc.id == from.id { continue }
                if !wasPreviouslyReached(rc.id, transport, overriding) { reached[rc.id]!.insert(transport) }
            }
        }
        let maxCities = openBordersCivCities.count
        while !citiesToCheck.isEmpty && reached.count < maxCities {
            newCitiesToCheck = []
            for id in citiesToCheck {
                guard let from = city(id) else { continue }
                if containsHarbor(from) {
                    check(from, wasPreviouslyReached(from.id, .railroad, nil) ? .harborFromRailroad : .harborFromRoad, .harborFromRailroad,
                          tileFilter: { $0.isWater },
                          cityFilter: { $0.civId == civId && containsHarbor($0) && !self.isCityBlockaded($0) })   // use only own harbors
                }
                if railroadIsResearched, (reached[from.id] ?? []).contains(where: { $0.checkRailroad }) {
                    check(from, .railroad, nil, tileFilter: { $0.railroad && !$0.roadPillaged })
                }
                if roadIsResearched {
                    check(from, .road, .railroad, tileFilter: { t in (t.roads && !t.roadPillaged) || (forestRoads && self.tileIsFriendlyForestRoad(t, civId: civId)) })
                }
            }
            citiesToCheck = newCitiesToCheck
        }
        return order.map { ($0, reached[$0] ?? []) }
    }

    // MARK: enemy movement penalty

    static let enemyMovementPenaltyPattern = "Enemy [] units must spend [] extra movement points when inside your territory"

    /// Unciv CivInfoTransientCache.updateHasActiveEnemyMovementPenalty: `hasUnique(EnemyUnitsSpendExtraMovement)`
    /// with the civ's own conditionals, stored. Run on load, when a building carrying it is added, and at the end
    /// of the civ's turn - so a Great Wall that changes hands, or goes obsolete, keeps or lacks the flag until then.
    /// (Unciv's `enemyMovementPenaltyUniques` is a lazy Sequence, re-read at every use: MovementCost reads the
    /// uniques live behind this flag.)
    func updateHasActiveEnemyMovementPenalty(_ civId: Int) {
        let ctx = UniqueContext(civId: civId)
        hasActiveEnemyMovementPenalty[civId] = civUniques(civId).contains { $0.pattern == GameState.enemyMovementPenaltyPattern && conditionalsHold($0, ctx) }
    }

    /// The stored flag; a game that has not set its transients yet computes it the way setTransients would.
    func activeEnemyMovementPenalty(_ civId: Int) -> Bool {
        if let v = hasActiveEnemyMovementPenalty[civId] { return v }
        updateHasActiveEnemyMovementPenalty(civId)
        return hasActiveEnemyMovementPenalty[civId] ?? false
    }

    // MARK: visibility
    /// Unciv `civInfo.viewableTiles` - `tile.isVisible(civ)`: the FIELD CivInfoTransientCache.updateViewableTiles last
    /// wrote (ours updateExploration), not what the civ would see now. Unciv writes it at startTurn
    /// (TurnManager.kt:63), on a unit's updateVisibleTiles when its view changed past ourTilesAndNeighboringTiles
    /// (MapUnit.kt:830-864), in updateOurTiles (border growth, founding, conquest, a traded city), for a city-state's
    /// new and old ally (CityStateFunctions.kt:309/338), on a unit's destroy and gift (MapUnit.kt:954/969/974), for
    /// a reveal-map trigger (UniqueTriggerActivation.kt:1021), an instant improvement (UnitActionsFromUniques.kt:358)
    /// and on every load and Next Turn (GameInfo.setTransients). Between two writes it stays: a city-state sees
    /// the tiles its ally's new or grown city brings only from its own next write, as the barbarians' camp
    /// placement, the AI's targets and the notifications ask it. Ours used to work the view out on every read.
    /// A civ never written yet (Unciv's `setOf()`, a state built without setTransients) reads the live view.
    func visibleTiles(for civId: Int) -> Set<HexCoord> {
        if let c = civ(civId), c.nation == "Spectator" { return c.explored }
        if let s = civStoredViewableTiles[civId] { return s }
        return liveVisibleTiles(for: civId)
    }

    /// Unciv setNewViewableTiles: what the civ sees now - the view updateExploration stores. Cached until units or
    /// cities change (visGen).
    func liveVisibleTiles(for civId: Int) -> Set<HexCoord> {
        if let (g, s) = visibleCache[civId], g == visGen { return s }
        let out = computeVisibleTiles(for: civId)
        visibleCache[civId] = (visGen, out)
        return out
    }

    /// Unciv MapUnit.getVisibilityRange: base 2, plus every Sight unique of the unit, of the civ, AND of the tile
    /// the unit stands on - its terrain, its natural wonder and its improvement - floored at 1.
    ///
    /// This lived twice: once here inside unitViewableTiles and once copied into tryExplore, and the copy had
    /// dropped the tile term. A copy of a rule is a rule that will disagree with itself.
    func visibilityRange(of u: Unit, civSight: [Unique]? = nil) -> Int {
        var radius = 2
        let ctx = UniqueContext(civId: u.civId, unit: u, tile: map[u.coord])
        for su in u.promotionUniques where su.pattern == "[] Sight" && conditionalsHold(su, ctx) { radius += su.int(0) }
        for su in civSight ?? civUniques(u.civId).filter({ $0.pattern == "[] Sight" }) where conditionalsHold(su, ctx) { radius += su.int(0) }
        if let t = map[u.coord] {
            var tileUniques = t.terrainNames.compactMap { rs.terrains[$0] }.flatMap { $0.uniqueObjects }
            if let w = t.naturalWonder { tileUniques += rs.terrains[w]?.uniqueObjects ?? [] }
            if let imp = t.improvement, !t.pillaged { tileUniques += rs.improvements[imp]?.uniqueObjects ?? [] }
            for su in tileUniques where su.pattern == "[] Sight" && conditionalsHold(su, ctx) { radius += su.int(0) }
        }
        return max(1, radius)
    }

    /// Unciv MapUnit.updateVisibleTiles for one unit.
    func unitViewableTiles(_ u: Unit, civSight: [Unique]) -> Set<HexCoord> {
        if let c = unitViewCache[u.id], unitViewFrozen.contains(u.id) || (c.coord == u.coord && c.promotions == u.promotions.count) { return c.tiles }
        let tiles = computeUnitViewableTiles(u, civSight: civSight)
        unitViewCache[u.id] = (u.coord, u.promotions.count, tiles)
        return tiles
    }
    private func computeUnitViewableTiles(_ u: Unit, civSight: [Unique]) -> Set<HexCoord> {
        if u.promotionUniques.contains(where: { $0.pattern == "No Sight" }) { return [u.coord] }   // Unciv MapUnit: 0 sight still sees its own tile
        let radius = visibilityRange(of: u, civSight: civSight)
        // Unciv MapUnit.getViewableTiles requires CanSeeOverObstacles; being an air unit is not enough - in the shipped
        // ruleset only the Fighter type and the Stealth Bomber have it, so bombers do not see past hills and forests.
        let overObstacles = u.def.uniques.contains("Can see over obstacles") || (rs.unitTypes[u.def.unitType]?.uniques.contains("Can see over obstacles") ?? false)
        return overObstacles ? Set(map.tilesWithin(u.coord, radius: radius)) : viewableTiles(from: u.coord, radius: radius, viewerBonus: 0)
    }

    private func computeVisibleTiles(for civId: Int) -> Set<HexCoord> {
        // Unciv setNewViewableTiles: "while spectating (or defeated in singleplayer, which grants the same rights) all
        // map is visible" - `if (civInfo.hasSpectatorVision()) viewableTiles = tileMap.values.toSet()`, checked BEFORE
        // the defeated branch below. (A Spectator's own view keeps its shortcut in visibleTiles(for:).)
        if let c = civ(civId), hasSpectatorVision(c) { return Set(map.tiles.map { $0.coord }) }
        // Unciv setNewViewableTiles: a defeated civ sees nothing - "Avoid meeting dead city states when entering a tile
        // owned by their former ally (#9245)". Ours let a city-state Austria had married into (nations t=120) go on
        // seeing Austria's cities, meet Songhai there at t=122 and hand it a goodwill gift.
        if let c = civ(civId), isDefeated(c) { return [] }
        var out: Set<HexCoord> = []
        let civSight = civUniques(civId).filter { $0.pattern == "[] Sight" }
        for u in units where u.civId == civId { out.formUnion(unitViewableTiles(u, civSight: civSight)) }
        for c in cities where c.civId == civId {
            out.formUnion(c.tiles)
            for t in c.tiles { out.formUnion(map.neighbors(of: t).filter { map[$0] != nil }) }
        }
        // Unciv: we also see the cities of the city-states allied with us, and the city each of our spies sits in
        for cs in cityStates where isAlly(civId, of: cs.id) { for c in cities(of: cs.id) { out.formUnion(c.tiles) } }
        // ...and the other way round: `otherCiv == civInfo.allyCiv` - a city-state sees its ally's cities too. Without
        // it Yerevan had never seen Greece's hills and planned a trireme route across them.
        if civ(civId)?.isCityState == true, let allyId = ally(of: civId) { for c in cities(of: allyId) { out.formUnion(c.tiles) } }
        // Unciv EspionageManager.getTilesVisibleViaSpies: a spy that has finished setting up sees the city
        // centre and the ring around it, not a single tile, and sees nothing while still moving in.
        for spy in civ(civId)?.spies ?? [] where spy.alive && GameState.spySetUpActions.contains(spy.action) {
            if let cid = spy.cityId, let c = city(cid) { out.formUnion(map.tilesWithin(c.coord, radius: 1)) }
        }
        return out
    }

    /// Unciv `civInfo.viewableTiles` in the order its HashSet<Tile> walks - the walk updateViewableTiles meets civs
    /// in and discoverNaturalWonders collects wonders in. The members are exactly `visibleTiles(for:)`; only the
    /// order comes from here. Under the reference's identity hash 1 the walk is a function of the insertion
    /// sequence (JavaHash1Set), and setNewViewableTiles inserts:
    /// `HashSet<Tile>(ourTilesAndNeighboringTiles)` - each city's getTiles, each tile followed by its neighbours,
    /// made distinct by `Sequence.toSet` (a LinkedHashSet); then every unit's viewableTiles not owned by us, in
    /// getCivUnits order; then the cities of allied known civs; then the spy tiles. With spectator vision it is
    /// `tileMap.values.toSet()`, a LinkedHashSet in tileList order.
    /// Ours met civs in id order and took the tile from a Swift Set, so which of two majors a city-state met first
    /// - and gave the doubled "first major civ to meet them" gift - and the notification tile were the run's.
    func civViewableTilesUncivOrder(_ civId: Int) -> [HexCoord] {
        let vis = visibleTiles(for: civId)
        guard let me = civ(civId), !vis.isEmpty else { return [] }
        var walk: [HexCoord]
        if me.isSpectator {
            walk = map.tilesInUncivOrder().map { $0.coord }
        } else {
            // ourTilesAndNeighboringTiles: cities.flatMap { getTiles() }.flatMap { sequenceOf(it) + it.neighbors }.toSet()
            var seed: [HexCoord] = []
            var seeded: Set<HexCoord> = []
            for c in cities(of: civId) {
                for t in uncivTileWalk(c) {
                    if seeded.insert(t).inserted { seed.append(t) }
                    for n in map.neighbors(of: t) where seeded.insert(n).inserted { seed.append(n) }
                }
            }
            var inserts = seed
            // `newViewableTiles.addAll(getCivUnits().flatMap { unit.viewableTiles.filter { it.getOwner() != civInfo } })`:
            // each unit's STORED view - where it was computed, which for a unit inside moveThroughTile is the tile it came from
            let civSight = civUniques(civId).filter { $0.pattern == "[] Sight" }
            for u in units(of: civId) {
                let members = unitViewableTiles(u, civSight: civSight)
                var at = u
                if let cached = unitViewCache[u.id] { at.coord = cached.coord }
                var ordered = unitViewableTilesUncivOrder(at).filter { members.contains($0) }
                if ordered.count != members.count { let have = Set(ordered); ordered += uncivTileOrder(members.filter { !have.contains($0) }) }
                inserts += ordered.filter { map[$0]?.ownerCivId != civId }
            }
            // `for (otherCiv in civInfo.getKnownCivs()) if (otherCiv.allyCiv == civInfo || otherCiv == civInfo.allyCiv)`
            for other in knownCivs(civId) where ally(of: other.id) == civId || ally(of: civId) == other.id {
                for c in cities(of: other.id) { inserts += uncivTileWalk(c) }
            }
            // EspionageManager.getTilesVisibleViaSpies: set-up spies, their city centre's getTilesInDistance(1)
            for spy in me.spies where spy.alive && GameState.spySetUpActions.contains(spy.action) {
                if let cid = spy.cityId, let c = city(cid) { inserts += map.tilesWithin(c.coord, radius: 1) }
            }
            // `HashSet(Collection)` on the reference's JDK 19: `HashMap.newHashMap(max(c.size(), 12))`, i.e. a capacity
            // of ceil(n / 0.75) - the later addAll calls may resize it
            let capacity = JavaHash1Set.jdk19CollectionCapacity(seed.count)
            walk = JavaHash1Set.iterationOrder(inserts, initialCapacity: capacity)
        }
        var out = walk.filter { vis.contains($0) }
        if out.count != vis.count { let have = Set(out); out += uncivTileOrder(vis.filter { !have.contains($0) }) }
        return out
    }

    /// Elevation used for line of sight: hills 1, mountains 2 ("Has an elevation of [] for visibility calculations").
    func tileHeight(_ t: Tile) -> Int {
        var h = 0
        // Unciv Tile.unitHeight: allTerrains = base terrain, dogal harika, sonra feature'lar
        for name in [t.baseTerrain] + (t.naturalWonder.map { [$0] } ?? []) + t.features { if let e = rs.terrainElevation[name] { h += e } }   // Unciv sumOf
        return h
    }

    /// Height that blocks sight through the tile: forests and jungles add one level ("Blocks line-of-sight from tiles at same elevation").
    func blockingHeight(_ t: Tile) -> Int {
        var h = tileHeight(t)
        if t.terrainNames.contains(where: { rs.terrainBlocksSight.contains($0) }) { h += 1 }
        return h
    }

    /// Unciv TileMap.getViewableTiles: ring by ring, every tile remembers the tallest obstacle on the way to it
    /// (maxHeightSeenToTile). A tile is seen when the viewer is at least as tall as the lowest such obstacle among its
    /// neighbours one ring closer, or when the tile itself rises above it. One ring beyond the sight distance is scanned
    /// as well, and only tiles taller than the viewer appear there. With `forAttack` the target's own height counts
    /// (Unciv isAttackable) and that extra ring is skipped.
    func viewableTiles(from center: HexCoord, radius: Int, viewerBonus: Int, forAttack: Bool = false) -> Set<HexCoord> {
        Set(viewableTilesList(from: center, radius: radius, viewerBonus: viewerBonus, forAttack: forAttack))
    }

    /// The same walk, in the order Unciv builds it: the centre, then each ring outwards. Unciv's getViewableTiles
    /// returns a List and its callers keep that order; handing them a Swift Set instead let the process hash seed
    /// decide which of several equally good targets a ranged unit shot at.
    func viewableTilesList(from center: HexCoord, radius: Int, viewerBonus: Int, forAttack: Bool = false) -> [HexCoord] {
        guard let ct = map[center] else { return [] }
        let viewerHeight = tileHeight(ct) + viewerBonus
        var result: [HexCoord] = forAttack ? [] : [center]   // Unciv: the centre is visible to itself but never attackable
        var maxHeightSeen: [HexCoord: Int] = [center: viewerHeight]
        guard radius >= 1 else { return result }
        for d in 1...(radius + 1) {
            // Unciv gathers the whole ring before merging it: tiles of the same ring never see for one another.
            var batch: [(coord: HexCoord, height: Int, visible: Bool)] = []
            // Unciv TileMap.forEachTileAtDistance: the neighbours in their own order at distance 1, then from 6
            // o'clock each tile paired with its mirror. The ring is gathered as a batch, so the order only shows in
            // the returned list - which is the order an attacker's targets are ranked in (ties: first wins).
            let ringOrder = d == 1 ? map.neighbors(of: center) : map.tilesInDistanceUncivOrder(center, radius: d).filter { $0.distance(to: center) == d }
            for raw in ringOrder {
                let c = map.normalize(raw)
                guard c.distance(to: center) == d, maxHeightSeen[c] == nil, let t = map[c] else { continue }
                let tileH = blockingHeight(t)
                if d == radius + 1 && (tileH <= viewerHeight || forAttack) { continue }
                var lowestObstacle = Int.max
                for n in map.neighbors(of: c) where n.distance(to: center) == d - 1 {
                    if let h = maxHeightSeen[n] { lowestObstacle = min(lowestObstacle, h) }
                }
                guard lowestObstacle != Int.max else { continue }
                let targetHeight = forAttack ? tileHeight(t) : tileH
                batch.append((c, max(tileH, lowestObstacle), viewerHeight >= lowestObstacle || targetHeight > lowestObstacle))
            }
            for entry in batch {
                maxHeightSeen[entry.coord] = entry.height
                if entry.visible { result.append(entry.coord) }
            }
        }
        return result
    }

    /// Unciv MapUnit.isVisibleTo(civ) for an invisible unit (the caller has already asked that the tile is visible):
    /// an "Invisible to non-adjacent units" unit is seen when one of our units stands next to it, otherwise only
    /// where Civilization.viewableInvisibleUnitsTiles has a filter it matches. That map is a STORED one - rebuilt by
    /// updateViewableTiles, which a unit's updateVisibleTiles skips when all it saw before and sees now lies in our
    /// tiles and their neighbours - so a detector that has sailed home can still be "seeing" the tile it left
    /// (t_45 with victories on, t=265: Japan's Destroyer retreated to Constantinople and the Carthaginian Submarine
    /// it had spotted at -9,-3 still counted as an enemy near -8,-5). Ours asked the detectors where they stand now,
    /// and let every unit in a city centre be seen, which isVisibleTo does not.
    func canSeeInvisibleUnit(_ u: Unit, from civId: Int) -> Bool {
        if u.civId == civId { return true }
        if civ(civId)?.isSpectator == true { return true }   // hasActiveInvisibilityUnique: `!to.isSpectator()`
        if u.def.isInvisible && units(of: civId).contains(where: { $0.coord.distance(to: u.coord) <= 1 }) { return true }
        let filters = viewableInvisibleUnitsTiles(civId)[u.coord] ?? []
        return filters.contains { unitMatches(u, $0) }
    }

    /// Unciv CivInfoTransientCache.ourTilesAndNeighboringTiles: our cities' tiles and every tile next to them
    func ourTilesAndNeighboringTiles(_ civId: Int) -> Set<HexCoord> {
        var out: Set<HexCoord> = []
        for c in cities where c.civId == civId { for t in c.tiles { out.insert(t); for n in map.neighbors(of: t) where map[n] != nil { out.insert(n) } } }
        return out
    }

    /// Unciv Civilization.viewableInvisibleUnitsTiles, built from scratch on first use after a load (setTransients).
    func viewableInvisibleUnitsTiles(_ civId: Int) -> [HexCoord: Set<String>] {
        if let m = viewableInvisibleUnitsTilesCache[civId] { return m }
        updateViewableInvisibleTiles(civId)
        return viewableInvisibleUnitsTilesCache[civId] ?? [:]
    }

    /// Unciv CivInfoTransientCache.updateViewableInvisibleTiles: every tile each of our "Can see invisible [] units"
    /// units sees, with the filters it can see there.
    func updateViewableInvisibleTiles(_ civId: Int) {
        var out: [HexCoord: Set<String>] = [:]
        let civSight = civUniques(civId).filter { $0.pattern == "[] Sight" }
        for o in units(of: civId) {
            let uniques = o.def.uniqueObjects + o.promotionUniques + (rs.unitTypes[o.def.unitType]?.uniqueObjects ?? [])
            let filters = uniques.filter { $0.pattern == "Can see invisible [] units" }.map { $0.param(0) }
            if filters.isEmpty { continue }
            for t in unitViewableTiles(o, civSight: civSight) { out[t, default: []].formUnion(filters) }
        }
        viewableInvisibleUnitsTilesCache[civId] = out
    }

    /// Units of other civs that this civ can currently see (submarines hide unless adjacent or spotted by a detector).
    func visibleUnits(for civId: Int) -> [Unit] {
        let vis = visibleTiles(for: civId)
        let own = units(of: civId)
        let civSight = civUniques(civId).filter { $0.pattern == "[] Sight" }
        return units.filter { u in
            guard vis.contains(u.coord) else { return false }
            if u.civId != civId && civ(civId)?.nation != "Spectator" && u.promotionUniques.contains(where: { $0.pattern == "Invisible to others" }) { return false }   // Unciv MapUnit.isInvisible
            if u.civId == civId || !u.def.isInvisible { return true }
            if own.contains(where: { $0.coord.distance(to: u.coord) <= 1 }) { return true }
            return own.contains { o in
                let detectors = o.def.uniqueObjects + o.promotionUniques + (rs.unitTypes[o.def.unitType]?.uniqueObjects ?? [])
                guard detectors.contains(where: { $0.pattern == "Can see invisible [] units" && ($0.param(0) == u.def.unitType || $0.param(0) == u.def.name) }) else { return false }
                return unitViewableTiles(o, civSight: civSight).contains(u.coord)   // Unciv: the detector's own sight, not a flat radius
            }
        }
    }

    /// Unciv MapUnit.updateVisibleTiles: the unit's own uniques (base unit, promotions, statuses - not the civ's)
    /// with TriggerUponDiscoveringTile fire for the tiles this unit sees that nobody had explored yet.
    func fireDiscoveryTriggers(_ u: Unit, sees: Set<HexCoord>, alreadyExplored: Set<HexCoord>) {
        let isDiscoverTrigger: (Unique) -> Bool = { $0.pattern == "upon discovering a [] tile" }
        let pool = u.promotionUniques.filter { $0.conditionals.contains(where: isDiscoverTrigger) }
        guard !pool.isEmpty else { return }
        let newlyExplored = sees.subtracting(alreadyExplored)
        guard !newlyExplored.isEmpty else { return }
        for c in newlyExplored.sorted(by: { ($0.q, $0.r) < ($1.q, $1.r) }) {
            guard let t = map[c] else { continue }
            for uq in pool where uq.conditionals.contains(where: { isDiscoverTrigger($0) && self.tileMatches(t, $0.param(0), civId: u.civId) }) {
                triggerUniques([uq.withoutConditionals(where: isDiscoverTrigger)], civId: u.civId, cityId: nil, unitId: u.id, triggerText: nil)
            }
        }
    }

    /// Unciv MapUnit.moveThroughTile calls updateVisibleTiles for every tile entered, so a unit with more than one
    /// movement point reveals the whole corridor it walks, not just the disc around where it stops.
    /// Returns whether updateVisibleTiles' `shouldUpdateTiles` held - civ.cache.updateViewableTiles ran.
    /// `explorer` is updateVisibleTiles' explorerPosition: moveThroughTile passes the unit's tile, other callers none.
    @discardableResult
    func revealFromCurrentTile(_ unitId: Int, explorer: HexCoord? = nil) -> Bool {
        let oldViewable = unitStoredViewableTiles[unitId] ?? []   // MapUnit.viewableTiles starts as an empty set
        unitViewCache[unitId] = nil   // Unciv putInTile -> updateVisibleTiles
        guard let u = unit(unitId), let i = civIndex(u.civId) else { return false }
        let civSight = civUniques(u.civId).filter { $0.pattern == "[] Sight" }
        let vis = unitViewableTiles(u, civSight: civSight)
        unitStoredViewableTiles[unitId] = vis
        // Unciv MapUnit.updateVisibleTiles: `civ.cache.updateViewableTiles()` only when the unit's view changed and some
        // tile of the old or the new view lies outside ourTilesAndNeighboringTiles - the civ's stored view
        // (visibleTiles(for:)) and its stored map of detected invisible units are written only then.
        // That civ-wide update is also where civs are met, so a unit meets a civ from any tile of its path, not only
        // from where it stops (nations t=9: Songhai's unit saw Brussels' -7,-1 on its way and met it that turn).
        var updatedCivView = false
        if oldViewable != vis {
            let ours = ourTilesAndNeighboringTiles(u.civId)
            if !oldViewable.isSubset(of: ours) || !vis.isSubset(of: ours) {
                // a barbarian's too: updateViewableTiles stores its view and explores, and meets no one (`if (!civInfo.isBarbarian)`)
                updateExploration(for: u.civId, explorer: explorer)
                updatedCivView = true
            }
        }
        guard !vis.isSubset(of: civs[i].explored) else { return updatedCivView }
        fireDiscoveryTriggers(u, sees: vis, alreadyExplored: civs[i].explored)
        civs[i].explored.formUnion(vis)
        return updatedCivView
    }

    /// `invisible: false` for the calls that stand in for a unit's own updateVisibleTiles, which decides for itself
    /// whether the civ's stored map of detected invisible units is refreshed (see revealFromCurrentTile).
    /// `explorer` is Unciv updateViewableTiles' explorerPosition (nil but from a unit's moveThroughTile).
    func updateExploration(for civId: Int, invisible: Bool = true, explorer: HexCoord? = nil) {
        guard let i = civIndex(civId) else { return }
        if invisible { updateViewableInvisibleTiles(civId) }   // setNewViewableTiles, then updateViewableInvisibleTiles
        let vis = civs[i].nation == "Spectator" ? civs[i].explored : liveVisibleTiles(for: civId)
        civStoredViewableTiles[civId] = vis   // `civInfo.viewableTiles = newViewableTiles`: what visibleTiles(for:) reads
        let exploredBefore = civs[i].explored
        civs[i].explored.formUnion(vis)
        // Unciv `viewableTiles.forEach { it.setExplored(civInfo, true, explorerPosition) }`: a human player's
        // exploredRegion.checkTilePosition for each tile, in the HashSet's walk. A tile inside the region changes
        // nothing, so the walk is only built when some tile lies outside it.
        if civs[i].isPlayer {
            let region = civs[i].exploredRegion
            if vis.contains(where: { let ll = map.longitudeLatitude($0); return region.wouldChange(longitude: ll.longitude, latitude: ll.latitude) }) {
                checkExploredRegion(i, civViewableTilesUncivOrder(civId), explorer: explorer)
            }
        }
        // Unciv MapUnit.updateVisibleTiles: each unit's own uniques (base unit, promotions, statuses — not civ uniques) with
        // TriggerUponDiscoveringTile fire for the tiles that unit sees which the civ had not explored yet; the civ's explored
        // set grows unit by unit, so a tile seen by two units triggers only for the first.
        let civSight = civUniques(civId).filter { $0.pattern == "[] Sight" }
        var exploredSoFar = exploredBefore
        for u in units where u.civId == civId {
            let unitVis = unitViewableTiles(u, civSight: civSight)
            fireDiscoveryTriggers(u, sees: unitVis, alreadyExplored: exploredSoFar)
            exploredSoFar.formUnion(unitVis)
        }
        // Unciv setLastSeenImprovement: remember what stood on every tile we can see, so the fog keeps showing it later.
        for c in vis { if let t = map[c] { if let imp = t.improvement { civs[i].lastSeenImprovement[c] = imp } else if civs[i].lastSeenImprovement[c] != nil { civs[i].lastSeenImprovement[c] = nil } } }
        // Meeting other civs (Unciv DiplomacyFunctions.makeCivilizationsMeet)
        // Unciv updateViewableTiles: `viewedCivs = HashMap<Civilization, Tile>()`, filled while walking viewableTiles
        // with each tile's owner and then the civ of its getFirstUnit() (military, else civilian, else air) - a civ
        // keeps the place it was first put in and the tile it was LAST seen on - and the meetings walk that map.
        // Civilization has no hashCode of its own, so under the reference's hash 1 it walks as JavaHash1Set does.
        // Ours met in civ-id order at a tile taken from a Swift Set: which of two majors a city-state met first - and
        // so gave the doubled "first major civ to meet them" gift - and the notification's tile were the run's.
        // Unciv updateViewableTiles: `if (!civInfo.isBarbarian)`, and a barbarian is never met - "metCiv.isBarbarian
        // || civInfo.diplomacy.containsKey(...) -> continue". Barbarians have no diplomacy entry in Unciv; ours
        // were being put into metCivs, which the known-civs order and the diplomacy turn both walk.
        var viewedCivs: [Int] = []
        var seen: [Int: HexCoord] = [:]
        if !civs[i].isBarbarian {
            let metBefore = civs[i].metCivs
            func isNew(_ o: Int) -> Bool { o != civId && !metBefore.contains(o) && civ(o)?.isBarbarian == false }
            // The ordered walk only matters when someone not yet met is in sight - most updates meet no one. The map
            // itself holds every civ seen (ourselves, known civs, barbarians), as Unciv's does, since its walk
            // depends on all of them.
            if vis.contains(where: { map[$0]?.ownerCivId.map(isNew) ?? false }) || units.contains(where: { isNew($0.civId) && vis.contains($0.coord) }) {
                for c in civViewableTilesUncivOrder(civId) {
                    if let o = map[c]?.ownerCivId { if seen[o] == nil { viewedCivs.append(o) }; seen[o] = c }
                    if let fu = units(at: c).first { if seen[fu.civId] == nil { viewedCivs.append(fu.civId) }; seen[fu.civId] = c }
                }
            }
        }
        for other in JavaHash1Set.iterationOrder(viewedCivs) {
            // `metCiv == civInfo || metCiv.isBarbarian || civInfo.diplomacy.containsKey(metCiv.civID)`, asked anew
            // for each entry
            guard other != civId, !civs[i].metCivs.contains(other), let met = civ(other), !met.isBarbarian else { continue }
            if ProcessInfo.processInfo.environment["MEETTRACE"] != nil, let at = seen[other] {
                let p = uncivPosition(at)
                let viewers = units.filter { $0.civId == civId && unitViewableTiles($0, civSight: civSight).contains(at) }.map { v -> String in let q = uncivPosition(v.coord); return "\(v.name)@\(q.x),\(q.y)" }
                let own = ourTilesAndNeighboringTiles(civId).contains(at)
                let allyId = ally(of: civId)
                let allyCity = allyId.map { a in cities(of: a).contains { $0.tiles.contains(at) } } ?? false
                let csAllied = cityStates.filter { isAlly(civId, of: $0.id) && cities(of: $0.id).contains { $0.tiles.contains(at) } }.map { $0.nation }
                let unitsThere = units.filter { $0.coord == at }.map { "\(civ($0.civId)?.nation ?? "?").\($0.name)" }
                print("MEETE t=\(uncivTurns) \(civs[i].nation) meets \(met.nation) at \(p.x),\(p.y) viewers=\(viewers) own=\(own) ally=\(allyId.flatMap { civ($0)?.nation } ?? "-") allyCity=\(allyCity) csAllied=\(csAllied) units=\(unitsThere) owner=\(map[at]?.ownerCivId.flatMap { civ($0)?.nation } ?? "-")")
            }
            makeCivilizationsMeet(civId, other)
            let at = seen[other]
            if !civs[i].isSpectator { notify(civId, "We have encountered [\(met.nation)]!", category: .Diplomacy, icons: [met.nation, "Diplomacy"], coord: at) }
            notify(other, "We have encountered [\(civs[i].nation)]!", category: .Diplomacy, icons: [civs[i].nation, "Diplomacy"], coord: at)
        }
        // Unciv updateViewableTiles ends, inside the same `if (!civInfo.isBarbarian)`, in discoverNaturalWonders - so a
        // wonder a grown border, a new city's ring, an allied city-state or a gifted unit brings into view is
        // discovered on the spot. Ours waited for the civ's next unit move or next turn start, and another civ could
        // become "first to discover" in between.
        if !civs[i].isBarbarian { discoverNaturalWonders(civId: civId) }
    }

    /// Unciv Tile.getShownImprovement(viewingCiv): the tile's real improvement for no viewer, an AI or a spectator,
    /// otherwise the human's getLastSeenImprovement - what updateViewableTiles last recorded there, visible or not
    /// (ours records one for the AI too, which Unciv's setLastSeenImprovement never does, so an AI's is never read)
    func shownImprovement(_ c: HexCoord, for civId: Int) -> String? {
        guard let t = map[c] else { return nil }
        guard let viewer = civ(civId), viewer.isPlayer, !viewer.isSpectator else { return t.improvement }
        return viewer.lastSeenImprovement[c]
    }
}

/// Unciv CapitalConnectionsFinder.CapitalConnectionMedium.
enum CapitalConnectionMedium: Int, Codable {
    case unknown, start, road, railroad, harbor, harborFromRoad, harborFromRailroad
    /// Unciv `checkRailroad`: reached this way, the city is on an unbroken line from the capital.
    var checkRailroad: Bool { self == .start || self == .railroad || self == .harborFromRailroad }
    /// Unciv `roadType == RoadStatus.Railroad`.
    var isRailroad: Bool { self == .railroad || self == .harborFromRailroad }
    /// Unciv `roadType` as the RoadStatus ordinal: None 0 (Unknown, Start, Harbor), Road 1, Railroad 2.
    var roadLevel: Int {
        switch self {
        case .road, .harborFromRoad: return 1
        case .railroad, .harborFromRailroad: return 2
        case .unknown, .start, .harbor: return 0
        }
    }
}

/// Unciv ResourceSupplyList.ResourceSupply: one row - resource and origin are the key, amount the value.
struct ResourceSupply: Equatable {
    let resource: String
    let origin: String
    var amount: Int
}

/// Mirror of Unciv `models/ruleset/tile/ResourceSupplyList.kt`: an ArrayList of rows whose `add` merges a row
/// into the one with the same resource and origin, and - unless `keepZeroAmounts` - drops a row that comes to 0
/// (so a later add of that key appends it again at the end). Equality is the list's: the rows, in order.
struct ResourceSupplyList: Equatable, Sequence {
    let keepZeroAmounts: Bool
    private(set) var entries: [ResourceSupply] = []

    init(keepZeroAmounts: Bool = false) { self.keepZeroAmounts = keepZeroAmounts }

    static func == (a: ResourceSupplyList, b: ResourceSupplyList) -> Bool { a.entries == b.entries }
    func makeIterator() -> IndexingIterator<[ResourceSupply]> { entries.makeIterator() }

    /// `add(element)`: merged into an existing row, or appended.
    mutating func add(_ element: ResourceSupply) {
        if let i = entries.firstIndex(where: { $0.resource == element.resource && $0.origin == element.origin }) {
            entries[i].amount += element.amount
            if keepZeroAmounts || entries[i].amount != 0 { return }
            entries.remove(at: i)
        } else {
            if !keepZeroAmounts && element.amount == 0 { return }
            entries.append(element)
        }
    }

    mutating func add(_ resource: String, _ origin: String, _ amount: Int = 1) { add(ResourceSupply(resource: resource, origin: origin, amount: amount)) }

    /// `add(resourceSupplyList)`: row by row through `add`.
    mutating func add(_ list: ResourceSupplyList) { for e in list.entries { add(e) } }

    /// Kotlin `list += other` on an ArrayList: `addAll`, which appends the rows as they are - no merging.
    mutating func appendAll(_ list: ResourceSupplyList) { entries += list.entries }

    /// `subtractResourceRequirements`: each requirement as a negative row of `origin`; unknown resources skipped.
    mutating func subtractResourceRequirements(_ requirements: [(String, Int)], rs: Ruleset, origin: String) {
        for (name, amount) in requirements where rs.resources[name] != nil { add(name, origin, -amount) }
    }

    /// `addByResource`: every row re-filed under `newOrigin`.
    mutating func addByResource(_ fromList: ResourceSupplyList, _ newOrigin: String) {
        for e in fromList.entries { add(e.resource, newOrigin, e.amount) }
    }

    /// `addPositiveByResource`: the same, positive rows only.
    mutating func addPositiveByResource(_ fromList: ResourceSupplyList, _ newOrigin: String) {
        for e in fromList.entries where e.amount > 0 { add(e.resource, newOrigin, e.amount) }
    }

    /// `sumByResource(newOrigin)`: a new list aggregating every origin.
    func sumByResource(_ newOrigin: String) -> ResourceSupplyList {
        var out = ResourceSupplyList(keepZeroAmounts: keepZeroAmounts)
        out.addByResource(self, newOrigin)
        return out
    }

    /// `applyModifiers`: each row with a modifier becomes `(amount.toFloat() * modifier).toInt()`.
    mutating func applyModifiers(_ modifiers: [String: Float]) {
        guard !modifiers.isEmpty else { return }
        for i in entries.indices { if let m = modifiers[entries[i].resource] { entries[i].amount = Int(Float(entries[i].amount) * m) } }
    }

    mutating func removeAll(where predicate: (ResourceSupply) -> Bool) { entries.removeAll(where: predicate) }
}
