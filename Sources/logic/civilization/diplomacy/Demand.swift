// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/diplomacy/Demand.kt`: the promises one civ asks of another.
extension GameState {
    /// `civId` asks `other` to stop. Unciv queues this as a popup alert and the receiver answers it at the start of
    /// its own turn (NextTurnAutomation.respondToPopupAlerts); a human answers it in the UI.
    func makeDemand(_ demand: Demand, from civId: Int, to other: Int) {
        // Unciv adds the demand alert without checking an earlier promise (the UI disables the button instead)
        guard let o = civ(other), civ(civId)?.isMajor == true, o.isMajor else { return }
        // (Unciv adds the alert to whoever it is for, the player under AutoPlay too: it is answered on the receiver's own
        // turn - respondToPopupAlerts, for an AI and for an automated human alike - not here.)
        guard !pendingDemands.contains(where: { $0.from == civId && $0.to == other && $0.demand == demand }) else { return }
        pendingDemands.append(DemandRequest(id: newId(), from: civId, to: other, demand: demand))
        if o.isPlayer {
            addAlert(other, demand.demandAlert, "\(civId)")
        }
    }

    /// Unciv NextTurnAutomation.respondToPopupAlerts: every demand waiting for us is answered at the start of our turn.
    func respondToDemands(_ civId: Int) {
        for request in pendingDemands.filter({ $0.to == civId }) {
            respondToDemand(request.demand, from: request.from, to: civId)
        }
    }

    /// Unciv NextTurnAutomation.respondToDemandAlert
    func respondToDemand(_ demand: Demand, from civId: Int, to other: Int) {
        if threatAssessment(other, civId) >= .high || relationshipLevel(other, civId) > .ally { agreeToDemand(demand, from: civId, by: other) }
        else { refuseDemand(demand, from: civId, by: other) }
    }

    /// `promiser` agrees to `civId`'s demand.
    func agreeToDemand(_ demand: Demand, from civId: Int, by promiser: Int) {
        pendingDemands.removeAll { $0.from == civId && $0.to == promiser && $0.demand == demand }
        setFlag(civId, promiser, demand.agreedToDemand, Int((100 * speed.modifier).rounded()))
        addModifier(promiser, civId, .UnacceptableDemands, -10)
        // Unciv fillPlaceholders keeps the brackets: "[Sweden] agreed to ..."
        notify(civId, demand.agreedText.replacingOccurrences(of: "[civName]", with: "[\(civ(promiser)?.nation ?? "?")]"), category: .Diplomacy, icons: ["Diplomacy", civ(promiser)?.nation ?? "?"])
        queueAlertIfUnique(civId, .AcceptingDemand, "\(promiser)")
    }

    func refuseDemand(_ demand: Demand, from civId: Int, by refuser: Int) {
        pendingDemands.removeAll { $0.from == civId && $0.to == refuser && $0.demand == demand }
        addModifier(refuser, civId, .UnacceptableDemands, -20)
        setFlag(civId, refuser, demand.willIgnoreViolation, Int((100 * speed.modifier).rounded()))
        notify(civId, demand.refusedText.replacingOccurrences(of: "[civName]", with: "[\(civ(refuser)?.nation ?? "?")]"), category: .Diplomacy, icons: ["Diplomacy", civ(refuser)?.nation ?? "?"])
        queueAlertIfUnique(civId, .RejectingDemand, "\(refuser)")
        if demand == .DoNotAttackUs { declareWar(refuser, on: civId) } else { addModifier(civId, refuser, demand.refusedModifier, -15) }
    }

    /// Unciv NextTurnAutomation.onDemandViolation – run every AI turn for each known major.
    func checkDemandViolations(_ civId: Int) {
        guard let civ = civ(civId), civ.isMajor else { return }
        for other in knownCivs(civId) where other.isMajor {
            for demand in Demand.allCases where hasFlag(civId, other.id, demand.violationOccurred) {
                if civ.isAtWar(with: other.id) && demand != .DoNotAttackUs { continue }
                // Unciv onDemandViolation: ihlal bayragi her dalda temizlenir, gormezden gelinen dal dahil
                if hasFlag(civId, other.id, demand.willIgnoreViolation) { removeFlag(civId, other.id, demand.violationOccurred); continue }
                if hasFlag(civId, other.id, demand.agreedToDemand) {
                    addAlert(other.id, demand.violationAlert, "\(civId)")
                    setFlag(civId, other.id, demand.willIgnoreViolation, Int((100 * speed.modifier).rounded()))
                    setModifier(civId, other.id, demand.betrayedModifier, -20)
                    if demand == .DoNotAttackUs { for third in commonKnownCivIds(civId, other.id) where self.civ(third)?.isMajor == true { setModifier(third, other.id, .BetrayedPromiseToNotAttackOtherCiv, -10) } }
                    removeFlag(civId, other.id, demand.agreedToDemand)
                } else if threatAssessment(civId, other.id) < .high || demand == .DoNotAttackUs {
                    makeDemand(demand, from: civId, to: other.id)
                }
                removeFlag(civId, other.id, demand.violationOccurred)
            }
        }
    }

    /// Unciv CityFounder.triggerCitiesSettledNearOtherCiv
    func triggerCitiesSettledNearOtherCiv(_ city: City) {
        let close = Set(cities.filter { $0.civId != city.civId && civ($0.civId)?.isMajor == true && $0.coord.distance(to: city.coord) <= 6 }.map { $0.civId })
        for other in close where civ(other)?.metCivs.contains(city.civId) == true && civ(other)?.explored.contains(city.coord) == true {
            setFlag(other, city.civId, "SettledCitiesNearUs", Int((30 * speed.modifier).rounded()))
        }
    }

    // MARK: - per turn (Unciv DiplomacyTurnManager)
}
