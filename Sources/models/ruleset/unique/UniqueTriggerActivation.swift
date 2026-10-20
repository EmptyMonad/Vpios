// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `models/ruleset/unique/UniqueTriggerActivation.kt`: firing a triggered unique.
extension GameState {
    /// Unciv Civilization.forEachTriggeredUnique (+ City.forEachLocalTriggeredUnique when a city is given, + the unit's
    /// own triggered uniques when a unit is given - Unciv runs that second pass for the founding, conquering and
    /// improvement triggers): every unique carrying a trigger conditional that `matches`, activated with that
    /// conditional stripped.
    @discardableResult
    func triggerConditionalUniques(civId: Int, cityId: Int? = nil, unitId: Int? = nil, triggerText: String? = nil, matches: (Unique) -> Bool) -> Bool {
        let city = cityId.flatMap { self.city($0) }
        let unit = unitId.flatMap { self.unit($0) }
        var pool = civTriggerPool(civId, includeCities: true)
        // City.forEachLocalTriggeredUnique: the city's built buildings' LOCAL uniques (again - the civ pass above
        // already walked all of them) and its religion's.
        if let c = city { pool += uniqueMapAllUniques(builtBuildingUniques(c)).filter { $0.isLocalEffect } + religionUniques(for: c) }
        if let u = unit { pool += u.promotionUniques }
        let state = triggerCallerContext(civId: civId, city: city, unit: unit)
        let triggered = multiplied(pool.filter { $0.conditionals.contains(where: matches) }, state).map { $0.withoutConditionals(where: matches) }
        guard !triggered.isEmpty else { return false }
        return triggerUniques(triggered, civId: civId, cityId: cityId, unitId: unitId, triggerText: triggerText)
    }

    /// Unciv MapUnit.getTriggeredUniques + triggerUnique(unique, unit): the unit's OWN uniques only (`tempUniquesMap`:
    /// base unit, type, promotions, statuses) - never the civ's. A unique addressed to "Target Unit" acts on the
    /// other combatant (Battle.triggerCombatUniques / triggerDamageUniquesForUnit), everything else on this unit, in
    /// the order the uniques come.
    @discardableResult
    func triggerUnitConditionalUniques(unit: Unit, targetUnitId: Int? = nil, triggerText: String? = nil, matches: (Unique) -> Bool) -> Bool {
        let state = triggerCallerContext(civId: unit.civId, city: nil, unit: unit)
        let triggered = multiplied(unit.promotionUniques.filter { $0.conditionals.contains(where: matches) }, state).map { $0.withoutConditionals(where: matches) }
        guard !triggered.isEmpty else { return false }
        var fired = false
        for u in triggered {
            if u.param(0) == "Target Unit", let t = targetUnitId, let tu = self.unit(t) {
                fired = triggerUniques([u], civId: tu.civId, cityId: nil, unitId: t, triggerText: triggerText) || fired
            } else {
                fired = triggerUniques([u], civId: unit.civId, cityId: nil, unitId: unit.id, triggerText: triggerText) || fired
            }
        }
        return fired
    }

    /// The state Unciv's trigger callers check a unique's conditionals against before calling triggerUnique:
    /// `unit.cache.state` (GameContext(unit)), `city.state` (GameContext(city)) or `civInfo.state`.
    private func triggerCallerContext(civId: Int, city: City?, unit: Unit?) -> UniqueContext {
        if let u = unit { return UniqueContext(civId: u.civId, unit: u, tile: map[u.coord]) }
        if let c = city { return UniqueContext(civId: c.civId, city: c, tile: map[c.coord]) }
        return UniqueContext(civId: civId)
    }

    /// Unciv TileMap.getTilesAtDistance: the ring in Unciv's own order (the centre for 0).
    private func uncivTilesAtDistance(_ c: HexCoord, _ d: Int) -> [HexCoord] {
        if d <= 0 { return [c] }
        return map.tilesInDistanceUncivOrder(c, radius: d).filter { $0.distance(to: c) == d }
    }

    /// Unciv UnitManager.addUnit(baseUnit, city): the civ's own version of the unit, placed near the given city - or,
    /// for a water unit that city cannot launch, near a random naval city (preferring one not in resistance); with
    /// no city, a random city not in resistance. `city.state` / `civ.state` seeds the choice.
    @discardableResult
    func unitManagerAddUnit(civId: Int, _ base: UnitDef, city: City?) -> Unit? {
        let owned = cities(of: civId)
        guard !owned.isEmpty else { return nil }
        var rng = city.map { stateBasedRandom("UnitManager.addUnit", city: $0) } ?? stateBasedRandom("UnitManager.addUnit", civId: civId)
        let unit = equivalentUnit(civId, base)
        let notInResistance = owned.filter { $0.resistanceTurns == 0 }
        func isNaval(_ c: City) -> Bool { map[c.coord]?.isWater == true || cityMatchesFilter("Coastal", city: c, viewer: c.civId) }   // Unciv City.isNaval
        let cityToAddTo: City?
        if unit.isWater && (city.map(isNaval) ?? false) { cityToAddTo = city }
        else if unit.isWater { cityToAddTo = rng.pick(notInResistance.filter(isNaval)) ?? rng.pick(owned.filter(isNaval)) }
        else if let c = city { cityToAddTo = c }
        else { cityToAddTo = rng.pick(notInResistance) ?? rng.pick(owned) }
        guard let target = cityToAddTo, let placed = spawnUnit(unit.name, civId: civId, at: target.coord) else { return nil }
        if unit.isGreatPerson {
            notify(civId, "A [\(unit.name)] has been born in [\(target.name)]!", category: .General, icons: [unit.name], actions: [.unit(placed.coord, placed.id)])   // MapUnitAction(placedUnit)
        }
        return placed
    }

    /// Unciv BaseUnit.getMatchingUniques(MaxNumberBuildable) (EmptyState) → the smallest limit, if any.
    private func maxNumberBuildable(_ def: UnitDef) -> Int? {
        def.uniqueObjects.filter { $0.pattern == "Limited to [] per Civilization" && conditionalsHold($0, UniqueContext(civId: -1)) }.map { $0.int(0) }.min()
    }

    /// Unciv `civUnit.isCityFounder() && civInfo.isOneCityChallenger()`.
    private func isBarredCityFounder(_ def: UnitDef, civId: Int) -> Bool {
        def.isSettler && settings.oneCityChallenge && (civ(civId)?.isPlayer ?? false)
    }

    /// Unciv City.addGameResource: stockpiled resources to the city, production into the current construction,
    /// food into the store; anything else to the civ.
    private func cityAddGameResource(_ city: City, _ name: String, _ amount: Int) {
        if let r = rs.resources[name] {
            guard r.isStockpiled else { return }
            gainStockpiledResource(cityId: city.id, name, amount)
            return
        }
        guard let idx = cityIndex(city.id) else { return }
        switch name {
        case "Production": cities[idx].productionStored += Double(amount)   // cityConstructions.addProductionPoints
        case "Food", "Stored Food": cities[idx].foodStored += Double(amount)
        default: addGameResource(city.civId, name, amount)
        }
    }

    /// Unciv City.getGameResource / Civilization.getGameResource.
    private func gameResourceAmount(_ name: String, city: City?, civId: Int) -> Int {
        if rs.resources[name] != nil {
            if let c = city { return availableResourceAmount(c, name) }
            return resourceCounts(civId)[name] ?? 0
        }
        if name == "Stored Food", let c = city { return Int(c.foodStored) }
        if name == "Golden Age points" { return Int(civ(civId)?.goldenAgePoints ?? 0) }
        return statReserve(name, city: city, civId: civId)
    }

    /// Returns true when at least one unique was applied (Unciv UniqueTriggerActivation.triggerUnique result, used by
    /// the ruins lottery): a trigger whose Unciv `getTriggerFunction` returns null, or whose function returns false,
    /// counts as not applied.
    @discardableResult
    func triggerUniques(_ uniques: [Unique], civId: Int, cityId: Int?, unitId: Int? = nil, notification: String? = nil, triggerText: String? = nil, sourceTech: String? = nil, sourcePolicy: String? = nil, tile: HexCoord? = nil) -> Bool {
        guard let ci = civIndex(civId) else { return false }
        var fired = false
        /// Unciv getNotificationText: the caller's notification (ruins text, placeholders filled), else the effect text
        /// followed by the trigger text, else nothing. Effects Unciv only announces through the caller's notification
        /// pass `nil`.
        func say(_ defaultText: String?, _ fill: [String] = [], category: NotificationCategory = .General, icons: [String] = [], coord: HexCoord? = nil, actions: [NotificationAction] = []) {
            let text: String?
            if let n = notification, !n.isEmpty {
                text = fill.reduce(n) { t, v in t.range(of: #"\[[^\]]*\]"#, options: .regularExpression).map { t.replacingCharacters(in: $0, with: "[\(v)]") } ?? t }
            } else if let d = defaultText, let tt = triggerText {
                // Unciv: translations.triggerNotificationEffectBeforeCause(settings.language) picks the order
                text = Translations.shared.effectBeforeCause ? "{\(d)}{ }{\(tt)}" : "{\(tt)}{ }{\(d)}"
            } else { text = nil }
            if let text { notify(civId, text, category: category, icons: icons, actions: actions, coord: coord) }
        }
        // Unciv getTriggerFunction(unique, civInfo, city, unit, tile = city?.getCenterTile() ?: unit?.currentTile) - or
        // the caller's own tile, as GameStarter's `triggerUnique(unique, civ, tile = startingLocation)`
        let explicitCity: City? = cityId.flatMap { self.city($0) }
        let triggerUnit: Unit? = unitId.flatMap { self.unit($0) }
        let triggerTile: HexCoord? = tile ?? explicitCity?.coord ?? triggerUnit?.coord
        // relevantCity = city ?: tile?.getCity(); chosenCity = relevantCity ?: the capital
        let relevantCity: City? = explicitCity ?? triggerTile.flatMap { owningCity($0) }
        let chosenCity: City? = relevantCity ?? cities(of: civId).first { $0.isCapital }
        func applicableCities(_ filter: String) -> [City] {
            filter == "in this city" ? (relevantCity.map { [$0] } ?? []) : cities(of: civId).filter { cityMatchesFilter(filter, city: $0, viewer: civId) }
        }
        var ctx = triggerCallerContext(civId: civId, city: explicitCity, unit: triggerUnit)
        ctx.sourceTech = sourceTech; ctx.sourcePolicy = sourcePolicy
        func speedModified(_ u: Unique) -> Bool { u.conditionals.contains { $0.pattern == "(modified by game speed)" } }
        for u in uniques {
            // Unciv: the `<for [n] turns>` modifier turns the unique into a TemporaryUnique, whatever else it says -
            // conditionalsApply lets a timed unique through, and its other conditionals are judged on the stored copy.
            if let turns = u.timedTurns {
                let source = sourcePolicy ?? sourceTech ?? u.sourceObjectName
                let type: UniqueTarget? = sourcePolicy != nil ? .policy : sourceTech != nil ? .tech : u.sourceObjectType
                addTemporaryUnique(u, turns: turns, civId: civId, source: source, sourceType: type)
                if ["Provides [] []", "Consumes [] []", "[]% of [] from every [] in the city added to []"].contains(u.pattern) { updateCivResources(civId) }
                fired = true
                continue
            }
            // Unciv's callers check the conditionals against their own state before triggering; ours hand the lists over.
            guard conditionalsHold(u, ctx) else { continue }
            var ok = true
            switch u.pattern {
            case "Triggers a [] event": ok = triggerEvent(u.param(0), civId: civId, unitId: unitId, triggerUniqueText: u.text)
            case "Mark tutorial [] complete": Tutorial.markTaskDone(u.param(0))
            case "Play [] sound":
                // Unciv PlaySound: `if (civInfo.isAIOrAutoPlaying()) return null` (or an empty / unknown sound);
                // for a human it plays and counts as having had an effect. The sound itself is not part of the game.
                if isAIOrAutoPlaying(civs[ci].id) || u.param(0).isEmpty { ok = false }
            case "Comment []":
                ok = false   // not triggerable: getTriggerFunction returns null
            case "Choose a music track for [], [], []":
                // Unciv UniqueTriggerActivation.ChooseMusic: skipped for AI / autoplay; like Unciv, suffixes and flags both come from the second parameter.
                guard !isAIOrAutoPlaying(civs[ci].id) else { ok = false; break }
                let prefix = u.param(0).lowercased() == "this civ" ? civs[ci].nation : u.param(0)
                let parts = u.param(1).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                var flags: MusicTrackChooserFlags = []
                for part in parts {
                    switch part.lowercased() {
                    case "prefixmustmatch": flags.insert(.prefixMustMatch)
                    case "suffixmustmatch": flags.insert(.suffixMustMatch)
                    case "slowfade": flags.insert(.slowFade)
                    case "playdefaultfile": flags.insert(.playDefaultFile)
                    default: break
                    }
                }
                DispatchQueue.main.async { MusicController.shared.chooseTrack(prefix: prefix, suffixes: parts, flags: flags) }
            case "Get the leader title of []":
                guard civs[ci].isMajor else { ok = false; break }
                civs[ci].leaderTitle = u.param(0)   // Unciv stores the raw title; getLeaderDisplayName fills in the leader
                if let n = notification { notify(civId, n, category: .Diplomacy) }

            case "Free [] appears":   // Unciv OneTimeFreeUnit
                guard let base = rs.units[u.param(0)] else { ok = false; break }
                let civUnit = equivalentUnit(civId, base)
                guard !isBarredCityFounder(civUnit, civId: civId) else { ok = false; break }
                if let limit = maxNumberBuildable(civUnit), limit <= units(of: civId).filter({ $0.name == civUnit.name }).count { ok = false; break }
                let placed: Unit?
                if relevantCity != nil || (triggerTile == nil && !cities(of: civId).isEmpty) { placed = unitManagerAddUnit(civId: civId, civUnit, city: chosenCity) }
                else if let t = triggerTile { placed = spawnUnit(civUnit.name, civId: civId, at: t) }
                else if let first = units(of: civId).first { placed = spawnUnit(civUnit.name, civId: civId, at: first.coord) }
                else { placed = nil }
                guard let p = placed else { ok = false; break }
                say("Gained [1] [\(civUnit.name)] unit(s)", [civUnit.name], category: .Units, icons: [p.name], actions: [.unit(p.coord, p.id)])   // MapUnitAction(placedUnit)
            case "[] free [] units appear":   // Unciv OneTimeAmountFreeUnits
                guard let base = rs.units[u.param(1)] else { ok = false; break }
                let civUnit = equivalentUnit(civId, base)
                guard !isBarredCityFounder(civUnit, civId: civId) else { ok = false; break }
                let unitCount = units(of: civId).filter { $0.name == civUnit.name }.count
                var actualAmount = u.int(0)
                if let limit = maxNumberBuildable(civUnit), actualAmount + unitCount > limit { actualAmount = limit - unitCount }
                guard actualAmount > 0 else { ok = false; break }
                var placedUnits: [Unit] = []
                for _ in 0..<actualAmount {
                    let placed: Unit?
                    if relevantCity != nil || (triggerTile == nil && !cities(of: civId).isEmpty) { placed = unitManagerAddUnit(civId: civId, civUnit, city: chosenCity) }
                    else if let t = triggerTile { placed = spawnUnit(civUnit.name, civId: civId, at: t) }
                    else if let first = units(of: civId).first { placed = spawnUnit(civUnit.name, civId: civId, at: first.coord) }
                    else { placed = nil }
                    if let p = placed { placedUnits.append(p) }
                }
                guard let firstPlaced = placedUnits.first else { ok = false; break }
                say("Gained [\(placedUnits.count)] [\(civUnit.name)] unit(s)", [civUnit.name], category: .Units, icons: [civUnit.name], coord: firstPlaced.coord, actions: placedUnits.map { .unit($0.coord, $0.id) })   // MapUnitAction(placedUnits)
            case "A [] rebels", "[] []s rebel":   // Unciv OneTimeRebel / OneTimeAmountRebels
                guard let barbId = barbarianCivId else { ok = false; break }
                let single = u.pattern == "A [] rebels"
                guard let base = rs.units[single ? u.param(0) : u.param(1)] else { ok = false; break }
                let civUnit = equivalentUnit(civId, base)
                guard !isBarredCityFounder(civUnit, civId: civId) else { ok = false; break }
                var actualAmount = 1
                if !single {
                    let unitCount = units(of: civId).filter { $0.name == civUnit.name }.count
                    actualAmount = u.int(0)
                    if let limit = maxNumberBuildable(civUnit), actualAmount + unitCount > limit { actualAmount = limit - unitCount }
                    guard actualAmount > 0 else { ok = false; break }
                }
                guard let anchor = relevantCity ?? cities(of: civId).first else { ok = false; break }
                var placed = 0
                for _ in 0..<actualAmount where spawnUnit(base.name, civId: barbId, at: anchor.coord) != nil { placed += 1 }   // the BASE unit, as TileMap.placeUnitNearTile gets it
                guard placed > 0 else { ok = false; break }
                say(single ? "[1] [\(civUnit.name)] has rebelled against us!" : "[\(placed)] [\(civUnit.name)] unit(s) have rebelled against us!", ["\(placed)", civUnit.name], category: .Units, icons: [civUnit.name], coord: anchor.coord)
            case "Free [] found in the ruins":   // Unciv OneTimeFreeUnitRuins
                guard let base = rs.units[u.param(0)] else { ok = false; break }
                var civUnit = equivalentUnit(civId, base)
                if isBarredCityFounder(civUnit, civId: civId) {
                    guard let replacement = rs.units.values.sorted(by: { $0.name < $1.name }).first(where: { $0.uniqueObjects.contains { $0.pattern == "Can build [] improvements on tiles" && $0.param(0) == "Land" } }) else { ok = false; break }
                    civUnit = equivalentUnit(civId, replacement)
                }
                let placingTile: HexCoord?
                if let t = triggerTile { placingTile = t }
                else {
                    var rng = triggerUnit.map { stateBasedRandom("UniqueTriggerActivation.getTriggerFunction", unit: $0) } ?? stateBasedRandom("UniqueTriggerActivation.getTriggerFunction", civId: civId)
                    placingTile = rng.pick(cities(of: civId))?.coord
                }
                guard let at = placingTile, let placed = spawnUnit(civUnit.name, civId: civId, at: at) else { ok = false; break }
                // Unciv: `sequence { yield(MapUnitAction(placedUnit)); yieldAll(LocationAction(tile?.position)) }`
                if notification != nil { say(nil, [u.param(0)], category: .Units, icons: [placed.name], actions: [.unit(placed.coord, placed.id)] + (triggerTile.map { [NotificationAction.location($0)] } ?? [])) }

            case "Free Social Policy":
                guard !civs[ci].isSpectator else { ok = false; break }
                civs[ci].freePolicies += 1; say("You may choose a free Policy", category: .General, icons: ["Culture"], actions: [.policy("")])   // PolicyAction()
            case "[] Free Social Policies":
                guard !civs[ci].isSpectator else { ok = false; break }
                civs[ci].freePolicies += u.int(0); say("You may choose [\(u.int(0))] free Policies", category: .General, icons: ["Culture"])
            case "Adopt []":   // Unciv OneTimeAdoptPolicyOrBelief
                let name = u.param(0)
                let isBranch = rs.policyBranches.contains { $0.name == name }
                if (rs.policies[name] != nil || isBranch) && !civs[ci].policies.contains(name) {
                    civs[ci].freePolicies += 1   // Unciv: a free policy pays for policies.adopt(policy)
                    if isBranch { adopt(civId: civId, branch: name) } else { adopt(civId: civId, policy: name) }
                    say("You gain the [\(name)] Policy", [name], category: .General, icons: ["Culture"])
                } else if let belief = rs.beliefs[name], civs[ci].pantheonBelief != nil || civs[ci].religionName != nil,
                          !civs[ci].religionBeliefs.contains(name), civs[ci].pantheonBelief != name {
                    // religionManager.religion?.hasBelief(name) == false -> chooseBeliefs(listOf(belief))
                    if belief.type == "Pantheon" && civs[ci].pantheonBelief == nil { civs[ci].pantheonBelief = name }
                    else { civs[ci].religionBeliefs.append(name) }
                    invalidateHappiness(civId)
                    say("You gain the [\(name)] Belief", [name], category: .Religion, icons: ["Faith"])
                } else { ok = false }
            case "Remove []", "Remove [] and refund []% of its cost":
                let filter = u.param(0)
                // Unciv PolicyManager.getAdoptedPoliciesMatching(forRemoval = true): branch-completion policies are never
                // removed explicitly, and the rest go in reverse ruleset order so a branch opener never precedes its members.
                let rulesetOrder = rs.policyBranches.flatMap { branch in branch.policies.map { $0.name } }
                let removable = civs[ci].orderedPolicies
                    .filter { rs.policies[$0] != nil && rs.policies[$0]?.isBranchCompletion != true && policyMatches($0, filter) }
                    .sorted { (rulesetOrder.firstIndex(of: $0) ?? -1) > (rulesetOrder.firstIndex(of: $1) ?? -1) }
                guard !removable.isEmpty else { ok = false; break }
                let refundPct = u.pattern == "Remove []" ? 0.0 : u.double(1)
                // Unciv PolicyManager.getCultureRefundMap: every removed policy refunds the cost of the slot it occupied,
                // counting down from numberOfAdoptedPolicies; a surplus beyond the policies bought with culture (FREE_POLICY_MARKER)
                // hands a free policy back instead. The whole map is computed before any removal, as in Unciv.
                var policyCostInput = civs[ci].paidPolicyCount
                civs[ci].numberOfAdoptedPolicies = policyCostInput   // normalise legacy -1 so the removals can count down
                var refunds: [(String, Int)] = []
                for p in removable {
                    policyCostInput -= 1
                    refunds.append((p, policyCostInput < 0 ? -1 : Int((policyCost(civs[ci], adoptedPolicies: policyCostInput) * refundPct / 100).rounded())))
                }
                for (p, refund) in refunds {
                    civs[ci].policies.remove(p)
                    // Unciv PolicyManager.removePolicy: a branch already marked complete reverts to incomplete
                    if let bn = rs.policyBranchOf[p], let b = rs.policyBranches.first(where: { $0.name == bn }), let done = b.completion,
                       civs[ci].policies.contains(done.name), !b.regularPolicies.allSatisfy({ civs[ci].policies.contains($0.name) }) {
                        civs[ci].policies.remove(done.name)
                    }
                    if refundPct <= 0 {
                        if civs[ci].numberOfAdoptedPolicies > 0 { civs[ci].numberOfAdoptedPolicies -= 1 }   // Unciv removePolicy
                        say("You lose the [\(p)] Policy", [p], category: .General, icons: ["Culture"])
                    } else if refund < 0 {
                        civs[ci].freePolicies += 1   // Unciv FREE_POLICY_MARKER: removePolicy(assumeWasFree = true) + freePolicies++
                        say("You lose the [\(p)] Policy. A free policy has been refunded", [p], category: .General, icons: ["Culture"])
                    } else {
                        if civs[ci].numberOfAdoptedPolicies > 0 { civs[ci].numberOfAdoptedPolicies -= 1 }   // Unciv removePolicy
                        addCulture(ci, Double(refund))   // Unciv policies.addCulture(refund)
                        say("You lose the [\(p)] Policy. [\(refund)] Culture has been refunded", [p], category: .General, icons: ["Culture"])
                    }
                }
                invalidateHappiness(civId)

            case "Empire enters golden age", "Empire enters a []-turn Golden Age":
                if u.pattern == "Empire enters a []-turn Golden Age" { startGoldenAge(civId, turns: u.int(0)) } else { startGoldenAge(civId) }
                say("You enter a Golden Age", category: .General, icons: ["Happiness"])
            case "Free Great Person":
                guard !civs[ci].isSpectator else { ok = false; break }
                civs[ci].freeGreatPeople += 1
                if let n = notification { notify(civId, n, category: .General) }
                // Unciv: the player chooses on the GreatPersonPickerScreen; the AI (or full auto-play) picks at once.
                if !civs[ci].isPlayer || autoPlayingFullAI { grantFreeGreatPeopleForAI(civId) } else if GameState.evlogOn { hbr("S6.playerPicksGreatPerson", civId) }   // UniqueTriggerActivation.kt:529: isAI() || isAutoPlayingAndFullAutoPlayAI()
            case "[] population []":   // Unciv OneTimeGainPopulation
                let applicable = applicableCities(u.param(1))
                guard !applicable.isEmpty else { ok = false; break }
                for c in applicable { if let idx = cityIndex(c.id) { addPopulation(cityIndex: idx, u.int(0)) } }
                // Unciv: LocationAction(applicableCities.map { it.location }) - every city that grew, not the first only
                if notification != nil { say(nil, category: .Cities, icons: ["Population"], actions: applicable.map { .location($0.coord) }) }
            case "[] population in a random city":   // Unciv OneTimeGainPopulationRandomCity
                guard !cities(of: civId).isEmpty else { ok = false; break }
                var g = triggerTileRandom(triggerTile)   // `civInfo.cities.random(tileBasedRandom)`
                if let c = g.pick(cities(of: civId)), let idx = cityIndex(c.id) {
                    addPopulation(cityIndex: idx, u.int(0))
                    if notification != nil { say(nil, [c.name], category: .Cities, icons: ["Population"], actions: [.location(c.coord)] + (triggerTile.map { [NotificationAction.location($0)] } ?? [])) }   // LocationAction(city, tile)
                }
            case "Free Technology", "[] Free Technologies":
                guard !civs[ci].isSpectator else { ok = false; break }
                civs[ci].freeTechs += u.pattern == "Free Technology" ? 1 : u.int(0)
                if notification != nil { say(nil, category: .General, icons: ["Science"]) }
            case "[] free random researchable Tech(s) from the []":   // Unciv OneTimeFreeTechRuins
                // ruleset.technologies.values in their json order, the era matching and canBeResearched
                let options = researchableTechs(for: civs[ci]).filter { $0.era == u.param(1) }
                guard !options.isEmpty else { ok = false; break }
                var g = triggerTileRandom(triggerTile)   // `researchableTechsFromThatEra.shuffled(tileBasedRandom)`
                let picked = Array(g.shuffled(options).prefix(u.int(0)))
                for t in picked { addTechnology(civId: civId, tech: t.name) }
                // Unciv: `LocationAction(tile?.position) + TechAction(techsToResearch.first().name)` - "Notification click
                // for first tech only"
                if notification != nil, let first = picked.first { say(nil, picked.map { $0.name }, category: .General, icons: ["Science"], actions: (triggerTile.map { [NotificationAction.location($0)] } ?? []) + [.tech(first.name)]) }
            case "Discover []":   // Unciv OneTimeDiscoverTech
                let tech = u.param(0)
                guard rs.techs[tech] != nil, !civs[ci].techs.contains(tech) else { ok = false; break }
                addTechnology(civId: civId, tech: tech)
                say("You have discovered the secrets of [\(tech)]", [tech], category: .General, icons: ["Science"])
            case "Reveals the entire map":   // Unciv OneTimeRevealEntireMap
                // Unciv: LocationAction(tile?.position) and NotificationIcon.Scout ("UnitIcons/Scout": a bare "Scout"
                // would name the unit)
                if notification != nil { say(nil, category: .General, icons: ["UnitIcons/Scout"], coord: triggerTile) }
                // `tileMap.values.forEach { it.setExplored(civInfo, true) }` - the map's tiles, not our grid's empty cells
                civs[ci].explored = Set(map.tiles.indices.filter { !map.missing.contains($0) }.map { map.tiles[$0].coord })
                checkExploredRegionForWholeMap(ci)   // each Tile.setExplored also widens a human player's exploredRegion

            case "Instantly consumes [] []", "Instantly provides [] []":   // Unciv OneTimeConsumeResources / OneTimeProvideResources
                guard let r = rs.resources[u.param(1)], r.isStockpiled else { ok = false; break }
                let amount = u.int(0) * (u.pattern == "Instantly consumes [] []" ? -1 : 1)
                if let c = explicitCity { gainStockpiledResource(cityId: c.id, r.name, amount) }
                else if !r.isCityWide { civs[ci].resourceStockpiles[r.name, default: 0] += amount; invalidateHappiness(civId) }
                say(amount < 0 ? "You have lost [\(-amount)] [\(r.name)]" : "You have gained [\(amount)] [\(r.name)]", ["\(abs(amount))", r.name], icons: [r.name])
            case "Instantly gain [] []":   // Unciv OneTimeGainResource
                let name = u.param(1)
                guard isGameResource(name), !(rs.resources[name].map { !$0.isStockpiled } ?? false) else { ok = false; break }
                var amount = u.int(0)
                if speedModified(u) { amount = Stats.roundToInt(Double(Float(amount) * (isStatName(name) ? statCostModifier(name) : Float(speed.modifier)))) }
                if let c = explicitCity { cityAddGameResource(c, name, amount) } else { addGameResource(civId, name, amount) }
                say("You have gained [\(amount)] [\(name)]", ["\(amount)", name], icons: [name])
            case "Set [] to []":   // Unciv OneTimeSetStockpile
                let name = u.param(0)
                guard isGameResource(name), !(rs.resources[name].map { !$0.isStockpiled } ?? false),
                      var amountRequired = countable(u.param(1), UniqueContext(civId: civId, city: explicitCity)) else { ok = false; break }
                if speedModified(u) { amountRequired = Stats.roundToInt(Double(Float(amountRequired) * (isStatName(name) ? statCostModifier(name) : Float(speed.modifier)))) }
                let missing = amountRequired - gameResourceAmount(name, city: explicitCity, civId: civId)
                if let c = explicitCity { cityAddGameResource(c, name, missing) } else { addGameResource(civId, name, missing) }
                say("[\(name)] has been set to [\(amountRequired)]", ["\(amountRequired)", name], icons: [name])
            case "[] units gain the [] promotion":   // Unciv UnitsGainPromotion
                guard let promotion = rs.promotions[u.param(1)] else { ok = false; break }
                let toPromote = units(of: civId).filter { unitMatches($0, u.param(0)) && (promotion.unitTypes.isEmpty || promotion.unitTypes.contains($0.def.unitType)) }
                guard !toPromote.isEmpty else { ok = false; break }
                for pu in toPromote where !(unit(pu.id)?.promotions.contains(promotion.name) ?? true) { addPromotion(unitId: pu.id, promotion.name, isFree: true) }
                if notification != nil { say(nil, category: .Units, icons: [promotion.name]) }
            case "Allied City-States will occasionally gift Great People":   // Unciv CityStateCanGiftGreatPeople
                civs[ci].civFlags["CityStateGreatPersonGift"] = turnsForGreatPersonFromCityState(civId) / 2
                if notification != nil { say(nil, category: .Diplomacy) }

            case "Gain [] []":   // Unciv OneTimeGainStat
                let stat = u.param(1)
                guard ["Gold", "Science", "Culture", "Faith", "Happiness"].contains(stat), let raw = Int(u.param(0)) else { ok = false; break }
                var statAmount = raw
                if speedModified(u) { statAmount = Stats.roundToInt(Double(Float(statAmount) * Float(statCostModifier(stat)))) }
                addGameResource(civId, stat, statAmount)   // civInfo.addStats
                say("Gained [\(statAmount >= 0 ? "+" : "")\(statAmount) \(stat)]", ["\(statAmount)"], icons: [stat], coord: triggerTile)
            case "Gain []-[] []":   // Unciv OneTimeGainStatRange
                let stat = u.param(2)
                guard ["Gold", "Science", "Culture", "Faith", "Happiness"].contains(stat), let a = Int(u.param(0)), let b = Int(u.param(1)) else { ok = false; break }
                var g = triggerTileRandom(triggerTile)   // `(minOf(a,b)..maxOf(a,b)).random(tileBasedRandom)`
                let randomValue = g.int(min(a, b)...max(a, b))
                let finalStatAmount = speedModified(u) ? Stats.roundToInt(Double(Float(randomValue) * Float(statCostModifier(stat)))) : randomValue
                addGameResource(civId, stat, finalStatAmount)
                say("Gained [+\(finalStatAmount) \(stat)]", ["\(finalStatAmount)"], icons: [stat], coord: triggerTile)
            case "Gain enough Faith for a Pantheon":   // Unciv OneTimeGainPantheon
                guard civs[ci].pantheonBelief == nil && civs[ci].religionName == nil else { ok = false; break }   // religionState != None
                // ReligionManager.faithForPantheon(additionalCivs = 2)
                let numCivs = 2 + civs.filter { $0.isMajor && ($0.pantheonBelief != nil || $0.religionName != nil) }.count
                let gainedFaith = Stats.roundToInt(Double(Float(rs.constants.pantheonBase + numCivs * rs.constants.pantheonGrowth) * Float(speed.faithCostModifier)))
                guard gainedFaith != 0 else { ok = false; break }
                addGameResource(civId, "Faith", gainedFaith)
                if notification != nil { say(nil, ["\(gainedFaith)"], category: .Religion, icons: ["Faith"], coord: triggerTile) }
            case "Gain enough Faith for []% of a Great Prophet":   // Unciv OneTimeGainProphet
                guard rs.units.values.contains(where: { $0.canFoundReligion }) else { ok = false; break }   // getGreatProphetEquivalent
                let gainedFaith = Int(Float(prophetCost(civs[ci])) * (Float(u.double(0)) / 100))   // (faithForNextGreatProphet() * (p / 100f)).toInt()
                guard gainedFaith != 0 else { ok = false; break }
                addGameResource(civId, "Faith", gainedFaith)
                if notification != nil { say(nil, ["\(gainedFaith)"], category: .Religion, icons: ["Faith"], coord: triggerTile) }
            case "Research []% of []":   // Unciv OneTimeGainTechPercent
                let tech = u.param(1)
                guard let def = rs.techs[tech], !civs[ci].techs.contains(tech), let pct = Float(u.param(0)) else { ok = false; break }
                let gain = Stats.roundToInt(Double(Float(Int(techCost(def, for: civs[ci]))) * pct / 100))
                guard gain != 0 else { ok = false; break }
                civs[ci].techsInProgress[tech, default: 0] += gain
                say("You have gained [\(gain)] Science towards researching [\(tech)]", ["\(gain)"], category: .General, icons: ["Science"], coord: triggerTile)
            case "Gain a free [] belief":   // Unciv OneTimeFreeBelief
                guard civs[ci].isMajor else { ok = false; break }
                let beliefType = u.param(0)
                if beliefType != "Pantheon" && beliefType != "Any" && civs[ci].religionName == nil { ok = false; break }
                if numberOfBeliefsAvailable(beliefType) == 0 { ok = false; break }
                // Unciv: religionIcon is the belief type, Pantheon when an "Any" belief is added as a pantheon one
                let religionIcon = beliefType == "Any" && civs[ci].religionName == nil ? "Pantheon" : beliefType
                civs[ci].freeBeliefsByType[religionIcon, default: 0] += 1
                if notification != nil { say(nil, category: .Religion, icons: ["Faith", "ReligionIcons/" + religionIcon]) }

            case "Reveal up to [] [] within a [] tile radius":   // Unciv OneTimeRevealSpecificMapTiles
                guard let origin = triggerTile else { ok = false; break }
                var explorable = map.tilesInDistanceUncivOrder(origin, radius: u.int(2))
                    .filter { !civs[ci].explored.contains($0) && (map[$0].map { tileMatches($0, u.param(1), civId: -1) } ?? false) }
                guard !explorable.isEmpty else { ok = false; break }
                if u.param(0) != "all" && u.param(0) != "All" {
                    var g = triggerTileRandom(triggerTile)
                    explorable = Array(g.shuffled(explorable).prefix(u.int(0)))
                }
                for t in explorable {
                    civs[ci].explored.insert(t)
                    checkExploredRegion(ci, [t], explorer: nil)   // Tile.setExplored: a human player's exploredRegion
                    civs[ci].lastSeenImprovement[t] = map[t]?.improvement   // civInfo.setLastSeenImprovement
                }
                // Unciv: LocationAction(positions.asSequence()) - every revealed tile - and NotificationIcon.Barbarians
                // for "Barbarian encampment" (Constants.barbarianEncampment), NotificationIcon.Scout otherwise
                // (the constants' paths: a bare "Barbarians" would name the nation and "Scout" the unit)
                if notification != nil { say(nil, category: .War, icons: [u.param(1) == "Barbarian encampment" ? "ImprovementIcons/Barbarian encampment" : "UnitIcons/Scout"], actions: explorable.map { .location($0) }) }
            case "From a randomly chosen tile [] tiles away from the ruins, reveal tiles up to [] tiles away with []% chance":   // Unciv OneTimeRevealCrudeMap
                guard let origin = triggerTile else { ok = false; break }
                // ONE tileBasedRandom: the centre (`randomOrNull`) and then a `nextFloat() < chance` per tile
                var g = triggerTileRandom(triggerTile)
                let chance = Float(u.double(2)) / 100
                guard let revealCenter = g.pick(uncivTilesAtDistance(origin, u.int(0)).filter({ !civs[ci].explored.contains($0) })) else { ok = false; break }
                // forEachTileInDistance: ring by ring, the first ring in `neighbors` order
                for d in 0...max(0, u.int(1)) {
                    let ring = d == 1 ? map.neighbors(of: revealCenter) : uncivTilesAtDistance(revealCenter, d)
                    for t in ring where g.nextFloat() < chance { civs[ci].explored.insert(t); checkExploredRegion(ci, [t], explorer: nil) }   // Tile.setExplored
                }
                updateExploration(for: civId)   // civInfo.cache.updateViewableTiles()
                if notification != nil { say(nil, category: .General, icons: ["Ruins"], coord: origin) }   // NotificationIcon.Ruins

            case "Triggers voting for the Diplomatic Victory":   // Unciv OneTimeTriggerVoting
                triggerDiplomaticVoting()
                if notification != nil { say(nil, category: .General, icons: ["Diplomacy"]) }   // NotificationIcon.Diplomacy
            case "Promotes all spies [] time(s)":   // Unciv OneTimeSpiesLevelUp: null unless a major civ with espionage on
                guard civs[ci].isMajor, espionageEnabled else { ok = false; break }
                // `espionageManager.spyList.forEach { it.levelUpSpy(unique.params[0].toInt()) }`
                for si in civs[ci].spies.indices { civs[ci].spies[si] = spyLeveledUp(civs[ci].spies[si], civId: civId, amount: u.int(0)) }
            case "Gain an extra spy":   // Unciv OneTimeGainSpy: null unless a major civ with espionage on
                guard civs[ci].isMajor, espionageEnabled else { ok = false; break }
                addSpy(civId: civId)   // espionageManager.addSpy() + "We have recruited [] as a spy!"
            case "Gain a free [] []":   // Unciv GainFreeBuildings
                guard rs.buildings[u.param(0)] != nil else { ok = false; break }
                let applicable = applicableCities(u.param(1))
                guard !applicable.isEmpty else { ok = false; break }
                for c in applicable { if let idx = cityIndex(c.id) { gainFreeBuilding(u.param(0), cityIndex: idx) } }
            case "Provides the cheapest [] building in your first [] cities for free":   // Unciv FreeStatBuildings
                guard GameState.statNames.contains(u.param(0)) else { ok = false; break }
                addFreeStatBuildings(civId, stat: u.param(0), amount: u.int(1))
            case "Provides a [] in your first [] cities for free":   // Unciv FreeSpecificBuildings
                guard rs.buildings[u.param(0)] != nil else { ok = false; break }
                addFreeBuildings(civId, building: u.param(0), amount: u.int(1))
            case "Remove [] []":   // Unciv RemoveBuilding
                let applicable = applicableCities(u.param(1))
                guard !applicable.isEmpty else { ok = false; break }
                for c in applicable {
                    for b in c.buildings where buildingMatches(b, u.param(0)) { if let idx = cityIndex(c.id) { removeBuilding(cityIndex: idx, b) } }
                }
                // Unciv: LocationAction(applicableCities.map { it.location }), NotificationIcon.Construction - whose path
                // is "StatIcons/Production"; a bare "Construction" would name the technology
                if notification != nil { say(nil, category: .Cities, icons: ["StatIcons/Production"], actions: applicable.map { .location($0.coord) }) }
            case "Sell [] buildings []":   // Unciv OneTimeSellBuilding
                let applicable = applicableCities(u.param(1))
                guard !applicable.isEmpty else { ok = false; break }
                for c in applicable {
                    for b in c.buildings where buildingMatches(b, u.param(0)) && (rs.buildings[b].map(isSellable) ?? false) {
                        guard let idx = cityIndex(c.id), cities[idx].buildings.contains(b) else { continue }
                        addGold(civId, goldForSellingBuilding(b))
                        removeBuilding(cityIndex: idx, b)
                    }
                }
                if notification != nil { say(nil, category: .Cities, icons: ["Gold"], actions: applicable.map { .location($0.coord) }) }   // LocationAction(applicableCities.map { it.location })
            case "Triggers the following global alert: []":   // Unciv OneTimeGlobalAlert
                guard let tt = triggerText else { ok = false; break }
                ok = triggerGlobalAlerts(civId: civId, alertText: u.param(0), triggerNotificationText: tt)
            case "Triggers a Cultural Victory upon completion":
                // Unciv TriggersCulturalVictory is not triggerable: getTriggerFunction's `else -> return null`. The
                // victory itself comes from the "Build [Utopia Project]" milestone at TurnManager.updateWinningCiv.
                ok = false
            case "Triggers a global alert upon completion":
                break   // Unciv: the WonderBuilt alert popup (Actions.swift completion notifications cover it)
            case "Gain control over [] tiles []":   // Unciv OneTimeTakeOverTilesInCity
                let applicable = applicableCities(u.param(1))
                guard !applicable.isEmpty, applicable.contains(where: { chooseNewTileToOwn($0) != nil }) else { ok = false; break }
                for c in applicable {
                    for _ in 0..<max(0, u.int(0)) {
                        guard let now = city(c.id), let tileToOwn = chooseNewTileToOwn(now) else { break }
                        takeOwnership(cityId: c.id, tileToOwn)
                    }
                }
                if notification != nil { say(nil, category: .Cities, icons: ["City"], actions: applicable.map { .location($0.coord) }) }   // LocationAction(applicableCities.map { it.location })
            case "Gain control over [] tiles in a []-tile radius":   // Unciv OneTimeTakeOverTilesInRadius (the Citadel)
                // Was hand-rolled in performGreatPersonAction; Unciv reaches it through setImprovement's
                // triggerImprovementUniques, the tile being the improvement's (the unit's) tile.
                guard let center = triggerTile, !cities(of: civId).isEmpty else { ok = false; break }
                let radius = u.int(1)
                guard radius >= 0 else { ok = false; break }
                let tilesToTakeOver = map.tilesWithin(center, radius: radius).filter { c in
                    guard let t = map[c] else { return false }
                    return !t.isCityCenter && tileMatches(t, u.param(0), civId: civId) && t.ownerCivId != civId
                }
                guard !tilesToTakeOver.isEmpty else { ok = false; break }
                // Lower is better
                func cityPriority(_ c: City) -> Int { c.coord.distance(to: center) + (c.razing ? 5 : 0) }
                // `flatMap { it.neighbors + it }.map { owningCity }.filter { civ == civInfo }.toSet()`: first-seen order
                var citiesWithAdjacentTiles: [City] = []
                for t in tilesToTakeOver {
                    for n in map.neighbors(of: t) + [t] {
                        guard let oc = owningCity(n), oc.civId == civId, !citiesWithAdjacentTiles.contains(where: { $0.id == oc.id }) else { continue }
                        citiesWithAdjacentTiles.append(oc)
                    }
                }
                // minByOrNull / minBy keep the first minimum
                guard let cityToAddTo = citiesWithAdjacentTiles.min(by: { cityPriority($0) < cityPriority($1) }) ?? cities(of: civId).min(by: { cityPriority($0) < cityPriority($1) }) else { ok = false; break }
                var civsToNotify: [Int] = []   // mutableSetOf: insertion order
                for c in tilesToTakeOver {
                    if let other = map[c]?.ownerCivId {
                        addModifier(other, civId, .StealingTerritory, -10)   // decrease relations for -10 pt/tile
                        if !civsToNotify.contains(other) { civsToNotify.append(other) }
                        if let oi = civIndex(other), civs[oi].isCityState {
                            addInfluence(cityState: other, major: civId, -15)
                            if !hasFlag(other, civId, "TilesStolen") { addAlert(civId, .TilesStolen, "\(other)"); setFlag(other, civId, "TilesStolen", 1) }
                        }
                    }
                    takeOwnership(cityId: cityToAddTo.id, c)
                }
                for other in civsToNotify { notify(other, "Your territory has been stolen by [\(civs[ci].nation)]!", category: .Cities, icons: [civs[ci].nation, "War"], coord: center) }

            case "[] heals [] HP":   // Unciv OneTimeUnitHeal
                guard let uid = unitId, let hu = unit(uid), hu.health != 100 else { ok = false; break }
                healBy(unitId: uid, u.int(1))
                if notification != nil { say(nil, category: .Units, icons: [hu.name, "Heal Instantly"], actions: [.unit(hu.coord, hu.id)]) }   // MapUnitAction(unit)
            case "[] takes [] damage":   // Unciv OneTimeUnitDamage: MapUnit.takeDamage, destroyed at 0
                guard let uid = unitId, let hit = unit(uid) else { ok = false; break }
                takeDamage(unitId: uid, u.int(1))   // Unciv takes the damage first, then tells with MapUnitAction(unit)
                if notification != nil { say(nil, category: .Units, icons: [hit.name], actions: [.unit(hit.coord, hit.id)]) }
            case "[] gains [] XP":   // Unciv OneTimeUnitGainXP
                guard let uid = unitId, let ui = unitIndex(uid) else { ok = false; break }
                units[ui].xp += u.int(1)
                if notification != nil { say(nil, category: .Units, icons: [units[ui].name, "UnitActionIcons/Promote"], actions: [.unit(units[ui].coord, units[ui].id)]) }   // MapUnitAction(unit)
            case "[] gains [] movement", "[] loses [] movement":   // Unciv OneTimeUnitGainMovement / LoseMovement: useMovementPoints, capped at the maximum
                guard let uid = unitId, unit(uid) != nil else { ok = false; break }
                let amount = Double(Float(u.param(1)) ?? 0)
                useMovementPoints(uid, u.pattern == "[] loses [] movement" ? amount : -amount)
                if notification != nil, let mu = unit(uid) { say(nil, category: .Units, icons: [mu.name], actions: [.unit(mu.coord, mu.id)]) }
            case "[] gains the [] status for [] turn(s)":   // Unciv OneTimeUnitGainStatus
                guard let uid = unitId, unit(uid) != nil, rs.promotions[u.param(1)] != nil else { ok = false; break }
                setStatus(unitId: uid, u.param(1), turns: u.int(2))
                if notification != nil, let su = unit(uid) { say(nil, category: .Units, icons: [su.name, u.param(1)], actions: [.unit(su.coord, su.id)]) }
            case "[] loses the [] status":   // Unciv OneTimeUnitLoseStatus
                guard let uid = unitId, let su = unit(uid), su.hasStatus(u.param(1)) else { ok = false; break }
                removeStatus(unitId: uid, u.param(1))
                if notification != nil { say(nil, category: .Units, icons: [su.name, u.param(1)], actions: [.unit(su.coord, su.id)]) }
            case "[] is destroyed":   // Unciv OneTimeUnitDestroyed: MapUnit.destroy
                guard let uid = unitId, let dead = unit(uid) else { ok = false; break }
                if notification != nil { say(nil, category: .Units, icons: [dead.name, "OtherIcons/DisbandUnit"], coord: dead.coord) }   // LocationAction
                destroyUnit(uid)
            case "[] upgrades for free", "[] upgrades for free including special upgrades":   // Unciv OneTimeUnitUpgrade / OneTimeUnitSpecialUpgrade
                guard let uid = unitId, let uu = unit(uid) else { ok = false; break }
                // UnitActionsUpgrade.getUpgradeActions(isFree = true, isAnywhere = true): the ruins-like target alone when
                // special and the unit has one, else its "Can upgrade to" targets and then upgradesTo - each the civ's
                // own version, valid ignoring requirements and resources; the cheapest wins (minBy: the first of equals).
                let state = UniqueContext(civId: uu.civId, unit: uu, tile: map[uu.coord])
                let special = u.pattern == "[] upgrades for free including special upgrades"
                    ? uu.def.uniqueObjects.first(where: { $0.pattern == "May upgrade to [] through ruins-like effects" && conditionalsHold($0, state) }).flatMap { rs.units[$0.param(0)] }
                    : nil
                let candidates = (special.map { [equivalentUnit(uu.civId, $0)] } ?? upgradeOptions(uu))
                    .filter { unitCanUpgrade(uu, to: $0, ignoreRequirements: true, ignoreResources: true) }
                guard let target = candidates.min(by: { $0.cost < $1.cost }) else { ok = false; break }
                let before = uu   // Unciv's `unit` is the MapUnit the upgrade replaced: its name, MapUnitAction(unit) on its tile
                upgradeUnit(uid, free: true, to: target)
                if notification != nil { say(nil, category: .Units, icons: [before.name, "UnitActionIcons/Upgrade"], actions: [.unit(before.coord, before.id)]) }
            case "[] gains the [] promotion":   // Unciv OneTimeUnitGainPromotion: UnitPromotions.addPromotion(isFree = true)
                let promo = u.param(1)
                guard let uid = unitId, unit(uid) != nil, rs.promotions[promo] != nil else { ok = false; break }
                addPromotion(unitId: uid, promo, isFree: true)
                if notification != nil, let pu = unit(uid) { say(nil, category: .Units, icons: [pu.name, promo], coord: pu.coord) }
            case "[] loses the [] promotion":   // Unciv OneTimeUnitRemovePromotion: UnitPromotions.removePromotion
                let promo = u.param(1)
                guard let uid = unitId, unit(uid) != nil, rs.promotions[promo] != nil else { ok = false; break }
                removePromotion(unitId: uid, promo)   // removal, updateUniques + updateVisibleTiles, then TriggerUponPromotionLoss
                if notification != nil, let pu = unit(uid) { say(nil, category: .Units, icons: [pu.name, promo], coord: pu.coord) }

            case "Turn this tile into a [] tile":
                guard let c = triggerTile, let t = map[c], let terrain = rs.terrains[u.param(0)] else { ok = false; break }
                switch terrain.type {
                case .land, .water:
                    guard t.baseTerrain != terrain.name, !(t.isCityCenter && terrain.type != .land) else { ok = false; break }
                    map[c]?.baseTerrain = terrain.name
                case .terrainFeature:
                    guard !t.features.contains(terrain.name), !t.isCityCenter else { ok = false; break }
                    map[c]?.features.append(terrain.name)
                default: ok = false
                }
            case "Add [] to this tile":   // Unciv OneTimeAddResource
                guard let c = triggerTile, let t = map[c], let r = rs.resources[u.param(0)], r.terrainsCanBeFoundOn.contains(where: { $0 == t.baseTerrain || t.features.contains($0) }) else { ok = false; break }
                map[c]?.resource = r.name
                map[c]?.resourceAmount = Tile.depositAmount(r, on: t, major: false, setting: settings.resourceSetting)
                if let owner = map[c]?.ownerCivId { updateCivResources(owner) }   // tile.getOwner()?.cache?.updateCivResources()
            case "Remove [] resources from this tile":   // Unciv OneTimeRemoveResourcesFromTile
                guard let c = triggerTile, let res = map[c]?.resource, let r = rs.resources[res] else { ok = false; break }
                let f = u.param(0)
                guard f == "All" || f == "all" || f == res || f == r.resourceType else { ok = false; break }
                map[c]?.resource = nil; map[c]?.resourceAmount = 0
            case "Remove [] improvements from this tile":   // Unciv OneTimeRemoveImprovementsFromTile
                guard let c = triggerTile, let t = map[c], let imp = t.improvement, improvementMatches(imp, u.param(0)) else { ok = false; break }
                let f = u.param(0)
                if f != "All Road" { map[c]?.improvement = nil }
                if f == "All" || f == "All Road" { removeRoad(at: c) }   // Unciv tile.removeRoad(): setRoadStatus(None) also lets a neutral road's owner stop paying
            default: ok = false
            }
            fired = fired || ok
        }
        return fired
    }
}
