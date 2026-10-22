// Vox Populi 4.22 international and internal trade routes for the VPiOS engine (MPL-2.0).
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// CvGameTrade / CvPlayerTrade, without the units walking the map:
// - A Caravan (land) or Cargo Ship (sea) in one of your cities is spent to open a route from that city; the route
//   runs for VP's target length (TRADE_ROUTE_BASE_TARGET_TURNS 30, scaled with the game speed and TRTurnMod), then
//   the trade unit comes back in the origin city. War between the two civs, or losing either city, ends it early.
// - Routes possible (GetNumTradeRoutesPossible): techs' InternationalTradeRoutesChange, policies' FreeTradeRoute,
//   buildings' NumTradeRouteBonus, the founded corporation's NumFreeTradeRoutes.
// - Range (GetTradeRouteRange): land 10, sea 20, + Technology_TradeRouteDomainExtraRange, × (100 + the origin city's
//   and the civ's distance modifiers + the corporation's)%. Distance is the straight hex distance; a land route needs
//   both cities on the same landmass, a sea route both cities on the coast.
// - Yields per turn (GetTradeConnectionValueTimes100), international, for the origin city:
//   Gold: 80 × (era + 2) + 1/80 of both cities' Gold + building and policy bonuses + City-State friend/ally gold,
//   × (100 - distance modifier + sea 25 + river 25 + policy and corporation modifiers)%, at least 1.
//   Science / Culture: sqrt(techs / policies the partner has and we lack) × 200 / 125, at least 1, × our era
//   (an allied City-State counts 1). The partner's city gets the same for what we know and it does not, plus the
//   buildings' TradeRouteRecipientBonus / TradeRouteTargetBonus gold.
//   Internal (Granary: Food; Workshop, Stone Works...: Production), for the destination city: 6, + 1 per 3 citizens
//   the origin has more, × (100 + techs known / 2)%, + Building_YieldFromInternalTR, × the same modifiers and
//   InternalTradeRouteYieldModifier.
// - Distance modifier (GetTradeConnectionDistanceValueModifierTimes100): 100 - length × 100 / range, 0 to 50.
// - A completed international route from a city with a corporation's Office plants a Franchise at its destination.

import Foundation

struct VPTradeRoute: Codable, Equatable {
    var id: Int
    var originCity: Int
    var destCity: Int
    var originCiv: Int
    var destCiv: Int
    var sea: Bool
    /// "international", "food" or "production"
    var kind: String
    var turnsLeft: Int
    var totalTurns: Int
    var unit: String
}

extension GameState {
    static let vpLandTradeUnits = ["Caravan"], vpSeaTradeUnits = ["Cargo Ship"]

    var vpTradeEnabled: Bool { vpData != nil }

    func vpIsTradeUnit(_ name: String) -> Bool {
        guard let d = rs.units[name] else { return false }
        let base = d.replaces ?? name
        return GameState.vpLandTradeUnits.contains(base) || GameState.vpSeaTradeUnits.contains(base)
    }
    func vpIsSeaTradeUnit(_ name: String) -> Bool { GameState.vpSeaTradeUnits.contains(rs.units[name]?.replaces ?? name) }

    private func vpCols(_ owners: [[String: Any]], _ col: String) -> Int { owners.reduce(0) { $0 + Int(VPData.column($1, col)) } }

    func vpTradeRoutesPossible(_ civId: Int) -> Int {
        guard let d = vpData, let civ = civ(civId) else { return 0 }
        var n = civ.techs.reduce(0) { $0 + Int(VPData.column(d.techs[$1], "InternationalTradeRoutesChange")) }
        n += vpCols(civ.policies.compactMap { d.policies[$0] }, "FreeTradeRoute")
        n += vpCols(cities(of: civId).flatMap { $0.buildings.compactMap { d.buildings[$0] } }, "NumTradeRouteBonus")
        if let corp = vpCorporation(of: civId) { n += corp.numFreeTradeRoutes }
        let perCities = Int(VPData.column(d.nations[civ.nation], "TradeRoutesPerXOwnedCities"))
        if perCities > 0 { n += cities(of: civId).count / perCities }
        return n
    }

    func vpTradeRoutes(of civId: Int) -> [VPTradeRoute] { vpTradeRoutes.filter { $0.originCiv == civId } }

    func vpTradeRange(_ origin: City, sea: Bool) -> Int {
        guard let d = vpData, let civ = civ(origin.civId) else { return 0 }
        var range = sea ? 20 : 10
        let domain = sea ? "Water" : "Land"
        for t in civ.techs { for r in VPData.rows(d.techs[t], "Technology_TradeRouteDomainExtraRange") where r.str("DomainType") == domain { range += r.int("Range") } }
        let col = sea ? "TradeRouteSeaDistanceModifier" : "TradeRouteLandDistanceModifier"
        var mod = vpCols(origin.buildings.compactMap { d.buildings[$0] }, col) + vpCols(civ.policies.compactMap { d.policies[$0] }, col)
        if let corp = vpCorporation(of: origin.civId) { mod += sea ? corp.seaRangeMod : corp.landRangeMod }
        return range * (100 + mod) / 100
    }

    private func vpIsRiverCity(_ c: City) -> Bool {
        map.tilesWithin(c.coord, radius: 1).contains { $0 != c.coord && map.hasRiver(between: c.coord, $0) }
    }

    /// Whether a route of this kind can run from `origin` to `dest` (ignoring the number of routes).
    func vpCanTrade(from origin: City, to dest: City, sea: Bool, kind: String) -> Bool {
        guard origin.id != dest.id, let oc = civ(origin.civId), let dc = civ(dest.civId), !dc.isBarbarian else { return false }
        if vpTradeRoutes.contains(where: { $0.originCity == origin.id && $0.destCity == dest.id }) { return false }
        if kind == "international" {
            guard oc.id != dc.id, oc.metCivs.contains(dc.id), !oc.isAtWar(with: dc.id) else { return false }
            if dc.isCityState && vpIsActive(.cityStateSanctions) { return false }
        } else {
            guard oc.id == dc.id else { return false }
            if kind == "food" && !origin.buildings.contains("Granary") { return false }
            if kind == "production" {
                let d = vpData
                let allows = origin.buildings.contains("Workshop") || origin.buildings.contains { VPData.column(d?.buildings[$0], "AllowsProductionTradeRoutes") != 0 }
                if !allows { return false }
            }
        }
        let dist = origin.coord.distance(to: dest.coord)
        guard dist <= vpTradeRange(origin, sea: sea) else { return false }
        if sea { return map.isAdjacentToCoast(origin.coord) && map.isAdjacentToCoast(dest.coord) }
        return map[origin.coord]?.continent == map[dest.coord]?.continent
    }

    /// Yields per turn of a route: (origin city, destination city)
    func vpTradeYields(from origin: City, to dest: City, sea: Bool, kind: String) -> (Stats, Stats) {
        guard let d = vpData, let oc = civ(origin.civId), let dc = civ(dest.civId) else { return (Stats(), Stats()) }
        let range = max(1, vpTradeRange(origin, sea: sea))
        let distMod = kind == "international" ? max(0, min(50, 100 - origin.coord.distance(to: dest.coord) * 100 / range)) : 0
        let domainMod = sea ? 25 : 0
        let pol = oc.policies.compactMap { d.policies[$0] }
        let obld = origin.buildings.compactMap { d.buildings[$0] }
        func eraIndex(_ c: Civilization) -> Int { rs.eras.firstIndex { $0.name == c.eraName } ?? 0 }
        var o = Stats(), t = Stats()
        if kind == "international" {
            // Gold for the origin (×100 as VP)
            var g = Double(80 * (eraIndex(oc) + 2))   // INTERNATIONAL_TRADE_BASE 80 × (era + 2), in hundredths
            g += currentCityStats(origin.id).total.gold * 100 / 80 + currentCityStats(dest.id).total.gold * 100 / 80
            g += Double(vpCols(obld, sea ? "TradeRouteSeaGoldBonus" : "TradeRouteLandGoldBonus"))
            g += Double(vpCols(pol, sea ? "SeaTradeRouteGoldChange" : "LandTradeRouteGoldChange"))
            g += Double(vpCols(dest.buildings.compactMap { d.buildings[$0] }, "TradeRouteTargetBonus") * 100)
            if dc.isCityState { g += Double(isAlly(oc.id, of: dc.id) ? 200 : isFriend(oc.id, of: dc.id) ? 100 : 0) }
            var mod = 100 - distMod + domainMod + (!sea && vpIsRiverCity(origin) ? 25 : 0) + vpCols(pol, "TradeRouteYieldModifier")
            if origin.isCapital { mod += vpCols(pol, "TradeRouteYieldModifierCapital") }
            let corp = vpCorporation(of: oc.id)
            if let corp, dest.buildings.contains(corp.franchise), origin.buildings.contains(corp.office) { mod += corp.tradeRouteMod["Gold"] ?? 0 }
            o.gold = max(100, g * Double(mod) / 100).rounded(.down) / 100
            // Science and Culture from what the partner knows that we do not
            func diff(_ mine: Int, _ theirs: Int, ally: Bool, scale: Int) -> Double {
                let delta = dc.isCityState ? (ally ? 1 : 0) : theirs - mine
                guard delta > 0 else { return 0 }
                return Double(max(1, Int((Double(delta).squareRoot() * 200 / 125))) * max(1, scale))
            }
            let ally = dc.isCityState && isAlly(oc.id, of: dc.id)
            o.science = diff(oc.techs.count, dc.techs.count, ally: ally, scale: eraIndex(oc))
            o.culture = diff(oc.policies.count, dc.policies.count, ally: ally, scale: eraIndex(oc))
            if let corp, dest.buildings.contains(corp.franchise), origin.buildings.contains(corp.office) {
                if let m = corp.tradeRouteMod["Science"] { o.science = (o.science * Double(100 + m) / 100).rounded(.down) }
            }
            // the partner city
            if !dc.isCityState {
                t.science = oc.techs.count > dc.techs.count ? Double(max(1, Int(Double(oc.techs.count - dc.techs.count).squareRoot() * 200 / 125))) : 0
                t.culture = oc.policies.count > dc.policies.count ? Double(max(1, Int(Double(oc.policies.count - dc.policies.count).squareRoot() * 200 / 125))) : 0
                t.gold = Double(vpCols(dest.buildings.compactMap { d.buildings[$0] }, "TradeRouteRecipientBonus"))
            }
        } else {
            var v = 600.0
            if origin.population > dest.population { v += Double(max(100, (origin.population - dest.population) / 3 * 100)) }
            v *= Double(100 + oc.techs.count * 100 / max(1, rs.techs.count) / 2) / 100
            let stat = kind == "food" ? "Food" : "Production"
            for b in obld { for r in VPData.rows(b, "Building_YieldFromInternalTR") where r.str("YieldType") == stat { v += Double(r.int("Yield")) * 100 } }
            var mod = 100 + domainMod + vpCols(pol, "InternalTradeRouteYieldModifier")
            if origin.isCapital { mod += vpCols(pol, "InternalTradeRouteYieldModifierCapital") }
            t[stat] = (v * Double(mod) / 100 / 100).rounded(.down)
        }
        return (o, t)
    }

    /// Every route the civ could open now from `origin` with a trade unit of this domain, best first.
    func vpTradeOptions(from origin: City, sea: Bool) -> [(dest: City, kind: String, origin: Stats, dest: Stats)] {
        var out: [(City, String, Stats, Stats)] = []
        for dest in cities {
            for kind in ["international", "food", "production"] where vpCanTrade(from: origin, to: dest, sea: sea, kind: kind) {
                let (a, b) = vpTradeYields(from: origin, to: dest, sea: sea, kind: kind)
                out.append((dest, kind, a, b))
            }
        }
        func value(_ x: (City, String, Stats, Stats)) -> Double {
            x.1 == "international" ? x.2.gold + 2 * x.2.science + 2 * x.2.culture : 1.5 * (x.3.food + x.3.production)
        }
        return out.sorted { a, b in value(a) != value(b) ? value(a) > value(b) : a.0.id < b.0.id }.map { (dest: $0.0, kind: $0.1, origin: $0.2, dest: $0.3) }
    }

    func vpTradeTurns(_ origin: City) -> Int {
        guard let d = vpData else { return 30 }
        var turns = Double(30) * speed.modifier
        let mod = vpCols(cities(of: origin.civId).flatMap { $0.buildings.compactMap { d.buildings[$0] } }, "TRTurnModGlobal")
            + vpCols(origin.buildings.compactMap { d.buildings[$0] }, "TRTurnModLocal")
        turns += turns * Double(mod) / 100
        return max(1, Int(turns))
    }

    /// The trade unit (by id) opens a route from the city it stands in.
    @discardableResult
    func vpEstablishTradeRoute(unitId: Int, to destId: Int, kind: String, from originId: Int? = nil) -> Bool {
        guard let u = units.first(where: { $0.id == unitId }), vpIsTradeUnit(u.name),
              let origin = originId.flatMap({ city($0) }).flatMap({ $0.civId == u.civId ? $0 : nil }) ?? cities.first(where: { $0.coord == u.coord && $0.civId == u.civId }),
              let dest = city(destId),
              vpTradeRoutes(of: u.civId).count < vpTradeRoutesPossible(u.civId) else { return false }
        let sea = vpIsSeaTradeUnit(u.name)
        guard vpCanTrade(from: origin, to: dest, sea: sea, kind: kind) else { return false }
        let turns = vpTradeTurns(origin)
        vpTradeRoutes.append(VPTradeRoute(id: (vpTradeRoutes.map { $0.id }.max() ?? 0) + 1, originCity: origin.id, destCity: dest.id,
                                          originCiv: u.civId, destCiv: dest.civId, sea: sea, kind: kind, turnsLeft: turns, totalTurns: turns, unit: u.name))
        removeUnit(unitId)
        return true
    }

    /// Base yields a city gets from the routes it starts or receives (CityStats base list).
    func vpTradeCityYields(_ city: City) -> Stats? {
        guard vpTradeEnabled, !vpTradeRoutes.isEmpty else { return nil }
        var s = Stats()
        for r in vpTradeRoutes where r.originCity == city.id || r.destCity == city.id {
            guard let o = self.city(r.originCity), let d = self.city(r.destCity) else { continue }
            let (a, b) = vpTradeYields(from: o, to: d, sea: r.sea, kind: r.kind)
            if r.originCity == city.id { s += a }
            if r.destCity == city.id { s += b }
        }
        return s.isEmpty ? nil : s
    }

    /// Once a round: routes count down, end, and the AI opens new ones.
    func vpTradeTurn() {
        guard vpTradeEnabled else { return }
        var keep: [VPTradeRoute] = []
        for var r in vpTradeRoutes {
            let o = city(r.originCity), d = city(r.destCity)
            let broken = o == nil || d == nil || o?.civId != r.originCiv || (r.kind == "international" && civ(r.originCiv)?.isAtWar(with: d?.civId ?? -1) == true)
            r.turnsLeft -= 1
            if broken || r.turnsLeft <= 0 {
                if !broken, let o, let d { vpTradeRouteCompleted(r, origin: o, dest: d) }
                if let o, o.civId == r.originCiv { _ = spawnUnit(r.unit, civId: r.originCiv, at: o.coord) }
                if civ(r.originCiv)?.isPlayer == true, !epochsAutoplay {
                    notify(r.originCiv, broken ? "A trade route from [\(o?.name ?? "?")] was cut." : "The trade route from [\(o?.name ?? "?")] to [\(d?.name ?? "?")] has ended. The [\(r.unit)] is back.",
                           category: .General, icons: ["UnitIcons/\(r.unit)"], coord: o?.coord)
                }
                continue
            }
            keep.append(r)
        }
        vpTradeRoutes = keep
        // AI: spend idle trade units on the best route from the nearest of its cities
        for civ in civs where civ.isMajor && civ.isAlive && (!civ.isPlayer || epochsAutoplay) {
            for u in units.filter({ $0.civId == civ.id && vpIsTradeUnit($0.name) }) {
                guard vpTradeRoutes(of: civ.id).count < vpTradeRoutesPossible(civ.id) else { break }
                guard let home = cities(of: civ.id).min(by: { $0.coord.distance(to: u.coord) < $1.coord.distance(to: u.coord) }) else { continue }
                // the abstraction: an AI trade unit sets out from its nearest city
                if let best = vpTradeOptions(from: home, sea: vpIsSeaTradeUnit(u.name)).first {
                    vpEstablishTradeRoute(unitId: u.id, to: best.dest.id, kind: best.kind, from: home.id)
                }
            }
        }
    }

    private func vpTradeRouteCompleted(_ r: VPTradeRoute, origin: City, dest: City) {
        // a corporation spreads along completed international routes (CvPlayerCorporations, trade route arrival)
        guard r.kind == "international", let d = vpData, let corp = vpCorporation(of: r.originCiv), origin.buildings.contains(corp.office),
              vpFranchiseCount(corp, owner: r.originCiv) < vpFranchiseLimit(corp, owner: r.originCiv),
              !d.corporations.contains(where: { dest.buildings.contains($0.franchise) || dest.buildings.contains($0.office) }),
              !vpLeagueBlocksFranchise(in: dest), let ci = cityIndex(dest.id) else { return }
        addBuilding(cityIndex: ci, corp.franchise, tryAddFreeBuildings: false)
    }

    /// For the AI's construction choice: is a trade unit worth building in this city?
    func vpWantsTradeUnit(_ city: City, _ candidates: [UnitDef]) -> (String, Float)? {
        guard vpTradeEnabled, let c = civ(city.civId), !c.isPlayer || epochsAutoplay else { return nil }
        let idle = units.filter { $0.civId == c.id && vpIsTradeUnit($0.name) }.count
        guard vpTradeRoutes(of: c.id).count + idle < vpTradeRoutesPossible(c.id) else { return nil }
        for u in candidates where vpIsTradeUnit(u.name) {
            if !vpTradeOptions(from: city, sea: vpIsSeaTradeUnit(u.name)).isEmpty { return (u.name, 4) }
        }
        return nil
    }
}
