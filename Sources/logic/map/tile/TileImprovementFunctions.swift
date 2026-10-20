// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv ImprovementBuildingProblem: why an improvement cannot be built by a given civ.
enum ImprovementBuildingProblem: Equatable {
    case replaced, wrongCiv, missingTech, unbuildable, conditionallyUnbuildable, notJustOutsideBorders, outsideBorders,
         unmetConditional, obsolete, missingResources, other
    /// Unciv: `true` if this cannot change in the future of this game
    var permanent: Bool { [.replaced, .wrongCiv, .unbuildable, .obsolete].contains(self) }
    /// Unciv: `true` if the ImprovementPicker should report this problem
    var reportable: Bool { [.missingTech, .notJustOutsideBorders, .outsideBorders, .missingResources].contains(self) }
}

/// Mirror of Unciv `logic/map/tile/TileImprovementFunctions.kt` (with `ImprovementFunctions.kt` and the
/// improvement-changing half of `Tile.kt`: removeImprovement, setRoadStatus, setPillaged, setRepaired,
/// doWorkerTurn and the improvement queue).
///
/// Our tile carries Unciv's two-entry use of `improvementQueue` as `improvementInProgress` + `queuedImprovement`,
/// and the CreatesOneImprovement marker as the claiming city's `reservedImprovementTile`.
extension GameState {
    // MARK: - the improvement queue

    /// Unciv Tile.improvementQueue, first entry first.
    func improvementQueue(_ t: Tile) -> [(improvement: String, turns: Int)] {
        var q: [(improvement: String, turns: Int)] = []
        if let a = t.improvementInProgress { q.append((a, t.improvementTurnsLeft)) }
        if let b = t.queuedImprovement { q.append((b, t.queuedImprovementTurns)) }
        return q
    }

    static func setImprovementQueue(_ t: inout Tile, _ q: [(improvement: String, turns: Int)]) {
        t.improvementInProgress = q.first?.improvement
        t.improvementTurnsLeft = q.first?.turns ?? 0
        t.queuedImprovement = q.count > 1 ? q[1].improvement : nil
        t.queuedImprovementTurns = q.count > 1 ? q[1].turns : 0
    }

    /// Unciv Tile.isMarkedForCreatesOneImprovement(): a "Creates a [] improvement on a specific tile" construction claimed it.
    func isMarkedForCreatesOneImprovement(_ c: HexCoord, _ improvement: String? = nil) -> Bool {
        cities.contains { $0.reservedImprovementTile == c && (improvement == nil || $0.reservedImprovement == improvement) }
    }

    // MARK: - canBuildImprovement

    /// Unciv TileImprovementFunctions.canBuildImprovement → ImprovementFunctions.getImprovementBuildingProblems.none()
    func canBuildImprovement(_ improvement: ImprovementDef, on tile: Tile, civId: Int, unit: Unit? = nil) -> Bool {
        improvementBuildingProblems(improvement, civId: civId, tile: tile, unit: unit).isEmpty
    }

    /// Unciv ImprovementFunctions.getImprovementBuildingProblems, every problem in its order (Unciv yields them lazily;
    /// the callers only ask `none()` / `any { permanent }`, which the full list answers the same).
    func improvementBuildingProblems(_ improvement: ImprovementDef, civId: Int?, tile: Tile? = nil, unit: Unit? = nil) -> [ImprovementBuildingProblem] {
        guard let civId, let civ = civ(civId) else { return [.wrongCiv] }
        var out: [ImprovementBuildingProblem] = []
        let ctx = UniqueContext(civId: civId, unit: unit, tile: tile)
        if let to = improvement.uniqueTo, !(to == civ.nation || civMatches(civ, to, viewer: civId)) { out.append(.wrongCiv) }
        // Unciv civInfo.cache.uniqueImprovements: this civ's own improvements, which replace the generic ones
        if rs.improvementOrder.contains(where: { name in
            guard let d = rs.improvements[name], let to = d.uniqueTo, to == civ.nation || civMatches(civ, to, viewer: civId) else { return false }
            return d.replaces == improvement.name
        }) { out.append(.replaced) }
        if let tech = improvement.techRequired, !civ.techs.contains(tech) { out.append(.missingTech) }
        let unbuildable = improvement.uniqueObjects.filter { $0.pattern == "Unbuildable" }
        if unbuildable.contains(where: { $0.conditionals.isEmpty }) { out.append(.unbuildable) }
        else if unbuildable.contains(where: { conditionalsHold($0, ctx) }) { out.append(.conditionallyUnbuildable) }
        if improvement.uniqueObjects.contains(where: { $0.pattern == "Unavailable" && conditionalsHold($0, ctx) }) { out.append(.conditionallyUnbuildable) }
        if improvement.uniqueObjects.contains(where: { $0.pattern == "Only available" && !conditionalsHold($0, ctx) }) { out.append(.unmetConditional) }
        if improvement.uniqueObjects.contains(where: { $0.pattern == "Obsolete with []" && conditionalsHold($0, ctx) && civ.techs.contains($0.param(0)) }) { out.append(.obsolete) }
        let counts = resourceCounts(civId)
        if improvement.uniqueObjects.contains(where: { $0.pattern == "Consumes [] []" && conditionalsHold($0, ctx) && (counts[$0.param(1)] ?? 0) < $0.int(0) }) { out.append(.missingResources) }
        if stockpiledResourceRequirements(improvement.uniqueObjects, ctx: ctx).contains(where: { (counts[$0.key] ?? 0) < $0.value }) { out.append(.missingResources) }
        if let tile {
            let outside = improvement.uniqueObjects.contains { $0.pattern == "Can be built outside your borders" && conditionalsHold($0, ctx) }
            let justOutside = improvement.uniqueObjects.contains { $0.pattern == "Can be built just outside your borders" && conditionalsHold($0, ctx) }
            if tile.ownerCivId != civId && !outside
                && (!justOutside || !map.neighbors(of: tile.coord).contains(where: { map[$0]?.ownerCivId == civId })) {
                out.append(.outsideBorders)
            }
            // knownFeatureRemovals: Unciv ruleset.nonRoadTileRemovals the civ has the technology for - built only
            // when an unbuildable top terrain asks for it (it is the same list whenever it is built)
            if !canImprovementBeBuiltHere(tile, improvement, resourceIsVisible: canSeeResource(tile.resource, civId: civId),
                                          knownFeatureRemovalsOf: civId, civId: civId, unit: unit) {
                out.append(.other)
            }
        }
        return out
    }

    /// Unciv TileImprovementFunctions.canImprovementBeBuiltHere: without regard to which civ builds it (no tech check),
    /// what the improvement asks of this tile - branch by branch, in Unciv's order.
    func canImprovementBeBuiltHere(_ tile: Tile, _ improvement: ImprovementDef, resourceIsVisible: Bool? = nil,
                                   knownFeatureRemovals: [ImprovementDef]? = nil, knownFeatureRemovalsOf removalsCiv: Int? = nil,
                                   civId: Int? = nil, unit: Unit? = nil, isNormalizeCheck: Bool = false,
                                   ignoreConditionals: Bool = false) -> Bool {
        let resourceIsVisible = resourceIsVisible ?? (tile.resource != nil)
        let observer = civId ?? -1
        let ctx = UniqueContext(civId: observer, unit: unit, tile: tile)
        /// Unciv `hasUnique(type, gameContext)` / `getMatchingUniques(type, gameContext)`: with GameContext.IgnoreConditionals
        /// (MapGenerator.spreadAncientRuins' isPlaceable) every unique counts whatever its conditionals say.
        func holds(_ u: Unique) -> Bool { ignoreConditionals || conditionalsHold(u, ctx) }
        let lastTerrain = lastTerrainOf(tile)
        let resource = tile.resource.flatMap { rs.resources[$0] }
        func isImprovedByResource(_ name: String) -> Bool { tile.resource.map { rs.resourceImprovements[$0]?.contains(name) ?? false } ?? false }

        /// Unciv canBeBuiltOnThisUnbuildableTerrain
        func canBeBuiltOnThisUnbuildableTerrain() -> Bool {
            guard let top = lastTerrain else { return false }
            if improvement.isAllowedOnFeature(top) { return true }
            // Otherwise, we can if this improvement removes the top terrain
            guard improvement.uniqueObjects.contains(where: { $0.pattern == "Removes removable features when built" && holds($0) }) else { return false }
            guard let known = knownFeatureRemovals ?? removalsCiv.map({ knownNonRoadTileRemovals(civId: $0) }), !known.isEmpty else { return false }
            let featureRemovals = tile.features.compactMap { f in rs.improvements["Remove " + f] }
            if featureRemovals.isEmpty { return false }
            if featureRemovals.contains(where: { r in !known.contains { $0.name == r.name } }) { return false }
            var cloned = tile
            cloned.features = tile.features.filter { f in !featureRemovals.contains { String($0.name.dropFirst(7)) == f } }
            return canImprovementBeBuiltHere(cloned, improvement, resourceIsVisible: resourceIsVisible, knownFeatureRemovals: known, civId: civId, unit: unit, ignoreConditionals: ignoreConditionals)
        }

        if improvement.name == tile.improvement && !isNormalizeCheck { return false }
        if tile.isCityCenter { return isNormalizeCheck && improvement.name == "City center" }
        // First we handle a few special improvements
        if improvement.name == "Cancel improvement order" { return tile.improvementInProgress != nil }
        if improvement.name == "Remove Road" || improvement.name == "Remove Railroad" {
            let removeAction: String? = !(tile.roads || tile.railroad) ? nil : tile.railroad ? "Remove Railroad" : "Remove Road"
            return removeAction == improvement.name
        }
        if improvement.name.hasPrefix("Remove ") {
            return tile.features.contains { "Remove " + $0 == improvement.name } || tile.improvement.map { "Remove " + $0 } == improvement.name
        }
        if improvement.name == "Road" || improvement.name == "Railroad" {
            let level = tile.railroad ? 2 : tile.roads ? 1 : 0
            return !tile.isWater && (improvement.name == "Railroad" ? 2 : 1) > level
        }
        // Then we check if there is any reason to not allow this improvement to be built
        if let cur = tile.improvement.flatMap({ rs.improvements[$0] }), cur.uniqueObjects.contains(where: { $0.pattern == "Irremovable" && holds($0) }) { return false }
        if lastTerrain?.unbuildable == true && !canBeBuiltOnThisUnbuildableTerrain() { return false }
        // "Only [] improvements may be built on this tile" on any terrain of the tile
        let restricted = allTerrainsOf(tile).flatMap { $0.uniqueObjects }.filter { $0.pattern == "Only [] improvements may be built on this tile" && holds($0) }
        if !restricted.isEmpty && !restricted.contains(where: { improvement.matchesFilter($0.param(0)) }) { return false }
        if improvement.uniqueObjects.contains(where: { $0.pattern == "Cannot be built on [] tiles" && holds($0) && tileMatches(tile, $0.param(0), civId: observer) }) { return false }
        let canOnly = improvement.uniqueObjects.filter { $0.pattern == "Can only be built on [] tiles" && holds($0) }
        if !canOnly.isEmpty && canOnly.contains(where: { !tileMatches(tile, $0.param(0), civId: observer) }) { return false }
        if improvement.uniqueObjects.contains(where: { $0.pattern == "Must be next to []" && holds($0) && !isAdjacentTo(tile, $0.param(0), civId: civId) }) { return false }
        if improvement.uniqueObjects.contains(where: { $0.pattern == "Can only be built to improve a resource" && holds($0) })
            && (!resourceIsVisible || !isImprovedByResource(improvement.name)) { return false }
        // At this point we know this is a normal improvement and that there is no reason not to allow it to be built.
        // Lastly we check if the improvement may be built on this terrain or resource
        if let top = lastTerrain, improvement.isAllowedOnFeature(top) { return true }
        if tile.isLand && improvement.canBeBuiltOn("Land") { return true }
        if tile.isWater && improvement.canBeBuiltOn("Water") { return true }
        if improvement.uniqueObjects.contains(where: { $0.pattern == "Can also be built on tiles adjacent to fresh water" && holds($0) })
            && isAdjacentTo(tile, "Fresh water", civId: civId) { return true }
        // "I don't particularly like this check, but it is required to build mines on non-hill resources"
        if resourceIsVisible && resource != nil && isImprovedByResource(improvement.name) && extendedDomainCheck(tile, improvement) { return true }
        return false
    }

    /// Unciv ruleset.nonRoadTileRemovals filtered to the ones the civ has researched (getImprovementBuildingProblems).
    func knownNonRoadTileRemovals(civId: Int) -> [ImprovementDef] {
        guard let civ = civ(civId) else { return [] }
        return rs.improvementOrder.compactMap { rs.improvements[$0] }.filter { r in
            r.name.hasPrefix("Remove ") && r.name != "Remove Road" && r.name != "Remove Railroad"
                && (r.techRequired == nil || civ.techs.contains(r.techRequired!))
        }
    }

    /// Unciv TileImprovementFunctions.extendedDomainCheck: no land improvement on water and vice versa.
    func extendedDomainCheck(_ tile: Tile, _ improvement: ImprovementDef) -> Bool {
        if improvement.terrainsCanBeBuiltOn.isEmpty { return true }
        var allowed: Set<TerrainType> = []
        for canBuildOn in improvement.terrainsCanBeBuiltOn {
            if let type = TerrainType(rawValue: canBuildOn) { allowed.insert(type) }
            guard let terrain = rs.terrains[canBuildOn] else { continue }
            allowed.insert(terrain.type)
            for occursOn in terrain.occursOn { if let base = rs.terrains[occursOn] { allowed.insert(base.type) } }
        }
        return (tile.isLand && allowed.contains(.land)) || (tile.isWater && allowed.contains(.water))
    }

    /// Unciv Tile.lastTerrain: the last feature, else the natural wonder, else the base terrain.
    func lastTerrainOf(_ tile: Tile) -> Terrain? {
        if let f = tile.features.last { return rs.terrains[f] ?? rs.terrains[tile.baseTerrain] }
        if let w = tile.naturalWonder { return rs.terrains[w] }
        return rs.terrains[tile.baseTerrain]
    }

    /// Unciv Tile.allTerrains: base, natural wonder, then the features.
    func allTerrainsOf(_ tile: Tile) -> [Terrain] {
        ([tile.baseTerrain] + (tile.naturalWonder.map { [$0] } ?? []) + tile.features).compactMap { rs.terrains[$0] }
    }

    /// Unciv Tile.isAdjacentTo: "This should be the only adjacency function". Rivers count for the tile itself.
    func isAdjacentTo(_ tile: Tile, _ terrainFilter: String, civId: Int? = nil) -> Bool {
        if terrainFilter == "River" { return tile.riverAdjacent }
        if terrainFilter == "Fresh water" && tile.riverAdjacent { return true }
        return map.neighbors(of: tile.coord).contains { n in map[n].map { tileMatches($0, terrainFilter, civId: civId ?? -1) } ?? false }
    }

    /// The improvements this civ could order on this tile, in ruleset order: Unciv's canBuildImprovement for each
    /// worker-buildable one (great improvements are placed by their unit, never ordered).
    func buildableImprovements(_ tile: Tile, civId: Int) -> [ImprovementDef] {
        rs.improvementOrder.compactMap { rs.improvements[$0] }.filter { imp in
            imp.isWorkerBuildable && !imp.isGreatImprovement && canBuildImprovement(imp, on: tile, civId: civId)
        }
    }

    // MARK: - setImprovement

    /// Unciv Tile.removeImprovement: `setImprovement(null)` - does not remove roads.
    func removeImprovement(at c: HexCoord) { setImprovement(at: c, nil) }

    /// Unciv TileImprovementFunctions.setImprovement(improvementName, civToActivateBroaderEffects, unit). A name the
    /// ruleset does not know is Unciv's `null`: the improvement is removed.
    /// `civToActivateBroaderEffects` is for completing a build, road ownership and taking over tiles; without it the
    /// owning city is not refreshed and no unique is triggered.
    func setImprovement(at c: HexCoord, _ improvementName: String?, civToActivateBroaderEffects civId: Int? = nil, unitId: Int? = nil) {
        guard map[c] != nil else { return }
        let improvement = improvementName.flatMap { rs.improvements[$0] }

        func updateVisibility() {
            // Update the separately-kept "what a civ sees"
            let visible: Set<Int> = Set(civs.filter { $0.isAlive && $0.isMajor && ($0.id == civId || visibleTiles(for: $0.id).contains(c)) }.map { $0.id })
            for i in civs.indices where visible.contains(civs[i].id) {
                if let name = improvement?.name { civs[i].lastSeenImprovement[c] = name } else { civs[i].lastSeenImprovement[c] = nil }
            }
        }
        func updateCity() {
            guard civId != nil, let city = owningCity(c) else { return }
            updateCityStats(city.id, reason: "TileImprovementFunctions.setImprovement")
            updateCivResources(city.civId)
            if let ci = cityIndex(city.id) { reassignPopulationDeferred(ci) }
        }

        guard let improvement else {
            let wasEncampment = map[c]?.hasBarbarianCamp ?? false
            map.update(c) { $0.pillaged = false; $0.improvement = nil }
            updateVisibility()
            updateCity()
            if !wasEncampment { return }
            // Any barbarian encampment cleared outside MapUnit.clearEncampment obsoletes ClearBarbarianCamp quests
            for cs in cityStates { handleObsoleteQuests(cityState: cs.id) }
            return
        }

        var improvementFieldHasChanged = false
        if improvement.name.hasPrefix("Remove ") {
            activateRemovalImprovement(at: c, improvement.name, civToActivateBroaderEffects: civId)
        } else if improvement.name == "Road" {
            setRoadStatus(at: c, 1, creatingCiv: civId)
        } else if improvement.name == "Railroad" {
            setRoadStatus(at: c, 2, creatingCiv: civId)
        } else if improvement.name == "Repair" {
            setRepaired(at: c)
        } else {
            map.update(c) { $0.pillaged = false; $0.improvement = improvement.name }
            improvementFieldHasChanged = true
            if improvement.uniques.contains("Irremovable") || isMarkedForCreatesOneImprovement(c, improvement.name) {
                removeCreatesOneImprovementMarker(at: c)
            }
            // relevant when the improvement was created instantly - such as Great Improvement
            if var t = map[c] {
                GameState.setImprovementQueue(&t, improvementQueue(t).filter { !(rs.improvements[$0.improvement]?.isRoad ?? false) })
                map[c] = t
            }
        }

        if improvementFieldHasChanged { updateVisibility() }

        if improvement.uniques.contains("Removes removable features when built"), let t = map[c] {
            // Remove terrainFeatures that a Worker can remove and that aren't explicitly allowed under the improvement
            let removable = t.features.filter { f in
                guard let feature = rs.terrains[f] else { return false }
                return rs.improvements["Remove " + f] != nil && !improvement.isAllowedOnFeature(feature)
            }
            map[c]?.features = t.features.filter { !removable.contains($0) }
        }

        if let civId { triggerImprovementUniques(at: c, improvement, civId: civId, unitId: unitId) }

        updateCity()
    }

    /// Unciv TileImprovementFunctions.triggerImprovementUniques: the improvement's own triggerable uniques, then the
    /// civ's and the unit's "upon building a [] improvement" triggers.
    private func triggerImprovementUniques(at c: HexCoord, _ improvement: ImprovementDef, civId: Int, unitId: Int?) {
        let ctx = UniqueContext(civId: civId, unit: unitId.flatMap { unit($0) }, tile: map[c])
        let own = improvement.uniqueObjects.filter { u in
            !u.conditionals.contains { $0.pattern.hasPrefix("upon ") } && conditionalsHold(u, ctx)
        }
        if !own.isEmpty { triggerUniques(own, civId: civId, cityId: nil, unitId: unitId) }
        triggerConditionalUniques(civId: civId, unitId: unitId) { cu in cu.pattern == "upon building a [] improvement" && improvement.matchesFilter(cu.param(0)) }
    }

    /// Unciv TileImprovementFunctions.activateRemovalImprovement
    private func activateRemovalImprovement(at c: HexCoord, _ improvementName: String, civToActivateBroaderEffects civId: Int?) {
        guard let t = map[c] else { return }
        let removedFeatureName = String(improvementName.dropFirst(7))
        // We removed a terrain (e.g. Forest) and the improvement (e.g. Lumber mill) requires it!
        if let current = t.improvement.flatMap({ rs.improvements[$0] }),
           t.features.contains(where: { current.terrainsCanBeBuiltOn.contains($0) && $0 == removedFeatureName }),
           !current.terrainsCanBeBuiltOn.contains(t.baseTerrain) {
            removeImprovement(at: c)
        }
        if improvementName == "Remove Road" || improvementName == "Remove Railroad" {
            removeRoad(at: c)
        } else if map[c]?.improvement == removedFeatureName {
            removeImprovement(at: c)
        } else {
            if let removed = rs.terrains[removedFeatureName], let civId,
               removed.uniqueObjects.contains(where: { $0.pattern == "Provides a one-time bonus of [] to the closest city when cut down" }) {
                tryProvideProductionToClosestCity(at: c, removedFeatureName, civId: civId)
            }
            // Unciv Tile.removeTerrainFeature: the first occurrence
            if let i = map[c]?.features.firstIndex(of: removedFeatureName) { map[c]?.features.remove(at: i) }
        }
    }

    /// Unciv TileImprovementFunctions.tryProvideProductionToClosestCity: Float stats, scaled by distance and by
    /// whose land it was, each stat added truncated to the closest city of the civ.
    private func tryProvideProductionToClosestCity(at c: HexCoord, _ removedTerrainFeature: String, civId: Int) {
        guard let tile = map[c] else { return }
        // Unciv civ.cities.minByOrNull: the first city at the smallest distance
        var closest: City? = nil
        for city in cities(of: civId) where closest == nil || city.coord.distance(to: c) < closest!.coord.distance(to: c) { closest = city }
        guard let closestCity = closest else { return }
        let distance = closestCity.coord.distance(to: c)
        if distance > 5 { return }
        var stats: [String: Float] = [:]
        let order = ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith"]
        let ctx = UniqueContext(civId: civId, city: owningCity(c), tile: tile)
        for t in allTerrainsOf(tile) {
            for u in t.uniqueObjects where u.pattern == "Provides a one-time bonus of [] to the closest city when cut down" && conditionalsHold(u, ctx) {
                guard let st = u.stats else { continue }
                for s in order where st[s] != 0 {
                    var v = Float(st[s])
                    if u.conditionals.contains(where: { $0.pattern == "(modified by game speed)" }) { v *= Float(speed.modifier) }
                    if u.conditionals.contains(where: { $0.pattern == "(modified by game progress up to []%)" }) { v *= Float(gameProgressModifier(u, civId: civId)) }
                    stats[s, default: 0] += v
                }
            }
        }
        if !stats.values.contains(where: { $0 != 0 }) { return }
        if distance != 1 { for k in stats.keys { stats[k]! *= Float(6 - distance) / 4 } }
        if owningCity(c).map({ $0.civId != civId }) ?? true { for k in stats.keys { stats[k]! *= 2 / Float(3) } }
        var text: [String] = []
        for s in order { if let v = stats[s], v != 0 { text.append("\(v > 0 ? "+" : "")\(Int(v)) \(s)") } }
        for s in order {
            guard let v = stats[s], v != 0 else { continue }
            let amount = Int(v)
            // Unciv City.addStat: production to the construction, food to the store, the rest to the civ
            if let cci = cityIndex(closestCity.id) {
                switch s {
                case "Production": addProductionPoints(cityIndex: cci, amount)
                case "Food": cities[cci].foodStored += Double(amount)
                case "Gold": if let cv = civIndex(civId) { civs[cv].gold += Double(amount) }
                case "Culture": if let cv = civIndex(civId) { civs[cv].cultureStored += Double(amount) }
                case "Faith": if let cv = civIndex(civId) { civs[cv].faithStored += Double(amount) }
                case "Science": addScience(civId: civId, amount)
                default: break
                }
            }
            notify(civId, "Clearing a [\(removedTerrainFeature)] has created [\(text.joined(separator: ", "))] for [\(closestCity.name)]",
                   category: .Production, icons: ["StatIcons/Production"], actions: [.location(c), .location(closestCity.coord)])
        }
    }

    /// Unciv TileImprovementFunctions.removeCreatesOneImprovementMarker is `removeCreatesOneImprovementMarker(at:)`
    /// (CityExpansionManager.swift), which also drops the claiming construction's tile.

    // MARK: - roads

    /// Unciv Tile.removeRoad: `setRoadStatus(RoadStatus.None, null)`
    func removeRoad(at c: HexCoord) { setRoadStatus(at: c, 0, creatingCiv: nil) }

    /// Unciv Tile.setRoadStatus: 0 None, 1 Road, 2 Railroad. The road is unpillaged; an owned tile's road belongs to
    /// the tile's owner, a neutral one to the civ that built it, which then pays for it through its neutralRoads.
    func setRoadStatus(at c: HexCoord, _ level: Int, creatingCiv: Int?) {
        guard var t = map[c] else { return }
        t.roads = level >= 1
        t.railroad = level >= 2
        t.roadPillaged = false
        let currentOwner = t.ownerCivId
        if level == 0 && currentOwner == nil {
            // Unciv: getRoadOwner()?.neutralRoads?.remove(position) - getRoadOwner() is roadOwnerObject ?: getOwner(),
            // the stored road owner on an unowned tile. roadOwner itself stays.
            if let roadOwner = t.roadOwner { neutralRoads[roadOwner]?.remove(c) }
        } else if let currentOwner {
            if currentOwner != t.roadOwner { t.roadOwner = currentOwner }
        } else if let creatingCiv {
            t.roadOwner = creatingCiv   // neutral tile, use building unit
            // Unciv `creatingCivInfo.neutralRoads.add(position)`; the previous road owner's entry is not removed, so a
            // civ upgrading another's neutral Road to Railroad leaves both paying for it.
            neutralRoads[creatingCiv, default: []].insert(c)
        }
        map[c] = t
    }

    // MARK: - pillage and repair

    /// Unciv Tile.setPillaged: sets the improvement (else the road) to pillaged without prior checks for validity, and
    /// ensures matching CreatesOneImprovement queued buildings are removed. Naval improvements are destroyed instead.
    func setPillaged(at c: HexCoord) {
        guard let t = map[c], t.canPillageTile else { return }
        if !t.isLand {
            removeImprovement(at: c)
            if let city = owningCity(c), let ci = cityIndex(city.id) { reassignPopulationDeferred(ci) }
            return
        }
        // Setting turnsToImprovement might interfere with UniqueType.CreatesOneImprovement
        removeCreatesOneImprovementMarker(at: c)
        if var q = map[c] { GameState.setImprovementQueue(&q, []); map[c] = q }   // remove any in progress work as well
        if rs.improvements["Repair"] == nil {
            // if no Repair action, destroy improvements instead
            if map[c]?.canPillageImprovement == true { removeImprovement(at: c) } else { removeRoad(at: c) }
        } else {
            if map[c]?.canPillageImprovement == true { map[c]?.pillaged = true }
            else {
                map[c]?.roadPillaged = true
                clearAllPathfindingCaches()
            }
        }
        if let city = owningCity(c) {
            if let ci = cityIndex(city.id) { reassignPopulationDeferred(ci) }
            updateCivResources(city.civId)
        }
    }

    /// Unciv Tile.setRepaired: the queue is cleared, the improvement is repaired first, otherwise the road.
    func setRepaired(at c: HexCoord) {
        guard var t = map[c] else { return }
        GameState.setImprovementQueue(&t, [])
        if t.pillaged { t.pillaged = false } else { t.roadPillaged = false }
        map[c] = t
        if let city = owningCity(c), let ci = cityIndex(city.id) { reassignPopulationDeferred(ci) }
    }

    // MARK: - Tile.doWorkerTurn

    /// Unciv Tile.doWorkerTurn: the first queue entry counts down; once it reaches zero it leaves the queue and the
    /// improvement is set with the worker's civ and the worker. `true` if work got finished.
    func tileDoWorkerTurn(at c: HexCoord, workerId: Int) -> Bool {
        guard var t = map[c], let worker = unit(workerId) else { return false }
        if isMarkedForCreatesOneImprovement(c) { return false }
        var queue = improvementQueue(t)
        if queue.isEmpty { return false }
        // Unciv ImprovementQueueEntry.countDown: `(turns - 1).coerceAtLeast(0)`, still counting while above zero
        queue[0].turns = max(0, queue[0].turns - 1)
        if queue[0].turns > 0 {
            GameState.setImprovementQueue(&t, queue)
            map[c] = t
            return false
        }
        let entry = queue.removeFirst()
        GameState.setImprovementQueue(&t, queue)
        map[c] = t
        setImprovement(at: c, entry.improvement, civToActivateBroaderEffects: worker.civId, unitId: workerId)
        return true
    }
}
