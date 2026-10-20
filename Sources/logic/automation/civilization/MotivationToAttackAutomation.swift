// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's civilization/MotivationToAttackAutomation.kt - in Float, as there. Every term is a Float
// in Unciv (personality foci, strength ratios, the modifier list and its `sum()`), and the thresholds the
// callers compare the result against (> 0, >= 10, >= 15, >= 20) sit exactly where a Double sum rounds
// differently from a Float one.

/// Kotlin `Float > Double-literal` compares the Float widened to Double.
@inline(__always) private func gtD(_ f: Float, _ d: Double) -> Bool { Double(f) > d }

extension GameState {
    /// Unciv `getStatForRanking(RankingType.Force)`: 0 for a defeated civ.
    func forceRanking(_ civId: Int) -> Int {
        guard let c = civ(civId), c.isAlive else { return 0 }
        return militaryMight(civId)
    }
    /// Unciv `getStatForRanking(RankingType.Score)`: 0 for a defeated civ.
    func scoreRankingForAI(_ civId: Int) -> Int {
        guard let c = civ(civId), c.isAlive else { return 0 }
        return scoreRanking(civId)
    }
    /// Unciv ThreatManager.getCombinedForceOfWarringCivs: `getCivsAtWarWith().sumOf { Force }` - an Int.
    func combinedForceOfWarringCivsAI(_ civId: Int) -> Int { civsAtWarWith(civId).reduce(0) { $0 + forceRanking($1.id) } }

    /// Unciv MotivationToAttackAutomation.hasAtLeastMotivationToAttack, for the callers that still work in Double.
    func hasAtLeastMotivationToAttack(_ civId: Int, _ targetCiv: Int, atLeast: Double) -> Double {
        Double(motivationToAttack(civId, targetCiv, atLeast: Float(atLeast)))
    }

    /// Unciv MotivationToAttackAutomation.hasAtLeastMotivationToAttack: returns the motivation to attack, but may
    /// short-circuit (before the path search) when the value is already below `atLeast`.
    func motivationToAttack(_ civId: Int, _ targetCiv: Int, atLeast: Float) -> Float {
        guard let civ = civ(civId), let target = self.civ(targetCiv) else { return 0 }
        let p = personality(of: civId)
        func sf(_ v: PersonalityValue) -> Float { Float(p.scaledFocus(v)) }
        func isf(_ v: PersonalityValue) -> Float { Float(p.inverseScaledFocus(v)) }

        let targetCitiesWithOurCity = neighboringCitiesOfOtherCivs(civId).filter { $0.1.civId == targetCiv }
        let targetCities = targetCitiesWithOurCity.map { $0.1 }
        if targetCitiesWithOurCity.isEmpty { return 0 }
        if targetCities.allSatisfy({ hasNoUnitsThatCanAttackCityWithoutDying(civId, $0) }) { return 0 }

        let baseForce: Float = 100
        let ourCombatStrength = calculateSelfCombatStrength(civId, baseForce)
        let theirCombatStrength = calculateCombatStrengthWithProtectors(targetCiv, baseForce, civId)

        var modifiers: [(String, Float)] = []
        // If our personality is to declare war more then we should have a higher base motivation (a negative number closer to 0)
        modifiers.append(("Base motivation", -(15 * isf(.declareWar))))
        modifiers.append(("Relative combat strength", getCombatStrengthModifier(civId, targetCiv, ourCombatStrength, theirCombatStrength + 0.8 * Float(combinedForceOfWarringCivsAI(civId)))))
        modifiers.append(("Concurrent wars", Float(-civsAtWarWith(civId).filter { $0.isMajor && $0.id != targetCiv }.count) * 20))
        modifiers.append(("Their concurrent wars", Float(civsAtWarWith(targetCiv).filter { $0.isMajor }.count) * 3))
        modifiers.append(("Their allies", getDefensivePactAlliesScore(targetCiv, civId, baseForce, ourCombatStrength)))

        if !neighboringCivilizations(civId).contains(where: { $0 != targetCiv && (self.civ($0)?.isMajor ?? false) && relationshipLevel(civId, $0) < .friend }) {
            modifiers.append(("No other threats", 10))
        }

        if target.isMajor {
            modifiers.append(("Relative score", getScoreRatioModifier(targetCiv, civId)))
            if unitSupplyDeficit(civId) != 0 {
                modifiers.append(("Over unit supply", min(Float(unitSupplyDeficit(civId)) * 2, 20)))
            } else if unitSupplyDeficit(targetCiv) == 0 && !target.isCityState {
                modifiers.append(("Relative production", getProductionRatioModifier(civId, targetCiv)))
            }
        }

        let minTargetCityDistance = targetCitiesWithOurCity.map { $0.1.coord.distance(to: $0.0.coord) }.min() ?? 0
        // Defensive civs should avoid fighting civilizations that are farther away and don't pose a threat
        let farAway: Float = minTargetCityDistance > 20 ? -10 : minTargetCityDistance > 14 ? -8 : minTargetCityDistance > 10 ? -3 : 0
        modifiers.append(("Far away cities", farAway * isf(.aggressive)))
        // Defensive civs want to deal with potential nearby cities to protect themselves
        if minTargetCityDistance < 6 { modifiers.append(("Close cities", 5 * isf(.aggressive))) }

        if hasFlag(civId, targetCiv, "ResearchAgreement") { modifiers.append(("Research Agreement", -5 * sf(.science) * sf(.commerce))) }
        if hasFlag(civId, targetCiv, "DeclarationOfFriendship") { modifiers.append(("Declaration of Friendship", -10 * sf(.loyal))) }
        if hasFlag(civId, targetCiv, "DefensivePact") { modifiers.append(("Defensive Pact", -15 * sf(.loyal))) }

        modifiers.append(("Relationship", getRelationshipModifier(civId, targetCiv)))

        if hasFlag(civId, targetCiv, "Denunciation") { modifiers.append(("Denunciation", 5 * isf(.diplomacy))) }

        if hasFlag(civId, targetCiv, "WaryOf") && flag(civId, targetCiv, "WaryOf") < 0 {
            // Completely defensive civs will plan defensively and have a 0 here
            modifiers.append(("PlanningAttack", Float(-flag(civId, targetCiv, "WaryOf")) * sf(.aggressive) / 2))
        } else {
            let attacksPlanned = diplomacyOrder(civId).filter { hasFlag(civId, $0, "WaryOf") && flag(civId, $0, "WaryOf") < 0 }.count
            modifiers.append(("PlanningAttackAgainstOtherCivs", Float(-attacksPlanned) * 5 * isf(.aggressive)))
        }

        if receivesTradeResources(civId, from: targetCiv) { modifiers.append(("Receiving trade resources", -8 * sf(.commerce))) }

        // If their cities don't have any nearby cities that are also targets to us and it doesn't include their capital
        // Then there cities are likely isolated and a good target.
        let theirCapital = capital(of: targetCiv) ?? cities(of: targetCiv).first   // getCapital(firstCityIfNoCapital = true)
        if !targetCities.contains(where: { $0.id == theirCapital?.id }),
           targetCities.allSatisfy({ theirs in !neighboringCities(of: theirs).contains { n in !targetCities.contains { $0.id == n.id } } }) {
            modifiers.append(("Isolated city", 10 * sf(.aggressive)))
        }

        if target.isCityState {
            let protectors = cityStateProtectorCivs(targetCiv)
            modifiers.append(("Protectors", Float(-protectors.count) * 3 * sf(.diplomacy)))
            // The more potential friends of this CS, the more times the friend bonus is shared and the utilitarian option is to leave it alive
            modifiers.append(("Influence", -Float(influence(of: civId, with: targetCiv)) / 10 * sf(.diplomacy)))
            // The more we invested into the city state already, the less likely we're going to attack it, and vice versa
            if ally(of: targetCiv) == civId { modifiers.append(("Allied City-state", -20 * sf(.diplomacy))) }
        }

        modifiers += getWonderBasedMotivations(targetCiv)
        modifiers.append(("War with allies", getAlliedWarMotivation(civId, targetCiv)))

        // Purely for debugging, remove modifiers that don't have an effect
        modifiers.removeAll { $0.1 == 0 }
        var motivationSoFar: Float = 0
        for m in modifiers { motivationSoFar += m.1 }   // List<Float>.sum(): a Float accumulator, in list order

        if let want = ProcessInfo.processInfo.environment["MOTTRACE"], want == "\(civ.nation)>\(target.nation)" {
            let parts: [String] = modifiers.map { "\($0.0)=\($0.1)" }
            print("MOTE t=\(turn) \(civ.nation)->\(target.nation) ours=\(ourCombatStrength) theirs=\(theirCombatStrength) deficit=\(unitSupplyDeficit(civId))/\(unitSupplyDeficit(targetCiv)) sum=\(motivationSoFar) atLeast=\(atLeast) " + parts.joined(separator: " "))
        }
        if epochsDebug && turn % 50 == 0 { print("AIDBG t\(turn) \(civ.nation) -> \(target.nation) " + modifiers.map { "\($0.0)=\(Int($0.1))" }.joined(separator: " ")) }

        // Short-circuit to avoid A-star
        if motivationSoFar < atLeast { return motivationSoFar }
        motivationSoFar += getAttackPathsModifier(civId, targetCiv, targetCitiesWithOurCity)
        return motivationSoFar
    }

    /// Unciv CityStateFunctions.getProtectorCivs: the living majors protecting this city-state.
    func cityStateProtectorCivs(_ cityState: Int) -> [Civilization] {
        diplomacyOrder(cityState).compactMap { civ($0) }.filter { $0.isAlive && $0.protectedCityStates.contains(cityState) }
    }

    /// Unciv DiplomacyManager.resourcesFromTrade().any { it.amount > 0 }: across the trades in OUR copy with
    /// them, a resource we receive more of than we give.
    func receivesTradeResources(_ civId: Int, from other: Int) -> Bool {
        var net: [String: Int] = [:]
        for d in deals where d.kind == .resource && d.exists(for: civId) && ((d.from == civId && d.to == other) || (d.from == other && d.to == civId)) {
            guard let r = d.resource, rs.resources[r] != nil else { continue }
            net[r, default: 0] += d.from == civId ? -d.offerAmount : d.offerAmount
        }
        return net.values.contains { $0 > 0 }
    }

    private func calculateCombatStrengthWithProtectors(_ otherCiv: Int, _ baseForce: Float, _ civId: Int) -> Float {
        var theirCombatStrength = calculateSelfCombatStrength(otherCiv, baseForce)
        // for city-states, also consider their protectors
        if civ(otherCiv)?.isCityState == true {
            let protectors = cityStateProtectorCivs(otherCiv)
            if !protectors.isEmpty { theirCombatStrength += Float(protectors.filter { $0.id != civId }.reduce(0) { $0 + forceRanking($1.id) }) }
        }
        return theirCombatStrength
    }

    private func calculateSelfCombatStrength(_ civId: Int, _ baseForce: Float) -> Float {
        var ourCombatStrength = Float(forceRanking(civId)) + baseForce
        // CityCombatant(capital).getCityStrength(): the Int strength, no opponent, no 1-HP shortcut
        if let cap = capital(of: civId) { ourCombatStrength += Float(getCityStrength(cap)) }
        return ourCombatStrength
    }

    private func getWonderBasedMotivations(_ otherCiv: Int) -> [(String, Float)] {
        var wonderCount = 0
        var modifiers: [(String, Float)] = []
        for city in cities(of: otherCiv) {
            if case .building(let b)? = city.currentProduction, rs.buildings[b]?.uniques.contains("Triggers a Cultural Victory upon completion") == true { modifiers.append(("About to win", 15)) }
            if case .unit(let u)? = city.currentProduction, rs.units[u]?.isSpaceshipPart == true { modifiers.append(("About to win", 15)) }   // UniqueType.AddInCapital
            wonderCount += city.buildings.filter { rs.buildings[$0]?.isWonder == true }.count
        }
        // The more wonders they have, the more beneficial it is to conquer them
        if wonderCount > 0 { modifiers.append(("Owned Wonders", Float(wonderCount))) }
        return modifiers
    }

    /// If they are at war with our allies, then we should join in
    private func getAlliedWarMotivation(_ civId: Int, _ otherCiv: Int) -> Float {
        var alliedWarMotivation: Float = 0
        for third in commonKnownCivIds(civId, otherCiv) {
            if relationshipLevel(civId, third) < .friend { continue }
            if hasFlag(third, otherCiv, "Denunciation") { alliedWarMotivation += 2 }
            if civ(third)?.isAtWar(with: otherCiv) == true {
                alliedWarMotivation += hasFlag(civId, third, "DefensivePact") ? 15 : hasFlag(civId, third, "DeclarationOfFriendship") ? 5 : 2
            }
        }
        return alliedWarMotivation * Float(personality(of: civId).scaledFocus(.loyal))
    }

    private func getRelationshipModifier(_ civId: Int, _ other: Int) -> Float {
        let m: Float
        switch relationshipIgnoreAfraid(civId, other) {
        case .unforgivable: m = 10
        case .enemy: m = 5
        case .competitor: m = 2
        case .favorable: m = -2
        case .friend: m = -5
        case .ally: m = -10   // this is so that ally + DoF is not too unbalanced
        default: m = 0
        }
        return m * Float(personality(of: civId).scaledFocus(.loyal))
    }

    private func getProductionRatioModifier(_ civId: Int, _ other: Int) -> Float {
        // Unciv divides the two ranking figures straight, with no guard: a civ with no production makes the
        // ratio infinite and the first branch takes it.
        let productionRatio = Float(productionRanking(civId)) / Float(productionRanking(other))
        if productionRatio > 2 { return 10 }
        if productionRatio > 1.5 { return 5 }
        if gtD(productionRatio, 1.2) { return 3 }   // `> 1.2` is a Double literal there
        if productionRatio > 0.8 { return 0 }
        if productionRatio > 0.5 { return -5 }
        if productionRatio > 0.25 { return -10 }
        return -15
    }

    private func getScoreRatioModifier(_ other: Int, _ civId: Int) -> Float {
        let scoreRatio = Float(scoreRankingForAI(other)) / Float(scoreRankingForAI(civId))
        if scoreRatio > 2 { return 15 }
        if scoreRatio > 1.5 { return 10 }
        if scoreRatio > 1.25 { return 5 }
        if scoreRatio > 1 { return 2 }
        if scoreRatio > 0.8 { return 0 }
        if scoreRatio > 0.5 { return -2 }
        if scoreRatio > 0.25 { return -5 }
        return -10
    }

    private func getDefensivePactAlliesScore(_ other: Int, _ civId: Int, _ baseForce: Float, _ ourCombatStrength: Float) -> Float {
        var theirAlliesValue: Float = 0
        for third in diplomacyOrder(other) where hasFlag(other, third, "DefensivePact") && third != civId {
            // Deterrence comes from the ally's own force, not the target's
            let ratio = (Float(forceRanking(third)) + baseForce) / ourCombatStrength
            // Double literals there: `> 5`, `> 2.5`, `> 2`, `> 1.5`, `> .8`
            theirAlliesValue += gtD(ratio, 5) ? -15 : gtD(ratio, 2.5) ? -10 : gtD(ratio, 2) ? -8 : gtD(ratio, 1.5) ? -5 : gtD(ratio, 0.8) ? -2 : 0
        }
        return theirAlliesValue
    }

    private func getCombatStrengthModifier(_ civId: Int, _ target: Int, _ ours: Float, _ theirs: Float) -> Float {
        var ratio = ours / theirs
        // At higher difficulty levels the AI gets a unit production boost.
        if !isHuman(civId) && isHuman(target) { ratio *= Float(pow(Double(Float(difficulty.aiUnitCostModifier)), Double(Float(1.5)))); if GameState.evlogOn { hbr("A13.aiEyesHuman", target) } }
        if ratio > 5 { return 20 }
        if ratio > 4 { return 15 }
        if ratio > 3 { return 12 }
        if ratio > 2 { return 10 }
        if ratio > 1.8 { return 8 }
        if ratio > 1.6 { return 6 }
        if ratio > 1.4 { return 4 }
        if ratio > 1.2 { return 2 }
        if ratio > 0.8 { return -5 }
        if ratio > 0.6 { return -10 }
        if ratio > 0.4 { return -20 }
        return -40
    }

    /// Unciv: none of our military units would take less than 100 damage attacking the city (from the city's tile,
    /// calculateDamageToAttacker's default).
    private func hasNoUnitsThatCanAttackCityWithoutDying(_ civId: Int, _ city: City) -> Bool {
        !units(of: civId).contains { u in u.isMilitary && damageToAttacker(u, from: u.coord, target: city.coord) < 100 }
    }

    /// Unciv MotivationToAttackAutomation.getAttackPathsModifier (useAStarPathfinding is off by default, so
    /// MapPathing.getConnection: a uniform-cost search whose path holds both ends).
    private func getAttackPathsModifier(_ civId: Int, _ other: Int, _ pairs: [(City, City)]) -> Float {
        func isTileCanMoveThrough(_ c: HexCoord) -> Bool {
            guard let t = map[c], !t.isImpassable else { return false }
            guard let o = t.ownerCivId else { return true }
            return o == other || canPassThroughTiles(civId, o)
        }
        func isLandTileCanMoveThrough(_ c: HexCoord) -> Bool { (map[c]?.isLand ?? false) && isTileCanMoveThrough(c) }
        /// The number of tiles on the path, both ends included; only answers below `limit` matter to the caller.
        func connection(_ from: HexCoord, _ to: HexCoord, landOnly: Bool, limit: Int) -> Int? {
            var seen: Set<HexCoord> = [from]; var frontier = [(from, 1)]; var i = 0
            while i < frontier.count {
                let (c, n) = frontier[i]; i += 1
                if c == to { return n }
                if n >= limit { continue }
                for nb in map.neighbors(of: c) where !seen.contains(nb) && (landOnly ? isLandTileCanMoveThrough(nb) : isTileCanMoveThrough(nb)) { seen.insert(nb); frontier.append((nb, n + 1)) }
            }
            return nil
        }
        var attackPaths = 0
        var attackPathModifiers: Float = -3
        // groupBy { it.first }: in order of first appearance
        var groupOrder: [Int] = []
        var groups: [Int: [(City, City)]] = [:]
        for pair in pairs { if groups[pair.0.id] == nil { groupOrder.append(pair.0.id) }; groups[pair.0.id, default: []].append(pair) }
        for key in groupOrder {
            let group = groups[key]!
            let cityToAttackFrom = group[0].0
            var cityAttackValue: Float = 0
            for (_, cityToAttack) in group {
                if let n = connection(cityToAttackFrom.coord, cityToAttack.coord, landOnly: true, limit: 16), n < 16 { attackPaths += 1; cityAttackValue = 3; break }
                if cityAttackValue > 0 { continue }
                if let n = connection(cityToAttackFrom.coord, cityToAttack.coord, landOnly: false, limit: 16), n < 16 { attackPaths += 1; cityAttackValue += 1 }
            }
            attackPathModifiers += cityAttackValue
        }
        if attackPaths == 0 {
            // Do an expensive BFS to find any possible attack path (from getCapital(firstCityIfNoCapital = true))
            guard let cap = capital(of: civId) ?? cities(of: civId).first else { return -50 }
            var tilesOnPath: [HexCoord: Int] = [cap.coord: 1]; var queue = [cap.coord]; var qi = 0
            while qi < queue.count {
                let c = queue[qi]; qi += 1
                for nb in map.neighbors(of: c) where tilesOnPath[nb] == nil && isTileCanMoveThrough(nb) { tilesOnPath[nb] = tilesOnPath[c]! + 1; queue.append(nb) }
            }
            let reachable = cities(of: other).compactMap { tilesOnPath[$0.coord] }
            if reachable.isEmpty { return -50 }   // Can't even reach the enemy city, no point in war.
            // Longer attack paths are worse, but if the attack path is too far away we shouldn't completely discard the possibility
            attackPathModifiers -= Float(min(30, max(0, reachable.min()! - 10)))
        }
        return attackPathModifiers
    }
}
