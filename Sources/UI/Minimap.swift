// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Small overview of the explored world; tap to move the camera.
struct MinimapView: View {
    @ObservedObject var controller: GameController
    /// Unciv MinimapHolder.maximized: the minimap grows to fill the screen and shrinks back.
    var width: CGFloat { controller.minimapMaximized ? maximizedWidth : Self.width(forSize: liveSize) }
    /// Unciv MinimapHolder.minimapSize (0...30), live while it is being dragged
    @State private var liveSize = UserSettings.minimapSize
    @State private var dragStartSize: Int? = nil
    static func width(forSize size: Int) -> CGFloat { 90 + CGFloat(size) * 7 }
    private var maximizedWidth: CGFloat { UIScreen.main.bounds.width * 0.8 }

    /// Unciv Minimap.createMinimapTiles + MinimapTileUtil.spreadOutMinimapTiles: the minimap's tiles - the map's tiles in
    /// tileMap.values order, those outside the civ's ExploredRegion left out - each with the top left corner it is drawn at.
    private struct Layout {
        var tiles: [(coord: HexCoord, origin: CGPoint)] = []
        var cell: CGFloat = 1
        var height: CGFloat = 0
        /// Where Unciv column 0 and latitude 0 fall on the minimap (at a tile's centre) - the camera frame's reference
        var originX: CGFloat = 0, originY: CGFloat = 0
        /// Minimap distance of one latitude step (half a row)
        var latStep: CGFloat { cell * CGFloat(3).squareRoot() / 4 }
    }
    private func layout(_ s: GameState, region: ExploredRegion?) -> Layout {
        let map = s.map
        let p = map.exploredRegionParameters
        var out = Layout()
        // Unciv Minimap.calcTileSize: the region's getWidth (columns) and getHeight (latitude steps), the whole map without one
        let cols: CGFloat, rows: CGFloat
        if let r = region { cols = CGFloat(r.getWidth(p)); rows = CGFloat(r.getHeight() + 1) / 2 }
        else { cols = CGFloat(map.width); rows = CGFloat(map.height) }
        let cell = min(width / (cols * 0.75 + 0.25), width * 0.9 / ((rows + 0.5) * 0.866))
        out.cell = cell; out.height = cell * (rows + 0.5) * 0.866
        // createMinimapTiles: a tile left of exploredRegion.getMinimapLeft lies across the map edge and moves right by the pad,
        // so the two explored strips of a world-wrap map sit side by side
        let pad = p.rectangularMap ? CGFloat(p.mapWidth - 1) * cell * 0.75 : CGFloat(p.mapSizeRadius) * cell * 1.5
        let leftSide = region.map { CGFloat($0.minimapLeft(tileSize: Float(cell))) } ?? -.greatestFiniteMagnitude
        var raw: [(HexCoord, CGFloat, CGFloat)] = []
        let order = map.uncivOrder.isEmpty ? Array(map.tiles.indices) : map.uncivOrder
        for idx in order where !map.missing.contains(idx) {
            let c = map.tiles[idx].coord
            let ll = map.longitudeLatitude(c)
            if let r = region, !r.isPositionInRegion(longitude: ll.longitude, latitude: ll.latitude) { continue }
            // MinimapTile: hex2WorldCoords(position) * 0.5 * tileSize = (0.75 * column, sqrt(3) / 4 * latitude) * tileSize
            var x = CGFloat(-ll.longitude) * 0.75 * cell
            if x < leftSide { x += pad }
            raw.append((c, x, CGFloat(ll.latitude) * out.latStep))
        }
        guard let minX = raw.map({ $0.1 }).min(), let maxX = raw.map({ $0.1 }).max(),
              let minY = raw.map({ $0.2 }).min(), let maxY = raw.map({ $0.2 }).max() else { return out }
        // Minimap init: the tiles are centred in the minimap (y grows downwards here, upwards in Unciv)
        let offX = (width - (maxX - minX + cell * 0.95)) / 2 - minX
        let offY = (out.height - (maxY - minY + cell * 0.85)) / 2 + maxY
        out.tiles = raw.map { ($0.0, CGPoint(x: offX + $0.1, y: offY - $0.2)) }
        out.originX = offX + cell * 0.95 / 2; out.originY = offY + cell * 0.85 / 2
        return out
    }

    var body: some View {
        let s = controller.state
        let map = s.map
        // Unciv WorldScreen.update: minimapWrapper.update(getGameViewConsideringForOfWar().civView.getCiv()) - a spectator's
        // selected civ (or itself with Fog of War off)
        let viewer = s.civ(controller.viewCivId) ?? s.player
        // Unciv MinimapHolder.rebuildIfSizeChanged: `civInfo.takeUnless { selectedGameView.spectatorMode }` - a spectating
        // player's minimap shows the whole map, anyone else's only the ExploredRegion of the civ it shows.
        let region: ExploredRegion? = s.player.isSpectator ? nil : viewer.exploredRegion
        let lay = layout(s, region: region)
        let cell = lay.cell, height = lay.height
        // Unciv MinimapHolder.shouldShowMapButtons: minimapSize > 0 and the minimap wider or taller than 100; while maximized
        // Unciv's minimapSize is the closest size to the stage, so the buttons show
        let showButtons = controller.minimapMaximized || (liveSize > 0 && (width > 100 || height > 100))
        let explored = viewer.explored
        Canvas { ctx, size in
            var cityDiscs: [(CGRect, CGFloat, NationDef)] = []
            for (c, o) in lay.tiles where explored.contains(c) {
                guard let tile = map[c] else { continue }
                let x = o.x, y = o.y
                // Unciv MinimapTile.updateColor: a city centre takes the owner's inner colour, other owned
                // land the outer colour, and everything else the terrain muted halfway to grey. Water is
                // never owner-coloured, and a tile we cannot currently see is not dimmed.
                let owner = tile.isWater ? nil : tile.ownerCivId.flatMap { s.civ($0)?.nationDef }
                var color: Color
                if let n = owner, tile.isCityCenter { color = Color(uiColor: UIColor(rgb: n.innerColor ?? [0, 0, 0])) }
                else if let n = owner { color = Color(uiColor: UIColor(rgb: n.outerColor)) }
                else if let t = s.rs.terrains[tile.baseTerrain] {
                    color = Color(red: (Double(t.rgb[0]) / 255 + 0.5) / 2, green: (Double(t.rgb[1]) / 255 + 0.5) / 2, blue: (Double(t.rgb[2]) / 255 + 0.5) / 2)
                } else { color = .gray }
                let rect = CGRect(x: x, y: y, width: cell * 0.95, height: cell * 0.85)
                ctx.fill(Path(rect), with: .color(color))
                // Unciv MinimapTile.updateCityCircle: collected here, drawn after every tile, since Unciv
                // keeps the city circles in their own layer above the tiles.
                if tile.isCityCenter, let n = owner ?? tile.ownerCivId.flatMap({ s.civ($0)?.nationDef }) {
                    let major = s.city(at: c).map { $0.isCapital && s.civ($0.civId)?.isMajor == true } ?? false
                    cityDiscs.append((rect, (major ? 1.667 : 1.25) * cell * 0.95, n))
                }
            }
            for (rect, size, n) in cityDiscs {
                let disc = CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
                ctx.fill(Path(ellipseIn: disc), with: .color(Color(uiColor: UIColor(rgb: n.outerColor))))
                ctx.fill(Path(ellipseIn: disc.insetBy(dx: size * 0.25, dy: size * 0.25)), with: .color(Color(uiColor: UIColor(rgb: n.innerColor ?? [0, 0, 0]))))
            }
        }
        .frame(width: width, height: height)
        .overlay { MinimapCameraFrame(viewport: controller.scene.viewport, map: map, originX: lay.originX, originY: lay.originY, cell: cell, latStep: lay.latStep) }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelDark.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { p in
            // Unciv MinimapHolder.getMaximizeToggleButton: a map this small is not touchable itself, the whole holder is
            // the maximize toggle
            guard showButtons else { controller.minimapMaximized.toggle(); return }
            // Unciv Minimap.addClickListener: `tileLayer.hit(x, y)` - the tile image under the tap, the last one added
            // winning as Group.hit walks the children from the top, an unrevealed (invisible) one never - centres the map
            // on its tile (setCenterPosition, selectUnit: the tile and what stands there selected); a tap on no tile does
            // nothing. The strips moved across the map edge resolve to their own tiles.
            let size = CGSize(width: cell, height: cell)
            if let hit = lay.tiles.last(where: { explored.contains($0.coord) && CGRect(origin: $0.origin, size: size).contains(p) }) {
                controller.setCenterPosition(hit.coord); controller.refresh(full: false)
            }
            // Unciv MinimapHolder: while maximized, `minimap.onClick { maximized = false }` - a tap on the map puts it back.
            if controller.minimapMaximized { controller.minimapMaximized = false }
        }
        // Unciv MinimapHolder.ResizeDragListener: dragging the minimap (it sits in the bottom right corner) sets the closest
        // size to the drag point, 0...30, saved when the drag ends; not while maximized
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { g in
            guard !controller.minimapMaximized else { return }
            if dragStartSize == nil { dragStartSize = liveSize }
            let target = Self.width(forSize: dragStartSize ?? liveSize) - max(g.translation.width, g.translation.height)
            liveSize = max(0, min(30, Int(((target - 90) / 7).rounded())))
        }.onEnded { _ in
            if dragStartSize != nil { UserSettings.minimapSize = liveSize; dragStartSize = nil }
        })
        // Unciv MinimapHolder.getCornerHandleIcon: the Corner image top left while not maximized and the map is big enough
        .overlay(alignment: .topLeading) {
            if !controller.minimapMaximized && showButtons {
                ArtIcon(name: "Corner", folder: "OtherIcons", fallback: "arrow.up.left", size: 14).padding(4).allowsHitTesting(false)
            }
        }
        // Unciv MinimapHolder.getMaximizeToggleButton: the button only when shouldShowMapButtons
        .overlay(alignment: .bottomTrailing) {
            if showButtons {
                Button { controller.minimapMaximized.toggle() } label: {
                    Image(systemName: controller.minimapMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11)).foregroundStyle(Theme.gold)
                        .padding(3).background(Circle().fill(Theme.panelDark.opacity(0.9)))
                }.buttonStyle(.plain).padding(2)
            }
        }
    }
}

/// Unciv Minimap.updateScrollPosition, which ZoomableScrollPane.onViewportChanged calls on every scroll, zoom and scrollTo
/// step: the camera frame, in a layer of its own over the minimap's tiles, follows the scene's viewport (MapViewport) as it
/// moves - it had waited for the game state's next change, so a pan or a zoom left it behind.
private struct MinimapCameraFrame: View {
    @ObservedObject var viewport: MapViewport
    let map: GameMap
    /// The minimap layout's reference (Unciv column 0 and latitude 0), tile size and latitude step
    let originX: CGFloat, originY: CGFloat, cell: CGFloat, latStep: CGFloat
    var body: some View {
        Canvas { ctx, size in
            // Unciv Minimap.updateScrollPosition: the camera frame drawn over the map, placed from the world viewport; with
            // world wrap (createScrollPositionIndicators: continuousScrollingX) two more a world's width to either side.
            // They are ClippingImages: each shows only its part inside the minimap.
            let view = viewport.rect
            guard view.width > 0 && view.height > 0 else { return }
            let x0 = originX + MapScene.uncivColumn(sceneX: view.minX, map) * 0.75 * cell
            let x1 = originX + MapScene.uncivColumn(sceneX: view.maxX, map) * 0.75 * cell
            let yTop = originY - MapScene.uncivLatitude(sceneY: view.maxY, map) * latStep
            let yBottom = originY - MapScene.uncivLatitude(sceneY: view.minY, map) * latStep
            let frame = CGRect(x: x0, y: yTop, width: x1 - x0, height: yBottom - yTop)
            let offset = CGFloat(map.width) * 0.75 * cell   // worldWidth * worldToMiniFactor.x
            ctx.clip(to: Path(CGRect(origin: .zero, size: size)))
            for dx in map.wrapX ? [0, -offset, offset] : [0] { ctx.stroke(Path(frame.offsetBy(dx: dx, dy: 0)), with: .color(.white), lineWidth: 1) }
        }
        .allowsHitTesting(false)
    }
}
