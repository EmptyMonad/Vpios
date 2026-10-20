// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's civilization/DeclareWarPlanEvaluator.kt, in Float as there: the forces are Ints, and every
// `Int op Float` there is a Float operation.

extension GameState {
    /// Unciv `civToJoin.getStatForRanking(Force) - 0.8f * civToJoin.getCivsAtWarWith().sumOf { Force }`, at least 100.
    private func forceLessWarsAtLeast100(_ civId: Int) -> Float {
        max(Float(forceRanking(civId)) - 0.8 * Float(combinedForceOfWarringCivsAI(civId)), 100)
    }

    /// How much motivation `civId` has to do a team war with `teamCiv` against `target`.
    /// This style of declaring war favors fighting stronger civilizations.
    func evaluateTeamWarPlan(_ civId: Int, target: Int, teamCiv: Int, given: Float?) -> Float {
        if personality(of: civId).declareWar == 0 { return -1000 }
        if relationshipLevel(civId, teamCiv) < .neutral { return -1000 }
        var motivation = given ?? motivationToAttack(civId, target, atLeast: 0)
        if relationshipLevel(civId, teamCiv) == .neutral { motivation -= 5 }
        // Make sure that they can actually help us with the target
        if !neighboringCivilizations(teamCiv).contains(target) { motivation -= 40 }

        let civForce = forceRanking(civId)
        let targetForce = forceRanking(target)
        let teamCivForce = forceLessWarsAtLeast100(teamCiv)

        // A higher motivation means that we can be riskier
        let multiplier: Float = motivation < 5 ? 1.2 : motivation < 10 ? 1.1 : motivation < 20 ? 1 : 0.8
        if Float(civForce) + teamCivForce < Float(targetForce) * multiplier {
            // We are weaker then them even with our combined forces
            motivation -= 30 * ((Float(targetForce) * multiplier) / (teamCivForce + Float(civForce)) - 1)
        } else if Float(civForce) + teamCivForce > Float(targetForce * 2) {
            // Why gang up on such a weaker enemy when we can declare war ourselves?
            motivation -= 20 * ((Float(civForce) + teamCivForce) / Float(targetForce) - 1)
        }

        let civScore = scoreRankingForAI(civId)
        let teamCivScore = scoreRankingForAI(teamCiv)
        let targetCivScore = scoreRankingForAI(target)
        if Float(teamCivScore) > Float(civScore) * 1.4 && teamCivScore >= targetCivScore {
            // If teamCiv has more score than us and the target they are likely in a good position already
            motivation -= 20 * ((Float(teamCivScore) / (Float(civScore) * 1.4)) - 1)
        }
        return motivation - 20
    }

    /// How much motivation `civId` has to join `civToJoin` in their war against `target`. Favors protecting allies.
    func evaluateJoinWarPlan(_ civId: Int, target: Int, civToJoin: Int, given: Float?) -> Float {
        if personality(of: civId).declareWar == 0 { return -1000 }
        if relationshipLevel(civId, civToJoin) <= .favorable { return -1000 }
        var motivation = given ?? motivationToAttack(civId, target, atLeast: 0)
        // We need to be able to trust the thirdCiv at least somewhat
        let opinion = Float(self.opinion(of: civId, toward: civToJoin))
        if !(civ(civId)?.defensivePacts.contains(civToJoin) ?? false) && opinion + motivation * 2 < 80 {   // diplomaticStatus != DefensivePact
            motivation -= 80 - (opinion + motivation * 2)
        }
        if !neighboringCivilizations(civToJoin).contains(target) { motivation -= 20 }

        let targetForce = forceLessWarsAtLeast100(target)
        let civForce = Float(forceRanking(civId))
        // They need to be at least half the targets size, and we need to be stronger than the target together
        let civToJoinForce = forceLessWarsAtLeast100(civToJoin)
        if civToJoinForce < targetForce / 2 {
            // Make sure that there is no wrap around
            motivation -= 10 * min(max(targetForce / civToJoinForce, -1000), 1000)
        }
        // A higher motivation means that we can be riskier
        let multiplier: Float = motivation < 10 ? 1.4 : motivation < 15 ? 1.3 : motivation < 20 ? 1.2 : motivation < 25 ? 1 : 0.8
        if civToJoinForce + civForce < targetForce * multiplier {
            motivation -= min(max(20 * (targetForce * multiplier) / (civToJoinForce + civForce), -1000), 1000)
        }
        return motivation - 15
    }

    /// How much motivation `civId` has for `civToJoin` to join them in their war against `target`.
    /// If it is >= 0 then we can accept their war offer.
    func evaluateJoinOurWarPlan(_ civId: Int, target: Int, civToJoin: Int, given: Float?) -> Float {
        if relationshipLevel(civId, civToJoin) < .favorable { return -1000 }
        var motivation = given ?? 0
        if !neighboringCivilizations(civToJoin).contains(target) { motivation -= 50 }

        let targetForce = forceRanking(target)
        let civForce = forceRanking(civId)
        // If we have more force than all enemies and overpower this enemy then we don't need help (Int arithmetic)
        if civForce - combinedForceOfWarringCivsAI(civId) > targetForce * 2 { return 0 }

        // They should to be at least half the targets size
        let thirdCivForce = forceLessWarsAtLeast100(civToJoin)
        motivation += min(20 * (1 - thirdCivForce / Float(targetForce)), 40)
        // If we have less relative force then the target then we have more motivation to accept
        motivation += 20 * min(max(1 - Float(civForce) / Float(targetForce), -40), 40)
        return motivation - 20
    }

    /// How much motivation `civId` has to declare war against `target` this turn - a prepared war or a surprise war.
    func evaluateDeclareWarPlan(_ civId: Int, target: Int, given: Float?) -> Float {
        if personality(of: civId).declareWar == 0 { return -1000 }
        let motivation = given ?? motivationToAttack(civId, target, atLeast: 0)
        if hasFlag(civId, target, "WaryOf") && flag(civId, target, "WaryOf") < 0 {
            let turnsToPlan = max(10 - (motivation / 10), 3)
            let turnsToWait = turnsToPlan + Float(flag(civId, target, "WaryOf"))
            return motivation - turnsToWait * 3
        }
        return motivation - 40
    }

    /// How much motivation `civId` has to start preparing for a war against `target`.
    func evaluateStartPreparingWarPlan(_ civId: Int, target: Int, given: Float?) -> Float {
        let motivation = given ?? motivationToAttack(civId, target, atLeast: 0)
        // Negative values in WaryOf mean a planned war, so that no extra field goes into the save
        if hasFlag(civId, target, "WaryOf") { return 0 }
        return motivation - 15
    }
}
