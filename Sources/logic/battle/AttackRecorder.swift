// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/battle/AttackRecorder.kt`: recording each attack and the outcome of its participants.
extension GameState {
    static let maxAttackEvents = 300

    /// AttackRecorder.init + snapshotTarget: capture the participants before the fight.
    func beginAttackEvent(attacker: Unit, target: HexCoord) -> AttackEvent {
        var ev = AttackEvent(turn: turn, sourceTile: attacker.coord, targetTile: target,
                             attacker: AttackParticipant(civId: attacker.civId, unitId: attacker.id, name: attacker.name, healthBefore: attacker.health))
        if let c = city(at: target) { ev.targets.append(AttackParticipant(civId: c.civId, unitId: nil, name: c.name, healthBefore: c.health)) }
        for d in units(at: target) where d.civId != attacker.civId { ev.targets.append(AttackParticipant(civId: d.civId, unitId: d.id, name: d.name, healthBefore: d.health)) }
        for c in civs where c.isAlive {
            if c.id == attacker.civId { ev.civIdsKnowingAttackSource.insert(c.id); ev.civIdsKnowingAttackTarget.insert(c.id); continue }
            let seen = visibleTiles(for: c.id)
            if seen.contains(attacker.coord) { ev.civIdsKnowingAttackSource.insert(c.id) }
            if seen.contains(target) { ev.civIdsKnowingAttackTarget.insert(c.id) }
        }
        return ev
    }

    /// AttackRecorder.finish: outcomes from what survived (Destroyed / Captured / Survived; Withdrew when the fight was cancelled).
    func finishAttackEvent(_ event: AttackEvent, withdrawn: Bool = false) {
        var ev = event
        let targetTile = event.targetTile
        func finish(_ p: inout AttackParticipant) {
            if let uid = p.unitId {
                if let u = unit(uid) {
                    p.healthAfter = u.health
                    p.outcome = u.civId != p.civId ? "Captured" : "Survived"
                } else { p.healthAfter = 0; p.outcome = "Destroyed" }
            } else if let c = city(at: targetTile) {
                p.healthAfter = c.health
                p.outcome = c.civId != p.civId ? "Captured" : "Survived"
            } else { p.outcome = "Destroyed" }
            p.damageReceived = max(0, p.healthBefore - p.healthAfter)
        }
        var attacker = ev.attacker; finish(&attacker); ev.attacker = attacker
        var targets = ev.targets
        for i in targets.indices { finish(&targets[i]); if withdrawn { targets[i].outcome = "Withdrew" } }
        ev.targets = targets
        ev.resolution = withdrawn ? "Withdrawn" : "Completed"
        attackEvents.append(ev)
        if attackEvents.count > GameState.maxAttackEvents { attackEvents.removeFirst(attackEvents.count - GameState.maxAttackEvents) }
    }

    /// Attacks a civilization knows about (it saw the attacker or the target).
    func attackEventsKnown(to civId: Int) -> [AttackEvent] { attackEvents.filter { $0.civIdsKnowingAttackSource.contains(civId) || $0.civIdsKnowingAttackTarget.contains(civId) } }
}
