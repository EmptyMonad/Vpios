// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
struct NationDef: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let leaderName: String?
    let adjective: [String]
    /// The colours as Unciv's Nation.setTransients makes them (getOuterColor / getInnerColor): a list of fewer than three
    /// numbers is Color.PURPLE, and a missing inner colour stays nil for each screen's own fallback. Every screen indexes
    /// [0], [1] and [2]; a mod's two-number colour stopped the app on the first border, badge or minimap it drew.
    let outerColor: [Int]
    let innerColor: [Int]?
    /// The lists as the json has them, for the ruleset checks only (Unciv RulesetValidator reads the json's lists).
    let rawOuterColor: [Int]
    let rawInnerColor: [Int]?
    /// Unciv Nation.setTransients `safeColorFromRGB`: `if (rgb.size >= 3) colorFromRGB(rgb) else Color.PURPLE` (0xA020F0)
    static func safeColorFromRGB(_ rgb: [Int]) -> [Int] { rgb.count >= 3 ? rgb : [160, 32, 240] }
    let cities: [String]
    let uniqueName: String?
    let uniques: [String]
    let startBias: [String]
    let cityStateType: String?
    let favoredReligion: String?
    /// Unciv Nation.neutralHello / hateHello: the greeting on the diplomacy screen (LeaderIntroTable).
    let neutralHello: String?
    let hateHello: String?
    /// Unciv Nation leader lines shown by AlertPopup / DiplomacyScreen / TradePopup (empty when the ruleset has none).
    let introduction: String
    let startIntroPart1: String
    let startIntroPart2: String
    let declaringWar: String
    let attacked: String
    let defeated: String
    let denounced: String
    let declaringFriendship: String
    let neutralDenouncing: String
    let hateDenouncing: String
    let acceptingDemand: String
    let neutralRejectingDemand: String
    let hateRejectingDemand: String
    let tradeRequest: String
    let afterPeace: String
    /// Unciv Nation.preferredVictoryType (default Constants.neutralVictoryType) and Nation.personality.
    let preferredVictoryType: String
    let personality: String?
    /// Unciv Nation.spyNames: EspionageManager.getSpyName picks an unused one at random
    let spyNames: [String]

    private enum CodingKeys: String, CodingKey { case name, spyNames, leaderName, adjective, outerColor, innerColor, cities, uniqueName, uniques, startBias, cityStateType, favoredReligion, neutralHello, hateHello, introduction, startIntroPart1, startIntroPart2, declaringWar, attacked, defeated, denounced, declaringFriendship, neutralDenouncing, hateDenouncing, acceptingDemand, neutralRejectingDemand, hateRejectingDemand, tradeRequest, afterPeace, preferredVictoryType, personality }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        leaderName = try c.decodeIfPresent(String.self, forKey: .leaderName)
        neutralHello = try c.decodeIfPresent(String.self, forKey: .neutralHello)
        hateHello = try c.decodeIfPresent(String.self, forKey: .hateHello)
        introduction = try c.decodeIfPresent(String.self, forKey: .introduction) ?? ""
        startIntroPart1 = try c.decodeIfPresent(String.self, forKey: .startIntroPart1) ?? ""
        startIntroPart2 = try c.decodeIfPresent(String.self, forKey: .startIntroPart2) ?? ""
        declaringWar = try c.decodeIfPresent(String.self, forKey: .declaringWar) ?? ""
        attacked = try c.decodeIfPresent(String.self, forKey: .attacked) ?? ""
        defeated = try c.decodeIfPresent(String.self, forKey: .defeated) ?? ""
        denounced = try c.decodeIfPresent(String.self, forKey: .denounced) ?? ""
        declaringFriendship = try c.decodeIfPresent(String.self, forKey: .declaringFriendship) ?? ""
        neutralDenouncing = try c.decodeIfPresent(String.self, forKey: .neutralDenouncing) ?? ""
        hateDenouncing = try c.decodeIfPresent(String.self, forKey: .hateDenouncing) ?? ""
        acceptingDemand = try c.decodeIfPresent(String.self, forKey: .acceptingDemand) ?? ""
        neutralRejectingDemand = try c.decodeIfPresent(String.self, forKey: .neutralRejectingDemand) ?? ""
        hateRejectingDemand = try c.decodeIfPresent(String.self, forKey: .hateRejectingDemand) ?? ""
        tradeRequest = try c.decodeIfPresent(String.self, forKey: .tradeRequest) ?? ""
        afterPeace = try c.decodeIfPresent(String.self, forKey: .afterPeace) ?? ""
        preferredVictoryType = try c.decodeIfPresent(String.self, forKey: .preferredVictoryType) ?? "Neutral"
        personality = try c.decodeIfPresent(String.self, forKey: .personality)
        spyNames = try c.decodeIfPresent([String].self, forKey: .spyNames) ?? []
        adjective = try c.decodeIfPresent([String].self, forKey: .adjective) ?? [name]
        rawOuterColor = try c.decodeIfPresent([Int].self, forKey: .outerColor) ?? [200, 200, 200]
        rawInnerColor = try c.decodeIfPresent([Int].self, forKey: .innerColor)
        outerColor = NationDef.safeColorFromRGB(rawOuterColor)
        innerColor = rawInnerColor.map(NationDef.safeColorFromRGB)
        cities = try c.decodeIfPresent([String].self, forKey: .cities) ?? []
        uniqueName = try c.decodeIfPresent(String.self, forKey: .uniqueName)
        uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        startBias = try c.decodeIfPresent([String].self, forKey: .startBias) ?? []
        cityStateType = try c.decodeIfPresent(String.self, forKey: .cityStateType)
        favoredReligion = try c.decodeIfPresent(String.self, forKey: .favoredReligion)
    }
    /// Major, playable nations have a leader and a city list.
    var isMajor: Bool { leaderName != nil && !cities.isEmpty && !isBarbarian }
    var isBarbarian: Bool { name == "Barbarians" }
    var isCityState: Bool { cityStateType != nil }
    var uniqueObjects: [Unique] { uniques.map(Unique.init) }
}

extension Ruleset {
    /// Unciv Nation.getStartBias(ruleset, IgnoreConditionals): the nation's startBias field, its "Start bias []" uniques,
    /// then its city-state type's, each once in that order (a LinkedHashSet). Map generation and the Civilopedia share it.
    func startBias(of n: NationDef) -> [String] {
        var out: [String] = []
        func add(_ b: String) { if !out.contains(b) { out.append(b) } }
        n.startBias.forEach(add)
        for u in n.uniqueObjects where u.pattern == "Start bias []" { add(u.param(0)) }
        if let type = n.cityStateType.flatMap({ cityStateTypes[$0] }) {
            for u in type.uniques.map(Unique.init) where u.pattern == "Start bias []" { add(u.param(0)) }
        }
        return out
    }
}


// MARK: - Nation, era, terrain and belief uniques that had no implementation (Unciv UniqueType parity pass).
extension GameState {
    func civHasUnique(_ civId: Int, _ pattern: String) -> Bool { civUniques(civId).contains { $0.pattern == pattern } }
    func civUniqueFirst(_ civId: Int, _ pattern: String) -> Unique? { civUniques(civId).first { $0.pattern == pattern } }

    // MARK: movement (Denmark, Inca, Iroquois, Polynesia, Carthage, submarines)
    /// "[1] Movement point cost to disembark <for [All] units>"
    /// Unciv MapUnitCache.costToDisembark / costToEmbark: the lowest matching value from the unit and its civ.
    func disembarkCost(for unit: Unit) -> Double? { movementTransitionCost(unit, "[] Movement point cost to disembark") }
    func embarkCost(for unit: Unit) -> Double? { movementTransitionCost(unit, "[] Movement point cost to embark") }
    private func movementTransitionCost(_ unit: Unit, _ pattern: String) -> Double? {
        (unit.promotionUniques + civUniques(unit.civId)).filter { u in
            u.pattern == pattern && (u.conditional("for [] units").map { unitMatches(unit, $0.param(0)) } ?? true)
        }.map { $0.double(0) }.min()
    }
    func ignoresHillCost(_ civId: Int) -> Bool { civHasUnique(civId, "Units ignore terrain costs when moving into any tile with Hills") }
    /// Iroquois: forest and jungle in friendly territory count as roads (movement always, city connections once the road tech is known).
    func forestsAreRoads(_ civId: Int) -> Bool { civUniques(civId).contains { $0.pattern.hasPrefix("All units move through Forest and Jungle Tiles in friendly territory") } }
    func forestsConnectCities(_ civId: Int) -> Bool {
        guard forestsAreRoads(civId), let civ = civ(civId) else { return false }
        let roadTech = rs.improvements["Road"]?.techRequired
        return roadTech == nil || civ.techs.contains(roadTech!)
    }
    /// Unciv Tile.forestOrJungleAreRoads: a Forest or Jungle feature, and `isFriendlyTerritory(civInfo)` - a Friend
    /// city-state's or an open-borders partner's woods carry the connection too, not only our own.
    func tileIsFriendlyForestRoad(_ t: Tile, civId: Int) -> Bool { t.hasForestOrJungle && isFriendlyTerritory(t, for: civId) }
    /// "Land units may cross [Mountain] tiles after the first [Great General] is earned"
    /// Unciv UnitMovement.cannotPassThroughReason: `passableImpassables.contains(tile.lastTerrain.name)` - the TOP terrain
    /// only. A natural wonder's base is its turnsInto ("Mountain") but its lastTerrain is the wonder itself, so Mount
    /// Fuji and the other mountain wonders stay impassable to Carthage; matching base + features let it walk onto them.
    func mayCrossImpassable(_ unit: Unit, _ tile: Tile) -> Bool {
        guard unit.def.isLand, let civ = civ(unit.civId) else { return false }
        let lastTerrain = tile.lastTerrainName
        for u in civUniques(unit.civId) where u.pattern == "Land units may cross [] tiles after the first [] is earned" {
            if lastTerrain == u.param(0) && civ.everEarnedUnits.contains(u.param(1)) { return true }
        }
        return false
    }
    /// "Can enter ice tiles" (unit type)
    func canEnterIce(_ unit: Unit) -> Bool {
        rs.unitTypes[unit.def.unitType]?.uniques.contains("Can enter ice tiles") == true || unit.def.uniques.contains("Can enter ice tiles")
    }
    /// Passable despite `isImpassable`: ice for submarines, mountains for Carthage.
    func impassableOverride(_ unit: Unit, _ tile: Tile) -> Bool {
        if tile.features.contains("Ice") && canEnterIce(unit) && rs.terrains[tile.baseTerrain]?.impassable != true && tile.naturalWonder == nil { return true }
        return mayCrossImpassable(unit, tile)
    }
    /// "Enables [Embarked]/[All] units to enter ocean tiles" (Astronomy, Polynesia)
    func oceanEnabled(for unit: Unit, embarked: Bool) -> Bool {
        let ctx = UniqueContext(civId: unit.civId, unit: unit)
        for u in civUniques(unit.civId) where u.pattern == "Enables [] units to enter ocean tiles" && conditionalsHold(u, ctx) {
            let f = u.param(0)
            if f == "All" || (embarked && f == "Embarked") || (!embarked && unitMatches(unit, f)) { return true }
        }
        return civUniques(unit.civId).contains { $0.pattern == "Enables embarked units to enter ocean tiles" } && embarked
    }
    func oceanEnabledForEmbarked(_ civId: Int) -> Bool {
        civUniques(civId).contains { $0.pattern == "Enables embarked units to enter ocean tiles" || ($0.pattern == "Enables [] units to enter ocean tiles" && ($0.param(0) == "All" || $0.param(0) == "Embarked")) }
    }
    /// "Cannot be carried by [Carrier] units"
    func canBeCarried(_ unit: Unit, by carrier: Unit) -> Bool {
        guard carrierCapacity(carrier) > 0 else { return false }
        for u in unit.def.uniqueObjects where u.pattern == "Cannot be carried by [] units" { if unitMatches(carrier, u.param(0)) { return false } }
        return true
    }
    // MARK: combat (Mongolia, Ottomans, anti-air, ranged ships)
    func canOnlyAttackUnitsFilter(_ unit: Unit) -> String? { unit.def.uniqueObjects.first { $0.pattern == "Can only attack [] units" }?.param(0) }
    func cannotCaptureCities(_ unit: Unit) -> Bool { unit.def.uniques.contains("Unable to capture cities") || unit.promotionUniques.contains { $0.pattern == "Unable to capture cities" } }
    func greatGeneralDoubles(_ civId: Int) -> Bool { civHasUnique(civId, "Great General provides double combat bonus") }
    /// "When defeating a [{Barbarian} {Water}] unit, earn [25] Gold and recruit it <with [50]% chance>" – melee kills only (Unciv BattleUnitCapture).
    @discardableResult
    func gainFromDefeating(attackerId: Int, victim: Unit, at target: HexCoord, melee: Bool) -> Bool {
        // Unciv BattleUnitCapture: an Uncapturable defender is never recruited
        guard melee, !victim.def.uniques.contains("Uncapturable"), !victim.promotionUniques.contains(where: { $0.pattern == "Uncapturable" }),
              let ai = unitIndex(attackerId), let ci = civIndex(units[ai].civId) else { return false }
        var recruited = false
        let attacker = units[ai]
        let ctx = UniqueContext(civId: attacker.civId, unit: attacker, tile: map[attacker.coord],
                                attackedTile: map[target], attacking: true, opponentUnit: victim,
                                opponentCivId: victim.civId, combatAction: "Attack")
        for u in civUniques(attacker.civId) + attacker.promotionUniques where u.pattern == "When defeating a [] unit, earn [] Gold and recruit it" {
            guard unitMatches(victim, u.param(0)), conditionalsHold(u, ctx) else { continue }
            // Unciv: <with []% chance> artik conditionalsHold icinde (Conditionals.ConditionalChance) degerlendiriliyor
            civs[ci].gold += u.double(1)
            if let recruit = spawnUnit(victim.name, civId: attacker.civId, at: target), let ri = unitIndex(recruit.id) {
                units[ri].health = 50; units[ri].movementLeft = 0
                recruited = true
                notify(attacker.civId, "An enemy [\(victim.name)] has joined us!", category: .War, icons: [victim.name], actions: [.unit(recruit.coord, recruit.id)])
            }
        }
        return recruited
    }
    /// Belief "Earn [50]% of [Military] unit's [Strength] as [Faith] when killed within 4 tiles of a city following this religion".
    func religionKillPlunder(killerCiv: Int, victim: Unit, at killerTile: HexCoord) {
        guard let ci = civIndex(killerCiv) else { return }
        // Unciv: every city centre within 4 tiles of the killer, regardless of who owns it
        for city in cities where city.coord.distance(to: killerTile) <= 4 {
            guard let r = majorityReligion(of: city), let owner = religionOwner(r) else { continue }
            for b in owner.religionBeliefs {
                for u in rs.beliefs[b]?.uniqueObjects ?? [] where u.pattern == "Earn []% of [] unit's [] as [] when killed within 4 tiles of a city following this religion" {
                    guard unitMatches(victim, u.param(1)) else { continue }
                    // Unciv tryEarnFromKilling: the strength source is the larger of melee and ranged, truncated.
                    let base = u.param(2) == "Strength" ? Double(max(victim.def.strength, victim.def.rangedStrength)) : Double(victim.def.cost)
                    let amount = (base * u.double(0) / 100).rounded(.towardZero)
                    switch u.param(3) {
                    case "Faith": civs[ci].faithStored += amount
                    case "Gold": civs[ci].gold += amount
                    case "Culture": civs[ci].cultureStored += amount; civs[ci].totalCulture += amount
                    case "Science": addScience(civId: civs[ci].id, Int(amount))
                    default: break
                    }
                }
            }
            break
        }
    }

    // MARK: encampments and cities (Germany, Songhai, Honor, walls)
    /// "Receive [+200]% Gold from Barbarian encampments and pillaging Cities"
    func plunderMultiplier(_ civId: Int) -> Double {
        var m = 1.0
        for u in civUniques(civId) where u.pattern == "Receive []% Gold from Barbarian encampments and pillaging Cities" || u.pattern == "Gain []% of the gold from encampments and cities" || u.pattern == "[]% Gold gained from encampments and cities" { m *= 1 + u.double(0) / 100 }
        return m
    }
    /// "When conquering an encampment, earn [25] Gold and recruit a Barbarian unit <with [67]% chance>"
    func recruitFromEncampment(civId: Int, at c: HexCoord) -> Double {
        var gold = 0.0
        for u in civUniques(civId) where u.pattern == "When conquering an encampment, earn [] Gold and recruit a Barbarian unit" {
            // Unciv MapUnit.kt:1083 `civ.getMatchingUniques(UniqueType.GainFromEncampment)` — kosullar (ve `<with []% chance>`)
            // Conditionals.ConditionalChance uzerinden degerlendirilir; kendi zarimizi atmiyoruz.
            guard conditionalsHold(u, UniqueContext(civId: civId)) else { continue }
            gold += u.double(0)
            // Unciv MapUnit: BarbarianManager.spawnBarbarian(tile, civ)
            if let recruit = spawnBarbarian(at: c, allegiance: civId), let ri = unitIndex(recruit.id) {
                units[ri].health = 100; units[ri].movementLeft = 0   // Unciv MapUnit.clearEncampment: `recruitedUnit.health = 100` (50 is the kill-recruit of BattleUnitCapture)
                notify(civId, "An enemy [\(recruit.name)] has joined us!", category: .War, icons: [recruit.name], actions: [.unit(recruit.coord, recruit.id)])
            }
        }
        return gold
    }
    /// "Upon capturing a city, receive [10] times its [Culture] production as [Culture] immediately"
    func captureCityStatRewards(city: City, conqueror: Int) {
        guard let ci = civIndex(conqueror) else { return }
        let stats = currentCityStats(city.id).total
        for u in civUniques(conqueror) where u.pattern == "Upon capturing a city, receive [] times its [] production as [] immediately" {
            let base: Double = { switch u.param(1) { case "Culture": return stats.culture; case "Gold": return stats.gold; case "Science": return stats.science; case "Production": return stats.production; case "Food": return stats.food; case "Faith": return stats.faith; default: return 0 } }()
            // Unciv Battle.conquerCity: `params[0].toInt() * currentCityStats[stat].toInt()` → addGameResource
            let amount = Double(u.int(0) * Int(base))
            switch u.param(2) {
            case "Culture": addCulture(ci, amount); civs[ci].totalCulture += amount; if amount > 0 { civs[ci].totalCultureForContests += Int(amount) }
            case "Gold": civs[ci].gold += amount; goldTrace(civs[ci].id, amount)
            case "Science": addScience(civId: civs[ci].id, Int(amount))
            case "Faith": civs[ci].faithStored += amount; if amount > 0 { civs[ci].totalFaithForContests += Int(amount) }
            default: break
            }
        }
    }
    /// "[+100]% Gold given to enemy if city is captured <in this city>" (buildings of the captured city)
    func goldGivenToEnemyMultiplier(_ city: City) -> Double {
        var m = 1.0
        for b in city.buildings { for u in rs.buildings[b]?.uniqueObjects ?? [] where u.pattern == "[]% Gold given to enemy if city is captured" { m *= 1 + u.double(0) / 100 } }
        return m
    }

    // MARK: natural wonders (Spain, El Dorado, Fountain of Youth)
    /// Unciv CivInfoTransientCache.discoverNaturalWonders: everything the civ can currently see is scanned, not
    /// just the neighbourhood of whichever unit happened to move. A wonder first seen from a city, from a border
    /// that grew, or by a scout with long sight was otherwise never discovered, and with it went the happiness
    /// Unciv grants for each one - which is enough to keep a whole empire one point unhappier than it should be.
    ///
    /// Run from the end of updateExploration (Unciv updateViewableTiles). `newlyViewedNaturalWonders` is a fresh
    /// HashSet<Tile> filled while walking viewableTiles, so two wonders come into view together in that set's walk -
    /// not in a (q, r) sort.
    func discoverNaturalWonders(civId: Int) {
        guard let ci = civIndex(civId), civs[ci].isMajor || civs[ci].isCityState else { return }
        let known = civs[ci].seenNaturalWonders
        // nothing new in sight: the ordered walk below would find nothing either
        guard visibleTiles(for: civId).contains(where: { c in map[c]?.naturalWonder.map { !known.contains($0) } ?? false }) else { return }
        var newlyViewed: [HexCoord] = []
        for c in civViewableTilesUncivOrder(civId) {
            if let nw = map[c]?.naturalWonder, !known.contains(nw) { newlyViewed.append(c) }
        }
        for c in JavaHash1Set.iterationOrder(newlyViewed) {
            // "GBR could be discovered twice otherwise!"
            guard let nw = map[c]?.naturalWonder, let idx = civIndex(civId), !civs[idx].seenNaturalWonders.contains(nw) else { continue }
            // Unciv CivInfoTransientCache: the wonder joins the list FIRST ("GBR could be discovered twice
            // otherwise!"), then the notification, then the stats and the triggers - so a triggered unique
            // that reads happiness already counts this wonder, and ours did not. The block ends in
            // `civInfo.updateStatsForNextTurn()`, which we were not doing at all.
            civs[idx].seenNaturalWonders.insert(nw)
            notify(civId, "We have discovered [\(nw)]!", category: .General, icons: ["StatIcons/Happiness"], coord: c)
            onNaturalWonderDiscovered(civId: civId, wonder: nw, at: c)
            updateStatsForNextTurn(civId)
        }
    }

    func onNaturalWonderDiscovered(civId: Int, wonder: String, at c: HexCoord) {
        guard let ci = civIndex(civId), let def = rs.terrains[wonder] else { return }
        let first = !civs.contains { $0.id != civId && $0.isMajor && $0.seenNaturalWonders.contains(wonder) }   // Unciv: `filter { it != civInfo && it.isMajorCiv() }` - a city-state does not use up "first to discover"
        // Unciv CivInfoTransientCache: both bonuses go into one total and one notification.
        var gained = Stats()
        for u in civUniques(civId) where u.pattern == "[] for discovering a Natural Wonder (bonus enhanced to [] if first to discover it)" {
            if let st = Unique.parseStats(first ? u.param(1) : u.param(0)) { gained = gained + st }
        }
        if first { for u in def.uniqueObjects where u.pattern == "Grants [] to the first civilization to discover it" { if let st = Unique.parseStats(u.param(0)) { gained = gained + st } } }
        if !gained.isEmpty {
            applyStats(civId: civId, gained)
            // Unciv: `addNotification("We have received [${statsGained}] for discovering [${naturalWonder}]", General,
            // statsGained.toString())` - the stats string with its stat characters, and that same string as the icon
            notify(civId, "We have received [\(gained.uncivTextWithIcons)] for discovering [\(wonder)]", category: .General, icons: [gained.uncivTextWithIcons])
        }
        _ = ci
        // Unciv CivInfoTransientCache: `civInfo.forEachTriggeredUnique(TriggerUponDiscoveringNaturalWonder,
        // GameContext(civInfo, tile = tile), ignoreCities = false)` - the civ's uniques, no unit's
        triggerConditionalUniques(civId: civId, triggerText: "due to discovering a Natural Wonder") { $0.pattern == "upon discovering a Natural Wonder" }
    }
    func applyStats(civId: Int, _ st: Stats) {
        addStats(civId: civId, st)   // Unciv civInfo.addStats(statsGained)
    }
    /// "Grants [Rejuvenation] ([all healing effects doubled]) to adjacent [{Military} {Land}] units for the rest of the game"
    func grantWonderPromotions(unitId: Int) {
        guard let ui = unitIndex(unitId) else { return }
        let unit = units[ui]
        for n in map.tilesWithin(unit.coord, radius: 1) {
            guard let nw = map[n]?.naturalWonder, let def = rs.terrains[nw] else { continue }
            for u in def.uniqueObjects where u.pattern == "Grants [] ([]) to adjacent [] units for the rest of the game" {
                guard unitMatches(unit, u.param(2)), rs.promotions[u.param(0)] != nil, !units[ui].promotions.contains(u.param(0)) else { continue }
                units[ui].promotions.append(u.param(0))
            }
        }
    }
    var naturalWonderHappinessBonus: Double { 0 }

    // MARK: city-states (Greece, Patronage, beliefs)
    func influenceRecoveryRate(_ major: Int) -> Double { civHasUnique(major, "City-State Influence recovers at twice the normal rate") ? 2 : 1 }
    /// "Resting point for Influence with City-States following this religion [+15]"
    func religionRestingPoint(major: Int, cityState: Int) -> Double {
        guard let mc = civ(major), let r = mc.religionName, let csCap = capital(of: cityState), majorityReligion(of: csCap) == r else { return 0 }
        var total = 0.0
        for b in mc.religionBeliefs { for u in rs.beliefs[b]?.uniqueObjects ?? [] where u.pattern == "Resting point for Influence with City-States following this religion []" { total += u.double(0) } }
        return total
    }
    func giftedUnitXP(_ major: Int) -> Int { civUniques(major).filter { $0.pattern == "Military Units gifted from City-States start with [] XP" }.reduce(0) { $0 + $1.int(0) } }
    /// "Militaristic City-States grant units [2] times as fast when you are at war with a common nation"
    func giftSpeedMultiplier(major: Int, cityState: Int) -> Int {
        guard let cs = civ(cityState), let mc = civ(major) else { return 1 }
        var m = 1
        for u in civUniques(major) where u.pattern == "Militaristic City-States grant units [] times as fast when you are at war with a common nation" {
            if !cs.atWarWith.intersection(mc.atWarWith).subtracting([major, cityState]).isEmpty { m = max(m, u.int(0)) }
        }
        return m
    }

    // MARK: religion (Byzantium, eras)
    /// "May choose [1] additional belief(s) of any type when [founding] a religion"
    func extraBeliefs(_ civId: Int, when phase: String) -> Int {
        // Unciv FreeExtraAnyBeliefs + FreeExtraBeliefs (the typed variant counts toward the same extra picks here)
        civUniques(civId).filter { ($0.pattern == "May choose [] additional belief(s) of any type when [] a religion" && $0.param(1) == phase) || ($0.pattern == "May choose [] additional [] beliefs when [] a religion" && $0.param(2) == phase) }.reduce(0) { $0 + $1.int(0) }
    }
    /// Unciv ReligionManager.canGenerateProphet: civInfo.hasUnique(MayNotGenerateGreatProphet) — policies, buildings and beliefs count as well as the era
    func eraForbidsProphets(_ civId: Int) -> Bool {
        guard let civ = civ(civId) else { return false }
        if let era = rs.era(named: civ.eraName), era.uniques.contains("May not generate great prophet equivalents naturally") { return true }
        return civUniques(civId).contains { $0.pattern == "May not generate great prophet equivalents naturally" }
    }

    // MARK: economy (Korea, Netherlands, India, Rome, Inca, policies)
    func techBoostForCapitalBuilding(civId: Int, city: City, building: BuildingDef) {
        // Unciv applyKoreanUnique: `if (!building.isStatRelated(Stat.Science, city)) return` - the building's
        // science in this city or its science percentage, not its Great Scientist points: ours counted those,
        // so the Porcelain Tower (medium t_152) gave Korea a boost Unciv never did.
        guard isStatRelated(building, stat: "Science", city: city) else { return }
        guard civHasUnique(civId, "Receive a tech boost when scientific buildings/wonders are built in capital"), city.isCapital, let ci = civIndex(civId) else { return }
        // Unciv CityConstructions.addFreeBuildings/techBoost: half the median cost of the currently researchable techs
        let costs = researchableTechs(for: civs[ci]).map { Int(techCost($0, for: civs[ci])) }.sorted()
        guard !costs.isEmpty else { return }
        let n = costs.count
        let medianCost = n % 2 == 1 ? Double(costs[n / 2]) : Double(costs[n / 2 - 1] + costs[n / 2]) / 2
        let boost = Int((0.5 * medianCost).rounded())
        addScience(civId: civId, boost)
    }
    /// Netherlands: luxuries that were entirely traded away still give part of their happiness.
    func retainedLuxuryHappiness(_ civId: Int, perLuxury: Double) -> Double {
        let pct = civUniques(civId).filter { $0.pattern == "Retain []% of the happiness from a luxury after the last copy has been traded away" }.reduce(0.0) { $0 + $1.double(0) }
        guard pct > 0 else { return 0 }
        // Unciv "Traded Luxuries": luxury entries from Trade with a negative amount whose resource is no longer in the supply
        let owned = Set(civResourceSupply(civId).keys)
        let tradedAway = detailedCivResources(civId).filter { $0.amount < 0 && $0.origin == "Trade" && rs.resources[$0.resource]?.resourceType == "Luxury" && !owned.contains($0.resource) }.map { $0.resource }
        return Double(tradedAway.count) * perLuxury * pct / 100
    }
    func cityCountUnhappinessMultiplier(_ civId: Int) -> Double {
        var m = 1.0
        for u in civUniques(civId) where u.pattern == "[]% unhappiness from the number of cities" { m *= 1 + u.double(0) / 100 }
        return m
    }
    /// "[-15]% maintenance cost for [all] buildings [in all cities]"
    func buildingMaintenanceMultiplier(city: City, building: String) -> Double {
        var m = 1.0
        for u in cityUniques(city) where u.pattern == "[]% maintenance cost for [] buildings []" && scopeIncludes(u, city: city) {
            if u.param(1).lowercased() == "all" || productionMatches(.building(building), u.param(1)) { m *= 1 + u.double(0) / 100 }
        }
        return max(0, m)
    }
    /// "No Maintenance costs for improvements in [Hill] tiles"
    func improvementMaintenanceFree(_ civId: Int, _ tile: Tile) -> Bool {
        civUniques(civId).contains { $0.pattern == "No Maintenance costs for improvements in [] tiles" && tileMatches(tile, $0.param(0), civId: civId) }
    }
    /// Sweden: "When declaring friendship, both parties gain a [10]% boost to great person generation"
    func friendshipGreatPersonBoost(_ civId: Int) -> Double {
        guard let civ = civ(civId) else { return 0 }
        var pct = 0.0
        for (friend, _) in civ.friendships {
            // Unciv walks `civ.getKnownCivs()` - `!isDefeated() && !isSpectator()`: a friend conquered while the
            // DeclarationOfFriendship flag still runs no longer counts
            guard let f = self.civ(friend), !isDefeated(f), !f.isSpectator else { continue }
            for u in civUniques(civId) + civUniques(friend) where u.pattern == "When declaring friendship, both parties gain a []% boost to great person generation" { pct += u.double(0) }
        }
        return pct
    }
    /// Huns: "Borrows city names from other civilizations in the game" - Unciv CityFounder.borrowCityName: the LAST
    /// unused name of each other living major nation (in civilizations order) as a set, one drawn at random; with those
    /// exhausted, every unused name of the ruleset's major nations not in the game. Ours drew from every unused name of
    /// the other nations, so the Huns' second borrowed city was Valencia where Unciv's was Tenerife.
    func borrowsCityNames(_ civId: Int) -> Bool {
        civUniques(civId).contains(where: { $0.pattern == "\"Borrows\" city names from other civilizations in the game" || $0.pattern == "Borrows city names from other civilizations in the game" })
    }
    func borrowedCityName(for civId: Int) -> String? {
        guard let me = civ(civId) else { return nil }
        let alive = civs.filter { $0.isAlive }
        let used = Set(alive.flatMap { cities(of: $0.id) }.map { $0.name })
        var g = stateBasedRandom("CityFounder.borrowCityName", civId: civId)   // Unciv CityFounder.kt:176
        func distinct(_ names: [String]) -> [String] { var seen = Set<String>(); return names.filter { seen.insert($0).inserted } }
        let aliveMajorNations = alive.filter { $0.isMajor }.map { $0.nation }
        let lastUnused = distinct(alive.filter { $0.isMajor && $0.nation != me.nation }.compactMap { c in c.nationDef?.cities.last(where: { !used.contains($0) }) })
        if !lastUnused.isEmpty { return g.pick(lastUnused) }
        let absent = rs.majorNations.filter { !$0.isCityState && !aliveMajorNations.contains($0.name) }
        let rest = distinct(absent.flatMap { $0.cities.filter { !used.contains($0) } })
        return g.pick(rest)
    }

    // MARK: Maya Long Count (Unciv MayaCalendar / GreatPersonManager)
    static func mayaBaktun(year: Int) -> Int {
        let daysOn30000101BCE = 36000 + 5040 + 240 + 11
        let mayaDays = (year + 3000) * 365 + (year + 3000) / 4 + daysOn30000101BCE
        let totalTuns = mayaDays >= 0 ? mayaDays / 360 : 13 * 20 * 20 + mayaDays / 360
        return totalTuns / 20 / 20
    }
    /// Unciv MayaCalendar.MayaYear: (b'ak'tun, k'atun, tun) for a game year.
    static func mayaParts(year: Int) -> (baktuns: Int, katuns: Int, tuns: Int) {
        let daysOn30000101BCE = 36000 + 5040 + 240 + 11
        let mayaDays = (year + 3000) * 365 + (year + 3000) / 4 + daysOn30000101BCE
        let totalTuns = mayaDays >= 0 ? mayaDays / 360 : 13 * 20 * 20 + mayaDays / 360
        let totalKatuns = totalTuns / 20
        let baktuns = totalKatuns / 20
        return (baktuns, totalKatuns - baktuns * 20, totalTuns - totalKatuns * 20)
    }
    /// Unciv MayaCalendar.yearToMayaDate: baktun.katun.tun in Maya numerals.
    static func mayaDate(year: Int) -> String {
        let daysOn30000101BCE = 36000 + 5040 + 240 + 11
        let mayaDays = (year + 3000) * 365 + (year + 3000) / 4 + daysOn30000101BCE
        let totalTuns = mayaDays >= 0 ? mayaDays / 360 : 13 * 20 * 20 + mayaDays / 360
        let totalKatuns = totalTuns / 20
        let baktuns = totalKatuns / 20, katuns = totalKatuns - baktuns * 20, tuns = totalTuns - totalKatuns * 20
        return "\(baktuns).\(katuns).\(tuns)"
    }
    func longCountUnique(_ civId: Int) -> Unique? { civUniqueFirst(civId, "Receive a free Great Person at the end of every [] (every 394 years), after researching []. Each bonus person can only be chosen once.") }
    func isLongCountActive(_ civId: Int) -> Bool {
        guard let u = longCountUnique(civId), let civ = civ(civId) else { return false }
        return civ.techs.contains(u.param(1))
    }
    func isLongCountDisplay(_ civId: Int) -> Bool { isLongCountActive(civId) && civHasUnique(civId, "Once The Long Count activates, the year on the world screen displays as the traditional Mayan Long Count.") }
    /// Unciv YearTextUtil.toYearText: the Maya date, or "[abs(year)] BC/AD", through tr() - the year's digits through
    /// Number.tr ("MS 1.800" in Turkish, "1,800 AD" in English) as tr() writes a parameter's digit run
    static func yearText(year: Int, usesMayaCalendar: Bool) -> String {
        usesMayaCalendar ? GameState.mayaDate(year: year) : L("[\(abs(year))] " + (year < 0 ? "BC" : "AD"))
    }
    func yearString(for civId: Int) -> String { GameState.yearText(year: year, usesMayaCalendar: isLongCountDisplay(civId)) }
    /// Unciv MayaCalendar.startTurnForMaya: a new b'ak'tun grants a free Great Person from the once-only pool.
    /// Unciv MayaCalendar.startTurnForMaya, called from TurnManager.startTurn when isLongCountActive():
    /// `if (!isNewCycle(year, getYear(-1))) return` - this turn's b'ak'tun against the previous turn's - then
    /// GreatPersonManager.triggerMayanGreatPerson, and an AI (or full autoplay) chooses at once.
    /// Ours kept a `lastBaktun` of its own that started unset, so the turn the Long Count switched on (or the
    /// first turn after loading a save) could never be a new cycle; and the AI's choice waited for our
    /// turn-start retry of the free great people, which Unciv does not have.
    func mayaTurnStart(_ civId: Int) {
        guard isLongCountActive(civId), let ci = civIndex(civId) else { return }
        let baktun = GameState.mayaBaktun(year: year)
        let previous = GameState.mayaBaktun(year: speed.year(forTurn: turn + startTurnOffset - 1))   // Unciv getYear(-1)
        civs[ci].lastBaktun = baktun
        guard baktun != previous else { return }
        // Unciv GreatPersonManager.triggerMayanGreatPerson
        guard !civs[ci].isSpectator else { return }
        if civs[ci].longCountGPPool.isEmpty { civs[ci].longCountGPPool = greatPeopleUnits(civId).map { $0.name } }
        civs[ci].freeGreatPeople += 1
        civs[ci].mayaLimitedFreeGP += 1
        // Unciv: `addNotification(notification, MayaLongCountAction(), NotificationCategory.General, MayaCalendar.notificationIcon)`
        notify(civId, "{A new b'ak'tun has just begun!}\n{A Great Person joins you!}", category: .General, icons: ["MayaCalendar/Maya"], actions: [.mayaLongCount])
        if !civs[ci].isPlayer || autoPlayingFullAI { grantFreeGreatPeopleForAI(civId) }   // Unciv MayaCalendar.kt:90: isAI() || isAutoPlayingAndFullAutoPlayAI() → NextTurnAutomation.chooseGreatPerson
    }

    // MARK: free Great People (Unciv GreatPersonManager.freeGreatPeople + GreatPersonPickerScreen)
    func greatPeopleUnits(_ civId: Int) -> [UnitDef] {
        // Unciv GreatPersonManager.getGreatPeople: every great person mapped to the civ's equivalent unit, minus those hidden by settings
        // `ruleset.units.values` in ruleset order, then `.toHashSet()`: BaseUnit has no hashCode of its own, so under
        // the reference's -XX:hashCode=2 the set walks in insertion order (see JavaHash1Set) - not alphabetically.
        let mapped = rs.unitOrder.compactMap { rs.units[$0] }.filter { $0.isGreatPerson && $0.uniqueTo == nil && $0.name != "Spy" }.map { equivalentUnit(civId, $0) }
            .filter { !($0.canFoundReligion && !religionEnabled) }
        let byName = Dictionary(mapped.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return JavaHash1Set.iterationOrder(mapped.map { $0.name }).compactMap { byName[$0] }
    }
    func freeGreatPersonOptions(_ civId: Int) -> [UnitDef] {
        guard let civ = civ(civId), civ.freeGreatPeople > 0, !cities(of: civId).isEmpty else { return [] }
        let all = greatPeopleUnits(civId)
        if civ.mayaLimitedFreeGP <= 0 { return all }
        return all.filter { civ.longCountGPPool.contains($0.name) }
    }
    /// Unciv GreatPersonManager.chooseFreeGreatPerson: `civInfo.units.addUnit(choice, civInfo.getCapital())` - so a
    /// water great person (the Great Admiral) with an inland capital goes to a random naval city, no capital means a
    /// random city, and the "has been born" notification names the city it was placed in (addUnit sends it). Ours
    /// required a capital, spawned on the capital tile and named the capital. A failed placement spends nothing.
    @discardableResult
    func chooseFreeGreatPerson(_ civId: Int, _ name: String) -> Unit? {
        guard let ci = civIndex(civId), let choice = freeGreatPersonOptions(civId).first(where: { $0.name == name }) else { return nil }
        let useMayaLongCount = civs[ci].mayaLimitedFreeGP > 0
        let cap = capital(of: civId)
        if ProcessInfo.processInfo.environment["DUMP_GPCITY"] != nil {
            print("GPFREEE t=\(turn) \(civ(civId)?.nation ?? "?") gp=\(name) capital=\(cap?.name ?? "-") free=\(civs[ci].freeGreatPeople)")
        }
        guard let unit = unitManagerAddUnit(civId: civId, choice, city: cap) else { return nil }
        civs[ci].freeGreatPeople -= 1
        if useMayaLongCount { civs[ci].mayaLimitedFreeGP -= 1; civs[ci].longCountGPPool.removeAll { $0 == choice.name } }
        return unit
    }
    /// Unciv NextTurnAutomation.chooseGreatPerson - ONE choice per call, as each trigger (OneTimeFreeGreatPerson,
    /// the Maya b'ak'tun) calls it once for the one great person it granted: `greatPeople.random(rng)`, replaced
    /// by the first "Great Person - [Science]" option when there is one, then chooseFreeGreatPerson.
    /// Ours looped while any free great person was left, so an earlier unclaimed one was taken as well.
    func grantFreeGreatPeopleForAI(_ civId: Int) {
        guard let civ = civ(civId), !civ.isPlayer || autoPlayingFullAI else { return }   // what both callers ask first
        let options = freeGreatPersonOptions(civId)
        if options.isEmpty { return }
        // Unciv NextTurnAutomation.kt:354: `civInfo.state.stateBasedRandom("NextTurnAutomation.chooseGreatPerson")`
        var g = stateBasedRandom("NextTurnAutomation.chooseGreatPerson", civId: civId)
        guard var pick = g.pick(options) else { return }
        if let science = options.first(where: { $0.uniques.contains("Great Person - [Science]") }) { pick = science }
        _ = chooseFreeGreatPerson(civId, pick.name)
    }
}

extension UnitDef {
    /// "Can build [Land] improvements on tiles" / "[Water]"
    var improvementFilters: [String] { uniqueObjects.filter { $0.pattern == "Can build [] improvements on tiles" }.map { $0.param(0) } }
    var automationIsPrimaryAction: Bool { uniques.contains("Automation is a primary action") }
    var canMoveImmediatelyOnceBought: Bool { uniques.contains("Can move immediately once bought") }
    var requiredPopulation: Int { uniqueObjects.first { $0.pattern == "Requires at least [] population" }?.int(0) ?? 0 }
    /// "Consumes [2] [Uranium]" – per-turn resource use beyond `requiredResource`.
    var consumedResources: [(String, Int)] { uniqueObjects.filter { $0.pattern == "Consumes [] []" }.map { ($0.param(1), $0.int(0)) } }
    var excessFoodToProduction: Bool { uniques.contains("Excess Food converted to Production when under construction") }
}
