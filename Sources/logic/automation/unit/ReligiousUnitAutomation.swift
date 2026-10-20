// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's unit/ReligiousUnitAutomation.kt.

extension GameState {
    // MARK: - ReligiousUnitAutomation

    /// Unciv ReligiousUnitAutomation.automateMissionary
    func automateMissionary(_ unitId: Int) {
        guard let unit = unit(unitId), let civ = civ(unit.civId) else { return }
        guard let religion = unit.religion, religion == civ.religionName else { disband(unitId: unitId); return }
        let ourWithout = cities(of: unit.civId).filter { majorityReligion(of: $0) != religion }
        func validTarget(_ city: City) -> Bool {
            if hasFlag(unit.civId, city.civId, "AgreedToNotSpreadReligion") {
                if relationshipLevel(unit.civId, city.civId) == .ally { return false }
                if threatAssessment(unit.civId, city.civId) >= .high { return false }
            }
            return true
        }
        func rank(_ city: City) -> Int { city.coord.distance(to: unit.coord) + (hasFlag(unit.civId, city.civId, "AgreedToNotSpreadReligion") ? 10 : 0) }
        let city: City?
        if !ourWithout.isEmpty { city = ourWithout.min { $0.coord.distance(to: unit.coord) < $1.coord.distance(to: unit.coord) } }
        else {
            // Unciv `gameInfo.getCities()` is `civilizations.flatMap { it.cities }`, and minByOrNull keeps the first
            // of equal ranks, so the walk has to be civ by civ in each civ's own city order.
            city = civs.flatMap { cities(of: $0.id) }.filter { majorityReligion(of: $0) != religion && civ.metCivs.contains($0.civId) && !areAtWar(unit.civId, $0.civId) && !isProtectedByInquisitor($0, fromReligion: religion) && validTarget($0) }.min { rank($0) < rank($1) }
        }
        guard let target = city else { return }
        // Unciv `city.getTiles()` walks the city's HashSet<Vector2>, and `sortedBy { aerialDistance }` is stable: two
        // tiles at the same distance keep that walk's order (fresh turn 159: Persia's prophet took 0,2, not 1,3).
        let destination = uncivTileWalk(target).filter { canUnitEnter(unit, $0) || $0 == unit.coord }.enumerated()
            .sorted { ($0.element.distance(to: unit.coord), $0.offset) < ($1.element.distance(to: unit.coord), $1.offset) }
            .map { $0.element }.first { canReach(unit, $0) }
        guard let d = destination else { return }
        if epochsDebug, epochsTraceUnit == "\(civ.nation)/\(unit.name)" {
            print("TRACEM t=\(turn) at=\(uncivPosition(unit.coord)) target=\(target.name) maj=\(majorityReligion(of: target) ?? "-") ours=\(ourWithout.map { $0.name }) dest=\(uncivPosition(d)) fol=\(followers(of: target).sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })")
        }
        moveUnit(unitId, toward: d)
        if epochsDebug, epochsTraceUnit == "\(civ.nation)/\(unit.name)", let u = self.unit(unitId) { print("TRACEM2 t=\(turn) now=\(uncivPosition(u.coord)) mp=\(u.movementLeft) charges=\(u.charges) spread=\(target.tiles.contains(u.coord) && canSpread(u, at: target.coord))") }
        if let u = self.unit(unitId), target.tiles.contains(u.coord), canSpread(u, at: target.coord) { spreadReligion(unitId: unitId, to: target.id) }
    }
    /// Unciv ReligiousUnitAutomation.automateInquisitor
    func automateInquisitor(_ unitId: Int) {
        guard let unit = unit(unitId), let civ = civ(unit.civId) else { return }
        guard let religion = unit.religion, religion == civ.religionName else { disband(unitId: unitId); return }
        let holyCity = holyCityOfOwnReligion(civ)
        let cityToConvert = determineBestInquisitorCityToConvert(unit)
        let deficit = cityToConvert.map { pressureDeficit(of: $0, religion: religion) } ?? 0
        let toProtect = cities(of: unit.civId).filter { majorityReligion(of: $0) == religion && (!isProtectedByInquisitor($0) || map.neighbors(of: $0.coord).contains(unit.coord)) }.max { $0.population < $1.population }
        var destination: City? = nil
        if let c = cityToConvert, (c.id == holyCity?.id || deficit > 3000 /* Constants.aiPreferInquisitorOverMissionaryPressureDifference */ || (c.holyCityOf == religion && !c.isHolyCity)), unit.def.canRemoveReligions { destination = c }
        else if let p = toProtect, unit.def.preventsSpreadingReligion { destination = (holyCity != nil && !isProtectedByInquisitor(holyCity!)) ? holyCity : p }
        else if let c = cityToConvert { destination = c }
        guard let dest = destination else { return }
        // Unciv `.sortedBy { it.aerialDistanceTo(unit.currentTile) }` - stable, and the six neighbours of a
        // city tie in pairs almost always, so the neighbour order is what picks between them.
        let tile = map.neighbors(of: dest.coord).filter { canUnitEnter(unit, $0) || $0 == unit.coord }
            .enumerated().sorted { ($0.element.distance(to: unit.coord), $0.offset) < ($1.element.distance(to: unit.coord), $1.offset) }.map { $0.element }.first { canReach(unit, $0) }
        guard let t = tile else { return }
        moveUnit(unitId, toward: t)
        // Unciv: `cityToConvert != null && unit.getTile().getCity() == destinationCity` - the tile's city, whichever
        // of the destinations it is, then RemoveHeresy there
        if cityToConvert != nil, let u = self.unit(unitId), owningCity(u.coord)?.id == dest.id, canRemoveHeresy(u, at: dest.coord) { removeHeresy(unitId: unitId, cityId: dest.id) }
    }
    /// Unciv ReligionManager.getHolyCity: the first city in the game (civ by civ) that is the unblocked Holy City of our religion
    private func holyCityOfOwnReligion(_ civ: Civilization) -> City? {
        guard let r = civ.religionName else { return nil }
        return civs.flatMap { cities(of: $0.id) }.first { $0.isHolyCity && $0.holyCityOf == r }
    }
    private func determineBestInquisitorCityToConvert(_ unit: Unit) -> City? {
        guard let civ = civ(unit.civId), let religion = civ.religionName, unit.religion == religion, unit.def.canRemoveReligions else { return nil }
        if let holy = holyCityOfOwnReligion(civ), holy.civId == unit.civId, majorityReligion(of: holy) != religion { return holy }
        // Unciv: a blocked Holy City of this religion comes next
        if let blocked = cities(of: unit.civId).first(where: { $0.holyCityOf == unit.religion && !$0.isHolyCity }) { return blocked }
        let relevant = cities(of: unit.civId).filter { civ.explored.contains($0.coord) }.filter { c in let m = majorityReligion(of: c); return m != nil && m != religion }
        if let close = relevant.filter({ $0.coord.distance(to: unit.coord) <= 20 }).min(by: { pressureDeficit(of: $0, religion: religion) < pressureDeficit(of: $1, religion: religion) }) { return close }
        return relevant.min { pressureDeficit(of: $0, religion: religion) < pressureDeficit(of: $1, religion: religion) }
    }
    /// Unciv ReligiousUnitAutomation.foundReligion
    func foundReligionWith(_ unitId: Int) {
        guard let unit = unit(unitId), let civ = civ(unit.civId) else { return }
        let here = city(at: unit.coord)
        let target: City? = (here != nil && !here!.isHolyCity) ? here : cities(of: unit.civId).first { !$0.isHolyCity && canUnitEnter(unit, $0.coord) && canReach(unit, $0.coord) }
        guard let city = target else { return }
        if unit.coord != city.coord { moveUnit(unitId, toward: city.coord); return }
        // Unciv UnitActionType.FoundReligion: the prophet is spent here; the name and the beliefs are chosen after
        // all units moved (ReligionAutomation.chooseReligiousBeliefs → foundReligion)
        _ = useProphetForFoundingReligion(unitId: unitId)
    }
    func enhanceReligionWith(_ unitId: Int) {
        guard let unit = unit(unitId) else { return }
        if map[unit.coord]?.isCityCenter != true { _ = tryEnterOwnClosestCity(unitId) }
        guard let u = self.unit(unitId), map[u.coord]?.isCityCenter == true else { return }
        // Unciv UnitActionType.EnhanceReligion: the prophet is spent here; the beliefs are chosen after all units
        // moved (ReligionAutomation.chooseReligiousBeliefs → enhanceReligion) - so a unit moving later this turn does
        // not fight with a belief (Just War) that Unciv only grants once the turn's units are done.
        _ = useProphetForEnhancingReligion(unitId: u.id)
    }
}
