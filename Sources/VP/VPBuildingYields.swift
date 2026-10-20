// Vox Populi 4.22 building yield tables with no Unciv unique, for the VPiOS engine (MPL-2.0).
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// CvCity yields that depend on things Unciv uniques cannot count:
// - Building_YieldPerAlly / Building_YieldPerFriend: per City-State ally / friend (an ally is also a friend, as in VP).
// - Building_YieldChangeWorldWonderGlobal: every World Wonder of the civ yields more (counted in the wonder's city).
// - Building_YieldChangesPerReligion: x/100 per religion with followers in the city.
// - Building_YieldChangesPerPopInEmpire: x/100 per citizen of the empire.
// - Building_YieldFromYieldPercent (city) / ..Global (all cities): x% of one yield also counts as another. VP converts
//   the final yield; here it is the city's base yield (before % modifiers).
// - Building_GrowthExtraYield: when a citizen is born, x% of the city's yield is added (Production to the build).
// - Building_ClassNeededNowhere / Building_ClassNeededAnywhere: mutually exclusive buildings and civ-wide prerequisites.

import Foundation

extension GameState {
    private func vpAdd(_ s: inout Stats, _ rows: [VPData.Row], times: Double, valueKey: String = "Yield") {
        guard times != 0 else { return }
        for r in rows {
            if let stat = r.str("YieldType"), GameState.statNames.contains(stat) { s[stat] += Double(r.int(valueKey)) * times }
        }
    }

    /// The per-ally, per-wonder, per-religion and per-population yields of a city's buildings.
    func vpBuildingYields(_ city: City) -> Stats? {
        guard let d = vpData, let civ = civ(city.civId), civ.isMajor else { return nil }
        let own = city.buildings.compactMap { d.buildings[$0] }
        var s = Stats()
        let perAlly = own.flatMap { VPData.rows($0, "Building_YieldPerAlly") }
        let perFriend = own.flatMap { VPData.rows($0, "Building_YieldPerFriend") }
        if !perAlly.isEmpty || !perFriend.isEmpty {
            let cs = civs.filter { $0.isCityState && !cities(of: $0.id).isEmpty }
            vpAdd(&s, perAlly, times: Double(cs.filter { isAlly(city.civId, of: $0.id) }.count))
            vpAdd(&s, perFriend, times: Double(cs.filter { isFriend(city.civId, of: $0.id) }.count))
        }
        let wonders = city.buildings.filter { rs.buildings[$0]?.isWonder == true }.count
        if wonders > 0 {
            let global = cities(of: city.civId).flatMap { $0.buildings.compactMap { d.buildings[$0] } }
            vpAdd(&s, global.flatMap { VPData.rows($0, "Building_YieldChangeWorldWonderGlobal") }, times: Double(wonders))
        }
        let perReligion = own.flatMap { VPData.rows($0, "Building_YieldChangesPerReligion") }
        if !perReligion.isEmpty, religionEnabled {
            let n = followers(of: city).filter { $0.value > 0 && religionIsMajor($0.key) }.count
            vpAdd(&s, perReligion, times: Double(n) / 100)
        }
        let perPop = own.flatMap { VPData.rows($0, "Building_YieldChangesPerPopInEmpire") }
        if !perPop.isEmpty {
            vpAdd(&s, perPop, times: Double(cities(of: city.civId).reduce(0) { $0 + $1.population }) / 100)
        }
        return s.isEmpty ? nil : s
    }

    /// Building_YieldFromYieldPercent(+Global): part of one yield of the city counted as another.
    func vpYieldConversions(_ city: City, base: Stats) -> Stats? {
        guard let d = vpData, civ(city.civId)?.isMajor == true else { return nil }
        var rows = city.buildings.compactMap { d.buildings[$0] }.flatMap { VPData.rows($0, "Building_YieldFromYieldPercent") }
        rows += cities(of: city.civId).flatMap { $0.buildings.compactMap { d.buildings[$0] } }.flatMap { VPData.rows($0, "Building_YieldFromYieldPercentGlobal") }
        guard !rows.isEmpty else { return nil }
        var s = Stats()
        for r in rows {
            guard let out = r.str("YieldOut"), let inp = r.str("YieldIn"), GameState.statNames.contains(out), GameState.statNames.contains(inp) else { continue }
            s[out] += max(0, base[inp]) * Double(r.int("Value")) / 100
        }
        return s.isEmpty ? nil : s
    }

    /// Building_GrowthExtraYield, on a birth in the city.
    func vpGrowthExtraYield(_ city: City) -> [String: Double] {
        guard let d = vpData else { return [:] }
        let rows = city.buildings.compactMap { d.buildings[$0] }.flatMap { VPData.rows($0, "Building_GrowthExtraYield") }
        guard !rows.isEmpty else { return [:] }
        let total = currentCityStats(city.id).total
        var y: [String: Double] = [:]
        for r in rows {
            if let stat = r.str("YieldType"), GameState.statNames.contains(stat) { y[stat, default: 0] += (max(0, total[stat]) * Double(r.int("Yield")) / 100).rounded(.down) }
        }
        return y
    }

    /// VP building prerequisites with no Unciv unique, plus the corporation rules (VPCorporations.swift).
    func vpBuildingRejections(_ b: BuildingDef, civId: Int) -> [(String, String)] {
        guard let d = vpData else { return [] }
        var out = vpCorporationRejections(b, civId: civId)
        let mine = Set(cities(of: civId).flatMap { $0.buildings })
        for r in VPData.rows(d.buildings[b.name], "Building_ClassNeededNowhere") {
            if let other = r.str("BuildingClassType"), mine.contains(other) { out.append(("CanOnlyBeBuiltInSpecificCities", "Cannot be built with [\(other)]")) }
        }
        for r in VPData.rows(d.buildings[b.name], "Building_ClassNeededAnywhere") {
            if let other = r.str("BuildingClassType"), !mine.contains(other) { out.append(("CanOnlyBeBuiltInSpecificCities", "Requires a [\(other)] in any city")) }
        }
        return out
    }
}
