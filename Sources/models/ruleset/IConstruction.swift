// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
enum Production: Codable, Equatable, Hashable {
    case unit(String)
    case building(String)

    var name: String {
        switch self { case .unit(let n), .building(let n): return n }
    }
    var isUnit: Bool { if case .unit = self { return true }; return false }
}


/// Unciv RejectionReason / RejectionReasonType: why a construction cannot be built in a city, and whether it is still listed.
struct ConstructionRejection: Equatable {
    let type: String
    let message: String
    static let defaultMessages: [String: String] = [
        "AlreadyBuilt": "Building already built in this city", "Unbuildable": "Unbuildable", "CanOnlyBePurchased": "Can only be purchased",
        "ShouldNotBeDisplayed": "Should not be displayed", "DisabledBySetting": "Disabled by setting",
        "HiddenWithoutVictory": "Hidden because a victory type has been disabled",
        "MustBeOnTile": "Must be on a specific tile", "MustNotBeOnTile": "Must not be on a specific tile", "MustBeNextToTile": "Must be next to a specific tile",
        "MustNotBeNextToTile": "Must not be next to a specific tile", "MustOwnTile": "Must own a specific tile close by",
        "WaterUnitsInCoastalCities": "May only built water units in coastal cities", "CanOnlyBeBuiltInSpecificCities": "Build requirements not met in this city",
        "MaxNumberBuildable": "Maximum number have been built or are being constructed",
        "UniqueToOtherNation": "Unique to another nation", "ReplacedByOurUnique": "Our unique replaces this", "CannotBeBuilt": "Cannot be built by this nation",
        "Obsoleted": "Obsolete", "RequiresTech": "Required tech not researched", "RequiresPolicy": "Requires a specific policy!",
        "MorePolicyBranches": "Hidden until more policy branches are fully adopted",
        "RequiresNearbyResource": "Requires a certain resource being exploited nearby",
        "CannotBeBuiltWith": "Cannot be built at the same time as another building already built",
        "RequiresBuildingInThisCity": "Requires a specific building in this city!", "RequiresBuildingInAllCities": "Requires a specific building in all cities!",
        "RequiresBuildingInSomeCities": "Requires a specific building in more cities!", "RequiresBuildingInSomeCity": "Requires a specific building anywhere in your empire!",
        "NoSuchImprovement": "No such improvement exists in the ruleset", "NoTileCanContainImprovement": "No tile can contain this improvement",
        "WonderAlreadyBuilt": "Wonder already built", "NationalWonderAlreadyBuilt": "National Wonder already built", "WonderBeingBuiltElsewhere": "Wonder is being built elsewhere",
        "CityStateWonder": "No Wonders for city-states", "PuppetWonder": "No Wonders for Puppets", "WonderDisabledEra": "This Wonder is disabled when starting in this era",
        "ConsumesResources": "Consumes resources which you are lacking", "PopulationRequirement": "Requires more population",
        "NoSettlerForOneCityPlayers": "No settlers for city-states or one-city challengers", "NoPlaceToPutUnit": "No space to place this unit",
    ]
    /// RejectionReasonType.shouldShow == true
    static let shownTypes: Set<String> = ["CanOnlyBePurchased", "RequiresBuildingInThisCity", "RequiresBuildingInAllCities", "RequiresBuildingInSomeCities",
                                          "RequiresBuildingInSomeCity", "WonderBeingBuiltElsewhere", "ConsumesResources", "PopulationRequirement", "NoPlaceToPutUnit"]
    /// RejectionReason.neverVisible
    static let neverVisibleTypes: Set<String> = ["AlreadyBuilt", "WonderAlreadyBuilt", "NationalWonderAlreadyBuilt", "DisabledBySetting", "UniqueToOtherNation",
                                                 "ReplacedByOurUnique", "Obsoleted", "WonderBeingBuiltElsewhere", "RequiresTech", "NoSettlerForOneCityPlayers", "WaterUnitsInCoastalCities"]
    /// RejectionReason.orderedImportantRejectionTypes
    static let orderedImportantTypes = ["ShouldNotBeDisplayed", "WonderBeingBuiltElsewhere", "RequiresBuildingInAllCities", "RequiresBuildingInThisCity",
                                        "RequiresBuildingInSomeCity", "RequiresBuildingInSomeCities", "CanOnlyBeBuiltInSpecificCities", "PopulationRequirement",
                                        "ConsumesResources", "CanOnlyBePurchased", "MaxNumberBuildable", "NoPlaceToPutUnit"]
    /// RejectionReason.reasonsToDefinitivelyRemoveFromQueue
    static let reasonsToDefinitivelyRemoveFromQueue: Set<String> = ["Obsoleted", "WonderAlreadyBuilt", "NationalWonderAlreadyBuilt", "CannotBeBuiltWith", "MaxNumberBuildable"]
    /// RejectionReason.techPolicyEraWonderRequirements
    static let techPolicyEraWonderRequirementTypes: Set<String> = ["Obsoleted", "RequiresTech", "RequiresPolicy", "MorePolicyBranches", "RequiresBuildingInSomeCity"]
    /// RejectionReason.constructionRejectionReasonType: the reasons that only bar *building* the thing (spawned / upgraded units pass)
    static let constructionRejectionTypes: Set<String> = ["Unbuildable", "CannotBeBuilt", "CanOnlyBeBuiltInSpecificCities"]

    var shouldShow: Bool { ConstructionRejection.shownTypes.contains(type) }
    var isNeverVisible: Bool { ConstructionRejection.neverVisibleTypes.contains(type) }
    var isImportant: Bool { ConstructionRejection.orderedImportantTypes.contains(type) }
    var precedence: Int { ConstructionRejection.orderedImportantTypes.firstIndex(of: type) ?? Int.max }
    var hasAReasonToBeRemovedFromQueue: Bool { ConstructionRejection.reasonsToDefinitivelyRemoveFromQueue.contains(type) }
    var techPolicyEraWonderRequirements: Bool { ConstructionRejection.techPolicyEraWonderRequirementTypes.contains(type) }
    var isConstructionRejection: Bool { ConstructionRejection.constructionRejectionTypes.contains(type) }
}

/// Unciv PurchaseReason
enum PurchaseReason {
    case allowed, invalid, unpurchasable, uniqueAllowed, other, otherAllowed, notAllowed
    var purchasable: Bool { self == .allowed || self == .uniqueAllowed || self == .otherAllowed }
}

extension GameState {
    // MARK: - resources (Unciv IConstruction / Building / BaseUnit)

    /// Unciv Building/BaseUnit.getResourceRequirementsPerTurn, in the Counter's (LinkedHashMap) order:
    /// `requiredResource` × 1 first, then every "Consumes [amount] [resource]" whose conditionals hold.
    func resourceRequirementsPerTurnOrdered(requiredResource: String?, uniques: [Unique], ctx: UniqueContext) -> [(String, Int)] {
        var out: [(String, Int)] = []
        func add(_ r: String, _ n: Int) {
            if let i = out.firstIndex(where: { $0.0 == r }) { out[i].1 += n } else { out.append((r, n)) }
        }
        if let r = requiredResource { add(r, 1) }
        for u in uniques where u.pattern == "Consumes [] []" && conditionalsHold(u, ctx) { add(u.param(1), u.int(0)) }
        return out
    }

    /// Unciv getResourceRequirementsPerTurn: requiredResource × 1 plus "Consumes [amount] [resource]"
    func resourceRequirementsPerTurn(requiredResource: String?, uniques: [Unique], ctx: UniqueContext) -> [String: Int] {
        var out: [String: Int] = [:]
        for (r, n) in resourceRequirementsPerTurnOrdered(requiredResource: requiredResource, uniques: uniques, ctx: ctx) { out[r, default: 0] += n }
        return out
    }

    /// Unciv INonPerpetualConstruction.getStockpiledResourceRequirements, in the Counter's order: "Costs [amount]
    /// [stockpiledResource]", × the speed modifier (in Float, truncated) when "(modified by game speed)".
    func stockpiledResourceRequirementsOrdered(_ uniques: [Unique], ctx: UniqueContext) -> [(String, Int)] {
        var out: [(String, Int)] = []
        for u in uniques where u.pattern == "Costs [] []" && conditionalsHold(u, ctx) {
            var amount = u.int(0)
            if u.conditionals.contains(where: { $0.pattern == "(modified by game speed)" }) { amount = Int(Float(amount) * Float(speed.modifier)) }
            if let i = out.firstIndex(where: { $0.0 == u.param(1) }) { out[i].1 += amount } else { out.append((u.param(1), amount)) }
        }
        return out
    }

    /// Unciv getStockpiledResourceRequirements: "Costs [amount] [stockpiledResource]", × game speed when "(modified by game speed)"
    func stockpiledResourceRequirements(_ uniques: [Unique], ctx: UniqueContext) -> [String: Int] {
        var out: [String: Int] = [:]
        for (r, n) in stockpiledResourceRequirementsOrdered(uniques, ctx: ctx) { out[r, default: 0] += n }
        return out
    }

    private func rejection(_ type: String, _ message: String? = nil) -> ConstructionRejection {
        ConstructionRejection(type: type, message: message ?? ConstructionRejection.defaultMessages[type] ?? type)
    }

    /// Unciv String.getNeedMoreAmountString: "Need [amount] more [resource]"
    private func needMoreAmount(_ resource: String, _ amount: Int) -> String { "Need [\(amount)] more [\(resource)]" }

    // MARK: - Unciv IHasUniques.isUnavailableBySettings

    /// Unciv IHasUniques.gameBasedConditionals
    static let gameBasedConditionals: Set<String> = [
        "when [] Victory is disabled", "when [] Victory is enabled", "on [] game speed", "on [] difficulty",
        "on [] difficulty or higher", "on [] difficulty or lower", "when religion is enabled", "when religion is disabled",
        "when espionage is enabled", "when espionage is disabled",
    ]

    /// `Conditionals.conditionalApplies(null, it, GameContext(gameInfo = gameInfo))` for a game-based conditional: it only
    /// reads the game's settings, so any civ serves as the context's owner.
    private func gameConditionalHolds(_ c: Unique) -> Bool {
        guard let anyCiv = civs.first?.id else { return false }
        return conditionalHolds(c, UniqueContext(civId: anyCiv))
    }

    /// Unciv IHasUniques.isUnavailableBySettings: an "Unavailable" unique with a game-based conditional that holds, or an
    /// "Only available" unique with a game-based conditional that does not.
    func isUnavailableBySettings(_ uniques: [Unique]) -> Bool {
        if uniques.contains(where: { u in u.pattern == "Unavailable" && u.conditionals.contains { GameState.gameBasedConditionals.contains($0.pattern) && gameConditionalHolds($0) } }) { return true }
        if uniques.contains(where: { u in u.pattern == "Only available" && u.conditionals.contains { GameState.gameBasedConditionals.contains($0.pattern) && !gameConditionalHolds($0) } }) { return true }
        return false
    }

    /// Unciv Building.isHiddenByStartingEra: a world wonder the starting era already made obsolete
    func isHiddenByStartingEra(_ b: BuildingDef) -> Bool {
        guard b.isWonder, let startingEra = rs.era(named: settings.startingEra) else { return false }
        return startingEra.startingObsoleteWonders.contains(b.name)
    }

    /// Unciv Building.isUnavailableBySettings (GameInfo.isUnavailableBySettingsCached)
    func isUnavailableBySettings(building b: BuildingDef) -> Bool {
        if isUnavailableBySettings(b.uniqueObjects) { return true }
        if !settings.nuclearWeaponsEnabled && b.uniqueObjects.contains(where: { $0.pattern == "Enables nuclear weapon" && conditionalsHold($0, UniqueContext(civId: -1)) }) { return true }
        return isHiddenByStartingEra(b)
    }

    /// Unciv BaseUnit.isUnavailableBySettings (GameInfo.isUnavailableBySettingsCached)
    func isUnavailableBySettings(unit u: UnitDef) -> Bool {
        isUnavailableBySettings(u.rulesetUniqueObjects) || (!settings.nuclearWeaponsEnabled && u.rulesetUniqueObjects.contains { $0.pattern == "Nuclear weapon of Strength []" })
    }

    // MARK: - construction state (Unciv CityConstructions / CivConstructions)

    /// Unciv CityConstructions.getWorkDone(name): the production banked under that name. The current construction's
    /// is held in productionStored here; the rest sit in inProgressConstructions, as in Unciv.
    func getWorkDone(_ name: String, in city: City) -> Int {
        if city.currentProduction?.name == name { return Int(city.productionStored) }
        return city.inProgressConstructions[name] ?? 0
    }

    /// Unciv CityConstructions.isBeingConstructedOrEnqueued: `constructionQueue.contains(name)`
    func isBeingConstructedOrEnqueued(_ name: String, in city: City) -> Bool {
        city.currentProduction?.name == name || city.productionQueue.contains { $0.name == name }
    }

    /// Unciv CivConstructions.countConstructedObjects: the spaceship's copies, plus one per city that has the building
    /// (or its equivalent) or has it in its queue - for a unit, every one the civ fields plus every queue it is in.
    func countConstructedObjects(_ p: Production, civId: Int) -> Int {
        let amountInSpaceShip = civ(civId)?.spaceshipParts[p.name] ?? 0
        // validateConstructions probes a city with its queue half rebuilt: that city counts as the probe, not as its stored self
        let probe = constructionProbe
        func cities(of civId: Int) -> [City] { self.cities(of: civId).map { $0.id == probe?.id ? probe! : $0 } }
        switch p {
        case .building(let n):
            return amountInSpaceShip + cities(of: civId).filter { containsBuildingOrEquivalent($0, n) || isBeingConstructedOrEnqueued(n, in: $0) }.count
        case .unit(let n):
            return amountInSpaceShip + units(of: civId).filter { $0.name == n }.count + cities(of: civId).filter { isBeingConstructedOrEnqueued(n, in: $0) }.count
        }
    }

    /// Unciv Tile.isAdjacentTo(terrainFilter): a river counts for "River" and "Fresh water", otherwise a neighbour must match.
    private func tileIsAdjacentTo(_ t: Tile, _ filter: String, civId: Int) -> Bool {
        if filter == "River" { return t.riverAdjacent }
        if filter == "Fresh water" && t.riverAdjacent { return true }
        if map.neighbors(of: t.coord).contains(where: { map[$0].map { tileMatches($0, filter, civId: civId) } ?? false }) { return true }
        // A neighbouring lake or oasis is fresh water through its terrain's own "Fresh water" unique
        return filter == "Fresh water" && hasFreshWater(t)
    }

    // MARK: - Unciv Building.getRejectionReasons

    /// Unciv Building.notMetRejections: every conditional of an "Only available" / "Can only be built" unique that does not hold
    private func buildingNotMetRejections(_ u: Unique, city: City, built: Bool) -> [ConstructionRejection] {
        let ctx = UniqueContext(civId: city.civId, city: city)
        let bySpeed = u.conditionals.contains { $0.pattern == "(modified by game speed)" }
        var out: [ConstructionRejection] = []
        let own = cities(of: city.civId)
        for c in u.conditionals {
            // We yield a rejection only when conditionals are NOT met
            if conditionalHolds(c, ctx, unique: u) { continue }
            switch c.pattern {
            case "if [] is constructed in at least [] of [] cities":   // ConditionalBuildingBuiltAmount
                let building = equivalentBuilding(city.civId, c.param(0)), amount = c.int(1), cityFilter = c.param(2)
                let numberOfCities = own.filter { containsBuildingOrEquivalent($0, building) && cityMatchesFilter(cityFilter, city: $0, viewer: city.civId) }.count
                if numberOfCities < amount {
                    out.append(rejection("RequiresBuildingInSomeCities", "Requires a [\(building)] in at least [\(amount)] of [\(cityFilter)] cities (\(numberOfCities)/\(numberOfCities))"))
                }
            case "if [] is constructed in all [] cities":   // ConditionalBuildingBuiltAll
                let building = equivalentBuilding(city.civId, c.param(0)), cityFilter = c.param(1)
                // Unciv's lambda reads `it.matchesFilter(cityFilter)` as a statement and discards it: only the
                // puppet and building test decide.
                if own.contains(where: { !$0.isPuppet && !containsBuildingOrEquivalent($0, building) }) {
                    out.append(rejection("RequiresBuildingInAllCities", "Requires a [\(building)] in all [\(cityFilter)] cities"))
                }
            default:
                out.append(built ? rejection("CanOnlyBeBuiltInSpecificCities", u.text) : rejection("ShouldNotBeDisplayed"))
            }
        }
        return out
    }

    /// Unciv Building.getRejectionReasons, in its order
    func buildingRejections(_ b: BuildingDef, city: City) -> [ConstructionRejection] {
        let umT = UIMeasure.start(); defer { UIMeasure.stop("buildingRejections", umT) }
        guard let civ = civ(city.civId), let cityCenter = map[city.coord] else { return [rejection("ShouldNotBeDisplayed")] }
        let stateForConditionals = UniqueContext(civId: city.civId, city: city)
        var out: [ConstructionRejection] = []

        if city.buildings.contains(b.name) { out.append(rejection("AlreadyBuilt")) }

        if isUnavailableBySettings(building: b) {
            // Repeat the starting era test isHiddenBySettings already did to change the RejectionReasonType
            out.append(rejection(isHiddenByStartingEra(b) ? "WonderDisabledEra" : "DisabledBySetting"))
        }

        for unique in b.uniqueObjects {
            // skip uniques that don't have conditionals apply, EXCEPT for "Only available" and "Can only be built",
            // since they trigger (reject) only if conditionals ARE NOT met
            if unique.pattern != "Only available" && unique.pattern != "Can only be built" && !conditionalsHold(unique, stateForConditionals) { continue }
            switch unique.pattern {
            case "Unbuildable": out.append(rejection("Unbuildable"))
            case "Only available": out += buildingNotMetRejections(unique, city: city, built: false)
            case "Can only be built": out += buildingNotMetRejections(unique, city: city, built: true)
            case "Unavailable": out.append(rejection("ShouldNotBeDisplayed"))
            case "Requires at least [] population":
                if unique.int(0) > city.population { out.append(rejection("PopulationRequirement", unique.text)) }
            case "Must be on []":
                if !tileMatches(cityCenter, unique.param(0), civId: city.civId) { out.append(rejection("MustBeOnTile", unique.text)) }
            case "Must not be on []":
                if tileMatches(cityCenter, unique.param(0), civId: city.civId) { out.append(rejection("MustNotBeOnTile", unique.text)) }
            case "Must be next to []":
                if !tileIsAdjacentTo(cityCenter, unique.param(0), civId: city.civId) && !tileMatches(cityCenter, unique.param(0), civId: city.civId) {
                    out.append(rejection("MustBeNextToTile", unique.text))
                }
            case "Must not be next to []":
                if map.tilesWithin(city.coord, radius: 1).contains(where: { map[$0].map { tileMatches($0, unique.param(0), civId: city.civId) } ?? false }) {
                    out.append(rejection("MustNotBeNextToTile", unique.text))
                }
            case "Must have an owned [] within [] tiles":
                if !map.tilesWithin(city.coord, radius: unique.int(1)).contains(where: { c in
                    guard let t = map[c] else { return false }
                    return tileMatches(t, unique.param(0), civId: city.civId) && t.ownerCivId == city.civId
                }) { out.append(rejection("MustOwnTile", unique.text)) }
            case "Obsolete with []":
                if civ.hasTech(unique.param(0)) { out.append(rejection("Obsoleted", unique.text)) }
            case "Limited to [] per Civilization":
                if countConstructedObjects(.building(b.name), civId: city.civId) >= unique.int(0) { out.append(rejection("MaxNumberBuildable")) }
            case "Spaceship part":   // To be replaced with `Only available <after [Apollo Project] has been build>`
                if !civUniques(city.civId).contains(where: { $0.pattern == "Enables construction of Spaceship parts" && conditionalsHold($0, UniqueContext(civId: city.civId)) }) {
                    out.append(rejection("RequiresBuildingInSomeCity", "Apollo project not built!"))
                }
            case "Creates a [] improvement on a specific tile":
                if rs.improvements[unique.param(0)] == nil {
                    out.append(rejection("NoSuchImprovement", "Unknown improvement: \(unique.param(0))"))
                } else if !city.tiles.contains(where: { !canBuildCreatedImprovement(city, $0, unique.param(0)) }) {
                    // Unciv: `city.getTiles().none { !it.improvementFunctions.canBuildImprovement(improvement, city.state) }`
                    // - it rejects only when EVERY city tile could take the improvement.
                    out.append(rejection("NoTileCanContainImprovement"))
                }
            default: break
            }
        }

        if let ut = b.uniqueTo, !civMatches(civ, ut, viewer: city.civId) { out.append(rejection("UniqueToOtherNation", "Unique to \(ut)")) }

        // civ.cache.uniqueBuildings: the buildings whose uniqueTo matches this civ
        if rs.buildings.values.contains(where: { o in o.replaces == b.name && o.uniqueTo.map { civMatches(civ, $0, viewer: city.civId) } == true }) {
            out.append(rejection("ReplacedByOurUnique"))
        }

        for requiredTech in requiredTechs(requiredTech: b.requiredTech, uniques: b.uniqueObjects) where !civ.hasTech(requiredTech) {
            out.append(rejection("RequiresTech", "\(requiredTech) not researched!"))
        }

        // All Wonders
        if b.isAnyWonder {
            if cities(of: city.civId).contains(where: { $0.id != city.id && isBeingConstructedOrEnqueued(b.name, in: $0) }) { out.append(rejection("WonderBeingBuiltElsewhere")) }
            if civ.isCityState { out.append(rejection("CityStateWonder")) }
            if city.isPuppet { out.append(rejection("PuppetWonder")) }
        }

        // World Wonders
        if b.isWonder && cities.contains(where: { $0.buildings.contains(b.name) }) { out.append(rejection("WonderAlreadyBuilt")) }

        // National Wonders
        if b.isNationalWonder && cities(of: city.civId).contains(where: { $0.buildings.contains(b.name) }) { out.append(rejection("NationalWonderAlreadyBuilt")) }

        if let req = b.requiredBuilding, !containsBuildingOrEquivalent(city, req) {
            out.append(rejection("RequiresBuildingInThisCity", "Requires a [\(equivalentBuilding(city.civId, req))] in this city"))
        }

        for (resourceName, requiredAmount) in resourceRequirementsPerTurnOrdered(requiredResource: b.requiredResource, uniques: b.uniqueObjects, ctx: stateForConditionals) {
            let availableAmount = availableResourceAmount(city, resourceName)
            if availableAmount < requiredAmount { out.append(rejection("ConsumesResources", needMoreAmount(resourceName, requiredAmount - availableAmount))) }
        }

        // If we've already paid the unit costs, we don't need to pay it again
        if getWorkDone(b.name, in: city) == 0 {
            for (resourceName, amount) in stockpiledResourceRequirementsOrdered(b.uniqueObjects, ctx: stateForConditionals) {
                let availableResources = availableResourceAmount(city, resourceName)
                if availableResources < amount { out.append(rejection("ConsumesResources", needMoreAmount(resourceName, amount - availableResources))) }
            }
        }

        if !b.requiredNearbyImprovedResources.isEmpty {
            // city.getWorkableTiles(): the tiles in work range that we own
            let containsResourceWithImprovement = map.tilesWithin(city.coord, radius: rs.constants.cityWorkRange).contains { c in
                guard let t = map[c], t.ownerCivId == city.civId, let r = t.resource, let resource = rs.resources[r] else { return false }
                // getUnpillagedTileImprovement(): the city centre carries Unciv's "City center" improvement
                let improvement: String
                if let imp = t.improvement { guard !t.pillaged else { return false }; improvement = imp }
                else if t.isCityCenter { improvement = "City center" }
                else { return false }
                return b.requiredNearbyImprovedResources.contains(r)
                    && (rs.resourceImprovements[r]?.contains(improvement) == true
                        || t.isCityCenter
                        || (rs.improvements[improvement]?.isGreatImprovement == true && resource.resourceType == "Strategic"))
            }
            if !containsResourceWithImprovement { out.append(rejection("RequiresNearbyResource", "Nearby \(b.requiredNearbyImprovedResources) required")) }
        }

        for unique in civUniques(city.civId) where unique.pattern == "Cannot build [] buildings" && conditionalsHold(unique, stateForConditionals)
            && buildingMatchesFilter(b, unique.param(0), stateForConditionals) {
            out.append(rejection("CannotBeBuilt"))
        }
        return out
    }

    /// Unciv `tile.improvementFunctions.canBuildImprovement(improvement, city.state)` for a CreatesOneImprovement
    /// building: ImprovementFunctions.getImprovementBuildingProblems(...).none(). Ours asked the UI's approximate
    /// Tile.buildableImprovements, which (among others) let a pillaged copy of the same improvement be rebuilt.
    func canBuildCreatedImprovement(_ city: City, _ c: HexCoord, _ improvement: String) -> Bool {
        guard let t = map[c], let def = rs.improvements[improvement] else { return false }
        return canBuildImprovement(def, on: t, civId: city.civId)
    }

    /// Unciv Building.isBuildable: `getRejectionReasons(cityConstructions).none()`
    func isBuildable(_ b: BuildingDef, city: City) -> Bool { buildingRejections(b, city: city).isEmpty }

    // MARK: - Unciv BaseUnit.getRejectionReasons

    /// Unciv BaseUnit.notMetRejections (the copy of Building.notMetRejections with a civ and an optional city)
    private func unitNotMetRejections(_ u: Unique, civId: Int, city: City?, built: Bool) -> [ConstructionRejection] {
        let ctx = UniqueContext(civId: civId, city: city)
        let bySpeed = u.conditionals.contains { $0.pattern == "(modified by game speed)" }
        var out: [ConstructionRejection] = []
        let own = cities(of: civId)
        for c in u.conditionals {
            if conditionalHolds(c, ctx, unique: u) { continue }
            switch c.pattern {
            case "if [] is constructed in at least [] of [] cities":
                let building = equivalentBuilding(civId, c.param(0)), amount = c.int(1), cityFilter = c.param(2)
                let numberOfCities = own.filter { containsBuildingOrEquivalent($0, building) && cityMatchesFilter(cityFilter, city: $0, viewer: civId) }.count
                if numberOfCities < amount {
                    out.append(rejection("RequiresBuildingInSomeCities", "Requires a [\(building)] in at least [\(amount)] cities (\(numberOfCities)/\(numberOfCities))"))
                }
            case "if [] is constructed in all [] cities":
                let building = equivalentBuilding(civId, c.param(0))
                if own.contains(where: { !$0.isPuppet && !containsBuildingOrEquivalent($0, building) }) {
                    out.append(rejection("RequiresBuildingInAllCities", "Requires a [\(building)] in all cities"))
                }
            default:
                out.append(built ? rejection("CanOnlyBeBuiltInSpecificCities", u.text) : rejection("ShouldNotBeDisplayed"))
            }
        }
        return out
    }

    /// Unciv BaseUnit.getRejectionReasons(cityConstructions)
    func unitRejections(_ u: UnitDef, city: City) -> [ConstructionRejection] { unitRejections(u, civId: city.civId, city: city) }

    /// Unciv BaseUnit.getRejectionReasons(civ, city?, additionalResources), in its order
    func unitRejections(_ u: UnitDef, civId: Int, city: City?, additionalResources: [String: Int] = [:]) -> [ConstructionRejection] {
        let umT = UIMeasure.start(); defer { UIMeasure.stop("unitRejections", umT) }
        guard let civ = civ(civId) else { return [rejection("ShouldNotBeDisplayed")] }
        let stateForConditionals = UniqueContext(civId: civId, city: city)
        let uniques = u.rulesetUniqueObjects
        var out: [ConstructionRejection] = []

        // city.isNaval(): the centre is water, or land next to a coast
        if let city, u.isWater, let center = map[city.coord] {
            let isNaval = center.isWater || map.isAdjacentToCoast(city.coord)   // Unciv City.isCoastal: centerTile.isAdjacentToCoast() (a lazy)
            if !isNaval { out.append(rejection("WaterUnitsInCoastalCities")) }
        }

        for unique in uniques where unique.pattern == "Only available" { out += unitNotMetRejections(unique, civId: civId, city: city, built: false) }
        for unique in uniques where unique.pattern == "Can only be built" { out += unitNotMetRejections(unique, civId: civId, city: city, built: true) }
        for unique in uniques where unique.pattern == "Unavailable" && conditionalsHold(unique, stateForConditionals) { out.append(rejection("ShouldNotBeDisplayed")) }

        if let city {
            // getMatchingUniques(RequiresPopulation) with no state: GameContext.EmptyState
            for unique in uniques where unique.pattern == "Requires at least [] population" && conditionalsHold(unique, UniqueContext(civId: -1)) {
                if unique.int(0) > city.population { out.append(rejection("PopulationRequirement", unique.text)) }
            }
        }

        for requiredTech in requiredTechs(requiredTech: u.requiredTech, uniques: uniques) where !civ.hasTech(requiredTech) {
            out.append(rejection("RequiresTech", "\(requiredTech) not researched"))
        }

        // techsAtWhichNoLongerAvailable
        if let obsoleteTech = u.obsoleteTech, civ.hasTech(obsoleteTech) { out.append(rejection("Obsoleted", "Obsolete by \(obsoleteTech)")) }

        if let ut = u.uniqueTo, !civMatches(civ, ut, viewer: civId) { out.append(rejection("UniqueToOtherNation", "Unique to \(ut)")) }
        // civ.cache.uniqueUnits: the units whose uniqueTo matches this civ
        if rs.units.values.contains(where: { o in o.replaces == u.name && o.uniqueTo.map { civMatches(civ, $0, viewer: civId) } == true }) {
            out.append(rejection("ReplacedByOurUnique", "Our unique unit replaces this"))
        }

        if isUnavailableBySettings(unit: u) { out.append(rejection("DisabledBySetting")) }

        if uniques.contains(where: { $0.pattern == "Unbuildable" && conditionalsHold($0, stateForConditionals) }) { out.append(rejection("Unbuildable")) }

        // civ.isOneCityChallenger(): a human player in a one-city-challenge game
        if (civ.isCityState || (civ.isPlayer && settings.oneCityChallenge)) && u.hasFoundCityUnique {
            out.append(rejection("NoSettlerForOneCityPlayers"))
        }

        if uniques.contains(where: { $0.pattern == "Limited to [] per Civilization" && conditionalsHold($0, stateForConditionals)
                && countConstructedObjects(.unit(u.name), civId: civId) >= $0.int(0) }) {
            out.append(rejection("MaxNumberBuildable"))
        }

        if !civ.isBarbarian {   // Barbarians don't need resources
            let civResources = resourceCounts(civId)
            for (resource, requiredAmount) in resourceRequirementsPerTurnOrdered(requiredResource: u.requiredResource, uniques: uniques, ctx: stateForConditionals) {
                let availableAmount = (civResources[resource] ?? 0) + (additionalResources[resource] ?? 0)
                if availableAmount < requiredAmount { out.append(rejection("ConsumesResources", needMoreAmount(resource, requiredAmount - availableAmount))) }
            }
            // If we've already paid the unit costs, we don't need to pay it again
            if city == nil || getWorkDone(u.name, in: city!) == 0 {
                for (resourceName, amount) in stockpiledResourceRequirementsOrdered(uniques, ctx: stateForConditionals) {
                    let availableResources = city.map { availableResourceAmount($0, resourceName) } ?? (civResources[resourceName] ?? 0)
                    if availableResources < amount { out.append(rejection("ConsumesResources", needMoreAmount(resourceName, amount - availableResources))) }
                }
            }
        }

        for unique in civUniques(civId) where unique.pattern == "Cannot build [] units" && conditionalsHold(unique, stateForConditionals)
            && baseUnitMatchesFilter(u, unique.param(0), stateForConditionals) {
            out.append(rejection("CannotBeBuilt"))
        }

        if let city, u.isAir, !canUnitEnterTile(u, city: city) {
            // Not actually added to civ so doesn't require destroy
            out.append(rejection("NoPlaceToPutUnit"))
        }
        return out
    }

    /// Unciv BaseUnit.canUnitEnterTile: a fresh unit of this kind could move onto the city centre
    func canUnitEnterTile(_ u: UnitDef, city: City) -> Bool {
        let fakeUnit = Unit(id: -1, civId: city.civId, name: u.name, coord: city.coord, movementLeft: 0)
        return canMoveTo(fakeUnit, city.coord)
    }

    /// Unciv BaseUnit.isBuildable(cityConstructions): `getRejectionReasons(cityConstructions).none()`
    func isBuildable(_ u: UnitDef, city: City) -> Bool { unitRejections(u, city: city).isEmpty }

    // MARK: - Unciv Building / BaseUnit.shouldBeDisplayed

    /// Unciv Building/BaseUnit.shouldBeDisplayed, returning the most important rejection when listed despite being unbuildable
    func displayedRejection(_ p: Production, city: City) -> ConstructionRejection? {
        let umT = UIMeasure.start(); defer { UIMeasure.stop("displayedRejection", umT) }
        let reasons: [ConstructionRejection]
        let uniques: [Unique]
        let ctx = UniqueContext(civId: city.civId, city: city)
        switch p {
        case .building(let n):
            guard let b = rs.buildings[n] else { return nil }
            if isBeingConstructedOrEnqueued(n, in: city) { return nil }
            // getMatchingUniques(MaxNumberBuildable): no state
            for unique in b.uniqueObjects where unique.pattern == "Limited to [] per Civilization" && conditionalsHold(unique, UniqueContext(civId: -1)) {
                if countConstructedObjects(p, civId: city.civId) >= unique.int(0) { return nil }
            }
            reasons = buildingRejections(b, city: city); uniques = b.uniqueObjects
            guard !reasons.isEmpty else { return nil }
            if uniques.contains(where: { $0.pattern == "Shown while unbuilable" && conditionalsHold($0, ctx) }) && !reasons.contains(where: { $0.isNeverVisible }) { return mostImportant(reasons) }
            // You will never be able to get more cities, this building is effectively disabled
            if reasons.contains(where: { $0.type == "RequiresBuildingInSomeCities" }) && settings.oneCityChallenge { return nil }
        case .unit(let n):
            guard let u = rs.units[n] else { return nil }
            reasons = unitRejections(u, city: city); uniques = u.rulesetUniqueObjects
            guard !reasons.isEmpty else { return nil }
            if uniques.contains(where: { $0.pattern == "Shown while unbuilable" && conditionalsHold($0, ctx) }) && !reasons.contains(where: { $0.isNeverVisible }) { return mostImportant(reasons) }
        }
        if !reasons.contains(where: { !$0.shouldShow }) { return mostImportant(reasons) }
        // Unciv `canBePurchasedWithAnyStat(city) && rejectionReasons.all { it.type == RejectionReasonType.Unbuildable }`, both
        // sides without side effects, asked the other way round: the purchase check walks the city's uniques for every
        // currency, and a construction the city screen lists is rarely rejected as Unbuildable alone
        if reasons.allSatisfy({ $0.type == "Unbuildable" }) && canBePurchasedWithAnyStat(p, city: city) { return mostImportant(reasons) }
        return nil
    }

    private func mostImportant(_ reasons: [ConstructionRejection]) -> ConstructionRejection {
        reasons.filter { $0.isImportant }.min { $0.precedence < $1.precedence } ?? ConstructionRejection(type: "Shown", message: "")
    }

    // MARK: - purchasing (Unciv INonPerpetualConstruction / Building / BaseUnit / BaseUnitCost)

    /// Unciv Speed.statCostModifiers[stat]
    func statCostModifier(_ stat: String) -> Float {
        switch stat {
        case "Production": return Float(speed.productionCostModifier)
        case "Gold": return Float(speed.goldCostModifier)
        case "Science": return Float(speed.scienceCostModifier)
        case "Faith": return Float(speed.faithCostModifier)
        case "Culture": return Float(speed.cultureCostModifier)
        default: return 1
        }
    }

    /// Unciv City.getMatchingUniques(type, city.state): the civ's uniques, then the city's local ones, conditionals applied.
    func cityMatchingUniques(_ city: City, _ pattern: String) -> [Unique] {
        let ctx = UniqueContext(civId: city.civId, city: city)
        let all = cityUniques(city)
        // cityUniques lists the city's local uniques first and appends the civ's non-local ones
        let civPart = min(all.count, civUniques(city.civId).filter { !$0.isLocalEffect }.count)
        let ordered = Array(all.suffix(civPart)) + Array(all.prefix(all.count - civPart))
        return ordered.filter { $0.pattern == pattern && conditionalsHold($0, ctx) }
    }

    private func constructionUniques(_ p: Production) -> [Unique] {
        switch p {
        case .building(let n): return rs.buildings[n]?.uniqueObjects ?? []
        case .unit(let n): return rs.units[n]?.rulesetUniqueObjects ?? []
        }
    }

    private func constructionMatchesFilter(_ p: Production, _ filter: String, _ ctx: UniqueContext) -> Bool {
        switch p {
        case .building(let n): return rs.buildings[n].map { buildingMatchesFilter($0, filter, ctx) } ?? false
        case .unit(let n): return rs.units[n].map { baseUnitMatchesFilter($0, filter, ctx) } ?? false
        }
    }

    /// Unciv INonPerpetualConstruction.canBePurchasedWithStatReasons: only whether it has the unique to be bought with
    /// this stat, not whether it is purchasable at all.
    func canBePurchasedWithStatReasons(_ p: Production, city: City?, stat: String) -> PurchaseReason {
        let ctx = city.map { UniqueContext(civId: $0.civId, city: $0) } ?? UniqueContext(civId: -1)
        let uniques = constructionUniques(p)
        if stat == "Production" || stat == "Happiness" { return .invalid }
        if uniques.contains(where: { $0.pattern == "Cannot be purchased" && conditionalsHold($0, ctx) }) { return .unpurchasable }
        // Can be purchased with [Stat] [cityFilter]
        if uniques.contains(where: { u in u.pattern == "Can be purchased with [] []" && u.param(0) == stat
            && (city == nil || (conditionalsHold(u, ctx) && cityMatchesFilter(u.param(1), city: city!, viewer: city!.civId))) }) { return .uniqueAllowed }
        // Can be purchased for [amount] [Stat] [cityFilter]
        if uniques.contains(where: { u in u.pattern == "Can be purchased for [] [] []" && u.param(1) == stat
            && (city == nil || (conditionalsHold(u, ctx) && cityMatchesFilter(u.param(2), city: city!, viewer: city!.civId))) }) { return .uniqueAllowed }
        if stat == "Gold" && !uniques.contains(where: { $0.pattern == "Unbuildable" && conditionalsHold($0, ctx) }) { return .allowed }
        return .notAllowed
    }

    /// Unciv Building.canBePurchasedWithStat / BaseUnit.canBePurchasedWithStat
    func canBePurchasedWithStat(_ p: Production, city: City?, stat: String) -> Bool {
        switch p {
        case .building(let n):
            guard let b = rs.buildings[n] else { return false }
            let purchaseReason = canBePurchasedWithStatReasons(p, city: nil, stat: stat)
            if purchaseReason != .uniqueAllowed && stat == "Gold" && b.isAnyWonder { return false }
            guard let city else { return purchaseReason.purchasable }
            let ctx = UniqueContext(civId: city.civId, city: city)
            func inCity(_ f: String) -> Bool { cityMatchesFilter(f, city: city, viewer: city.civId) }
            return cityMatchingUniques(city, "May buy [] buildings for [] [] [] at an increasing price ([])").contains { $0.param(2) == stat && buildingMatchesFilter(b, $0.param(0), ctx) && inCity($0.param(3)) }
                || cityMatchingUniques(city, "May buy [] buildings with [] for [] times their normal Production cost").contains { $0.param(1) == stat && buildingMatchesFilter(b, $0.param(0), ctx) }
                || cityMatchingUniques(city, "May buy [] buildings with [] []").contains { $0.param(1) == stat && buildingMatchesFilter(b, $0.param(0), ctx) && inCity($0.param(2)) }
                || cityMatchingUniques(city, "May buy [] buildings for [] [] []").contains { $0.param(2) == stat && buildingMatchesFilter(b, $0.param(0), ctx) && inCity($0.param(3)) }
                || canBePurchasedWithStatReasons(p, city: city, stat: stat).purchasable
        case .unit(let n):
            guard let u = rs.units[n] else { return false }
            guard let city else { return canBePurchasedWithStatReasons(p, city: nil, stat: stat).purchasable }
            if u.rulesetUniqueObjects.contains(where: { $0.pattern == "Cannot be purchased" && conditionalsHold($0, UniqueContext(civId: -1)) }) { return false }
            if unitRejections(u, city: city).contains(where: { $0.type != "Unbuildable" }) { return false }
            if unitCostCanBePurchasedWithStat(u, city: city, stat: stat) { return true }
            return canBePurchasedWithStatReasons(p, city: city, stat: stat).purchasable
        }
    }

    /// Unciv BaseUnitCost.canBePurchasedWithStat: only the unit-specific "May buy" uniques
    private func unitCostCanBePurchasedWithStat(_ u: UnitDef, city: City, stat: String) -> Bool {
        let ctx = UniqueContext(civId: city.civId, city: city)
        func inCity(_ f: String) -> Bool { cityMatchesFilter(f, city: city, viewer: city.civId) }
        if cityMatchingUniques(city, "May buy [] units for [] [] [] at an increasing price ([])").contains(where: { $0.param(2) == stat && baseUnitMatchesFilter(u, $0.param(0), ctx) && inCity($0.param(3)) }) { return true }
        if cityMatchingUniques(city, "May buy [] units with [] for [] times their normal Production cost").contains(where: { $0.param(1) == stat && baseUnitMatchesFilter(u, $0.param(0), ctx) }) { return true }
        if cityMatchingUniques(city, "May buy [] units with [] []").contains(where: { $0.param(1) == stat && baseUnitMatchesFilter(u, $0.param(0), ctx) && inCity($0.param(2)) }) { return true }
        if cityMatchingUniques(city, "May buy [] units for [] [] []").contains(where: { $0.param(2) == stat && baseUnitMatchesFilter(u, $0.param(0), ctx) && inCity($0.param(3)) }) { return true }
        return false
    }

    /// Unciv INonPerpetualConstruction.isPurchasable: every rejection reason is "Unbuildable"
    func isPurchasable(_ p: Production, city: City) -> Bool {
        switch p {
        case .building(let n): return rs.buildings[n].map { buildingRejections($0, city: city).allSatisfy { $0.type == "Unbuildable" } } ?? false
        case .unit(let n): return rs.units[n].map { unitRejections($0, city: city).allSatisfy { $0.type == "Unbuildable" } } ?? false
        }
    }

    /// Unciv INonPerpetualConstruction.canBePurchasedWithAnyStat: Stat.statsUsableToBuy (Gold, Food, Science, Culture, Faith)
    func canBePurchasedWithAnyStat(_ p: Production, city: City) -> Bool {
        (["Gold"] + GameState.statsUsableToBuy).contains { canBePurchasedWithStat(p, city: city, stat: $0) }
    }

    /// Unciv INonPerpetualConstruction.getCostForConstructionsIncreasingInPrice: `(baseCost + increaseCost / 2f * (n² + n)).toInt()`
    func costForConstructionsIncreasingInPrice(baseCost: Int, increaseCost: Int, previouslyBought: Int) -> Int {
        Int(Float(baseCost) + Float(increaseCost) / 2 * Float(previouslyBought * previouslyBought + previouslyBought))
    }

    /// Unciv INonPerpetualConstruction.getBaseGoldCost: `(30.0 * productionCost).pow(0.75) * hurryCostModifier.toPercent()`
    func getBaseGoldCost(_ p: Production, civId: Int, city: City?) -> Double {
        let hurry: Int
        switch p {
        case .building(let n): hurry = rs.buildings[n]?.hurryCostModifier ?? 0
        case .unit(let n): hurry = rs.units[n]?.hurryCostModifier ?? 0
        }
        return pow(30.0 * Double(productionCost(p, for: civId, city: city)), 0.75) * Stats.toPercent(Double(hurry))
    }

    /// Unciv BaseUnit.getDisbandGold: `getBaseGoldCost(civInfo, null).toInt() / 20`
    /// A unit without a cost (-1) has a negative production cost, whose 0.75th power is NaN - and Kotlin's
    /// `NaN.toInt()` is 0.
    func disbandGold(_ u: UnitDef, civId: Int) -> Int {
        let g = getBaseGoldCost(.unit(u.name), civId: civId, city: nil)
        return GameState.kotlinToInt(g) / 20
    }

    private func eraBaseUnitBuyCost(_ civId: Int) -> Int { rs.era(named: civ(civId)?.eraName ?? "")?.baseUnitBuyCost ?? 200 }

    /// Unciv civConstructions.boughtItemsWithIncreasingPrice[name] (a Counter: 0 when absent). A save from before the
    /// counter kept the prophets as prophetsEarned, which ReligionManager reads the same way.
    private func boughtItemsWithIncreasingPrice(_ name: String, civId: Int) -> Int {
        guard let c = civ(civId) else { return 0 }
        if let n = c.boughtWithIncreasingPrice[name] { return n }
        return rs.units[name]?.canFoundReligion == true ? c.prophetsEarned : 0
    }

    /// Unciv INonPerpetualConstruction.getBaseBuyCost (the default, after any specific cost)
    private func defaultBaseBuyCost(_ p: Production, city: City, stat: String) -> Double? {
        let uniques = constructionUniques(p)
        let ctx = UniqueContext(civId: city.civId, city: city)
        // Can be purchased for [amount] [Stat] [cityFilter]
        let lowestCostUnique = uniques.filter { $0.pattern == "Can be purchased for [] [] []" && conditionalsHold($0, ctx) && $0.param(1) == stat && cityMatchesFilter($0.param(2), city: city, viewer: city.civId) }
            .min { $0.int(0) < $1.int(0) }   // minByOrNull keeps the first lowest
        if let lowestCostUnique { return Double(Float(lowestCostUnique.int(0)) * statCostModifier(stat)) }
        if stat == "Gold" { return Double(Float(getBaseGoldCost(p, civId: city.civId, city: city))) }
        // Can be purchased with [Stat] [cityFilter]
        if uniques.contains(where: { $0.pattern == "Can be purchased with [] []" && conditionalsHold($0, ctx) && $0.param(0) == stat && cityMatchesFilter($0.param(1), city: city, viewer: city.civId) }) {
            return Double(Float(eraBaseUnitBuyCost(city.civId)) * statCostModifier(stat))
        }
        return nil
    }

    /// Unciv Building.getBaseBuyCost / BaseUnit.getBaseBuyCost: the lowest specific cost, else the default one. Float.
    func getBaseBuyCost(_ p: Production, city: City, stat: String) -> Double? {
        let ctx = UniqueContext(civId: city.civId, city: city)
        let mod = statCostModifier(stat)
        func inCity(_ f: String) -> Bool { cityMatchesFilter(f, city: city, viewer: city.civId) }
        var specific: [Float] = []
        switch p {
        case .building(let n):
            guard let b = rs.buildings[n] else { return nil }
            // Building.getSpecificBuyCost
            for u in cityMatchingUniques(city, "May buy [] buildings for [] [] [] at an increasing price ([])") where u.param(2) == stat && buildingMatchesFilter(b, u.param(0), ctx) && inCity(u.param(3)) {
                specific.append(Float(costForConstructionsIncreasingInPrice(baseCost: u.int(1), increaseCost: u.int(4), previouslyBought: boughtItemsWithIncreasingPrice(n, civId: city.civId))) * mod)
            }
            for u in cityMatchingUniques(city, "May buy [] buildings with [] for [] times their normal Production cost") where u.param(1) == stat && buildingMatchesFilter(b, u.param(0), ctx) {
                specific.append(Float(productionCost(p, for: city.civId, city: city) * u.int(2)))
            }
            if cityMatchingUniques(city, "May buy [] buildings with [] []").contains(where: { $0.param(1) == stat && buildingMatchesFilter(b, $0.param(0), ctx) && inCity($0.param(2)) }) {
                specific.append(Float(eraBaseUnitBuyCost(city.civId)) * mod)
            }
            for u in cityMatchingUniques(city, "May buy [] buildings for [] [] []") where u.param(2) == stat && buildingMatchesFilter(b, u.param(0), ctx) && inCity(u.param(3)) {
                specific.append(Float(u.int(1)) * mod)
            }
        case .unit(let n):
            guard let unit = rs.units[n] else { return nil }
            // BaseUnitCost.getBaseBuyCosts
            for u in cityMatchingUniques(city, "May buy [] units for [] [] [] at an increasing price ([])") where u.param(2) == stat && baseUnitMatchesFilter(unit, u.param(0), ctx) && inCity(u.param(3)) {
                specific.append(Float(costForConstructionsIncreasingInPrice(baseCost: u.int(1), increaseCost: u.int(4), previouslyBought: boughtItemsWithIncreasingPrice(n, civId: city.civId))) * mod)
            }
            for u in cityMatchingUniques(city, "May buy [] units with [] for [] times their normal Production cost") where u.param(1) == stat && baseUnitMatchesFilter(unit, u.param(0), ctx) {
                specific.append(Float(productionCost(p, for: city.civId, city: city) * u.int(2)))
            }
            if cityMatchingUniques(city, "May buy [] units with [] []").contains(where: { $0.param(1) == stat && baseUnitMatchesFilter(unit, $0.param(0), ctx) && inCity($0.param(2)) }) {
                specific.append(Float(eraBaseUnitBuyCost(city.civId)) * mod)
            }
            for u in cityMatchingUniques(city, "May buy [] units for [] [] []") where u.param(2) == stat && baseUnitMatchesFilter(unit, u.param(0), ctx) && inCity(u.param(3)) {
                specific.append(Float(u.int(1)) * mod)
            }
        }
        if let lowest = specific.min() { return Double(lowest) }
        return defaultBaseBuyCost(p, city: city, stat: stat)
    }

    /// Unciv Building.getStatBuyCost / BaseUnitCost.getStatBuyCost: the base cost, the discounts (a building takes the
    /// general one first, a unit its own first), then rounded down to a multiple of 10.
    func getStatBuyCost(_ p: Production, city: City, stat: String) -> Int? {
        guard var cost = getBaseBuyCost(p, city: city, stat: stat) else { return nil }
        let ctx = UniqueContext(civId: city.civId, city: city)
        let itemsDiscount = cityMatchingUniques(city, "[] cost of purchasing items in cities []%").filter { $0.param(0) == stat }
        switch p {
        case .building:
            for u in itemsDiscount { cost *= Stats.toPercent(u.double(1)) }
            for u in cityMatchingUniques(city, "[] cost of purchasing [] buildings []%") where u.param(0) == stat && constructionMatchesFilter(p, u.param(1), ctx) {
                cost *= Stats.toPercent(u.double(2))
            }
        case .unit:
            for u in cityMatchingUniques(city, "[] cost of purchasing [] units []%") where u.param(0) == stat && constructionMatchesFilter(p, u.param(1), ctx) {
                cost *= Stats.toPercent(u.double(2))
            }
            for u in itemsDiscount { cost *= Stats.toPercent(u.double(1)) }
        }
        return GameState.kotlinToInt(cost / 10) * 10
    }

    /// Kotlin Double.toInt(): truncation toward zero, NaN is 0, out-of-range values clamp.
    static func kotlinToInt(_ d: Double) -> Int {
        if d.isNaN { return 0 }
        if d >= Double(Int32.max) { return Int(Int32.max) }
        if d <= Double(Int32.min) { return Int(Int32.min) }
        return Int(d)
    }

    /// Unciv CityConstructions.isConstructionPurchaseAllowed without the reserve test: puppets (without the unique),
    /// resistance, `isPurchasable`, room for a unit on the centre, and `canBePurchasedWithStat`.
    func isConstructionPurchaseAllowed(_ p: Production, city: City, stat: String) -> Bool {
        if city.isPuppet && cityMatchingUniques(city, "May buy items in puppet cities").isEmpty { return false }
        if city.resistanceTurns > 0 { return false }
        if !isPurchasable(p, city: city) { return false }
        if case .unit(let n) = p, let u = rs.units[n], !canPlaceNewUnit(u, city: city) { return false }
        return canBePurchasedWithStat(p, city: city, stat: stat)
    }

    /// Unciv CityConstructions.isConstructionPurchaseBlockedByUnit, word for word: not a puppet, no "May buy items in puppet
    /// cities", not in resistance, purchasable, a unit, and no room for a new unit in the centre
    func isConstructionPurchaseBlockedByUnit(_ p: Production, city: City) -> Bool {
        guard case .unit(let n) = p, let u = rs.units[n] else { return false }
        return !city.isPuppet && cityMatchingUniques(city, "May buy items in puppet cities").isEmpty && city.resistanceTurns == 0
            && isPurchasable(p, city: city) && !canPlaceNewUnit(u, city: city)
    }

    /// Unciv City.canPlaceNewUnit: a civilian needs the centre's civilian slot, an air unit is judged by its own
    /// rejection reasons, anything else needs the military slot.
    func canPlaceNewUnit(_ u: UnitDef, city: City) -> Bool {
        let onTile = units(at: city.coord)
        if !u.isMilitaryUnit { return !onTile.contains { !$0.def.isAir && $0.isCivilian } }
        if u.isAir { return true }
        return !onTile.contains { !$0.def.isAir && $0.isMilitary }
    }
}

extension ObjectDescriptions {
    /// Unciv getCivilopediaGoldCost: `((30.0 * cost.toFloat()).pow(0.75) * hurryCostModifier.toPercent() / 10).toInt() * 10`
    static func civilopediaGoldCost(cost: Int, hurryCostModifier: Int) -> Int {
        Int(pow(30.0 * Double(Float(cost)), 0.75) * Stats.toPercent(Double(hurryCostModifier)) / 10) * 10
    }
}
