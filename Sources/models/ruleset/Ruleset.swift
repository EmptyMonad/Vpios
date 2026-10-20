// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Rule names the code relies on (keep these in sync with the ruleset JSON).
enum Names {
    static let palace = "Palace"
    static let obelisk = "Monument"
    static let settler = "Settler"
    static let laborer = "Worker"
    static let brave = "Warrior"
    static let destroyedOnCapture = "Destroyed when the city is captured"
    static let barbarianCamp = "Barbarian encampment"
    static let ancientRuins = "Ancient ruins"
    static let barbarians = "Barbarians"
    static let greatGeneral = "Great General"
    static let holySite = "Holy site"
}

/// The loaded, indexed game rules (data comes from the open-source Unciv "Civ V - Vanilla" ruleset).
final class Ruleset {
    let terrains: [String: Terrain]
    let unitTypes: [String: UnitType]
    /// The order UnitTypes.json declares them in; a dictionary's keys have no stable order.
    private(set) var unitTypeOrder: [String] = []
    private(set) var unitOrder: [String] = []        // Units.json order (Unciv ruleset.units iteration order)
    private(set) var buildingOrder: [String] = []    // Buildings.json order (Unciv ruleset.buildings iteration order)
    private(set) var unitOrderIndex: [String: Int] = [:]
    private(set) var buildingOrderIndex: [String: Int] = [:]
    let units: [String: UnitDef]
    let buildings: [String: BuildingDef]
    let techs: [String: TechDef]
    let techColumns: [TechColumn]
    let nations: [String: NationDef]
    let eras: [EraDef]
    let resources: [String: ResourceDef]
    let improvements: [String: ImprovementDef]
    var improvementOrder: [String] = []   // TileImprovements.json order (Unciv ruleset.tileImprovements iteration order)
    var terrainOrder: [String] = []       // Terrains.json order (Unciv ruleset.terrains iteration order)
    var resourceOrder: [String] = []      // TileResources.json order (Unciv ruleset.tileResources iteration order)
    /// The resources in the order the ruleset declares them, which is the order Unciv places them in.
    var resourcesInOrder: [ResourceDef] { resourceOrder.compactMap { resources[$0] } }
    private(set) var nationOrder: [String] = []        // Nations.json order (Unciv ruleset.nations iteration order)
    private(set) var personalityOrder: [String] = []   // Personalities.json order (Unciv ruleset.personalities iteration order)
    /// Unciv ruleset.technologies iteration order: Techs.json column by column, each column's techs in file order
    /// (a name met again keeps its first place, as a LinkedHashMap does).
    var techOrder: [String] {
        var seen = Set<String>()
        return techColumns.flatMap { $0.techs.map(\.name) }.filter { seen.insert($0).inserted && techs[$0] != nil }
    }
    let promotions: [String: PromotionDef]
    /// The promotions in the order UnitPromotions.json lists them.
    ///
    /// Unciv's `ruleset.unitPromotions` is a LinkedHashMap, so every walk of it is in file order, and the AI's
    /// weighted pick walks that order: with two promotions of equal weight the first one the walk reaches wins.
    /// Sorting by name instead handed the same draw a different answer - a Warrior took Shock I where Unciv
    /// took Drill I, and from then on its strength in rough terrain was 15% short.
    let promotionOrder: [PromotionDef]
    let policyBranches: [PolicyBranch]
    let policies: [String: PolicyDef]
    let policyBranchOf: [String: String]
    let ruins: [RuinDef]
    let difficulties: [DifficultyDef]
    let speeds: [SpeedDef]
    let victories: [VictoryDef]
    let globalUniques: [Unique]
    /// Unciv GlobalUniques.unitUniques: folded into every unit's own uniques (BaseUnit.rulesetUniqueObjects)
    let globalUnitUniques: [Unique]
    /// Unciv GlobalUniques.civilopediaText (the Civilopedia's Global Uniques entry).
    let globalUniquesCivilopediaText: [CivilopediaLine]
    fileprivate var happinessLevelsCache: Set<Int>? = nil
    let naturalWonders: [Terrain]
    let specialists: [String: SpecialistDef]
    let cityStateTypes: [String: CityStateTypeDef]
    let cityStateNations: [NationDef]
    let beliefs: [String: BeliefDef]
    /// Beliefs.json order: Unciv's `ruleset.beliefs` is a LinkedHashMap, so `beliefs.values` walks the file order.
    let beliefList: [BeliefDef]
    let religionNames: [String]
    let constants: ModConstants
    let quests: [QuestDef]
    let personalities: [String: PersonalityDef]
    /// Unciv TileResource.getImprovements: resource name -> every improvement that unlocks it.
    let resourceImprovements: [String: Set<String>]
    let unitNameGroups: [String: [String]]
    let events: [EventDef]
    let modOptionUniques: [Unique]

    let baseTerrains: [Terrain]
    let terrainFeatures: [Terrain]
    let majorNations: [NationDef]

    nonisolated(unsafe) static var shared: Ruleset = {
        do { return try Ruleset(named: currentBaseRuleset) }
        catch { fatalError("Ruleset failed to load: \(error)") }
    }()
    /// Rebuild the shared ruleset with a set of mods (names of folders under Documents/Mods).
    static func activate(mods: [String], baseRuleset: String? = nil) {
        if let baseRuleset, baseRuleset != currentBaseRuleset, baseRulesets.contains(baseRuleset) { currentBaseRuleset = baseRuleset }
        else if shared.mods == mods { return }
        if let r = try? Ruleset(named: currentBaseRuleset, mods: mods) { shared = r; Art.shared.reloadModRoots(mods: mods) }
    }

    let mods: [String]

    static var modsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Mods")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func availableMods() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: modsDirectory.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Unciv-style mod JSON may contain comments and trailing commas (libGDX's JsonReader reads them); its names are
    /// Unciv's, which the base rulesets use too.
    static func cleanedModJSON(_ data: Data) -> Data? { cleanModJSON(data) }

    // MARK: Unciv ModCompatibility (ModRequires / ModIncompatibleWith / ModIsAudioVisualOnly)
    /// The base ruleset the next load should use; set from the game settings.
    nonisolated(unsafe) static var currentBaseRuleset = baseRulesetName
    nonisolated(unsafe) private static var modOptionsCache: [String: [Unique]] = [:]
    static func clearModOptionsCache() { modOptionsCache = [:] }
    /// A mod's ModOptions uniques (jsons/ModOptions.json), cached per mod name.
    static func modOptionUniques(of mod: String) -> [Unique] {
        if let cached = modOptionsCache[mod] { return cached }
        let root = modsDirectory.appendingPathComponent(mod)
        let candidates = [root.appendingPathComponent("jsons/ModOptions.json"), root.appendingPathComponent("jsons/Civ V - Vanilla/ModOptions.json"), root.appendingPathComponent("ModOptions.json")]
        var result: [Unique] = []
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }), let raw = try? Data(contentsOf: url), let cleaned = cleanModJSON(raw),
           let obj = (try? JSONSerialization.jsonObject(with: cleaned)) as? [String: Any] {
            result = ((obj["uniques"] as? [String]) ?? []).map(Unique.init)
        }
        modOptionsCache[mod] = result
        return result
    }
    /// Unciv ModCompatibility.isAudioVisualMod: declared by ModOptions, else guessed from non-empty music/sounds/voices folders or atlas files.
    static func isAudioVisualMod(_ mod: String) -> Bool {
        let uniques = modOptionUniques(of: mod)
        if uniques.contains(where: { $0.pattern == "Should only be used as permanent audiovisual mod" || $0.pattern == "Can be used as permanent audiovisual mod" }) { return true }
        if uniques.contains(where: { $0.pattern == "Cannot be used as permanent audiovisual mod" }) { return false }
        let root = modsDirectory.appendingPathComponent(mod)
        let fm = FileManager.default
        for sub in ["music", "sounds", "voices"] {
            if let items = try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(sub).path), !items.isEmpty { return true }
        }
        return ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).contains { $0.hasSuffix(".atlas") }
    }
    /// Unciv ModCompatibility.modNameFilter: exact name, or "*part*" (case-insensitive, at least 3 characters).
    static func modNameFilter(_ modName: String, _ filter: String) -> Bool {
        if modName == filter { return true }
        guard filter.count >= 3, filter.hasPrefix("*"), filter.hasSuffix("*") else { return false }
        return modName.lowercased().contains(filter.dropFirst().dropLast().lowercased())
    }
    private static func modIncompatible(_ a: String, _ b: String) -> Bool {
        modOptionUniques(of: a).contains { $0.pattern == "Mod is incompatible with []" && modNameFilter(b, $0.param(0)) }
            || modOptionUniques(of: b).contains { $0.pattern == "Mod is incompatible with []" && modNameFilter(a, $0.param(0)) }
    }
    private static func modRequirementsMet(_ mod: String, others: [String]) -> Bool {
        for u in modOptionUniques(of: mod) where u.pattern == "Mod requires []" {
            if modNameFilter(baseRulesetName, u.param(0)) { continue }
            if !others.contains(where: { modNameFilter($0, u.param(0)) }) { return false }
        }
        return true
    }
    /// Unciv ModCompatibility.isExtensionMod + meetsBaseRequirements: whether the mod is listed at all.
    static func modMeetsBaseRequirements(_ mod: String) -> Bool {
        let uniques = modOptionUniques(of: mod)
        if uniques.contains(where: { $0.pattern == "Should only be used as permanent audiovisual mod" }) { return false }
        if uniques.contains(where: { $0.pattern == "Mod is incompatible with []" && modNameFilter(baseRulesetName, $0.param(0)) }) { return false }
        return modRequirementsMet(mod, others: availableMods().filter { $0 != mod })
    }
    /// Unciv ModCompatibility.meetsAllRequirements: allowed together with the other selected extension mods.
    static func modMeetsAllRequirements(_ mod: String, selected: [String]) -> Bool {
        let others = selected.filter { $0 != mod }
        if others.contains(where: { modIncompatible(mod, $0) }) { return false }
        return modRequirementsMet(mod, others: others)
    }
    /// Unciv ModCheckboxTable.disableIncompatibleMods: drop selections that no longer meet their requirements.
    static func pruneModSelection(_ selected: [String]) -> [String] {
        var current = selected
        while let bad = current.first(where: { !modMeetsAllRequirements($0, selected: current) }) { current.removeAll { $0 == bad } }
        return current
    }
    /// `rename` no longer does anything (a mod is read with its own names); kept for the callers that pass it
    static func cleanModJSON(_ data: Data, rename: Bool = false) -> Data? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        var out = "", inStr = false, i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inStr { out.append(c); if c == "\\" { let n = text.index(after: i); if n < text.endIndex { out.append(text[n]); i = text.index(after: n); continue } }; if c == "\"" { inStr = false }; i = text.index(after: i); continue }
            if c == "\"" { inStr = true; out.append(c); i = text.index(after: i); continue }
            // libGDX JsonReader ends a `//` comment at '\n', which a CRLF file's "\r\n" (one Character in Swift) holds
            if text[i...].hasPrefix("//") { if let nl = text[i...].firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) { i = nl } else { break }; continue }
            if text[i...].hasPrefix("/*") { if let end = text[i...].range(of: "*/") { i = end.upperBound } else { break }; continue }
            out.append(c); i = text.index(after: i)
        }
        text = out.replacingOccurrences(of: ",\\s*([\\]}])", with: "$1", options: .regularExpression)
        // A mod's names were once mapped to the names this port's rulesets used to have (GameData/Rulesets/renames.json,
        // "Settler" to "Pioneer", "Warrior" to "Brave", ...); the rulesets have Unciv's names now, so that turned a mod's
        // "unitsToRemove": ["Settler"] or a unit's "Warrior" into names no ruleset has - Unciv reads them as written
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        return try? JSONSerialization.data(withJSONObject: obj)
    }

    init(named name: String, mods: [String] = []) throws {
        self.mods = mods
        let modRoots = mods.map { Ruleset.modsDirectory.appendingPathComponent($0) }
        /// Unciv ModOptions.*ToRemove of each mod, applied while that mod is added (Ruleset.add).
        let modRemovals: [[String: [String]]] = modRoots.map { root in
            let candidates = [root.appendingPathComponent("jsons/ModOptions.json"), root.appendingPathComponent("jsons/Civ V - Vanilla/ModOptions.json"), root.appendingPathComponent("ModOptions.json")]
            guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }), let raw = try? Data(contentsOf: url), let cleaned = Ruleset.cleanModJSON(raw),
                  let obj = (try? JSONSerialization.jsonObject(with: cleaned)) as? [String: Any] else { return [:] }
            var out: [String: [String]] = [:]
            for key in ["beliefsToRemove", "buildingsToRemove", "nationsToRemove", "policyBranchesToRemove", "policiesToRemove", "religionsToRemove", "techsToRemove", "unitsToRemove"] { out[key] = obj[key] as? [String] ?? [] }
            return out
        }
        /// Base file plus, for each mod, entries merged by name (replace) or appended.
        func load<T: Decodable>(_ file: String, as: T.Type) throws -> T {
            guard let url = Bundle.main.url(forResource: file, withExtension: "json", subdirectory: "GameData/Rulesets/\(name)") else {
                throw NSError(domain: "Ruleset", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(file).json"])
            }
            // Unciv reads its own jsons with libGDX's JsonReader, which tolerates comments and trailing commas.
            let rawBase = try Data(contentsOf: url)
            var base: Any
            if let strict = try? JSONSerialization.jsonObject(with: rawBase) { base = strict }
            else { base = try JSONSerialization.jsonObject(with: Ruleset.cleanModJSON(rawBase) ?? rawBase) }
            for (rootIndex, root) in modRoots.enumerated() {
                let removals = modRemovals[rootIndex]
                base = Ruleset.applyRemovals(base, file: file, removals: removals, afterMerge: false)
                let candidates = [root.appendingPathComponent("jsons/\(file).json"), root.appendingPathComponent("jsons/Civ V - Vanilla/\(file).json"), root.appendingPathComponent("\(file).json")]
                guard let modURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }), let raw = try? Data(contentsOf: modURL), let cleaned = Ruleset.cleanModJSON(raw), let modObj = try? JSONSerialization.jsonObject(with: cleaned) else { base = Ruleset.applyRemovals(base, file: file, removals: removals, afterMerge: true); continue }
                base = Ruleset.merge(base, modObj, file: file)
                base = Ruleset.applyRemovals(base, file: file, removals: removals, afterMerge: true)
            }
            let data = try JSONSerialization.data(withJSONObject: base)
            return try JSONDecoder().decode(T.self, from: data)
        }
        let terrainList = try load("Terrains", as: [Terrain].self)
        terrains = Dictionary(uniqueKeysWithValues: terrainList.map { ($0.name, $0) })
        baseTerrains = terrainList.filter { $0.type == .land || $0.type == .water }
        terrainOrder = terrainList.map { $0.name }
        terrainFeatures = terrainList.filter { $0.type == .terrainFeature }

        let ut = try load("UnitTypes", as: [UnitType].self)
        unitTypes = Dictionary(uniqueKeysWithValues: ut.map { ($0.name, $0) })
        unitTypeOrder = ut.map { $0.name }   // Unciv sorts some things by the ruleset's own order
        let unitList = try load("Units", as: [UnitDef].self)
        units = Dictionary(unitList.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        unitOrder = unitList.map { $0.name }
        unitOrderIndex = Dictionary(unitOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let buildingList = try load("Buildings", as: [BuildingDef].self)
        buildings = Dictionary(buildingList.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        buildingOrder = buildingList.map { $0.name }
        buildingOrderIndex = Dictionary(buildingOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })

        let columns = try load("Techs", as: [TechColumn].self)
        techColumns = columns
        var techDict: [String: TechDef] = [:]
        for col in columns {
            for var t in col.techs {
                t.column = col.columnNumber; t.era = col.era
                if t.cost == 0 { t.cost = col.techCost }   // Unciv Ruleset: a technology keeps a cost it declares itself
                techDict[t.name] = t
            }
        }
        techs = techDict

        let nationList = try load("Nations", as: [NationDef].self)
        nations = Dictionary(nationList.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var seenNations = Set<String>()
        nationOrder = nationList.map { $0.name }.filter { seenNations.insert($0).inserted }
        majorNations = nationList.filter { $0.isMajor }
        eras = try load("Eras", as: [EraDef].self)
        let resList = try load("TileResources", as: [ResourceDef].self)
        resources = Dictionary(resList.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        resourceOrder = resList.map { $0.name }
        let impList = try load("TileImprovements", as: [ImprovementDef].self)
        improvements = Dictionary(impList.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        improvementOrder = impList.map { $0.name }
        // Unciv TileResource.getImprovements: improvement + improvedBy + improvements with "Improves [resourceFilter] resource in this tile"
        var resourceImps: [String: Set<String>] = [:]
        let improvesUniques = impList.map { imp in (imp.name, imp.uniques.map(Unique.init).filter { $0.pattern == "Improves [] resource in this tile" }.map { $0.param(0) }) }
        for r in resList {
            var set = Set(r.improvedBy)
            if let i = r.improvement { set.insert(i) }
            for (impName, filters) in improvesUniques where filters.contains(where: { $0 == r.name || $0 == r.resourceType || $0 == "All" }) { set.insert(impName) }
            resourceImps[r.name] = set
        }
        resourceImprovements = resourceImps
        let promoList = try load("UnitPromotions", as: [PromotionDef].self)
        promotions = Dictionary(promoList.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        promotionOrder = promoList
        policyBranches = try load("Policies", as: [PolicyBranch].self)
        var pdict: [String: PolicyDef] = [:], branchOf: [String: String] = [:]
        for b in policyBranches { for p in b.policies { pdict[p.name] = p; branchOf[p.name] = b.name } }
        policies = pdict; policyBranchOf = branchOf
        ruins = try load("Ruins", as: [RuinDef].self)
        difficulties = try load("Difficulties", as: [DifficultyDef].self)
        speeds = try load("Speeds", as: [SpeedDef].self)
        victories = try load("VictoryTypes", as: [VictoryDef].self)
        let globalUniquesDef = try load("GlobalUniques", as: GlobalUniquesDef.self)
        globalUniques = globalUniquesDef.uniqueObjects
        globalUnitUniques = globalUniquesDef.unitUniques.map(Unique.init)
        globalUniquesCivilopediaText = globalUniquesDef.civilopediaText
        naturalWonders = terrainList.filter { $0.type == .naturalWonder }
        let specList = try load("Specialists", as: [SpecialistDef].self)
        specialists = Dictionary(specList.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let cst = try load("CityStateTypes", as: [CityStateTypeDef].self)
        cityStateTypes = Dictionary(cst.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        cityStateNations = nationList.filter { $0.isCityState }
        let beliefList = (try? load("Beliefs", as: [BeliefDef].self)) ?? []
        beliefs = Dictionary(beliefList.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var seenBeliefs: Set<String> = []
        self.beliefList = beliefList.filter { seenBeliefs.insert($0.name).inserted }
        religionNames = (try? load("Religions", as: [String].self)) ?? []
        let modOptions = try? load("ModOptions", as: ModOptionsDef.self)
        constants = modOptions?.constants ?? ModConstants()
        modOptionUniques = (modOptions?.uniques ?? []).map(Unique.init)
        quests = (try? load("Quests", as: [QuestDef].self)) ?? []
        let persList = (try? load("Personalities", as: [PersonalityDef].self)) ?? []
        personalities = Dictionary(persList.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var seenPersonalities = Set<String>()
        personalityOrder = persList.map { $0.name }.filter { seenPersonalities.insert($0).inserted }
        let groups = (try? load("UnitNameGroups", as: [UnitNameGroup].self)) ?? []
        unitNameGroups = Dictionary(groups.map { ($0.name, $0.unitNames) }, uniquingKeysWith: { a, _ in a })
        events = (try? load("Events", as: [EventDef].self)) ?? []
    }

    func beliefs(ofType t: String) -> [BeliefDef] { beliefs.values.filter { $0.type == t }.sorted { $0.name < $1.name } }
    /// Personality by leader name (Unciv keys personalities by leader), neutral otherwise.
    func personality(for nation: NationDef?) -> PersonalityDef {
        // Unciv getPersonality: ruleset.personalities[nation.personality]; older rulesets key by leader name.
        if let key = nation?.personality, let p = personalities[key] { return p }
        guard let leader = nation?.leaderName, let p = personalities[leader] else { return .neutral }
        return p
    }

    /// Unciv RulesetObject.matchesFilter, simplified for JSON entries: the name, "All", or a unique on the object.
    private static func entryMatches(_ entry: [String: Any], _ filter: String) -> Bool {
        if filter == "All" || filter == "all" { return true }
        if (entry["name"] as? String) == filter { return true }
        return ((entry["uniques"] as? [String]) ?? []).contains(filter)
    }
    /// Unciv Ruleset.add: buildings/nations/techs/units/policy branches are removed before the mod's entries are added;
    /// beliefs, policies and religions after. Removed religions are also cleared from nations' favoredReligion.
    private static func applyRemovals(_ base: Any, file: String, removals: [String: [String]], afterMerge: Bool) -> Any {
        func strip(_ list: [[String: Any]], _ filters: [String]) -> [[String: Any]] { filters.isEmpty ? list : list.filter { e in !filters.contains { entryMatches(e, $0) } } }
        switch (file, afterMerge) {
        case ("Buildings", false): return strip(base as? [[String: Any]] ?? [], removals["buildingsToRemove"] ?? [])
        case ("Nations", false): return strip(base as? [[String: Any]] ?? [], removals["nationsToRemove"] ?? [])
        case ("Units", false): return strip(base as? [[String: Any]] ?? [], removals["unitsToRemove"] ?? [])
        case ("Policies", false): return strip(base as? [[String: Any]] ?? [], removals["policyBranchesToRemove"] ?? [])
        case ("Techs", false):
            let filters = removals["techsToRemove"] ?? []
            guard !filters.isEmpty, var cols = base as? [[String: Any]] else { return base }
            for i in cols.indices { cols[i]["techs"] = strip((cols[i]["techs"] as? [[String: Any]]) ?? [], filters) }
            return cols
        case ("Beliefs", true): return strip(base as? [[String: Any]] ?? [], removals["beliefsToRemove"] ?? [])
        case ("Policies", true):
            let filters = removals["policiesToRemove"] ?? []
            guard !filters.isEmpty, var branches = base as? [[String: Any]] else { return base }
            for i in branches.indices { branches[i]["policies"] = strip((branches[i]["policies"] as? [[String: Any]]) ?? [], filters) }
            return branches
        case ("Religions", true):
            let gone = Set(removals["religionsToRemove"] ?? [])
            return gone.isEmpty ? base : ((base as? [String]) ?? []).filter { !gone.contains($0) }
        case ("Nations", true):
            let gone = Set(removals["religionsToRemove"] ?? [])
            guard !gone.isEmpty, var nations = base as? [[String: Any]] else { return base }
            for i in nations.indices where (nations[i]["favoredReligion"] as? String).map(gone.contains) == true { nations[i]["favoredReligion"] = nil }
            return nations
        default: return base
        }
    }

    private static func merge(_ base: Any, _ mod: Any, file: String) -> Any {
        if let baseNames = base as? [String], let modNames = mod as? [String] { return baseNames + modNames.filter { !baseNames.contains($0) } }   // Unciv religions.addAll
        guard var baseList = base as? [[String: Any]], let modList = mod as? [[String: Any]] else { return mod }
        if file == "Techs" {
            for col in modList {
                if let idx = baseList.firstIndex(where: { ($0["columnNumber"] as? Int) == (col["columnNumber"] as? Int) }) {
                    var existing = (baseList[idx]["techs"] as? [[String: Any]]) ?? []
                    for t in (col["techs"] as? [[String: Any]]) ?? [] {
                        if let i = existing.firstIndex(where: { ($0["name"] as? String) == (t["name"] as? String) }) { existing[i] = t } else { existing.append(t) }
                    }
                    baseList[idx]["techs"] = existing
                } else { baseList.append(col) }
            }
            return baseList
        }
        for entry in modList {
            if let i = baseList.firstIndex(where: { ($0["name"] as? String) == (entry["name"] as? String) }) { baseList[i] = entry } else { baseList.append(entry) }
        }
        return baseList
    }

    func difficulty(_ name: String) -> DifficultyDef { difficulties.first { $0.name == name } ?? difficulties[min(3, difficulties.count - 1)] }
    func speed(_ name: String) -> SpeedDef { speeds.first { $0.name == name } ?? speeds[0] }   // Unciv: the ruleset's first speed
    /// Unciv's tutorial texts (GameData/Tutorials.json - Unciv 4.22.1's jsons/Tutorials.json as strict JSON),
    /// shown in the encyclopedia: Unciv Tutorial - name, category (nil when absent), steps (the
    /// popup's lines, also its Civilopedia lines) and civilopediaText as FormattedLines (links, empty lines, separators,
    /// pictures).
    struct TutorialDef: Decodable, Identifiable {
        var id: String { name }
        let name: String
        let category: String
        let steps: [String]
        let civilopediaText: [CivilopediaLine]
        let uniques: [String]
        private enum CodingKeys: String, CodingKey { case name, category, steps, civilopediaText, uniques }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
            steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
            civilopediaText = try c.decodeIfPresent([CivilopediaLine].self, forKey: .civilopediaText) ?? []
            uniques = try c.decodeIfPresent([String].self, forKey: .uniques) ?? []
        }
    }
    /// Every tutorial in the file. "Will not be displayed in Civilopedia" is a rule about the ENCYCLOPEDIA, not
    /// about the tutorial: filtering it out here took the five it names - Introduction, Slow Start,
    /// OtherCivEncountered, BarbarianEncountered, EnemyCityNeedsConqueringWithMeleeUnit - away from the popup
    /// system too. Their step lists came back empty, and a tutorial with no steps is marked as seen and skipped,
    /// so the welcome text never appeared once and could never appear again. Use `civilopediaTutorials` for the
    /// encyclopedia; use this for everything else.
    static let tutorials: [TutorialDef] = {
        guard let url = Bundle.main.url(forResource: "Tutorials", withExtension: "json", subdirectory: "GameData"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TutorialDef].self, from: data)) ?? []
    }()
    /// Unciv CivilopediaCategories.Tutorial: the encyclopedia hides the ones flagged for it.
    static var civilopediaTutorials: [TutorialDef] { tutorials.filter { !$0.uniques.contains("Will not be displayed in Civilopedia") } }

    func eraIndex(_ name: String) -> Int { eras.firstIndex { $0.name == name } ?? 0 }
    /// Terrain elevation and sight-blocking flags parsed once from the terrain uniques.
    lazy var terrainElevation: [String: Int] = {
        var out: [String: Int] = [:]
        for t in terrains.values { for u in t.uniqueObjects where u.pattern == "Has an elevation of [] for visibility calculations" { out[t.name] = u.int(0) } }
        return out
    }()
    lazy var terrainBlocksSight: Set<String> = Set(terrains.values.filter { $0.uniques.contains("Blocks line-of-sight from tiles at same elevation") }.map { $0.name })
    /// Unciv BaseUnit.setRuleset: each unit's rulesetUniqueObjects - its own uniques, the global unitUniques, its type's.
    lazy var unitRulesetUniques: [String: [Unique]] = {
        var out: [String: [Unique]] = [:]
        for (name, u) in units { out[name] = u.uniqueObjects + globalUnitUniques + (unitTypes[u.unitType]?.uniqueObjects ?? []) }
        return out
    }()
    /// The lazily built tables above and happinessLevelsThatAffectUniques, built now: Swift's `lazy` is not thread safe,
    /// and the world screen's turn runs on a background thread while the screens read the same ruleset. Unciv's
    /// equivalents are filled when the ruleset is loaded (Ruleset.updateBuildingCosts, BaseUnit.setRuleset).
    func buildLazyTables() {
        _ = terrainElevation; _ = terrainBlocksSight; _ = unitRulesetUniques; _ = happinessLevelsThatAffectUniques
    }
    func victory(_ name: String) -> VictoryDef? { victories.first { $0.name == name } }

    func era(named name: String) -> EraDef? { eras.first { $0.name == name } }
    var ancientEra: EraDef { eras[0] }

    /// Unciv Ruleset.updateBuildingCosts: a building without a cost takes its tech column's building cost (the wonder
    /// cost for any wonder); one with an unconditional "Unbuildable", or without any required tech column, keeps -1.
    func cost(of building: BuildingDef) -> Int {
        if building.cost != -1 { return building.cost }
        if building.uniqueObjects.contains(where: { $0.pattern == "Unbuildable" && $0.conditionals.isEmpty }) { return building.cost }
        // IHasUniques.techColumn: the highest column among the required techs (legacy requiredTech + "after discovering" availability)
        var required: [String] = building.requiredTech.map { [$0] } ?? []
        for pattern in ["Only available", "Can only be built"] {
            for u in building.uniqueObjects where u.pattern == pattern {
                for m in u.conditionals where m.pattern == "after discovering []" { required.append(m.param(0)) }
            }
        }
        let columns = required.compactMap { techs[$0] }.compactMap { t in techColumns.first(where: { $0.columnNumber == t.column }) }
        guard var column = columns.first else { return building.cost }
        for c in columns.dropFirst() where c.columnNumber > column.columnNumber { column = c }   // maxByOrNull keeps the first highest
        return building.isAnyWonder ? column.wonderCost : column.buildingCost
    }

    /// Units that are generic (not another nation's unique) or unique to the given nation, ignoring replaced base units.
    func availableUnitDefs(for nation: String) -> [UnitDef] {
        let uniqueReplaced = Set(units.values.filter { $0.uniqueTo == nation }.compactMap { $0.replaces })
        return units.values.filter { u in
            if u.isGreatPerson { return false }
            if let uniqueTo = u.uniqueTo { return uniqueTo == nation }
            return !uniqueReplaced.contains(u.name)
        }.sorted { (unitOrderIndex[$0.name] ?? .max) < (unitOrderIndex[$1.name] ?? .max) }
    }

    func availableBuildingDefs(for nation: String) -> [BuildingDef] {
        let uniqueReplaced = Set(buildings.values.filter { $0.uniqueTo == nation }.compactMap { $0.replaces })
        return buildings.values.filter { b in
            if let uniqueTo = b.uniqueTo { return uniqueTo == nation }
            return !uniqueReplaced.contains(b.name)
        }.sorted { (buildingOrderIndex[$0.name] ?? .max) < (buildingOrderIndex[$1.name] ?? .max) }
    }

    /// Promotions a unit of the given type may ever take.
    func promotions(forUnitType type: String) -> [PromotionDef] {
        promotionOrder.filter { $0.unitTypes.contains(type) }
    }
}

extension Ruleset {
    /// Unciv Ruleset.allHappinessLevelsThatAffectUniques: every happiness level that moving across it can
    /// change which uniques apply. Read from the conditionals themselves, never listed by hand.
    var happinessLevelsThatAffectUniques: Set<Int> {
        if let cached = happinessLevelsCache { return cached }
        var out: Set<Int> = []
        func scan(_ uniques: [Unique]) {
            for u in uniques {
                for c in u.conditionals {
                    switch c.pattern {
                    case "when below [] []": if c.params.count > 1, c.params[1] == "Happiness", let v = Int(c.params[0]) { out.insert(v) }
                    case "when above [] []": if c.params.count > 1, c.params[1] == "Happiness", let v = Int(c.params[0]) { out.insert(v) }
                    case "when between [] and [] []":
                        if c.params.count > 2, c.params[2] == "Happiness" {
                            if let lo = Int(c.params[0]) { out.insert(lo) }
                            if let hi = Int(c.params[1]) { out.insert(hi + 1) }
                        }
                    case "while the empire is happy": out.insert(0)
                    default: break
                    }
                }
            }
        }
        scan(globalUniques)
        for b in buildings.values { scan(b.uniqueObjects) }
        for p in policies.values { scan(p.uniqueObjects) }
        for b in policyBranches { scan(b.uniqueObjects); if let done = b.completion { scan(done.uniqueObjects) } }
        for n in nations.values { scan(n.uniqueObjects) }
        for u in units.values { scan(u.uniqueObjects) }
        for p in promotions.values { scan(p.uniqueObjects) }
        for i in improvements.values { scan(i.uniqueObjects) }
        for t in terrains.values { scan(t.uniqueObjects) }
        for r in resources.values { scan(r.uniqueObjects) }
        for t in techs.values { scan(t.uniqueObjects) }
        for b in beliefs.values { scan(b.uniqueObjects) }
        happinessLevelsCache = out
        return out
    }
}
