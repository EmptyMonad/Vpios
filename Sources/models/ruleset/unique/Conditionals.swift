// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `models/ruleset/unique/Conditionals.kt` (and `Unique.conditionalsApply`): whether a unique applies right now.
extension GameState {
    /// Unciv GameContext.relevantTile: `attackedTile ?: tile ?: relevantUnit's tile ?: city centre`.
    func relevantTile(_ ctx: UniqueContext) -> Tile? {
        ctx.attackedTile ?? ctx.tile ?? ctx.unit.flatMap { map[$0.coord] } ?? ctx.city.flatMap { map[$0.coord] }
    }

    /// The modifiers Unciv answers `true` unconditionally (`conditional.isOtherModifierType`: UniqueTarget
    /// UnitActionModifier and MetaModifier). Unciv's TriggerCondition / UnitTriggerCondition modifiers ("upon ...")
    /// are Other modifiers too; all but "upon expending" are deliberately left out here - see `conditionalHolds`.
    static let otherModifierPatterns: Set<String> = [
        "for every []", "for every [] []", "for every adjacent []", "(modified by game progress up to []%)",
        "by consuming this unit", "(modified by game speed)", "upon expending a [] unit", "Suppress warning []",
        "hidden from users", "for [] movement", "[] times", "[] additional time(s)", "after which this unit is consumed",
        "Civilopedia link []", "for all movement", "requires [] movement", "costs [] stats", "costs [] []",
        "removing the [] promotion/status", "once", "with [] priority", "for [] turns",
    ]

    /// Unciv Unique.conditionalsApply.
    func conditionalsHold(_ u: Unique, _ ctx: UniqueContext) -> Bool {
        // Unciv: "Always allow Timed conditional uniques. They are managed elsewhere" - a unique carrying
        // `<for [n] turns>` passes whatever its other conditionals say; they are judged on the stored copy.
        if u.conditionals.contains(where: { $0.pattern == "for [] turns" }) { return true }
        for c in u.conditionals where !conditionalHolds(c, ctx, unique: u) { return false }
        return true
    }

    /// Unciv GameContext.getResourceAmount: the relevant city's available amount, else the civ's.
    func contextResourceAmount(_ name: String, _ ctx: UniqueContext) -> Int {
        if let city = relevantCity(ctx) { return availableResourceAmount(city, name) }
        guard civ(ctx.civId) != nil else { return 0 }
        return resourceCounts(ctx.civId)[name] ?? 0
    }

    /// Unciv City.getStatReserve / Civilization.getStatReserve.
    func statReserve(_ stat: String, city: City?, civId: Int) -> Int {
        if let city {
            if stat == "Production" { return city.currentProduction == nil ? 0 : Int(city.productionStored) }   // workDone of the current construction
            if stat == "Food" { return Int(city.foodStored) }
        }
        guard let civ = civ(civId) else { return 0 }
        switch stat {
        case "Culture": return Int(civ.cultureStored)
        case "Science": return scienceReserve(civ)
        case "Gold": return Int(civ.gold)
        case "Faith": return Int(civ.faithStored)
        case "Happiness": return happiness(of: civId)   // Unciv stats.happiness: the cached field
        default: return 0
        }
    }

    /// Unciv GameContext.getStatAmount: the relevant city's reserve, else the civ's for the civ-wide stats.
    func contextStatAmount(_ stat: String, _ ctx: UniqueContext) -> Int {
        if let city = relevantCity(ctx) { return statReserve(stat, city: city, civId: city.civId) }
        guard civ(ctx.civId) != nil, ["Gold", "Science", "Culture", "Faith", "Happiness"].contains(stat) else { return 0 }
        return statReserve(stat, city: nil, civId: ctx.civId)
    }


    /// Unciv Conditionals.checkResourceOrStatAmount: a resource (by ruleset name) first, then a stat reserve.
    /// The current amount is an Int, the limits Floats, scaled by the game speed when the unique asks for it.
    private func checkResourceOrStatAmount(_ name: String, _ lower: Double, _ upper: Double, byGameSpeed: Bool, _ ctx: UniqueContext,
                                           _ compare: (Int, Double, Double) -> Bool) -> Bool {
        if rs.resources[name] != nil {
            let m = byGameSpeed ? Double(Float(speed.modifier)) : 1
            return compare(contextResourceAmount(name, ctx), lower * m, upper * m)
        }
        guard GameState.statNames.contains(name) else { return false }
        let m = byGameSpeed ? Double(Float(statCostModifier(name))) : 1
        return compare(contextStatAmount(name, ctx), lower * m, upper * m)
    }

    /// Unciv Civilization.isAtWar: at war with anyone in its diplomacy map who is not defeated. Barbarians are never
    /// in a diplomacy map.
    private func civIsAtWar(_ civ: Civilization) -> Bool {
        civ.atWarWith.contains { id in self.civ(id).map { !$0.isBarbarian && !isDefeated($0) } ?? false }
    }

    /// Unciv ICombatant.matchesFilter for `theirCombatant`: a unit answers with its own filter, a city with
    /// "City", "all" or the city filter (which falls back to its civ's).
    private func theirCombatantMatches(_ filter: String, _ ctx: UniqueContext) -> Bool {
        if let o = ctx.opponentUnit { return unitMatches(o, filter) }
        if let c = ctx.opponentCity {
            return MultiFilter.multiFilter(filter) { f in f == "City" || f == "all" || f == "All" || self.cityMatchesSingleFilter(f, city: c, viewer: c.civId) }
        }
        guard ctx.opponentIsCity, let oc = ctx.opponentCivId.flatMap({ self.civ($0) }) else { return false }
        return filter == "City" || filter == "all" || filter == "All" || civMatches(oc, filter, viewer: oc.id)
    }

    /// Unciv Conditionals.conditionalApplies. `unique` is the unique the conditional belongs to (Unciv passes it for
    /// the game-speed flag, the first-to-research source and the chance seed).
    ///
    /// One departure: Unciv answers every TriggerCondition ("upon ...") `true` here and leaves it to each trigger
    /// caller to skip uniques that carry one (`hasTriggerConditional()`). Our trigger callers hand whole unique lists
    /// to `triggerUniques`, which judges them with `conditionalsHold`, so an "upon" modifier stays `false` and
    /// the trigger machinery strips the one it fires on before the unique gets here. No standing (non-trigger)
    /// unique in the shipped rulesets carries an "upon" modifier, so no static lookup can tell the two apart.
    func conditionalHolds(_ c: Unique, _ ctx: UniqueContext, unique: Unique? = nil) -> Bool {
        // Unciv: `if (conditional.isOtherModifierType) return true` comes before any state is read, so a meta or
        // action modifier holds even in GameContext.EmptyState, where every civ-bound conditional is false.
        if Self.otherModifierPatterns.contains(c.pattern) { return true }
        let civOrNil = civ(ctx.civId)
        let hasGame = civOrNil != nil   // Unciv checkOnGameInfo: every non-empty context carries the game
        let byGameSpeed = unique?.conditionals.contains { $0.pattern == "(modified by game speed)" } ?? false
        func onCity(_ p: (City) -> Bool) -> Bool { relevantCity(ctx).map(p) ?? false }   // Unciv checkOnCity
        func compareEra(_ name: String, _ cmp: (Int, Int) -> Bool) -> Bool {
            guard let civ = civOrNil, let target = rs.eras.firstIndex(where: { $0.name == name }) else { return false }
            return cmp(rs.eraIndex(civ.eraName), target)
        }
        switch c.pattern {
        case "with []% chance":
            // Unciv Conditionals.getStateBasedRandom: Random(hashOf(turns, unique.hashCode(), state.hashCode())).nextFloat()
            return conditionalChanceRoll(c.text, ctx, hasUnique: unique != nil) < Float(c.double(0)) / 100
        case "every [] turns": let n = c.int(0); return hasGame && n != 0 && uncivTurns % n == 0
        case "before turn number []": return hasGame && uncivTurns < c.int(0)
        case "after turn number []": return hasGame && uncivTurns >= c.int(0)
        case "if tutorials are enabled": return Tutorial.enabled                               // Unciv settings.showTutorials
        case "if tutorial [] is completed": return Tutorial.tasksDone.contains(c.param(0))    // Unciv settings.tutorialTasksCompleted

        case "for [] Civilizations": return civOrNil.map { civMatches($0, c.param(0), viewer: $0.id) } ?? false
        case "when at war": return civOrNil.map { civIsAtWar($0) } ?? false
        case "when not at war": return civOrNil.map { !civIsAtWar($0) } ?? false
        case "with []": return contextResourceAmount(c.param(0), ctx) > 0      // ConditionalWithResource
        case "without []": return contextResourceAmount(c.param(0), ctx) <= 0  // ConditionalWithoutResource

        case "when above [] []":
            guard hasGame else { return false }
            return checkResourceOrStatAmount(c.param(1), c.double(0), Double(Float.greatestFiniteMagnitude), byGameSpeed: byGameSpeed, ctx) { cur, lo, _ in Double(cur) > lo }
        case "when below [] []":
            guard hasGame else { return false }
            return checkResourceOrStatAmount(c.param(1), Double(Float.leastNonzeroMagnitude), c.double(0), byGameSpeed: byGameSpeed, ctx) { cur, _, hi in Double(cur) < hi }
        case "when between [] and [] []":
            guard hasGame else { return false }
            return checkResourceOrStatAmount(c.param(2), c.double(0), c.double(1), byGameSpeed: byGameSpeed, ctx) { cur, lo, hi in Double(cur) >= lo && Double(cur) <= hi }

        case "while the empire is happy": return civOrNil.map { _ in happiness(of: ctx.civId) >= 0 } ?? false
        case "during a Golden Age": return civOrNil?.isInGoldenAge ?? false
        case "when not in a Golden Age": return civOrNil.map { !$0.isInGoldenAge } ?? false

        case "before the []": return compareEra(c.param(0)) { $0 < $1 }
        case "starting from the []": return compareEra(c.param(0)) { $0 >= $1 }
        case "during the []": return compareEra(c.param(0)) { $0 == $1 }
        case "if starting in the []": return hasGame && (settings.startingEra.isEmpty ? (rs.eras.first?.name ?? "") : settings.startingEra) == c.param(0)
        case "on [] game speed": return hasGame && settings.speed == c.param(0)
        case "on [] difficulty": return hasGame && settings.difficulty == c.param(0)
        case "on [] difficulty or higher", "on [] difficulty or lower":
            guard hasGame, let target = rs.difficulties.firstIndex(where: { $0.name == c.param(0) }) else { return false }
            let current = rs.difficulties.firstIndex { $0.name == settings.difficulty } ?? -1
            return c.pattern == "on [] difficulty or higher" ? current >= target : current <= target
        case "when [] Victory is enabled": return hasGame && settings.victoryTypes.contains(c.param(0))
        case "when [] Victory is disabled": return hasGame && !settings.victoryTypes.contains(c.param(0))
        case "when religion is enabled": return hasGame && religionEnabled
        case "when religion is disabled": return hasGame && !religionEnabled
        case "when espionage is enabled": return hasGame && settings.espionageEnabled
        case "when espionage is disabled": return hasGame && !settings.espionageEnabled
        case "when nuclear weapons are enabled": return hasGame && settings.nuclearWeaponsEnabled
        case "when nuclear weapons are disabled": return hasGame && !settings.nuclearWeaponsEnabled
        case "after discovering []": return civOrNil.map { hasDiscovered($0, c.param(0)) } ?? false
        case "before discovering []": return civOrNil.map { !hasDiscovered($0, c.param(0)) } ?? false
        case "while researching []": return civOrNil?.currentTech.map { techMatches($0, c.param(0)) } ?? false
        case "if no Civilization has adopted []":
            guard hasGame else { return false }
            let name = c.param(0)
            return !civs.contains { $0.isMajor && $0.isAlive && ($0.policies.contains(name) || $0.religionBeliefs.contains(name) || $0.pantheonBelief == name) }
        // Unciv ConditionalAfterPolicyOrBelief / ConditionalBeforePolicyOrBelief: a policy, or a belief our religion holds.
        case "after adopting []": return civOrNil.map { hasAdopted($0, c.param(0)) } ?? false
        case "before adopting []": return civOrNil.map { !hasAdopted($0, c.param(0)) } ?? false
        // Unciv ReligionState: None < Pantheon < FoundingReligion < Religion < EnhancingReligion < EnhancedReligion
        case "before founding a Pantheon": return civOrNil.map { $0.pantheonBelief == nil && $0.religionName == nil } ?? false
        case "after founding a Pantheon": return civOrNil.map { $0.pantheonBelief != nil || $0.religionName != nil } ?? false
        case "before founding a religion": return civOrNil.map { $0.religionName == nil } ?? false
        case "after founding a religion": return civOrNil.map { $0.religionName != nil } ?? false
        case "before enhancing a religion": return civOrNil.map { civ in !civ.religionBeliefs.contains { rs.beliefs[$0]?.type == "Enhancer" } } ?? false
        case "after enhancing a religion": return civOrNil.map { civ in civ.religionBeliefs.contains { rs.beliefs[$0]?.type == "Enhancer" } } ?? false
        // Unciv ReligionManager.greatProphetsEarned: civConstructions.boughtItemsWithIncreasingPrice[getGreatProphetEquivalent()?.name ?: ""],
        // which counts generated and faith-bought prophets alike and comes with an Unciv save; no prophet unit reads key "" (0).
        // prophetsEarned stands in only for a native save from before the counter, as prophetCost does.
        case "after generating a Great Prophet":
            guard let civ = civOrNil, let prophet = greatProphetEquivalent(civ.id) else { return false }
            return (civ.boughtWithIncreasingPrice[prophet.name] ?? civ.prophetsEarned) > 0

        case "if [] is constructed": return civOrNil.map { civ in cities(of: civ.id).contains { hasBuildingOrEquivalent($0, c.param(0)) } } ?? false
        case "if [] is not constructed": return civOrNil.map { civ in !cities(of: civ.id).contains { hasBuildingOrEquivalent($0, c.param(0)) } } ?? false
        case "if [] is constructed in all [] cities":   // Unciv ConditionalBuildingBuiltAll: every city matching the filter (vacuously true)
            return civOrNil.map { civ in cities(of: civ.id).filter { cityMatchesFilter(c.param(1), city: $0, viewer: $0.civId) }.allSatisfy { hasBuildingOrEquivalent($0, c.param(0)) } } ?? false
        case "if [] is constructed in at least [] of [] cities":
            return civOrNil.map { civ in cities(of: civ.id).filter { hasBuildingOrEquivalent($0, c.param(0)) && cityMatchesFilter(c.param(2), city: $0, viewer: $0.civId) }.count >= c.int(1) } ?? false
        case "if [] is constructed by anybody": return hasGame && cities.contains { hasBuildingOrEquivalent($0, c.param(0)) }
        case "if [] is not constructed by anybody": return !(hasGame && cities.contains { hasBuildingOrEquivalent($0, c.param(0)) })

        // "Filtered via city.getMatchingUniques" - all of these ask GameContext.relevantCity
        case "in this city": return relevantCity(ctx) != nil
        case "in [] cities": return onCity { cityMatchesFilter(c.param(0), city: $0, viewer: ctx.civId) }
        case "in cities connected to the capital": return onCity { $0.isCapital || $0.connectedToCapital }
        case "in cities with a [] religion":
            return onCity { city in majorityReligion(of: city).map { r in civOrNil.map { religionMatches(r, c.param(0), viewer: $0) } ?? false } ?? false }
        case "in cities not following a [] religion":
            return onCity { city in !(majorityReligion(of: city).map { r in civOrNil.map { religionMatches(r, c.param(0), viewer: $0) } ?? false } ?? false) }
        case "in cities with a major religion":
            return onCity { city in majorityReligion(of: city).map { r in civOrNil.map { religionMatches(r, "major", viewer: $0) } ?? false } ?? false }
        case "in cities with an enhanced religion":
            return onCity { city in majorityReligion(of: city).map { r in civOrNil.map { religionMatches(r, "enhanced", viewer: $0) } ?? false } ?? false }
        case "in cities following our religion":   // ConditionalCityThisReligion
            return onCity { city in civOrNil?.religionName.map { majorityReligion(of: city) == $0 } ?? false }
        case "during We Love The King Day": return onCity { $0.isCelebrating }
        case "in cities with a []": return onCity { hasBuildingOrEquivalent($0, c.param(0)) }
        case "in cities without a []": return onCity { !hasBuildingOrEquivalent($0, c.param(0)) }
        case "in cities with at least [] []": return onCity { populationFilterAmount($0, c.param(1)) >= c.int(0) }
        case "in cities with [] []": return onCity { populationFilterAmount($0, c.param(1)) == c.int(0) }
        case "in cities with between [] and [] []":
            return onCity { let v = populationFilterAmount($0, c.param(2)); return v >= c.int(0) && v <= c.int(1) }
        case "in cities with less than [] []": return onCity { populationFilterAmount($0, c.param(1)) < c.int(0) }
        case "with a garrison":   // Unciv ConditionalWhenGarrisoned: the centre tile's military unit can garrison (military, land)
            return onCity { city in units(at: city.coord).contains { $0.isMilitary && $0.def.isLand } }

        case "vs cities": return ctx.opponentCity != nil || ctx.opponentIsCity   // theirCombatant.matchesFilter("City")
        case "vs [] units", "vs []": return theirCombatantMatches(c.param(0), ctx)   // ConditionalVsUnits, ConditionalVsCombatant
        case "for [] units", "when []":   // ConditionalOurUnit, ConditionalOurUnitOnUnit: relevantUnit
            return ctx.unit.map { unitMatches($0, c.param(0)) } ?? false
        case "for units with []":   // Unciv ConditionalUnitWithPromotion: also true for temporary statuses
            guard let u = ctx.unit else { return false }
            return u.promotions.contains(c.param(0)) || u.hasStatus(c.param(0))
        case "for units without []":
            guard let u = ctx.unit else { return false }
            return !(u.promotions.contains(c.param(0)) || u.hasStatus(c.param(0)))
        case "when attacking": return ctx.resolvedCombatAction == "Attack"
        case "when defending": return ctx.resolvedCombatAction == "Defend"
        case "when above [] HP", "when below [] HP":
            // Unciv: relevantUnit's health, or ourCombatant's (a city in a fight)
            let above = c.pattern == "when above [] HP"
            func cmp(_ h: Int) -> Bool { above ? h > c.int(0) : h < c.int(0) }
            if let u = ctx.unit, cmp(u.health) { return true }
            if ctx.isCombat, ctx.unit == nil, let city = ctx.city { return cmp(city.health) }
            if ctx.isCombat, let u = ctx.unit { return cmp(u.health) }
            return false
        case "when above [] movement": return ctx.unit.map { Float($0.movementLeft) > Float(c.int(0)) } ?? false
        case "when below [] movement": return ctx.unit.map { Float($0.movementLeft) < Float(c.int(0)) } ?? false
        case "if it hasn't used other actions yet": return ctx.unit.map { $0.abilityToTimesUsed.isEmpty } ?? true   // `state.unit == null ||`
        case "when stacked with a [] unit":
            guard let u = ctx.unit else { return false }
            return units(at: u.coord).contains { $0.id != u.id && unitMatches($0, c.param(0)) }
        case "when not stacked with a [] unit":
            guard let u = ctx.unit else { return true }
            return !units(at: u.coord).contains { $0.id != u.id && unitMatches($0, c.param(0)) }

        case "in [] tiles": return relevantTile(ctx).map { tileMatches($0, c.param(0), civId: ctx.civId) } ?? false
        case "in tiles without []":   // `relevantTile?.matchesFilter(...) == false`
            return relevantTile(ctx).map { !tileMatches($0, c.param(0), civId: ctx.civId) } ?? false
        case "in tiles adjacent to [] tiles", "in tiles not adjacent to [] tiles":
            guard let t = relevantTile(ctx) else { return false }
            let adjacent = map.neighbors(of: t.coord).contains { map[$0].map { tileMatches($0, c.param(0), civId: ctx.civId) } ?? false }
            return c.pattern == "in tiles adjacent to [] tiles" ? adjacent : !adjacent
        case "when fighting in [] tiles":   // Unciv ConditionalFightingInTiles: the attackedTile only
            return ctx.attackedTile.map { tileMatches($0, c.param(0), civId: ctx.civId) } ?? false
        case "within [] tiles of a []":   // Unciv ConditionalNearTiles: relevantTile.getTilesInDistance
            guard let t = relevantTile(ctx) else { return false }
            return map.tilesWithin(t.coord, radius: c.int(0)).contains { map[$0].map { tileMatches($0, c.param(1), civId: ctx.civId) } ?? false }

        case "when fighting units from a Civilization with more Cities than you":   // Unciv ConditionalVsLargerCiv
            let yours = civOrNil.map { cities(of: $0.id).count } ?? 1
            let theirs = ctx.theirCombatantCivId.map { cities(of: $0).count } ?? 0
            return yours < theirs
        case "on foreign continents":
            // Unciv ConditionalForeignContinent: true with no cities or no capital - the first settler qualifies.
            guard civOrNil != nil, let t = relevantTile(ctx) else { return false }
            guard let home = capital(of: ctx.civId) else { return true }
            return continentId(of: t.coord) != continentId(of: home.coord)
        case "when adjacent to a [] unit":
            // Unciv: the neighbours of state.relevantTile - attackedTile ?: tile ?: the unit's tile. In a fight that
            // is the DEFENDER's tile, for both sides (t_45 turn 114: Discipline's +15% "when adjacent to a [Melee]
            // unit" asked for a Japanese melee unit next to the Cataphract, not next to the attacking Samurai).
            guard civOrNil != nil, let u = ctx.unit, let t = relevantTile(ctx) else { return false }
            return map.neighbors(of: t.coord).contains { n in units(at: n).contains { $0.id != u.id && $0.civId == ctx.civId && unitMatches($0, c.param(0)) } }
        case "with [] to [] neighboring [] tiles":   // Unciv ConditionalNeighborTiles: relevantTile
            guard let t = relevantTile(ctx) else { return false }
            let n = map.neighbors(of: t.coord).filter { map[$0].map { tileMatches($0, c.param(2), civId: ctx.civId) } ?? false }.count
            return n >= c.int(0) && n <= c.int(1)

        // Map-generation regions: a game context has no region, so `region?.type != x` holds and the rest do not.
        case "on water maps", "in [] Regions": return false
        case "in all except [] Regions": return true

        case "if no other Civilization has researched this":   // Unciv ConditionalFirstCivToResearch
            guard hasGame, let tech = sourceName(of: unique, .tech, fallback: ctx.sourceTech) else { return false }
            return !civs.contains { $0.id != ctx.civId && $0.isMajor && $0.techs.contains(tech) }
        case "if no other Civilization has adopted this":   // Unciv ConditionalFirstCivToAdopt
            guard hasGame, let policy = sourceName(of: unique, .policy, fallback: ctx.sourcePolicy) else { return false }
            return !civs.contains { $0.id != ctx.civId && $0.isMajor && $0.policies.contains(policy) }

        case "when number of [] is equal to []", "when number of [] is different than []",
             "when number of [] is more than []", "when number of [] is less than []":
            guard let a = countable(c.param(0), ctx), let b = countable(c.param(1), ctx) else { return false }
            switch c.pattern {
            case "when number of [] is equal to []": return a == b
            case "when number of [] is different than []": return a != b
            case "when number of [] is more than []": return a > b
            default: return a < b
            }
        case "when number of [] is between [] and []":
            guard let a = countable(c.param(0), ctx), let lo = countable(c.param(1), ctx), let hi = countable(c.param(2), ctx) else { return false }
            return a >= lo && a <= hi

        case "when carried by [] units":
            // Unciv ConditionalWhenCarriedBy: a transported unit whose tile's military unit (the carrier) matches the filter.
            guard let u = ctx.unit, u.isTransported,
                  let carrier = units(at: u.coord).first(where: { $0.isMilitary && !$0.def.isAir }) else { return false }
            return carrier.id != u.id && unitMatches(carrier, c.param(0))
        case "if [] is enabled", "if [] is not enabled":
            guard hasGame else { return false }
            let enabled = (settings.mods + ["Civ V - Gods & Kings"]).contains(c.param(0))
            return c.pattern == "if [] is enabled" ? enabled : !enabled
        default: return false
        }
    }

    /// Unciv `unique.sourceObjectType == type` then `unique.sourceObjectName`. Our ruleset objects do not stamp their
    /// own uniques, so a trigger passes the source along instead (`fallback`), as Unciv's stamped unique would carry it.
    private func sourceName(of unique: Unique?, _ type: UniqueTarget, fallback: String?) -> String? {
        if let u = unique, let t = u.sourceObjectType { return t == type ? u.sourceObjectName : nil }
        return fallback ?? unique?.sourceObjectName
    }
}
