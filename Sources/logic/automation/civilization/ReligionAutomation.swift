// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv `ReligionAutomation.rateBelief` icindeki UC `stateBasedRandom` cagrisinin ortak
/// `caller` dizesi (`ReligionAutomation.kt:215`, `:225`, `:229` -- ucunde de ayni dize).
/// Java `String.hashCode()` degeri gercek JVM'de olculdu: 869106439.
private let rateBeliefCaller = "ReligionAutomation.rateBelief"

/// Unciv Stats.sum(): `production + food + gold + science + culture + happiness + faith`, in Float, in that order.
private func uncivStatsSum(_ s: Stats?) -> Float {
    guard let s else { return 0 }
    var r = Float(s.production)
    r += Float(s.food); r += Float(s.gold); r += Float(s.science); r += Float(s.culture); r += Float(s.happiness); r += Float(s.faith)
    return r
}

/// Unciv `String.toFloat()` of a unique parameter ("+15" parses as 15).
private func pf(_ u: Unique, _ i: Int) -> Float { Float(u.param(i).replacingOccurrences(of: "+", with: "")) ?? 0 }

// Port of Unciv's civilization/ReligionAutomation.kt.
extension GameState {
    /// Unciv Constants.aiPreferInquisitorOverMissionaryPressureDifference
    private var aiPreferInquisitorOverMissionaryPressureDifference: Double { 3000 }

    /// Unciv ReligionManager.getGreatProphetEquivalent: the FIRST unit of the ruleset (Units.json order) that
    /// "May found a religion", as this civ's own version of it.
    func greatProphetEquivalent(_ civId: Int) -> UnitDef? {
        guard let base = rs.unitOrder.lazy.compactMap({ self.rs.units[$0] }).first(where: { $0.canFoundReligion }) else { return nil }
        return equivalentUnit(civId, base)
    }

    /// Unciv ReligionManager.religionState > Pantheon: a religion founded, being founded or enhanced.
    private func religionStateAbovePantheon(_ civ: Civilization) -> Bool { civ.religionName != nil || civ.pendingReligion != nil }

    /// Unciv `civInfo.stats.statsForNextTurn[stat]`: the stored field, as it was last updated.
    private func storedStatForNextTurn(_ civId: Int, _ stat: String) -> Float {
        let s = civ(civId)?.statsForNextTurn ?? statMapForNextTurn(civId).reduce(Stats()) { $0 + $1.1 }
        switch stat {
        case "Production": return Float(s.production)
        case "Food": return Float(s.food)
        case "Gold": return Float(s.gold)
        case "Science": return Float(s.science)
        case "Culture": return Float(s.culture)
        case "Happiness": return Float(s.happiness)
        case "Faith": return Float(s.faith)
        default: return 0
        }
    }

    // MARK: - faith spending

    /// Unciv ReligionAutomation.spendFaithOnReligion
    func spendFaithOnReligion(_ civId: Int) {
        guard let civ = civ(civId), !cities(of: civId).isEmpty else { return }
        // Save for great prophet: religionState != EnhancedReligion && (remaining != 0 || religionState > Pantheon)
        if !civ.religionEnhanced && (remainingFoundableReligions() != 0 || religionStateAbovePantheon(civ)) {
            buyGreatProphetInAnyCity(civId); return
        }
        if remainingFoundableReligions() == 0 {
            buyGreatPersonWithFaith(civId); tryBuyAnyReligiousBuilding(civId); return
        }
        // Unciv `civInfo.religionManager.religion!!`: here the state is above Pantheon, so it is set
        guard let religion = civ.religionName else { return }
        let citiesWithoutOurReligion = cities(of: civId).filter { majorityReligion(of: $0) != religion }
        // Unciv `it.hasUnique(CanSpreadReligion) || it.hasUnique(CanRemoveHeresy)`: MapUnit.hasUnique over the unit's
        // own uniques with conditionals in cache.state - the G&K Inquisitor's "<in [Friendly] tiles> <once> <after
        // which this unit is consumed>" counts it while it stands in friendly land; a raw string match never did.
        let spreaders = units(of: civId).filter { unitHasUnique($0, "Can Spread Religion") || unitHasUnique($0, "Can remove other religions from cities") }.count
        if citiesWithoutOurReligion.count > 4 * spreaders {
            // maxByOrNull: the first city with the largest deficit
            if let (city, deficit) = citiesWithoutOurReligion.map({ ($0, pressureDeficit(of: $0, religion: religion)) }).max(by: { $0.1 < $1.1 }) {
                if deficit >= aiPreferInquisitorOverMissionaryPressureDifference { buyInquisitorNear(civId, city) }
            }
            buyMissionaryInAnyCity(civId); return
        }
        if let hid = civ.holyCityId, let holy = city(hid), holy.civId == civId,
           !units(of: civId).contains(where: { unitHasUnique($0, "Prevents spreading of religion to the city it is next to") }), !isProtectedByInquisitor(holy) {
            buyInquisitorNear(civId, holy); return
        }
        if units(of: civId).filter({ unitHasUnique($0, "Can Spread Religion") }).count < 4 { buyMissionaryInAnyCity(civId); return }
    }
    /// Unciv tryBuyAnyReligiousBuilding: the first city (in city order) with a purchasable belief building it can
    /// afford buys the cheapest one - and the walk stops there whatever the purchase answered.
    private func tryBuyAnyReligiousBuilding(_ civId: Int) {
        guard let civ = civ(civId) else { return }
        for city in cities(of: civId) where majorityReligion(of: city) != nil {
            let options = faithPurchasableBuildings(for: city, lazyReligionList: true).filter { Double($0.1) <= civ.faithStored }
            guard let best = options.min(by: { $0.1 < $1.1 }) else { continue }
            buyWithFaith(cityId: city.id, building: best.0.name, automated: true)
            return
        }
    }
    /// Unciv's shared "cheapest construction" step of buyMissionary / buyInquisitor / buyGreatPerson: the
    /// candidate units in ruleset order, each with the cities that may buy it with faith; of those with any
    /// city, the first whose cheapest price there is lowest (minByOrNull keeps the first).
    private func cheapestFaithUnit(_ civId: Int, _ candidates: [UnitDef]) -> UnitDef? {
        var best: (UnitDef, Int)? = nil
        var seen: Set<String> = []
        for unit in candidates where seen.insert(unit.name).inserted {   // associateBy: one entry per unit
            let buyable = cities(of: civId).filter { c in faithPurchasableUnits(for: c).contains { $0.name == unit.name } }
            guard let cost = buyable.map({ faithCost(unit, for: civId, in: $0) }).min() else { continue }
            if best == nil || cost < best!.1 { best = (unit, cost) }
        }
        return best?.0
    }
    private func buyMissionaryInAnyCity(_ civId: Int) {
        guard let civ = civ(civId), let religion = civ.religionName else { return }   // religionState < Religion
        let missionaries = rs.unitOrder.compactMap { rs.units[$0] }.filter { $0.canSpreadReligion }.map { equivalentUnit(civId, $0) }
        guard let missionary = cheapestFaithUnit(civId, missionaries) else { return }
        let takesCivReligion = missionary.uniques.contains("Takes your religion over the one in their birth city")
        let valid = cities(of: civId).filter { city in
            !units(at: city.coord).contains { $0.isCivilian } && (takesCivReligion || majorityReligion(of: city) == religion)
                && Double(faithCost(missionary, for: civId, in: city)) <= civ.faithStored && faithPurchasableUnits(for: city).contains { $0.name == missionary.name }
        }
        guard !valid.isEmpty else { return }
        let withBonus = valid.filter { city in cityUniques(city).contains { u in (u.pattern == "[] units built [] start with [] promotion" || u.pattern == "All newly-trained [] units [] receive the [] promotion") && (rs.promotions[u.param(2)]?.uniqueObjects.contains { $0.pattern == "Can Spread Religion" } ?? false) } }
        let holy = valid.first { $0.isHolyCity && $0.holyCityOf == religion }
        let target = withBonus.first ?? holy ?? valid[0]
        buyWithFaith(cityId: target.id, unit: missionary.name, automated: true)
    }
    private func buyGreatProphetInAnyCity(_ civId: Int) {
        guard let civ = civ(civId), civ.religionName != nil else { return }   // religionState < Religion
        guard let prophet = greatProphetEquivalent(civId) else { return }
        let cities = cities(of: civId).filter { faithPurchasableUnits(for: $0).contains { $0.name == prophet.name } && Double(faithCost(prophet, for: civId, in: $0)) <= civ.faithStored }
        guard let city = cities.min(by: { faithCost(prophet, for: civId, in: $0) < faithCost(prophet, for: civId, in: $1) }) else { return }
        buyWithFaith(cityId: city.id, unit: prophet.name, automated: true)
    }
    private func buyInquisitorNear(_ civId: Int, _ near: City) {
        guard let civ = civ(civId), let religion = civ.religionName else { return }   // religionState < Religion
        let inquisitors = rs.unitOrder.compactMap { rs.units[$0] }.filter { $0.uniques.contains("Can remove other religions from cities") || $0.preventsSpreadingReligion }.map { equivalentUnit(civId, $0) }
        guard let inquisitor = cheapestFaithUnit(civId, inquisitors) else { return }
        let takesCivReligion = inquisitor.uniques.contains("Takes your religion over the one in their birth city")
        let valid = cities(of: civId).filter { city in
            (takesCivReligion || majorityReligion(of: city) == religion) && Double(faithCost(inquisitor, for: civId, in: city)) <= civ.faithStored && faithPurchasableUnits(for: city).contains { $0.name == inquisitor.name }
        }
        guard let city = valid.min(by: { $0.coord.distance(to: near.coord) < $1.coord.distance(to: near.coord) }) else { return }
        buyWithFaith(cityId: city.id, unit: inquisitor.name, automated: true)
    }
    /// Unciv buyGreatPerson: the ruleset's great people (not the civ's equivalents), prophets left out; bought
    /// in the first city whose price for it fits the stored faith. A city without a faith price for it
    /// (`getStatBuyCost(it, Faith) ?: return@filter false`, e.g. no majority religion there) is skipped - it is
    /// not a 0 price (faithCost's fallback), which made the capital "first" and the purchase then fail there.
    private func buyGreatPersonWithFaith(_ civId: Int) {
        guard let civ = civ(civId) else { return }
        let greatPeople = rs.unitOrder.compactMap { rs.units[$0] }.filter { $0.greatPersonType != nil && !$0.canFoundReligion }
        guard let person = cheapestFaithUnit(civId, greatPeople) else { return }
        guard let city = cities(of: civId).first(where: { c in
            guard let cost = getStatBuyCost(.unit(person.name), city: c, stat: "Faith") else { return false }
            return Double(cost) <= civ.faithStored
        }) else { return }
        buyWithFaith(cityId: city.id, unit: person.name, automated: true)
    }

    // MARK: - belief rating

    /// Unciv ReligionAutomation.rateBelief, in Float as there.
    func rateBelief(_ civId: Int, _ belief: BeliefDef, state: String = "") -> Float {
        var score: Float = 0
        for city in cities(of: civId) {
            // Unciv: city.getCenterTile().forEachTileInDistance(city.getWorkRange())
            for c in map.tilesWithin(city.coord, radius: rs.constants.cityWorkRange) {
                guard let tile = map[c] else { continue }
                // Unciv: tile.stateThisTile.stateBasedRandom("ReligionAutomation.rateBelief")
                var tileRng = stateBasedRandom(rateBeliefCaller, tile: tile)
                let tileScore = beliefBonusForTile(belief, tile, city, civId: civId)
                // worked / workable (tile.getCity() == city) / unavailable
                let mult: Float = city.workedTiles.contains(c) ? 1 : city.tiles.contains(c) ? 0.7 : 0.5
                score += tileScore * mult * (tileRng.nextFloat() * 0.05 + 0.975)
            }
            // Unciv: city.state.stateBasedRandom("ReligionAutomation.rateBelief")
            var cityRng = stateBasedRandom(rateBeliefCaller, city: city)
            score += beliefBonusForCity(civId, belief, city) * (cityRng.nextFloat() * 0.1 + 0.95)
        }
        // Unciv: civInfo.state.stateBasedRandom("ReligionAutomation.rateBelief")
        var civRng = stateBasedRandom(rateBeliefCaller, civId: civId)
        score += beliefBonusForPlayer(civId, belief, state: state) * (civRng.nextFloat() * 0.3 + 0.85)
        if belief.type == "Pantheon" { score *= 0.9 }
        // Unciv IHasUniques.getWeightForAiDecision: the product of the matching weights, then one multiplication
        var weight: Float = 1
        for u in belief.uniqueObjects where u.pattern == "[]% weight to this choice for AI decisions" && conditionalsHold(u, UniqueContext(civId: civId)) { weight *= 1 + pf(u, 0) / 100 }
        score *= weight
        return score
    }
    /// Unciv TileResource.matchesFilter (name, any/all, type, improvement stat) or isImprovedBy (getImprovements).
    private func resourceMatchesOrImprovedBy(_ resource: ResourceDef?, _ f: String) -> Bool {
        guard let r = resource else { return false }
        if r.name == f || f == "any" || f == "all" || r.resourceType == f { return true }
        return rs.resourceImprovements[r.name]?.contains(f) ?? false
    }
    private func beliefBonusForTile(_ belief: BeliefDef, _ tile: Tile, _ city: City, civId: Int) -> Float {
        var bonus: Float = 0
        let resource = tile.resource.flatMap { rs.resources[$0] }
        for u in belief.uniqueObjects {
            switch u.pattern {
            case "[] from every []":
                let f = u.param(1)
                if tileMatches(tile, f, civId: civId) {
                    // Unciv tile.lastTerrain: the last feature, else the base terrain
                    let last = (tile.features.last ?? Optional(tile.baseTerrain)).flatMap { rs.terrains[$0] }
                    let removable = last?.uniqueObjects.contains { $0.pattern == "Provides a one-time bonus of [] [] to the closest city when cut down" } ?? false
                    if !removable || !(last.map { $0.name == f } ?? false) { bonus += uncivStatsSum(u.stats) }   // forest pantheons are bad
                    else if resourceMatchesOrImprovedBy(resource, f) { bonus += uncivStatsSum(u.stats) }
                } else if resourceMatchesOrImprovedBy(resource, f) { bonus += uncivStatsSum(u.stats) }
            case "[] from [] tiles without [] []":
                if cityMatchesFilter(u.param(3), city: city, viewer: city.civId) && tileMatches(tile, u.param(1), civId: civId) && !tileMatches(tile, u.param(2), civId: civId) { bonus += uncivStatsSum(u.stats) }
            default: break
            }
        }
        return bonus
    }
    private func beliefBonusForCity(_ civId: Int, _ belief: BeliefDef, _ city: City) -> Float {
        var score: Float = 0
        for u in belief.uniqueObjects {
            let modifier = Float(pow(0.5, Double(u.conditionals.count)))   // 0.5f.pow(unique.modifiers.size): exact powers of two
            var v: Float = 0
            switch u.pattern {
            case "[]% growth []": v = pf(u, 0) / 3
            case "[]% Culture cost of natural border growth []": v = -pf(u, 0) / 10
            case "[]% Strength for cities": v = pf(u, 0) / 10   // the conditional is not part of the pattern: "[+30]% Strength for cities <when attacking>"
            case "[] Units adjacent to this city heal [] HP per turn when healing": v = pf(u, 1) / 10
            case "[]% Production when constructing [] buildings []", "[]% Production when constructing [] wonders []", "[]% Production when constructing [] units []": v = pf(u, 0) / 3
            case "[] in cities on [] tiles": v = map[city.coord].map { tileMatches($0, u.param(1), civId: civId) } == true ? uncivStatsSum(u.stats) : 0
            case "[] from every []":
                let name = u.param(1)
                if let b = rs.buildings[name] { v = uncivStatsSum(u.stats) * (b.isNationalWonder ? 0.25 : 1) }
                else if rs.specialists[name] != nil { v = uncivStatsSum(u.stats) * (Float(city.population) > 8 ? 2 : 1) }
                else { v = uncivStatsSum(u.stats) * 0 }
            // Unciv city.isConnectedToCapital(): the city's own civ's stored connection map, which holds the capital
            case "[] from each Trade Route": v = uncivStatsSum(u.stats) * (isCapitalConnected(to: city, civId: city.civId) ? 1 : 0)
            case "[]% [] from every follower, up to []%": v = min(pf(u, 0) * Float(city.population), pf(u, 2))
            case "[] []": v = cityMatchesFilter(u.param(1), city: city, viewer: city.civId) ? uncivStatsSum(u.stats) * 1 : 0
            default: v = 0
            }
            score += modifier * v
        }
        return score
    }
    private func beliefBonusForPlayer(_ civId: Int, _ belief: BeliefDef, state: String) -> Float {
        guard let civ = civ(civId) else { return 0 }
        var score: Float = 0
        // Unciv: religion != null && religionState >= Religion - the civ founding right now is not counted yet
        let founded = foundedReligionsCount
        let maxNumberOfReligions = founded + remainingFoundableReligions()
        var gameTimeScalingPercent = 100
        // Unciv: scaled only in the FoundingReligion / EnhancingReligion states
        if state == "founding" { gameTimeScalingPercent = 100 - (founded * 100) / max(1, maxNumberOfReligions) }
        else if state == "enhancing" {
            let enhanced = civs.filter { $0.religionName != nil && $0.religionEnhanced }.count
            gameTimeScalingPercent = 100 - (enhanced * 100) / max(1, maxNumberOfReligions)
        }
        let goodEarly: Float = gameTimeScalingPercent < 33 ? 1 : gameTimeScalingPercent < 66 ? 2 : 4
        let goodLate: Float = gameTimeScalingPercent < 33 ? 2 : gameTimeScalingPercent < 66 ? 1 : 1 / 2
        let prophet = greatProphetEquivalent(civId)?.name
        // Unciv Religion.followerBeliefUniqueMap: the religion's (or pantheon's) pantheon and follower beliefs
        let hasReligion = civ.religionName != nil || civ.pantheonBelief != nil
        let followerUniques = Set(((civ.religionBeliefs + (civ.pantheonBelief.map { [$0] } ?? [])).compactMap { rs.beliefs[$0] }.filter { $0.type == "Follower" || $0.type == "Pantheon" }).flatMap { $0.uniqueObjects.map { $0.pattern } })
        let era = rs.era(named: civ.eraName)
        for u in belief.uniqueObjects {
            let modifier: Float = u.conditionals.contains { $0.pattern == "for [] units" && $0.param(0) == prophet } ? 1 / 2 : 1
            var v: Float = 0
            switch u.pattern {
            case "Earn []% of killed [] unit's [] as []": v = 0
            case "May buy [] units for [] [] []", "May buy [] buildings for [] [] []":
                v = hasReligion && followerUniques.contains(u.pattern) ? 0 : storedStatForNextTurn(civId, u.param(2)) * 300 / pf(u, 1)
            case "May buy [] units with [] []", "May buy [] buildings with [] []":
                v = hasReligion && followerUniques.contains(u.pattern) ? 0 : storedStatForNextTurn(civId, u.param(1)) * 300 / Float(era?.baseUnitBuyCost ?? 200)
            case "May buy [] units with [] for [] times their normal Production cost": v = 0
            case "When spreading religion to a city, gain [] times the amount of followers of other religions as []": v = pf(u, 0) / 15
            case "[] when a city adopts this religion for the first time", "[] when a city adopts this religion for the first time (modified by game speed)": v = uncivStatsSum(u.stats) / 50
            case "Resting point for Influence with City-States following this religion []": v = pf(u, 0) / 8
            case "[] for each global city following this religion": v = uncivStatsSum(u.stats) * 2
            case "[] from every [] global followers []": v = 10 * (uncivStatsSum(u.stats) / pf(u, 1))
            case "[]% Strength": v = pf(u, 0) * 3
            case "Religion naturally spreads to cities [] tiles away": v = (10 + pf(u, 0)) * goodEarly
            case "[]% Natural religion spread []": v = pf(u, 0) * goodEarly / 10
            case "[]% Spread Religion Strength": v = pf(u, 0) * goodLate / 10
            case "[]% Faith cost of generating Great Prophet equivalents": v = -pf(u, 0) * goodLate / 10
            case "[] cost of purchasing [] buildings []%", "[] cost of purchasing [] units []%": v = -pf(u, 2) * goodLate / 5
            case "[] cost of purchasing items in cities []%": v = -pf(u, 1) * goodLate / 5
            default: v = 0
            }
            score += modifier * v
        }
        return score
    }

    // MARK: - choosing beliefs

    /// Unciv ReligionAutomation.chooseReligiousBeliefs (founding / enhancing happen through the prophet's actions)
    func chooseReligiousBeliefs(_ civId: Int) {
        guard religionEnabled, let civ = civ(civId), civ.isMajor else { return }
        // choosePantheon: canFoundOrExpandPantheon → pickBeliefOfType(Pantheon) → chooseBeliefs(useFreeBeliefs = usingFreeBeliefs())
        if canFoundOrExpandPantheon(civ), let b = pickBeliefOfType(civId, "Pantheon") { _ = foundPantheon(civId: civId, belief: b.name) }
        // foundReligion: only in the FoundingReligion state the prophet left behind
        if let c = self.civ(civId), c.pendingReligion == "founding" {
            let used = Set(civs.compactMap { $0.religionName })
            let available = rs.religionNames.filter { !used.contains($0) }
            let favored = c.nationDef?.favoredReligion.flatMap { available.contains($0) ? $0 : nil }
            let allFavored = Set(civs.compactMap { $0.nationDef?.favoredReligion })
            // Unciv ReligionAutomation.kt:441: `civInfo.state.stateBasedRandom("ReligionAutomation.foundReligion")` — iki eleme de AYNI uretecten (:444-445).
            var g = stateBasedRandom("ReligionAutomation.foundReligion", civId: civId)
            if let name = favored ?? g.pick(available.filter { !allFavored.contains($0) }) ?? g.pick(available) {
                // Unciv: religionManager.foundReligion(name, name) FIRST - the holy city's pressure, adoption, resources
                // and stats, and shouldChoosePantheonBelief = false - and only then the beliefs are rated
                // (chooseBeliefs over getBeliefsToChooseAtFounding) and chosen. Ours rated them before founding.
                if foundReligionNamed(civId: civId, name: name) {
                    let chosen = chooseBeliefsAI(civId, beliefsToChoose(civId: civId, enhancing: false, shouldChoosePantheon: false), state: "founding")
                    chooseFoundingBeliefs(civId: civId, beliefs: chosen)
                }
            }
        }
        // enhanceReligion: only in the EnhancingReligion state
        if let c = self.civ(civId), c.pendingReligion == "enhancing" {
            _ = completeEnhancingReligion(civId: civId, beliefs: chooseBeliefsAI(civId, beliefsToChoose(civId: civId, enhancing: true), state: "enhancing"), strict: false)
        }
        // chooseFreeBeliefs: chooseBeliefs(freeBeliefsAsEnums(), useFreeBeliefs = true)
        if let c = self.civ(civId), c.freeBeliefsByType.values.reduce(0, +) > 0 {
            _ = applyFreeBeliefs(civId: civId, beliefs: chooseBeliefsAI(civId, c.freeBeliefsByType), requireAll: false)
        }
    }
    /// Unciv ReligionAutomation.chooseBeliefs: for each BeliefType in order, pick the best-rated belief per slot
    func chooseBeliefsAI(_ civId: Int, _ beliefsToChoose: [String: Int], state: String = "") -> [String] {
        var chosen: [String] = []
        for t in beliefTypeOrder {
            for _ in 0..<max(0, beliefsToChoose[t] ?? 0) { if let b = pickBeliefOfType(civId, t, excluding: Set(chosen), state: state) { chosen.append(b.name) } }
        }
        return chosen
    }
    /// Unciv ReligionAutomation.pickBeliefOfType: `ruleset.beliefs.values` (Beliefs.json order) filtered, then
    /// `maxByOrNull { rateBelief }` - the first of the equally rated wins.
    func pickBeliefOfType(_ civId: Int, _ type: String, excluding: Set<String> = [], state: String = "") -> BeliefDef? {
        let ctx = UniqueContext(civId: civId)
        let options = rs.beliefList.filter { b in
            (b.type == type || type == "Any") && !excluding.contains(b.name)
                && !civs.contains { $0.pantheonBelief == b.name || $0.religionBeliefs.contains(b.name) }   // getReligionWithBelief
                && !b.uniqueObjects.contains { u in u.pattern == "Only available" && !conditionalsHold(u, ctx) }
                && !b.uniqueObjects.contains { u in u.pattern == "Unavailable" && conditionalsHold(u, ctx) }
        }
        var best: (belief: BeliefDef, rating: Float)? = nil
        for b in options {
            let r = rateBelief(civId, b, state: state)
            if best == nil || best!.rating < r { best = (b, r) }
        }
        return best?.belief
    }

    // MARK: AI helpers

    /// Unciv'de bu iki yardimcinin karsiligi yoktur: `choosePantheon` (`ReligionAutomation.kt:414`)
    /// ve butun inanc secimleri (`:489`) tek bir `pickBeliefOfType` uzerinden gider, o da
    /// `maxByOrNull { rateBelief(civInfo, it) }` kullanir -- puan oge basina BIR KEZ hesaplanip
    /// saklanir, karsilastirma saftir. Ikisi de `pickBeliefOfType`'a devrediyor.
    func bestPantheon(for civId: Int) -> BeliefDef? { pickBeliefOfType(civId, "Pantheon") }

    func bestBelief(ofType t: String, for civId: Int) -> BeliefDef? { pickBeliefOfType(civId, t) }
}
