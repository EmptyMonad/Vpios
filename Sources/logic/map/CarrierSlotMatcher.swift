// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv CarrierSlotMatcher: a carrier's "Can carry [n] [filter] units" (plus "[n] extra") rules form typed slots; a unit may board only
/// when a maximum bipartite matching of carried units to slots still leaves a slot it fits into.
struct CarrierSlotRule: Hashable { let filter: String; let capacity: Int }

extension GameState {
    func carrierSlotRules(_ carrier: Unit) -> [CarrierSlotRule] {
        var rules: [CarrierSlotRule] = []
        // Unciv checkCarryCapacity.getSlotsFor → forEachMatchingUnique(type) over tempUniquesMap in cache.state: the
        // unit's own uniques, its type's, its promotions' and statuses' - each once (promotionUniques already holds
        // the unit's and its type's; adding them again gave a G&K Carrier 4 Aircraft slots instead of 2) - whose
        // conditionals hold for the carrier.
        // Unciv checkCarryCapacity: once CarryAirUnits, sonra CarryExtraAirUnits - slot sirasi eslesmeyi belirler
        for u in unitMatchingUniques(carrier, "Can carry [] [] units") { rules.append(CarrierSlotRule(filter: u.param(1), capacity: u.int(0))) }
        for u in unitMatchingUniques(carrier, "Can carry [] extra [] units") { rules.append(CarrierSlotRule(filter: u.param(1), capacity: u.int(0))) }
        return rules.filter { $0.capacity > 0 }
    }

    /// Slots left for `newUnit` on `carrier` (negative when the carrier is already over-allocated) — CarrierSlotMatcher.availableCapacity.
    /// `carried`, when given, is the carriedUnits list exactly as the caller's Unciv code builds it.
    func carrierAvailableCapacity(_ carrier: Unit, for newUnit: Unit, carried: [Unit]? = nil) -> Int {
        let rules = carrierSlotRules(carrier)
        if rules.isEmpty { return 0 }
        var slots: [String] = []
        for r in rules { for _ in 0..<r.capacity { slots.append(r.filter) } }
        var all = [newUnit]
        all += carried ?? units(at: carrier.coord).filter { $0.id != newUnit.id && $0.id != carrier.id && $0.civId == carrier.civId && $0.def.isAir && $0.isTransported }
        switch maxBipartiteMatching(slots: slots, units: all) {
        case .failure(let over): return -over
        case .success(let allocations):
            let unassigned = slots.indices.filter { !allocations.contains($0) }
            return unassigned.filter { unitMatches(newUnit, slots[$0]) }.count + 1
        }
    }

    private enum MatchResult { case success(Set<Int>); case failure(Int) }

    private func maxBipartiteMatching(slots: [String], units list: [Unit]) -> MatchResult {
        var unitToSlot: [Int: Int] = [:]
        var slotUsed = [Bool](repeating: false, count: slots.count)
        func countOverAllocation() -> Int {
            guard let first = unitToSlot[0] else { return 0 }
            let slot = slots[first]
            return list.indices.filter { unitToSlot[$0] == nil }.filter { unitMatches(list[$0], slot) }.count - 1
        }
        func augment(_ unitIdx: Int, _ visited: inout [Bool]) -> Bool {
            let u = list[unitIdx]
            for slotIdx in slots.indices {
                if visited[slotIdx] || !unitMatches(u, slots[slotIdx]) { continue }
                visited[slotIdx] = true
                if !slotUsed[slotIdx] { unitToSlot[unitIdx] = slotIdx; slotUsed[slotIdx] = true; return true }
                if let occupant = unitToSlot.first(where: { $0.value == slotIdx })?.key, augment(occupant, &visited) { unitToSlot[unitIdx] = slotIdx; return true }
            }
            return false
        }
        for unitIdx in list.indices {
            var visited = [Bool](repeating: false, count: slots.count)
            if !augment(unitIdx, &visited) { return .failure(countOverAllocation()) }
        }
        return .success(Set(unitToSlot.values))
    }
}
