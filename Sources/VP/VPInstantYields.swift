// Vox Populi 4.22 instant yields for the VPiOS engine (MPL-2.0).
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// CvPlayer::doInstantYield: yields granted when something happens - a citizen is born, borders grow, a technology,
// policy or building is completed, a great person is expended, a city is conquered or founded - summed from the
// policies, the nation, the city's buildings (and every building's *Global rows) and the beliefs of the religion
// the city follows, scaled with the era where VP scales them (max(1, era index)). Food and Production go to the
// city, Gold, Science, Culture, Faith and Golden Age points to the civilization.

import Foundation

enum VPInstantEvent {
    case birth, borders, tech, policy, construction(String), gpExpended(String), conquest, founded
}

extension GameState {
    private func vpSum(_ owners: [[String: Any]], _ table: String, into y: inout [String: Double], scale: Double = 1,
                       valueKey: String = "Yield", filter: (VPData.Row) -> Bool = { _ in true }) {
        for o in owners {
            for r in VPData.rows(o, table) where filter(r) {
                guard let stat = r.str("YieldType") else { continue }
                let v = Double(r.int(valueKey))
                if v != 0 { y[stat, default: 0] += v * scale }
            }
        }
    }

    /// Fire VP's instant yields for an event. `cityId`: the city it happened in (VP's pCity); nil uses the capital.
    func vpInstantYield(_ event: VPInstantEvent, civId: Int, cityId: Int?) {
        guard vpData != nil, let civ = civ(civId), civ.isMajor else { return }   // "No minors or barbs here, please!"
        let city = cityId.flatMap { self.city($0) } ?? cities(of: civId).first(where: { $0.isCapital })
        guard let o = vpOwners(civId: civId, city: city) else { return }
        let era = Double(vpEraScale(civId))
        let isCapital = city?.isCapital ?? false
        var y: [String: Double] = [:]
        let civLevel = o.policies + (o.nation.map { [$0] } ?? [])
        let cityBuildings = o.cityBuildings
        let global = o.allBuildings
        switch event {
        case .birth:
            vpSum(civLevel, "Policy_YieldFromBirth", into: &y, scale: era)
            if isCapital { vpSum(civLevel, "Policy_YieldFromBirthCapital", into: &y, scale: era) }
            vpSum(cityBuildings, "Building_YieldFromBirth", into: &y, scale: era)
            vpSum(o.beliefs, "Belief_YieldPerBirth", into: &y, scale: era)
        case .borders:
            vpSum(civLevel, "Policy_YieldFromBorderGrowth", into: &y, scale: era)
            vpSum(cityBuildings, "Building_YieldFromBorderGrowth", into: &y, scale: era)
            vpSum(civLevel, "Trait_YieldFromTileEarn", into: &y, scale: era)
            vpSum(o.beliefs, "Belief_YieldPerBorderGrowth", into: &y, scale: era) { $0.int("IsEraScaling") != 0 }
            vpSum(o.beliefs, "Belief_YieldPerBorderGrowth", into: &y) { $0.int("IsEraScaling") == 0 }
        case .tech:
            // VP gives the civ-level part in the capital and each city's buildings their own
            vpSum(civLevel, "Policy_YieldFromTech", into: &y, scale: era)
            for c in cities(of: civId) {
                if let cb = vpOwners(civId: civId, city: c)?.cityBuildings { vpSum(cb, "Building_YieldFromTech", into: &y, scale: era) }
            }
            vpSum(o.beliefs, "Belief_YieldFromTechUnlock", into: &y, scale: era) { $0.int("IsEraScaling") != 0 }
            vpSum(o.beliefs, "Belief_YieldFromTechUnlock", into: &y) { $0.int("IsEraScaling") == 0 }
        case .policy:
            for c in cities(of: civId) {
                if let cb = vpOwners(civId: civId, city: c)?.cityBuildings { vpSum(cb, "Building_YieldFromPolicyUnlock", into: &y, scale: era) }
            }
            vpSum(o.beliefs, "Belief_YieldFromPolicyUnlock", into: &y)
        case .construction(let building):
            vpSum(civLevel, "Policy_YieldFromConstruction", into: &y, scale: era)
            vpSum(cityBuildings, "Building_YieldFromConstruction", into: &y, scale: era)
            vpSum(o.beliefs, "Belief_YieldPerConstruction", into: &y)
            if rs.buildings[building]?.isWonder == true { vpSum(civLevel, "Policy_YieldFromWorldWonderConstruction", into: &y, scale: era) }
        case .gpExpended(let unitName):
            let gp = rs.units[unitName]?.name ?? unitName
            if isCapital || city == nil {
                vpSum(civLevel, "Policy_YieldGPExpend", into: &y, scale: era)
            }
            vpSum(global, "Building_YieldFromGPExpend", into: &y, scale: era)
            vpSum(o.beliefs, "Belief_YieldFromGPUse", into: &y, scale: era)
            vpSum(o.beliefs, "Belief_GreatPersonExpendedYield", into: &y) { $0.str("GreatPersonType") == gp }
        case .conquest:
            let pop = Double(city?.population ?? 1)
            vpSum(civLevel, "Policy_ConquerorYield", into: &y, scale: era * max(1, pop / 4))   // "scaling with Era and City Population"
            vpSum(o.beliefs, "Belief_YieldFromConquest", into: &y, scale: era)
            vpSum(global, "Building_YieldFromVictoryGlobal", into: &y, scale: era)
        case .founded:
            vpSum(civLevel, "Policy_FounderYield", into: &y, scale: era)
        }
        vpGrant(y, civId: civId, cityId: city?.id)
    }

    /// Hands out VP yields: city-local ones to the city, the rest to the civilization.
    func vpGrant(_ yields: [String: Double], civId: Int, cityId: Int?) {
        guard !yields.isEmpty, let ci = civIndex(civId) else { return }
        for (stat, amount) in yields where amount != 0 {
            switch stat {
            case "Food":
                if let cid = cityId, let x = cityIndex(cid) { cities[x].foodStored += amount }
            case "Production":
                if let cid = cityId, let x = cityIndex(cid) { cities[x].productionStored += amount }
            case "Gold", "Science", "Culture", "Faith":
                applyStatGain(civId: civId, stat: stat, amount: amount)
            case "GoldenAgePoints":
                civs[ci].goldenAgePoints += amount
            default:
                break   // Tourism, Great General/Admiral points: not modelled here yet
            }
        }
        if civs[ci].isPlayer, !epochsAutoplay {
            let text = yields.filter { $0.value != 0 && ["Food", "Production", "Gold", "Science", "Culture", "Faith", "GoldenAgePoints"].contains($0.key) }
                .sorted { $0.key < $1.key }.map { "+\(Int($0.value)) [\($0.key == "GoldenAgePoints" ? "Golden Age points" : $0.key)]" }.joined(separator: ", ")
            if !text.isEmpty { notify(civId, text, category: .General, icons: ["StatIcons/Culture"]) }
        }
    }
}
