// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/city/CityStats.kt`. Method names, their order and their contents follow that
/// file so the two can be read side by side; where our value-type `GameState` forces a difference it is
/// marked DEVIATION with the reason.

/// Unciv StatTreeNode: a city's stats as a tree of named contributions, so the player can open a total
/// and see what made it.
final class StatTreeNode {
    private(set) var children: [String: StatTreeNode] = [:]
    private(set) var childOrder: [String] = []
    private var innerStats: Stats? = nil

    func setInnerStat(_ stat: String, _ value: Double) {
        if innerStats == nil { innerStats = Stats() }
        innerStats![stat] = value
    }

    private func addInnerStats(_ stats: Stats) {
        if innerStats == nil { innerStats = stats } else { innerStats! += stats }
    }

    func addStats(_ newStats: Stats?, _ hierarchyList: String...) { addStats(newStats, hierarchyList) }

    func addStats(_ newStats: Stats?, _ hierarchyList: [String]) {
        guard let newStats, !newStats.isEmpty else { return }
        guard let childName = hierarchyList.first else { addInnerStats(newStats); return }
        if children[childName] == nil { children[childName] = StatTreeNode(); childOrder.append(childName) }
        children[childName]!.addStats(newStats, Array(hierarchyList.dropFirst()))
    }

    func setChild(_ name: String, _ node: StatTreeNode) {
        if children[name] == nil { childOrder.append(name) }
        children[name] = node
    }

    func add(_ otherTree: StatTreeNode) {
        if let inner = otherTree.innerStats { addInnerStats(inner) }
        for key in otherTree.childOrder {
            guard let value = otherTree.children[key] else { continue }
            if children[key] == nil { children[key] = value; childOrder.append(key) }
            else { children[key]!.add(value) }
        }
    }

    var totalStats: Stats {
        var toReturn = Stats()
        if let inner = innerStats { toReturn += inner }
        for name in childOrder { if let c = children[name] { toReturn += c.totalStats } }
        return toReturn
    }
}

/// Unciv StatMap: named stat entries in insertion order.
struct StatMap {
    private(set) var order: [String] = []
    private(set) var dict: [String: Stats] = [:]

    subscript(key: String) -> Stats? {
        get { dict[key] }
        set {
            guard let newValue else { dict[key] = nil; order.removeAll { $0 == key }; return }
            if dict[key] == nil { order.append(key) }
            dict[key] = newValue
        }
    }
    /// Unciv StatMap.add: adds to the entry, creating it when it is not there yet.
    mutating func add(_ key: String, _ stats: Stats) {
        if dict[key] == nil { order.append(key); dict[key] = stats } else { dict[key]! += stats }
    }
    var values: [Stats] { order.compactMap { dict[$0] } }
    mutating func clear() { order = []; dict = [:] }
    mutating func mutateAll(_ body: (inout Stats) -> Void) {
        for key in order { if var s = dict[key] { body(&s); dict[key] = s } }
    }
}

/// Unciv CityStats(city): holds and calculates the stats of one city.
/// DEVIATION: Unciv's CityStats hangs off the City object and keeps its results; our `GameState` is a
/// value type recomputed on demand, so this is built per calculation and reads the state it was given.
final class CityStats {
    let city: City
    let state: GameState

    var baseStatTree = StatTreeNode()
    var statPercentBonusTree = StatTreeNode()
    var finalStatList = StatMap()
    var happinessList: [(String, Double)] = []
    var statsFromTiles = Stats()
    var currentCityStats = Stats()
    /// The food total after the percentages and before the citizens eat - what the old aggregate called
    /// `total.food`, and what `CivInfoStatsForNextTurn` needs to name its Population and Bonuses rows.
    var grossFood: Double = 0
    /// The worked tiles `updateTileStats` dropped because they were blockaded (Unciv drops them silently;
    /// we also keep the list so the city screen can say why a citizen moved).
    private(set) var blockadedWorkedTiles: [HexCoord] = []

    private let civ: Civilization
    private let uniques: [Unique]            // city.getMatchingUniques, already filtered by scope and conditionals
    private let ctx: GameState.UniqueContext

    init?(city: City, state: GameState) {
        guard let civ = state.civ(city.civId) else { return nil }
        self.city = city
        self.state = state
        self.civ = civ
        let ctx = GameState.UniqueContext(civId: city.civId, city: city)
        self.ctx = ctx
        // Unciv city.getMatchingUniques / forEachMatchingUnique: civ.getMatchingUniques FIRST - which includes
        // civResourcesUniqueMap, the uniques of every resource the civ holds (G&K: Marble's "+15% Production when
        // constructing wonders") - and the city's local ones (its buildings' "in this city", its religion) AFTER.
        // The order is the order the percentages and the food-consumption factors are summed and multiplied in,
        // in Float, and the order of the stat tree's rows.
        let civLevel = state.civUniques(city.civId).filter { !$0.isLocalEffect } + state.heldResourceUniques(city.civId)
        self.uniques = (civLevel + state.cityLocalUniques(city)).filter { state.scopeIncludes($0, city: city) && state.conditionalsHold($0, ctx) }
    }

    /// `matching` is called twenty-two times per update, and it used to scan the whole unique list each time.
    /// The list is grouped by pattern once, in init, which turns every one of those scans into a lookup.
    private lazy var byPattern: [String: [Unique]] = Dictionary(grouping: uniques, by: { $0.pattern })
    private func matching(_ patterns: String...) -> [Unique] {
        if patterns.count == 1 { return byPattern[patterns[0]] ?? [] }
        var out: [Unique] = []
        for u in uniques where patterns.contains(u.pattern) { out.append(u) }   // order preserved across patterns
        return out
    }
    private func matchesFilter(_ filter: String) -> Bool { state.cityMatchesFilter(filter, city: city, viewer: city.civId) }

    // MARK: - Pure Functions

    /// Unciv's ConstructionAutomation prices a building on a CLONE whose `setTransients` has broken the city
    /// connection - its own todo says so: "breaks city connection; trade route gold is currently not
    /// considered for markets etc." So a building is valued there against a city with no trade route at all,
    /// on both sides of the difference. Ours kept the connection, which values anything touching gold
    /// differently. This is that clone boundary.
    var countsTradeRoutes = true

    /// Unciv getStatsFromTradeRoute
    private func getStatsFromTradeRoute() -> Stats { countsTradeRoutes ? state.cityTradeRouteStats(city) : Stats() }

    /// Unciv getStatsFromProduction: the stat a "Produce [Gold]" style construction converts production into.
    private func getStatsFromProduction(_ production: Double) -> Stats? {
        guard city.currentProduction == nil, !city.convertProductionTo.isEmpty,
              state.productionConversions(for: city.civId).contains(city.convertProductionTo) else { return nil }
        var stats = Stats()
        stats[city.convertProductionTo] = production * getStatConversionRate(city.convertProductionTo)
        return stats
    }

    /// Unciv getStatConversionRate: a quarter, times any ProductionToStatConversionBonus.
    func getStatConversionRate(_ stat: String) -> Double { state.statConversionRate(city.civId, stat) }

    /// Unciv getStatPercentBonusesFromRailroad
    private func getStatPercentBonusesFromRailroad() -> Stats? {
        guard let railroad = state.rs.improvements["Railroad"] else { return nil }   // for mods
        let techEnabling = railroad.techRequired
        if (techEnabling == nil || civ.techs.contains(techEnabling!))
            // the construction automation's clone is not in citiesConnectedToCapitalToMediums either (see countsTradeRoutes)
            && (city.isCapital || (countsTradeRoutes && isConnectedToCapital(.railroad))) {
            return Stats(production: 25)
        }
        return nil
    }

    /// Unciv getStatPercentBonusesFromPuppetCity
    private func getStatPercentBonusesFromPuppetCity() -> Stats? {
        guard city.isPuppet else { return nil }
        return Stats(science: -25, culture: -25)
    }

    /// Unciv getGrowthBonus: "[amount]% growth [cityFilter]", by source.
    func getGrowthBonus(_ totalFood: Double) -> StatMap {
        var growthSources = StatMap()
        let vpGrowth = state.vpGrowthModifiers(city.civId)   // VP: supply and approval growth penalties (VP/VPSupply.swift)
        for unique in matching("[]% growth []", "[]% growth") {
            if unique.pattern == "[]% growth []" && !matchesFilter(unique.param(1)) { continue }
            if vpGrowth != nil && unique.conditionals.contains(where: { $0.params.contains("Happiness") }) { continue }   // VP's own approval penalty replaces these
            // Unciv: `Stats(food = unique.params[0].toFloat() / 100f * totalFood)` - Float throughout.
            growthSources.add(unique.sourceNameForUser, Stats(food: Stats.f32(Stats.f32(Stats.f32(unique.double(0)) / 100) * totalFood)))
        }
        for (k, pct) in vpGrowth ?? [] { growthSources.add(k, Stats(food: Stats.f32(Stats.f32(pct / 100) * totalFood))) }
        return growthSources
    }

    /// Unciv hasExtraAnnexUnhappiness
    func hasExtraAnnexUnhappiness() -> Bool {
        if city.originalOwner == city.civId || city.isPuppet { return false }
        return !city.buildings.contains { state.rs.buildings[$0]?.uniques.contains("Removes extra unhappiness from annexed cities") == true }
    }

    /// Unciv getStatsOfSpecialist
    func getStatsOfSpecialist(_ specialistName: String) -> Stats {
        guard let specialist = state.rs.specialists[specialistName] else { return Stats() }
        var stats = specialist.stats
        for unique in matching("[] from every specialist []", "[] from every specialist") {
            if unique.pattern == "[] from every specialist" || matchesFilter(unique.param(1)) { stats += unique.stats ?? Stats() }
        }
        for unique in matching("[] from every []") where unique.param(1) == specialistName {
            stats += unique.stats ?? Stats()
        }
        return stats
    }

    /// Unciv getStatsFromSpecialists
    private func getStatsFromSpecialists(_ specialists: [String: Int]) -> Stats {
        var stats = Stats()
        for (key, value) in specialists.sorted(by: { $0.key < $1.key }) where value > 0 {
            stats += getStatsOfSpecialist(key) * Double(value)
        }
        return stats
    }

    /// Unciv getStatsFromUniquesBySource
    private func getStatsFromUniquesBySource() -> StatTreeNode {
        let sourceToStats = StatTreeNode()

        // Unciv `city.civ.getMatchingUniques(BonusStatsFromCityStates)`: "[x]% [stat] from City-States" scales a
        // city-state's bonus, `stats[stat] *= params[0].toPercent()` in Float, when the unique's source is a city-state
        let civCtx = GameState.UniqueContext(civId: city.civId)
        let cityStateStatsMultipliers = state.civUniques(city.civId).filter { $0.pattern == "[]% [] from City-States" && state.conditionalsHold($0, civCtx) }
        func addUniqueStats(_ unique: Unique) {
            guard var stats = unique.stats else { return }
            if unique.sourceObjectType == .cityState {
                for m in cityStateStatsMultipliers { stats[m.param(1)] = Double(Float(stats[m.param(1)]) * (1 + Float(m.double(0)) / 100)) }
            }
            sourceToStats.addStats(stats, unique.sourceNameForUser, unique.sourceObjectName ?? "")
        }

        // "[stats] [cityFilter]" / a building's own "[stats]"
        for unique in matching("[] []") where matchesFilter(unique.param(1)) { addUniqueStats(unique) }
        // Unciv keeps a bare "[stats]" OUT of getStatsFromUniquesBySource: a building's own is added in
        // Building.getStats, and anything else the empire holds - a city-state's friendship bonus, a policy,
        // a nation trait - is a civ-level row in getGlobalStatsFromUniques and reaches no city at all.
        // Allowing it in the capital is the bug the live path already measured and removed: a Cultured
        // city-state's "[+3 Culture]" was paid into Paris's culture and, through it, into its border growth.
        for unique in matching("[]") where unique.params.count == 1 && (unique.sourceObjectType == .building || unique.sourceObjectType == .wonder) {
            addUniqueStats(unique)
        }

        // "[stats] per [amount] population [cityFilter]"
        for unique in matching("[] per [] population []", "[] per [] population") {
            if unique.pattern == "[] per [] population []" && !matchesFilter(unique.param(2)) { continue }
            let amountOfEffects = Double(city.population / max(1, unique.int(1)))
            sourceToStats.addStats((unique.stats ?? Stats()) * amountOfEffects, unique.sourceNameForUser, unique.sourceObjectName ?? "")
        }

        // "[stats] in cities on [terrainFilter] tiles"
        for unique in matching("[] in cities on [] tiles") {
            if let centre = state.map[city.coord], state.tileMatches(centre, unique.param(1), civId: city.civId) { addUniqueStats(unique) }
        }

        return sourceToStats
    }

    /// Unciv getStatPercentBonusesFromGoldenAge
    private func getStatPercentBonusesFromGoldenAge(_ isGoldenAge: Bool) -> Stats? {
        guard isGoldenAge else { return nil }
        return Stats(production: 20, culture: 20)
    }

    /// Unciv getStatsPercentBonusesFromUniquesBySource
    private func getStatsPercentBonusesFromUniquesBySource(_ currentConstruction: Production?) -> StatTreeNode {
        let sourceToStats = StatTreeNode()

        func addUniqueStats(_ unique: Unique, _ stat: String, _ amount: Double) {
            var stats = Stats()
            stats[stat] = amount
            sourceToStats.addStats(stats, unique.sourceNameForUser, unique.sourceObjectName ?? "")
        }

        for unique in matching("[]% []") { addUniqueStats(unique, unique.param(1), unique.double(0)) }
        for unique in matching("[]% [] []") where matchesFilter(unique.param(2)) {
            addUniqueStats(unique, unique.param(1), unique.double(0))
        }

        // Unciv picks one of PercentProductionUnits / Buildings / Wonders by what is being built, then
        // checks the construction filter and the city filter of each.
        if let p = currentConstruction {
            let uniquesToCheck: [Unique]
            switch p {
            case .unit:
                uniquesToCheck = matching("[]% Production when constructing [] units []", "[]% Production when constructing [] units")
            case .building(let name):
                let isWonder = state.rs.buildings[name]?.isAnyWonder == true
                uniquesToCheck = isWonder
                    ? matching("[]% Production when constructing [] wonders []", "[]% Production when constructing [] wonders")
                    : matching("[]% Production when constructing [] buildings []", "[]% Production when constructing [] buildings")
            }
            for unique in uniquesToCheck {
                let filter = unique.param(1)
                let cityFilter = unique.params.count > 2 ? unique.param(2) : "in all cities"
                let filterOK = filter == "All" || filter == "all" || constructionMatchesFilter(p, filter)
                if filterOK && matchesFilter(cityFilter) { addUniqueStats(unique, "Production", unique.double(0)) }
            }
            // "[amount]% Production when constructing [filter]" with no category word
            for unique in matching("[]% Production when constructing []", "[]% Production when constructing [] []") {
                let cityFilter = unique.params.count > 2 ? unique.param(2) : "in all cities"
                if constructionMatchesFilter(p, unique.param(1)) && matchesFilter(cityFilter) {
                    addUniqueStats(unique, "Production", unique.double(0))
                }
            }
        }

        // "[amount]% [stat] from every follower, up to [amount]%"
        for unique in matching("[]% [] from every follower, up to []%") {
            let followerCount = Double(state.majorityReligion(of: city).flatMap { state.followers(of: city)[$0] } ?? 0)
            addUniqueStats(unique, unique.param(1), min(unique.double(0) * followerCount, unique.double(2)))
        }

        // Unciv PercentProductionBuildingsInCapital
        if case .building(let name)? = currentConstruction, let cap = state.capital(of: city.civId),
           cap.buildings.contains(name) {   // Unciv does not exclude the capital itself
            for unique in matching("[]% Production towards any buildings that already exist in the Capital") {
                addUniqueStats(unique, "Production", unique.double(0))
            }
        }

        return sourceToStats
    }

    /// Unciv getStatPercentBonusesFromUnitSupply
    private func getStatPercentBonusesFromUnitSupply() -> Stats? {
        guard state.unitSupplyDeficit(city.civId) > 0 else { return nil }
        return Stats(production: -state.unitSupplyProductionPenalty(city.civId))
    }

    /// Unciv constructionMatchesFilter
    private func constructionMatchesFilter(_ construction: Production, _ filter: String) -> Bool {
        state.productionMatches(construction, filter)
    }

    /// Unciv CityStats.isConnectedToCapital
    enum RoadStatus { case none, road, railroad }
    func isConnectedToCapital(_ roadType: RoadStatus) -> Bool {
        if state.cities(of: city.civId).count < 2 { return false }   // first city!
        if roadType == .railroad { return state.railroadConnectedCityIds(city.civId).contains(city.id) }
        return city.connectedToCapital
    }

    /// Unciv getBuildingMaintenanceCosts
    /// The struct keeps maintenance in its own field, so the live path needs this value out of the mirror.
    var buildingMaintenanceCosts: Double { getBuildingMaintenanceCosts() }

    /// Unciv CityStats.getBuildingMaintenanceCosts → CityConstructions.getMaintenanceCosts, in Float: each building's
    /// maintenance times every matching "[x]% maintenance cost for [filter] buildings [cityFilter]" (toPercent), summed;
    /// then, for an AI, times the GAME difficulty's aiBuildingMaintenanceModifier (`gameInfo.getDifficulty()`, not
    /// the AI's own Chieftain level).
    private func getBuildingMaintenanceCosts() -> Double {
        var buildingsMaintenance: Float = 0
        let maintenanceUniques = matching("[]% maintenance cost for [] buildings []")
        let freeBuildings = state.freeBuildingNames(city)   // Unciv `city.civ.civConstructions.getFreeBuildingNames(city)`
        // Unciv sums in getBuiltBuildings() order, as Floats. The live city keeps its buildings in the set's order as the
        // last load or Next Turn left them (reapplyJavaHashSetOrders), then in the order they were added;
        // ConstructionAutomation's `city.clone()` rebuilds them from the builtBuildings HashSet<String>, so a
        // hypothetical city sums them in the set's hash order - and 34.000004 vs 33.999996 truncates to a different
        // Maintenance row (Cuzco's Temple was worth one gold more upkeep in Unciv's eyes, and it built a Temple).
        let order = appliesSideEffects ? city.builtBuildingObjects : javaHashMapOrder(city.buildings)
        for b in order {
            guard let def = state.rs.buildings[b], !freeBuildings.contains(b) else { continue }
            var forThisBuilding = Float(def.maintenance)
            for u in maintenanceUniques where u.param(1).lowercased() == "all" || state.productionMatches(.building(b), u.param(1)) {
                forThisBuilding *= Float(Stats.toPercent(u.double(0)))
            }
            buildingsMaintenance += forThisBuilding
        }
        if !civ.isPlayer { buildingsMaintenance *= Float(state.difficulty.aiBuildingMaintenanceModifier) }
        return Double(buildingsMaintenance)
    }

    // MARK: - State-Changing Methods

    /// Unciv updateTileStats
    /// Unciv's `updateTileStats` takes a blockaded worked tile off the city as it goes, and
    /// ConstructionAutomation is safe from that only because it updates a CLONE of the city
    /// (`getStatDifferenceFromBuilding`: `city.clone()`, then `newCity.cityStats.update(...)`). Ours is handed
    /// a copy of the City struct but writes through its id, so a hypothetical "what if this building existed"
    /// would stop the REAL city working a tile. `appliesSideEffects` is that clone boundary.
    var appliesSideEffects = true

    /// Unciv `cityConstructions.getBuiltBuildings()`: the live city's ArrayList, a second copy included; a clone's is
    /// rebuilt from the builtBuildings names by setTransients, so it holds none.
    private var builtBuildings: [String] { appliesSideEffects ? city.builtBuildingObjects : city.buildings }

    func updateTileStats() {
        var stats = Stats()
        var blockaded: [HexCoord] = []
        let worked = ([city.coord] + city.workedTiles).compactMap { state.map[$0] }
        for tile in worked {
            if tile.coord != city.coord && state.isBlockaded(tile.coord, for: city.civId) && city.workedTiles.contains(tile.coord) {
                // Unciv updateTileStats: city.stopWorkingTile(tile); city.shouldReassignPopulation = true
                blockaded.append(tile.coord)
                if appliesSideEffects {
                    state.stopWorkingTile(cityId: city.id, tile.coord)
                    if let ci = state.cityIndex(city.id) { state.cities[ci].shouldReassignPopulation = true }
                }
                continue
            }
            stats += state.tileStats(tile, civId: city.civId, city: city)
        }
        for tile in state.unassignedYieldTiles(city) { stats += state.tileStats(tile, civId: city.civId, city: city) }
        statsFromTiles = stats
        blockadedWorkedTiles = blockaded
    }

    /// Unciv updateCityHappiness
    func updateCityHappiness(_ statsFromBuildings: StatTreeNode, _ statsFromSpecialists: Stats, _ statsFromUniquesBySource: StatTreeNode) {
        var newHappinessList: [(String, Double)] = []
        func set(_ key: String, _ value: Double) {
            if let i = newHappinessList.firstIndex(where: { $0.0 == key }) { newHappinessList[i].1 = value }
            else { newHappinessList.append((key, value)) }
        }

        // Unciv: both modifiers are Float fields and the product is taken in Float
        var unhappinessModifierF = Float(state.difficulty(for: city.civId).unhappinessModifier)
        if !civ.isPlayer { unhappinessModifierF *= Float(state.difficulty.aiUnhappinessModifier) }
        let unhappinessModifier = Double(unhappinessModifierF)

        // VP: needs-based unhappiness replaces the per-city and per-citizen rows (VP/VPNeeds.swift)
        if let vp = state.vpCityUnhappiness(city) {
            for (k, v) in vp.rows { set(k, -Double(v)) }
        } else {
            var unhappinessFromCity = -3.0   // -3 happiness per city
            if hasExtraAnnexUnhappiness() { unhappinessFromCity -= 2 }

            var uniqueUnhappinessModifier = 0.0
            for unique in state.civUniques(city.civId) where unique.pattern == "[]% unhappiness from the number of cities" {
                uniqueUnhappinessModifier += unique.double(0)
            }
            // Unciv: `unhappinessFromCity * unhappinessModifier * uniqueUnhappinessModifier.toPercent()`, Float.
            set("Cities", Stats.f32(Stats.f32(unhappinessFromCity * unhappinessModifier) * Stats.toPercent(uniqueUnhappinessModifier)))

            var unhappinessFromCitizens = Double(city.population)
            // Unciv UnhappinessFromPopulationTypePercentageChange is "[relativeAmount]% Unhappiness from
            // [populationFilter] [cityFilter]" - capital U, as all eight uses in the rulesets are. We looked for a
            // lowercase "unhappiness", which matched nothing: Meritocracy's "-5% Unhappiness from [Population]" never
            // reached a city's happiness list. The empire's live breakdown spelled it right, so the live path hid it.
            for unique in matching("[]% Unhappiness from [] []") where matchesFilter(unique.param(2)) {
                unhappinessFromCitizens = Stats.f32(unhappinessFromCitizens + Stats.f32(Stats.f32(unique.double(0) / 100) * Double(state.populationFilterAmount(city, unique.param(1)))))
            }
            if hasExtraAnnexUnhappiness() { unhappinessFromCitizens = Stats.f32(unhappinessFromCitizens * 2) }
            if unhappinessFromCitizens < 0 { unhappinessFromCitizens = 0 }
            set("Population", Stats.f32(-unhappinessFromCitizens * unhappinessModifier))

            if hasExtraAnnexUnhappiness() { set("Occupied City", -2) }
        }

        let happinessFromSpecialists = statsFromSpecialists.happiness.rounded(.towardZero)
        if happinessFromSpecialists > 0 { set("Specialists", happinessFromSpecialists) }

        set("Buildings", statsFromBuildings.totalStats.happiness.rounded(.towardZero))
        set("Tile yields", statsFromTiles.happiness)

        // Unciv updateCityHappiness ends by folding every unique SOURCE with non-zero happiness into the list
        // under its own name - "Policies", "Natural Wonders", a wonder's name - on top of the six fixed rows.
        // ONE loop. We had two of them, both adding the same `totalStats.happiness` to the same key.
        for key in statsFromUniquesBySource.childOrder {
            guard let node = statsFromUniquesBySource.children[key] else { continue }
            let happy = node.totalStats.happiness
            guard happy != 0 else { continue }
            if let i = newHappinessList.firstIndex(where: { $0.0 == key }) { newHappinessList[i].1 += happy }
            else { newHappinessList.append((key, happy)) }
        }
        happinessList = newHappinessList
    }

    /// Unciv updateBaseStatList
    private func updateBaseStatList(_ statsFromBuildings: StatTreeNode, _ statsFromSpecialists: Stats, _ statsFromUniquesBySource: StatTreeNode) {
        let newBaseStatTree = StatTreeNode()
        var newBaseStatList = StatMap()

        let specialistCount = city.specialists.values.reduce(0, +)
        // Unciv getFreePopulation() runs after updateTileStats has stopped working any blockaded tile, so that
        // citizen is free here and yields its 1 production. Our `city` is the copy taken before, hence the subtraction.
        let stillWorked = city.workedTiles.filter { !blockadedWorkedTiles.contains($0) }.count
        newBaseStatTree.addStats(Stats(production: Double(max(0, city.population - stillWorked - specialistCount)),
                                       science: Double(city.population)), "Population")
        newBaseStatList["Tile yields"] = statsFromTiles
        newBaseStatList["Specialists"] = statsFromSpecialists
        newBaseStatList["Trade routes"] = getStatsFromTradeRoute()
        newBaseStatTree.setChild("Buildings", statsFromBuildings)

        for source in newBaseStatList.order { newBaseStatTree.addStats(newBaseStatList[source], source) }
        newBaseStatTree.add(statsFromUniquesBySource)
        baseStatTree = newBaseStatTree
    }

    /// Unciv getStatPercentBonusList
    private func getStatPercentBonusList(_ currentConstruction: Production?) -> StatTreeNode {
        let newStatsBonusTree = StatTreeNode()
        newStatsBonusTree.addStats(getStatPercentBonusesFromGoldenAge(civ.isInGoldenAge), "Golden Age")
        newStatsBonusTree.addStats(getStatPercentBonusesFromRailroad(), "Railroad")
        newStatsBonusTree.addStats(getStatPercentBonusesFromPuppetCity(), "Puppet City")
        newStatsBonusTree.addStats(getStatPercentBonusesFromUnitSupply(), "Unit Supply")
        newStatsBonusTree.addStats(state.vpMonopolyCityPercent(city.civId), "Monopolies")   // VP: VP/VPMonopolies.swift
        newStatsBonusTree.add(getStatsPercentBonusesFromUniquesBySource(currentConstruction))
        // Unciv Building.getStatPercentageBonuses: the building's own percentStatBonus PLUS the city's
        // "[amount]% [stat] from every [buildingFilter]" for the buildings that match it.
        let percentFromObject = matching("[]% [] from every []", "[]% Yield from every []")
        for b in builtBuildings {
            guard let def = state.rs.buildings[b] else { continue }
            var bonus = def.percentStatBonus
            for u in percentFromObject where state.productionMatches(.building(b), u.param(2)) {
                if u.pattern == "[]% Yield from every []" { continue }   // Unciv: that one is a tile-yield unique
                bonus[u.param(1)] += u.double(0)
            }
            newStatsBonusTree.addStats(bonus, "Buildings", b)
        }
        return newStatsBonusTree
    }

    /// Unciv update
    /// `updateTileStats` is Unciv's own parameter. Its `updateTileStats()` writes ONLY `statsFromTiles` (and
    /// drops a blockaded worked tile on the way), so passing false means "take the tiles as they already are".
    /// `CityConstructions.productionForConstruction` is the caller that needs it: it hands a fresh CityStats
    /// the city's current `statsFromTiles` and never walks the tiles again.
    /// Unciv GameInfo.updateCivilizationState's first city loop: `city.cityStats.updateTileStats()` and then
    /// `updateCityHappiness(city.cityConstructions.getStats())`, its specialists and uniques by default.
    func updateTileStatsAndHappiness() {
        updateTileStats()
        updateCityHappiness(getStatsFromBuildings(), getStatsFromSpecialists(city.specialists), getStatsFromUniquesBySource())
    }

    func update(currentConstruction: Production? = nil, calculateGrowthModifiers: Bool = true, updateTileStats doUpdateTileStats: Bool = true) {
        if doUpdateTileStats { updateTileStats() }
        // We need to compute Tile yields before happiness
        let statsFromBuildings = getStatsFromBuildings()
        let statsFromSpecialists = getStatsFromSpecialists(city.specialists)
        let statsFromUniquesBySource = getStatsFromUniquesBySource()
        updateBaseStatList(statsFromBuildings, statsFromSpecialists, statsFromUniquesBySource)
        updateCityHappiness(statsFromBuildings, statsFromSpecialists, statsFromUniquesBySource)
        statPercentBonusTree = getStatPercentBonusList(currentConstruction)
        updateFinalStatList(currentConstruction, calculateGrowthModifiers)

        // Unciv `for (stat in finalStatList.values) newCurrentCityStats.add(stat)` - a Float accumulation,
        // one entry at a time, and the order of the entries is the order they were filed in.
        var newCurrentCityStats = Stats()
        for stat in finalStatList.values { newCurrentCityStats = (newCurrentCityStats + stat).f32 }
        currentCityStats = newCurrentCityStats
    }

    /// Unciv CityConstructions.getStats: `stats.addStats(building.getStats(city), building.name)`.
    /// `Building.getStats` is NOT just the building's line in the json: it also collects the city's
    /// "[stats] from every [buildingFilter]" for the buildings that match, and - for anything that is not a
    /// wonder - "[stats] from all [buildingFilter] buildings". Reading only `def.stats` is most of the gap the
    /// `cityStatsMirror` self-test reports: Addis Ababa's gold read 3 against the live path's 11.
    /// The building's own plain "[stats]" uniques are NOT added here; `getStatsFromUniquesBySource` already
    /// files those under the same source, and adding them twice is a double count.
    /// Unciv Building.getStats(city) for one building (CityView.getBuildingStats, shown in the city's building list)
    func buildingStats(_ b: String) -> Stats {
        guard let def = state.rs.buildings[b] else { return Stats() }
        var stats = def.stats
        for u in matching("[] from every []") where state.productionMatches(.building(b), u.param(1)) { if let st = u.stats { stats += st } }
        if !def.isWonder { for u in matching("[] from all [] buildings") where state.productionMatches(.building(b), u.param(1)) { if let st = u.stats { stats += st } } }
        return stats
    }

    private func getStatsFromBuildings() -> StatTreeNode {
        let node = StatTreeNode()
        let fromObject = matching("[] from every []")
        let fromBuildings = matching("[] from all [] buildings")
        for b in builtBuildings {
            guard let def = state.rs.buildings[b] else { continue }
            var stats = def.stats
            for u in fromObject where state.productionMatches(.building(b), u.param(1)) {
                if let st = u.stats { stats += st }
            }
            // Unciv Building.getStats: `if (!isWonder)` - only a WORLD wonder is left out; the Palace, the National
            // College and Oxford take Sovereignty's "[+1 Gold] from all [Science] buildings" like any Library.
            if !def.isWonder {
                for u in fromBuildings where state.productionMatches(.building(b), u.param(1)) {
                    if let st = u.stats { stats += st }
                }
            }
            node.addStats(stats, b)
        }
        return node
    }

    /// Kotlin's `List<Float>.sum()` accumulates in Float (`var sum = 0.0f; for (e in this) sum += e`), while
    /// its `sumOf { it.toDouble() }` accumulates in Double. `updateFinalStatList` uses BOTH, and which one it
    /// uses where decides the answer: measured on `fresh` turn 61, Persepolis' food entries sum to exactly
    /// 6.0 in Float and to 6.000000238 in Double, so the -75% growth penalty is -4.5 against -4.5000002 and
    /// the city banks 2 food against 1.
    /// Unciv's NullifiesStat and NullifiesGrowth entries: `sumOf { it[stat].toDouble() }` - a Double sum - then
    /// `Stats(... = -amount.toFloat())`. Kept as the Double, the entry did not cancel the Float sum it is added to: the
    /// city read 2.98e-8 food where Unciv reads 0 (a state comparison, a test game, turn 64, Agra at -13 happiness).
    static func uncivNegatedSum(_ values: [Double]) -> Double { -Double(Float(values.reduce(0.0, +))) }

    private static func sumF(_ values: [Stats], _ get: (Stats) -> Double) -> Double {
        var sum = 0.0
        for v in values { sum = Stats.f32(sum + get(v)) }
        return sum
    }

    /// Unciv updateFinalStatList
    private func updateFinalStatList(_ currentConstruction: Production?, _ calculateGrowthModifiers: Bool) {
        var newFinalStatList = StatMap()

        for key in baseStatTree.childOrder {
            if let value = baseStatTree.children[key] { newFinalStatList[key] = value.totalStats }
        }

        let statPercentBonusesSum = statPercentBonusTree.totalStats

        // Unciv multiplies each ENTRY by the percentage, in Float, and only sums at the end.
        let prodPercent = Stats.toPercent(statPercentBonusesSum.production)
        newFinalStatList.mutateAll { $0.production = Stats.f32($0.production * prodPercent) }

        // We only add the 'extra stats from production' AFTER we calculate the production INCLUDING BONUSES
        let statsFromProduction = getStatsFromProduction(CityStats.sumF(newFinalStatList.values) { $0.production })
        if let statsFromProduction, !statsFromProduction.isEmpty {
            baseStatTree.addStats(statsFromProduction, "Production")
            newFinalStatList["Construction"] = statsFromProduction
        }

        let goldPercent = Stats.toPercent(statPercentBonusesSum.gold)
        let culturePercent = Stats.toPercent(statPercentBonusesSum.culture)
        let foodPercent = Stats.toPercent(statPercentBonusesSum.food)
        let faithPercent = Stats.toPercent(statPercentBonusesSum.faith)
        newFinalStatList.mutateAll {
            $0.gold = Stats.f32($0.gold * goldPercent)
            $0.culture = Stats.f32($0.culture * culturePercent)
            $0.food = Stats.f32($0.food * foodPercent)
            $0.faith = Stats.f32($0.faith * faithPercent)
        }

        // AFTER we've gotten all the gold stats figured out, only THEN do we plonk that gold into Science
        if state.rs.modOptionUniques.contains(where: { $0.pattern == "Can convert gold to science with sliders" }) {
            let amountConverted = (newFinalStatList.values.reduce(0) { $0 + $1.gold } * civ.goldPercentConvertedToScience).rounded(.towardZero)
            if amountConverted > 0 { newFinalStatList["Gold -> Science"] = Stats(gold: -amountConverted, science: amountConverted) }
        }
        let sciencePercent = Stats.toPercent(statPercentBonusesSum.science)
        newFinalStatList.mutateAll { $0.science = Stats.f32($0.science * sciencePercent) }

        for unique in matching("Nullifies [] []") where matchesFilter(unique.param(1)) {
            let stat = unique.param(0)
            var s = Stats(); s[stat] = CityStats.uncivNegatedSum(newFinalStatList.values.map { $0[stat] })
            newFinalStatList.add(unique.sourceNameForUser, s)
        }

        /* Food: produced, then bonuses, then food eaten, and only the excess gets growth modifiers. */
        // The empire's stat map reads the GROSS food back out of the city (its "Population" row is
        // surplus - gross, its "Bonuses" row is gross - base), so the value has to be kept at the one moment
        // it exists: after the percentages and before anything is eaten.
        grossFood = CityStats.sumF(newFinalStatList.values) { $0.food }
        let foodEaten = calcFoodEaten()
        if var pop = newFinalStatList["Population"] { pop.food -= foodEaten; newFinalStatList["Population"] = pop }
        else { newFinalStatList["Population"] = Stats(food: -foodEaten) }

        var totalFood = CityStats.sumF(newFinalStatList.values) { $0.food }

        if totalFood > 0 && calculateGrowthModifiers {
            let growthBonuses = getGrowthBonus(totalFood)
            for key in growthBonuses.order {
                newFinalStatList.add("[\(key)] ([Growth])", growthBonuses[key] ?? Stats())
            }
            if city.isCelebrating && state.happiness(of: city.civId) >= 0 {
                newFinalStatList.add("We Love The King Day", Stats(food: Stats.f32(totalFood / 4)))
            }
            totalFood = CityStats.sumF(newFinalStatList.values) { $0.food }
        }

        let buildingsMaintenance = getBuildingMaintenanceCosts()
        newFinalStatList["Maintenance"] = Stats(gold: -buildingsMaintenance.rounded(.towardZero))

        if canConvertFoodToProduction(totalFood, currentConstruction) {
            newFinalStatList["Excess food to production"] = Stats(food: -totalFood, production: getProductionFromExcessiveFood(totalFood))
        }

        if let growthNullifying = matching("Nullifies Growth []", "Nullifies Growth").first {
            let currentGrowth = newFinalStatList.values.reduce(0) { $0 + $1.food }
            if currentGrowth > 0 { newFinalStatList.add(growthNullifying.sourceNameForUser, Stats(food: CityStats.uncivNegatedSum(newFinalStatList.values.map { $0.food }))) }
        }

        // Unciv: `if (city.isInResistance()) newFinalStatList.clear() // NOPE` - the food it would have grown
        // goes too; grossFood was read before the clear, so a resisting city still counted its whole harvest
        // when a building was weighed against it (settled turn 146: Adrianople's Granary 11.88 against 0).
        if city.resistanceTurns > 0 { newFinalStatList.clear(); grossFood = 0 }

        if CityStats.sumF(newFinalStatList.values, { $0.production }) < 1 {
            newFinalStatList["Production"] = Stats(production: 1)   // Minimum production for things to progress
        }
        finalStatList = newFinalStatList
    }

    /// Unciv canConvertFoodToProduction
    func canConvertFoodToProduction(_ food: Double, _ currentConstruction: Production?) -> Bool {
        guard food > 0, let p = currentConstruction else { return false }
        switch p {
        case .unit(let n): return state.rs.units[n]?.excessFoodToProduction == true
        case .building(let b): return state.rs.buildings[b]?.uniques.contains("Excess Food converted to Production when under construction") == true
        }
    }

    /// Unciv getProductionFromExcessiveFood
    func getProductionFromExcessiveFood(_ food: Double) -> Double {
        if food >= 4 { return 2 + (food / 4).rounded(.towardZero) }
        if food >= 2 { return 2 }
        if food >= 1 { return 1 }
        return 0
    }

    /// Unciv calcFoodEaten
    private func calcFoodEaten() -> Double { state.foodEaten(city, uniques: uniques) }

    /// Unciv CityStats.calcFoodEaten
}

extension GameState {
    /// Unciv City.getStatsOfSpecialist: the ruleset value plus the city's own "from every specialist" bonuses,
    /// which is what a specialist is really worth there - Secularism, Korea's ability, the Statue of Liberty.
    func specialistStats(_ name: String, in city: City) -> Stats {
        guard let sp = rs.specialists[name] else { return Stats() }
        var stats = sp.stats
        let ctx = UniqueContext(civId: city.civId, city: city)
        for u in cityUniques(city) where conditionalsHold(u, ctx) {
            switch u.pattern {
            case "[] from every specialist []":
                if cityMatchesFilter(u.param(1), city: city, viewer: city.civId) { stats += u.stats ?? Stats() }
            case "[] from every specialist": stats += u.stats ?? Stats()
            case "[] from every []":
                if u.param(1) == name { stats += u.stats ?? Stats() }
            default: break
            }
        }
        return stats
    }

    func foodEaten(_ city: City, uniques: [Unique]) -> Double {
        let specialists = city.specialists.values.reduce(0, +)
        var bySpecialists = 2.0 * Double(specialists)
        var eaten = Double(city.population) * 2 - bySpecialists
        // Unciv `toPercent()` is `1 + value / 100f`, and the whole of calcFoodEaten is Float.
        for u in uniques where u.pattern == "[]% Food consumption by specialists []" { bySpecialists = Stats.f32(bySpecialists * Stats.toPercent(u.double(0))) }
        eaten = Stats.f32(eaten + bySpecialists)
        for u in uniques where u.pattern == "[]% Food consumption by [] []" {
            let n: Int
            switch u.param(1) {
            case "Specialists": n = specialists
            case "Population": n = city.population
            case "Followers of the Majority Religion", "Followers of this Religion": n = majorityReligion(of: city).flatMap { followers(of: city)[$0] } ?? 0
            case "Unemployed": n = max(0, city.population - city.workedTiles.count - specialists)
            default: n = city.specialists[u.param(1)] ?? 0
            }
            eaten = Stats.f32(eaten - Stats.f32(Stats.f32(2 * Double(n)) * Stats.f32(1 - Stats.toPercent(u.double(0)))))
        }
        return eaten
    }

    /// Unciv CityStats.getStatsFromTradeRoute: capital population × 0.15 + city population × 1.1 − 1 gold, "[stats] from each Trade Route", then the percentages
    func cityTradeRouteStats(_ city: City) -> Stats {
        guard !city.isCapital, city.connectedToCapital, let cap = cities(of: city.civId).first(where: { $0.isCapital }) else { return Stats() }
        // Unciv: `capital.population * 0.15f + city.population * 1.1f - 1`, Float left to right.
        var st = Stats(gold: Stats.f32(Stats.f32(Stats.f32(Double(cap.population) * Stats.f32(0.15)) + Stats.f32(Double(city.population) * Stats.f32(1.1))) - 1))
        let ctx = UniqueContext(civId: city.civId, city: city)
        let us = cityUniques(city).filter { ($0.pattern == "[] from each Trade Route" || $0.pattern == "[]% [] from Trade Routes") && conditionalsHold($0, ctx) }
        for u in us where u.pattern == "[] from each Trade Route" { if let s2 = u.stats { st += s2 } }
        var pct = Stats()
        for u in us where u.pattern == "[]% [] from Trade Routes" {
            switch u.param(1) { case "Food": pct.food += u.double(0); case "Production": pct.production += u.double(0); case "Gold": pct.gold += u.double(0); case "Science": pct.science += u.double(0); case "Culture": pct.culture += u.double(0); case "Faith": pct.faith += u.double(0); default: break }
        }
        st.food = Stats.f32(st.food * Stats.toPercent(pct.food)); st.production = Stats.f32(st.production * Stats.toPercent(pct.production))
        st.gold = Stats.f32(st.gold * Stats.toPercent(pct.gold)); st.science = Stats.f32(st.science * Stats.toPercent(pct.science))
        st.culture = Stats.f32(st.culture * Stats.toPercent(pct.culture)); st.faith = Stats.f32(st.faith * Stats.toPercent(pct.faith))
        return st
    }

    /// Unciv CityStats.getStatConversionRate
    func statConversionRate(_ civId: Int, _ stat: String) -> Double {
        // `var conversionRate = 1 / 4f` and `conversionRate *= params[1].toPercent()`: Float, the first matching
        // civ unique (conditionals applied in the civ's state)
        var rate: Float = 1 / 4
        let ctx = UniqueContext(civId: civId)
        if let cu = civUniques(civId).first(where: { $0.pattern == "Production to [] conversion in cities changed by []%" && conditionalsHold($0, ctx) && $0.param(0) == stat }) {
            rate *= Float(Stats.toPercent(cu.double(1)))
        }
        return Double(rate)
    }

    /// Unciv CityPopulationManager.getFoodToNextPopulation: Civ V curve × speed, ×1.5 for city-states, × AI growth modifier.
    func growthCost(_ city: City) -> Double {
        var food = city.foodToGrow * speed.modifier
        if let c = civ(city.civId) {
            if c.isCityState { food *= 1.5 }
            if !c.isPlayer { food *= difficulty.aiCityGrowthModifier }
        }
        return food.rounded(.down)
    }

    /// "Tile provides yield without assigned population" (natural wonders inside the borders)
    func unassignedYieldTiles(_ city: City) -> [Tile] {
        city.tiles.compactMap { c in
            guard c != city.coord, c.distance(to: city.coord) <= rs.constants.cityWorkRange, !city.workedTiles.contains(c), let t = map[c], t.ownerCivId == city.civId,   // Unciv: within tilesInRange
                  t.terrainNames.contains(where: { rs.terrains[$0]?.uniques.contains("Tile provides yield without assigned population") == true }) || (t.naturalWonder.flatMap { rs.terrains[$0]?.uniques.contains("Tile provides yield without assigned population") } ?? false) else { return nil }
            return t
        }
    }

    /// Unciv City.cityStats.currentCityStats: THE city's stats, as every engine reader sees them.
    ///
    /// Unciv holds one object per city, written by `cityStats.update()` and read by everyone in between. It is
    /// stale on purpose: the gold that buys a building, the construction the city automation queues and the
    /// technology that lands mid-turn do not touch it, so a turn spends the yields the city had when the turn
    /// began. We recomputed on demand and emulated one axis of that (the construction), which could not hold
    /// both of the cases MIRROR.md records. This is the cache itself; `updateCityStats` is `update()`.
    /// Unciv City.getLocalMatchingUniques: the city's buildings' local ("in this city") uniques, then its religion's -
    /// the part of `cityUniques` that is not the civ's, multiplied the same way.
    func cityLocalUniques(_ city: City) -> [Unique] {
        var out: [Unique] = []
        for b in city.builtBuildingObjects { out += (rs.buildings[b]?.uniqueObjects ?? []).filter { $0.isLocalEffect }.from(rs.buildings[b]?.isAnyWonder == true ? .wonder : .building, b) }
        out += religionUniques(for: city)
        return multiplied(out, UniqueContext(civId: city.civId, city: city))
    }

    func currentCityStats(_ cityId: Int) -> CityStats {
        if ProcessInfo.processInfo.environment["NOSTATCACHE"] == nil, let s = storedCityStats[cityId] { return s }
        guard let c = city(cityId) else { return CityStats() }
        let s = computeStats(for: c)
        storedCityStats[cityId] = s
        return s
    }

    /// Unciv CityScreen's init (CityScreen.kt:164) and a new CityScreen's updateAsync (page, Move to city): the city's
    /// stats refreshed - `cityView.updateCityStats()` - as the screen opens
    func cityScreenOpened(_ cityId: Int) { updateCityStats(cityId, reason: "CityScreen.init") }
    /// Unciv CityStats.update(updateCivStats = true): recompute THIS city and then the empire's totals, which
    /// are a sum over the cities' stored stats. Call it where Unciv calls it, and nowhere else.
    func updateCityStats(_ cityId: Int, updateCivStats: Bool = true, reason: String = "?") {
        guard let c = city(cityId) else { storedCityStats.removeValue(forKey: cityId); return }
        if epochsDebug { AI.profile["n.updateCityStats", default: 0] += 1; AI.profile["u." + reason, default: 0] += 1 }
        let fresh = computeStats(for: c)
        if ProcessInfo.processInfo.environment["STATSUPD"] == c.name {
            print("STATSUPD t=\(turn) \(c.name) reason=\(reason) constr=\(c.currentProduction?.name ?? "-") prod=\(fresh.total.production) " + Thread.callStackSymbols.dropFirst(1).prefix(4).map { String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first ?? "") }.joined(separator: " < "))
        }
        if ProcessInfo.processInfo.environment["CHOICE_CITY"] == c.name {
            if let m = Epochs.CityStats(city: c, state: self) {
                m.update(currentConstruction: c.currentProduction)
                let rows = m.finalStatList.order.compactMap { k -> String? in
                    guard let v = m.finalStatList[k], v.production != 0 || v.food != 0 else { return nil }
                    return "\(k)=\(v.production)/\(v.food)"
                }
                print("AYNAE t=\(turn) \(c.name) prod=\(m.currentCityStats.production) food=\(m.currentCityStats.food) | " + rows.joined(separator: " "))
                let pct: [String] = m.statPercentBonusTree.children.keys.sorted().map { k in
                    let node = m.statPercentBonusTree.children[k]!
                    let kids: [String] = node.children.keys.sorted().map { "\($0):\(node.children[$0]!.totalStats.production)" }
                    return "\(k)=\(node.totalStats.production){\(kids.joined(separator: ","))}"
                }
                print("PCTE t=\(turn) \(c.name) " + pct.joined(separator: " "))
            }
            print("UPDCS t=\(turn) \(c.name) prod=\(fresh.total.production) tile=\(fresh.tileYields.production) bld=\(fresh.buildingYields.production) pct=\(fresh.percentBonus.production) pop=\(c.population) worked=\(c.workedTiles.count) surplus=\(fresh.foodSurplus) growthPct=\(fresh.growthPercent) happy=\(happiness(of: c.civId)) gold=\(fresh.total.gold) cur=\(c.currentProduction?.name ?? "-")")
        }
        storedCityStats[cityId] = fresh
        if updateCivStats { if epochsDebug { AI.profile["n.civFromCity", default: 0] += 1 }; updateStatsForNextTurn(c.civId) }
    }

    /// `growthModifiers: false` is Unciv's CityStats.update(calculateGrowthModifiers = false), used when the AI compares two constructions.
    /// `hypothetical` is Unciv's `city.clone()` in ConstructionAutomation.getStatDifferenceFromBuilding: the
    /// stats of a city that does not exist must not change the one that does.
    func computeStats(for city: City, growthModifiers: Bool = true, hypothetical: Bool = false,
                      currentConstruction: Production?? = nil, seededTileStats: Stats? = nil) -> CityStats {
        let umT = UIMeasure.start(); defer { UIMeasure.stop("computeStats", umT) }
        var s = CityStats()
        guard civ(city.civId) != nil else { return s }
        if epochsDebug { AI.profile["n.computeStats", default: 0] += 1 }   // Unciv's own Timers says CityStats.update runs 2284 times in 60 turns
        let tCS = epochsDebug ? Date() : nil
        defer { if let tCS { AI.profile["t.computeStats", default: 0] += Date().timeIntervalSince(tCS) } }
        // Unciv CityStats.updateTileStats drops a blockaded worked tile there and then, so the blockade costs
        // the defender this turn's yield rather than the next one's, and the citizen it freed is placed again
        // at the next turn start. The mirror does that itself now; it used to be duplicated here.
        let mirror = Epochs.CityStats(city: city, state: self)
        mirror?.appliesSideEffects = !hypothetical
        mirror?.countsTradeRoutes = !hypothetical
        // `seededTileStats` is Unciv's `cityStats.statsFromTiles = city.cityStats.statsFromTiles` - the tiles
        // handed over as they stand, with `updateTileStats = false` so they are not walked again.
        if let seeded = seededTileStats { mirror?.statsFromTiles = seeded }
        mirror?.update(currentConstruction: currentConstruction ?? city.currentProduction,
                       calculateGrowthModifiers: growthModifiers, updateTileStats: seededTileStats == nil)
        let ctx = UniqueContext(civId: city.civId, city: city)
        let uniques = cityUniques(city).filter { scopeIncludes($0, city: city) && conditionalsHold($0, ctx) }
        // What stood here was a second, aggregate calculation of the same city. It is gone: the mirrored
        // CityStats above is Unciv's own shape - one entry per SOURCE, the percentages applied per entry, in
        // Float - and the struct is filled from it. Only one of the two was ever right.
        // On the clock this costs nothing measurable. Ours spends about 1.5ms per call against the
        // reference's 100µs (Unciv's own Timers, 2284 calls in 60 turns of `settled`), but it is called ten
        // times a turn, not thirty-eight, and the whole of it is ~2% of a turn: `t.computeStats` is 185ms per
        // ten turns where the turns themselves take 9300ms. The 120-turn autoplay measured 303s before any of
        // this work and 291s after it.
        guard let m = mirror else { return s }
        if StateDump.captureTrees, !hypothetical, seededTileStats == nil, growthModifiers, currentConstruction == nil { StateDump.trees[city.id] = (m.baseStatTree, m.statPercentBonusTree) }
        let base = m.baseStatTree
        s.tileYields = m.statsFromTiles
        s.tradeRoutes = base.children["Trade routes"]?.totalStats ?? Stats()
        // The old field lumped specialists and every unique-derived yield in with the buildings, and the
        // empire's stat map still names its rows that way: everything that is not a tile, a citizen or a
        // trade route.
        var bld = base.totalStats
        bld += m.statsFromTiles * -1
        bld += s.tradeRoutes * -1
        bld += (base.children["Population"]?.totalStats ?? Stats()) * -1
        s.buildingYields = bld
        s.percentBonus = m.statPercentBonusTree.totalStats
        s.maintenance = Int(m.buildingMaintenanceCosts)
        var total = m.currentCityStats
        total.gold += Double(s.maintenance)   // the mirror files Maintenance as an entry; this struct keeps it apart
        total.food = m.grossFood              // the empire's stat map reads the GROSS food back out
        s.total = total
        s.foodSurplus = m.currentCityStats.food
        s.happinessRows = m.happinessList
        s.finalStatList = m.finalStatList.order.compactMap { k in m.finalStatList[k].map { (k, $0) } }
        // Unciv getGrowthBonus is "[]% growth []" only (We Love The King Day is the separate quarter), and
        // NullifiesGrowth is its own unique; the citizen assignment reads both.
        for u in uniques {
            switch u.pattern {
            case "[]% growth []", "[]% growth": s.growthPercent += u.double(0)
            case "Nullifies Growth []", "Nullifies Growth": s.nullifiesGrowth = true
            default: break
            }
        }
        // Unciv City.foodForNextTurn: the food actually banked each turn is the rounded surplus, and both
        // isGrowing and getNumTurnsToNewPopulation are counted from that, with at least one turn.
        s.foodForNextTurn = (s.foodSurplus + 0.5).rounded(.down)
        if s.foodForNextTurn > 0 { s.growthTurns = max(1, Int(((growthCost(city) - city.foodStored) / s.foodForNextTurn).rounded(.up))) }
        return s
    }
}
