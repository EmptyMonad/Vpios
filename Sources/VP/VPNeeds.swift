// Vox Populi 4.22 needs-based happiness for the Unciv 4X core (MPL-2.0).
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// A port of Community-Patch-DLL (Release-4.22) CvCity::GetUnhappinessAggregated and its sources (Distress, Poverty,
// Illiteracy, Boredom, Religious Unrest, Isolation, Pillaged Tiles, Famine, Occupation, Urbanization), the yield medians
// of CvGame::DoUpdateGlobalMedians and the need modifiers of CvCity::GetTotalNeedModifierForYield.
// Active only when a loaded mod carries jsons/VPNeeds.json (written by the vp2unciv converter); otherwise every entry
// point here returns nil and Unciv's happiness is left exactly as it was.
//
// Not yet ported (VP has them, these do not count here): war weariness, process need modifiers (Wealth/Research),
// air-unit need modifiers, trade routes curing isolation, garrison occupation modifiers, monopoly happiness.

import Foundation

/// jsons/VPNeeds.json
struct VPNeedsData: Decodable {
    struct Entry: Decodable {
        var local: [String: Double]? = nil
        var global: [String: Double]? = nil
        var capital: [String: Double]? = nil
        var flags: [String: Double]? = nil
    }
    struct Difficulty: Decodable {
        var happinessDefault = 0, happinessDefaultCapital = 0, aiHappinessDefault = 0, aiHappinessDefaultCapital = 0
        var populationUnhappinessMod = 0, aiPopulationUnhappinessMod = 0, empireSizeUnhappinessMod = 0, aiEmpireSizeUnhappinessMod = 0
        var extraHappinessPerLuxury = 0, aiExtraHappinessPerLuxury = 0
        var unitSupplyBase = 0, unitSupplyPerCity = 0, unitSupplyPopulationPercent = 0, unitSupplyPerEraFlat = 0, unitSupplyPerEraModifier = 0, unitSupplyBonusPercent = 0
        var aiUnitSupplyBase = 0, aiUnitSupplyPerCity = 0, aiUnitSupplyPopulationPercent = 0, aiUnitSupplyPerEraFlat = 0, aiUnitSupplyPerEraModifier = 0, aiUnitSupplyBonusPercent = 0
        var cityStateUnitSupplyBase = 0, cityStateUnitSupplyPerCity = 0, cityStateUnitSupplyPopulationPercent = 0
    }
    var version: Int
    var defines: [String: Double]
    var difficulties: [String: Difficulty]
    var luxuryHappiness: [String: Int]
    var buildings: [String: Entry]
    var policies: [String: Entry]
    var nations: [String: Entry]
    var eraSupplyBase: [String: Int]? = nil

    func define(_ name: String, _ fallback: Double) -> Double { defines[name] ?? fallback }

    nonisolated(unsafe) private static var cache: [String: VPNeedsData?] = [:]
    private static let lock = NSLock()
    /// The last mod (in load order) that carries a VPNeeds.json wins.
    static func forMods(_ mods: [String]) -> VPNeedsData? {
        let key = mods.joined(separator: "\u{1}")
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        var found: VPNeedsData? = nil
        for m in mods {
            let url = Ruleset.modsDirectory.appendingPathComponent(m).appendingPathComponent("jsons/VPNeeds.json")
            if let raw = try? Data(contentsOf: url), let clean = Ruleset.cleanedModJSON(raw), let d = try? JSONDecoder().decode(VPNeedsData.self, from: clean) { found = d }
        }
        cache[key] = found
        return found
    }
}

/// CvGame m_iBasicNeedsMedian / m_iGoldMedian / m_iScienceMedian / m_iCultureMedian: yield per citizen ×100, smoothed.
/// Saved with the game.
struct VPMedians: Codable, Equatable {
    var basicNeeds = 0, gold = 0, science = 0, culture = 0
}

/// One city's unhappiness by source, in GetUnhappinessAggregated's order, already capped.
struct VPCityUnhappiness {
    var rows: [(String, Int)] = []
    var total: Int { rows.reduce(0) { $0 + $1.1 } }
}

extension GameState {
    var vpNeeds: VPNeedsData? { VPNeedsData.forMods(rs.mods) }

    // MARK: effects from buildings, policies and the nation

    private struct VPEffects {
        var v: [String: Double] = [:]
        mutating func add(_ d: [String: Double]?) { for (k, x) in d ?? [:] { v[k, default: 0] += x } }
        subscript(_ k: String) -> Double { v[k] ?? 0 }
    }

    /// The city's own buildings' local effects, plus every global effect of the empire (its cities' buildings, its
    /// policies, its nation) and the capital-only policy effects when the city is the capital.
    private func vpEffects(_ vp: VPNeedsData, city: City) -> (local: VPEffects, global: VPEffects) {
        var local = VPEffects(), global = VPEffects()
        for b in city.buildings { local.add(vp.buildings[b]?.local) }
        for c in cities(of: city.civId) { for b in c.buildings { global.add(vp.buildings[b]?.global) } }
        if let civ = civ(city.civId) {
            for p in civ.policies {
                global.add(vp.policies[p]?.global)
                if city.isCapital { local.add(vp.policies[p]?.capital) }
            }
            global.add(vp.nations[civ.nation]?.global)
        }
        return (local, global)
    }

    private func vpFlag(_ vp: VPNeedsData, civId: Int, _ flag: String) -> Double {
        guard let civ = civ(civId) else { return 0 }
        var x = vp.nations[civ.nation]?.flags?[flag] ?? 0
        for p in civ.policies { x += vp.policies[p]?.flags?[flag] ?? 0 }
        return x
    }

    private func vpDifficulty(_ vp: VPNeedsData, civId: Int) -> (own: VPNeedsData.Difficulty, isHuman: Bool) {
        let d = vp.difficulties[difficulty.name] ?? VPNeedsData.Difficulty()
        return (d, civ(civId)?.isPlayer ?? true)
    }

    // MARK: need modifiers (CvCity::GetAllNeedsModifier, GetEmpireSizeModifier, GetNeedModifierForYield)

    /// CvCity::GetEmpireSizeModifier: 5% per non-puppet city beyond the first, 1.25% per non-puppet citizen.
    func vpEmpireSizeModifier(civId: Int) -> Int {
        guard let vp = vpNeeds else { return 0 }
        let mine = cities(of: civId)
        let real = mine.filter { !$0.isPuppet }
        let cityMod = max(0, (mine.count - (mine.count - real.count) - 1) * Int(vp.define("EMPIRE_SIZE_NEED_MODIFIER_CITIES", 500)) / 100)
        let popMod = max(0, real.reduce(0) { $0 + $1.population } * Int(vp.define("EMPIRE_SIZE_NEED_MODIFIER_POP", 125)) / 1000)
        var mod = cityMod + popMod          // × min(100, world NumCitiesUnhappinessPercent): 100 on every VP map size
        let (d, human) = vpDifficulty(vp, civId: civId)
        mod = mod * (100 + d.empireSizeUnhappinessMod + (human ? 0 : d.aiEmpireSizeUnhappinessMod)) / 100
        return min(max(mod, 0), Int(vp.define("EMPIRE_SIZE_NEED_MODIFIER_CAP", 100000)))
    }

    enum VPNeed: String, CaseIterable { case distress = "Distress", poverty = "Poverty", illiteracy = "Illiteracy", boredom = "Boredom", religiousUnrest = "Religious Unrest" }

    /// CvCity::GetTotalNeedModifierForYield: the % by which this city's median is raised (positive) or lowered.
    func vpNeedModifier(_ need: VPNeed, city: City) -> Int {
        guard let vp = vpNeeds else { return 0 }
        let (local, global) = vpEffects(vp, city: city)
        var mod = city.isCapital ? Int(vp.define("CAPITAL_NEED_MODIFIER", 25)) : 0
        // tech need modifier and city size modifier are 0 in VP 4.22
        let empire = vpEmpireSizeModifier(civId: city.civId)
        let reduction = Int(local["empireSizeModReduction"] + global["empireSizeModReduction"])   // negative
        mod += min(max(empire + reduction, 0), empire)
        let (d, human) = vpDifficulty(vp, civId: city.civId)
        mod += d.populationUnhappinessMod + (human ? 0 : d.aiPopulationUnhappinessMod)
        if city.isCelebrating { mod += Int(vpFlag(vp, civId: city.civId, "wltkdNeedsMod")) }
        let key: String
        switch need {
        case .distress: key = "basicNeedsMedianMod"
        case .poverty: key = "goldMedianMod"
        case .illiteracy: key = "scienceMedianMod"
        case .boredom: key = "cultureMedianMod"
        case .religiousUnrest: key = "religiousUnrestMod"
        }
        mod += Int(local[key] + global[key])
        return mod
    }

    // MARK: yields

    /// The city's yield for a need, ×100 (CvCity::getYieldRateTimes100): gross food plus production for Distress, gold,
    /// science, culture. `forMedian` leaves trade-route yields out, as the medians do.
    func vpYieldTimes100(_ need: VPNeed, city: City, forMedian: Bool = false) -> Int {
        guard let s = storedCityStats[city.id] else { return 0 }
        var t = s.total
        if forMedian { t += s.tradeRoutes * -1 }
        switch need {
        case .distress: return Int((t.food + t.production) * 100)
        case .poverty: return Int(t.gold * 100)
        case .illiteracy: return Int(t.science * 100)
        case .boredom: return Int(t.culture) * 100   // getJONSCulturePerTurn() * 100
        case .religiousUnrest: return 0
        }
    }

    private func vpGameMedian(_ need: VPNeed) -> Int {
        switch need {
        case .distress: return vpMedians.basicNeeds
        case .poverty: return vpMedians.gold
        case .illiteracy: return vpMedians.science
        case .boredom: return vpMedians.culture
        case .religiousUnrest: return 0
        }
    }

    /// CvCity::GetBasicNeedsMedian etc.: the game median × (100 + need modifier)/100 × base modifier/100, as a Float.
    func vpCityMedian(_ need: VPNeed, city: City) -> Float {
        guard let vp = vpNeeds else { return 0 }
        let baseKey = ["Distress": "DISTRESS", "Poverty": "POVERTY", "Illiteracy": "ILLITERACY", "Boredom": "BOREDOM"][need.rawValue] ?? "DISTRESS"
        var m = Float(vpGameMedian(need))
        m *= Float(100 + vpNeedModifier(need, city: city)); m /= 100
        m *= Float(max(Int(vp.define("\(baseKey)_MEDIAN_BASE_MODIFIER", 100)), 0)); m /= 100
        return m <= 0 ? 0 : m
    }

    /// CvCity::GetDistress / GetPoverty / GetIlliteracy / GetBoredom.
    func vpNeedUnhappiness(_ need: VPNeed, city: City, extraPopulation: Int = 0) -> Int {
        guard let vp = vpNeeds, need != .religiousUnrest else { return 0 }
        if city.isPuppet || city.resistanceTurns > 0 || city.razing { return 0 }
        let pop = city.population + extraPopulation
        let median = vpCityMedian(need, city: city)
        let yield = Float(vpYieldTimes100(need, city: city))
        guard median > 0 else { return 0 }   // no median yet: VP divides by 0, pop - inf, clamped to 0
        let raw = min(max(Int((Float(pop) - yield / median).rounded(.up)), 0), pop)   // ceil(pop - yield/median)
        let (local, global) = vpEffects(vp, city: city)
        let flatKey: String = ["Distress": "distressFlat", "Poverty": "povertyFlat", "Illiteracy": "illiteracyFlat", "Boredom": "boredomFlat"][need.rawValue]!
        return min(max(raw - Int(local[flatKey]) - Int(global[flatKey]), 0), pop)
    }

    // MARK: the city's unhappiness (CvCity::GetUnhappinessAggregated)

    /// VP's occupation: a conquered city that is not a puppet and has no courthouse (Unciv hasExtraAnnexUnhappiness).
    func vpIsOccupied(_ city: City) -> Bool {
        city.originalOwner != city.civId && !city.isPuppet
            && !city.buildings.contains { rs.buildings[$0]?.uniques.contains("Removes extra unhappiness from annexed cities") == true }
    }

    func vpCityUnhappiness(_ city: City) -> VPCityUnhappiness? {
        guard let vp = vpNeeds, let civ = civ(city.civId), civ.isMajor else { return nil }
        var out = VPCityUnhappiness()
        let pop = city.population
        let (local, global) = vpEffects(vp, city: city)

        // Urbanization (specialists): 1 each, less the free ones
        let specialistCount = city.specialists.values.reduce(0, +)
        func specialistUnhappiness() -> Int {
            var n = specialistCount
            var free = Int(local["noUnhappyFromXSpecialists"] + global["noUnhappyFromXSpecialists"])
            free = min(free, n)
            if n > 0 { n -= free }
            if vpFlag(vp, civId: city.civId, "halfSpecialistUnhappiness") > 0 { n = (n + 1) / 2 }
            return n * Int(vp.define("UNHAPPINESS_PER_SPECIALIST", 100)) / 100
        }

        if city.razing || city.resistanceTurns > 0 { out.rows = [(city.razing ? "Razing" : "Resistance", pop)]; return out }
        if city.isPuppet {
            out.rows = [("Puppet", pop / max(1, Int(vp.define("UNHAPPINESS_PER_X_PUPPET_CITIZENS", 4)))), ("Urbanization", specialistUnhappiness())]
            return out
        }

        var running = 0
        func add(_ name: String, _ amount: () -> Int) {
            guard running < pop else { return }
            let a = amount()
            guard a > 0 else { return }
            out.rows.append((name, a)); running += a
        }
        add("Occupation") {
            guard vpIsOccupied(city), local["noOccupiedUnhappiness"] == 0 else { return 0 }
            var f = Float(pop) * Float(vp.define("UNHAPPINESS_PER_OCCUPIED_POPULATION", 1.0))
            f *= Float(100 + Int(vpFlag(vp, civId: city.civId, "populationUnhappinessMod"))); f /= 100
            return min(max(Int(f), 0), pop)
        }
        add("Isolation") {
            if city.isCapital || cities(of: city.civId).count < 2 || city.connectedToCapital { return 0 }
            if vpFlag(vp, civId: city.civId, "noConnectionUnhappiness") > 0 || vpFlag(vp, civId: city.civId, "noUnhappyIsolation") > 0 { return 0 }
            return min(max(Int(Float(pop) * Float(vp.define("UNHAPPINESS_PER_ISOLATED_POP", 0.34))), 0), pop)
        }
        add("Religious Unrest") {
            guard settings.religionEnabled, vpFlag(vp, civId: city.civId, "noReligiousStrife") == 0,
                  let major = majorityReligion(of: city), religionIsMajor(major) else { return 0 }
            let minorities = pop - (followers(of: city)[major] ?? 0)
            guard minorities > 0 else { return 0 }
            var f = Float(minorities) * Float(vp.define("UNHAPPINESS_PER_RELIGIOUS_MINORITY_POP", 0.5))
            f *= Float(100 + vpNeedModifier(.religiousUnrest, city: city)); f /= 100
            return min(max(Int(f) - Int(local["religiousUnrestFlat"]) - Int(global["religiousUnrestFlat"]), 0), pop)
        }
        add("Pillaged Tiles") {
            let n = city.tiles.compactMap { map[$0] }.filter { $0.pillaged }.count
            return min(max(Int(Float(n) * Float(vp.define("UNHAPPINESS_PER_PILLAGED_TILE", 0.5))), 0), pop)
        }
        add("Poverty") { vpNeedUnhappiness(.poverty, city: city) }
        add("Illiteracy") { vpNeedUnhappiness(.illiteracy, city: city) }
        add("Boredom") { vpNeedUnhappiness(.boredom, city: city) }
        add("Famine") {
            let surplus = storedCityStats[city.id]?.foodSurplus ?? 0
            guard surplus < 0 else { return 0 }
            return min(max(Int(Float(-surplus) * Float(vp.define("UNHAPPINESS_PER_STARVING_POP", 1.0))), 0), pop)
        }
        add("Distress") { vpNeedUnhappiness(.distress, city: city) }
        // capped at the population, specialists excepted: trim the last rows
        var excess = running - pop
        var i = out.rows.count - 1
        while excess > 0 && i >= 0 {
            let cut = min(excess, out.rows[i].1)
            out.rows[i].1 -= cut; excess -= cut
            if out.rows[i].1 == 0 { out.rows.remove(at: i) }
            i -= 1
        }
        let urb = specialistUnhappiness()
        if urb > 0 { out.rows.append(("Urbanization", urb)) }
        return out
    }

    // MARK: happiness sources VP changes

    /// CvPlayer::DoUpdateTotalHappiness start level, plus the capital's handicap happiness (CvCity::GetLocalHappiness).
    func vpBaseHappiness(civId: Int) -> Int? {
        guard let vp = vpNeeds else { return nil }
        let (d, human) = vpDifficulty(vp, civId: civId)
        let hasCapital = cities(of: civId).contains { $0.isCapital }
        if human { return d.happinessDefault + (hasCapital ? d.happinessDefaultCapital : 0) }
        return d.aiHappinessDefault + (hasCapital ? d.aiHappinessDefaultCapital : 0)
    }

    /// CvPlayer::GetBonusHappinessFromLuxuriesFlat: each luxury's own Happiness (2 in VP) plus the per-luxury extra.
    func vpLuxuryHappiness(civId: Int, luxuries: Set<String>) -> Int? {
        guard let vp = vpNeeds else { return nil }
        let (d, human) = vpDifficulty(vp, civId: civId)
        let extra = human ? d.extraHappinessPerLuxury : d.aiExtraHappinessPerLuxury
        return luxuries.reduce(0) { acc, r in
            let base = vp.luxuryHappiness[r] ?? 0
            return base > 0 ? acc + base + extra : acc
        }
    }

    // MARK: approval (CvPlayer::CalculateNetHappiness under MOD_BALANCE_VP)

    /// VP's approval rating: min(200, happy×100/unhappy)/2, 100 with no unhappiness. 50 is the unhappy threshold.
    func vpApproval(civId: Int) -> Int? {
        guard vpNeeds != nil else { return nil }
        let h = happinessBreakdown(civId)
        let unhappy = -h.rows.filter { $0.1 < 0 }.reduce(0.0) { $0 + $1.1 }
        let happy = h.rows.filter { $0.1 > 0 }.reduce(0.0) { $0 + $1.1 }
        if unhappy <= 0 { return 100 }
        return min(200, Int(happy) * 100 / max(1, Int(unhappy))) / 2
    }

    // MARK: the medians (CvGame::DoUpdateGlobalMedians), once a turn

    func vpUpdateMedians() {
        guard let vp = vpNeeds else { return }
        let minPop = Int(vp.define("YIELD_MEDIAN_MIN_POP_REQUIREMENT", 3))
        var lists: [VPNeed: [Float]] = [:]
        for civ in civs where civ.isAlive && civ.isMajor {
            for c in cities(of: civ.id) where !c.isPuppet && !c.razing && c.resistanceTurns == 0 && c.population >= minPop {
                for need in [VPNeed.distress, .poverty, .illiteracy, .boredom] {
                    lists[need, default: []].append(Float(vpYieldTimes100(need, city: c, forMedian: true)) / Float(c.population))
                }
            }
        }
        guard let count = lists[.boredom]?.count, count > 0 else { return }
        let n = count * min(max(Int(vp.define("YIELD_MEDIAN_PERCENTILE", 50)), 1), 100) / 100
        func next(_ need: VPNeed, _ old: Int, _ alphaKey: String) -> Int {
            let sorted = (lists[need] ?? []).sorted()
            let alpha = Float(vp.define(alphaKey, 0.65))
            return Int(0.5 + Float(Int(sorted[min(n, sorted.count - 1)])) * alpha + Float(old) * (1 - alpha))
        }
        vpMedians = VPMedians(basicNeeds: next(.distress, vpMedians.basicNeeds, "DISTRESS_MEDIAN_RATE_CHANGE"),
                              gold: next(.poverty, vpMedians.gold, "POVERTY_MEDIAN_RATE_CHANGE"),
                              science: next(.illiteracy, vpMedians.science, "ILLITERACY_MEDIAN_RATE_CHANGE"),
                              culture: next(.boredom, vpMedians.culture, "BOREDOM_MEDIAN_RATE_CHANGE"))
    }
}
