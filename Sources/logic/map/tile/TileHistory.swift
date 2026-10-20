// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv TileHistory: who owned a tile at which turn, and whether it was a (capital) city centre — feeds the victory-screen Replay.
struct TileHistoryEntry: Codable, Hashable {
    var owner: Int? = nil
    /// Unciv CityCenterType serialisation: "N" none, "R" regular, "C" capital.
    var center: String = "N"
}

extension GameState {
    /// The tile's state at `turn` (Unciv TileHistory.getState: the latest entry at or before that turn).
    func tileHistoryState(_ tile: Tile, turn t: Int) -> TileHistoryEntry {
        var best: (Int, TileHistoryEntry)? = nil
        for (k, v) in tile.history where k <= t { if best == nil || k > best!.0 { best = (k, v) } }
        return best?.1 ?? TileHistoryEntry()
    }

    private func currentHistoryEntry(_ t: Tile) -> TileHistoryEntry {
        var center = "N"
        if let cid = t.cityId, let c = city(cid) { center = c.isCapital ? "C" : "R" }
        return TileHistoryEntry(owner: t.ownerCivId, center: center)
    }

    /// Unciv records ownership at the moment it changes (recordTakeOwnership / recordRelinquishOwnership); we compare every tile
    /// against its last entry at the end of the turn, which yields the same turn numbers.
    func recordTileHistoryChanges() {
        for i in map.tiles.indices {
            let t = map.tiles[i]
            let cur = currentHistoryEntry(t)
            let last = t.history.max { $0.key < $1.key }?.value
            if last == nil ? (cur.owner != nil || cur.center != "N") : last! != cur { map.tiles[i].history[turn] = cur }
        }
    }

    /// Owner of a tile at `turn` for the replay (Unciv MinimapTile.getOwningCivFromHistory).
    func tileOwner(at turn: Int, _ tile: Tile) -> Civilization? { tileHistoryState(tile, turn: turn).owner.flatMap { civ($0) } }
}
