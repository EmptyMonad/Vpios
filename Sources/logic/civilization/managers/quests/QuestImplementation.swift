// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `logic/civilization/managers/quests/QuestImplementation.kt`: what each quest asks for, when it is done and when it has passed.
extension GameState {
    /// The quests whose Unciv data1 is a civID (ours: the civ's id as a string)
    static let civTargetQuests: Set<String> = ["Conquer City State", "Find Player", "Give Gold", "Pledge to Protect", "Bully City State", "Denounce Civilization"]

    func questDef(_ name: String) -> QuestDef? { rs.quests.first { $0.name == name } }

    func isGlobalQuest(_ q: Quest) -> Bool { questDef(q.name)?.isGlobal == true }

    /// Unciv getQuestWeight: personality weight × city-state type weight
    func questWeight(_ q: QuestDef, for cs: Civilization) -> Float {
        var w: Float = 1   // Unciv: Float weight, HashMap<String, Float> factors
        if let p = q.weightForCityStateType[cs.cityStatePersonality] { w *= Float(p) }
        if let t = cs.cityStateType, let tw = q.weightForCityStateType[t] { w *= Float(tw) }
        return w
    }

    /// Unciv QuestManager.kt:247 `assignableQuests.randomWeighted(civ.getRandom()) { ... }` (global)
    /// ve :269 `... randomWeighted(civ.getRandom(challenger)) { ... }` (bireysel).
    /// `getRandom` QuestTargetHelpers.kt:18-23 → caller dizesi "QuestManager",
    /// baglam GameContext(sehir devleti[, challenger]).
    func randomWeightedQuest(_ defs: [QuestDef], _ cs: Civilization, challenger: Int? = nil) -> QuestDef? {
        guard !defs.isEmpty else { return nil }
        var g = stateBasedRandom("QuestManager", civId: cs.id, otherCivId: challenger)
        // Unciv CollectionExtensions.randomWeighted: Float total, one nextDouble(), Float running sum of w/total
        let weights = defs.map { questWeight($0, for: cs) }
        let total = weights.reduce(Float(0), +)
        let randDouble = g.double()
        var sum: Float = 0
        for (d, w) in zip(defs, weights) { sum += w / total; if randDouble <= Double(sum) { return d } }
        return defs.last
    }

    /// Unciv canAssignAQuestTo
    func canAssignQuest(_ cs: Civilization, to m: Civilization) -> Bool {
        m.isAlive && m.isMajor && cs.metCivs.contains(m.id) && !cs.isAtWar(with: m.id)
    }

    /// Unciv isQuestValid
    func isQuestValid(_ def: QuestDef, _ cs: Civilization, _ m: Civilization) -> Bool {
        guard canAssignQuest(cs, to: m) else { return false }
        if cs.quests.contains(where: { $0.name == def.name && $0.assigneeId == m.id }) { return false }
        if !def.isGlobal && hasFlag(cs.id, m.id, "Bullied") { return false }
        return questData(def, cs, m) != nil
    }

    /// Unciv QuestImplementation.isValid + getAssignedQuestData: nil when the quest cannot be given, otherwise its data1
    func questData(_ def: QuestDef, _ cs: Civilization, _ m: Civilization) -> String? {
        guard let csCap = capital(of: cs.id) else { return nil }
        // Unciv QuestTargetHelpers.kt:20-22: her hedef secici `getRandom(challenger)` ile yeni bir uretec kurar —
        // `getDiplomacyManager(challenger).state.stateBasedRandom("QuestManager")`. Her secim tek cekim yapar,
        // bu yuzden cagri basina taze uretec Unciv ile birebir ayni davranir.
        func questRng() -> SeededRandom { stateBasedRandom("QuestManager", civId: cs.id, otherCivId: m.id) }
        switch def.name {
        case "Route":
            let mine = cities(of: m.id)
            guard !mine.isEmpty, !isCapitalConnected(to: csCap, civId: m.id) else { return nil }
            let continent = continentId(of: csCap.coord)
            return mine.contains { continentId(of: $0.coord) == continent && $0.coord.distance(to: csCap.coord) <= 7 } ? "" : nil
        case "Clear Barbarian Camp":
            var g = questRng()   // Unciv QuestTargetHelpers.getBarbarianEncampmentForQuest (:35)
            return g.pick(map.tilesWithin(csCap.coord, radius: 8).filter { map[$0]?.hasBarbarianCamp == true }).map { "\($0.q),\($0.r)" }
        case "Construct Wonder":
            // Unciv QuestTargetHelpers.getWonderToBuildForQuest iterates `ruleset.buildings.values` - the
            // JSON's own order - and picks by index with randomOrNull. Sorting by name drew the same index out
            // of a differently ordered list: measured on `fresh`, Ragusa asked Unciv's Persia for the Temple of
            // Artemis and asked ours for the Mausoleum of Halicarnassus. Persepolis built the Temple on turn 51
            // either way, so Unciv collected 40 influence and the Maritime ally's food and we collected nothing.
            // Unciv `challenger.tech.isResearched(building)` (every required tech, the unique-given ones too) and
            // `!building.isUnavailableBySettings(gameInfo)` - which also drops "Only available <when religion is enabled>"
            // wonders in a game whose starting era disables religion (the Great Mosque of Djenne was drawn in a Modern start)
            let wonders = rs.buildingOrder.compactMap { rs.buildings[$0] }.filter { b in
                b.isWonder && requiredTechs(requiredTech: b.requiredTech, uniques: b.uniqueObjects).allSatisfy({ m.hasTech($0) })
                    && !isUnavailableBySettings(building: b) && b.uniqueTo == nil && !cities.contains { c in
                    if c.buildings.contains(b.name) { return true }
                    let done = c.currentProduction == .building(b.name) ? c.productionStored : Double(c.inProgressConstructions[b.name] ?? 0)
                    return done * 3 > Double(productionCost(.building(b.name), for: c.civId)) - done   // more than a quarter done
                }
            }
            var g = questRng()   // Unciv QuestTargetHelpers.getWonderToBuildForQuest (:84)
            return g.pick(wonders)?.name
        case "Connect Resource":
            // Unciv walks `tileMap.values` - the tile list in the order the save file holds it - and keeps the
            // first appearance of each resource (`mapNotNull { it.tileResource }.distinct()`). Sorting by name
            // handed the same draw a differently ordered list: measured on `t_45`, Ragusa asked Unciv's Carthage
            // for Horses, which Carthage already had a route to, and asked ours for Salt, which it did not.
            // Unciv collected the quest's 40 influence on turn 43, crossed 30, and the Maritime city-state's
            // "[+2 Food] [in capital]" fed Carthage two food a turn for the rest of the game.
            // Unciv reads the stored `detailedCivResources` field (written by updateCivResources only)
            let csOwned = Set((storedDetailedResources[cs.id] ?? detailedCivResources(cs.id)).map { $0.resource }), mine = Set((storedDetailedResources[m.id] ?? detailedCivResources(m.id)).map { $0.resource })
            var seenRes: Set<String> = []
            let onMap = map.tilesInUncivOrder().compactMap { $0.resource }.filter { seenRes.insert($0).inserted }
            var g = questRng()   // Unciv QuestTargetHelpers.getResourceForQuest (:59)
            return g.pick(onMap.filter { r in canSeeResource(r, civId: m.id) && rs.resources[r]?.resourceType != "Bonus" && !csOwned.contains(r) && !mine.contains(r) })
        case "Acquire Great Person":
            func base(_ d: UnitDef) -> String { d.replaces.flatMap { rs.units[$0]?.name } ?? d.name }
            let existing = Set((units(of: m.id) + units(of: cs.id)).filter { $0.isGreatPerson }.map { base($0.def) })
            var g = questRng()   // Unciv QuestTargetHelpers.getGreatPersonForQuest (:120)
            // Unciv `getGreatPeople().map { it.getReplacedUnit(ruleset) }.distinct()`: the set's walk, first occurrence kept
            var seenBase: Set<String> = []
            return g.pick(greatPeopleUnits(m.id).map { base($0) }.filter { seenBase.insert($0).inserted && !existing.contains($0) })
        case "Conquer City State":
            guard cs.cityStatePersonality != "Friendly" else { return nil }
            return cityStateQuestTarget(cs, m).map { String($0.id) }
        case "Find Player":
            var g = questRng()   // Unciv QuestTargetHelpers.getCivilizationToFindForQuest (:134)
            // Unciv `challenger.getKnownCivs()` - the challenger's diplomacy map order (alive, not barbarian)
            return g.pick(knownCivs(m.id).filter { $0.isMajor && !hasMetCivTerritory(m.id, $0.id) }).map { String($0.id) }
        case "Find Natural Wonder":
            // Unciv TileMap.naturalWonders is `tileList.asSequence()...toSet()`, a LinkedHashSet in tile-list
            // order, and Kotlin's `subtract` keeps the receiver's order. Same list, same draw, different answer.
            var seenNW: Set<String> = []
            let wondersOnMap = map.tilesInUncivOrder().compactMap { $0.naturalWonder }.filter { seenNW.insert($0).inserted }
            var g = questRng()   // Unciv QuestTargetHelpers.getNaturalWonderToFindForQuest (:98)
            return g.pick(wondersOnMap.filter { !m.seenNaturalWonders.contains($0) && !cs.seenNaturalWonders.contains($0) })
        case "Give Gold": return mostRecentBully(cs).map { String($0) }
        case "Pledge to Protect":
            guard let b = mostRecentBully(cs), !m.protectedCityStates.contains(cs.id) else { return nil }
            return String(b)
        case "Contest Culture": return String(m.totalCultureForContests)
        case "Contest Faith": return religionEnabled ? String(m.totalFaithForContests) : nil
        case "Contest Technologies": return String(m.techs.count + m.futureTechs)   // Unciv tech.getNumberOfTechsResearched(): techsResearched.size + repeatingTechsResearched
        case "Invest":
            if let r = def.description.range(of: #"\[\d+\]"#, options: .regularExpression) { return String(def.description[r].dropFirst().dropLast()) }
            return "0"
        case "Bully City State": return cityStateQuestTarget(cs, m).map { String($0.id) }
        case "Denounce Civilization":
            // Unciv bails out on a missing DiplomacyManager, so a civ we have not met cannot be the target.
            guard let b = mostRecentBully(cs), let bc = civ(b), m.metCivs.contains(b),
                  !isDenouncing(m.id, b), !m.isAtWar(with: b), !(m.isPlayer && bc.isPlayer) else {
                if GameState.evlogOn, let b = mostRecentBully(cs), civ(b)?.isPlayer == true, m.isPlayer { hbr("A11.noBullyQuestBetweenHumans", m.id) }
                return nil
            }
            return String(b)
        case "Spread Religion":
            guard religionEnabled, let r = m.religionName, religionIsMajor(r), majorityReligion(of: csCap) != r else { return nil }
            return r
        default: return nil
        }
    }

    /// Unciv QuestImplementation.isComplete (quests completed by events return false here)
    func isQuestComplete(_ q: Quest, _ cs: Civilization) -> Bool {
        guard let a = q.assigneeId, let m = civ(a), let csCap = capital(of: cs.id) else { return false }
        switch q.name {
        case "Route": return isCapitalConnected(to: csCap, civId: a)
        case "Construct Wonder": return cities(of: a).contains { $0.buildings.contains(q.target ?? "") }
        case "Connect Resource": return (storedDetailedResources[a] ?? detailedCivResources(a)).contains { $0.resource == q.target }   // Unciv: the stored field
        case "Acquire Great Person": return units(of: a).contains { u in u.isGreatPerson && (u.def.replaces ?? u.name) == q.target }
        case "Find Player": return q.target.flatMap { Int($0) }.map { hasMetCivTerritory(a, $0) } ?? false
        case "Find Natural Wonder": return m.seenNaturalWonders.contains(q.target ?? "")
        case "Pledge to Protect": return m.protectedCityStates.contains(cs.id)
        case "Denounce Civilization": return q.target.flatMap { Int($0) }.map { isDenouncing(a, $0) } ?? false
        case "Spread Religion": return majorityReligion(of: csCap) == q.target
        default: return false
        }
    }

    /// Unciv QuestImplementation.isObsolete
    func isQuestObsolete(_ q: Quest, _ cs: Civilization) -> Bool {
        switch q.name {
        case "Clear Barbarian Camp":
            guard let parts = q.target?.split(separator: ","), parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else { return true }
            return map[HexCoord(x, y)]?.hasBarbarianCamp != true
        case "Construct Wonder": return cities.contains { $0.civId != q.assigneeId && $0.buildings.contains(q.target ?? "") }
        case "Conquer City State", "Find Player", "Bully City State", "Denounce Civilization": return q.target.flatMap { Int($0) }.map { civ($0)?.isAlive != true } ?? true
        default: return false
        }
    }

    /// Unciv getScoreForQuest
    func questScore(_ q: Quest) -> Int {
        guard let a = q.assigneeId, let m = civ(a) else { return 0 }
        let start = Int(q.target ?? "0") ?? 0
        switch q.name {
        case "Contest Culture": return m.totalCultureForContests - start
        case "Contest Faith": return m.totalFaithForContests - start
        case "Contest Technologies": return m.techs.count + m.futureTechs - start   // Unciv getNumberOfTechsResearched() - data1: each Future Tech counts
        default: return 0
        }
    }

    /// Unciv WinnersAndLosers: the highest positive score, ties included
    func questWinners(_ name: String, _ cs: Civilization) -> (winners: [Quest], maxScore: Int) {
        var winners: [Quest] = [], maxScore = -1
        for q in cs.quests where q.name == name {
            let score = questScore(q)
            if score <= 0 { continue }
            if score == maxScore { winners.append(q) } else if score > maxScore { winners = [q]; maxScore = score }
        }
        return (winners, maxScore)
    }

    /// Unciv getScoreStringForGlobalQuest
    func contestStandingText(_ q: Quest, cityState cs: Civilization) -> String? {
        let descriptor: String
        switch q.name { case "Contest Culture": descriptor = "Culture"; case "Contest Faith": descriptor = "Faith"; case "Contest Technologies": descriptor = "Technologies"; default: return nil }
        let (winners, maxScore) = questWinners(q.name, cs)
        guard !winners.isEmpty else { return nil }
        // listOfLeadersAsTranslatedString: each winner's civName.tr() joined by ", ", then getScoreString(...).tr() - so tied
        // leaders read translated one by one (the joined list is no key the file knows)
        let names = winners.compactMap { $0.assigneeId.flatMap { civ($0)?.nation } }.map { L($0) }.joined(separator: ", ")
        let leaders = L("[\(names)] with [\(maxScore)] [\(descriptor)]")
        if winners.contains(where: { $0.id == q.id }) { return "Current leader(s): [\(leaders)]" }
        let you = L("[\(q.assigneeId.flatMap { civ($0)?.nation } ?? "?")] with [\(questScore(q))] [\(descriptor)]")
        return "Current leader(s): [\(leaders)], you: [\(you)]"
    }

    /// Unciv AssignedQuest.getDescription: `quest.description.fillPlaceholders(data1)` - the placeholder keeps its
    /// brackets ("[Iron]"), so the diplomacy table's tr() finds the description's template and translates the
    /// filled-in resource, wonder, nation, great person or religion name as well.
    func questText(_ q: Quest, cityState cs: Civilization) -> String {
        var text = questDef(q.name)?.description ?? q.name
        let data1 = q.target.map { t in Int(t).flatMap { id in GameState.civTargetQuests.contains(q.name) ? civ(id)?.nation : nil } ?? t } ?? ""
        // fillPlaceholders: the (single) [placeholder] becomes [data1]
        if let open = text.firstIndex(of: "["), let close = text[open...].firstIndex(of: "]") {
            text.replaceSubrange(open...close, with: "[\(data1)]")
        }
        return text
    }
}
