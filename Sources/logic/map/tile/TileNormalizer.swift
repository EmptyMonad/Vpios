// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mirror of Unciv `logic/map/tile/TileNormalizer.kt` for one tile of the map: what the map editor runs after every
/// brush stroke (MapEditorEditTab.paintTile) and over every tile when a map is fitted to another ruleset
/// (MapEditorModsTab.fitMapToRuleset). MapGenerator.normalizeToRuleset keeps its own whole-map pass for generation.
extension GameState {
    /// Unciv TileNormalizer.normalizeToRuleset(tile, ruleset), against the active ruleset.
    func normalizeTileToRuleset(_ c: HexCoord) {
        guard var tile = map[c] else { return }
        if let nw = tile.naturalWonder, rs.terrains[nw] == nil { tile.naturalWonder = nil }
        if let nw = tile.naturalWonder, let wonderTerrain = rs.terrains[nw] {
            if let into = wonderTerrain.turnsInto {
                tile.baseTerrain = into
                tile.features = []   // removeTerrainFeatures()
            } else {
                tile.features = tile.features.filter { wonderTerrain.occursOn.contains($0) }
            }
            tile.resource = nil   // `tileResource = null` - the amount is left as it is
            clearImprovementForNormalize(&tile)
        }

        if rs.terrains[tile.baseTerrain] == nil {
            // `ruleset.terrains.values.first { it.type == TerrainType.Land && !it.impassable }`
            tile.baseTerrain = rs.terrainOrder.compactMap { rs.terrains[$0] }.first { $0.type == .land && !$0.impassable }?.name ?? tile.baseTerrain
        }

        let base = tile.baseTerrain
        let newFeatures = tile.features.filter { f in
            guard let feature = rs.terrains[f] else { return false }
            return feature.occursOn.isEmpty || feature.occursOn.contains(base)
        }
        if newFeatures.count != tile.features.count { tile.features = newFeatures }

        if let r = tile.resource, rs.resources[r] == nil { tile.resource = nil }
        if let resource = tile.resource.flatMap({ rs.resources[$0] }),
           !resource.terrainsCanBeFoundOn.contains(where: { $0 == tile.baseTerrain || tile.features.contains($0) }) {
            tile.resource = nil
        }

        // "If we're checking this at gameInfo.setTransients, we can't check the top terrain"
        if tile.improvement != nil { normalizeTileImprovement(&tile) }
        if tile.improvementInProgress != nil { normalizeImprovementQueue(&tile) }
        if tile.isWater || (lastTerrainOf(tile)?.impassable ?? false) {   // Unciv tile.isImpassible(): lastTerrain.impassable
            // Tile.removeRoad(): setRoadStatus(RoadStatus.None, null)
            tile.roads = false; tile.railroad = false; tile.roadPillaged = false
        }
        map[c] = tile
    }

    /// Unciv TileNormalizer.normalizeTileImprovement
    private func normalizeTileImprovement(_ tile: inout Tile) {
        guard let improvementObject = tile.improvement.flatMap({ rs.improvements[$0] }) else { return clearImprovementForNormalize(&tile) }
        if canImprovementBeBuiltHere(tile, improvementObject, isNormalizeCheck: true, ignoreConditionals: true) { return }
        clearImprovementForNormalize(&tile)
    }

    /// Unciv TileNormalizer.normalizeImprovementQueue: only the entries that could still be built stay.
    private func normalizeImprovementQueue(_ tile: inout Tile) {
        let oldQueue = improvementQueue(tile)
        var kept: [(improvement: String, turns: Int)] = []
        for entry in oldQueue {
            guard let improvementObject = rs.improvements[entry.improvement] else { continue }
            if canImprovementBeBuiltHere(tile, improvementObject, isNormalizeCheck: true, ignoreConditionals: true) { kept.append(entry) }
        }
        GameState.setImprovementQueue(&tile, kept)
    }

    /// Unciv TileNormalizer `Tile.clearImprovement()`: "This runs from mapgen, so don't go through the
    /// side-effect-triggering TileImprovementFunctions" - the field and stopWorkingOnImprovement().
    private func clearImprovementForNormalize(_ tile: inout Tile) {
        tile.improvement = nil
        if isMarkedForCreatesOneImprovement(tile.coord) { return }   // Tile.stopWorkingOnImprovement
        GameState.setImprovementQueue(&tile, [])
    }
}
