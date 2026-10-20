// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Port of Unciv's core/src/com/unciv/logic/automation/Automation.kt plus the small helpers the
// automation package pulls from Civilization / ThreatManager / BaseUnit / Personality.

enum ThreatLevel: Int, Comparable {
    case veryLow, low, medium, high, veryHigh
    static func < (a: ThreatLevel, b: ThreatLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Unciv RelationshipLevel including Afraid (city-states that would pay tribute).
enum RelationshipLevel: Int, Comparable {
    case unforgivable, enemy, afraid, competitor, neutral, favorable, friend, ally
    static func < (a: RelationshipLevel, b: RelationshipLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Unciv PersonalityValue keys.
enum PersonalityValue: String, CaseIterable {
    case production, food, gold, science, culture, happiness, faith, military, aggressive, declareWar, commerce, diplomacy, loyal, expansion, denounceWillingness
}

extension PersonalityDef {
    subscript(_ v: PersonalityValue) -> Double {
        switch v {
        case .production: return production
        case .food: return food
        case .gold: return gold
        case .science: return science
        case .culture: return culture
        case .happiness: return happiness
        case .faith: return faith
        case .military: return military
        case .aggressive: return aggressive
        case .declareWar: return declareWar
        case .commerce: return commerce
        case .diplomacy: return diplomacy
        case .loyal: return loyal
        case .expansion: return expansion
        case .denounceWillingness: return denounceWillingness
        }
    }
    /// Unciv scaledFocus: 10 → 2, 5 → 1, 0 → 0.
    /// Unciv's personality values and these four are Float, and every step rounds there: 6/5 is 1.2000000477,
    /// not 1.2, so Tokyo's Amphitheater came to 2.0 in Unciv (a tie with the Mint, which the Amphitheater wins
    /// by coming first) and to one ulp under 2.0 in ours (settled, turn 97).
    func scaledFocus(_ v: PersonalityValue) -> Double { Stats.f32(Stats.f32(self[v]) / 5) }
    /// Unciv inverseScaledFocus: 0 → 2, 5 → 1, 10 → 0.
    func inverseScaledFocus(_ v: PersonalityValue) -> Double { Stats.f32(Stats.f32(10 - Stats.f32(self[v])) / 5) }
    func modifierFocus(_ v: PersonalityValue, _ weight: Double) -> Double { Stats.f32(1 + Stats.f32(Stats.f32(scaledFocus(v) - 1) * Stats.f32(weight))) }
    func inverseModifierFocus(_ v: PersonalityValue, _ weight: Double) -> Double { Stats.f32(1 + Stats.f32(Stats.f32(inverseScaledFocus(v) - 1) * Stats.f32(weight))) }
    static func value(forStat stat: String) -> PersonalityValue? {
        switch stat {
        case "Production": return .production
        case "Food": return .food
        case "Gold": return .gold
        case "Science": return .science
        case "Culture": return .culture
        case "Happiness": return .happiness
        case "Faith": return .faith
        default: return nil
        }
    }
    /// Unciv scaleStats
    func scaleStats(_ s: Stats, _ weight: Double) -> Stats {
        // Unciv `stats[it] *= modifierFocus(...)`: a Float product
        func m(_ x: Double, _ v: PersonalityValue) -> Double { Stats.f32(x * modifierFocus(v, weight)) }
        return Stats(food: m(s.food, .food), production: m(s.production, .production), gold: m(s.gold, .gold),
              science: m(s.science, .science), culture: m(s.culture, .culture), happiness: m(s.happiness, .happiness), faith: m(s.faith, .faith))
    }
}

extension Stats {
    /// Unciv `Stats.sum()` folds the seven Float values in declaration order, rounding at every step.
    var sum: Double {
        var t = 0.0
        for v in [food, production, gold, science, culture, happiness, faith] { t = Stats.f32(t + v) }
        return t
    }
    /// Unciv Stats.minus: `clone().apply { add(stats.times(-1)) }` - a Float difference per field.
    static func - (a: Stats, b: Stats) -> Stats {
        Stats(food: f32(a.food - b.food), production: f32(a.production - b.production), gold: f32(a.gold - b.gold), science: f32(a.science - b.science), culture: f32(a.culture - b.culture), happiness: f32(a.happiness - b.happiness), faith: f32(a.faith - b.faith))
    }
    /// Unciv Stats.times(Float): each field times a Float factor, in Float.
    static func * (a: Stats, k: Double) -> Stats {
        let k = f32(k)
        return Stats(food: f32(a.food * k), production: f32(a.production * k), gold: f32(a.gold * k), science: f32(a.science * k), culture: f32(a.culture * k), happiness: f32(a.happiness * k), faith: f32(a.faith * k))
    }
    subscript(_ stat: String) -> Double {
        get {
            switch stat { case "Food": return food; case "Production": return production; case "Gold": return gold; case "Science": return science; case "Culture": return culture; case "Happiness": return happiness; case "Faith": return faith; default: return 0 }
        }
        set {
            switch stat { case "Food": food = newValue; case "Production": production = newValue; case "Gold": gold = newValue; case "Science": science = newValue; case "Culture": culture = newValue; case "Happiness": happiness = newValue; case "Faith": faith = newValue; default: break }
        }
    }
    /// Unciv Stats.applyRankingWeights (Stats.kt): Food 14, Production 12.01 (tie break vs gold), Gold 6, Science 9.01, Culture 8, Happiness 10 (base), Faith 7.
    mutating func applyRankingWeights() {
        // `12.01f` and `9.01f` are not the Doubles that look like them, and production's weight is a
        // deliberate tie-break against gold - so the digits that decide the tie are exactly the ones we lost.
        food = Stats.f32(food * 14); production = Stats.f32(production * Stats.f32(12.01)); gold = Stats.f32(gold * 6)
        science = Stats.f32(science * Stats.f32(9.01)); culture = Stats.f32(culture * 8)
        happiness = Stats.f32(happiness * 10); faith = Stats.f32(faith * 7)
    }
}

extension UnitDef {
    var isMelee: Bool { !isCivilian && !isRanged }
    /// Unciv BaseUnit.isProbablySiegeUnit: ranged, and a positive "[]% Strength" carrying <vs cities>
    /// (ConditionalVsCity only; <vs [City] units> is ConditionalVsUnits) among the BaseUnit's uniques - its own,
    /// the global unit uniques and its type's (rulesetUniqueObjects) - conditionals ignored.
    var isProbablySiegeUnit: Bool {
        isRanged && rulesetUniqueObjects.contains { $0.pattern == "[]% Strength" && $0.int(0) > 0 && $0.conditionals.contains { c in c.pattern == "vs cities" } }
    }
    /// Unciv BaseUnit.hasUnique(SelfDestructs): over rulesetUniqueObjects - the unit's own uniques, the global unit
    /// uniques and its type's - conditionals ignored. The Guided Missile carries it on its Missile unit type only,
    /// which the unit's own list never showed. The automation asks the MapUnit (unitHasUnique), as Unciv does.
    var selfDestructs: Bool { rulesetUniqueObjects.contains { $0.pattern == "Self-destructs when attacking" } }
    var cannotAttack: Bool { uniques.contains("Cannot attack") }
    var canIntercept: Bool { uniqueObjects.contains { $0.pattern == "[]% chance to intercept air attacks" && $0.double(0) > 0 } }
    var hasStrengthBonusInRadius: Bool { uniqueObjects.contains { $0.pattern == "[]% Strength bonus for [] units within [] tiles" } }
    var hasCitadelPlacement: Bool { instantImprovement.map { Ruleset.shared.improvements[$0]?.uniqueObjects.contains { $0.pattern == "Gain control over [] tiles in a []-tile radius" } ?? false } ?? false }
    var canTradeMission: Bool { uniques.contains { $0.hasPrefix("Can undertake a trade mission") } }
    var canHurryTech: Bool { uniques.contains("Can hurry technology research") }
    var canHurryPolicy: Bool { uniques.contains("Can generate a large amount of culture") }   // Unciv CanHurryPolicy
    var canSpeedupConstruction: Bool { uniques.contains { $0.hasPrefix("Can speed up construction of a building") || $0.hasPrefix("Can speed up the construction of a wonder") } }
    var canStartGoldenAge: Bool { uniqueObjects.contains { $0.pattern == "Empire enters a []-turn Golden Age" } }
    var canAddInCapital: Bool { uniqueObjects.contains { $0.pattern == "Can be added to [] in the Capital" } }
    var createsWaterImprovements: Bool { uniques.contains("May create improvements on water resources") }
    var canSpreadReligion: Bool { uniqueObjects.contains { $0.pattern == "Can Spread Religion" } }
    var preventsSpreadingReligion: Bool { uniques.contains("Prevents spreading of religion to the city it is next to") }
    // Unciv BaseUnit.getForceEvaluation lives with BaseUnit (models/ruleset/unit/BaseUnit.swift), in Float.
}

extension Unit {
    var isGreatPersonOfWar: Bool { def.uniqueObjects.contains { $0.pattern == "Great Person - []" && $0.param(0) == "War" } || def.hasStrengthBonusInRadius }
    /// Unciv MapUnit.hasMovement: any movement above zero - the Float crumbs a path leaves behind included
    var hasMovement: Bool { movementLeft > 0 }
}

extension GameState {
    /// Unciv MapUnit.getForceEvaluation: base force × (promotions + 1)^0.3, truncated, then × health / 100
    func unitForceEvaluation(_ u: Unit) -> Int {
        // Unciv UnitPromotions.numberOfPromotions does not count the free ones the unit was built with, which
        // the base evaluation has already taken into account.
        // `(numberOfPromotions + 1).toFloat().pow(0.3f)` and `(baseForce * promotionBonus).toInt()`: Float, as there
        let promotionBonus = Float(pow(Double(Float(u.promotionNumber + 1)), Double(Float(0.3))))
        var power = Int(Float(u.def.forceEvaluation) * promotionBonus)
        power *= u.health
        power /= 100
        return power
    }
    // MARK: - Ranking (Unciv RankingType)

    /// Unciv Civilization.calculateMilitaryMight: force evaluation of all units (water halved), scaled by sqrt(gold)% up to 2×.
    func militaryMight(_ civId: Int) -> Int {
        // Unciv Civilization.getMilitaryMight: `if (cachedMilitaryMight < 0) cachedMilitaryMight = calculate...`.
        // The cache is cleared at the END of that civ's turn and when the world turn records ranking history,
        // never in between - so every reader during a civ's turn sees the strength it had last turn.
        if let c = militaryMightCache[civId] { return c }
        let v = calculateMilitaryMight(civId)
        militaryMightCache[civId] = v
        if GameState.mightProbe && EvLog.game === self {   // MIGHTQ probe: who filled the cache, and when
            print("MIGHTCALC t=\(turn - (barbarianPhase ? 0 : 1)) \(civ(civId)?.nation ?? "?")=\(v) " + Thread.callStackSymbols.dropFirst().prefix(6).map { $0.split(separator: " ").dropFirst(3).first.map(String.init) ?? "?" }.joined(separator: "<"))
        }
        return v
    }
    static let mightProbe = ProcessInfo.processInfo.environment["MIGHTQ"] != nil
    /// Unciv Civilization.resetMilitaryMightCache.
    func resetMilitaryMightCache(_ civId: Int) { militaryMightCache[civId] = nil }
    /// Unciv Civilization.calculateMilitaryMight.
    func calculateMilitaryMight(_ civId: Int) -> Int {
        guard let civ = civ(civId) else { return 1 }
        var sum = 1
        for u in units(of: civId) { sum += u.def.isWater ? unitForceEvaluation(u) / 2 : unitForceEvaluation(u) }
        // `sqrt(max(0f, gold.toFloat())).toPercent()` and `(sum * min(goldBonus, 2f)).toInt()`: Float, as there.
        // Kotlin's sqrt(Float) is Math.sqrt(double).toFloat(); toPercent is `1 + this/100` in Float; Int*Float
        // is a Float product truncated by toInt. In Double, gold=16 sum=225 gave 234 where Unciv gets 233.
        let g = Float(max(0, civ.gold))
        let goldBonus: Float = 1 + Float(sqrt(Double(g))) / 100
        return Int(Float(sum) * min(goldBonus, Float(2)))
    }
    /// Unciv Civilization.getStatForRanking(RankingType.Production) = `stats.statsForNextTurn.production.roundToInt()`
    /// - the STORED civilization figure, rounded, not a fresh walk over the cities. Ours summed every city's
    /// production on every call, which is both a different number (it misses nothing today, but it is computed
    /// at a different moment) and the expensive way to ask.
    func productionRanking(_ civId: Int) -> Int {
        let p = civ(civId)?.statsForNextTurn?.production ?? statMapForNextTurn(civId).reduce(Stats()) { ($0 + $1.1).f32 }.production
        return Stats.roundToInt(p)   // Kotlin Float.roundToInt: half up (-2.5 -> -2), not away from zero
    }
    func scoreRanking(_ civId: Int) -> Int { civ(civId).map { score($0) } ?? 0 }
    func isAtWarAtAll(_ civId: Int) -> Bool { civ(civId)?.atWarWith.contains { self.civ($0).map { !$0.isBarbarian && $0.isAlive } ?? false } ?? false }   // Unciv isAtWar(): a war with a defeated civ does not count
    /// Unciv Civilization.getCivsAtWarWith walks `diplomacy.values`, whose order is fixed for a given set of
    /// civs. Walking our atWarWith Set gave a different order on every launch, and the callers are order-sensitive:
    /// offerPeaceTreaty budgets the gold inside the loop, and automateUnitsAI spends units on the first besieged
    /// city it reaches. Same fix as knownCivs below.
    func civsAtWarWith(_ civId: Int) -> [Civilization] {
        let atWar = civ(civId)?.atWarWith ?? []
        return civs.filter { atWar.contains($0.id) && $0.isAlive && !$0.isBarbarian }
    }
    /// Unciv Civilization.getKnownCivs walks its diplomacy map, whose order is fixed for a given set of civs.
    /// Walking our metCivs Set instead gave a different order on every launch.
    /// Records that civ at index `i` has now met `other`, keeping the order Unciv's `diplomacy` map was
    /// filled in. Returns false when they had already met, the way `Set.insert(_:).inserted` did.
    @discardableResult
    func meet(_ i: Int, _ other: Int) -> Bool {
        guard civs[i].metCivs.insert(other).inserted else { return false }
        civs[i].metOrder.append(other)
        // Unciv DiplomacyManager(civInfo, otherCiv) - the meeting's constructor - starts both smoothed opinions at 0f (the
        // no-arg constructor a load uses keeps OLD_SAVEFILE_INITIAL_SMOOTHED_OPINION); reading ours as `?? 0` was the same
        // to the AI, but a game exported after a meeting left them out and Unciv read -250 back
        civs[i].smoothedOpinion[other] = 0
        civs[i].cachedSmoothedOpinion[other] = 0
        return true
    }

    /// The bucket `java.util.HashMap` puts a key in: `(h ^ (h >>> 16)) & (capacity - 1)`, over the same
    /// `javaStringHash` the diplomacy rolls already use.
    func javaBucket(_ key: String, capacity: Int) -> Int {
        let h = UInt32(bitPattern: javaStringHash(key))
        return Int((h ^ (h >> 16)) & UInt32(capacity - 1))
    }

    /// Unciv `Civilization.getKnownCivs()` walks `diplomacy.values`, and `diplomacy` is a plain
    /// `HashMap<String, DiplomacyManager>` keyed by the civ's NAME - not a LinkedHashMap. So the order is the
    /// JVM's: bucket by bucket, and inside a bucket in the order the entries were put in. Ours walked the
    /// global civ array in id order, and every stable sort over the known civs - the espionage target list,
    /// the trade partner loop, the wonder's technology-ranking penalty - broke its ties by that instead.
    ///
    /// Measured against the reference on `t_45`, seventeen turns in: it lists Byzantium's known civs as
    /// [Carthage, Japan] and we listed [Japan, Carthage]. Carthage hashes into bucket 0, Japan into 6 and
    /// Byzantium into 8, which reproduces all three civs' lists exactly, collisions included.
    ///
    /// The capacity is the one the map grew to: 16 until a thirteenth entry, then doubling. Unciv's map also
    /// holds the Spectator, which `getKnownCivs` then filters out, so it counts towards the size.
    /// The ids of every civ this one has diplomacy with, in the order `diplomacy.values` walks them.
    /// `TurnManager` iterates exactly this (`civInfo.diplomacy.values.toList().forEach { it.nextTurn() }`),
    /// and so does the city-state's relationship update - not just `getKnownCivs`.
    func diplomacyOrder(_ civId: Int) -> [Int] {
        guard let me = civ(civId) else { return [] }
        // The map's size: our met civs, plus the Spectator when the game has one and our list does not hold it
        // already (an imported save's diplomacy does). Counting it twice grew a twelve-entry map to 32 buckets.
        let spectator = civs.first { $0.isSpectator }?.id
        let size = me.metCivs.count + (spectator.map { !me.metCivs.contains($0) && $0 != civId } ?? false ? 1 : 0)
        var capacity = 16
        while size > capacity * 3 / 4 { capacity <<= 1 }
        var insertion: [Int: Int] = [:]
        for (n, id) in me.metOrder.enumerated() { insertion[id] = n }
        return me.metCivs
            .map { ($0, javaBucket(civ($0)?.nation ?? "", capacity: capacity), insertion[$0] ?? Int.max) }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .map { $0.0 }
    }

    func knownCivs(_ civId: Int) -> [Civilization] {
        diplomacyOrder(civId).compactMap { civ($0) }.filter { $0.isAlive && !$0.isBarbarian }
    }
    /// Unciv Civilization.getPersonality: the nation's personality belongs to an AI (or a civ being auto-played);
    /// a human answers with the neutral one, all fives.
    func personality(of civId: Int) -> PersonalityDef {
        guard let c = civ(civId) else { return .neutral }
        if isAIOrAutoPlaying(c.id) { return rs.personality(for: c.nationDef) }
        if GameState.evlogOn && !c.isSpectator { hbr("S9.neutralPersonality", c.id) }
        return .neutral
    }
    /// Unciv Civilization.getPreferredVictoryTypes: a lone enabled victory wins; else the nation's and personality's choices that are enabled; else Neutral.
    func preferredVictoryTypes(_ civId: Int) -> [String] {
        let enabled = settings.victoryTypes
        if enabled.count == 1, let only = enabled.first { return [only] }
        let names = Set(rs.victories.map { $0.name })
        let picks = [civ(civId)?.nationDef?.preferredVictoryType ?? "Neutral", personality(of: civId).preferredVictoryType].filter { enabled.contains($0) && names.contains($0) }
        return picks.isEmpty ? ["Neutral"] : picks
    }
    func isHuman(_ civId: Int) -> Bool { civ(civId)?.isPlayer ?? false }
    /// Unciv TechManager.allTechsAreResearched (updateTransientBooleans): every technology is either researched - a
    /// continually researchable one (Future Tech) counts once it is in techsResearched - or cannot be researched now.
    /// Ours asked "is nothing researchable?", which Future Tech never lets be true: fresh turn 282, Paris and Orleans
    /// kept converting production to Science where Unciv, all techs done, turned to Gold.
    func allTechsResearched(_ civId: Int) -> Bool {
        guard let civ = civ(civId) else { return false }
        let researchable = Set(researchableTechs(for: civ).map { $0.name })   // Unciv canBeResearched
        return rs.techs.values.allSatisfy { civ.techs.contains($0.name) || !researchable.contains($0.name) }
    }

    // MARK: - Diplomacy flags (Unciv DiplomacyFlags / DiplomacyManager.flagsCountdown)
    func hasFlag(_ civId: Int, _ other: Int, _ flag: String) -> Bool { civ(civId)?.diploFlags[other]?[flag] != nil }
    func flag(_ civId: Int, _ other: Int, _ flag: String) -> Int { civ(civId)?.diploFlags[other]?[flag] ?? 0 }
    func setFlag(_ civId: Int, _ other: Int, _ flag: String, _ turns: Int) { if let i = civIndex(civId) { civs[i].diploFlags[other, default: [:]][flag] = turns } }
    func removeFlag(_ civId: Int, _ other: Int, _ flag: String) { if let i = civIndex(civId) { civs[i].diploFlags[other]?[flag] = nil } }
    func smoothedOpinionDelta(_ civId: Int, _ other: Int) -> Double { opinion(of: civId, toward: other) - (civ(civId)?.smoothedOpinion[other] ?? 0) }

    // MARK: - ThreatManager
    /// Unciv ThreatManager.doesTileHaveMilitaryEnemy
    func tileHasMilitaryEnemy(_ c: HexCoord, for civId: Int) -> Bool {
        guard let civ = civ(civId), civ.explored.contains(c) else { return false }
        if let city = city(at: c), areAtWar(civId, city.civId) { return true }
        let here = units(at: c)
        if here.isEmpty || !visibleTiles(for: civId).contains(c) { return false }   // Unciv: units only count on visible tiles
        // Unciv ThreatManager.tileHasMilitaryEnemy → MapUnit.isInvisible(to:): an undetected submarine is not a
        // threat we can react to. The old test measured the unit's distance to its own tile, which is always zero.
        return here.contains { $0.isMilitary && areAtWar(civId, $0.civId) && (!$0.def.isInvisible || canSeeInvisibleUnit($0, from: civId)) }
    }
    /// Unciv TileMap.forEachTileAtDistance(origin, d): the ring at exactly d, in getTilesAtDistance's order (from
    /// 6 o'clock, each tile followed by its mirror; ring 1 is Tile.neighbors, the same walk).
    func tilesAtDistanceUncivOrder(_ c: HexCoord, _ d: Int) -> [HexCoord] {
        guard d > 0 else { return map.contains(map.normalize(c)) ? [map.normalize(c)] : [] }
        var out: [HexCoord] = []
        var q = 0, r = d
        for (dq, dr) in [(-1, 0), (0, -1), (1, -1)] {
            for _ in 0..<d {
                for raw in [HexCoord(c.q + q, c.r + r), HexCoord(c.q - q, c.r - r)] {
                    let n = map.normalize(raw)
                    if map.contains(n) { out.append(n) }
                }
                q += dq; r += dr
            }
        }
        return out
    }

    /// Unciv ThreatManager.getDistanceToClosestEnemyUnit, with its per-civ, per-tile cache - which is cleared only
    /// in TurnManager.startTurn, so within a civ's turn the answer goes stale on purpose: an enemy our own units
    /// reveal inside rings already searched is not seen, and a "none within N" stays true. Ours searched live on
    /// every call, and read enemies Unciv's AI does not know it has seen yet.
    func distanceToClosestEnemyUnit(_ c: HexCoord, civId: Int, maxDist: Int, takeLargerValues: Bool = true) -> Int {
        let tileData = threatManagerCache[civId]?[c]
        // Needs to be a high value, but not the max value so we can still add to it (NextTurnAutomation sorting)
        let notFoundDistance = takeLargerValues ? 500000 : maxDist
        var minDistanceToSearch = 1
        if let data = tileData {
            // The tiles where we previously found an enemy: the first one still valid must be the closest
            while let first = data.tilesWithEnemies.first {
                if tileHasMilitaryEnemy(first.tile, for: civId) { return takeLargerValues ? first.distance : min(first.distance, maxDist) }
                data.tilesWithEnemies.removeFirst()   // this tile is no longer valid
            }
            // Already searched past the range we want and found nothing
            if data.distanceSearched > maxDist { return takeLargerValues ? notFoundDistance : maxDist }
            minDistanceToSearch = max(1, data.distanceSearched + 1)   // only the rings not searched yet
        }
        if minDistanceToSearch <= maxDist {
            for i in minDistanceToSearch...maxDist {
                var found: [(tile: HexCoord, distance: Int)] = []
                for t in tilesAtDistanceUncivOrder(c, i) where tileHasMilitaryEnemy(t, for: civId) { found.append((t, i)) }
                if !found.isEmpty { threatManagerCache[civId, default: [:]][c] = ThreatClosestEnemyTileData(i, found); return i }
            }
        }
        threatManagerCache[civId, default: [:]][c] = ThreatClosestEnemyTileData(maxDist, [])
        return notFoundDistance
    }

    /// Unciv ThreatManager.getTilesWithEnemyUnitsInDistance: reuses and extends the same cache entry.
    func tilesWithEnemyUnitsInDistance(_ c: HexCoord, civId: Int, maxDist: Int) -> [HexCoord] {
        let tileData = threatManagerCache[civId]?[c]
        var tilesWithEnemies: [HexCoord] = []
        var dataList: [(tile: HexCoord, distance: Int)] = tileData?.tilesWithEnemies ?? []
        if let data = tileData {
            var kept: [(tile: HexCoord, distance: Int)] = []
            for (idx, e) in dataList.enumerated() {
                // Kotlin returns from inside the iterator: the removals made so far persist, the rest stays
                if e.distance > maxDist { data.tilesWithEnemies = kept + Array(dataList[idx...]); return tilesWithEnemies }
                if tileHasMilitaryEnemy(e.tile, for: civId) { tilesWithEnemies.append(e.tile); kept.append(e) }
            }
            data.tilesWithEnemies = kept
            dataList = kept
            if maxDist <= data.distanceSearched { return tilesWithEnemies }
        }
        let minDistanceToSearch = max(0, tileData?.distanceSearched ?? 0) + 1
        if minDistanceToSearch <= maxDist {
            for i in minDistanceToSearch...maxDist {
                for t in tilesAtDistanceUncivOrder(c, i) where tileHasMilitaryEnemy(t, for: civId) { tilesWithEnemies.append(t); dataList.append((t, i)) }
            }
        }
        if let data = tileData { data.tilesWithEnemies = dataList; data.distanceSearched = max(data.distanceSearched, maxDist) }
        else { threatManagerCache[civId, default: [:]][c] = ThreatClosestEnemyTileData(maxDist, dataList) }
        return tilesWithEnemies
    }
    func enemyUnitsOnTiles(_ tiles: [HexCoord], civId: Int) -> [Unit] {
        tiles.flatMap { units(at: $0) }.filter { $0.isMilitary && areAtWar(civId, $0.civId) }
    }
    /// Unciv ThreatManager.getDangerousTiles: tiles enemy units can strike, city bombardment reach, damaging terrain.
    func dangerousTiles(for unit: Unit, distance: Int = 3) -> Set<HexCoord> { Set(dangerousTilesInUncivOrder(for: unit, distance: distance)) }
    /// Unciv ThreatManager.getDangerousTiles: `(tilesInRangeOfAttack + tilesWithinBombardmentRange + tilesWithTerrainDamage)
    /// .toHashSet()` - a HashSet<Tile>, which under the reference's identity hash 1 walks as JavaHash1Set does over
    /// that list (duplicates and all count toward the capacity Kotlin sizes it with).
    func dangerousTilesInUncivOrder(for unit: Unit, distance: Int = 3) -> [HexCoord] {
        let enemyTiles = tilesWithEnemyUnitsInDistance(unit.coord, civId: unit.civId, maxDist: distance)
        var list: [HexCoord] = []
        for e in enemyUnitsOnTiles(enemyTiles, civId: unit.civId) { list += map.tilesWithin(e.coord, radius: max(1, attackRange(e))) }
        for t in enemyTiles { if let city = city(at: t), areAtWar(unit.civId, city.civId) { list += map.tilesWithin(t, radius: rs.constants.baseCityBombardRange) } }
        for t in map.tilesWithin(unit.coord, radius: distance) where damageFromTerrain(unit, at: t) > 0 { list.append(t) }
        return JavaHash1Set.iterationOrder(list, initialCapacity: JavaHash1Set.kotlinCollectionCapacity(list.count))
    }
    /// Unciv UnitAutomation.getDangerousTiles (movement + range aware version used for civilians).
    func dangerousTilesForCivilian(_ unit: Unit) -> Set<HexCoord> {
        var out: Set<HexCoord> = []
        for t in map.tilesWithin(unit.coord, radius: 3) {
            for e in units(at: t) where areAtWar(unit.civId, e.civId) {
                if ProcessInfo.processInfo.environment["DANGERX"] != nil {
                    let p = uncivPosition(e.coord), u0 = uncivPosition(unit.coord)
                    print("DANGERX t=\(turn) for=\(unit.name)@\(u0.x),\(u0.y) enemy=\(e.name)@\(p.x),\(p.y) mov=\(maxMovement(of: e)) range=\(attackRange(e)) radius=\((Int(maxMovement(of: e)) - 1) + attackRange(e))")
                }
                out.formUnion(map.tilesWithin(e.coord, radius: (Int(maxMovement(of: e)) - 1) + attackRange(e)))
            }
            if let city = city(at: t), areAtWar(unit.civId, city.civId) { out.formUnion(map.tilesWithin(t, radius: rs.constants.baseCityBombardRange)) }
        }
        for t in map.tilesWithin(unit.coord, radius: 3) where damageFromTerrain(unit, at: t) > 0 { out.insert(t) }
        if ProcessInfo.processInfo.environment["DANGERX"] != nil {
            let u0 = uncivPosition(unit.coord)
            let enemies = map.tilesWithin(unit.coord, radius: 3).flatMap { units(at: $0) }.filter { areAtWar(unit.civId, $0.civId) }.count
            let cityCentres = map.tilesWithin(unit.coord, radius: 3).compactMap { city(at: $0) }.filter { areAtWar(unit.civId, $0.civId) }.map { c -> String in let p = uncivPosition(c.coord); return "\(c.name)@\(p.x),\(p.y)" }
            let terrain = map.tilesWithin(unit.coord, radius: 3).filter { damageFromTerrain(unit, at: $0) > 0 }.count
            print("DANGERN t=\(turn) \(unit.name)@\(u0.x),\(u0.y) n=\(out.count) enemies=\(enemies) cities=\(cityCentres) terrain=\(terrain)")
        }
        return out
    }
    /// Unciv City.neighboringCities: cities whose centre our civ has explored, within 12 tiles
    func neighboringCities(of city: City) -> [City] {
        // Unciv City.neighboringCities: `by lazy`, so this is computed once per city and never refreshed.
        // A city destroyed since stays in the list, as the dead City object stays in Unciv's (see destroyedCitySnapshots).
        if let ids = neighboringCitiesCache[city.id] { return ids.compactMap { id in cities.first { $0.id == id } ?? destroyedCitySnapshots[id] } }
        guard let owner = civ(city.civId) else { return [] }
        // Unciv `civ.gameInfo.getCities()` is `civilizations.flatMap { it.cities }`: grouped by civ, each in its own order
        let found = civs.flatMap { cities(of: $0.id) }.filter { $0.id != city.id && owner.explored.contains($0.coord) && $0.coord.distance(to: city.coord) <= 12 }
        neighboringCitiesCache[city.id] = found.map { $0.id }
        return found
    }
    /// Unciv ThreatManager.getNeighboringCitiesOfOtherCivs
    func neighboringCitiesOfOtherCivs(_ civId: Int) -> [(City, City)] {
        cities(of: civId).flatMap { ours in neighboringCities(of: ours).filter { $0.civId != civId }.map { (ours, $0) } }
    }
    func neighboringCivilizations(_ civId: Int) -> Set<Int> {
        guard let civ = civ(civId) else { return [] }
        return Set(neighboringCitiesOfOtherCivs(civId).map { $0.1.civId }.filter { civ.metCivs.contains($0) })
    }
    func combinedForceOfWarringCivs(_ civId: Int) -> Int { civsAtWarWith(civId).reduce(0) { $0 + militaryMight($1.id) } }

    /// Unciv NextTurnAutomation.getForeignCityNearCapital
    func foreignCityNearCapital(of civId: Int, foreignCiv: Int) -> (city: City, distance: Int)? {
        guard let cap = cities(of: civId).first(where: { $0.isCapital }) else { return nil }   // Unciv: no capital, no target
        var best: (City, Int)? = nil
        for c in cities(of: foreignCiv) { let d = c.coord.distance(to: cap.coord); if best == nil || d < best!.1 { best = (c, d) } }
        return best.map { (city: $0.0, distance: $0.1) }
    }
    func canSeeResource(_ res: String?, civId: Int) -> Bool {
        guard let r = res, let def = rs.resources[r] else { return false }
        if let rev = def.revealedBy { return civ(civId)?.techs.contains(rev) ?? false }
        return true
    }
    /// Unciv UnitMovement.canReach: is there any path at all. Connectivity only (no costs), computed once per movement class
    /// per turn as connected components of the tiles the unit may enter, so every unit of a civ shares one flood fill.
    /// Unciv UnitMovement.canReach: an air unit answers from this turn's range, everyone else is asked the path
    /// finder itself - `getShortestPath(destination).any()`.
    ///
    /// We had a connected-components flood fill here instead, because asking the path finder was slow. It was
    /// never the same question. The flood fill answers "is the destination on the same landmass"; the path
    /// finder answers "is there a route". Measured on the `fresh` fixture at turn 44: a Greek settler on
    /// (-9,-1) was offered (-9,-3) as somewhere to explore because the flood fill said reachable, walked the
    /// path finder, got an empty path, and stood still for the whole turn. Unciv's settler, asked the real
    /// question, discarded that tile, took the next one and moved - and from there the two games were a turn
    /// apart for the rest of the run.
    /// Unciv UnitMovement.canReach → canReachCommon: a unit that cannot move reaches only its own tile, an air unit
    /// by range, everything else by getShortestPath - its own tile included, which goes through the "no neighbour
    /// is passable" test and the pathfinding cache like any other destination.
    func canReach(_ unit: Unit, _ target: HexCoord) -> Bool {
        if unitCannotMove(unit) { return unit.coord == target }
        if unit.def.isAir { return unit.coord == target || canReachInCurrentTurn(unit, target) }
        return !shortestPath(unit, to: target).isEmpty
    }
    /// Tiles within `radius` of any enemy unit (at war with `civId`), computed once per turn/unit count and shared by every explorer.
    func enemyProximityTiles(civId: Int, radius: Int) -> Set<HexCoord> {
        let key = ProximityKey(turn: turn, unitCount: units.count, civId: civId, radius: radius)
        if let cached = enemyProximityCache[key] { return cached }
        var out: Set<HexCoord> = []
        for u in units where u.isMilitary && u.civId != civId && areAtWar(civId, u.civId) { for c in map.tilesWithin(u.coord, radius: radius) { out.insert(c) } }
        if enemyProximityCache.keys.contains(where: { $0.turn != turn }) { enemyProximityCache = enemyProximityCache.filter { $0.key.turn == turn } }
        enemyProximityCache[key] = out
        return out
    }
    /// Any enemy unit or city (we are at war with) within `dist` tiles – cheap pre-check before expensive attack scans.
    func anyEnemyWithin(_ c: HexCoord, civId: Int, dist: Int) -> Bool {
        for u in units where areAtWar(civId, u.civId) && u.coord.distance(to: c) <= dist { return true }
        for city in cities where areAtWar(civId, city.civId) && city.coord.distance(to: c) <= dist { return true }
        return false
    }
    /// Unciv MapUnit.getDamageFromTerrain – no damaging terrain in this ruleset unless Fallout-like "Units ending their turn on this terrain take [] damage".
    func damageFromTerrain(_ unit: Unit, at c: HexCoord) -> Int {
        guard let t = map[c] else { return 0 }
        var dmg = 0
        // Unciv: tile.allTerrains.sumOf { damagePerTurn } — base + dogal harika + feature
        for name in [t.baseTerrain] + (t.naturalWonder.map { [$0] } ?? []) + t.features { for u in rs.terrains[name]?.uniqueObjects ?? [] where u.pattern == "Units ending their turn on this terrain take [] damage" { dmg += u.int(0) } }
        return dmg
    }
    /// Unciv MapUnit.getHealAmountForCurrentTile
    func healAmountForCurrentTile(_ unit: Unit) -> Int {
        if isEmbarked(unit) || unit.health >= 100 { return 0 }
        if (unit.promotionUniques + civUniques(unit.civId)).contains(where: { $0.pattern == "Can only heal by pillaging" }) { return 0 }
        return rankTileForHealing(unit, unit.coord, noTerrainDamage: true)
    }
    /// Unciv MapUnit.rankTileForHealing
    func rankTileForHealing(_ unit: Unit, _ c: HexCoord, noTerrainDamage: Bool = false) -> Int {
        guard let t = map[c] else { return 0 }
        let friendly = isFriendlyTerritory(c, for: unit.civId)
        let uniques = unit.promotionUniques + civUniques(unit.civId)
        let canMoveOnWater = unit.promotionUniques.contains { $0.pattern == "May travel on Water tiles without embarking" }
        let transported = unit.isTransported   // Unciv MapUnit.isTransported
        var healing: Int
        if t.isCityCenter { healing = 25 }
        else if t.isWater && friendly && (unit.def.isWater || transported) { healing = 20 }   // Water unit on friendly water
        else if t.isWater && friendly && canMoveOnWater { healing = 20 }
        else if t.isWater { healing = 0 }
        else if friendly { healing = 20 }
        else { healing = 10 }
        let mayHeal = healing > 0 || (t.isWater && uniques.contains { $0.pattern == "May heal outside of friendly territory" })
        if !mayHeal { return healing }
        // Unciv getMatchingUniques(Heal, checkCivInfoUniques = true) reads cache.state: the unit's OWN tile, not the ranked one
        let ctx = UniqueContext(civId: unit.civId, unit: unit, tile: map[unit.coord])
        for u in uniques where u.pattern == "[] HP when healing" && conditionalsHold(u, ctx) { healing += u.int(0) }
        // The first city within 1 tile with "[] Units adjacent to this city heal [] HP per turn when healing" heals our or allied units
        if let healingCity = map.tilesWithin(c, radius: 1).compactMap({ city(at: $0) }).first(where: { hc in cityUniques(hc).contains { $0.pattern == "[] Units adjacent to this city heal [] HP per turn when healing" } }) {
            let owner = healingCity.civId
            let isAlly = owner == unit.civId || (civ(owner)?.isCityState == true && ally(of: owner) == unit.civId) || (civ(unit.civId)?.isCityState == true && ally(of: unit.civId) == owner)
            for u in cityUniques(healingCity) where u.pattern == "[] Units adjacent to this city heal [] HP per turn when healing" && unitMatches(unit, u.param(0)) && isAlly { healing += u.int(1) }
        }
        // The best "All adjacent units heal [] HP when healing" of our units next to the unit's current tile
        let adjacent = map.neighbors(of: unit.coord).flatMap { units(at: $0) }.filter { $0.civId == unit.civId }
            .map { a in a.promotionUniques.filter { $0.pattern == "All adjacent units heal [] HP when healing" }.reduce(0) { $0 + $1.int(0) } }
        if let best = adjacent.max() { healing += best }
        if noTerrainDamage { return healing }
        return healing - damageFromTerrain(unit, at: c)
    }

    // MARK: - Automation.kt

    /// Unciv Automation.rankStatsValue
    func rankStatsValue(_ stats: Stats, civId: Int) -> Double {
        // Unciv accumulates this in a Float, one `rank +=` at a time, and `1.2f` is not 1.2. Ours summed
        // five of the terms in one Double expression, so both the rounding and the number of roundings were
        // different - and this is the value every tile and every building is finally judged by.
        var rank = 0.0
        rank = Stats.f32(rank + Stats.f32(stats.food * Stats.f32(1.2)))
        let civ = civ(civId)
        rank = Stats.f32(rank + ((civ != nil && civ!.gold < 0 && netGoldPerTurn(civId) <= 0) ? stats.gold : Stats.f32(stats.gold / 3)))
        rank = Stats.f32(rank + stats.happiness)
        rank = Stats.f32(rank + stats.production)
        rank = Stats.f32(rank + stats.science)
        rank = Stats.f32(rank + stats.culture)
        rank = Stats.f32(rank + stats.faith)
        return rank
    }
    /// Unciv Automation.rankTile (any purpose except city expansion)
    func rankTileAI(_ c: HexCoord, civId: Int) -> Double {
        guard let t = map[c] else { return 0 }
        if let o = t.ownerCivId, o != civId { return 0 }
        // Float again: `0.5f`, `0.6f` and `1.1f` are not the Doubles that look like them.
        // Unciv Automation.rankTile: `tile.stats.getTileStats(null, civInfo)` - NO city. A city's own
        // "[+1 Food] from [Wheat] tiles" style uniques do not count here, and ours passed the owning city, so
        // every improved tile inside our borders ranked higher for us than it does for the reference.
        var rank = rankStatsValue(tileStats(t, civId: civId, city: nil), civId: civId)
        if t.improvement == nil { rank = Stats.f32(rank + Stats.f32(0.5)) }
        if t.pillaged || t.roadPillaged { rank = Stats.f32(rank + Stats.f32(0.6)) }
        if canSeeResource(t.resource, civId: civId), let r = t.resource.flatMap({ rs.resources[$0] }) {
            if r.resourceType != "Bonus" { rank = Stats.f32(rank + 1) }
            if t.improvement == nil { rank = Stats.f32(rank + 1) }
            if t.pillaged || t.roadPillaged { rank = Stats.f32(rank + Stats.f32(1.1)) }
        }
        return rank
    }
    /// Unciv Automation.threatAssessment
    func threatAssessment(_ assessor: Int, _ assessed: Int) -> ThreatLevel {
        // Unciv: `Int / Int.toFloat()` - a Float ratio, compared with the Float constants (1 / 1.5f included).
        let ratio = Float(militaryMight(assessed)) / Float(max(1, militaryMight(assessor)))
        if ratio > 2 { return .veryHigh }
        if ratio > Float(1.5) { return .high }
        if ratio < Float(0.5) { return .veryLow }
        if ratio < 1 / Float(1.5) { return .low }
        return .medium
    }
    /// Unciv Automation.afraidOfBarbarians
    func afraidOfBarbarians(_ civId: Int) -> Bool {
        guard let civ = civ(civId), !civ.isCityState, !civ.isBarbarian, settings.barbarians else { return false }
        // Unciv: speed.barbarianModifier and the multiplier are Float, every comparison is Int against Float.
        let barbMod = Float(speed.barbarianModifier)
        if Float(uncivTurns) > 200 * barbMod { return false }   // Unciv gameInfo.turns
        var multiplier: Float = settings.ragingBarbarians ? 1.3 : 1
        if Float(uncivTurns) > 120 * barbMod * multiplier { multiplier /= 2 }
        if cities(of: civId).isEmpty || Float(units(of: civId).count) >= 4 * multiplier { return false }
        // Continent size check: the visible area compared to the capital's continent.
        // Unciv: `tileMap.assignContinents(Ensure)`, then `continentSizes[capital.getCenterTile().getContinent()]` -
        // the sizes of the ids stored at map generation, before the natural wonders, so a wonder tile still counts
        // and a mountain never does. No size (a capital off every continent) skips the check.
        if let cap = capital(of: civId) {
            if map.continentSizes.isEmpty { map.assignContinents(.ensure) }   // Unciv tileMap.assignContinents(Ensure)
            let startingContinent = continentId(of: cap.coord)
            if let startingContinentSize = map.continentSizes[startingContinent],
               Float(startingContinentSize) < Float(visibleTiles(for: civId).count) * multiplier { return false }
        }
        return true
    }
    /// Unciv GameInfo.spaceResources: resources needed by spaceship parts
    func spaceResources() -> Set<String> {
        var out: Set<String> = []
        let ctx = UniqueContext(civId: -1)
        for u in rs.units.values where u.isSpaceshipPart { out.formUnion(resourceRequirementsPerTurn(requiredResource: u.requiredResource, uniques: u.uniqueObjects, ctx: ctx).keys) }
        for b in rs.buildings.values where b.uniques.contains("Spaceship part") { out.formUnion(resourceRequirementsPerTurn(requiredResource: b.requiredResource, uniques: b.uniqueObjects, ctx: ctx).keys) }
        for v in rs.victories { out.formUnion(v.requiredSpaceshipParts) }   // Unciv GameInfo.setTransients: parca ADLARI da spaceResources icinde
        return out
    }
    /// Unciv CivInfoTransientCache.lastEraResourceUsedForBuilding / ForUnit: the latest era of the civ's own buildings and units needing a strategic resource
    func lastEraResourceUsed(_ civId: Int, _ resource: String) -> (building: Int?, unit: Int?) {
        guard let civ = civ(civId), rs.resources[resource]?.resourceType == "Strategic" else { return (nil, nil) }
        let ctx = UniqueContext(civId: civId)
        func era(_ tech: String?) -> Int { tech.flatMap { rs.techs[$0]?.era }.map { rs.eraIndex($0) } ?? 0 }
        let b = rs.availableBuildingDefs(for: civ.nation).filter { resourceRequirementsPerTurn(requiredResource: $0.requiredResource, uniques: $0.uniqueObjects, ctx: ctx)[resource] != nil }.map { era($0.requiredTech) }.max()
        let u = rs.availableUnitDefs(for: civ.nation).filter { resourceRequirementsPerTurn(requiredResource: $0.requiredResource, uniques: $0.uniqueObjects, ctx: ctx)[resource] != nil }.map { era($0.requiredTech) }.max()
        return (b, u)
    }
    /// Unciv Automation.allowSpendingResource: reserve 2 for the spaceship, then keep units and buildings from using more than half each
    func allowSpendingResource(_ civId: Int, unit: UnitDef?, building: BuildingDef?, city: City? = nil) -> Bool {
        guard let civ = civ(civId) else { return false }
        if civ.isCityState { return true }
        let space = spaceResources()
        if space.contains(unit?.name ?? building?.name ?? "") { return true }   // Unciv compares the construction name with the space resources
        let required: [String: Int]
        if let u = unit { required = resourceRequirementsPerTurn(requiredResource: u.requiredResource, uniques: u.uniqueObjects, ctx: UniqueContext(civId: civId)) }
        else if let b = building { required = resourceRequirementsPerTurn(requiredResource: b.requiredResource, uniques: b.uniqueObjects, ctx: UniqueContext(civId: civId, city: city)) }
        else { return true }
        if required.isEmpty { return true }
        let counts = resourceCounts(civId)
        let eraNumber = rs.eraIndex(civ.eraName)
        let detailed = detailedCivResources(civId)
        for (resource, amount) in required.sorted(by: { $0.key < $1.key }) {
            var futureForUnits = 0, futureForBuildings = 0
            for c in cities(of: civId) {
                switch c.currentProduction {
                case .building(let bn)?: if let bd = rs.buildings[bn] { futureForBuildings += resourceRequirementsPerTurn(requiredResource: bd.requiredResource, uniques: bd.uniqueObjects, ctx: UniqueContext(civId: civId, city: c))[resource] ?? 0 }
                case .unit(let un)?: if let ud = rs.units[un] { futureForUnits += resourceRequirementsPerTurn(requiredResource: ud.requiredResource, uniques: ud.uniqueObjects, ctx: UniqueContext(civId: civId))[resource] ?? 0 }
                default: break
                }
            }
            let have = counts[resource] ?? 0
            if space.contains(resource) && have - amount - futureForBuildings - futureForUnits < 2 { return false }
            let last = lastEraResourceUsed(civId, resource)
            let neededForBuilding = last.building != nil
            let neededForUnits = last.unit.map { $0 >= eraNumber } ?? false
            if !neededForBuilding || !neededForUnits { continue }
            let usedForUnits = detailed.filter { $0.resource == resource && $0.origin == "Units" }.reduce(0) { $0 - $1.amount }
            let usedForBuildings = detailed.filter { $0.resource == resource && $0.origin == "Buildings" }.reduce(0) { $0 - $1.amount }
            if building != nil { if have + usedForUnits < usedForBuildings + amount + futureForBuildings { return false } }
            else if have + usedForBuildings < usedForUnits + amount + futureForUnits { return false }
        }
        return true
    }
    /// Unciv Automation.chooseMilitaryUnit
    func chooseMilitaryUnit(for city: City, availableUnits: [UnitDef]) -> UnitDef? {
        if case .unit(let n)? = city.currentProduction, let cur = rs.units[n], !cur.isCivilian { return cur }
        var removeShips = true
        var isMissingNavalUnitsForCityDefence = false
        let coastal = map.isAdjacentToCoast(city.coord)   // Unciv city.isCoastal(): centerTile.isAdjacentToCoast() (a lazy)
        if coastal {
            // BFS over the water body connected to this city.
            var seen: Set<HexCoord> = [city.coord]; var frontier = [city.coord]
            while let c = frontier.popLast() {
                for n in map.neighbors(of: c) where !seen.contains(n) {
                    guard let t = map[n] else { continue }
                    if (t.isWater && !t.isImpassable) || t.isCityCenter { seen.insert(n); frontier.append(n) }
                }
            }
            let ourConnectedCities = seen.filter { c in self.city(at: c).map { $0.civId == city.civId } ?? false }.count
            let ourNavalMelee = seen.flatMap { units(at: $0) }.filter { $0.def.isMelee && $0.def.isWater }.count   // Unciv counts every civ's naval melee units
            isMissingNavalUnitsForCityDefence = ourConnectedCities > ourNavalMelee
            removeShips = !seen.contains { c in (self.city(at: c).map { $0.civId != city.civId } ?? false) || (militaryUnitOn(c).map { $0.civId != city.civId } ?? false) }   // Unciv `it.militaryUnit != null && it.militaryUnit!!.civ != city.civ`: never an aircraft
        }
        let militaryUnits = availableUnits.filter { !$0.isCivilian && !(removeShips && $0.isWater) && allowSpendingResource(city.civId, unit: $0, building: nil, city: city) && !$0.cannotAttack }
        guard !militaryUnits.isEmpty else { return nil }
        let atWar = isAtWarAtAll(city.civId)
        if !atWar, cities(of: city.civId).contains(where: { c in militaryUnitOn(c.coord) == nil }) /* Unciv `getCenterTile().militaryUnit == null`: aircraft in the city do not count */, militaryUnits.contains(where: { $0.isRanged }) {
            return militaryUnits.filter { $0.isRanged }.max { $0.cost < $1.cost }
        }
        if isMissingNavalUnitsForCityDefence, militaryUnits.contains(where: { $0.isMelee && $0.isWater }) {
            return militaryUnits.filter { $0.isMelee && $0.isWater }.max { $0.cost < $1.cost }
        }
        // Unciv `bestUnitsForType` bir `hashMapOf<String, BaseUnit>`: `values.random(rng)` indeksi
        // ekleme sırasına göre değil java.util.HashMap kova sırasına göre seçer. Birim adına göre
        // alfabetik sıralamak ilk turda {Sword→Warrior, Scout→Scout} ikilisini ters çeviriyor ve
        // aynı rastgele indeks Savaşçı yerine İzci veriyordu; kova sırasını birebir üretiyoruz.
        var bestForType: [String: UnitDef] = [:]
        var typeOrder: [String] = []
        for u in militaryUnits {
            if bestForType[u.unitType] == nil { typeOrder.append(u.unitType); bestForType[u.unitType] = u }
            else if bestForType[u.unitType]!.forceEvaluation < u.forceEvaluation { bestForType[u.unitType] = u }
        }
        guard let bestForce = bestForType.values.map({ $0.forceEvaluation }).max() else { return nil }
        let shortlist = javaHashMapOrder(typeOrder).compactMap { bestForType[$0] }
            .filter { $0.uniqueTo != nil || $0.forceEvaluation > bestForce / 3 }
        // Unciv Automation.kt:201: `city.state.stateBasedRandom("Automation.chooseMilitaryUnit")`
        var g = stateBasedRandom("Automation.chooseMilitaryUnit", city: city)
        let picked = g.pick(shortlist)
        if epochsDebug { print("AIDBGH \(city.name) ctxHash=\(contextHash(UniqueContext(civId: city.civId, city: city, tile: map[city.coord]))) civID=\(civ(city.civId)?.nation ?? "-") cityId=\(city.uncivId)") }
        if epochsDebug { print("AIDBGM \(city.name) types=\(typeOrder) bucket=\(javaHashMapOrder(typeOrder)) shortlist=\(shortlist.map { $0.name }) bestForce=\(Int(bestForce)) chose=\(picked?.name ?? "-")") }
        return picked
    }
    /// Unciv Automation.tryTrainMilitaryUnit
    func tryTrainMilitaryUnit(_ city: City) {
        guard !city.isPuppet, let ci = cityIndex(city.id) else { return }
        if case .unit(let n)? = city.currentProduction, rs.units[n]?.isCivilian == false { return }
        // Unciv setCurrentConstruction replaces the head of the queue - a perpetual Science/Gold included when it IS the
        // head (our empty currentProduction); a perpetual trailing a building stays behind the new unit.
        if let chosen = chooseMilitaryUnit(for: city, availableUnits: buildableUnits(for: city)) {
            if cities[ci].currentProduction == nil { cities[ci].convertProductionTo = "" }
            cities[ci].currentProduction = .unit(chosen.name)
        }
    }
}

struct ProximityKey: Hashable { let turn: Int, unitCount: Int, civId: Int, radius: Int }

/// Unciv `utils/CollectionExtensions.randomWeighted(weights, random)`:
///   `totalWeight = weights.sum()` (Float), `randDouble = random.nextDouble()` - drawn ALWAYS, also for a single
///   item or a zero total - then `sum += weights[i] / totalWeight` (Float) and the first `randDouble <= sum` wins,
///   else `last()`. A zero total makes every quotient NaN, so the last item comes back after one draw.
/// Unciv throws on an empty list; this returns nil without drawing.
func uncivRandomWeighted<T>(_ items: [T], _ rng: inout SeededRandom, _ weight: (T) -> Float) -> T? {
    if items.isEmpty { return nil }
    let ws = items.map(weight)
    var total: Float = 0
    for w in ws { total += w }
    let randDouble = rng.nextDouble()
    var sum: Float = 0
    for (i, w) in ws.enumerated() {
        sum += w / total
        if randDouble <= Double(sum) { return items[i] }
    }
    return items.last
}

extension GameState {
    /// Unciv IHasUniques.getWeightForAiDecision (the AiChoiceWeight part): a Float product of `toPercent()`
    /// (`1 + p/100`) over the "[]% weight to this choice for AI decisions" uniques whose conditionals hold.
    func aiDecisionWeight(_ uniques: [Unique], _ ctx: UniqueContext) -> Float {
        var weight: Float = 1
        for u in uniques where u.pattern == "[]% weight to this choice for AI decisions" && conditionalsHold(u, ctx) {
            weight *= 1 + Float(u.double(0)) / 100
        }
        return weight
    }
}


// The approximate threat/ranking helpers that used to live here were unused and did not match Unciv;
// the Unciv ports are in Game/Automation/Automation.swift (ThreatManager, rankTile, rankStatsValue).
