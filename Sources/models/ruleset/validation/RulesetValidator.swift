// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv RulesetValidator / RulesetErrorList: checks a mod (merged onto the base ruleset) for dangling references,
/// empty names, unknown uniques and missing files, with Unciv's severities.
enum RulesetErrorSeverity: Int, Comparable {
    case OK = 0, WarningOptionsOnly, Warning, ErrorOptionsOnly, Error
    static func < (a: RulesetErrorSeverity, b: RulesetErrorSeverity) -> Bool { a.rawValue < b.rawValue }
}
struct RulesetError: Identifiable { let id = UUID(); let text: String; let severity: RulesetErrorSeverity }

struct RulesetValidator {
    let ruleset: Ruleset
    let modName: String
    private var lines: [RulesetError] = []

    static func validate(mod: String, base: String? = nil) -> [RulesetError] {
        do {
            let rs = try Ruleset(named: base ?? Ruleset.currentBaseRuleset, mods: [mod])
            var v = RulesetValidator(ruleset: rs, modName: mod)
            v.run()
            return v.lines
        } catch {
            return [RulesetError(text: "Failed to load ruleset: \(error.localizedDescription)", severity: .Error)]
        }
    }
    /// ModManagerView's check of one mod, off the main thread, `done` called on `queue` with the result. Unciv's
    /// ModCheckTab.runModChecker runs its checker on `Concurrency.run("ModChecker")` against the base ruleset the tab
    /// holds (`base`, chosen in the tab's own select box), never against a global; ours reads the base on the calling
    /// (main) thread before the job leaves it, and fills knownPatterns there too, its first use reading Ruleset.shared -
    /// both globals are written on the main thread when a game is started or loaded (Ruleset.activate), which the
    /// player can do while a check is still running (the mod sheet closed). The job then reads only what it was given.
    /// `startGate` (ScenarioSelfTests.modCheckThread only) holds the job until the test has switched the globals.
    static func validateInBackground(mod: String, queue: DispatchQueue = .main, startGate: DispatchSemaphore? = nil, _ done: @escaping ([RulesetError]) -> Void) {
        let base = Ruleset.currentBaseRuleset
        _ = knownPatterns.isEmpty
        DispatchQueue.global(qos: .userInitiated).async {
            startGate?.wait()
            let result = validate(mod: mod, base: base)
            queue.async { done(result) }
        }
    }
    static func finalSeverity(_ errors: [RulesetError]) -> RulesetErrorSeverity { errors.map { $0.severity }.max() ?? .OK }

    private mutating func add(_ text: String, _ severity: RulesetErrorSeverity = .Error) { lines.append(RulesetError(text: text, severity: severity)) }

    /// Unique templates the base ruleset uses; anything else a mod adds is reported like Unciv's "not found in Unciv's list of uniques".
    private static let knownPatterns: Set<String> = {
        let base = Ruleset.shared
        var set = Set<String>()
        func take(_ us: [String]) { for u in us { set.insert(Unique(u).pattern) } }
        for u in base.units.values { take(u.uniques) }
        for b in base.buildings.values { take(b.uniques) }
        for t in base.techs.values { take(t.uniques) }
        for p in base.policies.values { take(p.uniques) }
        for b in base.policyBranches { take(b.uniques) }
        for p in base.promotions.values { take(p.uniques) }
        for n in base.nations.values { take(n.uniques) }
        for t in base.terrains.values { take(t.uniques) }
        for i in base.improvements.values { take(i.uniques) }
        for r in base.resources.values { take(r.uniques) }
        for b in base.beliefs.values { take(b.uniques) }
        for e in base.eras { take(e.uniques) }
        for r in base.ruins { take(r.uniques) }
        take(base.globalUniques.map { $0.text })
        for e in base.events { take(e.uniques); for c in e.choices { take(c.uniques) } }
        return set
    }()

    private mutating func checkUniques(_ uniques: [String], owner: String, severity: RulesetErrorSeverity = .WarningOptionsOnly) {
        for u in uniques {
            let parsed = Unique(u)
            if !RulesetValidator.knownPatterns.contains(parsed.pattern) {
                add("\(owner)'s unique \"\(u)\" not found in Unciv's list of uniques - may be a misspelling, or may be a deprecated/unknown unique", severity)
            }
            if u.contains("<") && !u.contains(">") || u.filter({ $0 == "[" }).count != u.filter({ $0 == "]" }).count { add("\(owner)'s unique \"\(u)\" has unbalanced brackets", .Error) }
        }
    }
    private mutating func checkName(_ name: String, kind: String) { if name.trimmingCharacters(in: .whitespaces).isEmpty { add("\(kind) with empty name", .Error) } }

    mutating func run() {
        let rs = ruleset
        // Units (Unciv checkUnit)
        for u in rs.units.values {
            checkName(u.name, kind: "Unit")
            if let t = u.requiredTech, rs.techs[t] == nil { add("\(u.name) requires tech \(t) which does not exist!") }
            if let t = u.obsoleteTech, rs.techs[t] == nil { add("\(u.name) obsoletes at tech \(t) which does not exist!") }
            if let up = u.upgradesTo, rs.units[up] == nil { add("\(u.name) upgrades to unit \(up) which does not exist!") }
            if let up = u.upgradesTo, up == u.name { add("\(u.name) upgrades to itself!") }
            if let r = u.replaces, rs.units[r] == nil { add("\(u.name) replaces \(r) which does not exist!") }
            if let n = u.uniqueTo, rs.nations[n] == nil { add("\(u.name) is unique to \(n) which does not exist!") }
            if let res = u.requiredResource, rs.resources[res] == nil { add("\(u.name) requires resource \(res) which does not exist!") }
            if rs.unitTypes[u.unitType] == nil { add("\(u.name) is of type \(u.unitType), which does not exist!") }
            for p in u.promotions where rs.promotions[p] == nil { add("\(u.name) contains promotion \(p) which does not exist!") }
            if u.uniqueTo != nil && u.replaces == nil { add("\(u.name) is unique to \(u.uniqueTo!) but replaces nothing", .WarningOptionsOnly) }
            checkUniques(u.uniques, owner: u.name)
        }
        // Buildings (Unciv checkBuilding)
        for b in rs.buildings.values {
            checkName(b.name, kind: "Building")
            if let t = b.requiredTech, rs.techs[t] == nil { add("\(b.name) requires tech \(t) which does not exist!") }
            if let rb = b.requiredBuilding, rs.buildings[rb] == nil { add("\(b.name) requires building \(rb) which does not exist!") }
            if let r = b.replaces, rs.buildings[r] == nil { add("\(b.name) replaces \(r) which does not exist!") }
            if let n = b.uniqueTo, rs.nations[n] == nil { add("\(b.name) is unique to \(n) which does not exist!") }
            if let res = b.requiredResource, rs.resources[res] == nil { add("\(b.name) requires resource \(res) which does not exist!") }
            for res in b.requiredNearbyImprovedResources where rs.resources[res] == nil { add("\(b.name) requires improved resource \(res) which does not exist!") }
            for (sp, _) in b.specialistSlots where rs.specialists[sp] == nil { add("\(b.name) provides specialist \(sp) which does not exist!") }
            if b.uniqueTo != nil && b.replaces == nil { add("\(b.name) is unique to \(b.uniqueTo!) but replaces nothing", .WarningOptionsOnly) }
            checkUniques(b.uniques, owner: b.name)
        }
        // Techs
        for t in rs.techs.values {
            checkName(t.name, kind: "Tech")
            for p in t.prerequisites where rs.techs[p] == nil { add("\(t.name) requires tech \(p) which does not exist!") }
            for p in t.prerequisites where p == t.name { add("\(t.name) requires itself!") }
            checkUniques(t.uniques, owner: t.name)
        }
        for col in rs.techColumns { if col.techCost <= 0 { add("Tech column \(col.columnNumber) has no cost", .Warning) } }
        // Terrains
        for t in rs.terrains.values {
            checkName(t.name, kind: "Terrain")
            for o in t.occursOn where rs.terrains[o] == nil { add("\(t.name) occurs on terrain \(o) which does not exist!") }
            if let into = t.turnsInto, rs.terrains[into] == nil { add("\(t.name) turns into terrain \(into) which does not exist!") }
            checkUniques(t.uniques, owner: t.name)
        }
        // Improvements
        for i in rs.improvements.values {
            checkName(i.name, kind: "Improvement")
            if let t = i.techRequired, rs.techs[t] == nil { add("\(i.name) requires tech \(t) which does not exist!") }
            for t in i.terrainsCanBeBuiltOn where rs.terrains[t] == nil && !["Land", "Water", "Coastal", "Hill"].contains(t) { add("\(i.name) can be built on terrain \(t) which does not exist!") }
            checkUniques(i.uniques, owner: i.name)
        }
        // Resources
        for r in rs.resources.values {
            checkName(r.name, kind: "Resource")
            if let t = r.revealedBy, rs.techs[t] == nil { add("\(r.name) revealed by tech \(t) which does not exist!") }
            if let imp = r.improvement, rs.improvements[imp] == nil { add("\(r.name) improved by improvement \(imp) which does not exist!") }
            for t in r.terrainsCanBeFoundOn where rs.terrains[t] == nil { add("\(r.name) can be found on terrain \(t) which does not exist!") }
            checkUniques(r.uniques, owner: r.name)
        }
        // Promotions
        for p in rs.promotions.values {
            checkName(p.name, kind: "Promotion")
            for pre in p.prerequisites where rs.promotions[pre] == nil { add("\(p.name) requires promotion \(pre) which does not exist!") }
            for ut in p.unitTypes where rs.unitTypes[ut] == nil { add("\(p.name) references unit type \(ut) which does not exist!") }
            checkUniques(p.uniques, owner: p.name)
        }
        // Policies
        for b in rs.policyBranches {
            checkName(b.name, kind: "Policy branch")
            if !b.era.isEmpty, !rs.eras.contains(where: { $0.name == b.era }) { add("\(b.name) requires era \(b.era) which does not exist!") }
            checkUniques(b.uniques, owner: b.name)
            for p in b.policies {
                checkName(p.name, kind: "Policy")
                for r in p.requires where rs.policies[r] == nil && !rs.policyBranches.contains(where: { $0.name == r }) { add("\(p.name) requires policy \(r) which does not exist!") }
                checkUniques(p.uniques, owner: p.name)
            }
        }
        // Nations (Unciv checkNation)
        for n in rs.nations.values {
            checkName(n.name, kind: "Nation")
            if n.isMajor && n.cities.isEmpty { add("\(n.name) is a major civ but has no city names!") }
            if let cst = n.cityStateType, rs.cityStateTypes[cst] == nil { add("\(n.name) is of city-state type \(cst) which does not exist!") }
            for sb in n.startBias where rs.terrains[sb] == nil && !["Coast", "Avoid [Coast]"].contains(sb) && !sb.hasPrefix("Avoid ") { add("\(n.name) has start bias \(sb) which does not exist!", .Warning) }
            if n.rawOuterColor.count < 3 { add("\(n.name) has an invalid outerColor") }
            if let inner = n.rawInnerColor, inner.count >= 3, n.rawOuterColor.count >= 3 {
                let d = zip(inner, n.rawOuterColor).map { abs($0 - $1) }.reduce(0, +)
                if d < 120 { add("\(n.name)'s colors do not contrast enough - it is unreadable!", .WarningOptionsOnly) }
            }
            checkUniques(n.uniques, owner: n.name)
        }
        // Beliefs / eras / ruins / specialists / city-state types / speeds / difficulties / victories
        for b in rs.beliefs.values { checkName(b.name, kind: "Belief"); if !["Pantheon", "Founder", "Follower", "Enhancer"].contains(b.type) { add("\(b.name) has unknown belief type \(b.type)") }; checkUniques(b.uniques, owner: b.name) }
        if rs.eras.isEmpty { add("Eras file is empty! This will likely lead to crashes. Ask the mod maker to update this mod!") }
        for e in rs.eras {
            checkName(e.name, kind: "Era")
            if rs.units[e.startingMilitaryUnit] == nil { add("Nonexistent unit \(e.startingMilitaryUnit) marked as starting unit when starting in \(e.name)") }
            for b in e.settlerBuildings where rs.buildings[b] == nil { add("Nonexistent building \(b) marked as starting building in \(e.name)") }
            checkUniques(e.uniques, owner: e.name)
        }
        for r in rs.ruins { checkName(r.name, kind: "Ruin"); checkUniques(r.uniques, owner: r.name) }
        for s in rs.specialists.values { checkName(s.name, kind: "Specialist") }
        for cst in rs.cityStateTypes.values { checkName(cst.name, kind: "City-state type") }
        for s in rs.speeds { checkName(s.name, kind: "Speed"); if s.modifier <= 0 { add("Speed \(s.name) has a non-positive modifier") } }
        for d in rs.difficulties { checkName(d.name, kind: "Difficulty"); for t in d.aiFreeTechs where rs.techs[t] == nil { add("Difficulty \(d.name) gives AI free tech \(t) which does not exist!") } }
        for v in rs.victories { checkName(v.name, kind: "Victory"); for m in v.milestones where m.isEmpty { add("Victory \(v.name) has an empty milestone") } }
        for e in rs.events { checkName(e.name, kind: "Event"); checkUniques(e.uniques, owner: e.name); for c in e.choices { checkUniques(c.uniques, owner: "\(e.name) choice \(c.name)") } }
        checkUniques(rs.globalUniques.map { $0.text }, owner: "GlobalUniques")
        // Files: Unciv warns about JSON files it does not know and about images with wrong folder spellings.
        let root = Ruleset.modsDirectory.appendingPathComponent(modName)
        let known = Set(["Terrains", "Units", "UnitTypes", "Buildings", "Techs", "Eras", "TileResources", "TileImprovements", "Speeds", "Difficulties", "UnitPromotions", "Policies", "Ruins", "GlobalUniques", "VictoryTypes", "Specialists", "CityStateTypes", "Beliefs", "Religions", "Quests", "Personalities", "UnitNameGroups", "Events", "ModOptions", "Nations", "Tutorials"])
        for jsonDir in [root.appendingPathComponent("jsons"), root.appendingPathComponent("jsons/Civ V - Gods & Kings"), root.appendingPathComponent("jsons/Civ V - Vanilla")] {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: jsonDir.path)) ?? [] where f.hasSuffix(".json") {
                let base = String(f.dropLast(5))
                if !known.contains(base) { add("File \(f) is in the jsons folder but is not a recognized ruleset file", .WarningOptionsOnly) }
                if let data = try? Data(contentsOf: jsonDir.appendingPathComponent(f)), Ruleset.cleanedModJSON(data) == nil { add("File \(f) could not be parsed as JSON", .Error) }
            }
        }
        if let images = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path) {
            let expected = ["BuildingIcons", "UnitIcons", "TechIcons", "ImprovementIcons", "ResourceIcons", "NationIcons", "PolicyIcons", "PolicyBranchIcons", "UnitPromotionIcons", "OtherIcons", "TileSets", "UnitSets", "StatIcons", "ReligionIcons", "EmojiIcons", "TileIcons", "PortraitIcons", "BeliefIcons", "PersonalityIcons", "UnitTypeIcons", "EraIcons", "Flags", "FlagIcons", "LeaderIcons", "Sounds"]
            for dir in images where !expected.contains(dir) && !dir.hasPrefix(".") {
                if let close = expected.first(where: { $0.lowercased() == dir.lowercased() }) { add("Image folder \(dir) should be spelled \(close)", .Warning) }
            }
        }
    }
}
