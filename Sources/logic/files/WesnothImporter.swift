// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv MapEditorWesnothImporter: a Battle for Wesnoth `.map` (TerrainCodesWML) becomes a rectangular Epochs map via WesnothImportMappings.json.
enum WesnothImporter {
    /// Unciv UncivShowableException: everything parse throws is shown to the player as its own (translated) text.
    struct ImportError: LocalizedError { let message: String; var errorDescription: String? { message } }

    private static let ignoreLines: Set<String> = ["usage=map", "border_size=1"]
    private static let mappings: [String: [String]] = {
        guard let url = Bundle.main.url(forResource: "WesnothImportMappings", withExtension: "json", subdirectory: "GameData"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: [String]] else { return ["fallback": ["Grassland"]] }
        return json
    }()
    private static let terrainCode = try! NSRegularExpression(pattern: #"^(((?<start>\d+)|[A-Za-z\d_]+) )*(?<base>[A-Z_][a-z\\|/]{1,3})(\^(?<layer>[A-Z_][a-z\\|/]{1,3}))?$"#)

    /// Unciv MapEditorWesnothImporter.parse. Wesnoth maps come with a non-playable border of one hex, and Wesnoth puts
    /// the odd corner with only two neighbours on top where Unciv puts it at the bottom: every other column is shifted
    /// one place vertically, using half the unplayable hexes on top and alternately those at the bottom - the map is
    /// one row taller than Wesnoth showed.
    static func parse(_ text: String, rs: Ruleset) throws -> CustomMap {
        // `lineSequence().filter { it.isNotBlank() && it !in ignoreLines }`
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !ignoreLines.contains($0) }
        let height = lines.count - 1
        let width = height <= 0 ? 0 : lines[0].split(separator: ",", omittingEmptySubsequences: false).count - 2
        guard width > 0 else { throw ImportError(message: "That map is invalid!") }
        // `TileMap(width, height, ruleset, false)`: columns -width/2 ... (width-1)/2, rows -height/2 ... (height-1)/2, every
        // tile on the first land terrain that generates naturally (MapLandmassGenerator.getInitializationTerrain); the
        // mapParameters say rectangular, MapSize(width, height). Laid into our grid as every Unciv map is (UncivSave.frame).
        let land = rs.terrainOrder.compactMap { rs.terrains[$0] }.first { $0.type == .land && !$0.uniques.contains("Doesn't generate naturally") }?.name ?? "Grassland"
        var map = GameMap(uncivPositions: HexMath.rectangularPositions(width: width, height: height, worldWrap: false), wrapX: false, baseTerrain: land)
        map.uncivSize = UncivMapSize(width: width, height: height, shape: "Rectangular")
        let frame = UncivSave.Frame.forExport(width: map.width, height: map.height)
        var starts: [HexCoord] = []
        let colOffset = 1 + width / 2
        let rowOffset = height / 2
        for (row, line) in lines.enumerated() {
            for (column, cellRaw) in line.split(separator: ",", omittingEmptySubsequences: false).enumerated() {
                let effectiveRow = rowOffset - row + column % 2   // see the comment above
                let pos = HexMath.tileCoordsFromColumnRow(column - colOffset, effectiveRow)
                let o = frame.ours(x: pos.x, y: pos.y)
                let hex = HexCoord.fromOffset(col: o.col, row: o.row)
                // `if (!map.contains(pos)) continue`
                guard let idx = map.index(of: hex), map.uncivPosition(hex) == pos else { continue }
                let (tile, start) = try paint(map.tiles[idx], code: cellRaw.trimmingCharacters(in: .whitespacesAndNewlines), rs: rs)
                map.tiles[idx] = tile
                // `map.addStartingLocation(Constants.spectator, this)`: once per tile
                if start && !starts.contains(hex) { starts.append(hex) }
            }
        }
        return CustomMap(map: map, starts: starts)
    }

    private static func translate(_ code: String?) -> [String] {
        guard let code else { return [] }
        var out: [String] = []
        for length in stride(from: code.count, through: 1, by: -1) { if let m = mappings[String(code.prefix(length))] { out += m } }
        return out
    }

    private static func paint(_ tile: Tile, code: String, rs: Ruleset) throws -> (Tile, Bool) {
        let ns = code as NSString
        guard let m = terrainCode.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) else { throw ImportError(message: "{That map is invalid!}\n{(\"[\(code)]\" does not conform to TerrainCodesWML)}") }
        func group(_ name: String) -> String? { let r = m.range(withName: name); return r.location == NSNotFound ? nil : ns.substring(with: r) }
        let base = group("base"), layer = group("layer"), start = group("start")
        let names = translate(base) + translate(layer) + (mappings["fallback"] ?? ["Grassland"])
        var t = tile
        // Unciv: base terrain first (hills sort first among terrains), then features, then an improvement.
        let terrains = names.compactMap { rs.terrains[$0] }
        if let baseT = terrains.first(where: { $0.type == .land || $0.type == .water }) { t.baseTerrain = baseT.name }
        let features = terrains.filter { $0.type == .terrainFeature }.map { $0.name }
        var seen = Set<String>(); t.features = features.filter { seen.insert($0).inserted }
        if let imp = names.first(where: { rs.improvements[$0] != nil || $0 == Names.barbarianCamp || $0 == Names.ancientRuins }) { t.improvement = imp }
        return (t, start != nil)
    }
}
