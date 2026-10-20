// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's city/ConstructionAutomation.kt.

extension GameState {
    private struct ConstructionChoice { let choice: Production; var modifier: Float; let remainingWork: Int }

    /// Unciv CityConstructions.chooseNextConstruction (the wrapper) + ConstructionAutomation.chooseNextConstruction.
    /// Callers apply the wrapper's AI / auto-assign / puppet gate.
    func chooseNextConstruction(cityId: Int) {
        defer { if GameState.evlogOn { EvLog.flushProduction() } }   // EVLOG: Unciv evProdCheck after chooseNextConstruction
        guard let ci = cityIndex(cityId) else { return }
        let city = cities[ci]
        guard let civ = civ(city.civId) else { return }
        // Unciv CityConstructions.chooseNextConstruction: `if (!isQueueEmptyOrIdle()) { if (current !is
        // PerpetualConstruction || currentConstructionIsUserSet) return }` - a perpetual the USER queued is kept.
        // (Ours: a unit/building is `currentProduction`, a perpetual is `convertProductionTo`, both empty is the
        // empty queue, and convertProductionTo "Nothing" is PerpetualConstruction.Idle, which isQueueEmptyOrIdle
        // counts as empty - the flag is not read for it.) Unciv leaves the flag alone here: an emptied queue keeps a
        // flag set when validateConstructionQueue, not removeFromQueue, did the emptying - a wonder a Great Engineer
        // queued twice ([Statue of Liberty, Statue of Liberty]) finishes, the second entry follows as the player's
        // (flag true) and validation drops it - and the perpetual then chosen is kept for good (a test game, turn 190).
        if city.currentProduction != nil { return }
        if city.convertProductionTo == City.idleConstruction {
            // isQueueEmptyOrIdle: go on to the automation
        } else if !city.convertProductionTo.isEmpty {
            if city.currentConstructionIsUserSet { return }
        }
        let personality = self.personality(of: city.civId)
        let avoid = personality.willNotBuild
        func shouldAvoid(_ name: String) -> Bool { avoid.contains { productionMatches(rs.units[name] != nil ? .unit(name) : .building(name), $0) } }
        let civUnits = units(of: city.civId)
        let militaryUnits = civUnits.filter { $0.isMilitary }.count
        // Unciv `civUnits.count { it.cache.hasUniqueToBuildImprovements }.toFloat()`: every unit with a
        // "Can build [] improvements on tiles" unique - Rome's Legion (roads and forts) counts, not only Workers.
        let workers = Float(civUnits.filter { !$0.def.improvementFilters.isEmpty }.count)
        let cityCount = cities(of: city.civId).count
        let atWar = isAtWarAtAll(city.civId)
        // Unciv ConstructionAutomation: `averageProduction` is a val of the instance, and one instance is built
        // per city per turn - so the average is re-read after every city that has already chosen this turn.
        // We cached it per TURN, which froze it: measured on `fresh`, Unciv's own average moved from 8.20 at
        // Paris's call to 10.23 at Lyon's call in the same turn, and Lyon's 8.75 production is over the first
        // and under the second. Ours saw the stale 8.20 for both, decided Lyon was an above-average producer,
        // offered it a military unit, and built a Warrior Unciv never built.
        // Unciv `cities.map { it.cityStats.currentCityStats.production }.average()`: List<Float>.average() sums
        // the Float values in a Double and divides in Double; the city's Float production is widened to compare.
        let empireStats = cities(of: city.civId).reduce(Stats()) { $0 + currentCityStats($1.id).total }
        var productionSum = 0.0
        for c in cities(of: city.civId) { productionSum += Stats.f32(currentCityStats(c.id).total.production) }
        let averageProduction = productionSum / Double(max(1, cityCount))
        let cityProduction = Stats.f32(currentCityStats(city.id).total.production)
        let overAverage = cityProduction >= averageProduction
        let allTechs = allTechsResearched(city.civId)
        var choices: [ConstructionChoice] = []
        func addChoice(_ p: Production, _ modifier: Float) {
            // Unciv addChoice: `choiceModifier * extraAiModifier`, the latter getWeightForAiDecision(GameContext(civ,
            // city)) for an AI civ (`civInfo.isAI()` - an auto-played human is not one) and 1 otherwise.
            var m = modifier
            if !civ.isPlayer {
                let ctx = UniqueContext(civId: city.civId, city: city)
                m *= aiDecisionWeight((p.isUnit ? rs.units[p.name]?.uniqueObjects : rs.buildings[p.name]?.uniqueObjects) ?? [], ctx)
                // IHasUniques.getWeightForAiDecision: the personality's "[]% weight to [filter] for AI decisions"
                for pu in personality.uniqueObjects where pu.pattern == "[]% weight to [] for AI decisions" && conditionalsHold(pu, ctx) && productionMatches(p, pu.param(1)) { m *= 1 + Float(pu.double(0)) / 100 }
            }
            // Unciv getRemainingWork: cost - getWorkDone(name); the coerceAtLeast(1) is applied by the ranking
            let cost = productionCost(p, for: city.civId)
            choices.append(ConstructionChoice(choice: p, modifier: m, remainingWork: cost - (city.currentProduction?.name == p.name ? Int(city.productionStored) : (city.inProgressConstructions[p.name] ?? 0))))
        }

        // addBuildingChoices
        // Unciv computeCityBaseline builds the baseline on a clone too, with the same broken connection, so
        // both sides of every building's difference are measured without trade-route gold.
        let baseline = computeStats(for: city, growthModifiers: false, hypothetical: true)   // Unciv compares constructions without the growth curve
        // Unciv `buildings` / `units`: `.filterNot { (civInfo.isHuman() && it.name in city.disabledConstructions) || ... }` -
        // the only place the city's disabled constructions are read; every choice below draws from these two lists
        let unitsBuildable = buildableUnits(for: city).filter { !(civ.isPlayer && city.disabledConstructions.contains($0.name)) }
        let buildingsBuildable = buildableBuildings(for: city).filter { !(civ.isPlayer && city.disabledConstructions.contains($0.name)) }
        if civ.isPlayer && GameState.evlogOn && !city.disabledConstructions.isEmpty { hbr("C2.disabledFiltered", civ.id) }
        let totalPop = cities(of: city.civId).reduce(0) { $0 + $1.population }
        for b in buildingsBuildable where !shouldAvoid(b.name) {
            if b.isWonder && city.isPuppet { continue }
            if b.isWonder && (!overAverage || totalPop < 12) { continue }
            addChoice(.building(b.name), Float(valueOfBuilding(b, city: city, baseline: baseline, overAverage: overAverage, atWar: atWar, personality: personality, empire: empireStats)))
        }
        if !city.isPuppet {
            // addSpaceshipPartChoice: `(nonWonders + units).filter { it.name in spaceshipParts }.filterBuildable().firstOrNull()`
            // - the buildings come first in that sequence, then the units.
            if overAverage, civUniques(city.civId).contains(where: { $0.pattern == "Enables construction of Spaceship parts" }) {
                let parts = spaceResources()
                if let part = buildingsBuildable.first(where: { !$0.isAnyWonder && !shouldAvoid($0.name) && parts.contains($0.name) }) { addChoice(.building(part.name), 20) }
                else if let part = unitsBuildable.first(where: { !shouldAvoid($0.name) && parts.contains($0.name) }) { addChoice(.unit(part.name), 20) }
            }
            // addWorkerChoice: units with BuildImprovements that allowAutomatedConstruction lets us build
            if let w = unitsBuildable.filter({ !$0.improvementFilters.isEmpty && !shouldAvoid($0.name) && allowSpendingResource(city.civId, unit: $0, building: nil, city: city) }).min(by: { $0.cost < $1.cost }) {
                // Unciv: Float throughout - `cities * 1.8f`, `9f + 1.3f * (cities - 5)`, `workers + 0.17f`
                let wanted: Float = cityCount <= 1 ? 1 : cityCount <= 5 ? Float(cityCount) * Float(1.8) : 9 + Float(1.3) * Float(cityCount - 5)
                if workers < wanted { addChoice(.unit(w.name), wanted / (workers + Float(0.17))) }
            }
            // addWorkBoatChoice
            let boats = unitsBuildable.filter({ $0.createsWaterImprovements && !shouldAvoid($0.name) && allowSpendingResource(city.civId, unit: $0, building: nil, city: city) })
            if let boat = boats.min(by: { $0.cost < $1.cost }) {
                let twoTurns = (boats.map { $0.movement }.max() ?? boat.movement) * 2
                let alreadyHas = map.tilesWithin(city.coord, radius: twoTurns).flatMap { units(at: $0) }.contains { $0.civId == city.civId && $0.isCivilian && $0.def.createsWaterImprovements }
                if !alreadyHas && workBoatTileWorthImproving(city) { addChoice(.unit(boat.name), 6) }
            }
            // addMilitaryUnitChoice
            if ProcessInfo.processInfo.environment["CHOICE_CITY"] == city.name { print("MILE t=\(uncivTurns) \(city.name) atWar=\(atWar) over=\(overAverage) deficit=\(unitSupplyDeficit(city.civId)) goldNext=\(netGoldPerTurn(city.civId)) mil=\(militaryUnits) cities=\(cityCount) gold=\(civ.gold) units=\(civUnits.count) milList=\(civUnits.filter { $0.isMilitary }.map { $0.name }.sorted().joined(separator: ","))") }
            if (atWar || overAverage) && unitSupplyDeficit(city.civId) == 0 && (atWar || (netGoldPerTurn(city.civId) >= 0 && militaryUnits <= max(7, cityCount * 5))) && civ.gold >= -50 {
                if let mil = chooseMilitaryUnit(for: city, availableUnits: unitsBuildable.filter { !shouldAvoid($0.name) }) {
                    // Unciv: `cities.toFloat() / (militaryUnits + 1)`, `1 + sqrt(ratio) / 2` - Float arithmetic
                    let ratio = Float(cityCount) / Float(militaryUnits + 1)
                    var modifier: Float = 1 + ratio.squareRoot() / 2
                    if atWar { modifier *= 2 }
                    if afraidOfBarbarians(city.civId) { modifier = 2 }
                    if !overAverage { modifier /= 5 }
                    // Unciv: `centerTile.civilianUnit` that can found a city, and no military unit of ours in the expand range
                    if units(at: city.coord).contains(where: { $0.isCivilian && $0.def.isSettler }) && !map.tilesWithin(city.coord, radius: rs.constants.cityExpandRange).flatMap({ units(at: $0) }).contains(where: { $0.isMilitary && $0.civId == city.civId }) { modifier = 5 }
                    if !isAIOrAutoPlaying(civ.id) { modifier /= 2; if GameState.evlogOn { hbr("C3.militaryHalf", civ.id) } }   // Unciv: players prefer to make their own unit choices
                    modifier *= Float(personality.modifierFocus(.military, 0.3))
                    addChoice(.unit(mil.name), modifier)
                }
            }
        }
        let chosen: Production?
        if choices.isEmpty {
            chosen = nil
            let conversions = productionConversions(for: city.civId)
            // Unciv: Science (unless all techs), Gold, Culture (unless `policies.allPoliciesAdopted(true)` - no
            // ruleset policy isAdoptable with the era check), Faith (StatConversion.isBuildable: religion on), else Idle
            let allPolicies = !rs.policyBranches.contains { b in canOpenBranch(civ, b) || b.policies.contains { canAdopt(civ, policy: $0) } }
            // Unciv `cityConstructions.currentConstructionName() == chosenConstruction.name` before setCurrentConstruction -
            // the raw name: "" for an empty queue (not Idle's "Nothing", which only getConstruction("") turns it into), so a
            // human city whose queue ran empty and gets Idle is told "[city] has started working on [Nothing]"
            let oldName = city.convertProductionTo
            if conversions.contains("Science") && !allTechs { cities[ci].convertProductionTo = "Science" }
            else if conversions.contains("Gold") { cities[ci].convertProductionTo = "Gold" }
            else if conversions.contains("Culture") && !allPolicies { cities[ci].convertProductionTo = "Culture" }
            else if conversions.contains("Faith") && religionEnabled { cities[ci].convertProductionTo = "Faith" }
            else { cities[ci].convertProductionTo = City.idleConstruction }   // setCurrentConstruction(PerpetualConstruction.Idle.name)
            cities[ci].currentProduction = nil
            // Unciv: the notification follows setCurrentConstruction for a perpetual choice too - not in resistance, not for
            // the AI, only when the decision changed ("still notify for puppets")
            let newName = cities[ci].convertProductionTo.isEmpty ? "Nothing" : cities[ci].convertProductionTo
            if civ.isPlayer && !epochsAutoplay && city.resistanceTurns == 0 && oldName != newName && !epochsCityScreenOpen { notify(city.civId, "[\(city.name)] has started working on [\(newName)]", category: .Production, icons: ["StatIcons/Production"], actions: [.location(city.coord), .city(city.coord)]) }   // NotificationIcon.Construction, CityAction.withLocation
            return
        } else {
            // Unciv: `maxBy { (it.choiceModifier / it.remainingWork.coerceAtLeast(1)).coerceAtLeast(0f) }` -
            // the division is Float there, and `maxBy` keeps the FIRST maximum, which Swift's `max(by:)` also
            // does. Only the arithmetic was ours: in Double two candidates that tie in the reference come
            // apart in the last digits and a different building wins.
            func key(_ c: ConstructionChoice) -> Float { max(0, c.modifier / Float(max(1, c.remainingWork))) }
            chosen = choices.max { key($0) < key($1) }?.choice
        }
        if epochsDebug, let want = epochsRankCity, city.name == want {
            let tbl = choices.sorted { max(0, $0.modifier / Float(max(1, $0.remainingWork))) > max(0, $1.modifier / Float(max(1, $1.remainingWork))) }
                .map { "\($0.choice.name.replacingOccurrences(of: " ", with: "_"))=\(max(0, $0.modifier / Float(max(1, $0.remainingWork))))(mod\($0.modifier)/rem\($0.remainingWork))" }
                .joined(separator: " ")
            let per = cities(of: city.civId).map { "\($0.name):\(currentCityStats($0.id).total.production):\(($0.currentProduction?.name ?? "Nothing").replacingOccurrences(of: " ", with: "_"))" }.joined(separator: ";")
            print("CHOICEE t=\(turn) \(city.name) chosen=\((chosen?.name ?? "-").replacingOccurrences(of: " ", with: "_")) prod=\(cityProduction) avg=\(averageProduction) over=\(overAverage) was=\((cities[ci].currentProduction?.name ?? "Nothing").replacingOccurrences(of: " ", with: "_")) percity=\(per) | " + tbl)
        }
        let previous = cities[ci].currentProduction
        cities[ci].convertProductionTo = ""
        cities[ci].currentProduction = chosen
        // Unciv noNotification: in resistance, an AI, the same decision, or `UncivGame.Current.screen is CityScreen`
        if civ.isPlayer && !epochsAutoplay && city.resistanceTurns == 0 && previous != chosen && !epochsCityScreenOpen, let picked = chosen { notify(city.civId, "[\(city.name)] has started working on [\(picked.name)]", category: .Production, icons: ["StatIcons/Production"], actions: [.location(city.coord), .city(city.coord)]) }   // Unciv ConstructionAutomation (auto-assigned production): NotificationIcon.Construction, CityAction.withLocation
        if epochsDebug && (turn % 25 == 0 || automatingPlayer) {
            var parts: [String] = []
            for c in cities(of: city.civId) {
                let st = computeStats(for: c)
                var tiles: [String] = []
                for w in c.workedTiles {
                    let p = uncivPosition(w)
                    let y = map[w].map { tileStats($0, civId: c.civId, city: c).production } ?? -1
                    let terr = map[w]?.baseTerrain ?? "?"
                    let imp = map[w]?.improvement ?? "-"
                    let blk = isBlockaded(w, for: c.civId) ? "|ABLUKA" : ""
                    tiles.append("\(p.x),\(p.y)=\(y)[\(terr)/\(imp)\(blk)]")
                }
                parts.append("\(c.name):\(st.total.production):tiles\(st.tileYields.production):bld\(st.buildingYields.production):pop\(c.population):worked{\(tiles.joined(separator: "+"))}:\(c.currentProduction?.name ?? "Nothing")")
            }
            print("AIDBG build t\(turn) \(civ.nation)/\(city.name) prod=\(cityProduction) avg=\(averageProduction) percity=" + parts.joined(separator: ";") + " chosen=\(chosen?.name ?? "-")")
        }
    }

    /// Unciv addWorkBoatChoice.findTileWorthImproving: BFS over explored water (and city centres) we may enter, up to workboatAutomationSearchMaxTiles
    private func workBoatTileWorthImproving(_ city: City) -> Bool {
        guard let civ = civ(city.civId) else { return false }
        let maxTiles = rs.constants.workboatAutomationSearchMaxTiles
        let workRange = rs.constants.cityWorkRange
        func passable(_ t: Tile) -> Bool {
            guard t.isWater || t.isCityCenter, civ.explored.contains(t.coord) else { return false }
            // Unciv `getOwner() == null || isFriendlyTerritory(civInfo)`: a friendly or allied city-state's water
            // counts too, not only our own and open borders
            return t.ownerCivId == nil || isFriendlyTerritory(t.coord, for: city.civId)
        }
        /// Unciv isWorthImproving: `getOwner() == civInfo`, WorkerAutomation.hasWorkableSeaResource, isNotBonusResourceOrWorkable
        func worthImproving(_ t: Tile) -> Bool {
            guard t.ownerCivId == city.civId, hasWorkableSeaResourceTile(t.coord, civId: city.civId), let r = t.resource.flatMap({ rs.resources[$0] }) else { return false }
            return r.resourceType != "Bonus" || cities(of: city.civId).contains { $0.coord.distance(to: t.coord) <= workRange }   // `civInfo.cities.any { it.tilesInRange.contains(tile) }`
        }
        var reached: Set<HexCoord> = [city.coord]
        var queue = [city.coord]; var i = 0
        repeat {
            guard i < queue.count else { break }
            let c = queue[i]; i += 1
            if let t = map[c], worthImproving(t) { return true }
            for n in map.neighbors(of: c) where !reached.contains(n) { if let t = map[n], passable(t) { reached.insert(n); queue.append(n) } }
        } while reached.count < maxTiles
        return false
    }

    /// Unciv ConstructionAutomation.getValueOfBuilding
    private func valueOfBuilding(_ b: BuildingDef, city: City, baseline: CityStats, overAverage: Bool, atWar: Bool, personality: PersonalityDef, empire: Stats) -> Double {
        var value = 0.0
        let vStats = applyBuildingStats(b, city: city, baseline: baseline, personality: personality, empire: empire)
        let vMil = militaryBuildingValue(b, city: city, atWar: atWar, overAverage: overAverage, personality: personality)
        let vVic = victoryBuildingValue(b, city: city, overAverage: overAverage, personality: personality)
        let vOne = onetimeUniqueBonuses(b, city: city, personality: personality)
        // Unciv adds the four terms one at a time into a Float accumulator, so it rounds four times.
        value = Stats.f32(Stats.f32(Stats.f32(vStats + vMil) + vVic) + vOne)
        // Which of Unciv's four terms a building's value comes from. A difference that moves every building
        // in the list by the same amount is not a per-building stat: it is one of these turning on.
        if epochsDebug, let want = epochsRankCity, city.name == want {
            print("BVAL t=\(turn) \(city.name)/\(b.name) total=\(String(format: "%.2f", value)) stats=\(String(format: "%.2f", vStats)) mil=\(String(format: "%.2f", vMil)) vic=\(String(format: "%.2f", vVic)) one=\(String(format: "%.2f", vOne))")
        }
        return value
    }
    private func onetimeUniqueBonuses(_ b: BuildingDef, city: City, personality: PersonalityDef) -> Double {
        var value = 0.0
        // Unciv asks `building.hasUnique(UniqueType.X)` with no state, i.e. GameContext.EmptyState: no civ, no
        // city. Every conditional that needs a civ is then false (checkOnCiv), so the Statue of Zeus's
        // "<vs cities> <when attacking>" Strength and the Great Wall's "<before discovering [Dynamite]>" never
        // count. Evaluated against the city, Osaka's Great Wall scored 10.6 (declareWar 7 on top) where Unciv's
        // scores 3.6, and Osaka started the wonder instead of Barracks (settled, turn 90).
        let uctx = UniqueContext(civId: -1)
        let has: (String) -> Bool = { p in b.uniqueObjects.contains { $0.pattern == p && self.conditionalsHold($0, uctx) } }
        if b.isWonder {
            if !b.isNationalWonder {
                // Unciv `getAliveMajorCivs().sortedByDescending { getStatForRanking(Technologies) }` - stable,
                // and civs tie on tech count all game, so an unstable sort moves us up and down the ranking
                // for free and the wonder's penalty moves with it.
                let ranked = majorCivs.filter { $0.isAlive }.enumerated().sorted { (-self.researchedTechnologiesSize($0.element), $0.offset) < (-self.researchedTechnologiesSize($1.element), $1.offset) }.map { $0.element }
                value = Stats.f32(value - Double(ranked.firstIndex { $0.id == city.civId } ?? 0))
            }
            if has("Free Social Policy") || has("[] Free Social Policies") { value = Stats.f32(value + personality.culture) }
            else if has("Free Technology") || has("[] Free Technologies") { value = Stats.f32(value + personality.science) }
            else if has("[] free [] units appear") || has("Free [] appears") { value = Stats.f32(value + personality.production) }
            else if has("Free Great Person") { value = Stats.f32(value + personality.science) }
            else if has("Empire enters golden age") || has("[]% Golden Age length") || has("Empire enters a []-turn Golden Age") { value = Stats.f32(value + personality.expansion) }
            else if has("Enemy [] units must spend [] extra movement points when inside your territory") { value = Stats.f32(value + personality.declareWar) }
            else if has("[] population []") || has("[] population in a random city") { value = Stats.f32(value + personality.food) }
            else if has("[]% [] from Trade Routes") { value = Stats.f32(value + personality.gold) }
            else if has("[]% Strength") { value = Stats.f32(value + personality.military) }   // Unciv UniqueType.Strength
            else if has("[]% [] []") { value = Stats.f32(value + personality.culture) }   // StatPercentBonusCities
        } else {
            if has("Creates a [] improvement on a specific tile") { value = Stats.f32(value + 5) }
            else if has("Provides [] []") { value = Stats.f32(value + 3) }
            else if has("[]% [] from every []") { value = Stats.f32(value + 1.5) }
            else if let req = b.requiredResource, rs.units.values.contains(where: { $0.isSpaceshipPart && $0.requiredResource == req }) { value = Stats.f32(value - 4) }
        }
        return value
    }
    private func victoryBuildingValue(_ b: BuildingDef, city: City, overAverage: Bool, personality: PersonalityDef) -> Double {
        guard overAverage else { return 0 }
        var value = 0.0
        if b.uniqueObjects.contains(where: { $0.pattern == "Triggers a Cultural Victory upon completion" || $0.pattern == "Triggers victory" }) { value = Stats.f32(value + 20) }
        if b.uniques.contains("Enables construction of Spaceship parts") { value = Stats.f32(value + Stats.f32(10 * personality.modifierFocus(.science, 0.3))) }
        return value
    }
    private func militaryBuildingValue(_ b: BuildingDef, city: City, atWar: Bool, overAverage: Bool, personality: PersonalityDef) -> Double {
        var value = 0.0
        var warModifier = atWar ? 1.0 : 0.5
        if knownCivs(city.civId).compactMap({ foreignCityNearCapital(of: $0.id, foreignCiv: city.civId) }).contains(where: { $0.city.id == city.id }) { warModifier *= 2 }
        // Unciv: building.cityHealth / city.getMaxHealth(), building.cityStrength / (city.getStrength() + 3)
        let maxHealth = Double(City.maxHealth) + city.buildings.reduce(0.0) { $0 + Double(rs.buildings[$1]?.cityHealth ?? 0) }
        value = Stats.f32(value + Stats.f32(Stats.f32(Stats.f32(warModifier * Double(b.cityHealth)) / maxHealth) * personality.inverseModifierFocus(.aggressive, 0.3)))
        // Unciv City.getStrength is the sum of the built buildings' cityStrength alone - zero in a city without
        // walls - not the combat strength, which also carries the population, the era and the garrison.
        let builtStrength = city.builtBuildingObjects.reduce(0.0) { $0 + (rs.buildings[$1]?.cityStrength ?? 0) }   // Unciv City.getStrength: getBuiltBuildings()
        value = Stats.f32(value + Stats.f32(Stats.f32(Stats.f32(warModifier * b.cityStrength) / (builtStrength + 3)) * personality.inverseModifierFocus(.aggressive, 0.3)))
        for u in b.uniqueObjects where u.pattern == "New [] units start with [] XP []" {
            var m = Stats.f32(u.double(1) / 5)
            m = Stats.f32(m * (overAverage ? 1 : 0.2))
            m = Stats.f32(m * personality.modifierFocus(.military, 0.3))
            m = Stats.f32(m * max(1, personality.modifierFocus(.aggressive, 0.2)))
            value = Stats.f32(value + m)
        }
        if b.uniques.contains("Enables nuclear weapon") && !civUniques(city.civId).contains(where: { $0.pattern == "Enables nuclear weapon" }) { value = Stats.f32(value + Stats.f32(10 * personality.modifierFocus(.military, 0.3))) }
        return value
    }
    /// Unciv ConstructionAutomation.applyBuildingStats – stat difference from adding the building, weighted.
    private func applyBuildingStats(_ b: BuildingDef, city: City, baseline: CityStats, personality: PersonalityDef, empire: Stats) -> Double {
        var withBuilding = city
        withBuilding.buildings.append(b.name)
        let withStats = computeStats(for: withBuilding, growthModifiers: false, hypothetical: true)
        // Unciv's Stats are Float and every step below rounds there; ours were Double and rounded nowhere,
        // so two buildings that tie in the reference could come apart here and pick a different winner.
        var diff = (withStats.total - baseline.total).f32
        // Unciv subtracts the two cities' `currentCityStats`, whose food is the NET figure: after the citizens eat
        // and after a NullifiesGrowth unique has taken the surplus away. Our `total.food` is the gross yield. With
        // the empire below -10 happiness ("Nullifies Growth") Unciv sees a Hospital's +5 food as 0 and values it
        // at -1.6; we valued it at 18.2 and Nicaea built a Hospital instead of a Research Lab (`settled` EV t=231).
        diff.food = Stats.f32(withStats.foodSurplus - baseline.foodSurplus)
        // Unciv's city stats carry the maintenance bill as negative gold, so its diff is net of upkeep; ours keeps
        // it in its own field, which left every building that costs gold per turn over-valued.
        diff.gold = Stats.f32(diff.gold - Double(withStats.maintenance - baseline.maintenance))
        if epochsDebug, city.name == epochsRankCity, b.name == ProcessInfo.processInfo.environment["RANK_BUILDING"] {
            print("BRAWE t=\(uncivTurns) \(b.name) gold=\(civ(city.civId)?.gold ?? 0) sfnGold=\(netGoldPerTurn(city.civId)) baseGold=\(baseline.total.gold) baseMaint=\(baseline.maintenance) withGold=\(withStats.total.gold) withMaint=\(withStats.maintenance) diff gold=\(diff.gold) faith=\(diff.faith) happy=\(diff.happiness)")
        }
        // Unciv's getBuildingStatsFromUniques adds only StatPercentBonusCities and CarryOverFood - a
        // building's happiness, its own and whatever its "[stats] [cityFilter]" uniques give, is already in
        // the stat difference, because `currentCityStats` carries happiness like any other stat. The old
        // aggregate here zeroed a unique's happiness (`st2.happiness = 0`) and this line put it back; the
        // mirrored CityStats does not zero it, so the line had become a double count.
        // Uniques not captured by the stat diff
        for u in b.uniqueObjects where u.pattern == "[]% [] []" {   // Unciv getBuildingStatsFromUniques: StatPercentBonusCities
            // Unciv: `civInfo.stats.statsForNextTurn[statType] * relativeAmount` - the empire's NET figure, the
            // one the stats overview shows. We summed every city's gross total instead, which for food is the
            // yield before the citizens eat: measured on `fresh`, Orleans valued the Temple of Artemis (+10%
            // Food in all cities) at 28.40 against Unciv's 16.07 and built it instead of Stone Works.
            let stat = u.param(1)
            let sfn = civ(city.civId)?.statsForNextTurn ?? empire
            if epochsDebug, let want = epochsRankCity, city.name == want {
                print("BPCT t=\(turn) \(city.name)/\(b.name) pattern=\(u.pattern) stat=\(stat) pct=\(u.double(0)) sfn=\(sfn[stat]) empire=\(empire[stat]) stored=\(civ(city.civId)?.statsForNextTurn != nil)")
            }
            diff[stat] = Stats.f32(diff[stat] + Stats.f32(Stats.f32(sfn[stat] * u.double(0)) / 100))
        }
        for u in b.uniqueObjects where u.pattern == "[]% Food is carried over after population increases []" && cityMatchesFilter(u.param(1), city: city, viewer: city.civId) && u.double(0) != 0 {
            // Unciv ConstructionAutomation.getBuildingStatsFromUniques:
            //     val foodGain = cityStats.currentCityStats.food + buildingStats.food
            // The city's LIVE food, not the growthModifiers-off baseline the stat difference is measured
            // against. Unciv uses both, for different things, and we were using the baseline for both - so
            // the value of a Granary never moved as the city grew. Measured on `fresh` at turn 39: Unciv
            // valued Sparta's Granary at 11.12 and we valued it at 5.36, which is the whole reason Sparta
            // built a Monument in our game and a Granary in Unciv's.
            diff.food = Stats.f32(diff.food + Stats.f32(Stats.f32(Stats.f32(currentCityStats(city.id).foodSurplus + diff.food) * u.double(0)) / 100))
        }
        diff.food = Stats.f32(diff.food * 3); diff.production = Stats.f32(diff.production * 2); diff.gold = Stats.f32(diff.gold * 2)
        if happiness(of: city.civId) < 10 || happiness(of: city.civId) < cities(of: city.civId).count { diff.happiness = Stats.f32(diff.happiness * 3) }
        if currentCityStats(city.id).total.culture < 2 { diff.culture = Stats.f32(diff.culture * 2) }   // Unciv: the city's live currentCityStats, not the baseline
        for stat in ["Food", "Production", "Gold", "Science", "Culture", "Happiness", "Faith"] { if let pv = PersonalityDef.value(forStat: stat) { diff[stat] = Stats.f32(diff[stat] * personality.scaledFocus(pv)) } }
        if epochsDebug, let want = epochsRankCity, city.name == want {
            print("BDIFF t=\(uncivTurns) \(city.name)/\(b.name) happyCiv=\(happiness(of: city.civId)) liveCul=\(currentCityStats(city.id).total.culture) resist=\(city.resistanceTurns) live=\(cities.first { $0.id == city.id }?.resistanceTurns ?? -9) puppet=\(city.isPuppet) base=\(String(format: "%.2f", baseline.total.food)) with=\(String(format: "%.2f", withStats.total.food)) bldBase=\(String(format: "%.2f", baseline.buildingYields.food)) bldWith=\(String(format: "%.2f", withStats.buildingYields.food)) tileBase=\(String(format: "%.2f", baseline.tileYields.food)) tileWith=\(String(format: "%.2f", withStats.tileYields.food)) surplusBase=\(String(format: "%.2f", baseline.foodSurplus)) food=\(String(format: "%.2f", diff.food)) prod=\(String(format: "%.2f", diff.production)) gold=\(String(format: "%.2f", diff.gold)) sci=\(String(format: "%.2f", diff.science)) cul=\(String(format: "%.2f", diff.culture)) faith=\(String(format: "%.2f", diff.faith)) happy=\(String(format: "%.2f", diff.happiness))")
        }
        return rankStatsValue(diff, civId: city.civId)

    }
}

extension GameState {
    /// Sum of every city's stats for the civ, computed once per turn (construction ranking needs it per candidate building).
}
