// Vox Populi 4.22 data tables for the VPiOS engine (MPL-2.0).
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// jsons/VPData.json (vp2unciv/vpdata.py): VP's own effect tables (Policy_*, Building_*, Belief_*, Trait_*) and the
// owners' scalar columns, keyed by the Unciv name of the owner (policy, building, belief, nation). Each VP system in
// Sources/VP reads the rows the way VP's C++ reads them. A table listed in `engineTables` has no Unciv-unique
// translation in the mod, so the engine is its only implementation.

import Foundation

struct VPData {
    typealias Row = [String: Any]
    /// owner -> table -> rows; owner -> "_" -> the owner's own columns
    let policies: [String: [String: Any]]
    let buildings: [String: [String: Any]]
    let beliefs: [String: [String: Any]]
    let nations: [String: [String: Any]]
    let engineTables: Set<String>

    nonisolated(unsafe) private static var cache: [String: VPData?] = [:]
    private static let lock = NSLock()

    static func forMods(_ mods: [String]) -> VPData? {
        let key = mods.joined(separator: "\u{1}")
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        var found: VPData? = nil
        for m in mods {
            let url = Ruleset.modsDirectory.appendingPathComponent(m).appendingPathComponent("jsons/VPData.json")
            guard let raw = try? Data(contentsOf: url), let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { continue }
            found = VPData(policies: obj["policies"] as? [String: [String: Any]] ?? [:],
                           buildings: obj["buildings"] as? [String: [String: Any]] ?? [:],
                           beliefs: obj["beliefs"] as? [String: [String: Any]] ?? [:],
                           nations: obj["nations"] as? [String: [String: Any]] ?? [:],
                           engineTables: Set(obj["engineTables"] as? [String] ?? []))
        }
        cache[key] = found
        return found
    }

    static func rows(_ owner: [String: Any]?, _ table: String) -> [Row] { owner?[table] as? [Row] ?? [] }
    static func column(_ owner: [String: Any]?, _ col: String) -> Double {
        guard let cols = owner?["_"] as? [String: Any] else { return 0 }
        if let d = cols[col] as? Double { return d }
        if let i = cols[col] as? Int { return Double(i) }
        return 0
    }
}

extension VPData.Row {
    func int(_ k: String) -> Int { (self[k] as? Int) ?? Int((self[k] as? Double) ?? 0) }
    func str(_ k: String) -> String? { self[k] as? String }
}

extension GameState {
    var vpData: VPData? { VPData.forMods(rs.mods) }

    /// The VP owners whose tables apply to a civ (its policies, its nation) and to one of its cities (that city's
    /// buildings, the beliefs of the religion it follows), and every building of the civ for the *Global tables.
    struct VPOwners {
        var policies: [[String: Any]] = []
        var nation: [String: Any]? = nil
        var cityBuildings: [[String: Any]] = []
        var allBuildings: [[String: Any]] = []
        var beliefs: [[String: Any]] = []
    }

    func vpOwners(civId: Int, city: City?) -> VPOwners? {
        guard let d = vpData, let civ = civ(civId) else { return nil }
        var o = VPOwners()
        o.policies = civ.policies.compactMap { d.policies[$0] }
        o.nation = d.nations[civ.nation]
        if let city { o.cityBuildings = city.buildings.compactMap { d.buildings[$0] } }
        o.allBuildings = cities(of: civId).flatMap { $0.buildings.compactMap { d.buildings[$0] } }
        if let city { o.beliefs = vpCityBeliefs(city).compactMap { d.beliefs[$0] } }
        else { o.beliefs = vpCivBeliefs(civId).compactMap { d.beliefs[$0] } }
        return o
    }

    /// The beliefs in effect in a city: its majority religion's (and pantheon), as VP's GetReligiousMajority.
    func vpCityBeliefs(_ city: City) -> [String] {
        guard religionEnabled, let r = majorityReligion(of: city) else { return [] }
        if let owner = religionOwner(r) { return owner.religionBeliefs + (owner.pantheonBelief.map { [$0] } ?? []) }
        if let founder = civs.first(where: { $0.pantheonBelief == r }) { return [r] + founder.religionBeliefs }
        return []
    }

    /// The beliefs of the religion a civ founded (founder and enhancer effects), or its pantheon.
    func vpCivBeliefs(_ civId: Int) -> [String] {
        guard let civ = civ(civId) else { return [] }
        return civ.religionBeliefs + (civ.pantheonBelief.map { [$0] } ?? [])
    }

    /// VP's era multiplier for "scaling with Era": max(1, era index) - Ancient and Classical x1, Medieval x2, ...
    func vpEraScale(_ civId: Int) -> Int {
        guard let civ = civ(civId) else { return 1 }
        return max(1, rs.eras.firstIndex { $0.name == civ.eraName } ?? 0)
    }
}
