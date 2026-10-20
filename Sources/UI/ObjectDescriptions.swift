// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv objectdescriptions/*: the Civilopedia text lines for ruleset objects (BuildingDescriptions, BaseUnitDescriptions,
/// ImprovementDescriptions, ResourceDescriptions, TechnologyDescriptions, NationDescriptions, terrain lines).
enum ObjectDescriptions {
    private static func signed(_ v: Double) -> String { (v > 0 ? "+" : "") + String(Int(v)) }
    /// Unciv `!Unique.isHiddenToUsers()`: an "Unavailable"/"Only available" unique is shown like any other
    private static func isPlayerFacing(_ u: String) -> Bool {
        let p = Unique(u).pattern
        return uniqueIsPlayerFacing(u) && !(p == "Will not be displayed in Civilopedia" || p.hasPrefix("Suppress warning") || u.contains("<hidden from users>"))
    }

    // MARK: FormattedLine (the Civilopedia's lines as Unciv's description builders make them)

    /// Unciv FormattedLine(text, link, indent): the translated text, the link as Unciv writes it ("Technology/Pottery",
    /// "Resources/Iron", nil for none) and the indent - two leading spaces a level, as the Civilopedia draws them.
    static func fl(_ text: String, link: String? = nil, indent: Int = 0) -> PediaLine {
        PediaLine(String(repeating: "  ", count: indent) + text, link: (link?.isEmpty ?? true) ? nil : link)
    }
    /// Unciv FormattedLine(): an empty line.
    static let blank = PediaLine("")
    /// Unciv IHasUniques.uniquesToCivilopediaTextLines: an empty line before the first shown unique (leadingSeparator),
    /// then FormattedLine(unique) each - getDisplayText with getUniqueLink's link, a ConsumesResources unique linked to its
    /// resource when colorConsumesResources.
    static func uniqueFLines(_ uniques: [String], rs: Ruleset, s: GameState?, leading: Bool = true, colorConsumesResources: Bool = false) -> [PediaLine] {
        var out: [PediaLine] = []
        for u in uniques where isPlayerFacing(u) {
            if leading && out.isEmpty { out.append(blank) }
            let q = Unique(u)
            let link = colorConsumesResources && q.pattern == "Consumes [] []" ? "Resources/\(q.param(1))" : uniqueLink(q, s: s)
            out.append(fl(L(displayText(u)), link: link))
        }
        return out
    }
    /// Unciv FormattedLine.getUniqueLink: the unique's `<Civilopedia link [...]>` modifier, else the first of its parameters
    /// (then its modifiers' parameters) that names a ruleset object, as "Category/name". The names are those of
    /// getCurrentRuleset(): the game's ruleset, Civ V - Vanilla's when there is no game (the main menu's Civilopedia).
    static func uniqueLink(_ u: Unique, s: GameState?) -> String {
        if let l = u.conditionals.first(where: { $0.pattern == "Civilopedia link []" }) { return l.param(0) }
        let map = namesCategoryMap(s?.rs ?? vanillaRuleset)
        for p in u.params + u.conditionals.flatMap({ $0.params }) { if let c = map[p] { return c + "/" + p } }
        return ""
    }
    nonisolated(unsafe) private static var vanillaCache: Ruleset? = nil
    /// RulesetCache[BaseRuleset.Civ_V_Vanilla.fullName], loaded once.
    static var vanillaRuleset: Ruleset {
        if let r = vanillaCache { return r }
        let r = Ruleset.currentBaseRuleset == "Civ V - Vanilla" && Ruleset.shared.mods.isEmpty ? Ruleset.shared : ((try? Ruleset(named: "Civ V - Vanilla")) ?? Ruleset.shared)
        vanillaCache = r
        return r
    }
    nonisolated(unsafe) private static var namesMapFor: ObjectIdentifier? = nil
    nonisolated(unsafe) private static var namesMap: [String: String] = [:]
    /// Unciv FormattedLine.initNamesCategoryMap: every object's name to its category's enum name, the later categories
    /// winning a shared name (Belief, Difficulty, Promotion, Policy, Terrain, Improvement, Resource, Nation, UnitType, Unit,
    /// Technology, Building, Wonder, UnitNameGroup), plus the Maya calendar's tutorial.
    static func namesCategoryMap(_ rs: Ruleset) -> [String: String] {
        if namesMapFor == ObjectIdentifier(rs) { return namesMap }
        var m: [String: String] = [:]
        for n in rs.beliefs.keys { m[n] = "Belief" }
        for d in rs.difficulties { m[d.name] = "Difficulty" }
        for n in rs.promotions.keys { m[n] = "Promotion" }
        for b in rs.policyBranches { m[b.name] = "Policy" }
        for n in rs.policies.keys { m[n] = "Policy" }
        for n in rs.terrains.keys { m[n] = "Terrain" }
        for n in rs.improvements.keys { m[n] = "Improvement" }
        for n in rs.resources.keys { m[n] = "Resource" }
        for n in rs.nations.keys { m[n] = "Nation" }
        for n in rs.unitTypes.keys { m[n] = "UnitType" }
        for n in rs.units.keys { m[n] = "Unit" }
        for n in rs.techs.keys { m[n] = "Technology" }
        for b in rs.buildings.values where !b.isAnyWonder { m[b.name] = "Building" }
        for b in rs.buildings.values where b.isAnyWonder { m[b.name] = "Wonder" }
        for n in rs.unitNameGroups.keys { m[n] = "UnitNameGroup" }
        m["Maya Long Count calendar cycle"] = "Tutorial"
        namesMap = m; namesMapFor = ObjectIdentifier(rs)
        return m
    }
    /// Unciv BaseUnit.promotions is a HashSet<String> filled from the json list: every walk of it (the Civilopedia's "Free
    /// promotions:", getShortDescription, getDescription, getDifferences) goes in java.util.HashMap bucket order.
    static func promotionSetOrder(_ u: UnitDef) -> [String] { javaHashMapOrder(u.promotions) }
    /// Unciv Building.makeLink.
    static func buildingLink(_ b: BuildingDef) -> String { (b.isAnyWonder ? "Wonder/" : "Building/") + b.name }
    /// Unciv Stats.toString(): "+1 Production, +2 Food" in Stat order, each amount truncated and through Number.tr(),
    /// its stat translated with the stat's icon in front.
    static func statsLine(_ st: Stats) -> String { Translations.mapFontIcons(st.uncivTextWithIcons) }
    /// Kotlin's Double.toString of a whole or fractional value: 5.0 reads "5.0".
    static func kotlinDouble(_ d: Double) -> String { d == d.rounded() && abs(d) < 1e7 ? "\(Int(d)).0" : "\(d)" }
    /// Belief.getCivilopediaTextMatching(name, ruleset, withSeeAlso = false): the matching beliefs, indented and linked.
    static func beliefLinesMatching(_ name: String, rs: Ruleset, s: GameState?) -> [PediaLine] {
        beliefsMatching(name, rs: rs, s: s).map { fl(L($0), link: "Belief/\($0)", indent: 1) }
    }

    // MARK: city screen (ConstructionInfoTable: BuildingDescriptions / BaseUnitDescriptions.getDescription)

    /// Unciv Stats.toString: "+1 ⚙Production, +2 ¤Gold" in Stat.entries order, amounts truncated and written by
    /// Number.tr, each stat's icon before its translated name
    private static func statsText(_ st: Stats) -> String { statsLine(st)
    }
    /// Unciv String.getConsumesAmountString / getCostsAmountString
    private static func consumesText(_ name: String, _ amount: Int, stockpiled: Bool, available: Int) -> String {
        L("Consumes [\(amount)] [\(name)]") + (stockpiled ? " /⏳" : "") + (available >= 0 ? " (" + L("[\(available)] available") + ")" : "")
    }

    /// Unciv BuildingDescriptions.getDescription(building, city, showAdditionalInfo = true)
    static func cityBuilding(_ b: BuildingDef, city: City, s: GameState) -> String {
        var lines: [String] = []
        let isFree = s.hasFreeBuilding(city, b.name)   // Unciv `city.civ.civConstructions.hasFreeBuilding(city, this)`
        if let u = b.uniqueTo { lines.append(b.replaces == nil ? L("Unique to [\(u)]") : L("Unique to [\(u)], replaces [\(b.replaces!)]")) }
        if b.isWonder { lines.append(L("Wonder")) }
        if b.isNationalWonder { lines.append(L("National Wonder")) }
        if !isFree {
            let ctx = GameState.UniqueContext(civId: city.civId, city: city)
            for (res, amount) in s.orderedResourceRequirements(requiredResource: b.requiredResource, uniques: b.uniqueObjects, ctx: ctx) {
                guard let r = s.rs.resources[res] else { continue }
                lines.append(consumesText(res, amount, stockpiled: r.isStockpiled, available: s.availableResourceAmount(city, res)))
            }
            for u in b.uniqueObjects where u.pattern == "Costs [] []" {
                guard s.rs.resources[u.param(1)] != nil else { continue }
                lines.append(L("Costs [\(u.int(0))] [\(u.param(1))]") + " (" + L("[\(s.availableResourceAmount(city, u.param(1)))] available") + ")")
            }
        }
        // getUniquesStringsWithoutDisablers: "[stats] from [tileFilter] tiles in this city" grouped by stats
        var tileBonus: [(String, [String])] = []
        for u in b.uniques where isPlayerFacing(u) {
            let un = Unique(u)
            if un.pattern == "Consumes [] []" || un.pattern == "Costs [] []" { continue }
            if un.pattern == "[] from [] tiles []" && un.param(2) == "in this city" {
                if let i = tileBonus.firstIndex(where: { $0.0 == un.param(0) }) { tileBonus[i].1.append(un.param(1)) } else { tileBonus.append((un.param(0), [un.param(1)])) }
            } else { lines.append(L(displayText(u))) }
        }
        // the grouped stats come out of a HashMap<String, ArrayList<String>> in its bucket order
        for st in javaHashMapOrder(tileBonus.map { $0.0 }) { let filters = tileBonus.first { $0.0 == st }!.1; lines.append(L("[\(st)] from [\(filters.count == 1 ? filters[0] : filters.map { L($0) }.joined(separator: ", "))] tiles in this city")) }
        // Building.getStats(city): its stats, the city's "[stats] from every [filter]", its own "[stats]", and for
        // anything but a world wonder "[stats] from all [filter] buildings"
        var st = b.stats
        for u in s.cityMatchingUniques(city, "[] from every []") where s.productionMatches(.building(b.name), u.param(1)) { if let x = u.stats { st += x } }
        for u in b.uniqueObjects where u.pattern == "[]" { if let x = u.stats { st += x } }
        if !b.isWonder { for u in s.cityMatchingUniques(city, "[] from all [] buildings") where s.productionMatches(.building(b.name), u.param(1)) { if let x = u.stats { st += x } } }
        let stText = statsText(st); if !stText.isEmpty { lines.append(stText) }
        // Building.getStatPercentageBonuses(city)
        var pct = b.percentStatBonus
        for u in s.cityMatchingUniques(city, "[]% [] from every []") where s.productionMatches(.building(b.name), u.param(2)) { pct[u.param(1)] += u.double(0) }
        for u in s.cityMatchingUniques(city, "[]% Yield from every []") where s.productionMatches(.building(b.name), u.param(1)) {
            for n in ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith"] { pct[n] += u.double(0) }
        }
        for (name, v) in [("Production", pct.production), ("Food", pct.food), ("Gold", pct.gold), ("Science", pct.science), ("Culture", pct.culture), ("Happiness", pct.happiness), ("Faith", pct.faith)] where Int(v) != 0 { lines.append("\(signed(v))% \(L(name))") }
        for (gp, v) in b.greatPersonPoints.sorted(by: { $0.key < $1.key }) { lines.append("+\(v) " + L("[\(gp)] points")) }
        for (sp, n) in b.specialistSlots.sorted(by: { $0.key < $1.key }) { lines.append("+\(n) " + L("[\(sp)] slots")) }
        if !b.requiredNearbyImprovedResources.isEmpty { lines.append(L("Requires improved [\(b.requiredNearbyImprovedResources.map { L($0) }.joined(separator: "/"))] near city")) }
        if b.cityStrength != 0 { lines.append(L("City strength") + " +\(b.cityStrength)") }
        if b.cityHealth != 0 { lines.append(L("City health") + " +\(b.cityHealth)") }
        if b.maintenance != 0 && !isFree { lines.append(L("Maintenance cost") + ": \(b.maintenance) " + L("Gold")) }
        // Unciv BuildingDescriptions.getDescription(city, showAdditionalInfo = true) - the city screen's call - then
        // additionalDescription: for every "Only available" / "Can only be built" unique, each <if [X] is constructed in all
        // [filter] cities> names the cities still missing it (missingCityText)
        for u in b.uniqueObjects where u.pattern == "Only available" || u.pattern == "Can only be built" {
            for c in u.conditionals where c.pattern == "if [] is constructed in all [] cities" {
                let missing = s.cities(of: city.civId).filter { s.cityMatchesFilter(c.param(1), city: $0, viewer: city.civId) && !s.containsBuildingOrEquivalent($0, c.param(0)) }
                if !missing.isEmpty { lines.append("\n" + L("[\(s.equivalentBuilding(city.civId, c.param(0)))] required:") + " " + missing.map { L($0.name) }.joined(separator: ", ")) }
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unciv BaseUnitDescriptions.getDescription(baseUnit, city)
    static func cityUnit(_ u: UnitDef, city: City, s: GameState) -> String {
        var lines: [String] = []
        let ctx = GameState.UniqueContext(civId: city.civId)
        let counts = s.resourceCounts(city.civId)
        for (res, amount) in s.orderedResourceRequirements(requiredResource: u.requiredResource, uniques: u.uniqueObjects, ctx: ctx) {
            guard let r = s.rs.resources[res] else { continue }
            lines.append(consumesText(res, amount, stockpiled: r.isStockpiled, available: counts[res] ?? 0))
        }
        for un in u.uniqueObjects where un.pattern == "Costs [] []" {
            guard s.rs.resources[un.param(1)] != nil else { continue }
            lines.append(L("Costs [\(un.int(0))] [\(un.param(1))]") + " (" + L("[\(s.availableResourceAmount(city, un.param(1)))] available") + ")")
        }
        var strength = ""
        if u.strength != 0 {
            strength += "\(u.strength)⚔️, "
            if u.rangedStrength != 0 { strength += "\(u.rangedStrength)🏹, \(u.range)⭕, " }
        }
        lines.append("\(strength)\(u.movement)👟")
        for x in u.uniques where isPlayerFacing(x) {
            let p = Unique(x).pattern
            if p == "Unbuildable" || p == "Consumes [] []" || p == "Costs [] []" { continue }
            lines.append(L(displayText(x)))
        }
        if !u.promotions.isEmpty { lines.append((u.promotions.count == 1 ? L("Free promotion:") : L("Free promotions:")) + " " + promotionSetOrder(u).map { L($0) }.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    /// Unciv Policy.getDescription(): a Member policy's name, then "• " + getDisplayText of every unique shown to users
    /// except "Only available" and "Triggers the following global alert" (the policy picker, a described branch's
    /// "On adoption" - the branch itself - and "On completion" - its last policy)
    static func policyDescription(name: String, uniques: [Unique], isMember: Bool) -> String {
        (isMember ? L(name) + "\n" : "") + uniques.filter { isPlayerFacing($0.text) && $0.pattern != "Only available" && $0.pattern != "Triggers the following global alert: []" }
            .map { "• " + L(displayText($0.text)) }.joined(separator: "\n")
    }
    static func policyDescription(_ p: PolicyDef, rs: Ruleset) -> String {
        policyDescription(name: p.name, uniques: p.uniqueObjects, isMember: !rs.policyBranches.contains { $0.name == p.name || $0.completion?.name == p.name })
    }
    /// Unciv Promotion.getDescription(promotionsForUnitType): uniquesToDescription, then "{Requires}: " with the
    /// prerequisites the unit type can have, joined by " OR " (the promotion picker)
    static func promotionDescription(_ p: PromotionDef, promotionsForUnitType: Set<String>) -> String {
        var lines = p.uniques.filter(isPlayerFacing).map { L(displayText($0)) }
        if !p.prerequisites.isEmpty { lines.append(L("Requires") + ": " + p.prerequisites.filter { promotionsForUnitType.contains($0) }.map { L($0) }.joined(separator: L(" OR "))) }
        return lines.joined(separator: "\n")
    }

    /// Unciv ImprovementDescriptions.getDescription(improvement, ruleset): the improvement picker's description - its
    /// stats, "Unique to", "Replaces", "Can be built on" the terrains, "[stats] <in [resource] tiles>" for every resource
    /// in ruleset order it improves, "Required tech: [tech]" and its uniques
    static func improvementDescription(_ i: ImprovementDef, rs: Ruleset) -> String {
        var lines: [String] = []
        let st = statsLine(i.stats); if !st.isEmpty { lines.append(st) }
        if let n = i.uniqueTo { lines.append(L("Unique to [\(n)]")) }
        if let r = i.replaces { lines.append(L("Replaces [\(r)]")) }
        if !i.terrainsCanBeBuiltOn.isEmpty { lines.append(L("Can be built on") + " " + i.terrainsCanBeBuiltOn.map { L($0) }.joined(separator: ", ")) }
        for r in rs.resourcesInOrder where !r.improvementStats.isEmpty && improvements(of: r, rs: rs).contains(i.name) {
            lines.append(L("[\(statsLine(r.improvementStats))] <in [\(r.name)] tiles>"))
        }
        if let t = i.techRequired { lines.append(L("Required tech: [\(t)]")) }
        lines += i.uniques.filter(isPlayerFacing).map { L(displayText($0)) }
        return lines.joined(separator: "\n")
    }

    // MARK: tech picker / tech researched alert (TechnologyDescriptions.getDescription)

    /// Unciv Unique.getDisplayText: modifiers flagged HiddenToUsers are dropped from the text
    static func displayText(_ u: String) -> String {
        let hidden: Set<String> = ["Civilopedia link []", "with [] priority", "hidden from users", "if tutorials are enabled", "if tutorial [] is completed",
                                   "Suppress warning []", "[]% weight to this choice for AI decisions"]
        let conds = Translations.conditionals(u)
        guard conds.contains(where: { hidden.contains(Translations.placeholderText($0)) }) else { return u }
        let kept = conds.filter { !hidden.contains(Translations.placeholderText($0)) }
        return Translations.removeConditionals(u) + kept.map { " <\($0)>" }.joined()
    }
    /// Unciv IHasUniques.shouldBeHiddenIfNoGameLoaded: with no game loaded, religion counts as on when the ruleset has
    /// beliefs and espionage when a nation has spy names; the first "Only available" / "Unavailable" naming one decides.
    static func hiddenWithoutGame(_ uniques: [Unique], rs: Ruleset) -> Bool {
        guard !uniques.isEmpty else { return false }
        func check(_ hasFeature: Bool, _ enabler: String, _ disabler: String) -> Bool {
            for u in uniques where u.pattern == "Only available" {
                if u.conditionals.contains(where: { $0.pattern == enabler }) { return !hasFeature }
                if u.conditionals.contains(where: { $0.pattern == disabler }) { return hasFeature }
            }
            for u in uniques where u.pattern == "Unavailable" {
                if u.conditionals.contains(where: { $0.pattern == enabler }) { return hasFeature }
                if u.conditionals.contains(where: { $0.pattern == disabler }) { return !hasFeature }
            }
            return false
        }
        return check(!rs.beliefs.isEmpty, "when religion is enabled", "when religion is disabled")
            || check(rs.nations.values.contains { !$0.spyNames.isEmpty }, "when espionage is enabled", "when espionage is disabled")
    }
    /// Unciv IHasUniques.isHiddenFromCivilopedia(gameInfo, ruleset): "Will not be displayed in Civilopedia"; with a game
    /// loaded the object's own isUnavailableBySettings (`unavailable`, the generic one when nil), without one the
    /// religion/espionage guess from the ruleset.
    static func hiddenFromCivilopedia(_ uniques: [Unique], s: GameState?, rs: Ruleset, unavailable: ((GameState) -> Bool)? = nil) -> Bool {
        if uniques.contains(where: { $0.pattern == "Will not be displayed in Civilopedia" }) { return true }
        if let s { return unavailable?(s) ?? s.isUnavailableBySettings(uniques) }
        return hiddenWithoutGame(uniques, rs: rs)
    }
    /// isHiddenFromCivilopedia through Building.isUnavailableBySettings (nuclear weapons off, starting-era wonders)
    static func hiddenFromCivilopedia(building b: BuildingDef, s: GameState?, rs: Ruleset) -> Bool {
        hiddenFromCivilopedia(b.uniqueObjects, s: s, rs: rs) { $0.isUnavailableBySettings(building: b) }
    }
    /// isHiddenFromCivilopedia through BaseUnit.isUnavailableBySettings (nuclear weapons off)
    static func hiddenFromCivilopedia(unit u: UnitDef, s: GameState?, rs: Ruleset) -> Bool {
        hiddenFromCivilopedia(u.uniqueObjects, s: s, rs: rs) { $0.isUnavailableBySettings(unit: u) }
    }
    /// Unciv IHasUniques.requiredTechs: the requiredTech, then the techs its "Only available" uniques ask for
    private static func requiredTechs(_ requiredTech: String?, _ uniques: [Unique]) -> [String] {
        (requiredTech.map { [$0] } ?? []) + uniques.filter { $0.pattern == "Only available" }.flatMap { $0.conditionals.filter { $0.pattern == "after discovering []" }.map { $0.param(0) } }
    }
    /// Unciv Technology.uniqueIsRequirementForThisTech
    private static func isRequirement(_ u: Unique, tech: String) -> Bool {
        u.pattern == "Only available" && u.conditionals.count == 1 && u.conditionals[0].pattern == "after discovering []" && u.conditionals[0].param(0) == tech
    }
    /// Unciv BaseUnit.getShortDescription() with no exclusion
    static func unitShortDescription(_ u: UnitDef) -> String { unitShortUnciv(u, tech: "") }
    /// Unciv BaseUnitDescriptions.getShortDescription
    private static func unitShortUnciv(_ u: UnitDef, tech: String) -> String {
        var info: [String] = []
        // `strength.tr()`: Number.tr in the game's language
        if u.strength != 0 { info.append("\(Translations.shared.numberTr(u.strength))⚔️") }
        if u.rangedStrength != 0 { info.append("\(Translations.shared.numberTr(u.rangedStrength))🏹") }
        if u.movement != 2 { info.append("\(Translations.shared.numberTr(u.movement))👟") }
        info += promotionSetOrder(u).map { L($0) }
        info += u.uniqueObjects.filter { isPlayerFacing($0.text) && !isRequirement($0, tech: tech) }.map { L(displayText($0.text)) }
        return info.joined(separator: ", ")
    }
    /// Unciv BuildingDescriptions.getShortDescription(multiline = false)
    static func buildingShortUnciv(_ b: BuildingDef, tech: String = "") -> String { buildingShortInfo(b, tech: tech).joined(separator: "; ") }
    /// Unciv BuildingDescriptions.getShortDescription's infoList, which multiline = true puts one per line
    static func buildingShortInfo(_ b: BuildingDef, tech: String = "") -> [String] {
        var info: [String] = []
        let st = statsText(b.stats); if !st.isEmpty { info.append(st) }
        for (name, v) in [("Production", b.percentStatBonus.production), ("Food", b.percentStatBonus.food), ("Gold", b.percentStatBonus.gold), ("Science", b.percentStatBonus.science), ("Culture", b.percentStatBonus.culture), ("Happiness", b.percentStatBonus.happiness), ("Faith", b.percentStatBonus.faith)] where v != 0 {
            info.append("+\(Int(v))% \(L(name))")
        }
        if !b.requiredNearbyImprovedResources.isEmpty { info.append(L("Requires improved [\(b.requiredNearbyImprovedResources.map { L($0) }.joined(separator: "/"))] near city")) }
        var tileBonus: [(String, [String])] = []
        for u in b.uniqueObjects where isPlayerFacing(u.text) && !isRequirement(u, tech: tech) {
            if u.pattern == "[] from [] tiles []" && u.param(2) == "in this city" {
                if let i = tileBonus.firstIndex(where: { $0.0 == u.param(0) }) { tileBonus[i].1.append(u.param(1)) } else { tileBonus.append((u.param(0), [u.param(1)])) }
            } else { info.append(L(displayText(u.text))) }
        }
        for st in javaHashMapOrder(tileBonus.map { $0.0 }) { let filters = tileBonus.first { $0.0 == st }!.1; info.append(L("[\(st)] from [\(filters.count == 1 ? filters[0] : filters.map { L($0) }.joined(separator: ", "))] tiles in this city")) }
        if b.cityStrength != 0 { info.append(L("City strength") + " +\(b.cityStrength)") }
        if b.cityHealth != 0 { info.append(L("City health") + " +\(b.cityHealth)") }
        return info
    }

    /// Unciv TechnologyDescriptions.getDescription(technology, viewingCiv): the text of the TechPickerScreen and of
    /// the TechResearched alert
    static func techDescription(_ t: TechDef, civId: Int, s: GameState) -> String {
        let rs = s.rs
        guard let civ = s.civ(civId) else { return "" }
        var lines: [String] = []
        lines += t.civilopediaText.map { $0.text }.filter { !$0.isEmpty }
        lines += t.uniqueObjects.filter { isPlayerFacing($0.text) }.map { L(displayText($0.text)) }
        // getAffectedImprovements: "[stats]" (Stats) / "[stats] from [tileFilter] tiles" (ImprovementStatsOnTile) uniques
        // that this tech switches on, for improvements the viewing civ may build
        for a in affectedImprovements(t.name, rs: rs) where a.improvement.uniqueTo == nil || s.civMatches(civ, a.improvement.uniqueTo!, viewer: civId) {
            lines.append(L(a.text))
        }
        let units = rs.unitOrder.compactMap { rs.units[$0] }.filter { u in
            requiredTechs(u.requiredTech, u.uniqueObjects).contains(t.name)
                && (u.uniqueTo != nil && s.civMatches(civ, u.uniqueTo!, viewer: civId) || u.uniqueTo == nil && s.equivalentUnit(civId, u).name == u.name)
                && !hiddenFromCivilopedia(unit: u, s: s, rs: rs)
        }
        if !units.isEmpty {
            lines.append(L("Units enabled") + ": ")
            for u in units { lines.append(" • \(L(u.name)) (\(unitShortUnciv(u, tech: t.name)))\n") }
        }
        func filteredBuildings(_ pred: (BuildingDef) -> Bool) -> [BuildingDef] {
            rs.buildingOrder.compactMap { rs.buildings[$0] }.filter { b in
                pred(b) && (b.uniqueTo != nil && s.civMatches(civ, b.uniqueTo!, viewer: civId) || b.uniqueTo == nil && s.equivalentBuilding(civId, b.name) == b.name)
                    && !hiddenFromCivilopedia(building: b, s: s, rs: rs)
            }
        }
        let enabled = filteredBuildings { requiredTechs($0.requiredTech, $0.uniqueObjects).contains(t.name) }
        let wonders = enabled.filter { $0.isAnyWonder }, regular = enabled.filter { !$0.isAnyWonder }
        if !regular.isEmpty {
            lines.append(L("Buildings enabled") + ": ")
            for b in regular { lines.append(" • \(L(b.name)) (\(buildingShortUnciv(b, tech: t.name)))\n") }
        }
        if !wonders.isEmpty {
            lines.append(L("Wonders enabled") + ": ")
            for b in wonders { lines.append(" • \(L(b.name)) (\(buildingShortUnciv(b, tech: t.name)))\n") }
        }
        // getObsoletedObjects: buildings, resources and improvements with "Obsolete with [tech]"
        func obsoletes(_ us: [Unique]) -> Bool { us.contains { $0.pattern == "Obsolete with []" && $0.param(0) == t.name } }
        let obsoleted = filteredBuildings { obsoletes($0.uniqueObjects) }.map { $0.name }
            + rs.resourcesInOrder.filter { obsoletes($0.uniqueObjects) }.map { $0.name }
            + rs.improvementOrder.compactMap { rs.improvements[$0] }.filter { ($0.uniqueTo == nil || s.civMatches(civ, $0.uniqueTo!, viewer: civId)) && obsoletes($0.uniqueObjects) }.map { $0.name }
        for o in obsoleted { lines.append(L("[\(o)] obsoleted")) }
        for r in rs.resourcesInOrder where r.revealedBy == t.name { lines.append(L("Reveals [\(r.name)] on the map")) }
        let imps = rs.improvementOrder.compactMap { rs.improvements[$0] }.filter { $0.techRequired == t.name && ($0.uniqueTo == nil || s.civMatches(civ, $0.uniqueTo!, viewer: civId)) }
        if !imps.isEmpty { lines.append(L("Tile improvements enabled") + ": " + imps.map { L($0.name) }.joined(separator: ", ")) }
        return lines.map { L($0) }.joined(separator: "\n")
    }

    // MARK: buildings (BuildingDescriptions.getCivilopediaTextLines)
    static func building(_ b: BuildingDef, rs: Ruleset, s: GameState?) -> [PediaLine] {
        var out: [PediaLine] = []
        if b.isAnyWonder { out.append(fl(L(b.isWonder ? "Wonder" : "National Wonder"))) }
        if let u = b.uniqueTo {
            out.append(blank)
            out.append(fl(L("Unique to [\(u)]"), link: "Nation/\(u)"))
            if let r = b.replaces { out.append(fl(L("Replaces [\(r)]"), link: rs.buildings[r].map(buildingLink) ?? "", indent: 1)) }
        }
        let cost = rs.cost(of: b)
        if cost > 0 {
            var parts = ["\(cost)⚙️"]
            if !b.isAnyWonder && !b.uniques.contains("Cannot be purchased") { parts.append("\(civilopediaGoldCost(cost: cost, hurryCostModifier: b.hurryCostModifier))💰") }
            out.append(fl(L("Cost") + ": " + parts.joined(separator: "/")))
        }
        if let t = b.requiredTech { out.append(fl(L("Required tech: [\(t)]"), link: "Technology/\(t)")) }
        if let rb = b.requiredBuilding { out.append(fl(L("Requires [\(rb)] to be built in the city"), link: (rs.buildings[rb]?.isWonder == true ? "Wonder/" : "Building/") + rb)) }
        if let r = b.requiredResource {
            out.append(blank)
            out.append(fl(consumesText(r, 1, stockpiled: rs.resources[r]?.isStockpiled ?? false, available: -1), link: "Resources/\(r)"))
        }
        // Stat order (Production, Food, Gold, Science, Culture, Happiness, Faith), as Stats iterates
        let pc = b.percentStatBonus
        let percent = [("Production", pc.production), ("Food", pc.food), ("Gold", pc.gold), ("Science", pc.science), ("Culture", pc.culture), ("Happiness", pc.happiness), ("Faith", pc.faith)].filter { $0.1 != 0 }
        if !b.uniques.isEmpty || !b.stats.isEmpty || !percent.isEmpty || !b.greatPersonPoints.isEmpty || b.specialistSlots.values.contains(where: { $0 != 0 }) { out.append(blank) }
        out += uniqueFLines(b.uniques, rs: rs, s: s, colorConsumesResources: true)
        if !b.stats.isEmpty { out.append(fl(statsLine(b.stats))) }
        for (name, v) in percent { out.append(fl((v > 0 ? "+" : "") + Translations.shared.numberTr(Int(v)) + "% " + L(name))) }
        for (gp, v) in b.greatPersonPoints.sorted(by: { $0.key < $1.key }) { out.append(fl("+\(v) " + L("[\(gp)] points"), link: "Unit/\(gp)")) }
        for (sp, n) in b.specialistSlots.sorted(by: { $0.key < $1.key }) where n != 0 { out.append(fl("+\(n) " + L("[\(sp)] slots"))) }
        if !b.requiredNearbyImprovedResources.isEmpty {
            out.append(blank)
            out.append(fl(L("Requires at least one of the following resources improved near the city:")))
            out += b.requiredNearbyImprovedResources.map { fl(L($0), link: "Resource/\($0)", indent: 1) }
        }
        if b.cityStrength != 0 || b.cityHealth != 0 || b.maintenance != 0 { out.append(blank) }
        if b.cityStrength != 0 { out.append(fl(L("City strength") + " +" + kotlinDouble(b.cityStrength))) }
        if b.cityHealth != 0 { out.append(fl(L("City health") + " +\(b.cityHealth)")) }
        if b.maintenance != 0 { out.append(fl(L("Maintenance cost") + ": \(b.maintenance) " + L("Gold"))) }
        // the buildings (ruleset order) replacing this one or naming it in a unique, then Belief.getCivilopediaTextMatching
        let seeAlso = rs.buildingOrder.compactMap { rs.buildings[$0] }.filter { $0.replaces == b.name || $0.uniqueObjects.contains { $0.params.contains(b.name) } }
            .map { fl(L($0.name), link: buildingLink($0), indent: 1) } + beliefLinesMatching(b.name, rs: rs, s: s)
        if !seeAlso.isEmpty { out.append(blank); out.append(fl(L("See also") + ":")); out += seeAlso }
        return out
    }
    /// Unciv Belief.getBeliefsMatching: the beliefs (ruleset order), not hidden from the Civilopedia, with a unique
    /// parameter that is exactly this name
    static func beliefsMatching(_ name: String, rs: Ruleset, s: GameState?) -> [String] {
        rs.beliefList.filter { b in
            let uniques = b.uniqueObjects
            return !hiddenFromCivilopedia(uniques, s: s, rs: rs) && uniques.contains { $0.params.contains(name) }
        }.map { $0.name }
    }
    /// BuildingDescriptions.getDifferences: what a unique building changes versus the one it replaces.
    static func buildingDifferences(_ original: BuildingDef, _ replacement: BuildingDef, rs: Ruleset) -> [String] {
        var out: [String] = []
        func cmp(_ name: String, _ a: Double, _ b: Double) { if a != b { out.append("  \(L(name)) " + L("[\(Int(b))] vs [\(Int(a))]")) } }
        // Stat.entries order: Production, Food, Gold, Science, Culture, Happiness, Faith - the stats, then the percentages
        cmp("Production", original.stats.production, replacement.stats.production); cmp("Food", original.stats.food, replacement.stats.food); cmp("Gold", original.stats.gold, replacement.stats.gold)
        cmp("Science", original.stats.science, replacement.stats.science); cmp("Culture", original.stats.culture, replacement.stats.culture); cmp("Happiness", original.stats.happiness, replacement.stats.happiness); cmp("Faith", original.stats.faith, replacement.stats.faith)
        for (name, a, b) in [("Production", original.percentStatBonus.production, replacement.percentStatBonus.production), ("Food", original.percentStatBonus.food, replacement.percentStatBonus.food), ("Gold", original.percentStatBonus.gold, replacement.percentStatBonus.gold), ("Science", original.percentStatBonus.science, replacement.percentStatBonus.science), ("Culture", original.percentStatBonus.culture, replacement.percentStatBonus.culture), ("Happiness", original.percentStatBonus.happiness, replacement.percentStatBonus.happiness), ("Faith", original.percentStatBonus.faith, replacement.percentStatBonus.faith)] where a != b { out.append("  " + L("[\(Int(b))]% [\(name)] vs [\(Int(a))]% [\(name)]")) }
        if original.maintenance != replacement.maintenance { out.append("  " + L("Maintenance") + " " + L("[\(replacement.maintenance)] vs [\(original.maintenance)]")) }
        if rs.cost(of: original) != rs.cost(of: replacement) { out.append("  " + L("Cost") + " " + L("[\(rs.cost(of: replacement))] vs [\(rs.cost(of: original))]")) }
        // cityStrength is a Double: "[6.0] vs [5.0]"
        if original.cityStrength != replacement.cityStrength { out.append("  " + L("City strength") + " " + L("[\(kotlinDouble(replacement.cityStrength))] vs [\(kotlinDouble(original.cityStrength))]")) }
        if original.cityHealth != replacement.cityHealth { out.append("  " + L("City health") + " " + L("[\(replacement.cityHealth)] vs [\(original.cityHealth)]")) }
        // Unciv: a new ability is FormattedLine(unique.getDisplayText(), indent=1); a lost one keeps `unique.text.tr()`
        for u in replacement.uniques where !original.uniques.contains(u) && isPlayerFacing(u) { out.append("  " + L(displayText(u))) }
        for u in original.uniques where !replacement.uniques.contains(u) && isPlayerFacing(u) { out.append("  " + L("Lost ability (vs [\(original.name)]): [\(L(u))]")) }
        return out
    }

    // MARK: units (BaseUnitDescriptions.getCivilopediaTextLines)
    static func unit(_ u: UnitDef, rs: Ruleset, s: GameState? = nil) -> [PediaLine] {
        var out: [PediaLine] = []
        out.append(fl(L("Unit type") + ": " + L(u.unitType), link: rs.unitTypes[u.unitType] != nil ? "UnitType/\(u.unitType)" : nil))
        var stats: [String] = []
        if u.strength != 0 { stats.append("\(u.strength)⚔️") }
        if u.rangedStrength != 0 { stats.append("\(u.rangedStrength)🏹"); stats.append("\(u.range)⭕") }
        if u.movement != 0 && !u.isAir { stats.append("\(u.movement)👟") }
        if !stats.isEmpty { out.append(fl(stats.joined(separator: ", "))) }
        if u.cost > 0 {
            var parts = ["\(u.cost)⚙️"]
            if !u.uniques.contains("Cannot be purchased") && !u.uniques.contains("Unbuildable") { parts.append("\(civilopediaGoldCost(cost: u.cost, hurryCostModifier: u.hurryCostModifier))💰") }
            out.append(fl(L("Cost") + ": " + parts.joined(separator: "/")))
        }
        if u.interceptRange > 0 { out.append(fl(L("Air Intercept Range: [\(u.interceptRange)]"))) }
        out += uniqueFLines(u.uniques, rs: rs, s: s, colorConsumesResources: true)
        if let r = u.requiredResource {
            out.append(blank)
            out.append(fl(consumesText(r, 1, stockpiled: rs.resources[r]?.isStockpiled ?? false, available: -1), link: "Resources/\(r)"))
        }
        if let n = u.uniqueTo {
            out.append(blank)
            out.append(fl(L("Unique to [\(n)]"), link: "Nation/\(n)"))
            if let r = u.replaces { out.append(fl(L("Replaces [\(r)]"), link: "Unit/\(r)", indent: 1)) }
        }
        if u.requiredTech != nil || u.upgradesTo != nil || u.obsoleteTech != nil { out.append(blank) }
        if let t = u.requiredTech { out.append(fl(L("Required tech: [\(t)]"), link: "Technology/\(t)")) }
        // ruleset.units.filterValues { ... }.keys: ruleset order; several are listed sorted
        let from = rs.unitOrder.compactMap { rs.units[$0] }.filter { ($0.upgradesTo == u.name || ($0.upgradesTo != nil && $0.upgradesTo == u.replaces)) && ($0.uniqueTo == nil || $0.uniqueTo == u.uniqueTo) }.map { $0.name }
        if from.count == 1 { out.append(fl(L("Can upgrade from [\(from[0])]"), link: "Unit/\(from[0])")) }
        else if from.count > 1 {
            out.append(blank); out.append(fl(L("Can upgrade from:")))
            out += from.sorted().map { fl(L($0), link: "Unit/\($0)", indent: 2) }
            out.append(blank)
        }
        if let up = u.upgradesTo { out.append(fl(L("Upgrades to [\(up)]"), link: "Unit/\(up)")) }
        if let ob = u.obsoleteTech { out.append(fl(L("Obsolete with [\(ob)]"), link: "Technology/\(ob)")) }
        if !u.promotions.isEmpty {
            out.append(blank)
            // "{Free promotion:} X" alone, else "{Free promotions:} X," then "Y," ... "Z" indented, each linked
            for (i, p) in promotionSetOrder(u).enumerated() {
                let head = u.promotions.count == 1 ? L("Free promotion:") + " " : i == 0 ? L("Free promotions:") + " " : ""
                let tail = (u.promotions.count == 1 || i == u.promotions.count - 1) ? "" : ","
                out.append(fl(head + L(p) + tail, link: "Promotions/\(p)", indent: i == 0 ? 0 : 1))
            }
        }
        // ruleset.units in order: the units replacing this one
        let seeAlso = rs.unitOrder.compactMap { rs.units[$0] }.filter { $0.replaces == u.name }.map { fl(L($0.name), link: "Unit/\($0.name)", indent: 1) }
        if !seeAlso.isEmpty { out.append(blank); out.append(fl(L("See also") + ":")); out += seeAlso }
        return out
    }
    /// Unciv BaseUnitDescriptions.getDifferences (the cost is left out): strength; ranged strength and range gained, lost
    /// or changed; movement; the resources no longer needed; the new abilities; the lost ones; then each new free
    /// promotion with its effects.
    static func unitDifferences(_ original: UnitDef, _ better: UnitDef, rs: Ruleset) -> [String] {
        unitDifferenceLines(original, better, rs: rs).map(\.text)
    }
    /// unitDifferences with Unciv's second member of each Pair: the link a line's icon comes from - a resource no longer
    /// needed ("Resource/$resource") and a new free promotion (promotion.makeLink()), nothing for the others.
    static func unitDifferenceLines(_ original: UnitDef, _ better: UnitDef, rs: Ruleset) -> [(text: String, icon: (name: String, folder: String)?)] {
        var out: [(text: String, icon: (name: String, folder: String)?)] = []
        func add(_ t: String, _ icon: (name: String, folder: String)? = nil) { out.append((t, icon)) }
        if better.strength != original.strength { add("⚔️ " + L("[\(better.strength)] vs [\(original.strength)]")) }
        if better.rangedStrength > 0 && original.rangedStrength == 0 { add(L("[Gained] 🏹 [\(better.rangedStrength)] ⭕ [\(better.range)]")) }
        else if better.rangedStrength == 0 && original.rangedStrength > 0 { add(L("[Lost] 🏹 [\(original.rangedStrength)] ⭕ [\(original.range)]")) }
        else {
            if better.rangedStrength != original.rangedStrength { add("🏹 " + L("[\(better.rangedStrength)] vs [\(original.rangedStrength)]")) }
            if better.range != original.range { add("⭕ " + L("[\(better.range)] vs [\(original.range)]")) }
        }
        if better.movement != original.movement { add("👟 " + L("[\(better.movement)] vs [\(original.movement)]")) }
        // getResourceRequirementsPerTurn(IgnoreConditionals).keys: the requiredResource, then every "Consumes [] []"
        func resources(_ u: UnitDef) -> [String] {
            var out: [String] = u.requiredResource.map { [$0] } ?? []
            for x in rs.unitRulesetUniques[u.name] ?? u.uniqueObjects where x.pattern == "Consumes [] []" && !out.contains(x.param(1)) { out.append(x.param(1)) }
            return out
        }
        let betterResources = resources(better)
        for r in resources(original) where !betterResources.contains(r) { add(L("[\(r)] not required"), (r, "ResourceIcons")) }
        for u in better.uniqueObjects where !original.uniques.contains(u.text) && isPlayerFacing(u.text) { add(L(u.text)) }
        for u in original.uniqueObjects where !better.uniques.contains(u.text) && isPlayerFacing(u.text) {
            add(L("Lost ability (vs [\(original.name)]): [\(L(displayText(u.text)))]"))
        }
        // "{promotion} (effects)", the effects being Promotion.uniquesToDescription joined with ", "
        for p in promotionSetOrder(better) where !original.promotions.contains(p) {
            let effects = (rs.promotions[p]?.uniques ?? []).filter(isPlayerFacing).map { L(displayText($0)) }.joined(separator: ", ")
            add(L(p) + " (" + effects + ")", (p, "PromotionIcons"))
        }
        return out
    }
    /// Unciv ImprovementDescriptions.getDifferences: stats, terrains gained and lost, build turns, new and lost abilities.
    static func improvementDifferences(_ original: ImprovementDef, _ replacement: ImprovementDef) -> [String] {
        var out: [String] = []
        for (name, a, b) in [("Production", original.stats.production, replacement.stats.production), ("Food", original.stats.food, replacement.stats.food), ("Gold", original.stats.gold, replacement.stats.gold), ("Science", original.stats.science, replacement.stats.science), ("Culture", original.stats.culture, replacement.stats.culture), ("Happiness", original.stats.happiness, replacement.stats.happiness), ("Faith", original.stats.faith, replacement.stats.faith)] where a != b {
            out.append(L(name) + " " + L("[\(Int(b))] vs [\(Int(a))]"))
        }
        for t in replacement.terrainsCanBeBuiltOn where !original.terrainsCanBeBuiltOn.contains(t) { out.append(L("Can be built on [\(t)]")) }
        for t in original.terrainsCanBeBuiltOn where !replacement.terrainsCanBeBuiltOn.contains(t) { out.append(L("Cannot be built on [\(t)]")) }
        if replacement.turnsToBuild != original.turnsToBuild { out.append(L("Turns to build") + " " + L("[\(replacement.turnsToBuild)] vs [\(original.turnsToBuild)]")) }
        for u in replacement.uniques where !original.uniques.contains(u) && isPlayerFacing(u) { out.append(L(displayText(u))) }
        for u in original.uniques where !replacement.uniques.contains(u) && isPlayerFacing(u) { out.append(L("Lost ability (vs [\(original.name)]): [\(L(displayText(u)))]")) }
        return out
    }

    // MARK: improvements (ImprovementDescriptions.getCivilopediaTextLines)
    static func improvement(_ i: ImprovementDef, rs: Ruleset, s: GameState?) -> [PediaLine] {
        var out: [PediaLine] = []
        if !i.stats.isEmpty { out.append(fl(statsLine(i.stats))) }
        if let n = i.uniqueTo { out.append(blank); out.append(fl(L("Unique to [\(n)]"), link: "Nation/\(n)")) }
        if let r = i.replaces { out.append(fl(L("Replaces [\(r)]"), link: rs.improvements[r] != nil ? "Improvement/\(r)" : nil, indent: 1)) }
        let constructors = constructorUnits(i, rs: rs), creating = creatingUnits(i, rs: rs)
        let creatorExists = !constructors.isEmpty || !creating.isEmpty
        if creatorExists && !i.terrainsCanBeBuiltOn.isEmpty {
            out.append(blank)
            if i.terrainsCanBeBuiltOn.count == 1 { let t = i.terrainsCanBeBuiltOn[0]; out.append(fl(L("Can be built on") + " " + L(t), link: "Terrain/\(t)")) }
            else { out.append(fl(L("Can be built on") + ":")); out += i.terrainsCanBeBuiltOn.map { fl(L($0), link: "Terrain/\($0)", indent: 1) } }
        }
        // ruleset.tileResources in order: "[stats] <in [resource] tiles>" for each resource this improvement improves
        var addedLine = false
        for r in rs.resourcesInOrder where !r.improvementStats.isEmpty && improvements(of: r, rs: rs).contains(i.name) {
            if !addedLine { addedLine = true; out.append(blank) }
            out.append(fl(L("[\(r.improvementStats.uncivText)] <in [\(r.name)] tiles>"), link: "Resource/\(r.name)"))
        }
        if let t = i.techRequired { out.append(blank); out.append(fl(L("Required tech: [\(t)]"), link: "Technology/\(t)")) }
        out += uniqueFLines(i.uniques, rs: rs, s: s)
        // Unciv: only where a unit can make it, it has stats, it neither skips nor removes the features itself, and none
        // of its terrainsCanBeBuiltOn is a terrain (an empty list passes, as Kotlin's none() does)
        if creatorExists && !i.stats.isEmpty && !i.uniqueObjects.contains(where: { $0.pattern == "Does not need removal of []" })
            && !i.uniqueObjects.contains(where: { $0.pattern == "Removes removable features when built" })
            && i.terrainsCanBeBuiltOn.allSatisfy({ rs.terrains[$0] == nil }) { out.append(fl(L("Needs removal of terrain features to be built"))) }
        // Unciv: ruins list their possible rewards, less those isHiddenFromCivilopedia hides - in a game through
        // RuinReward.isUnavailableBySettings (the difficulty in excludedDifficulties, the settings' conditionals) - each
        // (starred) followed by its civilopediaText
        if i.uniques.contains("Provides a random bonus when entered") && !rs.ruins.isEmpty {
            out.append(blank)
            out.append(fl(L("The possible rewards are:")))
            for reward in rs.ruins {
                let uniques = reward.uniqueObjects
                if hiddenFromCivilopedia(uniques, s: s, rs: rs, unavailable: { reward.excludedDifficulties.contains($0.settings.difficulty) || $0.isUnavailableBySettings(uniques) }) { continue }
                out.append(fl("★ " + L(reward.name)))
                out += reward.civilopediaText.map { fl(L($0.text), link: $0.link) }
            }
        }
        if creatorExists { out.append(blank) }
        for c in constructors { out.append(fl(L("Can be constructed by") + " " + L(c.name), link: "Unit/\(c.name)")) }
        for c in creating { out.append(fl(L("Can be created instantly by") + " " + L(c.name), link: "Unit/\(c.name)")) }
        // the improvements (ruleset order) replacing this one, then Belief.getCivilopediaTextMatching
        let seeAlso = rs.improvementOrder.compactMap { rs.improvements[$0] }.filter { $0.replaces == i.name }.map { fl(L($0.name), link: "Improvement/\($0.name)", indent: 1) }
            + beliefLinesMatching(i.name, rs: rs, s: s)
        if !seeAlso.isEmpty { out.append(blank); out.append(fl(L("See also") + ":")); out += seeAlso }
        return out
    }
    /// Unciv TileImprovement.getConstructorUnits: the units (ruleset order) whose "Can build [filter] improvements on
    /// tiles" matches the improvement itself, its terrains - expanded by their occursOn, the terrains of the resources a
    /// resource-only improvement improves and a removal's target - or those terrains' types; and, for an improvement
    /// that can go on water, the units that "May create improvements on water resources".
    static func constructorUnits(_ i: ImprovementDef, rs: Ruleset) -> [UnitDef] {
        if i.uniqueObjects.contains(where: { $0.pattern == "Unbuildable" }) { return [] }
        let canOnly = Set(i.uniqueObjects.filter { $0.pattern == "Can only be built on [] tiles" }.map { $0.param(0) == "Coastal" ? "Land" : $0.param(0) })
        let cannot = Set(i.uniqueObjects.filter { $0.pattern == "Cannot be built on [] tiles" }.map { $0.param(0) })
        var expandedList = i.terrainsCanBeBuiltOn
        expandedList += i.terrainsCanBeBuiltOn.compactMap { rs.terrains[$0] }.flatMap { $0.occursOn }
        if i.uniqueObjects.contains(where: { $0.pattern == "Can only be built to improve a resource" }) {
            expandedList += rs.resourcesInOrder.filter { rs.resourceImprovements[$0.name]?.contains(i.name) ?? false }.flatMap { $0.terrainsCanBeFoundOn }
        }
        if i.name.hasPrefix("Remove ") {
            let target = String(i.name.dropFirst("Remove ".count))
            expandedList.append(target)
            expandedList += rs.terrains[target]?.occursOn ?? []
            expandedList += rs.improvements[target]?.terrainsCanBeBuiltOn ?? []
        }
        var expanded = Set(expandedList.filter { !cannot.contains($0) })
        // the terrain types of those terrains, and any TerrainType named outright
        var types = Set(expanded.compactMap { rs.terrains[$0]?.type.rawValue } + ["Land", "Water", "TerrainFeature", "NaturalWonder"].filter { expanded.contains($0) })
            .filter { !cannot.contains($0) }
        if !canOnly.isEmpty && canOnly.isDisjoint(with: expanded) {
            expanded.removeAll()
            if !types.contains(where: { canOnly.contains($0) }) { types.removeAll() }
        }
        func matchesBuildImprovementsFilter(_ f: String) -> Bool { i.matchesFilter(f) || expanded.contains(f) || types.contains(f) }
        return rs.unitOrder.compactMap { rs.units[$0] }.filter { u in
            let uniques = rs.unitRulesetUniques[u.name] ?? u.uniqueObjects
            return i.turnsToBuild != -1 && uniques.contains { $0.pattern == "Can build [] improvements on tiles" && matchesBuildImprovementsFilter($0.param(0)) }
                || uniques.contains { $0.pattern == "May create improvements on water resources" } && types.contains("Water")
        }
    }
    /// Unciv TileImprovement.getCreatingUnits: the units (ruleset order) that "Can instantly construct a [this] improvement"
    static func creatingUnits(_ i: ImprovementDef, rs: Ruleset) -> [UnitDef] {
        rs.unitOrder.compactMap { rs.units[$0] }.filter { u in
            (rs.unitRulesetUniques[u.name] ?? u.uniqueObjects).contains { $0.pattern == "Can instantly construct a [] improvement" && $0.param(0) == i.name }
        }
    }

    // MARK: resources (ResourceDescriptions.getCivilopediaTextLines)
    static func resource(_ r: ResourceDef, rs: Ruleset, s: GameState?) -> [PediaLine] {
        var out: [PediaLine] = []
        out.append(fl(L("\(r.resourceType) resource")))   // header 4, the type's colour
        out.append(blank)
        out += uniqueFLines(r.uniques, rs: rs, s: s)
        if !r.stats.isEmpty { out.append(fl(statsLine(r.stats))) }
        if let t = r.revealedBy, !t.isEmpty { out.append(blank); out.append(fl(L("Revealed by:"))); out.append(fl(L(t), link: "Technology/\(t)", indent: 1)) }
        if !r.terrainsCanBeFoundOn.isEmpty {
            out.append(blank)
            if r.terrainsCanBeFoundOn.count == 1 { let t = r.terrainsCanBeFoundOn[0]; out.append(fl(L("Can be found on") + " " + L(t), link: "Terrain/\(t)")) }
            else { out.append(fl(L("Can be found on") + ":")); out += r.terrainsCanBeFoundOn.map { fl(L($0), link: "Terrain/\($0)", indent: 1) } }
        }
        // one "Improved by [X]" per improvement of getImprovements, each followed by the bonus stats
        for imp in improvements(of: r, rs: rs) {
            out.append(blank)
            out.append(fl(L("Improved by [\(imp)]"), link: "Improvement/\(imp)"))
            if !r.improvementStats.isEmpty { out.append(fl(L("Bonus stats for improvement") + ": " + statsLine(r.improvementStats))) }
        }
        // every list below walks its ruleset file in order, as Unciv's LinkedHashMaps do
        func provides(_ us: [Unique]) -> Bool { us.contains { $0.pattern == "Provides [] []" && $0.param(1) == r.name } }
        func list(_ header: String, _ items: [PediaLine]) { if !items.isEmpty { out.append(blank); out.append(fl(L(header) + ":")); out += items } }
        list("Improvements that provide this resource", rs.improvementOrder.compactMap { rs.improvements[$0] }.filter { provides($0.uniqueObjects) }.map { fl(L($0.name), link: "Improvement/\($0.name)", indent: 1) })
        list("Buildings that provide this resource", rs.buildingOrder.compactMap { rs.buildings[$0] }.filter { provides($0.uniqueObjects) }.map { fl(L($0.name), link: buildingLink($0), indent: 1) })
        list("Technologies that provide this resource", rs.techOrder.compactMap { rs.techs[$0] }.filter { provides($0.uniqueObjects) }.map { fl(L($0.name), link: "Technology/\($0.name)", indent: 1) })
        // getResourceRequirementsPerTurn(IgnoreConditionals).containsKey: the requiredResource or any "Consumes [amount] [resource]"
        func consumes(_ requiredResource: String?, _ us: [Unique]) -> Bool { requiredResource == r.name || us.contains { $0.pattern == "Consumes [] []" && $0.param(1) == r.name } }
        list("Buildings that consume this resource", rs.buildingOrder.compactMap { rs.buildings[$0] }.filter { consumes($0.requiredResource, $0.uniqueObjects) }.map { fl(L($0.name), link: buildingLink($0), indent: 1) })
        // Unciv's own header keys end in ": " here
        let consumersU = rs.unitOrder.compactMap { rs.units[$0] }.filter { consumes($0.requiredResource, rs.unitRulesetUniques[$0.name] ?? $0.uniqueObjects) }
        if !consumersU.isEmpty { out.append(blank); out.append(fl(L("Units that consume this resource") + ": ")); out += consumersU.map { fl(L($0.name), link: "Unit/\($0.name)", indent: 1) } }
        let requiring = rs.buildingOrder.compactMap { rs.buildings[$0] }.filter { $0.requiredNearbyImprovedResources.contains(r.name) }
        if !requiring.isEmpty { out.append(blank); out.append(fl(L("Buildings that require this resource improved near the city") + ": ")); out += requiring.map { fl(L($0.name), link: buildingLink($0), indent: 1) } }
        // Belief.getCivilopediaTextMatching(withSeeAlso = true): its own empty line and header
        let beliefs = beliefLinesMatching(r.name, rs: rs, s: s)
        if !beliefs.isEmpty { out.append(blank); out.append(fl(L("See also") + ":")); out += beliefs }
        return out
    }
    /// Unciv TileResource.getImprovements in its LinkedHashSet order: the resource's improvement, its improvedBy, then
    /// (ruleset order) every improvement that "Improves [this] resource in this tile" - the ones Ruleset.resourceImprovements
    /// holds - or replaces one already listed.
    private static func improvements(of r: ResourceDef, rs: Ruleset) -> [String] {
        var out: [String] = []
        func add(_ n: String) { if !out.contains(n) { out.append(n) } }
        if let i = r.improvement { add(i) }
        r.improvedBy.forEach(add)
        let improving = rs.resourceImprovements[r.name] ?? []
        for imp in rs.improvementOrder.compactMap({ rs.improvements[$0] }) where improving.contains(imp.name) || imp.replaces.map({ out.contains($0) }) == true {
            add(imp.name)
        }
        return out
    }

    // MARK: technologies (TechnologyDescriptions.getCivilopediaTextLines)
    /// Unciv TechnologyDescriptions.getCivilopediaTextLines: the Civilopedia page, which knows no civ (getEnabledUnits,
    /// getEnabledBuildings and getObsoletedObjects with civInfo = null). `s` is the game in progress, if any - the one
    /// isHiddenFromCivilopedia reads through UncivGame.getGameInfoOrNull.
    static func technology(_ t: TechDef, rs: Ruleset, s: GameState?) -> [PediaLine] {
        var out: [PediaLine] = []
        if !t.era.isEmpty { out.append(fl(L(t.era))) }   // header 3 in the era's colour, no link
        out.append(blank)
        out.append(fl(L("Cost") + ": \(t.cost)🔬"))
        if !t.prerequisites.isEmpty {
            out.append(blank)
            if t.prerequisites.count == 1 { out.append(fl(L("Required tech: [\(t.prerequisites[0])]"), link: "Technology/\(t.prerequisites[0])")) }
            else { out.append(fl(L("Requires all of the following:"))); out += t.prerequisites.map { fl(L($0), link: "Technology/\($0)") } }
        }
        // ruleset.technologies.values.filter { name in it.prerequisites }
        let leadsTo = rs.techOrder.compactMap { rs.techs[$0] }.filter { $0.prerequisites.contains(t.name) }.map { $0.name }
        if !leadsTo.isEmpty {
            out.append(blank)
            if leadsTo.count == 1 { out.append(fl(L("Leads to [\(leadsTo[0])]"), link: "Technology/\(leadsTo[0])")) }
            else { out.append(fl(L("Leads to:"))); out += leadsTo.map { fl(L($0), link: "Technology/\($0)") } }
        }
        out += uniqueFLines(t.uniques, rs: rs, s: s)
        let affected = affectedImprovements(t.name, rs: rs)
        if !affected.isEmpty { out.append(blank); out += affected.map { fl(L($0.text), link: "Improvement/\($0.improvement.name)") } }
        // getEnabledUnits(name, ruleset, null): no unique units, none hidden from the Civilopedia
        let units = rs.unitOrder.compactMap { rs.units[$0] }.filter {
            requiredTechs($0.requiredTech, $0.uniqueObjects).contains(t.name) && $0.uniqueTo == nil && !hiddenFromCivilopedia(unit: $0, s: s, rs: rs)
        }
        if !units.isEmpty {
            out.append(blank); out.append(fl(L("Units enabled") + ":"))
            out += units.map { fl(L($0.name) + " (" + unitShortUnciv($0, tech: t.name) + ")", link: "Unit/\($0.name)") }
        }
        // getEnabledBuildings(name, ruleset, null).partition { isAnyWonder }: the wonders first
        let buildings = rs.buildingOrder.compactMap { rs.buildings[$0] }.filter {
            requiredTechs($0.requiredTech, $0.uniqueObjects).contains(t.name) && $0.uniqueTo == nil && !hiddenFromCivilopedia(building: $0, s: s, rs: rs)
        }
        let wonders = buildings.filter { $0.isAnyWonder }, regular = buildings.filter { !$0.isAnyWonder }
        if !wonders.isEmpty {
            out.append(blank); out.append(fl(L("Wonders enabled") + ":"))
            out += wonders.map { fl(L($0.name) + " (" + buildingShortUnciv($0, tech: t.name) + ")", link: buildingLink($0)) }
        }
        if !regular.isEmpty {
            out.append(blank); out.append(fl(L("Buildings enabled") + ":"))
            out += regular.map { fl(L($0.name) + " (" + buildingShortUnciv($0, tech: t.name) + ")", link: buildingLink($0)) }
        }
        // getObsoletedObjects(name, ruleset, null): the Civilopedia's buildings, every resource and the improvements unique
        // to no nation that are "Obsolete with [this tech]" - never units, whose obsoleteTech only their own page shows
        func obsoletes(_ us: [Unique]) -> Bool { us.contains { $0.pattern == "Obsolete with []" && $0.param(0) == t.name } }
        let obsoleted = rs.buildingOrder.compactMap { rs.buildings[$0] }.filter { $0.uniqueTo == nil && !hiddenFromCivilopedia(building: $0, s: s, rs: rs) && obsoletes($0.uniqueObjects) }.map { ($0.name, buildingLink($0)) }
            + rs.resourcesInOrder.filter { obsoletes($0.uniqueObjects) }.map { ($0.name, "Resource/\($0.name)") }
            + rs.improvementOrder.compactMap { rs.improvements[$0] }.filter { $0.uniqueTo == nil && obsoletes($0.uniqueObjects) }.map { ($0.name, "Improvement/\($0.name)") }
        if !obsoleted.isEmpty { out.append(blank); out += obsoleted.map { fl(L("[\($0.0)] obsoleted"), link: $0.1) } }
        let revealed = rs.resourcesInOrder.filter { $0.revealedBy == t.name }
        if !revealed.isEmpty { out.append(blank); out += revealed.map { fl(L("Reveals [\($0.name)] on the map"), link: "Resource/\($0.name)") } }
        // ruleset.tileImprovements.values.filter { techRequired == name }: every one, nation-unique ones too
        let imps = rs.improvementOrder.compactMap { rs.improvements[$0] }.filter { $0.techRequired == t.name }
        if !imps.isEmpty { out.append(blank); out.append(fl(L("Tile improvements enabled") + ":")); out += imps.map { fl(L($0.name), link: "Improvement/\($0.name)") } }
        // getSeeAlsoObjects: every ruleset object with a unique that this tech switches on or off, except the
        // improvement stats getAffectedImprovements already listed
        let seeAlso = allRulesetObjects(rs).filter { o in
            o.uniques.contains { u in
                u.conditionals.contains { ($0.pattern == "after discovering []" || $0.pattern == "before discovering []") && $0.param(0) == t.name }
                    && !isImprovementStatsEnabledByTech(u, t.name)
            }
        }
        if !seeAlso.isEmpty { out.append(blank); out.append(fl(L("See also") + ":")); out += seeAlso.map { fl(L($0.name), link: $0.link) } }
        return out
    }
    /// Unciv TechnologyDescriptions.isImprovementStatsEnabledByTech: a Stats "[stats]" or ImprovementStatsOnTile
    /// "[stats] from [tileFilter] tiles" unique with an "after discovering [tech]" conditional for this tech.
    private static func isImprovementStatsEnabledByTech(_ u: Unique, _ tech: String) -> Bool {
        (u.pattern == "[]" || u.pattern == "[] from [] tiles") && u.conditionals.contains { $0.pattern == "after discovering []" && $0.param(0) == tech }
    }
    /// Unciv TechnologyDescriptions.getAffectedImprovements with ImprovementAndUnique.getText: "[stats] from every
    /// [improvement]" (" on [tileFilter] tiles" for the tile form), every improvement in ruleset order.
    private static func affectedImprovements(_ tech: String, rs: Ruleset) -> [(improvement: ImprovementDef, text: String)] {
        var out: [(improvement: ImprovementDef, text: String)] = []
        for imp in rs.improvementOrder.compactMap({ rs.improvements[$0] }) {
            for u in imp.uniqueObjects where isImprovementStatsEnabledByTech(u, tech) {
                out.append((imp, "[\(u.param(0))] from every [\(imp.name)]" + (u.pattern == "[]" ? "" : " on [\(u.param(1))] tiles")))
            }
        }
        return out
    }
    /// Unciv Ruleset.allRulesetObjects: every ruleset object with its uniques, in RulesetFile order (Beliefs, Buildings,
    /// Eras, Nations, Policies, Techs, Terrains, Tutorials, TileImprovements, TileResources, Units, UnitPromotions,
    /// UnitNameGroups, UnitTypes, VictoryTypes, Personalities, Events and their choices, GlobalUniques, Speeds, Ruins),
    /// each file in its own order. Unit name groups, victory types and speeds carry no uniques here.
    private nonisolated(unsafe) static var allObjectsRuleset: Ruleset? = nil
    private nonisolated(unsafe) static var allObjectsCache: [(name: String, uniques: [Unique], link: String)] = []
    /// Each with its makeLink(): "Belief/…", "Wonder/…" or "Building/…", "Era/…", … - "" for a ruin reward or an event's choice.
    static func allRulesetObjects(_ rs: Ruleset) -> [(name: String, uniques: [Unique], link: String)] {
        // parsed once per ruleset: the Civilopedia search builds every tech page
        if allObjectsRuleset === rs { return allObjectsCache }
        var out: [(name: String, uniques: [Unique], link: String)] = []
        defer { allObjectsRuleset = rs; allObjectsCache = out }
        func add(_ name: String, _ uniques: [String], _ category: String) { out.append((name, uniques.map(Unique.init), category.isEmpty ? "" : category + "/" + name)) }
        for b in rs.beliefList { add(b.name, b.uniques, "Belief") }
        for n in rs.buildingOrder { if let b = rs.buildings[n] { out.append((b.name, b.uniqueObjects, buildingLink(b))) } }
        for e in rs.eras { add(e.name, e.uniques, "Era") }
        for n in rs.nationOrder { if let x = rs.nations[n] { add(x.name, x.uniques, "Nation") } }
        for b in rs.policyBranches { add(b.name, b.uniques, "Policy"); for p in b.policies { add(p.name, p.uniques, "Policy") } }
        for n in rs.techOrder { if let x = rs.techs[n] { add(x.name, x.uniques, "Technology") } }
        for n in rs.terrainOrder { if let x = rs.terrains[n] { out.append((x.name, x.uniqueObjects, "Terrain/\(x.name)")) } }
        for x in Ruleset.tutorials { add(x.name, x.uniques, "Tutorial") }
        for n in rs.improvementOrder { if let x = rs.improvements[n] { out.append((x.name, x.uniqueObjects, "Improvement/\(x.name)")) } }
        for x in rs.resourcesInOrder { add(x.name, x.uniques, "Resource") }
        for n in rs.unitOrder { if let x = rs.units[n] { out.append((x.name, x.uniqueObjects, "Unit/\(x.name)")) } }
        for x in rs.promotionOrder { add(x.name, x.uniques, "Promotion") }
        for n in rs.unitTypeOrder { if let x = rs.unitTypes[n] { out.append((x.name, x.uniqueObjects, "UnitType/\(x.name)")) } }
        for n in rs.personalityOrder { if let x = rs.personalities[n] { add(x.name, x.uniques, "Personality") } }
        for e in rs.events { out.append((e.name, e.uniqueObjects, "Event/\(e.name)")); for c in e.choices { out.append((c.name, c.uniqueObjects, "")) } }
        out.append(("Global Uniques", rs.globalUniques, "Tutorial/Global Uniques"))
        for x in rs.ruins { add(x.name, x.uniques, "") }
        return out
    }

    // MARK: nations (NationDescriptions.getCivilopediaTextLinesImpl)
    /// `withoutHeader3`: Unciv NationTable's `getCivilopediaTextLines(ruleset).filter { it.header != 3 }` - the new game's
    /// nation card leaves out the centred "[leader] of [nation]" line, its own title saying it
    static func nation(_ n: NationDef, rs: Ruleset, s: GameState?, withoutHeader3: Bool = false) -> [PediaLine] {
        var out: [PediaLine] = []
        // getCityStateInfo: the type (header 4), "When Friends:" / "When Allies:" with their uniques (each after an empty
        // line, linked as uniques), the mercantile luxuries, then a separator
        if n.isCityState, let type = n.cityStateType, let def = rs.cityStateTypes[type] {
            out.append(fl(L("{Type}: {\(type)}")))
            var showResources = false
            func bonus(_ header: String, _ uniques: [String]) {
                let shown = uniques.filter(isPlayerFacing)
                guard !shown.isEmpty else { return }
                out.append(blank); out.append(fl(L(header) + " "))
                for u in shown {
                    let q = Unique(u)
                    out.append(fl(L(displayText(u)), link: uniqueLink(q, s: s), indent: 1))
                    if q.pattern == "Provides a unique luxury" { showResources = true }
                }
            }
            bonus("When Friends:", def.friendBonusUniques)
            bonus("When Allies:", def.allyBonusUniques)
            if showResources {
                let mercantile = rs.resourcesInOrder.filter { $0.uniques.contains("Can only be created by Mercantile City-States") }
                if !mercantile.isEmpty { out.append(blank); out.append(fl(L("The unique luxury is one of:"))); out += mercantile.map { fl(L($0.name), link: "Resource/\($0.name)", indent: 1) } }
            }
            out.append(blank)   // separator
        }
        if let leader = n.leaderName, !leader.isEmpty, !withoutHeader3 { out.append(fl(L("[\(leader)] of [\(n.name)]"))) }   // header 3, centred
        // `FormattedLine("{Personality}: {$personalityObj}", link = personalityObj.makeLink())` - the object's toString,
        // getShortDescription: the preferred victory type and the strongest focuses ("Pushy, Expansionistic")
        if let p = n.personality, let pd = rs.personalities[p] {
            out.append(fl(L("Personality") + ": " + pd.shortDescriptionParts.map { L($0) }.joined(separator: ", "), link: "Personality/\(p)"))
        }
        if !(n.leaderName ?? "").isEmpty || (n.personality.flatMap { rs.personalities[$0] } != nil) { out.append(blank) }
        if let un = n.uniqueName, !un.isEmpty { out.append(fl(L(un) + ":")) }   // header 4
        out += uniqueFLines(n.uniques, rs: rs, s: s, leading: false)
        out.append(blank)
        // Nation.getStartBias: the first bias after "Start bias:", each further one on its own indented line, each linked to
        // its terrain (the one in brackets for an "Avoid [X]")
        let biases = rs.startBias(of: n)
        for (index, bias) in biases.enumerated() {
            let target = bias.firstIndex(of: "[").map { i in String(bias[bias.index(after: i)...].prefix { $0 != "]" }) } ?? bias
            out.append(fl((index == 0 ? L("Start bias:") + " " : "") + L(bias), link: "Terrain/\(target)", indent: index == 0 ? 0 : 1))
        }
        if !biases.isEmpty { out.append(blank) }
        // getUniqueBuildingsText / getUniqueUnitsText / getUniqueImprovementsText: ruleset order, the nation's by
        // Nation.matchesFilter, none hidden from the Civilopedia, each after a separator
        for b in rs.buildingOrder.compactMap({ rs.buildings[$0] }) {
            guard let to = b.uniqueTo, nationMatches(n, to), !hiddenFromCivilopedia(building: b, s: s, rs: rs) else { continue }
            out.append(blank)   // separator
            out.append(fl(L(b.name) + " -", link: buildingLink(b)))
            if let r = b.replaces, let orig = rs.buildings[r] {
                out.append(fl(L("Replaces [\(orig.name)]"), link: buildingLink(orig), indent: 1))
                out += buildingDifferences(orig, b, rs: rs).map { fl(String($0.drop(while: { $0 == " " })), indent: 1) }
                out.append(blank)
            } else if let r = b.replaces { out.append(fl(L("Replaces [\(r)], which is not found in the ruleset!"), indent: 1)) }
            else { out.append(fl(buildingShortInfo(b).joined(separator: "\n"), indent: 1)) }   // getShortDescription(multiline = true)
        }
        for u in rs.unitOrder.compactMap({ rs.units[$0] }) {
            guard !hiddenFromCivilopedia(unit: u, s: s, rs: rs), let to = u.uniqueTo, nationMatches(n, to) else { continue }
            out.append(blank)   // separator
            out.append(fl(L(u.name) + " -", link: "Unit/\(u.name)"))
            if let r = u.replaces, let orig = rs.units[r] {
                out.append(fl(L("Replaces [\(orig.name)]"), link: "Unit/\(orig.name)", indent: 1))
                if u.cost != orig.cost { out.append(fl(L("Cost") + " " + L("[\(u.cost)] vs [\(orig.cost)]"), indent: 1)) }
                out += unitDifferenceLines(orig, u, rs: rs).map { fl($0.text, link: $0.icon.map { ic in (ic.folder == "PromotionIcons" ? "Promotion/" : "Resource/") + ic.name }, indent: 1) }
            } else if let r = u.replaces { out.append(fl(L("Replaces [\(r)], which is not found in the ruleset!"), indent: 1)) }
            else { out += unit(u, rs: rs, s: s).map { PediaLine("  " + $0.text, link: $0.link) } }
            out.append(blank)
        }
        for i in rs.improvementOrder.compactMap({ rs.improvements[$0] }) {
            guard !hiddenFromCivilopedia(i.uniqueObjects, s: s, rs: rs), let to = i.uniqueTo, nationMatches(n, to) else { continue }
            out.append(blank)   // separator
            out.append(fl(L(i.name), link: "Improvement/\(i.name)"))
            out.append(fl(statsLine(i.stats), indent: 1))
            if let r = i.replaces, let orig = rs.improvements[r] {
                out.append(fl(L("Replaces [\(orig.name)]"), link: "Improvement/\(orig.name)", indent: 1))
                out += improvementDifferences(orig, i).map { fl(String($0.drop(while: { $0 == " " })), indent: 1) }; out.append(blank)
            } else if let r = i.replaces { out.append(fl(L("Replaces [\(r)], which is not found in the ruleset!"), indent: 1)) }
            else {
                // Unciv ImprovementDescriptions.getShortDecription: "Can be built on" the first terrain, "or [x]" for the
                // others, then the uniques
                for (index, t) in i.terrainsCanBeBuiltOn.enumerated() {
                    out.append(index == 0 ? fl(L("Can be built on") + " " + L(t), link: "Terrain/\(t)", indent: 1) : fl(L("or [\(t)]"), link: "Terrain/\(t)", indent: 2))
                }
                out += uniqueFLines(i.uniques, rs: rs, s: s, leading: false).map { PediaLine("  " + $0.text, link: $0.link) }
            }
        }
        return out
    }
    /// Unciv Nation.matchesFilter with no game state: All/all, Major, City-States/City-State, the name, or a tag unique
    private static func nationMatches(_ n: NationDef, _ filter: String) -> Bool {
        MultiFilter.multiFilter(filter) { f in
            switch f {
            case "All", "all": return true
            case "Major": return !n.isBarbarian && !n.isCityState && n.name != "Spectator"   // Nation.isMajorCiv
            case "City-States", "City-State": return n.isCityState
            default: return f == n.name || n.uniqueObjects.contains { $0.pattern == f }
            }
        }
    }

    // MARK: terrain (Terrain.getCivilopediaTextLines)
    /// The lines in Unciv's order with its empty FormattedLine()s ("" - a spacer in the Civilopedia).
    static func terrain(_ t: Terrain, rs: Ruleset, s: GameState?) -> [PediaLine] {
        var out: [PediaLine] = []
        if t.type == .naturalWonder { out.append(fl(L("Natural Wonder"))) }
        if !t.stats.isEmpty || t.overrideStats {
            out.append(blank)
            out.append(fl(t.stats.isEmpty ? L("No yields") : statsLine(t.stats)))
            if t.overrideStats { out.append(fl(L("Overrides yields from underlying terrain"))) }
        }
        // Unciv: every terrain that the generator may place says where it occurs, not only features and wonders.
        if !t.occursOn.isEmpty, !t.uniques.contains("Doesn't generate naturally") {
            out.append(blank)
            // Unciv: "Occurs on [terrain]" for one, "Occurs on:" and a line each for several
            if t.occursOn.count == 1 { out.append(fl(L("Occurs on [\(t.occursOn[0])]"), link: "Terrain/\(t.occursOn[0])")) }
            else { out.append(fl(L("Occurs on:"))); out += t.occursOn.map { fl(L($0), link: "Terrain/\($0)", indent: 1) } }
        }
        // Unciv Terrain: ruleset.tileImprovements in its order that may be built here - "{Tile Improvements}:" and a line
        // each (ours: one line, sorted by the translated name)
        let improvements = rs.improvementOrder.compactMap { rs.improvements[$0] }.filter { $0.terrainsCanBeBuiltOn.contains(t.name) }.map { $0.name }
        if !improvements.isEmpty { out.append(fl(L("{Tile Improvements}:"))); out += improvements.map { fl(L($0), link: "Improvement/\($0)", indent: 1) } }
        // Unciv Terrain: a natural wonder says what it is placed on.
        if let into = t.turnsInto { out.append(fl(L("Placed on [\(into)]"), link: "Terrain/\(into)")) }
        // Unciv: ruleset.tileResources in its order - "May contain [resource]" for one, "May contain:" and a line each for several
        let resources = rs.resourcesInOrder.filter { $0.terrainsCanBeFoundOn.contains(t.name) }.map { $0.name }
        if !resources.isEmpty { out.append(blank) }
        if resources.count == 1 { out.append(fl(L("May contain [\(resources[0])]"), link: "Resource/\(resources[0])")) }
        else if !resources.isEmpty { out.append(fl(L("May contain:"))); out += resources.map { fl(L($0), link: "Resource/\($0)", indent: 1) } }
        out.append(blank)
        // Unciv Terrain: land that does not turn into something else and is not rough is open terrain.
        let showsAsLand = t.type == .land || (t.type == .terrainFeature && t.occursOn.contains { rs.terrains[$0]?.type == .land })
        if t.turnsInto == nil, showsAsLand, !t.isRough { out.append(fl(L("Open terrain"))) }
        out += uniqueFLines(t.uniques, rs: rs, s: s, leading: false)
        out.append(blank)
        if t.impassable { out.append(fl(L("Impassable"))) } else if t.movementCost > 0 { out.append(fl(L("Movement cost") + ": \(t.movementCost)")) }
        // (defenceBonus * 100).toInt() in Float
        if t.defenceBonus != 0 { out.append(fl(L("Defence bonus") + ": \(Int(Float(t.defenceBonus) * 100))%")) }
        // Unciv Terrain.getCivilopediaTextLines: buildings, then units (ruleset order) whose uniques name this terrain,
        // then Belief.getCivilopediaTextMatching
        let seeAlso = rs.buildingOrder.compactMap { rs.buildings[$0] }.filter { $0.uniqueObjects.contains { $0.params.contains(t.name) } }.map { fl(L($0.name), link: buildingLink($0), indent: 1) }
            + rs.unitOrder.compactMap { rs.units[$0] }.filter { $0.uniqueObjects.contains { $0.params.contains(t.name) } }.map { fl(L($0.name), link: "Unit/\($0.name)", indent: 1) }
            + beliefLinesMatching(t.name, rs: rs, s: s)
        if !seeAlso.isEmpty { out.append(blank); out.append(fl(L("See also") + ":")); out += seeAlso }
        return out
    }
}
