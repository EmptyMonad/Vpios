// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
/// Mirror of Unciv `models/ruleset/unique/UniqueParameterType.kt`: what each filter parameter of a unique matches.
extension GameState {
    /// Unciv City.matchesSingleFilter: the cityFilter vocabulary, evaluated for `viewer` (the civ whose unique is being applied).
    func cityMatchesFilter(_ scope: String, city: City, viewer: Int) -> Bool {
        // Unciv MultiFilter: `non-[X]` is the negation, and `{a} {b}` requires every part to match.
        MultiFilter.multiFilter(scope) { self.cityMatchesSingleFilter($0, city: city, viewer: viewer) }
    }

    func cityMatchesSingleFilter(_ scope: String, city: City, viewer: Int) -> Bool {
        switch scope {
        case "", "in this city", "in all cities", "all", "All": return true
        case "in your cities", "Your": return viewer == city.civId
        case "in all non-occupied cities", "Non-occupied":
            // Unciv: !hasExtraAnnexUnhappiness() || isPuppet — the courthouse unique ends the occupation.
            // Same test as CityStats.hasExtraAnnexUnhappiness: a city with no known founder (`foundingCiv` that
            // matches no civ) is occupied there, and ours read it as the owner's own here - long t_194 Genoa.
            if city.isPuppet || city.originalOwner == city.civId { return true }
            return city.buildings.contains { rs.buildings[$0]?.uniques.contains("Removes extra unhappiness from annexed cities") == true }
        case "in capital", "Capital": return city.isCapital
        case "in all coastal cities", "Coastal": return map.isAdjacentToCoast(city.coord)   // Unciv City.isCoastal: centerTile.isAdjacentToCoast()
        case "in [Holy] cities", "in Holy cities", "in holy cities", "Holy": return city.isHolyCity
        case "in all cities with a world wonder": return city.buildings.contains { rs.buildings[$0]?.isWonder == true }
        case "in all cities connected to capital": return city.isCapital || city.connectedToCapital
        case "in all cities with a garrison", "Garrisoned": return units(at: city.coord).contains { $0.isMilitary && $0.def.isLand && $0.civId == city.civId }
        case "in all cities in which the majority religion is a major religion": return religionIsMajor(majorityReligion(of: city))
        case "in all cities in which the majority religion is an enhanced religion": return (majorityReligion(of: city).flatMap { religionOwner($0) }?.religionEnhanced) ?? false
        case "in non-enemy foreign cities": return viewer != city.civId && !areAtWar(viewer, city.civId)
        case "in enemy cities", "Enemy": return areAtWar(viewer, city.civId)
        case "in foreign cities", "Foreign": return viewer != city.civId
        case "in annexed cities", "Annexed": return city.originalOwner != city.civId && !city.isPuppet
        case "in puppeted cities", "Puppeted": return city.isPuppet
        case "in resisting cities", "Resisting": return city.resistanceTurns > 0
        case "in cities being razed", "Razing": return city.razing
        case "in City-State cities": return civ(city.civId)?.isCityState == true
        case "in cities following this religion": return true   // religion uniques only reach cities that follow it
        case "in cities following our religion": return civ(viewer)?.religionName != nil && majorityReligion(of: city) == civ(viewer)?.religionName
        default:
            // "in cities with a [X]" / "in all cities with a [X]"
            if scope.hasPrefix("in cities with a ") || scope.hasPrefix("in all cities with a ") {
                let name = scope.components(separatedBy: "with a ").last ?? ""
                return city.buildings.contains(name.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
            }
            if scope.hasPrefix("in cities without a ") {
                let name = scope.components(separatedBy: "without a ").last ?? ""
                return !city.buildings.contains(name.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
            }
            // Unciv: the city's own name, or its civilization's filter; anything else does not match
            if scope == city.name { return true }
            if let owner = civ(city.civId) { return civMatches(owner, scope, viewer: viewer) }
            return false
        }
    }

    // MARK: conditionals


    /// Unciv CityConstructions.containsBuildingOrEquivalent: the building itself or a unique building replacing it.
    func hasBuildingOrEquivalent(_ city: City, _ name: String) -> Bool {
        city.buildings.contains { $0 == name || rs.buildings[$0]?.replaces == name }
    }

    /// Unciv CityPopulationManager.getPopulationFilterAmount
    func populationFilterAmount(_ city: City, _ filter: String) -> Int {
        switch filter {
        case "Specialists": return city.specialists.values.reduce(0, +)
        case "Population": return city.population
        case "Followers of the Majority Religion", "Followers of this Religion": return majorityReligion(of: city).map { followers(of: city)[$0] ?? 0 } ?? 0
        case "Unemployed": return freePopulation(city)
        default: return city.specialists[filter] ?? 0
        }
    }

    /// Unciv Religion.matchesSingleFilter
    func religionMatches(_ name: String, _ filter: String, viewer: Civilization) -> Bool {
        let founder = civs.first { $0.religionName == name }
        let beliefs = founder?.religionBeliefs ?? []
        switch filter {
        case "any": return true
        case "major": return beliefs.contains { rs.beliefs[$0]?.type == "Founder" }
        case "enhanced": return beliefs.contains { rs.beliefs[$0]?.type == "Enhancer" }
        case "your": return founder?.id == viewer.id
        case "foreign": return founder?.id != viewer.id
        case "enemy": guard let f = founder else { return false }; return areAtWar(viewer.id, f.id)
        default: return filter == name || beliefs.contains(filter)
        }
    }

    // MARK: filters

    func unitMatches(_ unit: Unit, _ filter: String) -> Bool {
        MultiFilter.multiFilter(filter) { self.unitMatchesSingleFilter(unit, $0) }
    }

    func unitMatchesSingleFilter(_ unit: Unit, _ filter: String) -> Bool {
        let f = filter.trimmingCharacters(in: .whitespaces)
        let def = unit.def
        switch f {
        case "All", "all", "Unit", "unit": return true
        case "Military", "military": return unit.isMilitary
        case "Civilian", "civilian": return unit.isCivilian
        case "Land", "land": return def.isLand
        case "Water", "water": return def.isWater
        case "Air", "air": return def.isAir
        case "Melee", "melee": return unit.isMilitary && !def.isRanged
        case "Ranged", "ranged": return def.isRanged
        case "Wounded", "wounded": return unit.health < 100
        case "Embarked": return def.isLand && (map[unit.coord]?.isWater ?? false)
        case "Great Person": return unit.isGreatPerson
        case "Barbarian", "Barbarians": return civ(unit.civId)?.isBarbarian ?? false
        case "wounded units": return unit.health < 100
        case "City-State", "City-States": return civ(unit.civId)?.isCityState ?? false
        case "Non-City": return true
        case "non-air": return !def.isAir
        case "Nuclear Weapon": return def.uniqueObjects.contains { $0.pattern == "Nuclear weapon of Strength []" }
        case "Religious": return def.uniqueObjects.contains { $0.pattern == "Religious Unit" }
        default:
            if def.name == f || def.unitType == f { return true }
            if let base = def.replaces, base == f { return true }
            // Unciv MapUnit.matchesSingleFilter: nation, tag uniques, promotions and temporary statuses all count as filters.
            if let c = civ(unit.civId), c.nation == f { return true }
            if def.uniques.contains(f) { return true }
            // Unciv BaseUnit.getUniques folds in the unit type's own uniques, so a tag that sits on the type
            // matches the unit: "Aircraft" is on Fighter/Bomber/Atomic Bomber, never on a unit, and the
            // carriers in the shipped ruleset ask for exactly that.
            if rs.unitTypes[def.unitType]?.uniques.contains(f) == true { return true }
            // Unciv BaseUnit.matchesSingleFilter falls through to the unit's required technology, which matches
            // its own name, its era, and the "pre-[era]" / "post-[era]" forms.
            if let tech = def.requiredTech, techMatchesFilter(tech, f) { return true }
            if unit.promotions.contains(f) || unit.hasStatus(f) { return true }
            return false
        }
    }

    func tileMatches(_ tile: Tile, _ filter: String, civId: Int) -> Bool {
        MultiFilter.multiFilter(filter) { self.tileMatchesSingleFilter(tile, $0, civId: civId) }
    }

    /// Unciv Tile.matchesSingleFilter: the terrain filter first, then the improvement states, the worked state,
    /// the unpillaged improvement's own filter and last the unpillaged road's. A `civId` that names no civ is
    /// Unciv's `observingCiv == null`.
    func tileMatchesSingleFilter(_ tile: Tile, _ filter: String, civId: Int) -> Bool {
        let f = filter.trimmingCharacters(in: .whitespaces)
        if tileMatchesSingleTerrainFilter(tile, f, civId: civId) { return true }
        if (tile.improvement == nil || tile.pillaged) && f == "unimproved" { return true }
        if tile.improvement != nil && !tile.pillaged && f == "improved" { return true }
        if (tile.pillaged || tile.roadPillaged) && f == "pillaged" { return true }   // Unciv isPillaged(): the improvement or the road
        if f == "worked" && tile.workingCityId != nil { return true }
        if !tile.pillaged, let imp = tile.improvement.flatMap({ rs.improvements[$0] }), imp.matchesFilter(f, multiFilter: false) { return true }
        if (tile.roads || tile.railroad) && !tile.roadPillaged, let road = rs.improvements[tile.railroad ? "Railroad" : "Road"] {
            return road.matchesFilter(f, multiFilter: false)
        }
        return false
    }

    /// Unciv Tile.matchesSingleTerrainFilter
    func tileMatchesSingleTerrainFilter(_ tile: Tile, _ f: String, civId: Int) -> Bool {
        let observing = civ(civId)
        switch f {
        case "Terrain", "All", "all": return true
        case "Water", "water": return tile.isWater
        case "Land", "land": return tile.isLand
        case "Coastal": return map.isAdjacentToCoast(tile.coord)   // Unciv isAdjacentToCoast (a lazy, see GameMap)
        case "River": return tile.riverAdjacent
        case "Unowned": return tile.ownerCivId == nil
        case "your": return observing != nil && tile.ownerCivId == civId
        case "Foreign Land", "Foreign": return observing != nil && !isFriendlyTerritory(tile, for: civId)
        case "Friendly Land", "Friendly": return observing != nil && isFriendlyTerritory(tile, for: civId)
        case "Enemy Land", "Enemy": return observing != nil && tile.ownerCivId != nil && areAtWar(civId, tile.ownerCivId!)
        case "resource": return observing != nil && canSeeResource(tile.resource, civId: civId)
        case "Water resource": return tile.isWater && observing != nil && canSeeResource(tile.resource, civId: civId)
        case "Featureless": return tile.features.isEmpty
        case "Open terrain": return !tile.isRough   // Unciv: every terrain open, not one
        case "Fresh Water": return hasFreshWater(tile)   // Unciv Constants.freshWaterFilter → isAdjacentTo(Constants.freshWater)
        case "City center": return tile.isCityCenter   // Unciv matches the "City center" improvement every city tile carries
        default: break
        }
        if f == tile.baseTerrain { return true }
        if let r = tile.resource, f == r { return observing == nil || canSeeResource(r, civId: civId) }
        // Unciv allTerrains: base, natural wonder, features
        for name in [tile.baseTerrain] + (tile.naturalWonder.map { [$0] } ?? []) + tile.features {
            if let t = rs.terrains[name], t.matchesFilter(f, multiFilter: false) { return true }
        }
        if let owner = tile.ownerCivId, let oc = civ(owner), civMatches(oc, f, viewer: civId) { return true }   // Unciv: the owning civ may match the filter
        // 'luxury resource', 'strategic resource' and 'bonus resource' - only the visible ones
        guard let resource = tile.resource.flatMap({ rs.resources[$0] }) else { return false }
        let hasResourceWithFilter = resource.name == f || resource.uniqueObjects.contains { $0.pattern == f }
            || (f.hasSuffix(" resource") ? String(f.dropLast(9)) : f) == resource.resourceType
        if !hasResourceWithFilter { return false }
        if resource.revealedBy == nil { return true }
        if observing == nil { return true }
        return canSeeResource(resource.name, civId: civId)
    }

    /// Unciv Technology.matchesSingleFilter: the tech's own name, the name of its era, or an era filter.
    func techMatchesFilter(_ tech: String, _ filter: String) -> Bool {
        if filter == tech || filter == "All" || filter == "all" { return true }
        guard let era = rs.techs[tech]?.era else { return false }
        return eraMatchesFilter(era, filter)
    }

    /// Unciv Era.matchesSingleFilter: the name, "any era", the game's starting era, and pre-/post- by era number.
    func eraMatchesFilter(_ era: String, _ filter: String) -> Bool {
        if filter == era || filter == "any era" { return true }
        if filter == "Starting Era" { return era == (settings.startingEra.isEmpty ? rs.ancientEra.name : settings.startingEra) }
        func other(_ prefix: String) -> EraDef? {
            guard filter.hasPrefix(prefix), filter.hasSuffix("]") else { return nil }
            return rs.era(named: String(filter.dropFirst(prefix.count).dropLast()))
        }
        if let t = other("pre-[") { return rs.eraIndex(era) < rs.eraIndex(t.name) }
        if let t = other("post-[") { return rs.eraIndex(era) > rs.eraIndex(t.name) }
        return false
    }

    /// Unciv Technology.matchesFilter through TechManager.researchedTechnologies: a name, an era, or "all".
    func hasDiscovered(_ civ: Civilization, _ filter: String) -> Bool {
        if civ.techs.contains(filter) { return true }
        if filter == "All" || filter == "all" { return !civ.techs.isEmpty }
        return civ.techs.contains { rs.techs[$0]?.era == filter }
    }

    /// Unciv ConditionalAfterAdopting: a policy, or a belief our religion holds.
    func hasAdopted(_ civ: Civilization, _ name: String) -> Bool {
        civ.policies.contains(name) || civ.religionBeliefs.contains(name) || civ.pantheonBelief == name
    }

    /// Unciv TileImprovement.matchesSingleFilter
    func improvementMatches(_ name: String, _ filter: String) -> Bool {
        switch filter {
        case "all", "All", "Improvement": return true
        case "All Road": return name == "Road" || name == "Railroad"
        case "Great Improvement", "Great": return rs.improvements[name]?.isGreatImprovement ?? false
        default: return filter == name || filter == rs.improvements[name]?.replaces   // Unciv: filter == name || filter == replaces
        }
    }

    /// Unciv Tile.isFriendlyTerritory / DiplomacyManager.isConsideredFriendlyTerritory.
    func isFriendlyTerritory(_ tile: Tile, for civId: Int) -> Bool {
        guard let owner = tile.ownerCivId else { return false }
        if owner == civId { return true }
        guard let oc = civ(owner), civ(civId)?.metCivs.contains(owner) == true else { return false }
        if oc.isCityState, isFriend(civId, of: owner) || civUniques(civId).contains(where: { $0.pattern == "City-State territory always counts as friendly territory" }) { return true }
        return hasOpenBorders(civId, in: owner)
    }

    func hasFreshWater(_ tile: Tile) -> Bool {
        if tile.riverAdjacent { return true }   // Unciv isAdjacentTo: a river counts for the tile itself, a lake or oasis does not
        return map.neighbors(of: tile.coord).contains { n in
            guard let t = map[n] else { return false }
            return t.baseTerrain == "Lakes" || t.features.contains("Oasis")
        }
    }

    // MARK: production/availability helpers

    /// Unciv BaseUnit.matchesFilter / Building.matchesFilter for a construction (models/ruleset/unit/BaseUnit.swift,
    /// models/ruleset/Building.swift)
    func productionMatches(_ p: Production, _ filter: String) -> Bool {
        switch p {
        case .unit(let n): return rs.units[n].map { baseUnitMatchesFilter($0, filter) } ?? false
        case .building(let n): return rs.buildings[n].map { buildingMatchesFilter($0, filter) } ?? false
        }
    }

    /// Sum of "[]% <thing>" style modifiers on the civ, e.g. Golden Age length, policy cost, GP generation.
    func civPercent(_ civId: Int, pattern: String, city: City? = nil, filterParamIndex: Int? = nil, filterMatches: ((String) -> Bool)? = nil) -> Double {
        var pct = 0.0
        let ctx = UniqueContext(civId: civId, city: city)
        for u in (city.map { cityUniques($0) } ?? civUniques(civId)) where u.pattern == pattern {
            if let city, !scopeIncludes(u, city: city) { continue }
            guard conditionalsHold(u, ctx) else { continue }
            if let idx = filterParamIndex, let fm = filterMatches, !fm(u.param(idx)) { continue }
            pct += u.double(0)
        }
        return pct
    }
}

// MARK: - Continents (Unciv Tile.getContinent, for "on foreign continents")
extension GameState {
}
