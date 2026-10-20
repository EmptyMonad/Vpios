// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/diplomacy/DiplomacyTurnManager.kt`: what one DiplomacyManager does at the end
/// of its civ's turn. Unciv runs `civInfo.diplomacy.values.toList().forEach { it.nextTurn() }` from
/// TurnManager.endTurn, and each manager does ALL of its steps - trades, untenable trades, open borders,
/// modifiers, flags, city-state influence, smoothed opinion - before the next manager starts. Ours ran each step
/// for every partner in turn (all the trades, then all the modifiers, then all the flags), and the city-state
/// influence after all of those, so a flag expiring or an ally changing reached the next partner a step late.
extension GameState {
    /// Unciv TurnManager.endTurn: `civInfo.diplomacy.values.toList().forEach { it.nextTurn() }` - the managers in
    /// the diplomacy HashMap's order, copied first so a civ met in the loop is not visited.
    func diplomacyManagersNextTurn(_ civId: Int) {
        for other in diplomacyOrder(civId) { diplomacyManagerNextTurn(civId, other) }
    }

    /// Unciv DiplomacyTurnManager.nextTurn
    func diplomacyManagerNextTurn(_ civId: Int, _ other: Int) {
        guard civ(civId) != nil, civ(other) != nil else { return }
        nextTurnTrades(civId, other)
        removeUntenableTrades(civId, other)
        updateHasOpenBorders(civId, other)
        nextTurnDiplomaticModifiers(civId, other)
        nextTurnFlags(civId, other)
        if civ(civId)?.isCityState == true && civ(other)?.isMajor == true { nextTurnCityStateInfluence(cityState: civId, major: other) }
        if civ(civId)?.isMajor == true { saveSmoothedOpinionOfOtherCiv(civId, other) }
    }

    // MARK: - modifiers

    /// Unciv SPEED_ADJUSTMENT_NORMALIZATION_FACTOR * amount / speed.modifier, all in Float.
    private func speedAdjusted(_ amount: Float) -> Float { Float(GameState.SPEED_ADJUSTMENT_NORMALIZATION_FACTOR) * amount / Float(speed.modifier) }

    /// Unciv DiplomacyTurnManager.revertToZero (Float)
    private func revertToZero(_ civId: Int, _ other: Int, _ m: DiploModifier, _ amount: Float) {
        guard hasModifier(civId, other, m) else { return }
        let current = Float(modifier(civId, other, m))
        let adjusted = speedAdjusted(amount)
        if adjusted >= abs(current) { removeModifier(civId, other, m) }
        else if current > 0 { addModifier(civId, other, m, Double(-adjusted)) } else { addModifier(civId, other, m, Double(adjusted)) }
    }

    /// Unciv DiplomacyTurnManager.accumulateToAtMost (Float)
    private func accumulateToAtMost(_ civId: Int, _ other: Int, _ m: DiploModifier, _ amount: Float, max maxAmount: Float = .greatestFiniteMagnitude) {
        let current = Float(modifier(civId, other, m))
        if current >= maxAmount { return }
        let adjusted = speedAdjusted(amount)
        if adjusted >= maxAmount - current { setModifier(civId, other, m, Double(maxAmount)) } else { addModifier(civId, other, m, Double(adjusted)) }
    }

    /// Unciv DiplomacyTurnManager.nextTurnDiplomaticModifiers for `civId`'s manager with `other`.
    /// Unciv runs it for every diplomacy manager, a city-state's too: its modifiers are never read (its relationship
    /// is its influence), but its tail is - a city-state whose influence with a MILITARISTIC city-state reached Friend
    /// (the shared-enemy +10s of a war both joined) gets that city-state's gifted units like a major would. Ours
    /// skipped city-states here, and Rio de Janeiro never got Hanoi's Carolean.
    func nextTurnDiplomaticModifiers(_ civId: Int, _ other: Int) {
        guard let civ = civ(civId), !civ.isBarbarian, let otherCiv = self.civ(other) else { return }
        // Unciv: `diplomaticStatus == Peace` - war and a defensive pact both revert it
        if !civ.isAtWar(with: other) && !civ.defensivePacts.contains(other) { accumulateToAtMost(civId, other, .YearsOfPeace, 0.5, max: 30) }
        else { revertToZero(civId, other, .YearsOfPeace, 0.5) }   // war makes you forget the good ol' days

        var openBorders = 0
        if hasOpenBorders(civId, in: other) { openBorders += 1 }
        if hasOpenBorders(other, in: civId) { openBorders += 1 }
        if openBorders > 0 { accumulateToAtMost(civId, other, .OpenBorders, Float(openBorders) / 8) }
        else { revertToZero(civId, other, .OpenBorders, 1 / 8) }

        // Negatives
        revertToZero(civId, other, .DeclaredWarOnUs, 1 / 8)
        revertToZero(civId, other, .WarMongerer, 1 / 2)
        revertToZero(civId, other, .CapturedOurCities, 1 / 4)
        revertToZero(civId, other, .BetrayedDeclarationOfFriendship, 1 / 8)
        revertToZero(civId, other, .BetrayedDefensivePact, 1 / 16)
        revertToZero(civId, other, .RefusedToNotSettleCitiesNearUs, 1 / 4)
        revertToZero(civId, other, .RefusedToPromiseNotToAttackUs, 1 / 2)
        revertToZero(civId, other, .BulliedProtectedMinor, 1 / 2)
        revertToZero(civId, other, .AttackedProtectedMinor, 1 / 2)
        revertToZero(civId, other, .DestroyedProtectedMinor, 1 / 4)
        for d in Demand.allCases { revertToZero(civId, other, d.betrayedModifier, 1 / 8) }
        revertToZero(civId, other, .BetrayedPromiseToNotAttackOtherCiv, 1 / 8)
        revertToZero(civId, other, .UnacceptableDemands, 1 / 4)
        revertToZero(civId, other, .StealingTerritory, 1 / 4)
        revertToZero(civId, other, .DenouncedOurAllies, 1 / 4)
        revertToZero(civId, other, .DenouncedOurEnemies, 1 / 4)
        revertToZero(civId, other, .Denunciation, 1 / 8)
        revertToZero(civId, other, .SpiedOnUs, 1 / 4)
        revertToZero(civId, other, .StoleOurAlly, 1 / 2)

        // Positives
        revertToZero(civId, other, .GaveUsUnits, 1 / 4)
        revertToZero(civId, other, .LiberatedCity, 1 / 8)
        if hasModifier(civId, other, .GaveUsGifts) {
            let base: Float
            switch relationshipLevel(civId, other) {
            case .ally: base = 1; case .friend: base = 1.5; case .favorable: base = 2; case .neutral: base = 2.5
            case .competitor: base = 5; case .enemy: base = 7.5; case .unforgivable: base = 10; default: base = 2.5
            }
            let giftLoss = base * Float(rs.constants.goldGiftDegradationMultiplier)
            let amountLost = max(abs(Float(modifier(civId, other, .GaveUsGifts))) * giftLoss / 100, giftLoss / 5)
            revertToZero(civId, other, .GaveUsGifts, amountLost)
        }

        setFriendshipBasedModifier(civId, other)
        setDefensivePactBasedModifier(civId, other)
        setReligionBasedModifier(civId, other)

        if !hasFlag(civId, other, "DeclarationOfFriendship") { revertToZero(civId, other, .DeclarationOfFriendship, 1 / 2) }
        if !hasFlag(civId, other, "DefensivePact") { revertToZero(civId, other, .DefensivePact, 1) }

        guard otherCiv.isCityState else { return }
        // Unciv: the major's OWN relationship level with the city-state - its opinion for an AI, the city-state's
        // view (influence) for a human - decides the ProvideMilitaryUnit flag, here, in the major's turn. Ours kept
        // a timer on the city-state and ran it in the city-state's turn, so the gifted unit came a turn apart.
        if relationshipLevel(civId, other) < .friend {
            if hasFlag(civId, other, "ProvideMilitaryUnit") { removeFlag(civId, other, "ProvideMilitaryUnit") }
            return
        }
        // Unciv DiplomacyTurnManager: `listOf(-1, 0, 1).random(rng)` - drawn before the uniques are even looked at
        var rng = stateBasedRandom("DiplomacyManager.nextTurnDiplomaticModifiers", civId: civId, otherCivId: other)
        let variance = rng.pick([-1, 0, 1]) ?? 0
        guard let every = militaryGiftInterval(civId, from: otherCiv) else { removeFlag(civId, other, "ProvideMilitaryUnit"); return }
        // Reset the countdown if it has ended, or if we have longer to go than the current maximum (friend -> ally)
        if !hasFlag(civId, other, "ProvideMilitaryUnit") || flag(civId, other, "ProvideMilitaryUnit") > every {
            setFlag(civId, other, "ProvideMilitaryUnit", every + variance)
        }
    }

    // MARK: - flags

    /// Unciv DiplomacyTurnManager.nextTurnFlags for `civId`'s manager with `other`: every flag counts down (negative
    /// flags keep going to keep time), side effects at 50 and at 0, and a flag at 0 is removed.
    func nextTurnFlags(_ civId: Int, _ other: Int) {
        guard let ci = civIndex(civId), let flags = civs[ci].diploFlags[other], !flags.isEmpty else { return }
        for flagName in javaHashMapOrder(Array(flags.keys).sorted()) {   // Java HashMap order; inside a bucket insertion order is not tracked, so by name
            guard let i = civIndex(civId), let current = civs[i].diploFlags[other]?[flagName] else { continue }
            var v = current - 1
            civs[i].diploFlags[other]?[flagName] = v
            // Militaristic city-states grant units faster when at war with a common enemy (the barbarians count)
            if flagName == "ProvideMilitaryUnit", civs[i].isMajor, civ(other)?.isCityState == true,
               civs.contains(where: { areAtWar(civId, $0.id) && areAtWar(other, $0.id) }) {
                for u in civUniques(civId) where u.pattern == "Militaristic City-States grant units [] times as fast when you are at war with a common nation" {
                    v = v - u.int(0) + 1
                    if v <= 0 { v = 0; civs[i].diploFlags[other]?[flagName] = v; break }
                    civs[i].diploFlags[other]?[flagName] = v
                }
            }
            // At the end of every turn
            if flagName == "ResearchAgreement" { civs[i].totalOfScienceDuringRA[other, default: 0] += Int(civs[i].statsForNextTurn?.science ?? 0) }
            // These modifiers decrease slightly @ 50
            if v == 50 {
                if flagName == "RememberAttackedProtectedMinor" { addModifier(civId, other, .AttackedProtectedMinor, 5) }
                if flagName == "RememberBulliedProtectedMinor" { addModifier(civId, other, .BulliedProtectedMinor, 5) }
            }
            if v == 0 {
                switch flagName {
                case "ResearchAgreement":
                    if !hasFlag(other, civId, "ResearchAgreement") { scienceFromResearchAgreement(civId, other) }
                case "DefensivePact":
                    if let x = civIndex(civId) { civs[x].defensivePacts.remove(other) }   // Unciv: `diplomaticStatus = Peace`, this side only
                case "ProvideMilitaryUnit":
                    // Do not unset the flag - they may return soon, and we'll continue from that point on
                    if cities(of: civId).isEmpty || cities(of: other).isEmpty { continue }
                    giveMilitaryUnitToPatron(cityState: other, patron: civId)
                case "RecentlyAttacked": askForUnitGifts(cityState: civId, attacker: other)
                case "RememberDestroyedProtectedMinor": removeModifier(civId, other, .DestroyedProtectedMinor)
                case "RememberAttackedProtectedMinor": removeModifier(civId, other, .AttackedProtectedMinor)
                case "RememberBulliedProtectedMinor": removeModifier(civId, other, .BulliedProtectedMinor)
                case "RememberSidedWithProtectedMinor": removeModifier(civId, other, .SidedWithProtectedMinor)
                case "DeclarationOfFriendship":
                    if let x = civIndex(civId) { civs[x].friendships[other] = nil }   // our bookkeeping of the flag
                default:
                    for d in Demand.allCases where d.agreedToDemand == flagName { addModifier(civId, other, d.fulfilledModifier, 10) }
                }
                if let x = civIndex(civId) { civs[x].diploFlags[other]?[flagName] = nil }
            } else if flagName == "WaryOf" && v < -10 {
                // Used in DeclareWarTargetAutomation.declarePlannedWar to count the turns preparing: over 10, the plan is off
                if let x = civIndex(civId) { civs[x].diploFlags[other]?[flagName] = nil }
            }
        }
    }

    /// Unciv DiplomacyTurnManager.scienceFromResearchAgreement: both get the smaller of the two totals.
    private func scienceFromResearchAgreement(_ civId: Int, _ other: Int) {
        guard let ci = civIndex(civId), let oi = civIndex(other) else { return }
        let science = min(civs[ci].totalOfScienceDuringRA[other] ?? 0, civs[oi].totalOfScienceDuringRA[civId] ?? 0)
        civs[ci].scienceFromResearchAgreements += Double(science)
        civs[oi].scienceFromResearchAgreements += Double(science)
        civs[ci].totalOfScienceDuringRA[other] = 0
        civs[oi].totalOfScienceDuringRA[civId] = 0
    }

    /// Unciv DiplomacyManager.saveSmoothedOpinionOfOtherCiv: last turn's cached value becomes the smoothed one, and
    /// the cache moves toward the current opinion by 1/(30 × speed) - in Float. Unciv does it for every manager of a
    /// major civ, city-states included.
    func saveSmoothedOpinionOfOtherCiv(_ civId: Int, _ other: Int) {
        guard let i = civIndex(civId) else { return }
        let smoothed = Float(civs[i].cachedSmoothedOpinion[other] ?? civs[i].smoothedOpinion[other] ?? 0)
        civs[i].smoothedOpinion[other] = Double(smoothed)
        let period = 30 * Float(speed.modifier)
        civs[i].cachedSmoothedOpinion[other] = Double((Float(opinion(of: civId, toward: other)) + smoothed * (period - 1)) / period)
    }

    // MARK: - city-state influence

    /// Unciv DiplomacyTurnManager.nextTurnCityStateInfluence, in the CITY-STATE's turn, for its manager with `major`:
    /// the raw influence moves toward the resting point through setInfluence - which updates the ally on the spot -
    /// then the warnings.
    func nextTurnCityStateInfluence(cityState cs: Int, major: Int) {
        guard let ci = civIndex(cs) else { return }
        let initialRelationshipLevel = relationshipIgnoreAfraid(cs, major)   // enough, since only >= Friend is notified
        let restingPoint = cityStateRestingPoint(major, cs)
        // Not getInfluence(): during a war with this city-state's ally the -60 would overwrite the value to restore
        let influence = civs[ci].influence[major] ?? 0
        if influence > restingPoint {
            let decrement = cityStateInfluenceDegrade(major, cs)
            setInfluence(cityState: cs, major: major, Double(max(Float(restingPoint), Float(influence) - Float(decrement))))
        } else if influence < restingPoint {
            let increment = cityStateInfluenceRecovery(major, cs)
            setInfluence(cityState: cs, major: major, Double(min(Float(restingPoint), Float(influence) + Float(increment))))
        }
        guard let c = civ(cs), c.isAlive else { return }   // no relationship notices while the city-state is defeated
        var actions: [NotificationAction] = []
        if let cap = capital(of: cs) { actions.append(.location(cap.coord)) }
        actions.append(.diplomacy(c.nation))
        if turnsToRelationshipChange(major, cs) == 1 {
            notify(major, "Your relationship with [\(c.nation)] is about to degrade", category: .Diplomacy, icons: [c.nation, "Diplomacy"], actions: actions)
        }
        if initialRelationshipLevel >= .friend && initialRelationshipLevel != relationshipIgnoreAfraid(cs, major) {
            notify(major, "Your relationship with [\(c.nation)] degraded", category: .Diplomacy, icons: [c.nation, "Diplomacy"], actions: actions)
        }
        // Potentially notify about afraid status
        if self.influence(of: major, with: cs) < 30 && !hasFlag(cs, major, "NotifiedAfraid") && tributeWillingness(from: major, cs) > 0 && civ(major)?.isMajor == true {
            setFlag(cs, major, "NotifiedAfraid", 20)   // wait 20 turns until the next reminder
            notify(major, "[\(c.nation)] is afraid of your military power!", category: .Diplomacy, icons: [c.nation, "Diplomacy"], actions: actions)
        }
    }

}
