// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv DevConsolePopup + Console*Commands: `unit / city / tile / civ / game / diplomacy / history` commands with
/// Unciv's parameter formats, `"quoted names"` or `dashed-names`, tab autocomplete and a 42-entry history.
@MainActor
final class DevConsole {
    struct Response { enum Kind { case ok, error, hint }; let kind: Kind; let message: String }
    private static func ok(_ m: String = "") -> Response { Response(kind: .ok, message: m) }
    private static func error(_ m: String) -> Response { Response(kind: .error, message: m) }
    private static func hint(_ m: String) -> Response { Response(kind: .hint, message: m) }
    struct ConsoleError: Error { let message: String }

    unowned let controller: GameController
    init(controller: GameController) { self.controller = controller }
    private var state: GameState { controller.state }

    /// Command formats exactly as Unciv prints them in "Format:" hints.
    static let formats: [String: [String: String]] = [
        "unit": ["checkfilter": "unit checkfilter <unitFilter>", "add": "unit add <civName> <unitName>", "remove": "unit remove [all]", "setmovement": "unit setmovement [amount]", "sethealth": "unit sethealth [amount]", "setxp": "unit setxp [amount]", "addpromotion": "unit addpromotion <promotionName>", "removepromotion": "unit removepromotion <promotionName>"],
        "city": ["checkfilter": "city checkfilter <cityFilter>", "add": "city add <civName>", "remove": "city remove", "setpop": "city setpop <amount>", "setname": "city setname <\"name\">", "addtile": "city addtile <cityName> [radius]", "removetile": "city removetile", "religion": "city religion <religionName> <±pressure>", "sethealth": "city sethealth [amount]", "addbuilding": "city addbuilding <buildingName>", "removebuilding": "city removebuilding <buildingName>", "setpuppet": "city setpuppet <boolean>"],
        "civ": ["addstat": "civ addstat <stat> <amount> [civ]", "setplayertype": "civ setplayertype <civName> <ai/human>", "revealmap": "civ revealmap [civName]", "addpolicy": "civ addpolicy <civName> <policyName>", "removepolicy": "civ removepolicy <civName> <policyName>", "addtech": "civ addtech <civName> <techName>", "removetech": "civ removetech <civName> <techName>", "add": "civ add <newCivName>", "remove": "civ remove <civName>"],
        "tile": ["checkfilter": "tile checkfilter <tileFilter>", "setimprovement": "tile setimprovement <improvementName> [civName]", "removeimprovement": "tile removeimprovement", "setpillaged": "tile setpillaged <boolean>", "removeroad": "tile removeroad", "addfeature": "tile addfeature <featureName>", "removefeature": "tile removefeature <featureName>", "setterrain": "tile setterrain <terrainName>", "setresource": "tile setresource <resourceName> [amount]", "removeresource": "tile removeresource", "addriver": "tile addriver <direction>", "removeriver": "tile removeriver <direction>", "spawn-barbarian-encampment": "tile spawn-barbarian-encampment", "setowner": "tile setowner [civName|cityName]", "find": "tile find <tileFilter>"],
        "game": ["setdifficulty": "game setdifficulty <difficulty>", "setturn": "game setturn <nonNegativeAmount>"],
        "diplomacy": ["list": "diplomacy list <civName> <civName>", "meet": "diplomacy meet <civName> <civName>", "declare-war": "diplomacy declare-war <civName> <civName>", "make-peace": "diplomacy make-peace <civName> <civName>", "setflag": "diplomacy setflag <civName> <civName> <diplomacyFlag> <amount>", "removeflag": "diplomacy removeflag <civName> <civName> <diplomacyFlag>", "addmodifier": "diplomacy addmodifier <civName> <civName> <diplomaticModifier> <amount>", "removemodifier": "diplomacy removemodifier <civName> <civName> <diplomaticModifier>", "setinfluence": "diplomacy setinfluence <civName> <civName> <amount>", "denounce": "diplomacy denounce <civName> <civName>"],
    ]

    /// Unciv RiverGenerator.RiverDirections: the six clock positions a river edge can be named by.
    static let riverDirections: [(String, Int)] = [("North", HexCoord.dirN), ("NorthEast", HexCoord.dirNE), ("SouthEast", HexCoord.dirSE), ("South", HexCoord.dirS), ("SouthWest", HexCoord.dirSW), ("NorthWest", HexCoord.dirNW)]

    // MARK: parsing (Unciv CliInput: quoted or dashed words; matching ignores case, spaces and dashes)
    static func split(_ line: String) -> [String] {
        var out: [String] = []; var cur = ""; var quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle(); continue }
            if (ch == " " || ch == "\n" || ch == "\t") && !quoted { if !cur.isEmpty { out.append(cur); cur = "" }; continue }
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
    /// Turkish keyboards type a dotless ı for i; fold it so commands still match.
    static func fold(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "i") }
    static func norm(_ s: String) -> String { fold(s).replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces) }
    private func match(_ input: String, in names: [String]) -> String? {
        let n = DevConsole.norm(input)
        return names.first { DevConsole.norm($0) == n }
    }
    private func civNamed(_ name: String) throws -> Civilization {
        guard let c = state.civs.first(where: { DevConsole.norm($0.nation) == DevConsole.norm(name) }) else { throw ConsoleError(message: "Unknown civ: \(name)") }
        return c
    }
    /// Unciv CliInput.toInt: `content.toIntOrNull()` - a Kotlin Int, 32 bits - so a number outside Int32 is "not a valid
    /// number" as much as one that is no number at all (Swift's Int32(String) takes the same signs and digits). Our own
    /// Int is 64 bits, and taking 9223372036854775807 there stopped the app a step later: `game setturn` adding 1 to it,
    /// `civ addstat` adding it to the science or converting the Double it became back to Int.
    nonisolated static func parseInt(_ s: String) -> Int? { Int32(s).map { Int($0) } }
    private func int(_ s: String) throws -> Int { guard let v = DevConsole.parseInt(s) else { throw ConsoleError(message: "'\(s)' is not a valid number.") }; return v }
    private func bool(_ s: String) throws -> Bool { switch s.lowercased() { case "true": return true; case "false": return false; default: throw ConsoleError(message: "'\(s)' is not a valid boolean value.") } }
    /// Unciv DevConsolePopup.getSelectedTile: `screen.mapHolder.selectedTile` - the tile last tapped on the map, which
    /// our battle table keeps as its target (every tap sets it, explored or not).
    private func selectedTile() throws -> HexCoord {
        if let t = controller.battleTarget ?? controller.infoTile, state.map.contains(t) { return t }
        throw ConsoleError(message: "Select tile")
    }
    /// Unciv DevConsolePopup.getSelectedUnit: the unit table's selected unit if it stands on the selected tile, else the
    /// tile's first unit (Tile.getUnits: the military unit, the civilian, then the air units) - whoever owns it.
    private func selectedUnit() throws -> Unit {
        let t = try selectedTile()
        let here = state.units(at: t)
        guard let first = here.first else { throw ConsoleError(message: "Select tile with units") }
        if let u = controller.selectedUnit, u.coord == t { return u }
        return first
    }
    /// Unciv DevConsolePopup.getSelectedCity: `getSelectedTile().getCity()` - the city owning the selected tile.
    private func selectedCity() throws -> City {
        guard let c = state.owningCity(try selectedTile()) else { throw ConsoleError(message: "Select tile belonging to city") }
        return c
    }

    // MARK: autocomplete (Unciv DevConsoleCommand.autocomplete)
    /// Unciv CliInput.getAutocompleteString's response: `showResponse(null)` first, then - with several matches - "Matching
    /// completions: a, b, …" (sorted, at most 42 then "... (n not shown)") in its lime-olive
    private(set) var completionMessage: String? = nil
    private func noteMatches(_ hits: [String]) {
        guard hits.count > 1 else { return }
        let sorted = hits.sorted()
        completionMessage = "Matching completions: " + sorted.prefix(42).joined(separator: ", ") + (sorted.count > 42 ? ", ... (\(sorted.count - 42) not shown)" : "")
    }
    func autocomplete(_ line: String) -> String? {
        completionMessage = nil
        let parts = DevConsole.split(line)
        let endsWithSpace = line.hasSuffix(" ")
        if parts.isEmpty { return nil }
        if parts.count == 1 && !endsWithSpace {
            let hits = (Array(DevConsole.formats.keys) + ["history"]).sorted().filter { $0.hasPrefix(DevConsole.fold(parts[0])) }   // ConsoleCommandRoot's keys, history among them
            if hits.isEmpty { return nil }
            noteMatches(hits)
            return hits.count == 1 ? hits[0] + " " : DevConsole.commonPrefix(hits)
        }
        guard let sub = DevConsole.formats[DevConsole.fold(parts[0])] else { return nil }
        if parts.count == 2 && !endsWithSpace || parts.count == 1 {
            let prefix = parts.count == 2 ? DevConsole.fold(parts[1]) : ""
            let hits = sub.keys.sorted().filter { $0.hasPrefix(prefix) }
            if hits.count == 1 { return parts[0] + " " + hits[0] + " " }
            noteMatches(hits)
            return hits.isEmpty ? nil : parts[0] + " " + DevConsole.commonPrefix(hits)
        }
        guard let format = sub[DevConsole.fold(parts[1])] else { return nil }
        let formatParams = format.split(separator: " ").dropFirst(2).map(String.init)
        let index = parts.count - 2 - (endsWithSpace ? 0 : 1)
        guard index >= 0, index < formatParams.count else { return nil }
        let paramType = formatParams[index].trimmingCharacters(in: CharacterSet(charactersIn: "<>[]\""))
        let options = optionsFor(paramType)
        let typed = endsWithSpace ? "" : DevConsole.fold(parts.last!)
        let hits = options.filter { DevConsole.norm($0).hasPrefix(DevConsole.norm(typed)) }.sorted()
        guard let first = hits.first else { return nil }
        noteMatches(hits)
        // Unciv CliInput.getAutocompleteString: with several matches, complete only as far as they all agree.
        let completion = hits.count == 1 ? first : DevConsole.commonPrefix(hits)
        if completion.isEmpty { return nil }
        let quoted = completion.contains(" ") ? "\"\(completion)\"" : completion
        let head = (endsWithSpace ? parts : Array(parts.dropLast())).joined(separator: " ")
        return head + " " + quoted + (hits.count == 1 ? " " : "")
    }
    /// Unciv CliInput.getAutocompleteString: the longest prefix every matching option shares.
    static func commonPrefix(_ options: [String]) -> String {
        guard var prefix = options.first else { return "" }
        for option in options.dropFirst() {
            var i = prefix.startIndex, j = option.startIndex, shared = ""
            while i < prefix.endIndex, j < option.endIndex, norm(String(prefix[i])) == norm(String(option[j])) {
                shared.append(prefix[i]); i = prefix.index(after: i); j = option.index(after: j)
            }
            prefix = shared
        }
        return prefix
    }

    private func optionsFor(_ type: String) -> [String] {
        let rs = state.rs
        switch type {
        case "civName", "civ": return state.civs.map { $0.nation }
        case "newCivName": return rs.nations.keys.filter { n in !state.civs.contains { $0.nation == n } }
        case "unitName": return Array(rs.units.keys)
        case "promotionName": return Array(rs.promotions.keys)
        case "improvementName": return Array(rs.improvements.keys)
        case "featureName": return rs.terrainFeatures.map { $0.name }
        case "terrainName": return rs.baseTerrains.map { $0.name } + rs.naturalWonders.map { $0.name }
        case "resourceName": return Array(rs.resources.keys)
        case "stat": return ["Food", "Production", "Gold", "Science", "Culture", "Happiness", "Faith"]
        case "religionName": return state.civs.compactMap { $0.religionName } + rs.religionNames
        case "buildingName": return Array(rs.buildings.keys)
        case "policyName": return rs.policyBranches.map { $0.name } + rs.policies.keys
        case "techName": return Array(rs.techs.keys)
        case "cityName": return state.cities.map { $0.name }
        case "difficulty": return rs.difficulties.map { $0.name }
        case "boolean": return ["true", "false"]
        case "direction": return DevConsole.riverDirections.map { $0.0 }
        case "diplomaticModifier": return DiploModifier.allCases.map { $0.rawValue }
        case "diplomacyFlag": return ["DeclinedDeclarationOfFriendship", "DeclaredWar", "DeclinedPeace", "RecentlyBullied", "DeclinedResearchAgreement", "DeclinedDefensivePact", "SettledCitiesNearUs", "AgreedToNotSettleNearUs", "SpreadReligionInOurCities", "AgreedToNotSpreadReligion", "SpiedOnUs", "AgreedToNotSpyOnUs", "IgnoreThemSuppliedUnits", "ProvideMilitaryUnit", "MarriageCooldown", "NotifiedAfraid", "RecentlyPledgedProtection", "RecentlyWithdrewProtection", "AngerFreeFromCityState", "RememberDestroyedProtectedMinor", "RememberAttackedProtectedMinor", "RememberBulliedProtectedMinor", "RememberSidedWithProtectedMinor", "Denunciation", "WaryOf", "Bullied", "RecentlyAttacked", "DeclaredFriendship", "DefensivePact", "ResearchAgreement", "BorderConflict", "SharedEmbassy", "EverBeenFriends"]
        default: return []
        }
    }

    // MARK: execution
    func handle(_ line: String) -> Response {
        let parts = DevConsole.split(line)
        // Unciv ConsoleCommandNode.handle: no word at all is the hint "Available commands: a, b, …" (the node's keys sorted,
        // history among them), an unknown one the error "Invalid command.\nAvailable commands:\n- a\n- b…"; the same one
        // level down (`game` alone hints, `game foo` errs)
        let rootCommands = (Array(DevConsole.formats.keys) + ["history"]).sorted()
        guard let first = parts.first.map(DevConsole.fold) else { return DevConsole.hint("Available commands: " + rootCommands.joined(separator: ", ")) }
        if first == "history" { return DevConsole.hint(UserSettings.consoleCommandHistory.joined(separator: "\n")) }
        guard let sub = DevConsole.formats[first] else {
            return DevConsole.error("Invalid command.\nAvailable commands:\n- " + rootCommands.joined(separator: "\n- "))
        }
        guard parts.count >= 2 else { return DevConsole.hint("Available commands: " + sub.keys.sorted().joined(separator: ", ")) }
        guard let format = sub[DevConsole.fold(parts[1])] else {
            return DevConsole.error("Invalid command.\nAvailable commands:\n- " + sub.keys.sorted().joined(separator: "\n- "))
        }
        let params = Array(parts.dropFirst(2))
        let formatParams = format.split(separator: " ").dropFirst(2).map(String.init)
        let required = formatParams.filter { $0.hasPrefix("<") }.count
        if params.count < required || (params.count > formatParams.count && !format.hasSuffix("]...")) { return DevConsole.hint("Format: \(format)") }   // Unciv validateFormat: ConsoleHintException
        do {
            let r: Response
            switch first {
            case "unit": r = try unit(DevConsole.fold(parts[1]), params)
            case "city": r = try city(DevConsole.fold(parts[1]), params)
            case "civ": r = try civ(DevConsole.fold(parts[1]), params)
            case "tile": r = try tile(DevConsole.fold(parts[1]), params)
            case "game": r = try game(DevConsole.fold(parts[1]), params)
            default: r = try diplomacy(DevConsole.fold(parts[1]), params)
            }
            controller.refresh()
            return r
        } catch let e as ConsoleError { return DevConsole.error(e.message) }
        catch { return DevConsole.error(error.localizedDescription) }
    }

    private func unit(_ cmd: String, _ p: [String]) throws -> Response {
        switch cmd {
        case "checkfilter": let u = try selectedUnit(); return DevConsole.hint("\(state.unitMatches(u, p[0]))")   // Unciv: DevConsoleResponse.hint
        case "add":
            let civ = try civNamed(p[0]); let t = try selectedTile()
            guard let name = match(p[1], in: Array(state.rs.units.keys)) else { throw ConsoleError(message: "Unknown unit: \(p[1])") }
            guard state.spawnUnit(name, civId: civ.id, at: t) != nil else { throw ConsoleError(message: "Could not place unit") }
            return DevConsole.ok()
        case "remove":
            // Unciv: `unit.destroy()` - for "all", every unit of every civ (a carrier's cargo goes with it, and is then skipped)
            if p.first?.lowercased() == "all" {
                for civ in state.civs { for u in state.units(of: civ.id) { state.destroyUnit(u.id) } }
                controller.selectedUnitId = nil
                return DevConsole.ok()
            }
            let u = try selectedUnit(); state.destroyUnit(u.id); if controller.selectedUnitId == u.id { controller.selectedUnitId = nil }; return DevConsole.ok()
        case "setmovement":
            // Unciv: amount defaults to maxMovement but is not limited by it; a Float, never below 0
            let u = try selectedUnit(); guard let i = state.unitIndex(u.id) else { return DevConsole.ok() }
            var movement = state.maxMovement(of: u)   // Unciv MapUnit.getMaxMovement: embarked 2, civ and conditional uniques
            if let s = p.first, !s.isEmpty {
                guard let f = Float(s) else { throw ConsoleError(message: "'\(s)' is not a valid number.") }
                movement = Double(f)
            }
            if movement < 0 { throw ConsoleError(message: "Number out of range") }
            state.units[i].movementLeft = movement; return DevConsole.ok()
        case "sethealth":
            var h = 100   // Unciv: `params.firstOrNull()?.takeIf { !it.isEmpty() }?.toInt() ?: 100`
            if let s = p.first, !s.isEmpty { h = try int(s) }
            guard (1...100).contains(h) else { throw ConsoleError(message: "Number out of range") }
            let u = try selectedUnit(); guard let i = state.unitIndex(u.id) else { return DevConsole.ok() }
            state.units[i].health = h; return DevConsole.ok()
        case "setxp":
            // Unciv: `params.firstOrNull()?.toInt() ?: throw "No XP provided"`, then "Number out of range" below 0
            guard let s = p.first else { throw ConsoleError(message: "No XP provided") }
            let xp = try int(s)
            if xp < 0 { throw ConsoleError(message: "Number out of range") }
            let u = try selectedUnit(); guard let i = state.unitIndex(u.id) else { return DevConsole.ok() }
            state.units[i].xp = xp; return DevConsole.ok()
        case "addpromotion":
            // Unciv: `unit.promotions.addPromotion(promotion.name, isFree = true)` - its triggers, one-shot effects,
            // updateUniques and updateVisibleTiles
            let u = try selectedUnit(); guard let name = match(p[0], in: Array(state.rs.promotions.keys)) else { throw ConsoleError(message: "Unknown promotion") }
            state.addPromotion(unitId: u.id, name, isFree: true); return DevConsole.ok()
        case "removepromotion":
            // Unciv: only a promotion the unit has; "No such action in-game so we need to manually update" - the
            // promotion goes, then updateUniques and updateVisibleTiles, and no "upon losing" trigger fires
            let u = try selectedUnit()
            guard let name = match(p[0], in: u.promotions) else { throw ConsoleError(message: "Promotion not found on unit") }
            guard let i = state.unitIndex(u.id) else { return DevConsole.ok() }
            if let k = state.units[i].promotions.firstIndex(of: name) { state.units[i].promotions.remove(at: k) }
            state.updateUnitUniquesCache(u.id)
            state.updateVisibleTilesAfterPromotionChange(u.id)
            return DevConsole.ok()
        default: throw ConsoleError(message: "Unknown command")
        }
    }

    private func city(_ cmd: String, _ p: [String]) throws -> Response {
        switch cmd {
        // Unciv ConsoleCityCommands checkfilter: `city.matchesFilter(params[0].toString())` - MultiFilter, viewingCiv the owner
        case "checkfilter": let c = try selectedCity(); return DevConsole.hint("\(state.cityMatchesFilter(p[0], city: c, viewer: c.civId))")   // Unciv: DevConsoleResponse.hint
        case "add":
            // Unciv: major civs and city-states only; any tile that is not already a city centre - water or foreign land
            // included - gets `civ.addCity(position)`: CityFounder.foundCity without a unit, then chooseNextConstruction
            let civ = try civNamed(p[0])
            guard civ.isMajor || civ.isCityState else { throw ConsoleError(message: "Can only add cities to major civs or city states") }
            let t = try selectedTile()
            if state.map[t]?.isCityCenter == true { throw ConsoleError(message: "Tile already contains a city center") }
            if let cityId = state.foundCity(civId: civ.id, at: t, unitId: nil) { state.chooseNextConstructionIfAutomated(cityId: cityId) }
            return DevConsole.ok()
        case "remove":
            let c = try selectedCity(); state.destroyCity(cityId: c.id, overrideSafeties: true)   // Unciv: destroyCity(overrideSafeties = true)
            controller.selectedCityId = nil; return DevConsole.ok()
        case "setpop":
            // Unciv: population.setPopulation(n) = addPopulation(n - population) - religion pressure and the citizens follow
            let c = try selectedCity(); let n = try int(p[0]); guard n >= 1 else { throw ConsoleError(message: "Population must be at least 1") }
            if let i = state.cityIndex(c.id) { state.addPopulation(cityIndex: i, n - state.cities[i].population) }; return DevConsole.ok()
        case "setname": let c = try selectedCity(); if let i = state.cityIndex(c.id) { state.cities[i].name = p[0] }; return DevConsole.ok()
        case "addtile":
            // Unciv: the selected tile must border a tile of the city and not be a city centre; every tile in the radius
            // that is not the city's own nor a city centre goes through city.expansion.takeOwnership
            let t = try selectedTile()
            guard let c = state.cities.first(where: { DevConsole.norm($0.name) == DevConsole.norm(p[0]) }) else { throw ConsoleError(message: "Unknown city: \(p[0])") }
            if !state.map.neighbors(of: t).contains(where: { state.owningCity($0)?.id == c.id }) {
                throw ConsoleError(message: "Tile is not adjacent to any tile already owned by the city")
            }
            if state.map[t]?.isCityCenter == true { throw ConsoleError(message: "Cannot transfer city center") }
            let radius = p.count > 1 ? try int(p[1]) : 0
            for tile in state.map.tilesWithin(t, radius: radius) where state.owningCity(tile)?.id != c.id && state.map[tile]?.isCityCenter != true {
                state.takeOwnership(cityId: c.id, tile)
            }
            return DevConsole.ok()
        case "removetile":
            // Unciv: the selected city (the one owning the tile) relinquishes it
            let t = try selectedTile(); let c = try selectedCity()
            state.relinquishOwnership(cityId: c.id, t); return DevConsole.ok()
        case "religion":
            // Unciv: `params[0].findOrNull(gameInfo.religions.keys) ?: throw "'x' is not a known religion"`
            let c = try selectedCity()
            let known = state.foundedReligions + state.civs.compactMap { $0.religionName == nil ? $0.pantheonBelief : nil }
            guard let religion = match(p[0], in: known) else { throw ConsoleError(message: "'\(p[0])' is not a known religion") }
            let amount = try int(p[1])
            guard let i = state.cityIndex(c.id) else { return DevConsole.ok() }
            // Unciv ConsoleCityCommands: addPressure(religion, pressure.coerceAtLeast(-current)); updatePressureOnPopulationChange(0)
            state.addPressure(cityIndex: i, religion, max(amount, -Int(state.cities[i].religionPressure[religion] ?? 0)))
            if state.cities[i].religionPressure[religion] == 0 { state.cities[i].religionPressure[religion] = nil }
            state.updatePressureOnPopulationChange(cityIndex: i, 0); return DevConsole.ok()
        case "sethealth":
            // Unciv: City.getMaxHealth() - 200 plus the buildings' cityHealth (Walls give 50)
            let c = try selectedCity(); let maxHealth = state.cityMaxHealth(c)
            let h = p.isEmpty ? maxHealth : try int(p[0])
            guard (1...maxHealth).contains(h) else { throw ConsoleError(message: "Number out of range") }
            if let i = state.cityIndex(c.id) { state.cities[i].health = h }; return DevConsole.ok()
        case "addbuilding":
            // Unciv: cityConstructions.addBuilding(building) - free buildings, triggers and the stats update with it
            let c = try selectedCity(); guard let name = match(p[0], in: Array(state.rs.buildings.keys)), let i = state.cityIndex(c.id) else { throw ConsoleError(message: "Unknown building") }
            state.addBuilding(cityIndex: i, name); return DevConsole.ok()
        case "removebuilding":
            // Unciv: cityConstructions.removeBuilding(building)
            let c = try selectedCity(); guard let name = match(p[0], in: Array(state.rs.buildings.keys)), let i = state.cityIndex(c.id) else { throw ConsoleError(message: "Unknown building") }
            state.removeBuilding(cityIndex: i, name); return DevConsole.ok()
        case "setpuppet":
            // Unciv: `city.isPuppet = params.getOrNull(0)?.toBoolean() ?: true` - the flag only, no puppet or annex chain
            let c = try selectedCity(); let on = try p.first.map { try bool($0) } ?? true
            if let i = state.cityIndex(c.id) { state.cities[i].isPuppet = on }; return DevConsole.ok()
        default: throw ConsoleError(message: "Unknown command")
        }
    }

    private func civ(_ cmd: String, _ p: [String]) throws -> Response {
        switch cmd {
        case "addstat":
            // Unciv: a stat of Stat.statsWithCivWideField (Gold, Science, Culture, Faith, Happiness), then Civilization.addStat -
            // culture through the policy manager and the contest totals, faith likewise, happiness does nothing
            let stat = DevConsole.fold(p[0]).capitalized; let amount = try int(p[1])
            guard ["Gold", "Science", "Culture", "Faith", "Happiness"].contains(stat) else { throw ConsoleError(message: "Stat must be one of: Gold, Science, Culture, Faith, Happiness") }
            let civ = p.count > 2 ? try civNamed(p[2]) : state.player
            state.applyStatGain(civId: civ.id, stat: stat, amount: Double(amount))
            return DevConsole.ok()
        case "setplayertype":
            let civ = try civNamed(p[0]); guard let i = state.civIndex(civ.id) else { return DevConsole.ok() }
            guard civ.isMajor else { throw ConsoleError(message: "Can only change player type for major civs") }
            switch p[1].lowercased() { case "ai": state.civs[i].isPlayer = false; case "human": state.civs[i].isPlayer = true; default: throw ConsoleError(message: "'\(p[1])' is not a valid PlayerType. Options are: [AI, Human].") }
            return DevConsole.ok()
        case "revealmap":
            let civ = p.isEmpty ? state.player : try civNamed(p[0]); guard let i = state.civIndex(civ.id) else { return DevConsole.ok() }
            state.civs[i].explored = Set(state.map.tiles.map { $0.coord }); state.checkExploredRegionForWholeMap(i); return DevConsole.ok()
        case "addpolicy":
            // Unciv: a policy or branch (findCliInput<Policy>); adopted already → a hint; else freePolicies++ and adopt,
            // with its triggers, the branch completion and the city stats refresh
            let civ = try civNamed(p[0]); guard let i = state.civIndex(civ.id) else { return DevConsole.ok() }
            let branch = match(p[1], in: state.rs.policyBranches.map { $0.name })
            guard let name = branch ?? match(p[1], in: Array(state.rs.policies.keys)) else { throw ConsoleError(message: "Unrecognized policy") }
            if state.civs[i].policies.contains(name) { return DevConsole.hint("\(civ.nation) already has adopted \(name)") }
            state.civs[i].freePolicies += 1
            if branch != nil { state.adopt(civId: civ.id, branch: name, ignoringRequirements: true) } else { state.adopt(civId: civ.id, policy: name, ignoringRequirements: true) }
            return DevConsole.ok()
        case "removepolicy":
            // Unciv: removePolicy(policy, assumeWasFree = true) - "See UniqueType.OneTimeRemovePolicy"
            let civ = try civNamed(p[0]); guard let i = state.civIndex(civ.id) else { return DevConsole.ok() }
            guard let name = match(p[1], in: state.rs.policyBranches.map { $0.name }) ?? match(p[1], in: Array(state.rs.policies.keys)) else { throw ConsoleError(message: "Unrecognized policy") }
            if !state.civs[i].policies.contains(name) { return DevConsole.hint("\(civ.nation) does not have \(name)") }
            state.removePolicy(civId: civ.id, name, assumeWasFree: true)
            return DevConsole.ok()
        case "addtech":
            let civ = try civNamed(p[0]); guard let i = state.civIndex(civ.id) else { return DevConsole.ok() }
            guard let t = match(p[1], in: Array(state.rs.techs.keys)) else { throw ConsoleError(message: "Unrecognized technology") }
            if state.civs[i].techs.contains(t) { return DevConsole.hint("\(civ.nation) already has researched \(t)") }
            state.addTechnology(civId: state.civs[i].id, tech: t, showNotification: false); return DevConsole.ok()   // Unciv: addTechnology(tech.name, false)
        case "removetech":
            let civ = try civNamed(p[0]); guard let i = state.civIndex(civ.id) else { return DevConsole.ok() }
            guard let t = match(p[1], in: Array(state.rs.techs.keys)) else { throw ConsoleError(message: "Unrecognized technology") }
            if !state.civs[i].techs.contains(t) { return DevConsole.hint("\(civ.nation) does not have \(t)") }
            state.civs[i].techs.remove(t); return DevConsole.ok()
        case "add":
            // Unciv "meant for Scenario building": a nation not yet in the game, as one settler-like unit near the
            // selected tile (a city-state is set up by initCityState first); no room for it takes the civ out again
            let present = Set(state.civs.map { $0.nation })
            guard let nation = match(p[0], in: state.rs.nations.keys.filter { !present.contains($0) }) else { throw ConsoleError(message: "'\(p[0])' is not a valid Nation.") }
            let t = try selectedTile()
            // "Not random - getting a Conquistador might be unfair"
            guard let settler = state.rs.unitOrder.compactMap({ state.rs.units[$0] }).first(where: { ($0.uniqueTo == nil || $0.uniqueTo == nation) && $0.isSettler }) else {
                throw ConsoleError(message: "No allowed Settler units in the ruleset")
            }
            var civ = state.newCivilization(nation: nation)
            if state.rs.nations[nation]?.isCityState == true {
                var rng = state.stateBasedRandom("DevConsole civ add", GameState.UniqueContext(civId: -1))   // GameContext(gameInfo = gameInfo)
                if !state.initCityState(&civ, usedMajorCivs: Set(state.civs.filter { $0.isMajor }.map { $0.nation }), rng: &rng) {
                    throw ConsoleError(message: "City-state not allowed in this game")
                }
            }
            state.civs.append(civ)
            let placed = state.spawnUnit(settler.name, civId: civ.id, at: t)
            state.updateExploration(for: civ.id)   // civ.cache.updateViewableTiles()
            if placed == nil {
                state.civs.removeAll { $0.id == civ.id }
                return DevConsole.error("No place for new Settler found")
            }
            return DevConsole.ok()
        case "remove":
            // Unciv: never the current player; a defeated civ is annihilated at once, any other only after the
            // "Do you really want to annihilate the poor buggers?" confirmation
            let civ = try civNamed(p[0])
            if civ.id == state.playerId { throw ConsoleError(message: "Suicide is not yet supported") }
            if state.isDefeated(civ) { state.annihilateCiv(civ.id) }
            else {
                let message = "\(civ.nation) has \(state.cities(of: civ.id).count) cities and \(state.units(of: civ.id).count) units.\n\nDo you really want to annihilate the poor buggers?"
                controller.pendingAnnihilation = (civId: civ.id, message: message)
            }
            return DevConsole.ok()
        default: throw ConsoleError(message: "Unknown command")
        }
    }

    /// Unciv ConsoleTileCommands. "We *don't* call TileNormalizer.normalizeToRuleset - we want the console to allow invalid
    /// tile configurations." Every command acts on the map through the ported Tile functions, then (where Unciv does)
    /// the owning city reassigns its citizens.
    private func tile(_ cmd: String, _ p: [String]) throws -> Response {
        let t = try selectedTile()
        guard let tile = state.map[t] else { throw ConsoleError(message: "Select tile") }
        /// Unciv `selectedTile.getCity()?.reassignPopulation()`
        func reassignPopulation() { if let city = state.owningCity(t) { state.assignWorkers(cityId: city.id, why: "DevConsole tile") } }
        switch cmd {
        case "checkfilter": return DevConsole.hint("\(state.tileMatches(tile, p[0], civId: state.playerId))")   // Unciv: DevConsoleResponse.hint
        case "setimprovement":
            // Unciv: `selectedTile.setImprovement(improvement, civ)` - the civ is only the one activating broader effects
            // (road owner, the improvement's uniques, the owning city's refresh), never the tile's owner
            guard let imp = match(p[0], in: Array(state.rs.improvements.keys)) else { throw ConsoleError(message: "Unknown improvement") }
            let civ = p.count > 1 ? try civNamed(p[1]) : nil
            state.setImprovement(at: t, imp, civToActivateBroaderEffects: civ?.id)
            reassignPopulation(); return DevConsole.ok()
        case "removeimprovement": state.setImprovement(at: t, nil); reassignPopulation(); return DevConsole.ok()
        case "setpillaged":
            // Unciv: Tile.setPillaged() / setRepaired()
            if try bool(p[0]) { state.setPillaged(at: t) } else { state.setRepaired(at: t) }
            return DevConsole.ok()
        // Unciv: `selectedTile.removeRoad()` (the pillage flag and the neutral-road bookkeeping with it), then the owner's
        // updateCitiesConnectedToCapital
        case "removeroad":
            state.removeRoad(at: t)
            if let owner = state.map[t]?.ownerCivId { state.updateCitiesConnectedToCapital(owner) }
            return DevConsole.ok()
        case "addfeature":
            // Unciv: a River grows on through RiverGenerator.continueRiverOn; any other feature is added when missing
            guard let f = match(p[0], in: state.rs.terrainFeatures.map { $0.name }) else { throw ConsoleError(message: "Unknown feature") }
            if f == "River" { _ = state.continueRiverOn(t) }
            else { state.map.update(t) { if !$0.features.contains(f) { $0.features.append(f) } } }
            reassignPopulation(); return DevConsole.ok()
        case "removefeature":
            guard let f = match(p[0], in: state.rs.terrainFeatures.map { $0.name }) else { throw ConsoleError(message: "Unknown feature") }
            if f == "River" { return DevConsole.hint("Rivers cannot be removed like a terrain feature - use tile removeriver <direction>") }
            state.map.update(t) { if let k = $0.features.firstIndex(of: f) { $0.features.remove(at: k) } }   // Tile.removeTerrainFeature
            reassignPopulation(); return DevConsole.ok()
        case "setterrain":
            guard let name = match(p[0], in: state.rs.terrainOrder), let terrain = state.rs.terrains[name] else { throw ConsoleError(message: "Unknown terrain") }
            if terrain.type == .naturalWonder {
                // Unciv setNaturalWonder: no features, the wonder, the base it turns into; then every civ that has explored
                // the tile and lacks the wonder looks for it (discoverNaturalWonders) and updates its stats
                state.map.update(t) { $0.features = []; $0.naturalWonder = name; $0.baseTerrain = terrain.turnsInto ?? $0.baseTerrain }
                reassignPopulation()
                for civ in state.civs where !civ.seenNaturalWonders.contains(name) && !state.isDefeated(civ) && !civ.isBarbarian && !civ.isSpectator && civ.explored.contains(t) {
                    state.discoverNaturalWonders(civId: civ.id)
                    state.updateStatsForNextTurn(civ.id)
                }
                return DevConsole.ok()
            }
            // Unciv setBaseTerrain: "Changing terrain type is not allowed" - land stays land, water stays water
            if terrain.type != state.rs.terrains[tile.baseTerrain]?.type { throw ConsoleError(message: "Changing terrain type is not allowed") }
            state.map.update(t) { $0.baseTerrain = name }
            reassignPopulation(); return DevConsole.ok()
        case "setresource":
            guard let r = match(p[0], in: Array(state.rs.resources.keys)), let resource = state.rs.resources[r] else { throw ConsoleError(message: "Unknown resource") }
            // Unciv ConsoleTileCommands: an amount may only be given for a strategic resource, and must be positive.
            var amount: Int? = nil
            if p.count > 1, !p[1].isEmpty { amount = try int(p[1]) }
            if amount != nil && resource.resourceType != "Strategic" { return DevConsole.error("Can't set resource amount for \(resource.resourceType) resource") }
            if let a = amount, a <= 0 { return DevConsole.error("Invalid resource amount") }
            // Unciv Tile.setTileResource(resource) with its default Random: no amount unless strategic, then the
            // "Deposits in [] tiles always provide [] resources" amount or a major/minor deposit of the map's setting
            let setting = state.settings.resourceSetting, rs = state.rs
            state.map.update(t) { tile in
                tile.resource = r
                if resource.resourceType != "Strategic" { tile.resourceAmount = 0; return }
                if let u = resource.uniqueObjects.first(where: { $0.pattern == "Deposits in [] tiles always provide [] resources" && tile.matchesTerrainFilterForDeposits($0.param(0)) }) {
                    tile.resourceAmount = u.int(1); return
                }
                let major = Double.random(in: 0..<1) < tile.approximateMajorDepositDistribution(rs)
                tile.resourceAmount = Tile.depositAmount(resource, on: tile, major: major, setting: setting)
            }
            if let a = amount { state.map.update(t) { $0.resourceAmount = a } }
            reassignPopulation(); return DevConsole.ok()
        case "removeresource":
            state.map.update(t) { $0.resource = nil }   // `tileResource = null` - the amount stays
            reassignPopulation(); return DevConsole.ok()
        case "setowner":
            // Unciv: the old owning city relinquishes the tile, the new one (a city by name, else a civ's nearest city -
            // one being razed counts 5 tiles further - none for a civ without cities) takes it
            let oldOwner = state.owningCity(t)
            var newOwner: City? = nil
            if let param = p.first, !param.isEmpty {
                let allCities = state.civs.flatMap { state.cities(of: $0.id) }   // civilizations.flatMap { civ -> civ.cities }
                if let named = allCities.first(where: { DevConsole.norm($0.name) == DevConsole.norm(param) }) { newOwner = named }
                else {
                    guard let civ = state.civs.first(where: { DevConsole.norm($0.nation) == DevConsole.norm(param) }) else {
                        throw ConsoleError(message: "\(param) is neither a city nor a civilization")
                    }
                    newOwner = state.cities(of: civ.id).min { a, b in
                        a.coord.distance(to: t) + (a.razing ? 5 : 0) < b.coord.distance(to: t) + (b.razing ? 5 : 0)
                    }
                }
            }
            if let o = oldOwner { state.relinquishOwnership(cityId: o.id, t) }
            if let n = newOwner { state.takeOwnership(cityId: n.id, t) }
            return DevConsole.ok()
        case "find":
            // Unciv: the tileList tiles matching the filter; none is a hint, otherwise a one-time notification with a
            // LocationAction for each match, executed at once
            let hits = state.map.tilesInUncivOrder().filter { state.tileMatches($0, p[0], civId: state.playerId) }.map { $0.coord }
            if hits.isEmpty { return DevConsole.hint("None found") }
            let item = NotificationItem(index: -1, text: "tile find [\(p[0])]: \(hits.count) matches", meta: NotificationMeta(category: .General, icons: ["Spy"], actions: hits.map { .location($0) }))
            controller.showOneTimeNotification(item, inList: false)
            return DevConsole.ok()
        case "addriver", "removeriver":
            // Unciv ConsoleTileCommands.ConsoleRiverAction: the edge towards the named neighbour, which has to be land.
            guard let d = DevConsole.riverDirections.first(where: { DevConsole.norm($0.0) == DevConsole.norm(p[0]) })?.1 else { throw ConsoleError(message: "'\(p[0])' is not a valid direction") }
            guard let other = state.map.neighbors(of: t).first(where: { t.wrappedDirection(to: $0) == d }) else { throw ConsoleError(message: "tile has no neighbor to the \(p[0])") }
            guard state.map[other]?.isLand == true else { throw ConsoleError(message: "there's no land to the \(p[0])") }
            state.map.setRiver(t, dir: d, cmd == "addriver")
            for c in [other, t] {
                let adjacent = (0..<6).contains { state.map.hasRiver(between: c, c.neighbor($0)) }
                state.map.update(c) { $0.riverAdjacent = adjacent }
            }
            return DevConsole.ok()
        case "spawn-barbarian-encampment":
            // Unciv ConsoleTileCommands: `gameInfo.barbarians.createNewCamp(selectedTile)` - no check of the tile, a random
            // camp-equivalent improvement, the camp recorded
            state.createNewCamp(at: t)
            return DevConsole.ok()
        default: throw ConsoleError(message: "Unknown command")
        }
    }

    private func game(_ cmd: String, _ p: [String]) throws -> Response {
        switch cmd {
        case "setdifficulty":
            guard let d = match(p[0], in: state.rs.difficulties.map { $0.name }) else { throw ConsoleError(message: "Unknown difficulty") }
            state.settings.difficulty = d; return DevConsole.ok()
        case "setturn":
            // Unciv: `gameInfo.turns = params[0].toInt()` (zero-based, no range check), then setTransients - ours counts
            // one ahead of gameInfo.turns outside the barbarian phase (GameContext.uncivTurns)
            let n = try int(p[0])
            state.turn = n + (state.barbarianPhase ? 0 : 1); return DevConsole.ok()
        default: throw ConsoleError(message: "Unknown command")
        }
    }

    private func diplomacy(_ cmd: String, _ p: [String]) throws -> Response {
        let a = try civNamed(p[0]); let b = try civNamed(p[1])
        guard let ai = state.civIndex(a.id), state.civIndex(b.id) != nil else { return DevConsole.ok() }
        // Unciv ConsoleDiplomacyCommands.getDiplomacy: both civs alive for every command; every command but `list` makes
        // them meet first (getDiplomacyManagerOrMeet → Civilization.makeCivilizationsMeet: first contact, a city-state's
        // gift, the capital revealed)
        guard a.isAlive, b.isAlive else { throw ConsoleError(message: "both civs must be alive") }
        if cmd != "list", a.id != b.id, !state.civs[ai].metCivs.contains(b.id) { state.makeCivilizationsMeet(a.id, b.id) }
        switch cmd {
        case "list":
            // Unciv: "not met" without a DiplomacyManager; else Relation, a city-state's Influence (the FIRST civ's), each
            // diplomatic modifier "<name> = <float>" and each flag "<name>: <n> turns", in their HashMaps' order
            guard state.civs[ai].metCivs.contains(b.id) else { return DevConsole.hint("not met") }
            let level = state.relationshipLevel(a.id, b.id)
            let levelNames = ["Unforgivable", "Enemy", "Afraid", "Competitor", "Neutral", "Favorable", "Friend", "Ally"]
            var lines = ["Relation: \(levelNames[level.rawValue])"]
            if a.isCityState { lines.append("Influence: \(Float(state.influence(of: b.id, with: a.id)))") }
            let modifiers = state.civs[ai].opinions[b.id] ?? [:]
            for k in javaHashMapOrder(Array(modifiers.keys)) { lines.append("\(k) = \(Float(modifiers[k] ?? 0))") }
            let flags = state.civs[ai].diploFlags[b.id] ?? [:]
            for k in javaHashMapOrder(Array(flags.keys)) { lines.append("\(k): \(flags[k] ?? 0) turns") }
            return DevConsole.hint(lines.joined(separator: "\n"))
        case "meet": return DevConsole.ok()
        case "declare-war":
            state.declareWar(a.id, on: b.id); return DevConsole.ok()
        case "make-peace":
            state.makePeace(a.id, b.id, withTreaty: false); return DevConsole.ok()   // Unciv DiplomacyManager.makePeace: no Peace Treaty
        case "setflag": let n = try int(p[3]); state.civs[ai].diploFlags[b.id, default: [:]][p[2]] = n; return DevConsole.ok()
        case "removeflag": state.civs[ai].diploFlags[b.id]?[p[2]] = nil; return DevConsole.ok()
        case "addmodifier":
            guard let m = DiploModifier.allCases.first(where: { DevConsole.norm($0.rawValue) == DevConsole.norm(p[2]) }) else { throw ConsoleError(message: "Unknown modifier") }
            guard let amount = Double(p[3]) else { throw ConsoleError(message: "'\(p[3])' is not a valid number.") }   // Unciv: params[3].toFloat()
            state.addModifier(a.id, b.id, m, amount); return DevConsole.ok()
        case "removemodifier": state.civs[ai].opinions[b.id]?[p[2]] = nil; return DevConsole.ok()
        case "setinfluence":
            // Unciv: the first civ the city-state, the second a major; `params[2].toFloat()`; DiplomacyManager.setInfluence
            // (clamped at -60, the ally updated at once)
            guard a.isCityState && b.isMajor else { throw ConsoleError(message: "first civ must be the city-state, second a major civ") }
            guard let amount = Double(p[2]) else { throw ConsoleError(message: "'\(p[2])' is not a valid number.") }
            state.setInfluence(cityState: a.id, major: b.id, amount); return DevConsole.ok()
        case "denounce": state.denounce(a.id, b.id); return DevConsole.ok()
        default: throw ConsoleError(message: "Unknown command")
        }
    }
}

// MARK: - Small helpers the console needs (Unciv City.matchesFilter / GameInfo.addCivilization)
extension GameState {
    /// Unciv `Civilization(nation)` as the console's `civ add` makes it: an AI civ with no techs, cities or units.
    func newCivilization(nation: String) -> Civilization {
        var c = Civilization(id: newId(), nation: nation, isPlayer: false)
        if let def = rs.nations[nation] { c.isCityState = def.isCityState; c.cityStateType = def.cityStateType }
        return c
    }

    /// Unciv CityStateFunctions.initCityState(ruleset, startingEra, usedMajorCivs, rng): the personality (the nation's
    /// own, else a draw), a Mercantile city-state's unique luxury, a Militaristic one's unique unit - each from `rng`.
    func initCityState(_ civ: inout Civilization, usedMajorCivs: Set<String>, rng: inout SeededRandom) -> Bool {
        guard let nation = rs.nations[civ.nation], let typeName = nation.cityStateType, let type = rs.cityStateTypes[typeName] else { return false }
        let bonusUniques = type.friendBonusUniques + type.allyBonusUniques
        let allMercantileResources = rs.resourcesInOrder.filter { $0.uniques.contains("Can only be created by Mercantile City-States") }.map { $0.name }
        // CityStatePersonality.safeValueOf(nation.personality) ?: CityStatePersonality.entries.random(rng)
        let personalities = ["Friendly", "Neutral", "Hostile", "Irrational"]
        if let own = nation.personality, personalities.contains(own) { civ.cityStatePersonality = own }
        else { civ.cityStatePersonality = personalities[Int(rng.nextInt(until: Int32(personalities.count)))] }
        if bonusUniques.contains("Provides a unique luxury") {   // UniqueType.CityStateUniqueLuxury
            civ.cityStateResource = allMercantileResources.isEmpty ? nil : allMercantileResources[Int(rng.nextInt(until: Int32(allMercantileResources.count)))]
        }
        if bonusUniques.contains(where: { $0.hasPrefix("Provides military units every") }) {   // UniqueType.CityStateMilitaryUnits
            let startEraIndex = rs.eraIndex(settings.startingEra)
            let possibleUnits = rs.unitOrder.compactMap { rs.units[$0] }.filter { u in
                // unit.availableInEra(ruleset, startingEra): no tech, or a tech of the starting era or before
                guard let tech = u.requiredTech, let era = rs.techs[tech]?.era, rs.eraIndex(era) > startEraIndex else { return false }
                guard let owner = u.uniqueTo, let uniqueNation = rs.nations[owner], uniqueNation.isMajor else { return false }
                if usedMajorCivs.contains(owner) { return false }
                return u.isLand && (u.strength > 0 || u.rangedStrength > 0)
            }
            if !possibleUnits.isEmpty { civ.cityStateUniqueUnit = possibleUnits[Int(rng.nextInt(until: Int32(possibleUnits.count)))].name }
        }
        return true
    }

    /// Unciv PolicyManager.removePolicy(policy, branchCompletion, assumeWasFree): the policy goes (a policy paid for gives
    /// its slot back unless assumed free), a branch marked complete reverts to incomplete, then updateCivResources and
    /// every city's stats and citizens.
    func removePolicy(civId: Int, _ policy: String, branchCompletion: Bool = false, assumeWasFree: Bool = false) {
        guard let ci = civIndex(civId), civs[ci].policies.contains(policy) else { return }
        civs[ci].policies.remove(policy)
        civs[ci].openBranches.remove(policy)   // a branch is adopted as a policy there; ours also lists it as open
        if !assumeWasFree && civs[ci].numberOfAdoptedPolicies > 0 { civs[ci].numberOfAdoptedPolicies -= 1 }
        if !branchCompletion {
            // `policy.branch`: a branch is its own branch
            let branchName = rs.policyBranches.contains(where: { $0.name == policy }) ? policy : rs.policyBranchOf[policy]
            if let bn = branchName, let branch = rs.policyBranches.first(where: { $0.name == bn }), let last = branch.policies.last,
               branch.policies.filter({ civs[ci].policies.contains($0.name) }).count == branch.policies.count - 1 {
                removePolicy(civId: civId, last.name, branchCompletion: true)
            }
        }
        updateCivResources(civId)
        for c in cities(of: civId) { updateCityStats(c.id, reason: "PolicyManager.removePolicy"); reassignPopulationDeferred(cityIndex(c.id) ?? 0) }
        invalidateHappiness(civId)
    }

    /// Unciv ConsoleCivCommands `civ remove` → annihilate(): the units leave (removeUnit + removeFromTile, not destroy),
    /// every tile of every city is let go (Tile.setOwningCity(null)) and the centre loses its improvement, roads the
    /// civ owned elsewhere forget it, the civ leaves the game, and every other civ drops its diplomacy with it -
    /// a city-state its quests for it - and recalls the spies it had in its cities.
    func annihilateCiv(_ civId: Int) {
        for u in units(of: civId) { removeUnit(u.id) }
        let deadCities = cities(of: civId)
        for city in deadCities {
            for t in city.tiles {
                map.update(t) { tile in
                    if (tile.roads || tile.railroad) && tile.ownerCivId != nil { tile.roadOwner = nil }   // "Razing City! Remove owner"
                    tile.ownerCivId = nil; tile.workingCityId = nil; tile.cityId = nil
                }
            }
            removeImprovement(at: city.coord)   // city.getCenterTile().removeImprovement()
        }
        for i in map.tiles.indices where map.tiles[i].roadOwner == civId { map.tiles[i].roadOwner = nil }   // tile.removeRoadOwner()
        neutralRoads[civId] = nil
        let deadCityIds = Set(deadCities.map { $0.id })
        for id in deadCityIds { unregisterCity(id) }
        cities.removeAll { deadCityIds.contains($0.id) }
        civs.removeAll { $0.id == civId }
        for j in civs.indices {
            // otherCiv.diplomacy.remove(civ.civID)
            civs[j].atWarWith.remove(civId); civs[j].metCivs.remove(civId); civs[j].metOrder.removeAll { $0 == civId }
            civs[j].lastPeaceTurn[civId] = nil; civs[j].influence[civId] = nil; civs[j].warStartTurn[civId] = nil
            civs[j].openBorders.remove(civId); civs[j].hasOpenBordersWith.remove(civId)
            civs[j].opinions[civId] = nil; civs[j].friendships[civId] = nil; civs[j].denouncements[civId] = nil
            civs[j].defensivePacts.remove(civId); civs[j].embassiesWith.remove(civId)
            civs[j].protectedCityStates.remove(civId); civs[j].protectionPledgedTurn[civId] = nil
            civs[j].peaceTreatyUntil[civId] = nil; civs[j].peaceTreatySharedOffer.remove(civId); civs[j].peaceTreatyStartDuration[civId] = nil; civs[j].diploFlags[civId] = nil
            civs[j].smoothedOpinion[civId] = nil; civs[j].cachedSmoothedOpinion[civId] = nil; civs[j].totalOfScienceDuringRA[civId] = nil
            // questManager.removeQuestsFor(civ): its assigned quests and its individual quest countdown
            if civs[j].isCityState {
                civs[j].quests.removeAll { $0.assigneeId == civId }
                civs[j].individualQuestCountdown[civId] = nil
            }
            // espionageManager.recallAllSpiesFrom(civ)
            for si in civs[j].spies.indices where civs[j].spies[si].cityId.map({ deadCityIds.contains($0) }) ?? false { spyMoveToHideout(j, si) }
        }
        invalidateHappiness()
    }
}
