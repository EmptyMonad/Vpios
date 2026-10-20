// Vox Populi 4.22 corporations for the VPiOS engine (MPL-2.0).
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// CvCorporations / CvPlayerCorporations, as far as this engine can carry them:
// - A Headquarters founds its corporation. It needs the Corporations tech (the mod's requiredTech), a Global
//   Monopoly on one of Corporation_ResourceMonopolyOrs (and all of ..Ands), and each civ may found only one
//   corporation; each corporation exists once in the world (HQs are world wonders). It grants a free Office.
// - Offices can only be built by the civ that owns the corporation's HQ.
// - Franchises spread to foreign cities. VP spreads them when a Trade Route from an Office city to a foreign city
//   completes; this engine has no international trade routes, so each Office city instead plants one in the nearest
//   foreign city in reach with a 4% chance a turn (about one per Trade Route lifetime). VP's own random spread
//   (RandomSpreadChance + CorporationRandomForeignFranchiseMod %, a random foreign city) is kept as is.
// - Franchise limit = BaseFranchises + Offices × BALANCE_CORE_CORP_OFFICE_FRANCHISE_CONVERSION + AdditionalNumFranchises,
//   then × (100 + AdditionalNumFranchisesMod)%. Building_YieldPerFranchise yields count min(franchises, limit).
// - One Franchise per city, none in a city that has an Office.
// - CorporationOfficesAsNumFranchises (Nationalization) counts Offices as Franchises, NoFranchisesInForeignCities
//   stops the spread.

import Foundation

struct VPCorporation {
    let name: String
    let hq: String
    let office: String
    let franchise: String
    let baseFranchises: Int
    let randomSpreadChance: Int
    let tradeRouteRangeMod: Int
    let monopolyOr: [String]
    let monopolyAnd: [String]

    init?(_ d: [String: Any]) {
        guard let name = d["name"] as? String, let hq = d["hq"] as? String, let office = d["office"] as? String,
              let franchise = d["franchise"] as? String else { return nil }
        self.name = name; self.hq = hq; self.office = office; self.franchise = franchise
        baseFranchises = (d["baseFranchises"] as? Int) ?? 0
        randomSpreadChance = (d["randomSpreadChance"] as? Int) ?? 0
        tradeRouteRangeMod = (d["tradeRouteRangeMod"] as? Int) ?? 0
        monopolyOr = d["monopolyOr"] as? [String] ?? []
        monopolyAnd = d["monopolyAnd"] as? [String] ?? []
    }
}

extension GameState {
    private func vpPolicyColumn(_ civId: Int, _ col: String) -> Int {
        guard let d = vpData, let civ = civ(civId) else { return 0 }
        return civ.policies.reduce(0) { $0 + Int(VPData.column(d.policies[$1], col)) }
    }

    /// The corporation a civ has founded: the one whose Headquarters stands in one of its cities.
    func vpCorporation(of civId: Int) -> VPCorporation? {
        guard let d = vpData, !d.corporations.isEmpty else { return nil }
        let mine = cities(of: civId)
        return d.corporations.first { c in mine.contains { $0.buildings.contains(c.hq) } }
    }

    /// The civ owning a corporation's Headquarters.
    func vpCorporationOwner(_ c: VPCorporation) -> Int? {
        cities.first { $0.buildings.contains(c.hq) }?.civId
    }

    func vpFranchiseCount(_ c: VPCorporation, owner: Int) -> Int {
        var n = cities.filter { $0.civId != owner && $0.buildings.contains(c.franchise) }.count
        if vpPolicyColumn(owner, "CorporationOfficesAsNumFranchises") > 0 {
            n += cities(of: owner).filter { $0.buildings.contains(c.office) }.count
        }
        return n
    }

    func vpFranchiseLimit(_ c: VPCorporation, owner: Int) -> Int {
        let offices = cities(of: owner).filter { $0.buildings.contains(c.office) }.count
        let conversion = vpNeeds?.define("BALANCE_CORE_CORP_OFFICE_FRANCHISE_CONVERSION", 0.5) ?? 0.5
        let base = c.baseFranchises + Int(Double(offices) * conversion) + vpPolicyColumn(owner, "AdditionalNumFranchises")
        return base * (100 + vpPolicyColumn(owner, "AdditionalNumFranchisesMod")) / 100
    }

    /// Construction rejections for corporation buildings ((type, message) pairs).
    func vpCorporationRejections(_ b: BuildingDef, civId: Int) -> [(String, String)] {
        guard let d = vpData, !d.corporations.isEmpty else { return [] }
        if let c = d.corporations.first(where: { $0.hq == b.name }) {
            var out: [(String, String)] = []
            if let founded = vpCorporation(of: civId), founded.hq != c.hq {
                out.append(("CanOnlyBeBuiltInSpecificCities", "Already founded [\(founded.name)]"))
            }
            let mono = vpMonopolies()[civId]?.global ?? []
            let orOK = c.monopolyOr.isEmpty || c.monopolyOr.contains { mono.contains($0) }
            let andOK = c.monopolyAnd.allSatisfy { mono.contains($0) }
            if !orOK || !andOK {
                let need = c.monopolyOr.isEmpty ? c.monopolyAnd : c.monopolyOr
                out.append(("CanOnlyBeBuiltInSpecificCities", "Requires a Global Monopoly on one of: " + need.joined(separator: ", ")))
            }
            return out
        }
        if let c = d.corporations.first(where: { $0.office == b.name }), vpCorporationOwner(c) != civId {
            return [("CanOnlyBeBuiltInSpecificCities", "Requires [\(c.hq)]")]
        }
        return []
    }

    /// Building_YieldPerFranchise of the city's Offices: per franchise of their corporation, up to its limit.
    func vpFranchiseYields(_ city: City) -> Stats? {
        guard let d = vpData, !d.corporations.isEmpty else { return nil }
        var s = Stats()
        for c in d.corporations where city.buildings.contains(c.office) {
            guard vpCorporationOwner(c) == city.civId else { continue }
            let n = min(vpFranchiseCount(c, owner: city.civId), vpFranchiseLimit(c, owner: city.civId))
            guard n > 0 else { continue }
            for row in VPData.rows(d.buildings[c.office], "Building_YieldPerFranchise") {
                if let stat = row.str("YieldType"), GameState.statNames.contains(stat) { s[stat] += Double(row.int("Yield") * n) }
            }
        }
        return s.isEmpty ? nil : s
    }

    private func vpCanHostFranchise(_ city: City, _ c: VPCorporation, owner: Int, corps: [VPCorporation]) -> Bool {
        guard city.civId != owner, let host = civ(city.civId), !host.isBarbarian, !vpLeagueBlocksFranchise(in: city) else { return false }
        return !corps.contains { city.buildings.contains($0.franchise) || city.buildings.contains($0.office) }
    }

    /// Once a round: every founded corporation may plant franchises (see the header).
    func vpSpreadFranchises() {
        guard let d = vpData, !d.corporations.isEmpty else { return }
        for c in d.corporations {
            guard let owner = vpCorporationOwner(c), civ(owner)?.isMajor == true,
                  vpPolicyColumn(owner, "NoFranchisesInForeignCities") == 0 else { continue }
            var placed = vpFranchiseCount(c, owner: owner)
            let limit = vpFranchiseLimit(c, owner: owner)
            guard placed < limit else { continue }
            var rng = stateBasedRandom("VP.franchise.\(c.name)", civId: owner, seed: Int32(truncatingIfNeeded: turn))
            // Office cities: the nearest foreign city in reach (VP's base trade route range, 10 tiles, + the corporation's range %)
            let range = 10 * (100 + c.tradeRouteRangeMod) / 100
            for office in cities(of: owner) where office.buildings.contains(c.office) && placed < limit {
                guard rng.nextInt(below: 100) < 4 else { continue }
                let target = cities.filter { vpCanHostFranchise($0, c, owner: owner, corps: d.corporations) && $0.coord.distance(to: office.coord) <= range }
                    .min { ($0.coord.distance(to: office.coord), $0.id) < ($1.coord.distance(to: office.coord), $1.id) }
                if let t = target { vpPlantFranchise(c, owner: owner, in: t.id); placed += 1 }
            }
            // VP's random spread to a random foreign city
            let chance = c.randomSpreadChance + vpPolicyColumn(owner, "CorporationRandomForeignFranchiseMod")
            if placed < limit, rng.nextInt(below: 100) < chance {
                let hosts = cities.filter { vpCanHostFranchise($0, c, owner: owner, corps: d.corporations) }.sorted { $0.id < $1.id }
                if let t = rng.randomElement(hosts) { vpPlantFranchise(c, owner: owner, in: t.id) }
            }
        }
    }

    private func vpPlantFranchise(_ c: VPCorporation, owner: Int, in cityId: Int) {
        guard let ci = cityIndex(cityId) else { return }
        addBuilding(cityIndex: ci, c.franchise, tryAddFreeBuildings: false)
        let host = cities[ci].civId, cityName = cities[ci].name
        if civ(owner)?.isPlayer == true, !epochsAutoplay {
            notify(owner, "[\(c.franchise)] opened in [\(cityName)]", category: .General, icons: ["BuildingIcons/\(c.office)"])
        }
        if civ(host)?.isPlayer == true, !epochsAutoplay {
            notify(host, "A [\(c.franchise)] opened in [\(cityName)]", category: .General, icons: ["BuildingIcons/\(c.office)"])
        }
    }
}
