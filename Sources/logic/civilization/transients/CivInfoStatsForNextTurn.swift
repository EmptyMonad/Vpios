// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/transients/CivInfoStatsForNextTurn.kt`: what the empire earns and owes next turn, and how happy it is.
extension GameState {
    /// `onlyCity`: Unciv City.cityStats.happinessList for that city alone (no civ-wide sources).
    /// Unciv `getHappinessBreakdown` builds the empire-wide rows itself and then adds, for every city,
    /// `city.cityStats.happinessList` - a STORED list written by `updateCityHappiness` inside that city's own
    /// `cityStats.update()`. A per-city row therefore reaches the empire only when that city is next updated,
    /// which is why the order of the turn's city loop decides what any given city sees. Measured on `settled`
    /// turn 72: the reference ranks Tokyo's tiles at happy=-1 while its own live sum already reads 0.25,
    /// because Satsuma - last in Japan's list - has not yet carried Meritocracy's +1 into the empire.
    /// The stored rows are the default; `storedCityRows: false` recomputes the cities for the self-tests.
    func happinessBreakdown(_ civId: Int, onlyCity: Int? = nil, storedCityRows: Bool = true) -> HappinessBreakdown {
        let umT = UIMeasure.start(); defer { UIMeasure.stop("happinessBreakdown", umT) }
        var h = HappinessBreakdown()
        guard let civ = civ(civId), !civ.isBarbarian else { return h }
        let diff = difficulty(for: civId)
        let ctx = UniqueContext(civId: civId)
        if onlyCity == nil {
            // Unciv getHappinessBreakdown, in its order. The four civ-wide rows are always put in the map, zero or not
            // - which decides the map's size, and with it the order its values are summed in.
            h.add("Base happiness", Double(vpBaseHappiness(civId: civId) ?? diff.baseHappiness))   // VP: handicap + capital default
            var perLux = Float(4.0 + diff.extraHappinessPerLuxury)
            for u in civUniques(civId) where u.pattern == "[] Happiness from each type of luxury resource" && conditionalsHold(u, ctx) { perLux += Float(u.int(0)) }
            // "Luxury resources": the summarized supply's luxuries (a zero sum is not in it) that are not obsolete.
            if vpNeeds != nil {   // VP: each luxury's own Happiness (CvPlayer::GetBonusHappinessFromLuxuriesFlat)
                let lux = Set(civResourceSupply(civId).keys.filter { rs.resources[$0]?.resourceType == "Luxury" })
                let uniqueExtra = Double(perLux - Float(4.0 + diff.extraHappinessPerLuxury))   // "[n] Happiness from each type of luxury resource"
                h.add("Luxury resources", Double(vpLuxuryHappiness(civId: civId, luxuries: lux) ?? 0) + uniqueExtra * Double(lux.filter { (vpNeeds?.luxuryHappiness[$0] ?? 0) > 0 }.count))
                perLux = 0   // the city-state and traded-luxury rows below are Unciv's, not VP's
            } else {
                h.add("Luxury resources", Double(Float(luxuryTypesOwned(civId)) * perLux))
            }
            // "City-State Luxuries": distinct luxuries in allied city-states' supply that we also have, in
            // getKnownCivs() order, × "[x]% Happiness from luxury resources gifted by City-States".
            let bonus = Float(civUniques(civId).filter { $0.pattern == "[]% Happiness from luxury resources gifted by City-States" && conditionalsHold($0, ctx) }.reduce(0) { $0 + $1.int(0) }) / 100
            // Both read `getCivResourceSupply()` - the stored summarized supply, ours and the city-states'.
            let ownedLuxuries = Set(civResourceSupply(civId).keys.filter { rs.resources[$0]?.resourceType == "Luxury" })
            var provided: Set<String> = []
            for cs in knownCivs(civId) where cs.isCityState && ally(of: cs.id) == civId {
                for r in civResourceSupply(cs.id).keys where rs.resources[r]?.resourceType == "Luxury" && ownedLuxuries.contains(r) { provided.insert(r) }
            }
            h.add("City-State Luxuries", Double(perLux * Float(provided.count) * bonus))
            // "Traded Luxuries": the stored detailed rows of luxuries given away ("Trade", or "Trade request") that
            // are no longer in the supply at all - one per row - × the "Retain [x]% of the happiness" sum / 100f.
            let tradedAway = detailedCivResources(civId).filter {
                $0.amount < 0 && rs.resources[$0.resource]?.resourceType == "Luxury" && ($0.origin == "Trade" || $0.origin == "Trade request")
            }.filter { !ownedLuxuries.contains($0.resource) }
            let retainPercent = civUniques(civId).filter { $0.pattern == "Retain []% of the happiness from a luxury after the last copy has been traded away" && conditionalsHold($0, ctx) }.reduce(0) { $0 + $1.int(0) }
            h.add("Traded Luxuries", Double(Float(tradedAway.count) * perLux * Float(retainPercent) / 100))
        }
        let myCities = cities(of: civId).filter { onlyCity == nil || $0.id == onlyCity }
        if storedCityRows {
            // Read the STORED list, never compute it: `city.cityStats.happinessList` in Unciv is whatever the
            // city's last update left there, and a city that has not been updated yet contributes nothing.
            // Computing it here would ask for the city's stats, which ask for the empire's happiness, which
            // asks for this - the load path went round that circle until the stack ran out.
            for city in myCities { for (k, v) in storedCityStats[city.id]?.happinessRows ?? [] { h.add(k, v) } }
        } else {
            liveCityHappinessRows(civId, myCities, into: &h)
        }
        // Transportation Upkeep has a happiness part only when a road costs happiness, and none does. Then every row
        // of getGlobalStatsFromUniques, by its key, zero or not: the founder beliefs ("Religion" - which ours never
        // counted here), "[stats] per [n] social policies", the empire's bare "[stats]" by source, "Natural Wonders".
        if onlyCity == nil {
            for (key, st) in globalStatsFromUniques(civId) { h.add(key, st.happiness) }
        }
        return h
    }

    /// The live computation of the cities' happiness rows (`storedCityRows: false`), kept for the self-tests.
    private func liveCityHappinessRows(_ civId: Int, _ myCities: [City], into h: inout HappinessBreakdown) {
        guard let civ = civ(civId) else { return }
        let diff = difficulty(for: civId)
        let onlyCity: Int? = myCities.count == 1 ? myCities.first?.id : nil
        let unhappyMod = diff.unhappinessModifier * (civ.isPlayer ? 1 : difficulty.aiUnhappinessModifier)   // Unciv CityStats: civ difficulty × game AI modifier
        let ctx = UniqueContext(civId: civId)
        let dbgHappy = ProcessInfo.processInfo.environment["DUMP_HAPPYSRC"] == civ.nation && onlyCity == nil
        if dbgHappy {
            for u in civUniques(civId) where (u.stats?.happiness ?? 0) != 0 {
                print("HSRCE civ [\(u.pattern)] <- \(u.text) src=\(u.sourceNameForUser) scope=\(u.scope) params=\(u.params.count) holds=\(conditionalsHold(u, ctx)) dependsHappy=\(dependsOnHappiness(u))")
            }
        }
        for city in myCities {
            let cityCtx = UniqueContext(civId: civId, city: city)
            // Unciv CityStats.updateCityHappiness: "Buildings" = Σ Building.getStats (base, StatsFromObject, StatsFromBuildings for non-wonders) truncated,
            // "Specialists" truncated when positive, "Tile yields", and StatsPerCity "[stats] [cityFilter]" by source.
            // Policies and beliefs come once through civUniques / religionUniques; only "in this city" building uniques are not broadcast.
            let happinessUniques = city.buildings.flatMap { rs.buildings[$0]?.uniqueObjects.filter { $0.params.contains("in this city") } ?? [] } + religionUniques(for: city) + civUniques(civId)
            var buildingHappiness = city.buildings.reduce(0.0) { $0 + (rs.buildings[$1]?.stats.happiness ?? 0) }
            var specialistHappiness = city.specialists.reduce(0.0) { $0 + (rs.specialists[$1.key]?.stats.happiness ?? 0) * Double($1.value) }
            for u in happinessUniques where !dependsOnHappiness(u) && conditionalsHold(u, cityCtx) {
                guard let st = u.stats, st.happiness != 0 else { continue }
                switch u.pattern {
                case "[] from every []":
                    buildingHappiness += st.happiness * Double(city.buildings.filter { productionMatches(.building($0), u.param(1)) }.count)
                    specialistHappiness += st.happiness * Double(city.specialists[u.param(1)] ?? 0)
                case "[] from all [] buildings":
                    buildingHappiness += st.happiness * Double(city.buildings.filter { productionMatches(.building($0), u.param(1)) && rs.buildings[$0]?.isWonder != true }.count)   // Unciv Building.getStats: `!isWonder`, world wonders only
                case "[] []":
                    if u.params.count == 2 && !u.scope.isEmpty && scopeIncludes(u, city: city) { h.add(u.sourceNameForUser.isEmpty ? "Policies" : u.sourceNameForUser, st.happiness) }
                default: break
                }
            }
            h.add("Buildings", Double(Int(buildingHappiness)))
            if Int(specialistHappiness) > 0 { h.add("Specialists", Double(Int(specialistHappiness))) }
            let tileHappinessUniques = cityTileUniques(city).contains { ($0.stats?.happiness ?? 0) != 0 }
            for t in ([city.coord] + city.workedTiles).compactMap({ map[$0] }) + unassignedYieldTiles(city) {
                let mayYieldHappiness = tileHappinessUniques || t.naturalWonder.flatMap { rs.terrains[$0]?.stats.happiness }.map { $0 != 0 } == true
                    || t.terrainNames.contains { (rs.terrains[$0]?.stats.happiness ?? 0) != 0 }
                    || (t.improvement.flatMap { rs.improvements[$0]?.stats.happiness } ?? 0) != 0 || (t.resource.flatMap { rs.resources[$0]?.stats.happiness } ?? 0) != 0
                if mayYieldHappiness { h.add("Tile yields", tileStats(t, civId: civId, city: city).happiness) }
            }
            for u in cityUniques(city) where !dependsOnHappiness(u) && scopeIncludes(u, city: city) && conditionalsHold(u, cityCtx) {
                if u.pattern == "[] per [] population []" || u.pattern == "[] per [] population", let st = u.stats, st.happiness != 0 {
                    h.add(u.sourceNameForUser.isEmpty ? "Policies" : u.sourceNameForUser, st.happiness * Double(city.population / max(1, u.int(1))))
                }
                if u.pattern == "[] in cities on [] tiles", let st = u.stats, st.happiness != 0, let centre = map[city.coord], tileMatches(centre, u.param(1), civId: civId) { h.add(u.sourceNameForUser.isEmpty ? "Buildings" : u.sourceNameForUser, st.happiness) }
            }
        }
        // Unciv CityStats.updateCityHappiness: −3 per city (−5 with extra annex unhappiness) × modifier × (1 + Σ cities%),
        // population + Σ (x% of a population filter) doubled when annexed, never negative, × modifier, and "Occupied City" −2
        var citiesPercent = 0.0
        for u in civUniques(civId) where u.pattern == "[]% unhappiness from the number of cities" && conditionalsHold(u, ctx) { citiesPercent += u.double(0) }
        if vpNeeds != nil {   // VP: needs-based unhappiness (VP/VPNeeds.swift)
            for c in myCities { for (k, v) in vpCityUnhappiness(c)?.rows ?? [] { h.add(k, -Double(v)) } }
            return
        }
        var cityUnhappy = 0.0, pop = 0.0
        for c in myCities {
            // Unciv hasExtraAnnexUnhappiness: `civName == foundingCiv` - a married city-state ("" founder) is occupied
            let extraAnnex = c.originalOwner != civId && !c.isPuppet && !c.buildings.contains { rs.buildings[$0]?.uniques.contains("Removes extra unhappiness from annexed cities") == true }
            cityUnhappy += (extraAnnex ? 5 : 3) * unhappyMod * (1 + citiesPercent / 100)
            var citizens = Double(c.population)
            let cityCtx = UniqueContext(civId: civId, city: c)
            for u in cityUniques(c) where u.pattern == "[]% Unhappiness from [] []" && cityMatchesFilter(u.param(2), city: c, viewer: civId) && conditionalsHold(u, cityCtx) {
                citizens += u.double(0) / 100 * Double(populationFilterAmount(c, u.param(1)))
            }
            if extraAnnex { citizens *= 2; cityUnhappy += 2 }
            pop += max(0, citizens) * unhappyMod
        }
        h.add("Cities", -cityUnhappy)
        h.add("Population", -pop)
    }

    /// Unciv `Civilization.getHappiness() = stats.happiness`, and `stats.happiness` is `var happiness = 0`.
    /// It is READ here and never computed: a civ whose stats have not been updated yet reads 0 there, and now
    /// reads 0 here. The fallback that used to compute the breakdown made our field fresher than the
    /// reference's at exactly the moments the reference is deliberately stale.
    func happiness(of civId: Int) -> Int { happinessCache[civId] ?? 0 }

    /// Unciv `Civilization.getHappiness() = stats.happiness` - a FIELD, written only by
    /// updateStatsForNextTurn. Everything a conditional asks about happiness ("while the empire is happy",
    /// "when below [0] [Happiness]") reads that field, so it changes at the points Unciv changes it and
    /// nowhere else: measured on `t_45`, Kyoto banked its food against -75% growth for a whole turn that
    /// Unciv had already spent at 0%, because our value was recomputed the moment anything touched it.
    /// This clears the caches DERIVED from happiness; the value itself is left alone.
    func invalidateHappiness(_ civId: Int? = nil) {
        if let c = civId { civUniquesCache[c] = nil; goldOutputCache[c] = nil } else { civUniquesCache.removeAll(); goldOutputCache.removeAll() }
    }

    /// Uniques whose conditionals depend on happiness cannot be used while computing happiness itself.
    private func dependsOnHappiness(_ u: Unique) -> Bool { u.conditionals.contains { $0.params.contains("Happiness") || $0.pattern == "while the empire is happy" } }

    // MARK: unit supply (Unciv getUnitSupply): base + per city + 0.5 per citizen; each missing supply costs 10% production, capped at 70%.
    /// Unciv getUnitSupply = getBaseUnitSupply + getUnitSupplyFromCities + getUnitSupplyFromPop, all Int, then for an
    /// AI major `(supply * (1f + aiUnitSupplyModifier)).toInt()` in Float. The uniques are read with the civ's
    /// conditionals.
    func unitSupply(_ civId: Int) -> Int {
        guard let civ = civ(civId) else { return 0 }
        let myCities = cities(of: civId)
        let ctx = UniqueContext(civId: civId)
        let civU = civUniques(civId).filter { ["[] Unit Supply", "[] Unit Supply per city", "[] Unit Supply per [] population []"].contains($0.pattern) && conditionalsHold($0, ctx) }
        let base = baseUnitSupply(civId), fromCities = unitSupplyFromCities(civId)
        var popSupply = Double(myCities.reduce(0) { $0 + $1.population }) * rs.constants.unitSupplyPerPopulation   // Unciv getUnitSupplyFromPop: modOptions.constants.unitSupplyPerPopulation
        for u in civU where u.pattern == "[] Unit Supply per [] population []" { let per = max(1, u.int(1)); popSupply += u.double(0) * Double(myCities.filter { cityMatchesFilter(u.param(2), city: $0, viewer: civId) }.reduce(0) { $0 + $1.population / per }) }   // Unciv UnitSupplyPerPop
        var supply = base + fromCities + Int(popSupply)
        if civ.isMajor && !civ.isPlayer { supply = Int(Float(supply) * (1 + Float(difficulty(for: civ.id).aiUnitSupplyModifier))) }
        return supply
    }

    /// Unciv getBaseUnitSupply: the civ's difficulty's unitSupplyBase plus every "[] Unit Supply".
    func baseUnitSupply(_ civId: Int) -> Int {
        let ctx = UniqueContext(civId: civId)
        return difficulty(for: civId).unitSupplyBase + civUniques(civId).filter { $0.pattern == "[] Unit Supply" && conditionalsHold($0, ctx) }.reduce(0) { $0 + $1.int(0) }
    }
    /// Unciv getUnitSupplyFromCities: the cities times (unitSupplyPerCity plus every "[] Unit Supply per city").
    func unitSupplyFromCities(_ civId: Int) -> Int {
        let ctx = UniqueContext(civId: civId)
        return cities(of: civId).count * (difficulty(for: civId).unitSupplyPerCity + civUniques(civId).filter { $0.pattern == "[] Unit Supply per city" && conditionalsHold($0, ctx) }.reduce(0) { $0 + $1.int(0) })
    }

    func unitSupplyDeficit(_ civId: Int) -> Int { max(0, units(of: civId).count - unitSupply(civId)) }

    func unitSupplyProductionPenalty(_ civId: Int) -> Double { min(Double(unitSupplyDeficit(civId)) * 10, 70) }

    // MARK: golden age

    /// Unciv Civilization.addGameResource / addStat: an Int amount (the caller's `toInt()`); culture goes through
    /// the policy manager and, when positive, into totalCultureForContests; faith likewise into
    /// totalFaithForContests - the city-state contests count those, and ours never did.
    func applyStatGain(civId: Int, stat: String, amount: Double) {
        guard let ci = civIndex(civId) else { return }
        let n = Int(amount)
        switch stat {
        case "Gold": civs[ci].gold += Double(n); goldTrace(civId, Double(n))
        case "Culture": addCulture(ci, Double(n)); civs[ci].totalCulture += Double(n); if n > 0 { civs[ci].totalCultureForContests += n }
        case "Science": addScience(civId: civId, n)
        case "Faith": civs[ci].faithStored += Double(n); if n > 0 { civs[ci].totalFaithForContests += n }
        // Unciv SubStat: golden age points are gainable the way a stat is (goldenAges.addHappiness).
        case "Golden Age points": civs[ci].goldenAgePoints += Double(n)
        case "Stored Food":
            // SubStat.StoredFood is city-scoped in Unciv; kept from before - no civ-wide gain of it reaches here in Gods & Kings.
            for i in cities.indices where cities[i].civId == civId { cities[i].foodStored += amount }
        default: break   // food, production and happiness cannot be added nationwide
        }
    }

    /// Unciv Civilization.addStats: every stat of the Stats, each `toInt()`, through addStat.
    func addStats(civId: Int, _ st: Stats) {
        for stat in ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith"] where st[stat] != 0 {
            applyStatGain(civId: civId, stat: stat, amount: st[stat])
        }
    }
}

// MARK: - Unciv CivInfoStatsForNextTurn (shared by the end-of-turn treasury and the Stats overview)
extension GameState {

    /// Unciv getTransportationUpkeep: every road of the civ's cities' tiles outside a city centre pays its
    /// "Costs [] [] per turn when in your territory" AND "Costs [] [] per turn" (unless a "No Maintenance costs for
    /// improvements in [] tiles" unique covers the tile); a neutral road the civ built pays only the unconditional
    /// one; then each "[]% maintenance on road & railroads" scales the total. All of it in Float, as Unciv's Stats.
    ///
    /// Ours had invented fallbacks (1 and 2 gold when the road named no cost), took only the first unique of the
    /// two, exempted neutral roads on covered tiles, and added a second, non-road "improvement upkeep" that Unciv
    /// does not charge anywhere.
    func transportationUpkeep(_ civId: Int) -> Double {
        let ignoredTileTypes = civUniques(civId).filter { $0.pattern == "No Maintenance costs for improvements in [] tiles" && conditionalsHold($0, UniqueContext(civId: civId)) }.map { $0.param(0) }
        var upkeep: Float = 0
        func addMaintenance(_ road: String, _ tile: Tile, inTerritory: Bool) {
            guard let def = rs.improvements[road] else { return }
            let ctx = UniqueContext(civId: civId, tile: tile)
            // Unciv: ImprovementMaintenance first, then ImprovementAllMaintenance.
            if inTerritory {
                for u in def.uniqueObjects where u.pattern == "Costs [] [] per turn when in your territory" && u.param(1) == "Gold" && conditionalsHold(u, ctx) { upkeep += Float(u.double(0)) }
            }
            for u in def.uniqueObjects where u.pattern == "Costs [] [] per turn" && u.param(1) == "Gold" && conditionalsHold(u, ctx) { upkeep += Float(u.double(0)) }
        }
        for city in cities(of: civId) {
            for c in city.tiles {
                guard let t = map[c], !t.isCityCenter, t.roads, !t.roadPillaged else { continue }   // getUnpillagedRoad() == None
                if ignoredTileTypes.contains(where: { tileMatches(t, $0, civId: civId) }) { continue }
                addMaintenance(t.railroad ? "Railroad" : "Road", t, inTerritory: true)
            }
        }
        // Unciv `for (position in civInfo.neutralRoads)`: the civ's STORED set (Tile.setRoadStatus / setOwningCity keep
        // it, setNeutralTransients rebuilds it on load), not the unowned tiles naming us as road owner today - a civ
        // whose neutral Road another civ upgraded to Railroad still pays for it, as does one whose neutral road a
        // city has since claimed. Only getUnpillagedRoad() != None is checked (no city-centre, owner or ignored-tile
        // test), and only ImprovementAllMaintenance is charged. The costs are whole numbers, so the walk order of
        // Unciv's HashSet does not change the Float sum; ours is fixed for determinism.
        for c in (neutralRoads[civId] ?? []).sorted(by: { ($0.q, $0.r) < ($1.q, $1.r) }) {
            guard let t = map[c], t.roads, !t.roadPillaged else { continue }   // getUnpillagedRoad() == None
            addMaintenance(t.railroad ? "Railroad" : "Road", t, inTerritory: false)
        }
        for u in civUniques(civId) where u.pattern == "[]% maintenance on road & railroads" && conditionalsHold(u, UniqueContext(civId: civId)) {
            upkeep *= 1 + Float(u.double(0)) / 100   // Stats.timesInPlace(toPercent())
        }
        return Double(upkeep)
    }

    /// Unciv ImprovementPickerScreen.getMaintenance: the gold this improvement would cost on this tile each
    /// turn - the unconditional cost always, the in-your-territory one only on your own land, nothing where a
    /// unique waives it - scaled by the road maintenance uniques.
    func improvementMaintenance(_ name: String, on tile: Tile, civId: Int) -> Double {
        guard let def = rs.improvements[name], !improvementMaintenanceFree(civId, tile) else { return 0 }
        var cost = 0.0
        for u in def.uniqueObjects where u.param(1) == "Gold" {
            if u.pattern == "Costs [] [] per turn" { cost += u.double(0) }
            else if u.pattern == "Costs [] [] per turn when in your territory", tile.ownerCivId == civId { cost += u.double(0) }
        }
        if name == "Road" || name == "Railroad" {
            for u in civUniques(civId) where u.pattern == "[]% maintenance on road & railroads" { cost *= 1 + u.double(0) / 100 }
        }
        return cost
    }

    /// Units that pay upkeep (kept for the overview): all but the garrisons "Units in cities cost no Maintenance" frees.
    func unitUpkeepPayingCount(_ civId: Int) -> Int {
        let noMaintenanceInCities = civUniques(civId).contains { $0.pattern == "Units in cities cost no Maintenance" && conditionalsHold($0, UniqueContext(civId: civId)) }
        return units(of: civId).filter { u in !(noMaintenanceInCities && map[u.coord]?.isCityCenter == true && u.isMilitary && u.def.isLand) }.count
    }

    /// Unciv getUnitMaintenance, in Float as there: each unit costs 1 × every "[x]% maintenance costs" that applies to
    /// it (its own uniques, and the civ's with the unit's conditionals); the `3 + "[n] units cost no maintenance"`
    /// dearest are dropped; `0.5 × sum × (1 + progress)`, raised to `1 + progress / 3`; an AI pays its difficulty
    /// modifier; truncated. `progress` is gameInfo.turns over the speed's total turns, capped at 1.
    ///
    /// Ours also counted "[] Free Units" / "[] free units" and read a non-numeric "[filter] units cost no maintenance"
    /// as a filter of exempt units - neither exists in Unciv.
    func unitUpkeepCost(_ civId: Int, paying n: Int) -> Double {
        _ = n
        let civU = civUniques(civId)
        let civCtx = UniqueContext(civId: civId)
        var freeUnits = 3
        for u in civU where u.pattern == "[] units cost no maintenance" && conditionalsHold(u, civCtx) { freeUnits += u.int(0) }   // Unciv FreeUnits
        let noMaintenanceInCities = civU.contains { $0.pattern == "Units in cities cost no Maintenance" && conditionalsHold($0, civCtx) }
        let civDiscounts = civU.filter { $0.pattern == "[]% maintenance costs" }   // IgnoreConditionals: judged per unit below
        var costsToPay: [Float] = []
        for u in units(of: civId) {
            if noMaintenanceInCities && map[u.coord]?.isCityCenter == true && u.isMilitary && u.def.isLand { continue }   // isCityCenter && canGarrison
            let ctx = UniqueContext(civId: civId, unit: u)
            var unitMaintenance: Float = 1
            for x in u.promotionUniques where x.pattern == "[]% maintenance costs" && conditionalsHold(x, ctx) { unitMaintenance *= 1 + Float(x.double(0)) / 100 }
            for x in civDiscounts where conditionalsHold(x, ctx) { unitMaintenance *= 1 + Float(x.double(0)) / 100 }
            costsToPay.append(unitMaintenance)
        }
        costsToPay.sort(by: >)
        let numberOfUnitsToPayFor = Float(max(0.0, costsToPay.dropFirst(freeUnits).reduce(0.0) { $0 + Double($1) }))   // sumOf { toDouble() }
        let turns = turn - (barbarianPhase ? 0 : 1)   // Unciv gameInfo.turns
        let gameProgress = min(Float(turns) / Float(max(1, speed.lastTurn)), 1)
        var cost: Float = 0.5 * numberOfUnitsToPayFor * (1 + gameProgress)
        cost = Float(pow(Double(cost), Double(1 + gameProgress / 3)))   // Kotlin Float.pow goes through Double
        if civ(civId)?.isPlayer == false { cost *= Float(difficulty.aiUnitMaintenanceModifier) }
        return Double(Int(cost))
    }

    /// Unciv getStatMapForNextTurn, in its order: every city's final stat list; the allied city-states' share;
    /// transportation and unit upkeep; excess happiness converted; the treasury deficit - judged on the gold summed
    /// SO FAR, before trade and the civ-wide uniques are in; trade gold; then getGlobalStatsFromUniques.
    func statMapForNextTurn(_ civId: Int) -> [(String, Stats)] {
        guard let civ = civ(civId) else { return [] }
        var rows: [(String, Stats)] = []
        func add(_ key: String, _ st: Stats) {
            if let i = rows.firstIndex(where: { $0.0 == key }) { rows[i].1 = (rows[i].1 + st).f32 } else { rows.append((key, st)) }
        }
        func set(_ key: String, _ st: Stats) {
            if let i = rows.firstIndex(where: { $0.0 == key }) { rows[i].1 = st } else { rows.append((key, st)) }
        }
        // `for (city in civInfo.cities) for (entry in city.cityStats.finalStatList) statMap.add(entry.key, entry.value)`:
        // every city's stored final list, source by source, each key summed in Float in the order the cities come.
        // Ours summed each city's aggregate totals into four invented rows (Tiles, Buildings, Population, Bonuses)
        // plus Maintenance and Trade routes - the same money added up in another order, which in Float is not
        // always the same money.
        for city in cities(of: civId) {
            for (key, value) in currentCityStats(city.id).finalStatList { add(key, value) }
        }
        // "City-States": for each known city-state that has us as its ally, each CityStateStatPercent unique takes
        // its share of what the city-state's OWN statsForNextTurn holds - the field, not a fresh sum of its cities.
        let civCtx = UniqueContext(civId: civId)
        let statPercent = civUniques(civId).filter { $0.pattern == "Allied City-States provide [] equal to []% of what they produce for themselves" && conditionalsHold($0, civCtx) }
        if !statPercent.isEmpty {
            for other in knownCivs(civId) where other.isCityState && isAlly(civId, of: other.id) {
                let theirs = other.statsForNextTurn ?? Stats()
                for u in statPercent {
                    let value = Stats.f32(Double(Float(theirs[u.param(0)]) * Float(u.double(1)) / 100))
                    var st = Stats(); st[u.param(0)] = value
                    add("City-States", st)
                }
            }
        }
        set("Transportation upkeep", Stats(gold: -transportationUpkeep(civId)))
        set("Unit upkeep", Stats(gold: -unitUpkeepCost(civId, paying: 0)))
        let happy = happiness(of: civId)
        if happy > 0 {
            var conv = Stats()
            for u in civUniques(civId) where u.pattern == "[]% of excess happiness converted to []" && conditionalsHold(u, civCtx) {
                conv[u.param(1)] = Stats.f32(conv[u.param(1)] + Double(Float(u.double(0)) / 100 * Float(happy)))
            }
            add("Policies", conv)
        }
        // "negative gold hurts science" - on what has been summed up to here.
        var goldSum: Float = 0, scienceSum: Float = 0
        for r in rows { goldSum += Float(r.1.gold); scienceSum += Float(r.1.science) }
        if goldSum < 0 && civ.gold < 0 {
            set("Treasury deficit", Stats(science: Double(max(goldSum, 1 - scienceSum))))   // leave at least 1
        }
        var tradeGold = 0
        // Unciv DiplomacyManager.goldPerTurn: the trades still in THIS side's copy (it is removed in the side's own
        // nextTurnTrades when its duration runs out)
        for d in deals where d.kind == .goldPerTurn {
            if d.from == civId && d.exists(for: civId) { tradeGold -= d.amount }
            else if d.to == civId && d.exists(for: civId) { tradeGold += d.amount }
        }
        if tradeGold != 0 { set("Trade", Stats(gold: Double(tradeGold))) }
        for (key, st) in globalStatsFromUniques(civId) { add(key, st) }
        if ProcessInfo.processInfo.environment["GOLDMAP"] == civ.nation {
            for city in cities(of: civId) {
                let fl = currentCityStats(city.id).finalStatList
                let worked = city.workedTiles.map { uncivPosition($0) }.map { "\($0.x),\($0.y)" }.sorted().joined(separator: ",")
                print("GOLDCITY t=\(uncivTurns) \(city.name) " + fl.map { "\($0.0.replacingOccurrences(of: " ", with: "_"))=\(String(format: "%.2f", Double(Float($0.1.gold))))" }.joined(separator: " ") + " worked=" + worked)
            }
        }
        if ProcessInfo.processInfo.environment["GOLDMAP"] == civ.nation { print("GOLDMAP t=\(uncivTurns) " + rows.map { "\($0.0.replacingOccurrences(of: " ", with: "_"))=\(String(format: "%.2f", Double(Float($0.1.gold))))" }.joined(separator: " ")) }
        return rows
    }

    /// Unciv getGlobalStatsFromUniques: what the empire earns from uniques that belong to no city - the founder
    /// beliefs, "[stats] per [n] social policies adopted", every bare "[stats]" whose source is not a building,
    /// "[stats] for every [n] [stat]", the natural wonders, and "[x]% [stat] from City-States" on the city-state row.
    func globalStatsFromUniques(_ civId: Int) -> [(String, Stats)] {
        guard let civ = civ(civId) else { return [] }
        var rows: [(String, Stats)] = []
        func add(_ key: String, _ st: Stats) {
            if let i = rows.firstIndex(where: { $0.0 == key }) { rows[i].1 = (rows[i].1 + st).f32 } else { rows.append((key, st)) }
        }
        let gctx = UniqueContext(civId: civId)
        // The FOUNDER's beliefs pay "[stats] for each global city following this religion" and "[stats] from every
        // [amount] global followers [filter]" into the empire's "Religion" row - not into a city.
        if let religionName = civ.religionName {
            for u in founderUniques(for: civId) {
                guard let st = u.stats, conditionalsHold(u, gctx) else { continue }
                switch u.pattern {
                case "[] for each global city following this religion":
                    add("Religion", (st * Double(citiesFollowing(religionName).count)).f32)
                case "[] from every [] global followers []":
                    add("Religion", (st * Stats.f32(Double(Float(globalFollowers(of: religionName, filter: u.param(2), viewer: civId)) / Float(max(1, u.int(1)))))).f32)
                default: break
                }
            }
        }
        // StatsPerPolicies: adopted policies that are not branch completions, integer-divided; always "Policies".
        for u in civUniques(civId) where u.pattern == "[] per [] social policies adopted" && conditionalsHold(u, gctx) {
            if let st = u.stats { add("Policies", st * Double(civ.adoptedPolicyCount / max(1, u.int(1)))) }
        }
        // Stats: a bare "[stats]" the EMPIRE holds - a city-state's friendship bonus, a policy, a nation trait -
        // added once, under the name of whatever granted it. Buildings' and wonders' are counted in their city.
        for u in civUniques(civId) where u.pattern == "[]" && u.sourceObjectType != .building && u.sourceObjectType != .wonder {
            guard let st = u.stats, conditionalsHold(u, gctx) else { continue }
            add(u.sourceNameForUser, st)
        }
        // StatsPerStat: "[stats] for every [amount] [stat]" of the civ's reserve.
        for u in civUniques(civId) where u.pattern == "[] for every [] []" && conditionalsHold(u, gctx) {
            guard let st = u.stats else { continue }
            let reserve: Int
            switch u.param(2) {
            case "Culture": reserve = Int(civ.cultureStored)
            case "Science": reserve = civ.currentTech.flatMap { civ.techsInProgress[$0] } ?? 0
            case "Gold": reserve = Int(civ.gold)
            case "Faith": reserve = Int(civ.faithStored)
            case "Happiness": reserve = happiness(of: civId)
            default: reserve = 0
            }
            add("Stats", st * Double(reserve / max(1, u.int(1))))
        }
        // Natural Wonders: +1 happiness each, plus every StatsFromNaturalWonders.
        var perNaturalWonder = Stats(happiness: 1)
        for u in civUniques(civId) where u.pattern == "[] for every known Natural Wonder" && conditionalsHold(u, gctx) { if let st = u.stats { perNaturalWonder += st } }
        add("Natural Wonders", perNaturalWonder * Double(civ.seenNaturalWonders.count))
        // Unciv: `if (statMap.contains(Constants.cityStates))` every "[x]% [stat] from City-States" multiplies that stat of
        // the city-states' row, `statMap[cityStates]!![bonusStat] *= bonusPercent` in Float
        if let i = rows.firstIndex(where: { $0.0 == "City-States" }) {
            for u in civUniques(civId) where u.pattern == "[]% [] from City-States" && conditionalsHold(u, gctx) {
                rows[i].1[u.param(1)] = Double(Float(rows[i].1[u.param(1)]) * (1 + Float(u.double(0)) / 100))
            }
        }
        return rows
    }
}

// MARK: - Unciv Civilization.moveCapitalTo / moveCapitalToNextLargest
extension GameState {

    func scienceOutput(for civId: Int) -> Double {
        cities(of: civId).reduce(0) { $0 + currentCityStats($1.id).total.science }
    }

    /// Unciv `civInfo.stats.statsForNextTurn.science`, which TechManager.turnsToTech divides by and the top bar shows:
    /// the stored field - every row of the civ's stat map, the allied city-states' share and the treasury deficit
    /// included - or, while it is stale, that whole map summed. Not scienceOutput, which adds up the cities alone.
    func scienceForNextTurn(_ civId: Int) -> Double {
        let st = civ(civId)?.statsForNextTurn ?? statMapForNextTurn(civId).reduce(Stats()) { $0 + $1.1 }
        return st.science
    }
    /// Unciv `civInfo.stats.statsForNextTurn.culture`, the top bar's culture rate and its turns-to-policy divisor
    /// (WorldScreenTopBarStats.getCultureText): the whole stat map - city-state friendship "[+3 Culture]",
    /// founder beliefs, StatsPerPolicies and the rest - not cultureOutput's cities alone.
    func cultureForNextTurn(_ civId: Int) -> Double {
        (civ(civId)?.statsForNextTurn ?? statMapForNextTurn(civId).reduce(Stats()) { $0 + $1.1 }).culture
    }
    /// Unciv `civInfo.stats.statsForNextTurn.faith`, the top bar's faith rate (WorldScreenTopBarStats.update).
    func faithForNextTurn(_ civId: Int) -> Double {
        (civ(civId)?.statsForNextTurn ?? statMapForNextTurn(civId).reduce(Stats()) { $0 + $1.1 }).faith
    }

    func goldOutput(for civId: Int) -> Double {
        if let c = goldOutputCache[civId] { return c }
        let v = cities(of: civId).reduce(0.0) { acc, city in let st = currentCityStats(city.id); return acc + st.total.gold - Double(st.maintenance) }
        goldOutputCache[civId] = v
        return v
    }

    func faithOutput(for civId: Int) -> Double {
        cities(of: civId).reduce(0) { $0 + currentCityStats($1.id).total.faith }
    }

    func cultureOutput(for civId: Int) -> Double {
        cities(of: civId).reduce(0) { $0 + currentCityStats($1.id).total.culture }
    }
}
