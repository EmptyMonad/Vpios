// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/city/CityConstructions.kt`: what a city can build, what it costs and how long it takes.
extension GameState {
    /// Unciv Building.getProductionCost / BaseUnitCost.getProductionCost(civInfo, city), in Float as there:
    /// the cost, the per-city and per-built increases, the percentage changes, the city-state / human / AI
    /// modifier, the speed, then `toInt()` (truncated). Conditionals are read in `city?.state ?: civInfo.state`.
    func productionCost(_ p: Production, for civId: Int, city: City? = nil) -> Int {
        let owner = civ(civId)
        let isHuman = owner?.isPlayer ?? true
        let isCityState = owner?.isCityState ?? false
        let stateForConditionals = city.map { UniqueContext(civId: civId, city: $0) } ?? UniqueContext(civId: civId)
        let citiesSize = cities(of: civId).count
        func built(_ name: String) -> Int { owner?.builtItemsWithIncreasingCost[name] ?? 0 }
        switch p {
        case .unit(let n):
            let uniques = rs.units[n]?.rulesetUniqueObjects ?? []
            var productionCost = Float(rs.units[n]?.cost ?? 40)
            for u in uniques where u.pattern == "Cost increases by [] per owned city" && conditionalsHold(u, stateForConditionals) { productionCost += Float(citiesSize * u.int(0)) }
            for u in uniques where u.pattern == "Cost increases by [] when built" && conditionalsHold(u, stateForConditionals) { productionCost += Float(built(n) * u.int(0)) }
            for u in uniques where u.pattern == "[]% production cost" && conditionalsHold(u, stateForConditionals) { productionCost *= Float(Stats.toPercent(u.double(0))) }
            productionCost *= isCityState ? 1.5 : isHuman ? Float(difficulty(for: civId).unitCostModifier) : Float(difficulty.aiUnitCostModifier)
            productionCost *= Float(speed.productionCostModifier)
            return Int(productionCost)
        case .building(let n):
            guard let b = rs.buildings[n] else { return 40 }
            var productionCost = Float(rs.cost(of: b))
            for u in b.uniqueObjects where u.pattern == "Cost increases by [] when built" && conditionalsHold(u, stateForConditionals) { productionCost += Float(built(n) * u.int(0)) }
            for u in b.uniqueObjects where u.pattern == "Cost increases by [] per owned city" && conditionalsHold(u, stateForConditionals) { productionCost += Float(citiesSize * u.int(0)) }
            for u in b.uniqueObjects where u.pattern == "[]% production cost" && conditionalsHold(u, stateForConditionals) { productionCost *= Float(Stats.toPercent(u.double(0))) }
            if isCityState {
                productionCost *= 1.5
            } else if isHuman {
                if !b.isWonder { productionCost *= Float(difficulty(for: civId).buildingCostModifier) }
            } else {
                // `civInfo.gameInfo.getDifficulty()`: an AI pays the game difficulty's AI modifiers
                productionCost *= Float(b.isWonder ? difficulty.aiWonderCostModifier : difficulty.aiBuildingCostModifier)
            }
            productionCost *= Float(speed.productionCostModifier)
            return Int(productionCost)
        }
    }

    func turnsToComplete(_ city: City) -> Int? {
        // Unciv CityConstructions.turnsToConstruction
        guard let p = city.currentProduction else { return nil }
        let workLeft = Double(productionCost(p, for: city.civId)) - city.productionStored
        if workLeft <= 0 { return 0 }
        if workLeft <= Double(city.productionOverflow) { return 1 }
        let production = currentCityStats(city.id).total.production.rounded()
        guard production > 0 else { return nil }
        return Int(((workLeft - Double(city.productionOverflow)) / production).rounded(.up))
    }

    /// Unciv CityConstructions.workDone: the production banked against a construction that is not the current one.
    func workDone(_ p: Production, in city: City) -> Int {
        city.currentProduction == p ? Int(city.productionStored) : (city.inProgressConstructions[p.name] ?? 0)
    }

    /// Unciv CityConstructions.turnsToConstruction: remaining work with stored progress counted, overflow first, then the city's
    /// production as if this were its current construction
    func turnsToConstruction(_ p: Production, in city: City, useStored: Bool = true) -> Int? {
        let umT = UIMeasure.start(); defer { UIMeasure.stop("turnsToConstruction", umT) }
        let done = !useStored ? 0 : (city.currentProduction == p ? city.productionStored : Double(city.inProgressConstructions[p.name] ?? 0))
        let workLeft = Double(productionCost(p, for: city.civId)) - done
        if workLeft <= 0 { return 0 }
        if workLeft <= Double(city.productionOverflow) { return 1 }
        // Unciv CityConstructions.productionForConstruction: if the construction asked about IS the city's
        // current one, the answer is the STORED `currentCityStats` and nothing is computed. Otherwise a fresh
        // CityStats takes the city's `statsFromTiles` as-is and runs with `updateTileStats = false` - the
        // tiles are never walked a second time. Ours recomputed everything on both paths, and this number is
        // what the construction automation ranks candidates by.
        let production: Double
        if city.currentProduction == p {
            production = (storedCityStats[city.id]?.total.production ?? 0).rounded()
        } else {
            production = computeStats(for: city, currentConstruction: .some(p),
                                      seededTileStats: storedCityStats[city.id]?.tileYields ?? Stats()).total.production.rounded()
        }
        guard production > 0 else { return nil }
        return Int(((workLeft - Double(city.productionOverflow)) / production).rounded(.up))
    }

    // MARK: what a city can build

    // (The availability shortcuts that stood here - wonderBuiltAnywhere, wonderInProgressElsewhere, availabilityHolds -
    // were an unused approximation of Building/BaseUnit.getRejectionReasons; those live in models/ruleset/IConstruction.swift.)

    /// Stats a civ may turn spare production into (Currency → Gold, Scientific Theory → Science).
    /// Unciv PerpetualConstruction.StatConversion.isBuildable, for every stat at once: the civ has "Enables conversion of
    /// city production to [stat]" with its conditionals holding (in the city's state when one is given), and Faith
    /// only when religion is enabled.
    func productionConversions(for civId: Int, city: City? = nil) -> [String] {
        var out: [String] = []
        let ctx = UniqueContext(civId: civId, city: city)
        for u in civUniques(civId) where u.pattern == "Enables conversion of city production to []" && conditionalsHold(u, ctx) {
            if u.param(0) == "Faith" && !religionEnabled { continue }
            if !out.contains(u.param(0)) { out.append(u.param(0)) }
        }
        return out
    }

    /// Unciv BaseUnit.isBuildable == getRejectionReasons().none(). No rejection reason reads City.disabledConstructions:
    /// a disabled construction is still buildable, only ConstructionAutomation leaves it out for a human.
    func buildableUnits(for city: City) -> [UnitDef] {
        guard let civ = civ(city.civId) else { return [] }
        return rs.availableUnitDefs(for: civ.nation).filter { u in unitRejections(u, city: city).isEmpty }
    }

    /// Unciv Building.isBuildable == getRejectionReasons().none()
    func buildableBuildings(for city: City) -> [BuildingDef] {
        guard let civ = civ(city.civId) else { return [] }
        return rs.availableBuildingDefs(for: civ.nation).filter { b in buildingRejections(b, city: city).isEmpty }
    }

    // MARK: faith purchases (and the other stats)

    /// The units this city could buy with `stat`: Unciv's `isPurchasable(cityConstructions) && canBePurchasedWithStat(city, stat)`
    /// (what ReligionAutomation asks of a missionary, an inquisitor or a great person), with a price. Ruleset order.
    func statPurchasableUnits(for city: City, stat: String = "Faith") -> [UnitDef] {
        let ctx = UniqueContext(civId: city.civId, city: city)
        let mayBuy = ["May buy [] units for [] [] [] at an increasing price ([])", "May buy [] units with [] for [] times their normal Production cost",
                      "May buy [] units with [] []", "May buy [] units for [] [] []"].flatMap { cityMatchingUniques(city, $0) }
        return rs.unitOrder.compactMap { rs.units[$0] }.filter { u in
            // a cheap necessary condition first: some unique has to name this stat for this unit
            let named = stat == "Gold"
                || u.rulesetUniqueObjects.contains { ($0.pattern == "Can be purchased with [] []" && $0.param(0) == stat) || ($0.pattern == "Can be purchased for [] [] []" && $0.param(1) == stat) }
                || mayBuy.contains { ($0.pattern == "May buy [] units for [] [] [] at an increasing price ([])" || $0.pattern == "May buy [] units for [] [] []" ? $0.param(2) : $0.param(1)) == stat && baseUnitMatchesFilter(u, $0.param(0), ctx) }
            guard named else { return false }
            let p = Production.unit(u.name)
            return canBePurchasedWithStat(p, city: city, stat: stat) && isPurchasable(p, city: city) && getStatBuyCost(p, city: city, stat: stat) != nil
        }
    }

    /// Unciv BaseUnitCost.getStatBuyCost(city, stat). Without a city, the civ's first city stands in.
    func statBuyCost(_ unit: UnitDef, for civId: Int, in city: City? = nil, stat: String = "Faith") -> Int {
        guard let city = city ?? cities(of: civId).first else { return 0 }
        return getStatBuyCost(.unit(unit.name), city: city, stat: stat) ?? 0
    }

    /// Unciv Religion.buildingsPurchasableByBeliefs of the city's majority religion: over getAllBeliefsOrdered (pantheon,
    /// founder, follower, enhancer), each belief's "May buy [] buildings with [] []", then "... for [] [] []", then the
    /// increasing-price form - mapped to our equivalent building, kept when `isPurchasable` and it has a price. This is
    /// the list ReligionAutomation.tryBuyAnyReligiousBuilding picks the cheapest from.
    /// `lazyReligionList`: ReligionAutomation reads `Religion.buildingsPurchasableByBeliefs`, which is `by lazy` - the
    /// names are fixed at the first read after the game was loaded or after the last human Next Turn (per religion:
    /// WorldScreen.nextTurn clones GameInfo, which makes new Religion objects), so a follower belief added by enhancing
    /// is missing from it until then. Other callers get the live list.
    func beliefPurchasableBuildings(for city: City, stat: String = "Faith", lazyReligionList: Bool = false) -> [(BuildingDef, Int)] {
        guard let r = majorityReligion(of: city), let owner = religionOwner(r) else { return [] }
        let names: [String]
        if lazyReligionList, let cached = religionBuildingsPurchasableCache[r] { names = cached }
        else {
            names = unlockedBuildingsPurchasable(owner)
            if lazyReligionList { religionBuildingsPurchasableCache[r] = names }
        }
        var out: [(BuildingDef, Int)] = []
        for name in names where rs.buildings[name] != nil {
            guard let def = rs.buildings[equivalentBuilding(city.civId, name)], !out.contains(where: { $0.0.name == def.name }) else { continue }
            let p = Production.building(def.name)
            guard isPurchasable(p, city: city), let cost = getStatBuyCost(p, city: city, stat: stat) else { continue }
            out.append((def, cost))
        }
        return out
    }

    /// Unciv Religion.unlockedBuildingsPurchasable: over getAllBeliefsOrdered, each belief's building-buying uniques'
    /// building names (the ruleset's buildings only)
    private func unlockedBuildingsPurchasable(_ owner: Civilization) -> [String] {
        // Unciv Religion keeps two HashSet<String>s - followerBeliefs (Pantheon, Follower) and founderBeliefs (Founder,
        // Enhancer) - and getAllBeliefsOrdered walks each in Java bucket order: Pantheon of followerBeliefs, Founder of
        // founderBeliefs, Follower of followerBeliefs, Enhancer of founderBeliefs. Ours kept the order they were
        // chosen, so a religion that took Pagodas before Mosques listed the Pagoda first and, the prices tied,
        // tryBuyAnyReligiousBuilding's minBy bought it where Unciv buys the Mosque.
        var followerAdded: [String] = owner.pantheonBelief.map { [$0] } ?? [], founderAdded: [String] = []   // insertion order, a set
        for b in owner.religionBeliefs {
            switch rs.beliefs[b]?.type {
            case "Pantheon", "Follower": if !followerAdded.contains(b) { followerAdded.append(b) }
            case "Founder", "Enhancer": if !founderAdded.contains(b) { founderAdded.append(b) }
            default: break
            }
        }
        let followerBeliefs = javaHashMapOrder(followerAdded), founderBeliefs = javaHashMapOrder(founderAdded)
        let beliefs = followerBeliefs.filter { rs.beliefs[$0]?.type == "Pantheon" } + founderBeliefs.filter { rs.beliefs[$0]?.type == "Founder" }
            + followerBeliefs.filter { rs.beliefs[$0]?.type == "Follower" } + founderBeliefs.filter { rs.beliefs[$0]?.type == "Enhancer" }
        var names: [String] = []
        for b in beliefs {
            let uniques = rs.beliefs[b]?.uniqueObjects ?? []
            for pattern in ["May buy [] buildings with [] []", "May buy [] buildings for [] [] []", "May buy [] buildings for [] [] [] at an increasing price ([])"] {
                names += uniques.filter { $0.pattern == pattern }.map { $0.param(0) }
            }
        }
        return names.filter { rs.buildings[$0] != nil }
    }

    /// The buildings this city could buy with `stat`: the belief ones first (above), then any other building that
    /// `canBePurchasedWithStat(city, stat)` and `isPurchasable`, in ruleset order.
    func statPurchasableBuildings(for city: City, stat: String = "Faith") -> [(BuildingDef, Int)] {
        var out = beliefPurchasableBuildings(for: city, stat: stat)
        for def in rs.buildingOrder.compactMap({ rs.buildings[$0] }) where !out.contains(where: { $0.0.name == def.name }) {
            let p = Production.building(def.name)
            guard canBePurchasedWithStat(p, city: city, stat: stat), isPurchasable(p, city: city), let cost = getStatBuyCost(p, city: city, stat: stat) else { continue }
            out.append((def, cost))
        }
        return out
    }

    /// Unciv isConstructionPurchaseAllowed: puppets may buy with the unique, a city in resistance may not buy at all.
    func faithPurchaseAllowed(_ city: City) -> Bool {
        if city.resistanceTurns > 0 { return false }
        return !city.isPuppet || cityUniques(city).contains { $0.pattern == "May buy items in puppet cities" }
    }

    func faithPurchasableUnits(for city: City) -> [UnitDef] { statPurchasableUnits(for: city) }

    /// Unciv ReligionAutomation.tryBuyAnyReligiousBuilding's candidates: the majority religion's belief buildings only
    func faithPurchasableBuildings(for city: City, lazyReligionList: Bool = false) -> [(BuildingDef, Int)] { beliefPurchasableBuildings(for: city, lazyReligionList: lazyReligionList) }

    func faithCost(_ unit: UnitDef, for civId: Int, in city: City? = nil) -> Int { statBuyCost(unit, for: civId, in: city) }

    /// The reserve a stat purchase is paid from: Food is the city's own store, the rest the empire's.
    func statPurchaseReserve(_ stat: String, in city: City) -> Double {
        guard let c = civ(city.civId) else { return 0 }
        switch stat {
        case "Faith": return c.faithStored
        case "Culture": return c.cultureStored
        case "Science": return Double(scienceReserve(c))
        case "Food": return city.foodStored
        default: return 0
        }
    }

    /// Take the price out of that reserve.
    private func spendStat(_ stat: String, _ amount: Double, cityIndex ci: Int) {
        guard let civIdx = civIndex(cities[ci].civId) else { return }
        switch stat {
        case "Faith": civs[civIdx].faithStored -= amount
        case "Culture": civs[civIdx].cultureStored -= amount
        case "Science": addScience(civId: cities[ci].civId, -Int(amount))
        case "Food": cities[ci].foodStored -= amount
        default: break
        }
    }

    @discardableResult
    func buyWithFaith(cityId: Int, unit: String? = nil, building: String? = nil, automated: Bool = false) -> Bool {
        buyWithStat(cityId: cityId, unit: unit, building: building, stat: "Faith", automated: automated)
    }

    /// Unciv CityConstructions.purchaseConstruction with another stat (faith, ...): the same order as the gold
    /// purchase - construct (no "has been built" notification, no saved promotions), pay, count the increasing
    /// price, take the stockpiled resources if nothing was put in yet, then validateConstructionQueue (ending in
    /// chooseNextConstruction) and choose again if the city is left idle. The automation buys with position -1.
    /// `automated`: ReligionAutomation calls purchaseConstruction directly after its own filters (isPurchasable,
    /// canBePurchasedWithStat, cost <= stored faith) - without isConstructionPurchaseAllowed's puppet, resistance
    /// and canPlaceNewUnit gates, so a city in resistance still buys. The city screen keeps the gate.
    @discardableResult
    func buyWithStat(cityId: Int, unit: String? = nil, building: String? = nil, stat: String, automated: Bool = false, queuePosition: Int? = nil) -> Bool {
        guard let ci = cityIndex(cityId), let civIdx = civIndex(cities[ci].civId) else { return false }
        let civId = cities[ci].civId
        let p: Production
        let cost: Int
        if let u = unit, let def = rs.units[u], statPurchasableUnits(for: cities[ci], stat: stat).contains(where: { $0.name == u }) {
            cost = statBuyCost(def, for: civId, in: cities[ci], stat: stat)
            guard statPurchaseReserve(stat, in: cities[ci]) >= Double(cost), automated || canPurchaseWithAnyStat(.unit(u), in: cities[ci]) else { return false }
            p = .unit(u)
        } else if let b = building, let entry = statPurchasableBuildings(for: cities[ci], stat: stat).first(where: { $0.0.name == b }) {
            cost = entry.1
            guard statPurchaseReserve(stat, in: cities[ci]) >= Double(cost), automated || canPurchaseWithAnyStat(.building(b), in: cities[ci]) else { return false }
            p = .building(b)
        } else { return false }
        let workDoneBefore = workDone(p, in: cities[ci])
        switch p {
        case .building(let name):
            addBuilding(cityIndex: ci, name)   // Building.construct
        case .unit(let name):
            guard let def = rs.units[name], let spawned = spawnUnit(name, civId: civId, at: cities[ci].coord), let ui = unitIndex(spawned.id) else { return false }   // nothing built - no pay
            units[ui].charges = def.spreadCharges   // religion already set by spawnUnit (Unciv addUnit rule)
            // Unciv BaseUnit.construct → civ.units.addUnit(unit, city): a great person is announced as born there
            if def.isGreatPerson, let c = city(cityId) { notify(civId, "A [\(name)] has been born in [\(c.name)]!", category: .General, icons: [name], actions: [.unit(spawned.coord, spawned.id)]) }
            if !settings.godMode, def.canMoveImmediatelyOnceBought != true { units[ui].movementLeft = 0 }   // BaseUnit.construct(boughtWith)
            if let c = city(cityId) { addConstructionBonuses(unitIndex: ui, city: c) }
            civs[civIdx].everEarnedUnits.insert(name)
        }
        if !settings.godMode, let cix = cityIndex(cityId) {
            spendStat(stat, Double(cost), cityIndex: cix)   // city.addStat(stat, -cost)
            // Unciv: `boughtItemsWithIncreasingPrice.add(construction.name, 1)` when any of the civ's
            // BuyUnitsIncreasingCost / BuyBuildingsIncreasingCost uniques (read with the city's state) names this
            // construction, this city and this stat - counted per item. Ours counted every great person bought.
            let cityCtx = UniqueContext(civId: civId, city: cities[cix])
            let increasing = civUniques(civId).contains { u in
                guard u.pattern == "May buy [] units for [] [] [] at an increasing price ([])" || u.pattern == "May buy [] buildings for [] [] [] at an increasing price ([])",
                      conditionalsHold(u, cityCtx) else { return false }
                let matches: Bool
                switch p {
                case .unit(let n): matches = rs.units[n].map { baseUnitMatchesFilter($0, u.param(0), cityCtx) } ?? false
                case .building(let n): matches = rs.buildings[n].map { buildingMatchesFilter($0, u.param(0), cityCtx) } ?? false
                default: matches = false
                }
                return matches && cityMatchesFilter(u.param(3), city: cities[cix], viewer: civId) && u.param(2) == stat
            }
            if increasing {
                if case .unit(let u) = p, rs.units[u]?.greatPersonType != nil { civs[civIdx].faithGreatPeopleBought += 1 }   // legacy counter
                civs[civIdx].boughtWithIncreasingPrice[p.name, default: 0] += 1
            }
            if workDoneBefore == 0 { payConstructionStockpileCosts(cityId: cityId, p) }
        }
        if GameState.evlogOn, let c = city(cityId) { ev(c.civId, "BUY", EvLog.name(c.name), EvLog.name(p.name), String(cost), stat) }
        // Unciv purchaseConstruction: `if (queuePosition in 0 until constructionQueue.size) removeFromQueue(queuePosition, automatic)`
        if let qp = queuePosition, let cq = cityIndex(cityId), combinedQueue(cities[cq]).indices.contains(qp) {
            removeFromCombinedQueue(cityId: cityId, index: qp)
        }
        validateConstructionQueue(cityId: cityId)
        if let c3 = cityIndex(cityId), cities[c3].isQueueEmptyOrIdle {
            chooseNextConstructionIfAutomated(cityId: cityId)   // "A purchase should never leave the city idle"
        }
        return true
    }

    /// Percent production bonus for a city building `p`, from all "[]% Production when constructing [] ..." uniques.
    func productionBonusPercent(city: City, for p: Production) -> Double {
        var pct = 0.0
        let ctx = UniqueContext(civId: city.civId, city: city, production: p)
        for u in cityUniques(city) + heldResourceUniques(city.civId) {
            guard scopeIncludes(u, city: city), conditionalsHold(u, ctx) else { continue }
            switch u.pattern {
            case "[]% Production when constructing [] units []", "[]% Production when constructing [] units":
                if p.isUnit && productionMatches(p, u.param(1)) { pct += u.double(0) }
            case "[]% Production when constructing [] buildings []", "[]% Production when constructing [] buildings":
                if case .building(let n) = p, let d = rs.buildings[n], !d.isAnyWonder, productionMatches(p, u.param(1)) { pct += u.double(0) }
            case "[]% Production when constructing [] wonders []", "[]% Production when constructing [] wonders":
                if case .building(let n) = p, let d = rs.buildings[n], d.isAnyWonder, (u.param(1) == "All" || u.param(1) == "all" || productionMatches(p, u.param(1))) { pct += u.double(0) }
            case "[]% Production when constructing []", "[]% Production when constructing [] []":
                if productionMatches(p, u.param(1)) { pct += u.double(0) }
            case "[]% Production towards any buildings that already exist in the Capital":
                if case .building(let n) = p, let cap = capital(of: city.civId), cap.buildings.contains(n) { pct += u.double(0) }   // Unciv does not exclude the capital itself
            default: break
            }
        }
        if civ(city.civId)?.isInGoldenAge == true { pct += 20 }
        return pct
    }


    /// Unciv UnitActionModifiers.getMaxUsages: the extra uses a promotion's "Can Spread Religion <[n] additional time(s)>" adds
    func extraSpreadTimes(promotion: String) -> Int {
        (rs.promotions[promotion]?.uniqueObjects ?? []).filter { $0.pattern == "Can Spread Religion" }
            .flatMap { $0.conditionals }.filter { $0.pattern == "[] additional time(s)" }.reduce(0) { $0 + $1.int(0) }
    }

    // MARK: cities
    /// Unciv BaseUnit.addConstructionBonuses: starting XP and promotions of the city the unit is treated as built in
    /// In Unciv's order: the XP of every "New [unitFilter] units start with [n] XP [cityFilter]" is summed and SET as
    /// the unit's XP, then every "All newly-trained [unitFilter] units [cityFilter] receive the [promotion] promotion"
    /// adds its promotion for free (UnitPromotions.addPromotion, with its triggers). The uniques are the city's
    /// (city.forEachMatchingUnique: conditionals read in the city's state).
    func addConstructionBonuses(unitIndex ui: Int, city: City) {
        let spawned = units[ui]
        let unitId = spawned.id
        var xp = 0
        for u in cityMatchingUniques(city, "New [] units start with [] XP []")
            where unitMatches(spawned, u.param(0)) && cityMatchesFilter(u.param(2), city: city, viewer: city.civId) { xp += u.int(1) }
        units[ui].xp = xp
        for u in cityMatchingUniques(city, "All newly-trained [] units [] receive the [] promotion") {
            guard cityMatchesFilter(u.param(1), city: city, viewer: city.civId) else { continue }
            let filter = u.param(0)
            let promotion = u.params.last ?? ""
            // "relevant" is not a unit filter - it means the promotion itself lists this unit's type, which is how
            // the Alhambra hands Drill I to land units only.
            let isRelevantPromotion = filter == "relevant" && rs.promotionOrder.contains { $0.name == promotion && $0.unitTypes.contains(spawned.def.unitType) }
            guard let now = unit(unitId), isRelevantPromotion || unitMatches(now, filter) else { continue }
            addPromotion(unitId: unitId, promotion, isFree: true)
        }
    }

    /// Unciv civ.stats.statsForNextTurn.gold, once per turn
    /// Unciv `civ.stats.statsForNextTurn.gold`.
    ///
    /// Unciv keeps that as a field refreshed whenever the civ's stats are updated, so it tracks the turn as the
    /// turn happens. Ours cached it per TURN, which is not the same thing: the figure changes as cities finish
    /// buildings, assign citizens and take tiles, and a value computed early in the turn was then handed to every
    /// later caller. The citizen ranking doubles a tile's gold when this is negative, so Parsagadae read -1 where
    /// its own breakdown summed to +4 and worked an ivory tile Unciv passed over.
    func netGoldPerTurn(_ civId: Int) -> Double {
        if let stored = civ(civId)?.statsForNextTurn {
            // Under --verify-stats every read is checked against a fresh sum, so a missing
            // updateStatsForNextTurn() call shows up as a line instead of as a divergence ten turns later.
            if epochsVerifyStats {
                let rows = statMapForNextTurn(civId)
                let fresh = rows.reduce(0) { $0 + $1.1.gold }
                if abs(fresh - stored.gold) > 1e-9 {
                    let was = civ(civId)?.statRowsDebug ?? [:]
                    var now: [String: Double] = [:]
                    for r in rows { now[r.0, default: 0] += r.1.gold }
                    let changed = Set(was.keys).union(now.keys).filter { abs((now[$0] ?? 0) - (was[$0] ?? 0)) > 1e-9 }.sorted()
                    print("STATSTALE t=\(turn) civ=\(civ(civId)?.nation ?? "?") stored=\(stored.gold) fresh=\(fresh) rows=" + changed.map { "\($0):\(was[$0] ?? 0)->\(now[$0] ?? 0)" }.joined(separator: ","))
                }
            }
            return stored.gold
        }
        return statMapForNextTurn(civId).reduce(0) { $0 + $1.1.gold }
    }

    /// Unciv Civilization.updateStatsForNextTurn: recompute the field now. Called where Unciv calls it -
    /// anything that changes what the sum would be.
    func updateStatsForNextTurn(_ civId: Int, file: String = #fileID, line: Int = #line) {
        guard let ci = civs.firstIndex(where: { $0.id == civId }) else { return }
        if epochsDebug { AI.profile["n.updateStatsForNextTurn", default: 0] += 1 }   // Unciv's Timers: 2217 calls in 60 turns of `settled`
        // Unciv Civilization.updateStatsForNextTurn opens by re-reading happiness, and when that crosses a level
        // some unique is conditioned on, it updates EVERY city's stats before summing them. That is how an
        // empire falling into unhappiness reaches the cities mid-turn: measured on `fresh`, Greece went from 3
        // to -1 and Athens' cached production dropped from 10 to 8 for that one turn, because the food its
        // Settler was converting went with it.
        // Unciv: `val previousHappiness = stats.happiness`, a field that starts at 0 - never absent. Ours was
        // an Optional and the `if let` below swallowed the very first call, so an empire that started the game
        // already past a happiness level never told its cities.
        let previousHappiness = happinessCache[civId] ?? 0
        // The field is written HERE and only here, as Unciv writes civ.stats.happiness.
        let happinessNow = Stats.roundToInt(happinessBreakdown(civId).total)   // Unciv `values.sum().roundToInt()`
        if ProcessInfo.processInfo.environment["DUMP_HAPPY"] == civs[ci].nation, happinessCache[civId] != happinessNow {
            print("HAPPYE t=\(turn) \(civs[ci].nation) \(happinessCache[civId].map(String.init) ?? "-") -> \(happinessNow) from \(file):\(line) rows=\(happinessBreakdown(civId).rows.filter { $0.1 != 0 }.map { "\($0.0)=\($0.1)" }) cities=" + cities(of: civId).map { c in "\(c.name):\(currentCityStats(c.id).happinessRows.first { $0.0 == "Buildings" }?.1 ?? 0)" }.joined(separator: ","))
        }
        happinessCache[civId] = happinessNow
        if GameState.evlogOn, previousHappiness != happinessNow { ev(civId, "HAPPY", String(happinessNow)) }
        if previousHappiness != happinessNow,
           rs.happinessLevelsThatAffectUniques.contains(where: { (happinessNow < $0) != (previousHappiness < $0) }) {
            for c in cities(of: civId) { updateCityStats(c.id, updateCivStats: false, reason: "CityConstructions:32253") }
            if ProcessInfo.processInfo.environment["DUMP_HAPPY"] == civs[ci].nation {
                print("HAPPYX t=\(turn) cross \(previousHappiness)->\(happinessNow) cities=" + cities(of: civId).map { c in "\(c.name):\(currentCityStats(c.id).happinessRows.first { $0.0 == "Buildings" }?.1 ?? 0)\(c.buildings.contains("Castle") ? "C" : "")" }.joined(separator: ","))
            }
        }
        var total = Stats()
        let rows = statMapForNextTurn(civId)
        for row in rows { total = (total + row.1).f32 }   // Unciv `for (stats in statMapForNextTurn.values) newStats.add(stats)`, in Float
        if ProcessInfo.processInfo.environment["NEXTGOLD_CIV"] == civs[ci].nation, (civs[ci].statsForNextTurn?.gold ?? -999) != total.gold {
            print("NEXTGE t=\(turn) \(civs[ci].statsForNextTurn?.gold ?? -999) -> \(total.gold) from \(file):\(line) cities=" + cities(of: civId).map { "\($0.name):\(storedCityStats[$0.id]?.total.gold ?? -1)" }.joined(separator: ",") + " rows=" + rows.filter { $0.1.gold != 0 }.map { "\($0.0)=\($0.1.gold)" }.joined(separator: ","))
        }
        civs[ci].statsForNextTurn = total
        if epochsVerifyStats {
            var byRow: [String: Double] = [:]
            for r in rows { byRow[r.0, default: 0] += r.1.gold }
            civs[ci].statRowsDebug = byRow
        }
    }

    /// Pops the next still-buildable item off the city's queue into current production.
    func advanceProductionQueue(cityId: Int) {
        guard let ci = cityIndex(cityId), cities[ci].currentProduction == nil else { return }
        while !cities[ci].productionQueue.isEmpty {
            let next = cities[ci].productionQueue.removeFirst()
            if canProduce(next, in: cities[ci]) { cities[ci].currentProduction = next; return }
        }
    }

    /// Same answer as membership in buildableUnits/buildableBuildings, without building the whole list (Unciv isBuildable for one construction)
    func canProduce(_ p: Production, in city: City) -> Bool {
        guard let civ = civ(city.civId) else { return false }
        switch p {
        case .unit(let n):
            guard let u = rs.availableUnitDefs(for: civ.nation).first(where: { $0.name == n }) else { return false }
            return unitRejections(u, city: city).isEmpty
        case .building(let n):
            guard let b = rs.availableBuildingDefs(for: civ.nation).first(where: { $0.name == n }) else { return false }
            return buildingRejections(b, city: city).isEmpty
        }
    }

    func enqueueProduction(cityId: Int, _ p: Production) { addToQueue(cityId: cityId, p) }   // Unciv CityConstructions.addToQueue

    func removeFromQueue(cityId: Int, index: Int) {
        guard let ci = cityIndex(cityId), cities[ci].productionQueue.indices.contains(index) else { return }
        cities[ci].productionQueue.remove(at: index)
    }

    /// Unciv CityConstructions.lowerPriority: a queued entry swaps places with the one after it
    func demoteQueued(cityId: Int, index: Int) {
        guard let ci = cityIndex(cityId), cities[ci].productionQueue.indices.contains(index + 1) else { return }
        cities[ci].productionQueue.swapAt(index, index + 1)
    }

    /// Moves a queued item into current production; the old current item goes to the front of the queue.
    func promoteQueued(cityId: Int, index: Int) {
        guard let ci = cityIndex(cityId), cities[ci].productionQueue.indices.contains(index) else { return }
        let item = cities[ci].productionQueue.remove(at: index)
        if let cur = cities[ci].currentProduction { cities[ci].productionQueue.insert(cur, at: 0) }
        cities[ci].currentProduction = item
    }

    func chooseDefaultProduction(cityId: Int) {
        guard let ci = cityIndex(cityId), cities[ci].currentProduction == nil else { return }
        // Unciv: a puppet is ranked by the same construction automation as any other city
        let city = cities[ci]
        let mil = buildableUnits(for: city).filter { !$0.isCivilian }.sorted { $0.cost < $1.cost }
        if let b = buildableBuildings(for: city).first(where: { $0.name == Names.obelisk }) { cities[ci].currentProduction = .building(b.name) }
        else if let u = mil.first { cities[ci].currentProduction = .unit(u.name) }
    }

    /// Unciv CityConstructions.constructionBegun: pay the stockpiled resource costs, then the build-start alert
    func constructionBegun(cityId: Int, _ construction: Production) {
        guard let ci = cityIndex(cityId) else { return }
        payConstructionStockpileCosts(cityId: cityId, construction)
        // Unciv: `if (!construction.hasUnique(UniqueType.TriggersAlertOnStart)) return` - a building or a unit
        let (uniques, icon): ([String], String) = {
            switch construction {
            case .building(let b): return (rs.buildings[b]?.uniques ?? [], "BuildingIcons/\(b)")
            case .unit(let u): return (rs.units[u]?.uniques ?? [], "UnitIcons/\(u)")
            }
        }()
        guard uniques.contains("Triggers a global alert upon build start") else { return }
        let city = cities[ci], name = construction.name
        let who = civ(city.civId)?.nation ?? "?"   // city.civ.civName
        // Unciv CityConstructions.constructionBegun: every civilization of the game but the builder - by the city's name and
        // place when it has explored the city centre, by the builder's name when it knows it, else "[An unknown civilization]"
        // NotificationIcon.Construction is "StatIcons/Production": a bare "Construction" would name the technology
        for j in civs.indices where civs[j].id != city.civId {
            if civs[j].explored.contains(city.coord) {
                notify(civs[j].id, "The city of [\(city.name)] has started constructing [\(name)]!", category: .General, icons: ["StatIcons/Production", icon], coord: city.coord)
            } else if civs[j].metCivs.contains(city.civId) {
                notify(civs[j].id, "[\(who)] has started constructing [\(name)]!", category: .General, icons: ["StatIcons/Production", icon])
            } else {
                notify(civs[j].id, "[An unknown civilization] has started constructing [\(name)]!", category: .General, icons: ["StatIcons/Production", icon])
            }
        }
    }

    func payConstructionStockpileCosts(cityId: Int, _ construction: Production) {
        guard let ci = cityIndex(cityId) else { return }
        let uniques: [Unique] = { switch construction { case .unit(let n): return rs.units[n]?.uniqueObjects ?? []; case .building(let n): return rs.buildings[n]?.uniqueObjects ?? [] } }()
        for (res, amount) in stockpiledResourceRequirements(uniques, ctx: UniqueContext(civId: cities[ci].civId, city: cities[ci])) { gainStockpiledResource(cityId: cityId, res, -amount) }
    }

    func setProduction(cityId: Int, _ p: Production?) {
        guard let ci = cityIndex(cityId) else { return }
        if cities[ci].currentProduction != p {
            // Switching between unit/building keeps stored production (Civ V lets you carry it over).
            cities[ci].currentProduction = p
        }
    }

    /// Unciv INonPerpetualConstruction.getStatBuyCost(city, Gold) (Building.getStatBuyCost / BaseUnitCost.getStatBuyCost).
    /// Without a city there is no such price; the gold value Unciv uses there is getBaseGoldCost (see disbandGold).
    func purchaseCost(_ p: Production, for civId: Int, in city: City? = nil) -> Int {
        if let city { return getStatBuyCost(p, city: city, stat: "Gold") ?? 0 }
        let g = getBaseGoldCost(p, civId: civId, city: nil)
        return GameState.kotlinToInt(g / 10) * 10
    }

    /// Unciv CityConstructions.isConstructionPurchaseAllowed, the part every currency shares: a puppet without the
    /// unique, resistance, `isPurchasable` (every rejection reason is Unbuildable) and room for a new unit.
    func canPurchaseWithAnyStat(_ p: Production, in city: City) -> Bool {
        if city.isPuppet && cityMatchingUniques(city, "May buy items in puppet cities").isEmpty { return false }   // MayBuyConstructionsInPuppets
        if city.resistanceTurns > 0 { return false }
        if !isPurchasable(p, city: city) { return false }
        if case .unit(let n) = p, let u = rs.units[n], !canPlaceNewUnit(u, city: city) { return false }
        return true
    }

    /// Unciv CityConstructions.isConstructionPurchaseAllowed(construction, Gold, cost) without the reserve test:
    /// the shared gate above, then Building/BaseUnit.canBePurchasedWithStat(city, Gold) - which bars an Unbuildable
    /// item and a wonder (unless a unique allows it) from a gold purchase, and nothing else.
    func canPurchase(_ p: Production, in city: City) -> Bool {
        isConstructionPurchaseAllowed(p, city: city, stat: "Gold")
    }

    /// Unciv CityConstructions.purchaseConstruction (gold), in its order. A purchase is NOT completeConstruction:
    /// the item is constructed (Building.construct → addBuilding; BaseUnit.construct → addUnit, no movement when
    /// bought, construction bonuses), then paid for, then the stockpiled resources are taken if no work was put in,
    /// then the bought queue position leaves the queue, validateConstructionQueue runs (ending in
    /// chooseNextConstruction) and an idle city chooses again. No "has been built" notification, no saved
    /// promotions, and the work already banked under the item's name stays where it is.
    /// `queuePosition` is Unciv's; nil is its -1 ("not from the queue"). The AI (UseGoldAutomation) passes 0.
    /// `automatic` is Unciv's: the AI's purchase (true) lets an emptied queue choose again, the player's (false) leaves Idle.
    @discardableResult
    func purchase(cityId: Int, _ p: Production, queuePosition: Int? = nil, fromList: Bool = false, automatic: Bool = true) -> Bool {
        guard let ci = cityIndex(cityId), let civIdx = civIndex(cities[ci].civId), canPurchase(p, in: cities[ci]) else { return false }
        let civId = cities[ci].civId
        let cost = purchaseCost(p, for: civId, in: cities[ci])
        guard settings.godMode || civs[civIdx].gold >= Double(cost) else { return false }
        // The city screen buys its current construction without naming a position; that is position 0 there.
        let position: Int? = queuePosition ?? ((!fromList && cities[ci].currentProduction == p) ? 0 : nil)
        let workDoneBefore = workDone(p, in: cities[ci])
        switch p {
        case .building(let name):
            addBuilding(cityIndex: ci, name)   // Building.construct
        case .unit(let name):
            guard let spawned = spawnUnit(name, civId: civId, at: cities[ci].coord), let ui = unitIndex(spawned.id) else { return false }   // nothing built - no pay
            if !settings.godMode, rs.units[name]?.canMoveImmediatelyOnceBought != true { units[ui].movementLeft = 0 }
            if let c = city(cityId) { addConstructionBonuses(unitIndex: ui, city: c) }
            civs[civIdx].everEarnedUnits.insert(name)
        }
        if !settings.godMode {
            civs[civIdx].gold -= Double(cost); goldTrace(civId, -Double(cost))   // city.addStat(Gold, -cost)
            // Consume stockpiled resources - usually consumed when construction starts, but not when bought
            if workDoneBefore == 0 { payConstructionStockpileCosts(cityId: cityId, p) }
        }
        if GameState.evlogOn, let c = city(cityId) { ev(c.civId, "BUY", EvLog.name(c.name), EvLog.name(p.name), String(cost), "Gold") }
        guard let ci2 = cityIndex(cityId) else { return true }
        if let qp = position, combinedQueue(cities[ci2]).indices.contains(qp) {
            removeFromCombinedQueue(cityId: cityId, index: qp, automatic: automatic)   // removeFromQueue(queuePosition, automatic)
        }
        validateConstructionQueue(cityId: cityId)
        if let ci3 = cityIndex(cityId), cities[ci3].isQueueEmptyOrIdle {
            chooseNextConstructionIfAutomated(cityId: cityId)   // "A purchase should never leave the city idle"
        }
        return true
    }

    /// Unciv CityConstructions.chooseNextConstruction's gate: the construction automation runs for the AI, for a
    /// puppet, and for a human only with "auto-assign city production" (or while the game plays itself).
    func chooseNextConstructionIfAutomated(cityId: Int) {
        if constructionIsAutomated(cityId: cityId) { chooseNextConstruction(cityId: cityId) }
    }
    /// Unciv CityConstructions.chooseNextConstruction's gate: `(isCurrentPlayersTurn && (settings.autoAssignCityProduction ||
    /// autoPlay.isAutoPlayingAndFullAutoPlayAI())) || city.civ.isAI() || city.isPuppet` (CityConstructions.kt:833-838).
    func constructionIsAutomated(cityId: Int) -> Bool {
        guard let ci = cityIndex(cityId), let owner = civ(cities[ci].civId) else { return false }
        let automated = !owner.isPlayer || UserSettings.autoAssignCityProduction || autoPlayingFullAI || cities[ci].isPuppet
        if owner.isPlayer && GameState.evlogOn {
            hbr(cities[ci].isPuppet ? "C1.puppet" : UserSettings.autoAssignCityProduction ? "C1.autoAssign" : autoPlayingFullAI ? "C1.fullAI" : "C1.playerPicks", owner.id)
        }
        return automated
    }

    /// Unciv CityConstructions.validateConstructionQueue (+ validateInProgressConstructions, which our
    /// validateConstructions does in the same pass): it always ends in chooseNextConstruction().
    func validateConstructionQueue(cityId: Int) {
        validateConstructions(cityId: cityId)
        chooseNextConstructionIfAutomated(cityId: cityId)
        if GameState.evlogOn { EvLog.flushProduction() }   // EVLOG: Unciv evProdCheck at the end of validateConstructionQueue
    }

    /// Unciv CityConstructions.updateUniques (not on load): a building came or went, so the capital connections
    /// ("could be a connecting building, like a harbor"), the city's stats - and through them the empire's
    /// updateStatsForNextTurn - and the civ's resources are all brought up to date there and then.
    func buildingUniquesChanged(cityIndex ci: Int) {
        guard cities.indices.contains(ci) else { return }
        let civId = cities[ci].civId, cityId = cities[ci].id
        // Unciv updateUniques rebuilds builtBuildingUniqueMap first, and civ.getMatchingUniques reads every city's map
        // live - so the stats update below, and every city a happiness-level crossing refreshes inside it, already
        // sees this city's non-local uniques. Ours cleared the empire pool only later in addBuilding: long t_198,
        // Neuschwanstein's "[+1 Happiness] from every [Castle]" reached Graz and Genoa a pass late.
        civUniquesCache[civId] = nil
        updateCitiesConnectedToCapital(civId)
        updateCityStats(cityId, reason: "updateUniques")
        updateCivResources(civId)
    }

    /// Unciv CityConstructions.addBuilding, in its order: the health top-up against the max before the building,
    /// the building, updateUniques, CreatesOneImprovement, triggerNewBuildingUniques, the Korean science boost,
    /// reassignPopulationDeferred (and every other city when the happiness crossed a level that uniques read),
    /// then - unless the caller is itself handing out free buildings - CivConstructions.tryAddFreeBuildings.
    func addBuilding(cityIndex ci: Int, _ name: String, tryAddFreeBuildings tryFree: Bool = true) {
        guard cities.indices.contains(ci), let def = rs.buildings[name] else { return }
        let civId = cities[ci].civId, cityId = cities[ci].id
        if def.cityHealth > 0 {
            // Unciv: `city.health += (building.cityHealth.toFloat() * city.health.toFloat() / city.getMaxHealth().toFloat()).toInt()`
            cities[ci].health += Int(Float(def.cityHealth) * Float(cities[ci].health) / Float(max(1, cityMaxHealth(cities[ci]))))
        }
        // Unciv `builtBuildingObjects = builtBuildingObjects.withItem(building)` (an ArrayList: a second copy is kept)
        // and `builtBuildings.add(buildingName)` (a set)
        if !cities[ci].buildings.contains(name) { cities[ci].buildings.append(name) } else { cities[ci].duplicateBuildingObjects.append(name) }
        buildingUniquesChanged(cityIndex: ci)
        // Unciv applyCreateOneImprovement: the improvement appears on the tile the construction claimed
        for u in def.uniqueObjects where u.pattern == "Creates a [] improvement on a specific tile" {
            guard let c = self.city(cityId), let cx = cityIndex(cityId) else { break }
            let target = c.reservedImprovementTile ?? tileForCreatedImprovement(c, u.param(0))
            cities[cx].reservedImprovementTile = nil; cities[cx].reservedImprovement = ""
            // Unciv: removeCreatesOneImprovementMarker(removeConstruction = false), then
            // `tileForImprovement.setImprovement(improvement, city.civ)` - resource recount, the city's refresh, the
            // improvement's triggers and feature removal. We set the tile fields by hand.
            if let t = target {
                // the marker's queue is cleared (Unciv only for a marked tile: turnsToImprovement < 0)
                if c.reservedImprovementTile == t, var tile = map[t] { GameState.setImprovementQueue(&tile, []); map[t] = tile }
                removeCreatesOneImprovementMarker(at: t)
                setImprovement(at: t, u.param(0), civToActivateBroaderEffects: civId)
            }
        }
        // Unciv triggerNewBuildingUniques: the building's own triggerable uniques, then TriggerUponConstructingBuilding(CityFilter).
        // One pass in uniqueObjects (json) order - the National Intelligence Agency promotes its spies BEFORE it recruits
        // the extra one ("Order is significant here") - skipping a unique with a trigger conditional, each repeated
        // getUniqueMultiplier(city.state) times; triggerUniques checks conditionalsApply.
        guard let city = self.city(cityId) else { return }
        let newBuildingUniques = def.uniqueObjects.filter { ["Free [] appears", "[] free [] units appear", "Free Great Person", "Free Social Policy", "Free Technology", "[] Free Technologies", "Empire enters golden age", "Gain a free [] []", "Triggers a Cultural Victory upon completion", "Triggers a global alert upon completion", "Triggers voting for the Diplomatic Victory", "Provides the cheapest [] building in your first [] cities for free", "[] population []", "Promotes all spies [] time(s)", "Gain an extra spy"].contains($0.pattern) && !hasTriggerConditional($0) }
        triggerUniques(multiplied(newBuildingUniques, UniqueContext(civId: civId, city: city)), civId: civId, cityId: cityId, triggerText: "due to constructing [\(name)]")
        triggerConditionalUniques(civId: civId, cityId: cityId, triggerText: "due to constructing [\(name)]") { u in (u.pattern == "upon constructing []" && self.buildingMatches(name, u.param(0))) || (u.pattern == "upon constructing [] []" && self.buildingMatches(name, u.param(0)) && self.cityMatchesFilter(u.param(1), city: city, viewer: civId)) }
        // Unciv: `if (building.hasUnique(EnemyUnitsSpendExtraMovement)) civ.cache.updateHasActiveEnemyMovementPenalty()`
        if def.uniqueObjects.contains(where: { $0.pattern == GameState.enemyMovementPenaltyPattern }) { updateHasActiveEnemyMovementPenalty(civId) }
        if let cityNow = self.city(cityId) { techBoostForCapitalBuilding(civId: civId, city: cityNow, building: def) }   // Unciv applyKoreanUnique
        // Unciv: reassignPopulationDeferred, and every OTHER city of the civ when the happiness crossed a level
        guard let cx = cityIndex(cityId) else { return }
        invalidateHappiness(civId)
        let happinessBefore = happiness(of: civId)
        reassignPopulationDeferred(cx)
        let happinessAfter = happiness(of: civId)
        if happinessBefore != happinessAfter,
           rs.happinessLevelsThatAffectUniques.contains(where: { (happinessAfter < $0) != (happinessBefore < $0) }) {
            for i in cities.indices where cities[i].civId == civId && cities[i].id != cityId { reassignPopulationDeferred(i) }
        }
        if tryFree { tryAddFreeBuildings(civId) }
    }

    /// Unciv CityConstructions.removeBuilding: the building goes, a tile improvement it created goes with it, and
    /// updateUniques runs.
    func removeBuilding(cityIndex ci: Int, _ name: String) {
        guard cities.indices.contains(ci), cities[ci].builtBuildingObjects.contains(name) else { return }
        // Unciv `builtBuildingObjects.withoutItem(building)` drops the FIRST copy - the one `buildings` holds - and
        // `builtBuildings.remove(name)` the name: a second copy stays an object without a name. Removing the name
        // again finds only that copy.
        if cities[ci].buildings.contains(name) { cities[ci].buildings.removeAll { $0 == name } }
        else if let k = cities[ci].duplicateBuildingObjects.firstIndex(of: name) { cities[ci].duplicateBuildingObjects.remove(at: k) }
        if let def = rs.buildings[name] {
            for u in def.uniqueObjects where u.pattern == "Creates a [] improvement on a specific tile" {
                if let t = cities[ci].tiles.first(where: { map[$0]?.improvement == u.param(0) }) { removeImprovement(at: t) }   // Unciv tile.removeImprovement()
            }
        }
        buildingUniquesChanged(cityIndex: ci)
    }

    /// Returns false when a unit could not be placed (Unciv completeConstruction keeps the progress then). The "has been
    /// built" notifications and a wonder's WonderBuilt alert go into `notices`, for the caller to give once the construction
    /// has left the queue: Unciv completeConstruction runs removeCurrentConstruction (chooseNextConstruction, with its "has
    /// started working on") and validateConstructionQueue before them, so a human's list reads the new pick first.
    @discardableResult
    func completeProduction(cityId: Int, _ p: Production, notices: inout [() -> Void]) -> Bool {
        guard let ci = cityIndex(cityId) else { return false }
        let city = cities[ci]
        switch p {
        case .building(let name):
            // Unciv completeConstruction: `construction.construct(this)` → Building.construct → addBuilding, then the
            // queue bookkeeping and the notifications.
            addBuilding(cityIndex: ci, name)
            if let def = rs.buildings[name], let cityNow = self.city(cityId) {
                // Unciv completeConstruction: a wonder is announced to every civilization of the game in its order - the
                // builder too, under Production, the others under General - with the building's icon alone; any other
                // building, like a unit, only to the builder, with the Construction icon in front.
                let pedia = NotificationAction.civilopedia("\(def.isAnyWonder ? "Wonder" : "Building")/\(name)")
                notices.append { [self] in
                    if def.isWonder {
                        addAlert(cityNow.civId, .WonderBuilt, name)
                        for j in civs.indices {
                            if civs[j].explored.contains(cityNow.coord) {
                                notify(civs[j].id, "[\(name)] has been built in [\(cityNow.name)]", category: civs[j].id == cityNow.civId ? .Production : .General, icons: ["BuildingIcons/" + name], actions: [.location(cityNow.coord), pedia])
                            } else {
                                notify(civs[j].id, "[\(name)] has been built in a faraway land", category: .General, icons: ["BuildingIcons/" + name], actions: [pedia])
                            }
                        }
                    } else {
                        notify(cityNow.civId, "[\(name)] has been built in [\(cityNow.name)]", category: .Production, icons: ["StatIcons/Production", "BuildingIcons/" + name], actions: [.location(cityNow.coord), pedia])
                    }
                    // Unciv TriggersAlertOnCompletion: every other civilization of the game hears of it, by name if it knows the builder
                    if def.uniqueObjects.contains(where: { $0.pattern == "Triggers a global alert upon completion" && conditionalsHold($0, UniqueContext(civId: cityNow.civId, city: cityNow)) }) {
                        for j in civs.indices where civs[j].id != cityNow.civId {
                            let who = civs[j].metCivs.contains(cityNow.civId) ? "[\(civ(cityNow.civId)?.nation ?? "?")]" : "[An unknown civilization]"
                            notify(civs[j].id, "\(who) has completed [\(name)]!", category: .General, icons: ["StatIcons/Production", "BuildingIcons/" + name], actions: [pedia])
                        }
                    }
                }
            }
        case .unit(let name):
            var builtUnit: Unit? = nil
            if let spawned = spawnUnit(name, civId: city.civId, at: city.coord), let ui = unitIndex(spawned.id) {
                builtUnit = spawned
                if rs.units[name]?.isGreatPerson == true { notify(city.civId, "A [\(name)] has been born in [\(city.name)]!", category: .General, icons: [name], actions: [.unit(spawned.coord, spawned.id)]) }   // Unciv construct → addUnit
                if let cv = civIndex(city.civId) { civs[cv].everEarnedUnits.insert(name) }
                addConstructionBonuses(unitIndex: ui, city: city)
                applyDefaultPromotions(unitId: spawned.id, city: city)   // Unciv "Use default promotions"
            }
            else { notify(city.civId, "No space available to place [\(name)] near [\(city.name)]", category: .Production, icons: [name], coord: city.coord); return false }   // Unciv completeConstruction
            // Unciv: MapUnitAction(unit) and CivilopediaAction(construction.makeLink()), with NotificationIcon.Construction and the unit
            let actions: [NotificationAction] = (builtUnit.map { [NotificationAction.unit($0.coord, $0.id)] } ?? [.location(city.coord)]) + [.civilopedia("Unit/\(name)")]
            notices.append { [self] in notify(city.civId, "[\(name)] has been built in [\(city.name)]", category: .Production, icons: ["StatIcons/Production", name], actions: actions) }
        }
        if GameState.evlogOn { ev(city.civId, "PROD_DONE", EvLog.name(city.name), EvLog.name(p.name)) }
        return true
    }

    @discardableResult
    /// `caller` defaults to #function, which Swift resolves at the CALL SITE - so the trace names whatever
    /// created the unit (city production, a ruins reward, a city-state gift, a trigger) for free.
    /// Unciv CityConstructions.addProductionPoints (City.addStat for Production): the points go to the current
    /// construction, or - when the city builds nothing or a perpetual construction - to productionOverflow, which the
    /// next real construction starts with. Ours always added them to the current progress, so a forest chopped for a
    /// city between two builds lost its hammers (deity t=54, Orleans 24 where Unciv had 44).
    func addProductionPoints(cityIndex ci: Int, _ amount: Int) {
        if cities[ci].currentProduction == nil { cities[ci].productionOverflow += amount }
        else { cities[ci].productionStored += Double(amount) }
    }

    func spawnUnit(_ name: String, civId: Int, at c: HexCoord, caller: String = #function) -> Unit? {
        defer { if let i = units.indices.last, units[i].originalCiv == -1, units[i].civId == civId { units[i].originalCiv = civId } }
        guard let def = rs.units[name] else { return nil }
        // Unciv TileMap.placeUnitNearTile starts with `unit.assignOwner(civInfo, updateCivInfo = false)` → UnitManager.addUnit,
        // which turns the civ's list at nextPotentiallyDueAt - before the tile is looked for, so even a unit that finds no
        // place (and is removed again) leaves the list turned.
        rotateCivUnitsToNextDue(civId)
        if epochsDebug { let p = uncivPosition(c); print("SPAWN t=\(turn) \(civ(civId)?.nation ?? "?") \(name) at \(p.x),\(p.y) by=\(caller)") }
        var unit = Unit(id: newId(), civId: civId, name: name, coord: c, movementLeft: Double(def.movement))
        for p in def.promotions where rs.promotions[p] != nil && !unit.promotions.contains(p) { unit.promotions.append(p) }   // Unciv placeUnitNearTile: built-in promotions are free
        unit.numberOfPromotions = 0
        // Unciv TileMap.placeUnitNearTile has ONE path for every unit: try the tile it was given, and if the
        // unit cannot move there, walk outwards ring by ring over passable neighbours and take the first tile
        // it can move to - land tiles first, and only for a land unit that cannot cross water. We had a second,
        // invented path for ships: "the nearest water tile within two rings". Measured on `settled`, Carthage
        // builds a Quinquereme on a city tile that already holds an Archer, so neither engine can place it in
        // the city; Unciv's ring walk put it on -3,6 and our nearest-water search put it on -2,7.
        if !canUnitEnter(unit, c) {
            let restricted = !def.isWater && !(unit.def.uniques.contains("May travel on Water tiles without embarking") || unit.promotionUniques.contains { $0.pattern == "May travel on Water tiles without embarking" })   // Unciv isRestrictedLandUnit
            var checked: Set<HexCoord> = [c]
            var frontier = map.neighbors(of: c).filter { canPassThrough(unit, $0) }
            var placed: HexCoord? = nil
            var rounds = 0
            while placed == nil && rounds < 10 && !frontier.isEmpty {
                rounds += 1
                // Unciv TileCandidates: a land unit that cannot cross water keeps the land tiles in `primary`
                // and the rest in `secondary`, and `allTiles` is primary THEN secondary - which is the order
                // the next ring is grown from as well, not just the order the match is looked for in.
                let ordered = restricted ? (frontier.filter { map[$0]?.isLand == true } + frontier.filter { map[$0]?.isLand != true }) : frontier
                placed = ordered.first { canUnitEnter(unit, $0) }
                if placed != nil { break }
                checked.formUnion(ordered)
                // Unciv `.toSet()`: a tile reachable from two frontier tiles is kept once, at the position its
                // first arrival gave it (Kotlin's set preserves insertion order).
                var seen = Set<HexCoord>()
                frontier = ordered.flatMap { map.neighbors(of: $0) }
                    .filter { !checked.contains($0) && canPassThrough(unit, $0) && seen.insert($0).inserted }
            }
            guard let free = placed else { return nil }
            unit.coord = free
        }
        // Unciv placeUnitNearTile: `unit.currentMovement = unit.getMaxMovement().toFloat()` once the unit is on its tile
        // and BEFORE its promotions are added - the civ's "[+1] Movement <for [...] units>" counts (the Great
        // Lighthouse's Trireme sails 4 on its first turn), an embarked start counts 2, the built-in promotions not yet.
        var bare = unit; bare.promotions = []
        unit.movementLeft = maxMovement(of: bare)
        if def.isReligious || def.spreadCharges > 0 {
            unit.charges = def.spreadCharges
            // Unciv UnitManager.placeUnitNearTile: `unit.religion = religionManager.religion?.name` - the civ's religion,
            // a pantheon's included, nil with neither. Then UnitManager.addUnit, for a unit born in a city (ours spawn
            // on the city's tile): the birth city's majority religion `if (!TakeReligionOverBirthCity ||
            // religion?.isMajorReligion() == false)` - a civ with no religion at all compares null to false, and its
            // Great Prophet keeps no religion. Ours gave that prophet the birth city's majority religion, which could
            // be a foreign one it then spread.
            let takesCivReligion = def.uniques.contains("Takes your religion over the one in their birth city")
            let civReligion = civ(civId).flatMap { $0.religionName ?? $0.pantheonBelief }
            unit.religion = civReligion
            if let birthCity = city(at: c), !takesCivReligion || (civReligion != nil && !religionIsMajor(civReligion)) {
                unit.religion = majorityReligion(of: birthCity)
            }
        }
        for u in def.uniqueObjects where u.pattern == "[] gets a name from the [] group" {
            if let names = rs.unitNameGroups[u.param(1)] {
                let free = names.filter { !unitNamesTaken.contains($0) }   // Unciv: only names not yet used
                // Unciv OneTimeUnitGetsName: `if (pair == null) return null` - a group with no free name left gives
                // no name, takes none and draws nothing (rng.pick of an empty list does not draw)
                if let picked = rng.pick(free) { unit.customName = picked; unitNamesTaken.insert(picked) }
            }
        }
        // Nation traits such as "[{Military} {Land}] units gain the [Amphibious] promotion"
        for u in civUniques(civId) where u.pattern == "[] units gain the [] promotion" && unitMatches(unit, u.param(0)) && rs.promotions[u.param(1)] != nil && !unit.promotions.contains(u.param(1)) {
            unit.promotions.append(u.param(1))
        }
        units.append(unit)
        // Unciv TileMap.placeUnitNearTile: `unit.putInTile(tile)` ends in moveThroughTile - the entering-tile
        // triggers, a camp or ruins on the tile, an UNGUARDED ENEMY CIVILIAN captured, terrain promotions, vision.
        // Ours ran those only for a unit that walked in: a prize ship placed on the tile of the Galleass it sank
        // left the Great General there alive (t_45 turn 154), where Unciv's placement destroyed it.
        moveThroughTile(unit.id, unit.coord)
        // EVLOG: Unciv logs UNIT_ADD right after putInTile, so a civilian the new unit captured there comes first
        if GameState.evlogOn { evUnitAdd(unit) }
        guard let unit = self.unit(unit.id) else { return nil }
        if let last = units.indices.last { units[last].addMovementMemory() }   // Unciv UnitManager.addUnit: the movement arrow starts here
        // No civ-wide view refresh here: Unciv's placement refreshes the civ's view only through putInTile →
        // moveThroughTile → updateVisibleTiles (and addPromotion's, the view unchanged by then), i.e. when the new unit
        // sees past ourTilesAndNeighboringTiles (revealFromCurrentTile above). Ours refreshed it after every placement,
        // so a civ met through some other change of its view was met at the unit's birth: a test game, t=106
        // Denmark heard "We have encountered [Byzantium]!" before "A [Great Prophet] has been born in [Copenhagen]!",
        // where Unciv meets Byzantium at TurnManager.startTurn's updateViewableTiles after the prophet (TurnManager.kt:63).
        // Unciv TileMap.placeUnitNearTile, and only once the unit really has a tile - the early returns above
        // are the ones where it "didn't actually create a unit", and ours updated the empire's stats on those
        // too, from a `defer` that fired on every exit.
        // It ends there with updateStatsForNextTurn and, for a unit that needs resources, updateCivResources -
        // and only AFTER that does UnitManager.placeUnitNearTile fire the gaining triggers, then update the
        // resources once more. Ours fired the triggers first, so a "<upon gaining a [..] unit>" effect read the
        // upkeep and the supply from before the unit existed.
        updateStatsForNextTurn(civId)   // "the new unit changes both unit upkeep and resource consumption"
        let needsResources = !resourceRequirementsPerTurn(requiredResource: def.requiredResource, uniques: def.uniqueObjects, ctx: UniqueContext(civId: civId, unit: unit)).isEmpty
        if needsResources { updateCivResources(civId) }
        unitGainedTriggers(unit)
        if needsResources { updateCivResources(civId) }   // Unciv UnitManager.placeUnitNearTile, after the triggers
        // Unciv UnitManager.placeUnitNearTile, next: `forEachMatchingUnique(LandUnitsCrossTerrainAfterUnitGained,
        // unit.cache.state) { if (unit.matchesFilter(params[1])) passableImpassables.add(params[0]) }` - every placement
        // counts (a city-state's gift, a free great person, a trigger), not only a unit built, bought or earned.
        if let ci = civIndex(civId) {
            let gained = self.unit(unit.id) ?? unit
            for q in civUniques(civId) where q.pattern == "Land units may cross [] tiles after the first [] is earned"
                && conditionalsHold(q, UniqueContext(civId: civId, unit: gained)) && unitMatches(gained, q.param(1)) {
                civs[ci].everEarnedUnits.insert(q.param(1))
            }
        }
        return unit
    }

    /// Unciv UnitManager.getCivUnitsStartingAtNextDue, as addUnit and removeUnit rebuild `unitList` from it:
    /// `unitList.subList(nextPotentiallyDueAt, size) + unitList.subList(0, nextPotentiallyDueAt)`, then
    /// `nextPotentiallyDueAt = 0`. Only the human's "Next unit" button moves the index, so an AI's list never turns.
    /// Our civ's list is `units(of:)`, the global array filtered: the civ's units swap places among their own slots
    /// and the other civs' units stay where they are. `excluding`: a unit already handed to this civ that Unciv
    /// has not added to its list yet (a gifted carrier while its aircraft go first).
    func rotateCivUnitsToNextDue(_ civId: Int, excluding: Int? = nil) {
        let k = nextPotentiallyDueAt[civId] ?? 0
        guard k != 0 else { return }
        nextPotentiallyDueAt[civId] = 0
        let slots = units.indices.filter { units[$0].civId == civId && units[$0].id != excluding }
        guard !slots.isEmpty else { return }
        let from = k % slots.count   // Unciv's index is always below the list size (the button stores `% size`)
        let turned = (Array(slots[from...]) + Array(slots[..<from])).map { units[$0] }
        var all = units
        for (j, slot) in slots.enumerated() { all[slot] = turned[j] }
        units = all
    }

    /// Unciv UnitManager.addUnit: TriggerUponGainingUnit (unit filter), depth-limited.
    func unitGainedTriggers(_ unit: Unit) {
        guard triggerDepth < 3 else { return }
        triggerDepth += 1
        defer { triggerDepth -= 1 }
        triggerConditionalUniques(civId: unit.civId, unitId: unit.id) { $0.pattern == "upon gaining a [] unit" && self.unitMatches(unit, $0.param(0)) }
    }

    // MARK: unit orders
    /// Unciv `unit.automated = on` - the flag alone, the action (our order) left as it is
    func setAutomated(unitId: Int, _ on: Bool = true) {
        guard let ui = unitIndex(unitId) else { return }
        units[ui].automated = on
        if !on && units[ui].order == .automate { units[ui].order = .none }
    }
    func setOrder(unitId: Int, _ order: UnitOrder) {
        guard let ui = unitIndex(unitId) else { return }
        units[ui].order = order
        // Unciv keeps being set up in the same `action` field (isSetUpForSiege: `action == SetUp`), so Sleep, Fortify
        // (fortify()), Guard, Explore and a move order each overwrite it: a set-up unit that sleeps must set up again.
        switch order {
        case .sleep, .sleepUntilHealed, .fortify, .fortifyUntilHealed, .guardPost, .explore, .moveTo: units[ui].isSetUp = false
        default: break
        }
        if case .build(let imp) = order {
            var tile = map[units[ui].coord]!
            if tile.improvementInProgress != imp {
                tile.improvementInProgress = imp
                tile.queuedImprovement = nil; tile.queuedImprovementTurns = 0
                payImprovementStockpileCosts(imp, unit: units[ui])   // Unciv Tile.startWorkingOnImprovement
                tile.improvementTurnsLeft = imp == "Repair" ? repairTurns(units[ui]) : improvementBuildTurns(imp, unit: units[ui])   // Unciv Tile.queueImprovement: god mode = 1 turn
                map[units[ui].coord] = tile
            }
            // Unciv Tile.startWorkingOnImprovement (ve ImprovementPickerScreen.accept ile
            // WorkerAutomation.startWorkOnCurrentTile) işe başlarken hareket harcamaz. Biz
            // harcıyorduk, bu da UnitTurnManager.endTurn'ün "hareketi kalmışsa çalış" koşulunu
            // başlangıç turunda düşürüyor ve her iyileştirme bir tur geç bitiyordu.
        }
    }

    /// Unciv ImprovementPickerScreen.accept(removal, improvement): start the removal and queue the improvement after it
    /// (nothing is queued when that removal is already in progress).
    func setOrderWithQueuedImprovement(unitId: Int, first: String, then second: String) {
        guard let u = unit(unitId) else { return }
        let alreadyInProgress = map[u.coord]?.improvementInProgress == first
        setOrder(unitId: unitId, .build(first))
        guard !alreadyInProgress, let u2 = unit(unitId) else { return }
        map[u2.coord]?.queuedImprovement = second
        let turns = settings.godMode ? 1 : improvementBuildTurns(second, unit: u2)   // worked out before the write: `map[..]?.x = f()` evaluates f with `map` held for writing
        map[u2.coord]?.queuedImprovementTurns = turns
    }

    /// Unciv Tile.stopWorkingOnImprovement ("Cancel improvement order"): the improvement queue is cleared.
    func stopWorkingOnImprovement(at c: HexCoord) {
        map[c]?.improvementInProgress = nil; map[c]?.improvementTurnsLeft = 0
        map[c]?.queuedImprovement = nil; map[c]?.queuedImprovementTurns = 0
        for i in units.indices where units[i].coord == c { if case .build = units[i].order { units[i].order = .none } }
    }

    /// Unciv MapUnit.disband: the aircraft it carries stay in a city or fly to the first tile within twice their
    /// range they can move to (disbanded when out of fuel or nowhere to go), then destroy(); inside our own
    /// borders the civ gets BaseUnit.getDisbandGold back, and a civ left with nothing is destroyed.
    func disband(unitId: Int) {
        guard let u = unit(unitId) else { return }   // Safeguard against running on already destroyed instances
        // evacuation of transported units before disbanding, if possible
        let carried = carrierCapacity(u) > 0
            ? units.filter { $0.id != unitId && $0.coord == u.coord && $0.isTransported && canBeCarried($0, by: u) }.map { $0.id }
            : []
        for pid in carried {
            guard let p = unit(pid) else { continue }
            // if we disbanded a unit carrying other units in a city, the carried units can still stay in the city
            if map[u.coord]?.isCityCenter == true && canMoveTo(p, u.coord) {
                if let pi = unitIndex(pid) { units[pi].isTransported = false }
                continue
            }
            // if no "fuel" to escape, should be disbanded as well
            if Float(p.movementLeft) < Float(GameState.minimumMovementEpsilon) { disband(unitId: pid); continue }
            // let's find closest city or another carrier where it can be evacuated
            if let to = map.tilesWithin(p.coord, radius: airRange(p) * 2).first(where: { $0 != u.coord && canMoveTo(p, $0) }) {
                moveToTile(pid, to)
            } else {
                disband(unitId: pid)
            }
        }
        destroyUnit(unitId)
        // Unciv: if (currentTile.getOwner() == civ) civ.addGold(baseUnit.getDisbandGold(civ))
        if map[u.coord]?.ownerCivId == u.civId { addGold(u.civId, disbandGold(u.def, civId: u.civId)) }
        if let c = civ(u.civId), c.isAlive, isDefeated(c) { destroyCiv(c.id) }   // civ.destroy()
    }

    /// Unciv City.getMaxHealth: 200 + the buildings' city health
    func cityMaxHealth(_ city: City) -> Int { City.maxHealth + city.builtBuildingObjects.reduce(0) { $0 + (rs.buildings[$1]?.cityHealth ?? 0) } }   // getBuiltBuildings()

    /// Cities (other than the capital) linked to the capital by roads, or by harbours across water.
    /// A tile is blockaded when an enemy military unit stands on it, or it is water next to an enemy warship.
    func isBlockaded(_ c: HexCoord, for civId: Int) -> Bool {
        guard let owner = map[c]?.ownerCivId else { return false }   // Unciv Tile.isBlockaded: an unowned tile is never blockaded
        // Unciv: the tile's own military unit decides alone - ours or a neutral one unblocks it, an enemy blocks
        // it - and only an empty tile goes on to the neighbours. Ours checked the neighbours under our own
        // unit too (t_45 turn 90, tile buying on: a Byzantine dromon stood on Nicaea's -1,-7, an enemy ship lay
        // beside it, and Nicaea lost the tile the reference kept working).
        if let unit = units(at: c).first(where: { $0.isMilitary && !$0.def.isAir }) { return unit.civId != owner && areAtWar(owner, unit.civId) }
        guard map[c]?.isWater == true else { return false }
        // enemy military units on adjacent water tiles, not embarked
        return map.neighbors(of: c).contains { n in
            guard map[n]?.isWater == true, let u = units(at: n).first(where: { $0.isMilitary && !$0.def.isAir }) else { return false }
            return u.civId != owner && areAtWar(owner, u.civId) && !isEmbarked(u)
        }
    }

    /// A coastal city is blockaded when every adjacent water tile is blockaded.
    func isCityBlockaded(_ city: City) -> Bool {
        let water = map.neighbors(of: city.coord).filter { map[$0]?.isWater == true }
        return !water.isEmpty && water.allSatisfy { isBlockaded($0, for: city.civId) }
    }

    /// Unciv CityTurnManager: We Love The King Day. The ResourceDemand cooldown (15+rand10 turns, +10 for a new capital) picks a luxury the
    /// civ lacks that exists on the map and is not near the city; owning it starts a 20×speed celebration, whose end demands a new one.
    /// Unciv CityTurnManager.startTurn: `if (!hasFlag(WeLoveTheKing)) tryWeLoveTheKing()`, then nextTurnFlags - the
    /// resistance countdown included.
    func updateDemands(cityId: Int) {
        guard let ci = cityIndex(cityId) else { return }
        let civId = cities[ci].civId
        // tryWeLoveTheKing
        if cities[ci].wltkdTurns == 0, !cities[ci].demandedResource.isEmpty, (resourceCounts(civId)[cities[ci].demandedResource] ?? 0) > 0 {
            cities[ci].wltkdTurns = Int((20 * speed.modifier).rounded()) + 1
            cities[ci].resourceDemandCooldown = -1
            notify(civId, "Because they have [\(cities[ci].demandedResource)], the citizens of [\(cities[ci].name)] are celebrating We Love The King Day!", category: .General, icons: ["City", "Happiness"], actions: [.location(cities[ci].coord), .city(cities[ci].coord)])   // CityAction.withLocation
        }
        // nextTurnFlags: `for (flag in city.flagsCountdown.keys.toList())` - a HashMap<String, Int>, so the flags come in
        // bucket order, Resistance (0), WeLoveTheKing (10), ResourceDemand (11), and only the flags present when the
        // walk starts are counted down (a ResourceDemand set by the celebration's end waits for the next turn).
        let hasResistance = cities[ci].resistanceTurns > 0
        let hasWeLoveTheKing = cities[ci].wltkdTurns > 0
        let hasResourceDemand = cities[ci].resourceDemandCooldown >= 0
        if hasResistance {
            cities[ci].resistanceTurns -= 1
            if cities[ci].resistanceTurns == 0 {
                cities[ci].shouldReassignPopulation = true
                notify(civId, "The resistance in [\(cities[ci].name)] has ended!", category: .General, icons: ["StatIcons/Resistance"], actions: [.location(cities[ci].coord), .city(cities[ci].coord)])   // CityAction.withLocation
            }
        }
        if hasWeLoveTheKing {
            cities[ci].wltkdTurns -= 1
            if cities[ci].wltkdTurns == 0 {
                notify(civId, "We Love The King Day in [\(cities[ci].name)] has ended.", category: .General, icons: ["City"], actions: [.location(cities[ci].coord), .city(cities[ci].coord)])
                demandNewResource(cityIndex: ci)
            }
        }
        if hasResourceDemand {
            if cities[ci].resourceDemandCooldown > 0 { cities[ci].resourceDemandCooldown -= 1 }
            if cities[ci].resourceDemandCooldown == 0 {
                cities[ci].resourceDemandCooldown = -1
                if cities[ci].wltkdTurns == 0 { demandNewResource(cityIndex: ci) }
            }
        }
    }

    /// Unciv CityTurnManager.startTurn, last: "Seed resource demand countdown" -
    /// `if (demandedResource == "" && !hasFlag(ResourceDemand)) setWltkResourceDemandCooldown(true)`.
    func seedResourceDemand(cityId: Int) {
        guard let ci = cityIndex(cityId) else { return }
        if cities[ci].demandedResource.isEmpty && cities[ci].resourceDemandCooldown < 0 { setWltkResourceDemandCooldown(cityIndex: ci, isNewCity: true) }
    }

    private func setWltkResourceDemandCooldown(cityIndex ci: Int, isNewCity: Bool) {
        // Unciv CityTurnManager.kt:74-76: `city.state.stateBasedRandom("CityTurnManager.setWltkResourceDemandCooldown")`, `15 + rng.nextInt(10)`
        var g = stateBasedRandom("CityTurnManager.setWltkResourceDemandCooldown", city: cities[ci])
        var duration = 15 + g.nextInt(below: 10)
        if isNewCity && cities[ci].isCapital { duration += 10 }
        if let w = ProcessInfo.processInfo.environment["WLTK_CITY"], cities[ci].name == w {
            print("WLTKE t=\(turn) \(cities[ci].name) setCooldown new=\(isNewCity) dur=\(duration) id=\(cities[ci].uncivId) hash=\(contextHash(UniqueContext(civId: cities[ci].civId, city: cities[ci], tile: map[cities[ci].coord]))) cities=\(cities(of: cities[ci].civId).count)")
        }
        // Unciv City.setFlag(flag, amount, adjustWithGameSpeed = true): the ResourceDemand countdown is
        // `(amount * speed.modifier).roundToInt()`, and CityTurnManager passes `true` for it. We stored the
        // raw draw. Measured on `fresh`, Sparta: both engines drew the same 22 from the same seed, Unciv put
        // 15 on the flag and we put 22, so Unciv demanded its luxury seven turns before we did and was
        // celebrating (+25% food) through the turns we were not.
        cities[ci].resourceDemandCooldown = Int((Double(duration) * speed.modifier).rounded())
    }

    private func demandNewResource(cityIndex ci: Int) {
        let city = cities[ci]
        let onMap = Set(map.tiles.compactMap { $0.resource })
        let nearby = Set(map.tilesWithin(city.coord, radius: rs.constants.cityWorkRange).compactMap { map[$0]?.resource })
        let candidatesUnordered = rs.resources.values.filter {
            $0.resourceType == "Luxury" && !$0.uniques.contains("Can only be created by Mercantile City-States") && $0.name != city.demandedResource && onMap.contains($0.name) && !nearby.contains($0.name)
        }
        // Unciv iterates `ruleset.tileResources.values` - the JSON's own order - and picks by index with
        // `randomOrNull(rng)`. Sorting by name here drew the same index out of a differently ordered list.
        let order = Dictionary(uniqueKeysWithValues: rs.resourceOrder.enumerated().map { ($1, $0) })
        let candidates = candidatesUnordered.sorted { (order[$0.name] ?? Int.max) < (order[$1.name] ?? Int.max) }
        let owned = resourceCounts(city.civId)
        let missing = candidates.filter { (owned[$0.name] ?? 0) <= 0 }
        // Unciv CityTurnManager.kt:133: `city.state.stateBasedRandom("CityTurnManager.demandNewResource")` — iki secim de AYNI uretecten.
        var g = stateBasedRandom("CityTurnManager.demandNewResource", city: city)
        if missing.isEmpty { cities[ci].demandedResource = g.pick(candidates)?.name ?? ""; return }   // hooray happy day forever!
        cities[ci].demandedResource = g.pick(missing)?.name ?? ""
        setWltkResourceDemandCooldown(cityIndex: ci, isNewCity: false)
        if !cities[ci].demandedResource.isEmpty { notify(city.civId, "[\(city.name)] demands [\(cities[ci].demandedResource)]!", category: .General, icons: ["City", "ResourceIcons/" + cities[ci].demandedResource], actions: [.location(city.coord), .overview("Resources", "")]) }
    }

    /// The civ's own cities, other than the capital, in the stored connection map (live until the first update).
    func connectedCities(_ civId: Int) -> [City] {
        guard let cap = capital(of: civId) else { return [] }
        let connected = Set(civ(civId)?.citiesConnectedToCapital ?? findCitiesConnectedToCapital(civId))
        return cities(of: civId).filter { $0.id != cap.id && connected.contains($0.id) }
    }

    /// Unciv Civilization.isCapitalConnectedToCity: `cache.citiesConnectedToCapitalToMediums.keys.contains(city)` - the
    /// STORED map, which reaches other civs' cities too (a city-state capital counts), and holds the capital itself.
    func isCapitalConnected(to city: City, civId: Int) -> Bool {
        (civ(civId)?.citiesConnectedToCapital ?? findCitiesConnectedToCapital(civId)).contains(city.id)
    }

    /// Unciv CapitalConnectionsFinder.find: every city whose borders we may enter is a node on the route.
    /// `useHarbours: false` answers Unciv's Road and Railroad mediums alone. A harbour hop carries a trade route
    /// but no road, so the worker AI - which asks where roads are still needed - must not count it as one.
    func capitalConnectionReach(_ civId: Int, useHarbours: Bool = true) -> Set<HexCoord> {
        guard let cap = capital(of: civId) else { return [] }
        var reached: Set<HexCoord> = [cap.coord]
        var frontier = [cap.coord]
        let reachableCities = cities.filter { $0.civId == civId || mayCrossOwner($0.civId, for: civId) }
        let cityCoords = Set(reachableCities.map { $0.coord })
        let forestRoads = forestsConnectCities(civId)
        // Unciv CapitalConnectionsFinder: roads carry a trade route only once their technology is researched
        let roadsUsable = rs.improvements["Road"]?.techRequired.map { civ(civId)?.techs.contains($0) == true } ?? true
        func mayCross(_ owner: Int?) -> Bool {
            guard let owner, owner != civId else { return true }
            return mayCrossOwner(owner, for: civId)
        }
        // Unciv links harbours through water, so label the bodies of water once and compare them
        var waterBody: [HexCoord: Int] = [:]
        var bodies = 0
        for t in map.tiles where t.isWater && waterBody[t.coord] == nil {
            bodies += 1
            waterBody[t.coord] = bodies
            var queue = [t.coord]
            while let c = queue.popLast() {
                for n in map.neighbors(of: c) where waterBody[n] == nil && map[n]?.isWater == true { waterBody[n] = bodies; queue.append(n) }
            }
        }
        func harbourWaters(_ c: HexCoord) -> Set<Int> { Set(map.neighbors(of: c).compactMap { waterBody[$0] }) }
        func hasHarbour(_ c: City) -> Bool { c.buildings.contains { rs.buildings[$0]?.uniques.contains("Connects trade routes over water") == true || $0 == "Docks" } }
        // Unciv CapitalConnectionsFinder.checkHarbor: the BFS may START at any reached city with a harbour...
        let harbourSources = Set(reachableCities.filter(hasHarbour).map { $0.coord })
        // ...but its cityFilter is `city.civ == civInfo && city.containsHarbor() && !city.isBlockaded()`,
        // so only our own unblockaded harbours are actually reached over water.
        let harbourCities = Set(reachableCities.filter { c in c.civId == civId && !isCityBlockaded(c) && hasHarbour(c) }.map { $0.coord })
        while let cur = frontier.popLast() {
            for n in map.neighbors(of: cur) where !reached.contains(n) {
                guard let t = map[n] else { continue }
                guard mayCross(t.ownerCivId) else { continue }
                if (roadsUsable && t.roads && !t.roadPillaged) || cityCoords.contains(n) || (forestRoads && tileIsFriendlyForestRoad(t, civId: civId)) { reached.insert(n); frontier.append(n) }
            }
            // Unciv CapitalConnectionsFinder: a harbour reaches the harbours that sit on the same body of water
            if useHarbours, harbourSources.contains(cur) {
                let ours = harbourWaters(cur)
                for h in harbourCities where !reached.contains(h) && !ours.isDisjoint(with: harbourWaters(h)) { reached.insert(h); frontier.append(h) }
            }
        }
        return reached
    }

    /// Unciv: the route may pass through our own land, an open-borders partner, or a city-state we are not fighting.
    func mayCrossOwner(_ owner: Int, for civId: Int) -> Bool {
        if owner == civId { return true }
        guard let other = civ(owner), !other.isBarbarian, !areAtWar(civId, owner) else { return false }
        return other.isCityState || hasOpenBorders(civId, in: owner)
    }

    /// Unciv City.destroyCity, in its order: the aircraft in the centre, the spies (before the tiles are let go),
    /// every tile relinquished through relinquishOwnership (each one updating the owner's tiles and the city's
    /// stats), the capital moved on WHILE the city is still in the list, then the city leaves the list, the centre
    /// becomes City ruins and the units that may not stay there are moved off. The notification belongs to the
    /// caller (the razing turn says "razed to the ground", a destroying unit "We have destroyed").
    func destroyCity(cityId: Int, overrideSafeties: Bool = false) {
        guard let ci0 = cityIndex(cityId) else { return }
        // Original capitals and holy cities cannot be destroyed, unless captured by a one-city-challenger.
        if !canBeDestroyed(cities[ci0]) && !overrideSafeties { return }
        let city = cities[ci0]
        for u in units(at: city.coord) where u.def.isAir { destroyUnit(u.id) }   // Destroy planes stationed in city
        spiesFlee(fromCity: cityId, cityName: city.name, reason: .destroyed)   // removeAllPresentSpies(CityDestroyed)
        for t in uncivTileWalk(city) {
            if t != city.coord { relinquishOwnership(cityId: cityId, t); continue }
            // The centre goes through relinquishOwnership in its place in the walk, as every other tile does; ours
            // refuses the centre (a standing city never lets it go), so its steps run here: the tile leaves the
            // city, any city of the civ working it places that citizen again, the marker goes, the owner is
            // cleared, then updateOurTiles and the city's stats - which from here on count no centre.
            guard let cc = cityIndex(cityId) else { continue }
            let civId = cities[cc].civId
            cities[cc].tilesWithoutItem(t, walk: uncivTileWalk(cities[cc]))   // `city.tiles = city.tiles.withoutItem(tile.position)`
            cities[cc].lockedTiles.remove(t)
            for other in cities(of: civId) where other.workedTiles.contains(t) {
                stopWorkingTile(cityId: other.id, t)
                assignWorkers(cityId: other.id, onlyFreePopulation: true, why: "destroyCity")
            }
            removeCreatesOneImprovementMarker(at: t)
            map[t]?.ownerCivId = nil; map[t]?.workingCityId = nil
            if map[t]?.roads == true { map[t]?.roadOwner = nil }   // Tile.setOwningCity(null): "Razing City! Remove owner"
            updateOurTiles(civId)
            invalidateHappiness(civId)
            updateCityStats(cityId, reason: "destroyCity")
        }
        guard let ci = cityIndex(cityId) else { return }
        // A worked tile can belong to a neighbouring city; Unciv derives "worked" from the cities still in play, so
        // once this one is gone nothing it worked stays taken. Ours kept the id: Kagoshima never saw Kyoto's iron.
        for t in cities[ci].workedTiles where map[t]?.workingCityId == cityId { map[t]?.workingCityId = nil }
        // Move the capital if destroyed - before the city leaves the list (a puppet may be annexed, see Unciv #8337)
        if cities[ci].isCapital { moveCapitalToNextLargest(civId: city.civId, oldCapital: nil) }
        guard let cx = cityIndex(cityId) else { return }
        destroyedCitySnapshots[cityId] = cities[cx]   // a razed city lives on in every lazy neighboringCities list that has it
        unregisterCity(cityId)   // civ.cities -= city
        cities.remove(at: cx)
        map[city.coord]?.cityId = nil
        if rs.improvements["City ruins"] != nil { map[city.coord]?.improvement = "City ruins" }
        // Edge case: a water unit in a razed city has to return to the water
        for u in units(at: city.coord) where !canPassThrough(u, u.coord) { teleportToClosestMoveableTile(u.id) }
        updateProximityAfterDestroying(city.civId)   // Unciv destroyCity: "Update proximity rankings for all civs"
        invalidateHappiness()
    }

    /// Unciv City.canBeDestroyed: capitals and holy cities only with the "Allow raze capital" / "Allow raze holy city" mod options.
    func canRaze(_ city: City) -> Bool {
        guard !city.razing, !settings.noCityRazing else { return false }   // Unciv City.canBeDestroyed
        let allowRazeCapital = rs.modOptionUniques.contains { $0.pattern == "Allow raze capital" }
        if city.isOriginalCapital && !allowRazeCapital { return false }
        if city.isCapital && !allowRazeCapital { return false }
        if city.isHolyCity && !rs.modOptionUniques.contains(where: { $0.pattern == "Allow raze holy city" }) { return false }
        return true
    }

    /// Unciv TileImprovement.getTurnsToBuild: "[]% construction time for [improvementFilter] improvements" from the unit and its civ.
    /// Unciv TileImprovement.getTurnsToBuild: "Can build [] improvements at a []% rate" sums into one percentage that divides the time.
    func improvementRateIncrease(_ unit: Unit, _ imp: String) -> Double {
        let sum = (unit.promotionUniques + civUniques(unit.civId)).filter { u in
            u.pattern == "Can build [] improvements at a []% rate" && (u.param(0) == "all" || u.param(0) == "All" || improvementMatches(imp, u.param(0)))
        }.reduce(0.0) { $0 + $1.double(1) }
        return max(0.01, 1 + sum / 100)
    }

    /// Unciv CityConstructions.getTileForImprovement: a tile of ours that can take the improvement and does not have it.
    func tileForCreatedImprovement(_ city: City, _ improvement: String) -> HexCoord? {
        guard let civ = civ(city.civId) else { return nil }
        return city.tiles.filter { c in
            guard let t = map[c], !t.isCityCenter, t.improvement != improvement else { return false }
            return rs.improvements[improvement].map { canBuildImprovement($0, on: t, civId: civ.id) } ?? false   // Unciv canBuildImprovement(improvement, city.state)
        }.sorted { ($0.q, $0.r) < ($1.q, $1.r) }.first
    }

    func improvementTimeMultiplier(_ unit: Unit, _ imp: String) -> Double {
        return (unit.promotionUniques + civUniques(unit.civId)).filter { u in
            u.pattern == "[]% construction time for [] improvements" && improvementMatches(imp, u.param(1))
        }.reduce(1.0) { $0 * max(0, 1 + $1.double(0) / 100) }
    }

    /// Unciv City.annexCity → CityConquestFunctions.annexCity
    func annex(cityId: Int) { annexCity(cityId: cityId) }

    /// Unciv CityConquestFunctions.puppetCity ends in `city.cityStats.update()` - a puppet loses its science
    /// and culture to the puppet penalty the moment it becomes one, and the empire's sum has to see that.
    func puppet(cityId: Int) { if let ci = cityIndex(cityId) { cities[ci].isPuppet = true; cities[ci].currentProduction = nil; chooseNextConstruction(cityId: cityId); invalidateHappiness(cities[ci].civId); updateCityStats(cityId, reason: "CityConstructions:75070") } }

    func setRazing(cityId: Int, _ on: Bool) { guard !settings.noCityRazing || !on else { return }; if let ci = cityIndex(cityId) { cities[ci].razing = on } }
}


/// Unciv CityScreenConstructionMenu actions: reorder queues, add/remove in every city, and disable constructions per city or empire-wide.
extension GameState {
    private func candidateCities(_ civId: Int) -> [City] { cities(of: civId).filter { !$0.isPuppet && $0.resistanceTurns == 0 && !$0.razing } }

    func queueIndex(cityId: Int, of p: Production) -> Int? { city(cityId)?.productionQueue.firstIndex(of: p) }
    /// Unciv CityConstructions.constructionQueue: the current construction is entry 0
    func combinedQueue(_ city: City) -> [Production] { (city.currentProduction.map { [$0] } ?? []) + city.productionQueue }
    func setCombinedQueue(_ ci: Int, _ list: [Production]) {
        cities[ci].currentProduction = list.first
        cities[ci].productionQueue = Array(list.dropFirst())
    }
    /// Unciv CityConstructions.canAddToQueue: room left (queueMaxSize 10 including the current entry and a trailing
    /// perpetual), buildable, a building only once
    func canAddToQueue(_ p: Production, in city: City) -> Bool {
        let list = combinedQueue(city)
        guard !isQueueFull(city), canProduce(p, in: city) else { return false }
        if case .building = p, list.contains(p) { return false }
        return true
    }
    /// Unciv CityConstructions.isQueueFull: `constructionQueue.size >= queueMaxSize` - the perpetual entry counts
    func isQueueFull(_ city: City) -> Bool { combinedQueue(city).count + (city.convertProductionTo.isEmpty ? 0 : 1) >= 10 }
    /// Unciv CityConstructions.canAddToQueue for a PerpetualConstruction: room left and isBuildable - a stat conversion
    /// the civ may use in this city (StatConversion.isBuildable), or Idle, which always is
    func canAddPerpetualToQueue(_ name: String, in city: City) -> Bool {
        !isQueueFull(city) && (name == City.idleConstruction || productionConversions(for: city.civId, city: city).contains(name))
    }
    /// Unciv CityConstructions.addToQueue(construction) for a PerpetualConstruction: an empty or idle queue starts it, a
    /// trailing perpetual is replaced, otherwise it goes last - ours is convertProductionTo in every case; the player set it
    func addPerpetualToQueue(cityId: Int, _ name: String) {
        guard let ci = cityIndex(cityId), canAddPerpetualToQueue(name, in: cities[ci]) else { return }
        cities[ci].convertProductionTo = name
        cities[ci].currentConstructionIsUserSet = true
    }
    /// Unciv CityConstructions.addToQueue(construction, addToTop): an empty or idle queue starts it (setCurrentConstruction
    /// replaces Idle's "Nothing"), addToTop makes it the current construction, otherwise it goes last - before a trailing
    /// perpetual, which ours keeps in convertProductionTo; the player set it either way
    func addToQueue(cityId: Int, _ p: Production, addToTop: Bool = false) {
        guard let ci = cityIndex(cityId), canAddToQueue(p, in: cities[ci]) else { return }
        var list = combinedQueue(cities[ci])
        if list.isEmpty {
            if cities[ci].convertProductionTo == City.idleConstruction { cities[ci].convertProductionTo = "" }   // isQueueEmptyOrIdle -> setCurrentConstruction
            setProduction(cityId: cityId, p)
        } else {
            if addToTop { list.insert(p, at: 0) } else { list.append(p) }
            setCombinedQueue(ci, list)
        }
        cities[ci].currentConstructionIsUserSet = true
    }
    /// Unciv CityConstructions.canPlaceCreateOneImprovementOn: one of this city's tiles within its work range, not the
    /// centre, not already claimed by a CreatesOneImprovement construction, and the improvement can be built there
    func canPlaceCreateOneImprovementOn(_ improvement: String, _ c: HexCoord, city: City) -> Bool {
        guard let t = map[c], city.tiles.contains(c), c.distance(to: city.coord) <= rs.constants.cityWorkRange else { return false }
        return !t.isCityCenter && !isMarkedForCreatesOneImprovement(c) && canBuildCreatedImprovement(city, c, improvement)
    }
    /// The improvement a "Creates a [] improvement on a specific tile" building makes (Building.improvementToCreate)
    func improvementToCreate(_ p: Production) -> String? {
        guard case .building(let b) = p else { return nil }
        return rs.buildings[b]?.uniqueObjects.first { $0.pattern == "Creates a [] improvement on a specific tile" }?.param(0)
    }
    /// Unciv CityView.tryAddToQueueWithTile → CityConstructions.addToQueue(construction, tile): queued, and the tile marked
    func addToQueueWithTile(cityId: Int, _ p: Production, tile: HexCoord) {
        guard let ci = cityIndex(cityId), canAddToQueue(p, in: cities[ci]), let imp = improvementToCreate(p) else { return }
        addToQueue(cityId: cityId, p)
        cities[ci].reservedImprovementTile = tile; cities[ci].reservedImprovement = imp
    }
    /// Unciv CityConstructions.moveEntryToTop (combined index)
    func moveQueueEntryToTop(cityId: Int, index: Int) {
        guard let ci = cityIndex(cityId) else { return }
        var list = combinedQueue(cities[ci])
        guard index > 0, index < list.count else { return }
        let p = list.remove(at: index); list.insert(p, at: 0)
        setCombinedQueue(ci, list)
    }
    /// Unciv CityConstructions.moveEntryToEnd (combined index)
    func moveQueueEntryToEnd(cityId: Int, index: Int) {
        guard let ci = cityIndex(cityId) else { return }
        var list = combinedQueue(cities[ci])
        guard index >= 0, index < list.count else { return }
        let p = list.remove(at: index); list.append(p)
        setCombinedQueue(ci, list)
    }
    /// Unciv CityConstructions.raisePriority: swaps with the entry before it
    func raiseQueuePriority(cityId: Int, index: Int) {
        guard let ci = cityIndex(cityId) else { return }
        var list = combinedQueue(cities[ci])
        guard index > 0, index < list.count else { return }
        list.swapAt(index - 1, index)
        setCombinedQueue(ci, list)
    }
    /// Unciv CityConstructions.lowerPriority: swaps with the entry after it
    func lowerQueuePriority(cityId: Int, index: Int) {
        guard let ci = cityIndex(cityId) else { return }
        var list = combinedQueue(cities[ci])
        guard index >= 0, index < list.count - 1 else { return }
        list.swapAt(index, index + 1)
        setCombinedQueue(ci, list)
    }
    /// Unciv CityConstructions.removeFromQueue(index, automatic): the next entry simply follows and counts as the player's;
    /// an emptied queue gets PerpetualConstruction.Idle ("Nothing", "to prevent Construction Automation") when the player
    /// emptied it, or chooseNextConstruction when it went automatically, and the flag is cleared. The index after the last
    /// combined entry is the trailing perpetual (convertProductionTo).
    func removeFromCombinedQueue(cityId: Int, index: Int, automatic: Bool = false) {
        guard let ci = cityIndex(cityId) else { return }
        var list = combinedQueue(cities[ci])
        if index == list.count && !cities[ci].convertProductionTo.isEmpty {
            cities[ci].convertProductionTo = ""
        } else {
            guard list.indices.contains(index) else { return }
            list.remove(at: index)
            setCombinedQueue(ci, list)
        }
        if list.isEmpty && cities[ci].convertProductionTo.isEmpty {   // constructionQueue.isEmpty()
            if automatic { chooseNextConstructionIfAutomated(cityId: cityId) }
            else { cities[ci].convertProductionTo = City.idleConstruction }
            if let cx = cityIndex(cityId) { cities[cx].currentConstructionIsUserSet = false }
        } else {
            cities[ci].currentConstructionIsUserSet = true   // we're just continuing the regular queue
        }
    }
    func addToQueueTop(cityId: Int, _ p: Production) { addToQueue(cityId: cityId, p, addToTop: true) }
    func canBuild(_ p: Production, in city: City) -> Bool { canProduce(p, in: city) }
    func addToAllQueues(_ p: Production, civId: Int) { for c in candidateCities(civId) { addToQueue(cityId: c.id, p) } }
    /// Unciv CityScreenConstructionMenu.addAllQueues for a PerpetualConstruction: addToQueue in every candidate city
    func addPerpetualToAllQueues(_ name: String, civId: Int) { for c in candidateCities(civId) { addPerpetualToQueue(cityId: c.id, name) } }
    /// Unciv CityScreenConstructionMenu.removeAllQueues for a PerpetualConstruction: removeAllByName in every candidate city -
    /// removeFromQueue(its index, false) while the queue is neither empty nor idle; ours holds it once, as the trailing entry
    func removePerpetualFromAllQueues(_ name: String, civId: Int) {
        for c in candidateCities(civId) {
            guard let cur = city(c.id), !cur.isQueueEmptyOrIdle, cur.convertProductionTo == name else { continue }
            removeFromCombinedQueue(cityId: c.id, index: combinedQueue(cur).count)
        }
    }
    /// Unciv CityScreenConstructionMenu "Add or move to the top in all cities"
    func addOrMoveToTopInAllCities(_ p: Production, civId: Int) {
        for c in candidateCities(civId) {
            if let i = combinedQueue(c).firstIndex(of: p), i > 0 { moveQueueEntryToTop(cityId: c.id, index: i) }   // index > 0: tryMoveEntryToTop
            else { addToQueue(cityId: c.id, p, addToTop: true) }
        }
    }
    /// Unciv CityConstructions.removeAllByName in every city: removeFromQueue(index, false) for each entry of that name
    /// while the queue is neither empty nor idle
    func removeFromAllQueues(_ p: Production, civId: Int) {
        for c in candidateCities(civId) {
            while let cur = city(c.id), !cur.isQueueEmptyOrIdle, let index = combinedQueue(cur).firstIndex(of: p) {
                removeFromCombinedQueue(cityId: c.id, index: index)
            }
        }
    }
    func setConstructionDisabled(_ name: String, cityId: Int, _ disabled: Bool) {
        guard let ci = cityIndex(cityId) else { return }
        if disabled { cities[ci].disabledConstructions.insert(name) } else { cities[ci].disabledConstructions.remove(name) }
    }
    func setCivConstructionDisabled(_ name: String, civId: Int, _ disabled: Bool) {
        guard let ci = civIndex(civId) else { return }
        // Unciv CivView.tryDisableCivConstruction / tryEnableCivConstruction: every city of the civ, then the civ-wide set
        for j in cities.indices where cities[j].civId == civId {
            if disabled { cities[j].disabledConstructions.insert(name) } else { cities[j].disabledConstructions.remove(name) }
        }
        if disabled { civs[ci].disabledCivConstructions.insert(name) } else { civs[ci].disabledCivConstructions.remove(name) }
    }
}
