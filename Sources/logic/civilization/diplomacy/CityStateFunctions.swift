// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/diplomacy/CityStateFunctions.kt`: how the minor civs answer what is done to them.
extension GameState {
    /// Unciv CityStateFunctions.cityStateAttacked: wariness, protectors and allies get upset.
    func cityStateAttacked(_ cs: Int, by attacker: Int) {
        guard let c = civ(cs), c.isCityState, let a = civ(attacker), !a.isCityState else { return }
        let aggressor = a.numMinorCivsAttacked >= 2, warmonger = a.numMinorCivsAttacked >= 4
        // Unciv CityStateFunctions.kt:644-645: `GameContext(civInfo, attacker)` → civInfo = saldirilan sehir devleti, otherCiv = saldiran.
        var attackRng = stateBasedRandom("CityStateFunctions.cityStateAttacked", civId: cs, otherCivId: attacker)
        if warmonger { becomeWary(cs, of: attacker) } else if aggressor && attackRng.nextBoolean() { becomeWary(cs, of: attacker) }   // Unciv :654 `rng.nextBoolean()`
        if aggressor {
            // Unciv CityStateFunctions.kt:670-671: makeOtherCityStatesWaryOfAttacker ayni baglamdan AYRI bir uretec kurar.
            var waryRng = stateBasedRandom("CityStateFunctions.makeOtherCityStatesWaryOfAttacker", civId: cs, otherCivId: attacker)
            for other in cityStates where other.id != cs && ally(of: other.id) != attacker && other.metCivs.contains(attacker) && !other.quests.contains(where: { $0.name == "Conquer City State" && $0.target == String(cs) }) {   // Unciv: skip city-states that want us dead
                // Unciv: the chance depends on Proximity (Neighbors / Close / Far / Distant), +50 if already at war with the attacker.
                let prox = proximity(other.id, attacker)
                var p: Int = warmonger ? (prox == .neighbors ? 100 : prox == .close ? 75 : prox == .far ? 50 : prox == .distant ? 25 : 0) : (prox == .neighbors ? 50 : prox == .close ? 20 : 0)
                if other.isAtWar(with: attacker) { p += 50 }
                if waryRng.nextInt(below: 100) < p { becomeWary(other.id, of: attacker) }
            }
        }
        for p in cityStateProtectorCivs(cs) where p.metCivs.contains(attacker) && p.id != attacker {   // Unciv getProtectorCivs(): the city-state's diplomacy order
            if hasModifier(p.id, attacker, .AttackedProtectedMinor) && flag(p.id, attacker, "RememberAttackedProtectedMinor") > 50 { addModifier(p.id, attacker, .AttackedProtectedMinor, -15, limit: -100) }
            else { addModifier(p.id, attacker, .AttackedProtectedMinor, -20, limit: -100) }
            setFlag(p.id, attacker, "RememberAttackedProtectedMinor", 75)
            // Unciv triggerProtectorCivs: AI protectors warn the attacker, human protectors get to choose via a popup
            if p.isPlayer { addAlert(p.id, .AttackedProtectedMinor, "\(attacker)@\(cs)") }
            else { notify(attacker, "[\(p.nation)] is upset that you attacked [\(c.nation)], whom they have pledged to protect!", category: .Diplomacy, icons: ["Diplomacy", p.nation]) }   // Unciv: NotificationIcon.Diplomacy, protector.civName
        }
        if let al = ally(of: cs), let alc = civ(al), !alc.protectedCityStates.contains(cs), alc.metCivs.contains(attacker), al != attacker {
            addModifier(al, attacker, .AttackedAlliedMinor, -10)
            if alc.isPlayer { addAlert(al, .AttackedAllyMinor, "\(attacker)@\(cs)") }
            else { notify(attacker, "[\(alc.nation)] is upset that you attacked [\(c.nation)], whom they are allied with!", category: .Diplomacy, icons: ["Diplomacy", alc.nation]) }   // Unciv: NotificationIcon.Diplomacy, allyCiv.civName
        }
        // Unciv cityStateAttacked: the war-with-major pseudo-quest is set up after the protectors and the ally react
        if a.isMajor { warWithMajorStarted(cityState: cs, attacker: attacker) }   // Unciv QuestManager.wasAttackedBy
        setFlag(cs, attacker, "RecentlyAttacked", 2)   // reminder to ask for unit gifts in 2 turns
    }

    /// Unciv DiplomacyManager.becomeWary
    func becomeWary(_ cs: Int, of other: Int) {
        if hasFlag(cs, other, "WaryOf") { return }
        setFlag(cs, other, "WaryOf", -1)
        notify(other, "City-States grow wary of your aggression. The resting point for Influence has decreased by [20] for [\(civ(cs)?.nation ?? "?")].", category: .Diplomacy, icons: [civ(cs)?.nation ?? ""])
    }

    /// Unciv CityStateFunctions.cityStateBullied (tribute demanded)
    /// Unciv order: the protectors react, then the Bullied flag, then every city-state's quests.
    func cityStateBullied(_ cs: Int, by bully: Int) {
        defer {
            setFlag(cs, bully, "Bullied", 20)   // Unciv DiplomacyFlags.Bullied: remembered for future quests
            revokeQuestsAfterTribute(cityState: cs, bully: bully)   // Unciv QuestManager.cityStateBullied
        }
        for p in cityStateProtectorCivs(cs) where p.metCivs.contains(bully) && p.id != bully {   // Unciv getProtectorCivs(): the city-state's diplomacy order
            if hasModifier(p.id, bully, .BulliedProtectedMinor) && flag(p.id, bully, "RememberBulliedProtectedMinor") > 50 { addModifier(p.id, bully, .BulliedProtectedMinor, -10, limit: -100) }
            else { addModifier(p.id, bully, .BulliedProtectedMinor, -15, limit: -100) }
            setFlag(p.id, bully, "RememberBulliedProtectedMinor", 75)
            if p.isPlayer { addAlert(p.id, .BulliedProtectedMinor, "\(bully)@\(cs)") }
            else { notify(bully, "[\(p.nation)] is upset that you demanded tribute from [\(civ(cs)?.nation ?? "?")], whom they have pledged to protect!", category: .Diplomacy, icons: ["Diplomacy", p.nation]) }   // Unciv: NotificationIcon.Diplomacy, protector.civName
        }
    }

    /// Unciv CityStateFunctions.cityStateDestroyed
    func cityStateDestroyed(_ cs: Int, by attacker: Int) {
        for p in cityStateProtectorCivs(cs) where p.metCivs.contains(attacker) && p.id != attacker {   // Unciv getProtectorCivs(): the city-state's diplomacy order
            if hasModifier(p.id, attacker, .DestroyedProtectedMinor) { addModifier(p.id, attacker, .DestroyedProtectedMinor, -10, limit: -100) }
            else { addModifier(p.id, attacker, .DestroyedProtectedMinor, -40, limit: -100) }
            setFlag(p.id, attacker, "RememberDestroyedProtectedMinor", 125)
            if !p.isPlayer { notify(attacker, "[\(p.nation)] is outraged that you destroyed [\(civ(cs)?.nation ?? "?")], whom they had pledged to protect!", category: .Diplomacy, icons: ["Diplomacy", p.nation]) }   // Unciv: NotificationIcon.Diplomacy, protector.civName
            notify(p.id, "[\(civ(attacker)?.nation ?? "?")] has destroyed [\(civ(cs)?.nation ?? "?")], whom you had pledged to protect!", category: .Diplomacy, icons: [civ(attacker)?.nation ?? "", "Death", civ(cs)?.nation ?? ""])
        }
    }

    /// `giver` handed `receiver` value worth `gold` (uninflated); the receiver's opinion of the giver rises.
    func giftGold(from giver: Int, to receiver: Int, value gold: Int, isPureGift: Bool) {
        guard civ(receiver)?.isMajor == true, civ(giver)?.isMajor == true else { return }
        // Unciv DiplomacyManager.giftGold: `(gold * multiplier).roundToInt()` in Float (Math.round: half up)
        let product = Float(gold) * Float(isPureGift ? rs.constants.goldGiftMultiplier : rs.constants.goldGiftTradeMultiplier)
        let current = Int((product + 0.5).rounded(.down))
        let otherGold = goldGifts(receivedBy: giver, from: receiver)
        if otherGold > current { receiveGoldGifts(giver, from: receiver, -current) }
        else { removeModifier(giver, receiver, .GaveUsGifts); receiveGoldGifts(receiver, from: giver, current - otherGold) }
    }

    /// Unciv DiplomacyManager.recieveGoldGifts: `(gold * inflation) / (speed.goldGiftModifier * 100)` - a Double
    /// over a Float - stored as a Float modifier.
    func receiveGoldGifts(_ civId: Int, from other: Int, _ gold: Int) {
        let value = (Double(gold) * goldInflation(civId)) / Double(Float(speed.goldGiftModifier) * 100)
        addModifier(civId, other, .GaveUsGifts, Double(Float(value)))
    }

    /// Unciv DiplomacyManager.getGoldGifts: `((giftAmount * goldGiftModifier * 100) / inflation).toInt()`.
    func goldGifts(receivedBy civId: Int, from other: Int) -> Int {
        Int(Double(Float(modifier(civId, other, .GaveUsGifts)) * Float(speed.goldGiftModifier) * 100) / goldInflation(civId))
    }

    // MARK: - demands (Unciv Demand / agreeToDemand / refuseDemand / onDemandViolation)


    /// Unciv CityStateFunctions.getCityStateResourcesForAlly: city by city, every POSITIVE row of
    /// getResourcesGeneratedByCity filed under "City-States" (`addPositiveByResource`) - "IGNORE the fact that
    /// they consume their own resources", so two Iron from tiles stay two even when a building eats one. Ours
    /// netted each resource first. What an ally receives is this filtered and scaled in updateCivResources.
    func cityStateResourceSupplyForAlly(_ csId: Int) -> ResourceSupplyList {
        var list = ResourceSupplyList()
        for city in cities(of: csId) { list.addPositiveByResource(resourceSupplyGeneratedByCity(city), "City-States") }
        return list
    }

    /// The same by resource name, for the diplomacy screen.
    func cityStateResourcesForAlly(_ csId: Int) -> [String: Int] {
        var supply: [String: Int] = [:]
        for e in cityStateResourceSupplyForAlly(csId).entries { supply[e.resource, default: 0] += e.amount }
        return supply
    }

    static let friendThreshold = 30.0

    static let allyThreshold = 60.0

    var cityStates: [Civilization] { civs.filter { $0.isCityState && $0.isAlive } }

    var majorCivs: [Civilization] { civs.filter { $0.isMajor && $0.isAlive } }

    /// Unciv DiplomacyManager.getInfluence: -60 while at war
    func influence(of major: Int, with cityState: Int) -> Double {
        guard let cs = civ(cityState) else { return 0 }
        return cs.isAtWar(with: major) ? -60 : (cs.influence[major] ?? 0)
    }

    /// Unciv DiplomacyManager.setInfluence: `influence = max(amount, MINIMUM_INFLUENCE)`, then updateAllyCivForCityState.
    func setInfluence(cityState: Int, major: Int, _ amount: Double) {
        guard let ci = civIndex(cityState) else { return }
        civs[ci].influence[major] = max(amount, -60)
        updateAllyCivForCityState(cityState)
    }

    /// Unciv DiplomacyManager.addInfluence: setInfluence(influence + amount), in Float.
    func addInfluence(cityState: Int, major: Int, _ amount: Double) {
        guard let ci = civIndex(cityState) else { return }
        setInfluence(cityState: cityState, major: major, Double(Float(civs[ci].influence[major] ?? 0) + Float(amount)))
    }

    /// Unciv CityStateFunctions.updateAllyCivForCityState: the living major with the highest (war-adjusted)
    /// influence, walked in the city-state's diplomacy order (maxByOrNull keeps the first), if at least 60.
    /// When the ally changes: the new ally is told and refreshes its resources, Austria's MarriageCooldown starts,
    /// and the city-state joins the new ally's wars; then the old ally is told, resents the newcomer and refreshes
    /// its resources. Ours refreshed both allies only after the wars had been declared.
    /// Unciv CityStateDiplomacyTable.kt:128 - building the city-state's diplomacy table runs updateAllyCivForCityState: an
    /// ally whose influence changed without it (a raw `influence += 20f`, a defeated ally) is settled here
    func cityStateDiplomacyTableShown(_ csId: Int) { updateAllyCivForCityState(csId) }
    func updateAllyCivForCityState(_ csId: Int) {
        guard let ci = civIndex(csId), civs[ci].isCityState else { return }
        let oldAlly = ally(of: csId)
        var newAlly: Int? = nil
        var best: (major: Int, influence: Double)? = nil
        // Unciv asks isDefeated()/isAlive() on the spot here, not a flag refreshed at the turn's end: a city-state
        // that just lost its last city (t_45 t=501, Budapest taken by Japan) is already out when Ragusa re-allies
        // with Japan, so Ragusa does not join a war against it.
        for m in diplomacyOrder(csId) where civ(m)?.isMajor == true && civ(m).map({ !isDefeated($0) }) == true {
            let inf = influence(of: m, with: csId)
            if best == nil || inf > best!.influence { best = (m, inf) }
        }
        if let b = best, b.influence >= GameState.allyThreshold { newAlly = b.major }
        if oldAlly == newAlly { return }
        let csName = civs[ci].nation
        var actions: [NotificationAction] = []
        if let cap = capital(of: csId) { actions.append(.location(cap.coord)) }
        actions.append(.diplomacy(csName))
        civs[ci].allySince = [:]
        if let a = newAlly { civs[ci].allySince[a] = turn }
        invalidateHappiness()
        if let a = newAlly {
            notify(a, "We have allied with [\(csName)].", category: .Diplomacy, icons: [csName, "Diplomacy"], actions: actions)
            // Unciv newAlly.cache.updateViewableTiles(): the city-state's territory is seen - and explored - at once,
            // not at the ally's next turn start (an AI unit exploring later in the same turn saw it as unexplored)
            visGen &+= 1   // the ally's view includes the city-state's territory (computeVisibleTiles), so the cached view is stale
            updateExploration(for: a)
            updateCivResources(a)
            for u in civUniques(a) where u.pattern.hasPrefix("Can spend Gold to annex or puppet a City-State that has been your") {
                setFlag(a, csId, "MarriageCooldown", u.int(0))
            }
            // Join the wars of our new ally - loop through all civs they are at war with
            for enemy in civs where areAtWar(enemy.id, a) && !isDefeated(enemy) {
                if areAtWar(csId, enemy.id) { continue }
                if civ(csId)?.metCivs.contains(enemy.id) != true { makeCivilizationsMeet(csId, enemy.id, warOnContact: true) }
                declareWar(csId, on: enemy.id, warType: .cityStateAllianceWar, allyCiv: a)
            }
        }
        if let o = oldAlly, civ(csId).map({ !isDefeated($0) }) == true {
            if let a = newAlly {
                notify(o, "We have lost our alliance with [\(csName)] to [\(civ(a)?.nation ?? "?")].", category: .Diplomacy, icons: [csName, "Diplomacy"], actions: actions)
                if civ(o)?.metCivs.contains(a) == true { addModifier(o, a, .StoleOurAlly, -10) }
            } else {
                notify(o, "We have lost our alliance with [\(csName)].", category: .Diplomacy, icons: [csName, "Diplomacy"], actions: actions)
            }
            // Unciv `oldAlly.cache.updateViewableTiles()` (CityStateFunctions.kt:338): the city-state's territory leaves
            // the old ally's stored view now, not at its next turn start
            visGen &+= 1
            updateExploration(for: o)
            updateCivResources(o)
        }
    }

    /// Unciv Civilization.allyCiv: a FIELD, changed only by updateAllyCivForCityState. Ours recomputed it from the
    /// influence on every read, so a war or a peace moved the alliance at once where Unciv waits for the next
    /// influence change.
    func ally(of cityState: Int) -> Int? {
        guard let cs = civ(cityState), cs.isCityState else { return nil }
        return cs.allySince.keys.first
    }
    /// Unciv getCityStateInfluenceRestingPoint
    func cityStateRestingPoint(_ major: Int, _ cs: Int) -> Double {
        civUniques(major).filter { $0.pattern == "Resting point for Influence with City-States is increased by []" }.reduce(0.0) { $0 + $1.double(0) } + religionRestingPoint(major: major, cityState: cs)
            + (civ(major)?.protectedCityStates.contains(cs) == true ? 10 : 0) - (hasFlag(cs, major, "WaryOf") ? 20 : 0)
    }

    /// Unciv getCityStateInfluenceDegrade: 1.5 hostile / 2 aggressor / 1, × (1 + summed %, −25 when sharing the religion, rivals' faster-degrade uniques)
    func cityStateInfluenceDegrade(_ major: Int, _ cs: Int) -> Double {
        guard let c = civ(cs), let m = civ(major), influence(of: major, with: cs) > cityStateRestingPoint(major, cs) else { return 0 }
        let decrement = c.cityStatePersonality == "Hostile" ? 1.5 : (m.numMinorCivsAttacked >= 2 ? 2 : 1)
        // Unciv modifierPercent is a Float, and so is the product
        var pct: Float = civUniques(major).filter { $0.pattern == "[]% City-State Influence degradation" }.reduce(0) { $0 + Float($1.double(0)) }
        if let r = m.religionName, let cap = capital(of: cs), majorityReligion(of: cap) == r { pct -= 25 }
        // Unciv `gameInfo.civilizations.filter { it.isMajorCiv() && it != otherCiv }`: no isDefeated filter - a
        // conquered civ that completed Patronage still speeds everyone's decay (its policies are never cleared)
        for rival in civs where rival.isMajor && rival.id != major { pct += civUniques(rival.id).filter { $0.pattern == "Influence of all other civilizations with all city-states degrades []% faster" }.reduce(0) { $0 + Float($1.double(0)) } }
        return Double(Float(max(0, decrement)) * (1 + max(-100, pct) / 100))
    }

    /// Unciv getCityStateInfluenceRecovery: 1 × (1 + 100% with the twice-rate unique + 50% when sharing the religion)
    func cityStateInfluenceRecovery(_ major: Int, _ cs: Int) -> Double {
        guard let m = civ(major), influence(of: major, with: cs) < cityStateRestingPoint(major, cs) else { return 0 }
        var pct = 0.0
        if civHasUnique(major, "City-State Influence recovers at twice the normal rate") { pct += 100 }
        if let r = m.religionName, let cap = capital(of: cs), majorityReligion(of: cap) == r { pct += 50 }
        return 1 + max(0, pct) / 100
    }

    func isFriend(_ major: Int, of cityState: Int) -> Bool { influence(of: major, with: cityState) >= GameState.friendThreshold }

    func isAlly(_ major: Int, of cityState: Int) -> Bool { ally(of: cityState) == major }

    func relationName(_ major: Int, _ cityState: Int) -> String {
        if isAlly(major, of: cityState) { return "Ally" }
        if isFriend(major, of: cityState) { return "Friend" }
        let inf = influence(of: major, with: cityState)
        return inf < 0 ? "Hostile" : "Neutral"
    }

    /// Bonus uniques a major civ receives from all city-states it is friends/allies with.
    /// Unciv reads a STORED list here (see GameState.cityStateBonusCache), not a live one.
    func cityStateBonusUniques(for major: Int) -> [Unique] {
        if let c = cityStateBonusCache[major] { return c }
        let v = computeCityStateBonusUniques(for: major)
        cityStateBonusCache[major] = v
        return v
    }

    func computeCityStateBonusUniques(for major: Int) -> [Unique] {
        var out: [Unique] = []
        // Unciv CivInfoTransientCache.updateCityStateBonuses: `for (diplomacyManager in civInfo.diplomacy.values)` -
        // the known civs in the diplomacy map's order, living city-states only; the ally's map, else the friend's
        // when the influence is at least 30. A city-state has none of these.
        guard civ(major)?.isCityState == false else { return [] }
        for id in diplomacyOrder(major) {
            // Unciv `cityState.isDefeated()`, asked on the spot: a city-state just married away (Austria, Zurich) has no
            // city left although our `isAlive` flag is refreshed only at the turn's end - it kept its +3 happiness here.
            guard let cs = civ(id), cs.isCityState, !isDefeated(cs), let typeName = cs.cityStateType, let type = rs.cityStateTypes[typeName] else { continue }
            // Unciv CityStateType.allyBonusUniqueMap / friendBonusUniqueMap: `Unique(it, UniqueTarget.CityState, name)` - the
            // source is the city-state TYPE ("Maritime"), which the city's stat details list the bonus under, not the
            // city-state (the state dump's CTREE, a test game, turn 23: Thebes' "City-States > Maritime", ours "> Mombasa")
            if isAlly(major, of: cs.id) { out += type.allyBonusUniques.map { Unique($0).from(.cityState, typeName) } }
            else if influence(of: major, with: cs.id) >= GameState.friendThreshold { out += type.friendBonusUniques.map { Unique($0).from(.cityState, typeName) } }
        }
        // "[+50]% [Food] from City-States" (Siam) is not applied here: Unciv keeps the bonus uniques as the city-state type
        // wrote them, with the city-state as their source, and multiplies their stats where they are counted - a city's
        // getStatsFromUniquesBySource (CityStats.kt:210-218) and getGlobalStatsFromUniques' "City-States" row
        // (CivInfoStatsForNextTurn.kt:347-352). Rebuilding the unique from its scaled stats lost that source, so the
        // happiness breakdown filed Siam's city-state happiness under no name (a state comparison, a test game, turn 50).
        return out
    }

    /// Unciv CityStateFunctions.giveMilitaryUnitToPatron: the city-state's unique unit when the patron can build it (tech known, not obsolete),
    /// otherwise a random buildable non-unique land military unit; placed near the patron's city closest to the city-state.
    func giveMilitaryUnitToPatron(cityState cs: Int, patron: Int) {
        guard let csCiv = civ(cs), let csCap = capital(of: cs), let p = civ(patron) else { return }
        guard let city = cities(of: patron).min(by: { $0.coord.distance(to: csCap.coord) < $1.coord.distance(to: csCap.coord) }) else { return }
        var pick: UnitDef? = nil
        if let name = csCiv.cityStateUniqueUnit, let u = rs.units[name], u.requiredTech.map({ p.techs.contains($0) }) ?? true, !(u.obsoleteTech.map { p.techs.contains($0) } ?? false) { pick = u }
        if pick == nil {
            let counts = resourceCounts(patron)
            let options = buildableUnits(for: city).filter { $0.isLand && !$0.isCivilian && $0.uniqueTo == nil && resourceRequirementsPerTurn(requiredResource: $0.requiredResource, uniques: $0.uniqueObjects, ctx: UniqueContext(civId: patron)).allSatisfy { (counts[$0.key] ?? 0) >= $0.value } }   // Unciv: no resource quota exceeded
            // Unciv CityStateFunctions.kt:145 — caller dizesi Unciv'de de "giveGreatPersonToPatron" (kopyala-yapistir hatasi, aynen korunur).
            var g = stateBasedRandom("CityStateFunctions.giveGreatPersonToPatron", civId: cs, otherCivId: patron)
            pick = g.pick(options)
        }
        guard let def = pick, let gifted = spawnUnit(def.name, civId: patron, at: city.coord) else { return }
        if let gi = unitIndex(gifted.id) {
            addConstructionBonuses(unitIndex: gi, city: csCap)   // Unciv: bonuses from Barracks etc. as if built in the city-state capital
            units[gi].xp += giftedUnitXP(patron)
        }
        notify(patron, "[\(csCiv.nation)] gave us a [\(def.name)] as gift near [\(city.name)]!", category: .Units, icons: [csCiv.nation, def.name], actions: [.unit(gifted.coord, gifted.id), .location(city.coord)], coord: city.coord)   // MapUnitAction(placedUnit): where it was placed
    }

    /// Turns between military gifts from a militaristic city-state ("Provides military units every ≈[20] turns").
    func militaryGiftInterval(_ major: Int, from cs: Civilization) -> Int? {
        guard let typeName = cs.cityStateType, let type = rs.cityStateTypes[typeName] else { return nil }
        // Unciv: the major's own relationship level - influence for a human, opinion for an AI - decides and selects the list
        let level = relationshipLevel(major, cs.id)
        let list = level >= .ally ? type.allyBonusUniques : level >= .friend ? type.friendBonusUniques : []
        return list.map(Unique.init).first { $0.pattern == "Provides military units every ≈[] turns" }?.int(0)
    }

    /// Unciv influenceGainedByGift: gift^1.01 / 9.8, fading by two thirds over the first 400 turns, rounded down to fives, minimum 5.
    func influenceGainedByGift(from major: Int, amount: Double, cityState: Int? = nil) -> Double {
        // Unciv, in Float, with gameInfo.turns - which our `turn` runs one ahead of outside the barbarian phase.
        // t_45 turn 98: Japan's 500 gold to Ragusa is 50.1 there and was 49.9 here, and the round down to a
        // multiple of 5 made it 50 influence against 45.
        let gameTurns = Float(turn - (barbarianPhase ? 0 : 1))
        var gain = powf(Float(amount), 1.01) / 9.8
        let progress = min(gameTurns / (400 * Float(speed.modifier)), 1)
        gain *= 1 - (2 / 3 as Float) * progress
        gain *= Float(speed.goldGiftModifier)
        for u in civUniques(major) where u.pattern == "Gifts of Gold to City-States generate []% more Influence" { gain *= 1 + Float(u.double(0)) / 100 }
        if let cs = cityState { gain *= Float(investmentMultiplier(cs, for: major)) }   // Unciv questManager.getInvestmentMultiplier
        gain -= gain.truncatingRemainder(dividingBy: 5)
        if gain < 5 { gain = 5 }
        return Double(Int(gain))
    }

    /// Unciv CityStateFunctions.receiveGoldGift: the donor pays, the city-state banks it, the influence is added
    /// and the quest manager hears of it - nothing else. Ours also made the two civs meet and refreshed the
    /// donor's happiness caches, neither of which Unciv does (a gift needs the two to know each other already).
    func giftGold(from major: Int, to cityState: Int, amount: Double) {
        guard let mi = civIndex(major), let ci = civIndex(cityState), civs[ci].isCityState, civs[mi].gold >= amount else { return }
        civs[mi].gold -= amount; goldTrace(major, -amount)
        civs[ci].gold += amount
        addInfluence(cityState: cityState, major: major, influenceGainedByGift(from: major, amount: amount, cityState: cityState))
        onGoldGifted(to: cityState, by: major, amount: amount)
    }

    /// Unciv TileMap.tileMatrix.size: `rightX - leftX + 1` over the real tiles' hex x (TileMap.setTransients) - one
    /// matrix column per hex x. A rectangular W×H map spans about H + W/2 (HexMath.getTileCoordsFromColumnRow):
    /// 76 on Large, 100 on Huge. A hexagonal map of radius R spans 2R+1; ours carves it out of a square grid,
    /// whose padding tiles do not exist in Unciv - and our hexagonal world-wrap map is that square uncarved.
    var uncivTileMatrixSize: Int {
        if let c = uncivTileMatrixSizeCache, c.width == map.width, c.height == map.height, c.missing == map.missing.count { return c.size }
        let size: Int
        if let r = map.hexRadius { size = 2 * r + 1 }
        else if map.wrapX && map.missing.isEmpty && settings.mapShape != "Rectangular" { size = 2 * (min(map.width, map.height) / 2) + 1 }
        else {
            var lo = Int.max, hi = Int.min
            for (i, t) in map.tiles.enumerated() where !map.missing.contains(i) {
                let x = uncivPosition(t.coord).x
                lo = min(lo, x); hi = max(hi, x)
            }
            size = lo <= hi ? hi - lo + 1 : 0
        }
        uncivTileMatrixSizeCache = (map.width, map.height, map.missing.count, size)
        return size
    }

    /// Unciv CityStateFunctions.getTributeModifiers (ordered, so the diplomacy screen can list them).
    func tributeModifiers(from major: Int, _ cityState: Int, demandingWorker: Bool = false, requireWholeList: Bool = false) -> [(String, Int)] {
        var m: [(String, Int)] = []
        guard let cs = civ(cityState), cs.isCityState else { return [("Major Civ", -999)] }
        guard let cap = capital(of: cityState) else { return [("No Cities", -999)] }
        m.append(("Base value", -110))
        if cs.cityStatePersonality == "Hostile" { m.append(("Hostile", -10)) }
        if let a = ally(of: cityState), a != major { m.append(("Has Ally", -10)) }
        if majorCivs.contains(where: { $0.protectedCityStates.contains(cityState) && $0.id != major }) { m.append(("Has Protector", -20)) }
        if demandingWorker { m.append(("Demanding a Worker", -30)) }
        if demandingWorker && cap.population < 4 { m.append(("Demanding a Worker from small City-State", -300)) }
        let recent = civ(cityState)?.civFlags["RecentlyBullied"] ?? 0   // Unciv getRecentBullyingCountdown: a CIV flag (startTurnFlags)
        if recent > 10 { m.append(("Very recently paid tribute", -300)) } else if recent > 0 { m.append(("Recently paid tribute", -40)) }
        if influence(of: major, with: cityState) < -30 { m.append(("Influence below -30", -300)) }
        if !requireWholeList && m.reduce(0, { $0 + $1.1 }) < -200 { return m }
        let alive = majorCivs.filter { $0.isAlive }
        // Unciv sortedByDescending: stable, ties keep the civilizations' order - and no key taken for a lone major
        // (getStatForRanking(Force) caches the strength)
        let byForce = sortedDescendingStable(alive) { statForRanking($0, "Force") }
        let forceRank = byForce.firstIndex { $0.id == major } ?? -1
        let numAlive = max(alive.count, 1)
        m.append(("Military Rank", rs.constants.tributeGlobalModifier * (numAlive - forceRank) / numAlive))
        if !requireWholeList && m.reduce(0, { $0 + $1.1 }) < -100 { return m }
        // Unciv: `(tileMap.tileMatrix.size / 10).coerceIn(5, 10)` - the span of the tiles' hex x, not max(width, height)
        let bullyRange = min(10, max(5, uncivTileMatrixSize / 10))
        let inRange = map.tilesWithin(cap.coord, radius: bullyRange).filter { $0 != cap.coord }
        // Unciv: `getDefendingStrength().toFloat().pow(1.5f).toInt()` plus each tile's militaryUnit (never an aircraft)
        var forceNear = 0, csForce = Int(powf(Float(cityStrength(cap)), 1.5))
        for c in inRange { for u in units(at: c) where u.isMilitary && !u.def.isAir { if u.civId == major { forceNear += unitForceEvaluation(u) } else if u.civId == cityState { csForce += unitForceEvaluation(u) } } }
        let ratio = Float(forceNear) / Float(csForce)
        let local = rs.constants.tributeLocalModifier
        m.append(("Military near City-State", ratio > 3 ? local : ratio > 2 ? local * 4 / 5 : ratio > 1.5 ? local * 3 / 5 : ratio > 1 ? local * 2 / 5 : ratio > 0.5 ? local / 5 : 0))
        return m
    }

    func tributeWillingness(from major: Int, _ cityState: Int, demandingWorker: Bool = false) -> Int { tributeModifiers(from: major, cityState, demandingWorker: demandingWorker).reduce(0) { $0 + $1.1 } }

    func canDemandTribute(from major: Int, _ cityState: Int) -> Bool {
        guard let cs = civ(cityState), !cs.isAtWar(with: major) else { return false }
        return tributeWillingness(from: major, cityState) >= 0
    }

    /// Unciv goldGainedByTribute: 50 × gift modifier, plus 5 every tribute-scaling interval of turns.
    func goldGainedByTribute() -> Int { Int(10 * speed.goldGiftModifier) * 5 + 5 * Int(Float(uncivTurns) / Float(speed.cityStateTributeScalingInterval)) }   // Unciv: (gameInfo.turns / turnsToIncrement).toInt(), Float

    /// Unciv tributeWorker: needs willingness ≥ 0 with the worker penalties; a random buildable worker-type civilian placed at the city-state's capital; −50 influence.
    func canDemandWorker(from major: Int, _ cityState: Int) -> Bool {
        guard let cs = civ(cityState), !cs.isAtWar(with: major), capital(of: cityState) != nil else { return false }
        return tributeWillingness(from: major, cityState, demandingWorker: true) >= 0
    }

    func tributeWorker(from major: Int, _ cityState: Int) {
        guard canDemandWorker(from: major, cityState), let csCap = capital(of: cityState) else { return }
        // Unciv `ruleset.units.filter { ... }`: the LinkedHashMap, in Units.json order
        let options = rs.unitOrder.compactMap { rs.units[$0] }.filter { !$0.improvementFilters.isEmpty && $0.isCivilian && unitRejections($0, civId: cityState, city: nil).isEmpty }
        // Unciv CityStateFunctions.kt:525: `civInfo.getDiplomacyManager(demandingCiv)!!.state.stateBasedRandom("CityStateFunctions.tributeWorker")`
        var g = stateBasedRandom("CityStateFunctions.tributeWorker", civId: cityState, otherCivId: major)
        guard let worker = g.pick(options) else { return }
        // Unciv `placeUnitNearTile(capital.location, ...)`: the foreign city centre cannot be entered, so the ring walk
        // starts from the capital's own neighbours (land first) and takes the first one the worker can move to -
        // a city-state warrior next to its capital blocks that tile. Ours picked a neighbour beforehand, blind to
        // foreign military units, and walked from there.
        _ = spawnUnit(worker.name, civId: major, at: csCap.coord)
        addInfluence(cityState: cityState, major: major, -50)
        cityStateBullied(cityState, by: major)
        if let rb = civIndex(cityState) { civs[rb].civFlags["RecentlyBullied"] = 20 }   // Unciv civInfo.addFlag(CivFlags.RecentlyBullied, 20)
    }

    /// Unciv otherCivCanWithdrawProtection: protectors may withdraw once they have protected for at least 10 turns and are not at war.
    func canWithdrawProtection(_ civId: Int, _ cs: Int) -> Bool {
        // Unciv otherCivCanWithdrawProtection: a known city-state we protect, and its RecentlyPledgedProtection flag
        // (10, counted in the city-state's own turns) gone - war allowed. Ours counted rounds since the pledge.
        guard let m = civ(civId), m.isMajor, m.isAlive, civ(cs)?.isCityState == true, civ(cs)?.metCivs.contains(civId) == true, m.protectedCityStates.contains(cs) else { return false }
        return !hasFlag(cs, civId, "RecentlyPledgedProtection")
    }

    /// Unciv "Gift Improvement": resource tiles of the city-state that still lack their improvement (200 gold each).
    func giftableImprovementTiles(of cityState: Int, by major: Int) -> [(HexCoord, String, String)] {
        var out: [(HexCoord, String, String)] = []
        // c.tiles bir Set<HexCoord>: dönen liste her açılışta başka sırada çıkıyordu.
        for c in cities(of: cityState) { for t in c.tiles.sorted(by: { ($0.q, $0.r) < ($1.q, $1.r) }).compactMap({ map[$0] }) {
            guard let r = t.resource, let def = rs.resources[r], def.resourceType != "Bonus", (def.revealedBy == nil || (civ(cityState)?.techs.contains(def.revealedBy!) ?? false)) else { continue }
            let improvers = rs.resourceImprovements[r] ?? []
            if let current = t.improvement, improvers.contains(current) { continue }   // Unciv getImprovableResourceTiles: not improved for the resource yet
            for imp in buildableImprovements(t, civId: cityState).map({ $0.name }).sorted() where improvers.contains(imp) {   // isImprovedBy && canBuildImprovement
                out.append((t.coord, r, imp))
            }
        } }
        return out
    }

    func giftImprovement(from major: Int, to cityState: Int, at c: HexCoord, improvement: String) {
        guard let mi = civIndex(major), civs[mi].gold >= 200, map[c] != nil else { return }
        // Unciv CityStateDiplomacyTable improveTileButton: addGold(-200), stopWorkingOnImprovement(),
        // setImprovement(improvement, cityState) (features, triggers, stats), cache.updateCivResources()
        civs[mi].gold -= 200
        stopWorkingOnImprovement(at: c)
        setImprovement(at: c, improvement, civToActivateBroaderEffects: cityState)
        updateCivResources(cityState)
    }

    func demandTribute(from major: Int, _ cityState: Int) {
        guard canDemandTribute(from: major, cityState), let mi = civIndex(major), let ci = civIndex(cityState) else { return }
        let gold = Double(goldGainedByTribute())
        civs[mi].gold += gold; goldTrace(civs[mi].id, gold)
        addInfluence(cityState: cityState, major: major, -15)
        cityStateBullied(cityState, by: major)
        if let rb = civIndex(cityState) { civs[rb].civFlags["RecentlyBullied"] = 20 }   // Unciv civInfo.addFlag(CivFlags.RecentlyBullied, 20)
        invalidateHappiness(major)
    }

    // MARK: diplomatic marriage ("Can spend Gold to annex or puppet a City-State that has been your ally for [5] turns.")
    func marriageTurnsRequired(_ major: Int) -> Int? {
        civUniques(major).first { $0.pattern == "Can spend Gold to annex or puppet a City-State that has been your Ally for [] turns" || $0.pattern == "Can spend Gold to annex or puppet a City-State that has been your ally for [] turns." }?.int(0)
    }

    /// Unciv getDiplomaticMarriageCost: 500 × gold cost modifier plus the disband value (purchase cost / 20) of every unit the city-state owns.
    func marriageCost(_ major: Int, cityState: Int? = nil) -> Double {
        var cost = Int(500 * speed.goldCostModifier)
        if let cs = cityState { for u in units(of: cs) { cost += disbandGold(u.def, civId: cs) } }   // Unciv unit.baseUnit.getDisbandGold(civInfo)
        return Double(cost / 5 * 5)   // Unciv: rounded down to a multiple of 5
    }

    func canMarry(_ major: Int, _ cityState: Int) -> Bool {
        // Unciv CityStateFunctions.canBeMarriedBy: an undefeated city-state with cities, allied (influence >= 60 and
        // allyCiv), the major's MarriageCooldown flag - set when the alliance began, counted in the major's own
        // turns - gone, the unique, and the gold. Ours counted rounds since the alliance instead of the flag.
        guard marriageTurnsRequired(major) != nil, let cs = civ(cityState), cs.isAlive, cs.isCityState, !cities(of: cityState).isEmpty,
              relationshipLevel(cityState, major) == .ally, !hasFlag(major, cityState, "MarriageCooldown"),
              let m = civ(major), m.gold >= marriageCost(major, cityState: cityState) else { return false }
        return true
    }

    /// Unciv CityStateFunctions.diplomaticMarriage: the major pays; it and then every other civ are told; each unit
    /// of the city-state is gifted (MapUnit.gift - out of one list and appended to the other, with the upkeep and
    /// resources recounted); every city it founded forgets its founder, so none can ever be liberated; each of its
    /// cities goes through moveToCiv and becomes a puppet; and the city-state is destroyed.
    ///
    /// Ours rewrote the owner fields of the cities and units directly - none of moveToCiv's capital, building,
    /// stats, proximity and supply updates, no gift bookkeeping - kept the founder, and ended every war.
    func marry(_ major: Int, _ cityState: Int) {
        guard canMarry(major, cityState), let mi = civIndex(major), let ci = civIndex(cityState) else { return }
        civs[mi].gold -= marriageCost(major, cityState: cityState)
        civs[mi].marriedCityStates += 1
        let csName = civs[ci].nation, majorName = civs[mi].nation
        let notificationLocation = capital(of: cityState)?.coord
        notify(major, "We have married into the ruling family of [\(csName)], bringing them under our control.", category: .Diplomacy, icons: [csName, "Diplomacy", majorName], coord: notificationLocation)
        for other in civs where other.id != major && !other.isBarbarian {
            notify(other.id, "[\(majorName)] has married into the ruling family of [\(csName)], bringing them under their control.", category: .Diplomacy, icons: [csName, "Diplomacy", majorName], coord: notificationLocation)
        }
        for u in units(of: cityState) where unit(u.id)?.civId == cityState { giftUnitTo(u.id, recipient: major) }
        // "Make sure this CS can never be liberated"
        for i in cities.indices where cities[i].originalOwner == cityState {
            cities[i].originalOwner = -1
            cities[i].isOriginalCapital = false
        }
        for c in cities(of: cityState) {
            spiesFlee(fromCity: c.id, cityName: c.name, reason: .takenOver)   // SpyFleeReason.CityTakenOverByMarriage
            moveToCiv(cityId: c.id, newCiv: major)
            if let idx = cityIndex(c.id) { cities[idx].isPuppet = true }   // "Human players get a popup that allows them to annex instead"
        }
        destroyCiv(cityState, notificationLocation: notificationLocation)
    }

    /// Per-turn city-state bookkeeping: influence decay, unit gifts, luxury sharing handled in resourceCounts.
    /// Unciv CityStateFunctions.getFreeTechForCityState: city-states automatically get every tech that more than half of the living majors know.
    func freeTechsForCityState(_ ci: Int) {
        let majors = majorCivs
        guard !majors.isEmpty else { return }
        for tech in researchableTechs(for: civs[ci]) where !tech.uniques.contains("Can be continually researched") {
            if majors.filter({ $0.techs.contains(tech.name) }).count > majors.count / 2 {
                addTechnology(civId: civs[ci].id, tech: tech.name)
            }
        }
    }

    /// Unciv MapUnit.threatensCiv: a barbarian on or next to the city-state's territory.
    func barbarianThreatens(_ unit: Unit, cityState cs: Int) -> Bool {
        if map[unit.coord]?.ownerCivId == cs { return true }
        return map.neighbors(of: unit.coord).contains { map[$0]?.ownerCivId == cs }
    }

    /// Unciv threateningBarbarianKilledBy: +12 influence and 5 turns of anger-free intrusion for the civ that killed a threatening barbarian.
    func threateningBarbarianKilled(_ victim: Unit, by civId: Int) {
        guard let killer = civ(civId), killer.isMajor else { return }   // Unciv Battle: a major civ that knows the city-state
        for cs in cityStates where cs.isAlive && killer.metCivs.contains(cs.id) && barbarianThreatens(victim, cityState: cs.id) && !cs.isAtWar(with: civId) {
            guard let ci = civIndex(cs.id) else { continue }
            addInfluence(cityState: cs.id, major: civId, 12)
            let current = civs[ci].diploFlags[civId]?["AngerFreeIntrusion"] ?? 0
            setFlag(cs.id, civId, "AngerFreeIntrusion", current + 5)
            notify(civId, "[\(cs.nation)] is grateful that you killed a Barbarian that was threatening them!", category: .Diplomacy, icons: [cs.nation], actions: [.diplomacy(cs.nation)])
        }
    }

    /// Unciv askForUnitGifts: an attacked city-state asks every major that knows the attacker and is not at war with them for military units.
    func askForUnitGifts(cityState cs: Int, attacker: Int) {
        guard let c = civ(cs), c.isAlive, let a = civ(attacker), a.isAlive, let cap = capital(of: cs) else { return }
        // Unciv `civInfo.getKnownCivs()` (neither defeated nor the Spectator), then majors that know the attacker and are
        // at peace with it; the icon is the literal "OtherIcons/Present", there being no NotificationIcon for it
        for third in knownCivs(cs) where !third.isSpectator && third.id != attacker && third.metCivs.contains(attacker) && !third.isAtWar(with: attacker) && third.isMajor {
            notify(third.id, "[\(c.nation)] is being attacked by [\(a.nation)] and asks all major civilizations to help them out by gifting them military units.", category: .Diplomacy, icons: [c.nation, "OtherIcons/Present"], coord: cap.coord)
        }
    }

    /// Unciv turnsForGreatPersonFromCityState: (37 + rand 7) × speed.
    /// Unciv CityStateFunctions.kt:124: `(37 + civInfo.state.stateBasedRandom("CityStateFunctions.turnsForGreatPersonFromCityState").nextInt(7)) * speed.modifier`.
    /// `civInfo` cagri yerinde (TurnManager.kt:137) bayragi tutan BUYUK civ'dir, sehir devleti degil.
    func turnsForGreatPersonFromCityState(_ civId: Int) -> Int {
        var g = stateBasedRandom("CityStateFunctions.turnsForGreatPersonFromCityState", civId: civId)
        return Int(Double(37 + g.nextInt(below: 7)) * speed.modifier)
    }

    /// Unciv giveGreatPersonToPatron: a random non-prophet great person appears at the patron's city nearest to the city-state's capital.
    func giveGreatPersonToPatron(cityState cs: Int, patron: Int) {
        // Unciv: `ruleset.units.values.filter { it.isGreatPerson && !it.hasUnique(MayFoundReligion) }` - ruleset order and the
        // literal unit, so another nation's unique great person (Khan) can be gifted. Ours sorted the names alphabetically.
        let giftable = rs.unitOrder.compactMap { rs.units[$0] }.filter { $0.isGreatPerson && !$0.canFoundReligion }.map { $0.name }
        // Unciv CityStateFunctions.kt:134: `civInfo.getDiplomacyManager(receivingCiv)!!.state.stateBasedRandom("CityStateFunctions.giveGreatPersonToPatron")`
        var g = stateBasedRandom("CityStateFunctions.giveGreatPersonToPatron", civId: cs, otherCivId: patron)
        // Unciv NextTurnAutomation.getForeignCityNearCapital: the first of the patron's cities at the least aerial distance
        guard let gp = g.pick(giftable), let csCap = capital(of: cs), let city = foreignCityNearCapital(of: cs, foreignCiv: patron)?.city else { return }
        if ProcessInfo.processInfo.environment["DUMP_GPCITY"] != nil {
            print("GPGIFTE t=\(turn) \(civ(cs)?.nation ?? "?") -> \(civ(patron)?.nation ?? "?") gp=\(gp) city=\(city.name)")
        }
        guard let placed = spawnUnit(gp, civId: patron, at: city.coord) else { return }
        notify(patron, "[\(civ(cs)?.nation ?? "?")] gave us a [\(gp)] as a gift!", category: .Units, icons: [civ(cs)?.nation ?? "", gp], actions: [.location(placed.coord), .location(csCap.coord)])
    }

    /// Unciv CityStateFunctions.updateDiplomaticRelationshipForCityState, from the city-state's automateCivMoves:
    /// a major's military units inside our borders cost it 10 influence while we are less than friends - unless
    /// barbarians threaten us, it is at war with us, it recently helped us, or it has the always-friendly unique.
    func updateDiplomaticRelationshipForCityState(_ csId: Int) {
        guard let cs = civ(csId), cs.isCityState else { return }
        // Unciv getNumThreateningBarbarians: every barbarian unit that threatens us, 0 without barbarians
        if settings.barbarians && units.contains(where: { $0.civId == barbarianCivId && barbarianThreatens($0, cityState: csId) }) { return }
        for other in knownCivs(csId).filter({ $0.isMajor }) {
            if areAtWar(csId, other.id) { continue }
            if civUniques(other.id).contains(where: { $0.pattern == "City-State territory always counts as friendly territory" }) { continue }
            if hasFlag(csId, other.id, "AngerFreeIntrusion") { continue }   // they recently helped us
            let unitsInBorder = units(of: other.id).filter { !$0.isCivilian && map[$0.coord]?.ownerCivId == csId }.count
            if unitsInBorder > 0 && relationshipLevel(csId, other.id) < .friend {
                addInfluence(cityState: csId, major: other.id, -10)
                if !hasFlag(csId, other.id, "BorderConflict") {
                    addAlert(other.id, .BorderConflict, "\(csId)")
                    setFlag(csId, other.id, "BorderConflict", 10)
                }
            }
        }
    }

    // MARK: diplomatic victory (Unciv VictoryManager / TurnManager.handleDiplomaticVictoryFlags / Civilization.diplomaticVoteForCiv)
}
