// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's unit/RoadToAutomation.kt.

extension GameState {
    /// Unciv RoadToAutomation.automateConnectRoad: the road path is found once and kept; walk to the furthest path tile
    /// reachable this turn (stopping at the first that needs a road), then repair a pillaged road or build the best road.
    func connectRoadStep(unitId: Int) {
        guard let i = unitIndex(unitId), case .connectRoad(let target) = units[i].order else { return }
        // Unciv RoadToAutomation.actualBestRoadAvailable: fixed when the civ's WorkerAutomation was made this turn
        guard let best = getWorkerAutomation(units[i].civId).actualBestRoadAvailable else { return }
        let u0 = units[i]
        func notifyRoad(_ msg: String) { notify(u0.civId, msg, category: .Units, icons: ["StatIcons/Production"], actions: [.unit(u0.coord, u0.id)]) }
        var path = units[i].roadConnectionPath
        if path.isEmpty || path.last != target {
            guard let found = roadPath(civId: u0.civId, from: u0.coord, to: target) else { stopConnectRoad(unitId); notifyRoad("Connect road failed!"); return }
            path = found; units[i].roadConnectionPath = found
        }
        if epochsDebug, epochsTraceUnit == "\(civ(u0.civId)?.nation ?? "")/\(u0.name)" {
            print("ROADSTEP t=\(uncivTurns) at=\(uncivPosition(u0.coord)) mv=\(u0.movementLeft) path=\(path.map { "\(uncivPosition($0))" }.joined(separator: " "))")
        }
        guard let idx = path.firstIndex(of: u0.coord) else { stopConnectRoad(unitId); notifyRoad("Connect road cancelled!"); return }
        if u0.hasMovement && !shouldBuildRoad(on: u0.coord, civId: u0.civId, best: best) {
            if idx == path.count - 1 { stopConnectRoad(unitId); notifyRoad("Connect road completed"); return }
            let reachable = distanceToTiles(u0)
            var next = u0.coord
            for f in path[(idx + 1)...] where reachable[f] != nil && canUnitEnter(u0, f) {
                next = f
                if shouldBuildRoad(on: f, civId: u0.civId, best: best) { break }
            }
            if next != u0.coord {
                moveUnit(unitId, toward: next)
                if let ui = unitIndex(unitId) { units[ui].order = .connectRoad(target) }   // moveUnit may have set a multi-turn moveTo
            }
        }
        guard let ui = unitIndex(unitId), units[ui].hasMovement, let t = map[units[ui].coord] else { return }
        let here = units[ui].coord
        let repair: String? = (t.roads && t.roadPillaged) ? "Repair" : nil
        let build: String? = (!shouldBuildRoad(on: here, civId: units[ui].civId, best: best) || t.improvementInProgress == best) ? nil : best
        guard let imp = repair ?? build else { return }
        // Unciv `(repairImprovement ?: buildImprovement)?.let { currentTile.startWorkingOnImprovement(it, civInfo, unit) }`:
        // a marked tile is left alone, otherwise the queue restarts with the improvement's full getTurnsToBuild -
        // Repair included, every turn the unit stands on the pillaged road, with no "already in progress" check.
        // We carried the Repair countdown over (repairTurns), so the road was repaired where Unciv's worker is
        // still starting it again at every speed but Quick.
        startWorkingOnImprovement(at: here, imp, unit: units[ui])
    }
    /// Unciv RoadToAutomation.stopAndCleanAutomation: also stops a road in progress on the current tile
    func stopConnectRoad(_ unitId: Int) {
        guard let i = unitIndex(unitId) else { return }
        units[i].order = .none
        units[i].automated = false   // `unit.automated = false; unit.action = null`
        units[i].roadConnectionPath = []
        let c = units[i].coord
        if let p = map[c]?.improvementInProgress, p == "Road" || p == "Railroad", !isMarkedForCreatesOneImprovement(c) { stopWorkingOnImprovement(at: c) }
    }
    /// Unciv RoadToAutomation.shouldBuildRoadOnTile
    func shouldBuildRoad(on c: HexCoord, civId: Int, best: String) -> Bool {
        guard let t = map[c] else { return false }
        if isMarkedForCreatesOneImprovement(c) { return false }
        if t.roads && t.roadPillaged { return true }
        let status: String? = t.railroad ? "Railroad" : t.roads ? "Road" : nil
        let hasConnection = (t.roads && !t.roadPillaged) || (forestsAreRoads(civId) && t.hasForestOrJungle && isFriendlyTerritory(c, for: civId))
        return !t.isCityCenter && !(hasConnection && best == "Road") && status != best
    }
}
