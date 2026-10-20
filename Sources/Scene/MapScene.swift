// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SpriteKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Unciv ZoomableScrollPane.onViewportChanged: the part of the world the camera shows, published on its own - apart from
/// GameController's state - so that following the camera redraws the minimap's camera frame and nothing else.
final class MapViewport: ObservableObject {
    @Published private(set) var rect: CGRect = .zero
    fileprivate func update(_ r: CGRect) { if r != rect { rect = r } }
}

/// Renders the hex map, units and cities; forwards taps to the controller.
final class MapScene: SKScene {
    weak var controller: GameController?
    /// Unciv ZoomableScrollPane.onViewportChangedListener: the minimap's camera frame follows it (Minimap.updateScrollPosition)
    let viewport = MapViewport()

    private let mapNode = SKNode()
    let tileLayer = SKNode()
    let overlayLayer = SKNode()
    let unitLayer = SKNode()
    /// Unciv WorldMapHolder.animateMovement: a unit that moves is walked from tile to tile rather than being
    /// redrawn at its destination. The controller leaves the path here and the next refresh picks it up - the
    /// game state has already moved on, so this is only the picture catching up.
    var moveAnimations: [(unitId: Int, from: HexCoord, path: [HexCoord])] = []
    /// Units whose art is still walking: their sprite at the destination stays hidden through any refresh until it arrives
    var walkingUnits: Set<Int> = []
    /// Unciv BattleTable NUKE: the tile a nuke was just dropped on
    var nukeAnimation: HexCoord?
    /// The map editor's scene (Unciv EditorMapHolder): its tile groups are plain TileGroups, not WorldTileGroups
    var isMapEditor = false
    /// Unciv TileMap.startingLocationsByNation as the editor holds it (MapEditorView.starts). TileLayerMisc draws them on
    /// non-world tile groups only; a game's map has none, Unciv clears them once the game starts.
    var editorStartingLocations: [StartingLocation] = []
    /// Unciv CityButton.isButtonMoved, per city
    var bannersDown: Set<Int> = []
    /// Unciv addTileOverlays: the tapped tile's table - its action button and the unit icons beside it (refreshUnits)
    private var overlayRow: (tile: HexCoord, units: [Unit])? = nil
    private var overlayButtonTiles: Set<HexCoord> = []
    /// libGDX Interpolation.swingOut (scale 2) and Interpolation.sine
    static let swingOut: SKActionTimingFunction = { t in let a = t - 1; return a * a * (3 * a + 2) + 1 }
    static let sine: SKActionTimingFunction = { t in (1 - cos(t * .pi)) / 2 }
    /// Unciv BattleTableHelpers.battleAnimation: the attacker lunges at the defender, a red damage figure rises
    /// from each side that took any, and both flash red on the way back.
    var battleAnimation: (attackerId: Int, attacker: HexCoord, defender: HexCoord, toAttacker: Int, toDefender: Int,
                          defenderId: Int?, attackerIsAir: Bool, defenderIsAir: Bool, hideDefenderDamage: Bool)?
    let labelLayer = SKNode()
    /// Effects that outlive a refresh (the nuke circle); the other layers are rebuilt on every refresh.
    let fxLayer = SKNode()
    let yieldLayer = SKNode()     // Unciv MapOverlayToggleButton: yields / worked tiles
    let cam = SKCameraNode()
    /// Unciv ZoomableScrollPane.scrollingTo: where the running "scrollTo" action is taking the camera
    private var scrollingTo: CGPoint? = nil
    /// Kept so the long-press delay can follow the setting without restarting the scene.
    private weak var longPressRecognizer: UILongPressGestureRecognizer?

    var tileNodes: [HexCoord: SKNode] = [:]
    private var tileCopies: [HexCoord: [SKNode]] = [:]
    private var mapWidthPx: CGFloat { CGFloat(controller?.state.map.width ?? 0) * HexCoord.colStep }
    private var wraps: Bool { controller?.state.map.wrapX ?? false }
    var tileKeys: [HexCoord: String] = [:]
    private var lastCameraScale: CGFloat = 0.5
    private var pinchStartScale: CGFloat = 0.5

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(red: 0.05, green: 0.08, blue: 0.13, alpha: 1)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        if mapNode.parent == nil {
            addChild(mapNode)
            mapNode.addChild(tileLayer); mapNode.addChild(overlayLayer); mapNode.addChild(unitLayer); mapNode.addChild(labelLayer); mapNode.addChild(yieldLayer); mapNode.addChild(fxLayer)
            tileLayer.zPosition = 0; overlayLayer.zPosition = 500; unitLayer.zPosition = 1000; labelLayer.zPosition = 2000; yieldLayer.zPosition = 700; fxLayer.zPosition = 4000
            camera = cam; addChild(cam)
            cam.setScale(lastCameraScale)
        }
        view.isMultipleTouchEnabled = true
        // Unciv WorldMapHolder: one UncivActorGestureListener (GestureDetector with a 20 half-side tap square, a 1.1 s long
        // press) for the whole map, and ZoomableScrollPane's pan and pinch listeners. A tap fires when the finger lifts
        // inside the square however long it rested; a long press only takes the place of the tap when it is consumed
        // (longPress returns true: Move units with a long tap, a unit selected, a tile under the finger). Unciv has no
        // recognizer that fires while the finger rests - "Show long-press indicators" marks context menus, not the map.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        let tap = UncivTapRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.halfSquare = 20 * MapScene.uncivStageUnit
        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:))); long.minimumPressDuration = UserSettings.longPressSeconds
        long.allowableMovement = 20 * MapScene.uncivStageUnit
        long.delegate = self
        longPressRecognizer = long; pinchRecognizer = pinch
        view.addGestureRecognizer(pan); view.addGestureRecognizer(pinch); view.addGestureRecognizer(tap); view.addGestureRecognizer(long)
        if InputTrace.on {
            let trace = TouchTraceRecognizer(target: nil, action: nil); trace.delegate = self
            traceRecognizer = trace; view.addGestureRecognizer(trace)
        }
        // Unciv EditorMapHolder.getDragPaintListener: in the map editor, a finger held for 400 ms (Unciv's fixed delay, not
        // the long-press setting) and then dragged paints with the brush instead of panning; moving earlier is a pan
        let paintDrag = UILongPressGestureRecognizer(target: self, action: #selector(handlePaintDrag(_:)))
        paintDrag.minimumPressDuration = 0.4
        paintDrag.delegate = self
        view.addGestureRecognizer(paintDrag)
        paintDragRecognizer = paintDrag; panRecognizer = pan
        view.ignoresSiblingOrder = true
        refreshAll()
    }

    // MARK: gestures
    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        if g.state == .began || g.state == .ended || g.state == .cancelled { InputTrace.log("pan \(g.state == .began ? "began" : g.state == .ended ? "ended" : "cancelled") fingers=\(g.numberOfTouches)") }
        let t = g.translation(in: view)
        cam.position.x -= t.x * cam.xScale
        cam.position.y += t.y * cam.yScale
        g.setTranslation(.zero, in: view)
        clampCamera()
    }
    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began || g.state == .ended { InputTrace.log("pinch \(g.state == .began ? "began" : "ended") scale=\(String(format: "%.2f", g.scale))") }
        if g.state == .began { pinchStartScale = cam.xScale }
        // Unciv ZoomGestureListener.pinch: olcek degisiminin yarattigi kaymayi telafi ederek
        // yakinlastirmayi iki parmagin ortasindaki odak noktasina yonlendirir.
        let focus: CGPoint? = (view != nil && g.numberOfTouches >= 2) ? g.location(in: view) : nil
        let before = focus.map { convertPoint(fromView: $0) }
        let s = min(maxZoomOutScale, max(0.18, pinchStartScale / g.scale))
        cam.setScale(s); lastCameraScale = s
        if let f = focus, let b = before {
            let after = convertPoint(fromView: f)
            cam.position.x += b.x - after.x
            cam.position.y += b.y - after.y
        }
        clampCamera()
    }
    /// Unciv AdvancedTab "Max zoom out" (2…10): camera scale ceiling.
    private var maxZoomOutScale: CGFloat { CGFloat(max(2, UserSettings.maxWorldZoomOut)) * 1.1 }
    /// Unciv EditorMapHolder drag-paint listener: `isPainting` once the hold has lasted 400 ms - the pan is cancelled
    /// (stage.cancelTouchFocusExcept) - every drag onto another tile paints it with the Edit tab's brush
    /// (tabs.edit.paintTilesWithBrush), and letting go redraws the map (updateTileGroups, setTransients).
    @objc private func handlePaintDrag(_ g: UILongPressGestureRecognizer) {
        guard let view = view, let controller else { return }
        switch g.state {
        case .began:
            panRecognizer?.isEnabled = false; panRecognizer?.isEnabled = true
            lastDragPainted = nil; dragPainted = false
        case .changed:
            let p = convertPoint(fromView: g.location(in: view))
            let hex = controller.state.map.normalize(HexCoord.fromPixel(mapNode.convert(p, from: self)))
            guard controller.state.map.contains(hex), hex != lastDragPainted else { return }   // getClosestTileTo: null off the map
            lastDragPainted = hex; dragPainted = true
            controller.editorDragPaint?(hex)
        case .ended, .cancelled, .failed:
            if dragPainted { controller.refresh() }
            lastDragPainted = nil; dragPainted = false
        default: break
        }
    }
    private weak var paintDragRecognizer: UILongPressGestureRecognizer?
    private weak var panRecognizer: UIPanGestureRecognizer?
    private weak var pinchRecognizer: UIPinchGestureRecognizer?
    private weak var traceRecognizer: TouchTraceRecognizer?
    private var lastDragPainted: HexCoord? = nil
    private var dragPainted = false
    /// Unciv "Move units with a long tap": a long press moves the selected unit at once (no Move-here button).
    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, UserSettings.longTapMove, controller?.selectedUnit != nil, let view = view else { return }
        let p = convertPoint(fromView: g.location(in: view))
        let hex = HexCoord.fromPixel(mapNode.convert(p, from: self))
        InputTrace.log("LONGPRESS -> tile \(InputTrace.hex(controller?.state.map.normalize(hex) ?? hex))")
        controller?.tileLongPressed(controller?.state.map.normalize(hex) ?? hex)
    }
    /// What sits above the map at a scene point: a unit icon, an action button or a city button - all of them take a tap
    /// for themselves, and none is a WorldTileGroup for WorldMapHolder's longPress.
    private enum MapHit { case unitIcon(Int), overlayButton(HexCoord), cityButton(Int) }
    private func mapHit(at p: CGPoint) -> MapHit? {
        let inOverlay = overlayLayer.convert(p, from: self)
        // Unciv addTileOverlays: a unit icon (a ClickableCircle) selects its unit
        if let hit = overlayLayer.children.first(where: { ($0.name?.hasPrefix("uniticon|") ?? false) && $0.calculateAccumulatedFrame().contains(inOverlay) }),
           let id = hit.name.flatMap({ Int($0.dropFirst("uniticon|".count)) }) {
            return .unitIcon(id)
        }
        if let hit = overlayLayer.children.first(where: { ($0.name?.hasPrefix("overlaybtn|") ?? false) && $0.calculateAccumulatedFrame().contains(inOverlay) }) {
            let parts = hit.name!.split(separator: "|")
            if parts.count == 3, let q = Int(parts[1]), let r = Int(parts[2]) { return .overlayButton(HexCoord(q, r)) }
        }
        // Unciv CityButton sits above the tile and takes the tap for itself
        let inLabels = labelLayer.convert(p, from: self)
        if let hit = labelLayer.children.first(where: { ($0.name?.hasPrefix("citybanner") ?? false) && $0.calculateAccumulatedFrame().contains(inLabels) }),
           let id = Int(hit.name!.dropFirst("citybanner".count)) {
            return .cityButton(id)
        }
        return nil
    }
    @objc private func handleTap(_ g: UncivTapRecognizer) {
        guard let view = view else { return }
        // Unciv GestureDetector.touchUp calls tap with the point where the finger lifted
        let p = convertPoint(fromView: g.liftLocation(in: view))
        InputTrace.log("TAP at=\(InputTrace.pt(g.liftLocation(in: nil))) hit=\(mapHit(at: p).map { "\($0)" } ?? "tile \(InputTrace.hex(controller?.state.map.normalize(HexCoord.fromPixel(mapNode.convert(p, from: self))) ?? HexCoord.fromPixel(mapNode.convert(p, from: self))))")")
        switch mapHit(at: p) {
        case .unitIcon(let id): controller?.tapUnitIcon(id); return
        // Unciv unit action overlays sit above everything; a tap on one presses it (here: a second tap on its tile)
        case .overlayButton(let t): controller?.tapTile(t); return
        case .cityButton(let id): controller?.tapCityButton(id, isLowered: bannersDown.contains(id)); return
        case nil: break
        }
        let hex = HexCoord.fromPixel(mapNode.convert(p, from: self))
        controller?.tapTile(controller?.state.map.normalize(hex) ?? hex)
    }
    func clampCamera() {
        guard let state = controller?.state else { return }
        let w = CGFloat(state.map.width) * HexCoord.colStep, h = CGFloat(state.map.height) * HexCoord.rowStep
        if state.map.wrapX {
            // Keep the camera inside one copy of the world; the shifted copies fill the seams.
            if cam.position.x < 0 { cam.position.x += w } else if cam.position.x >= w { cam.position.x -= w }
        } else {
            cam.position.x = min(max(cam.position.x, -16), w)
        }
        cam.position.y = min(max(cam.position.y, -h), 16)
        // Unciv WorldMapHolder.restrictX / restrictY: the camera cannot leave the player's ExploredRegion (plus a small
        // margin) - Y always, X off a world-wrap map (ours does not restrict X on one); a spectator is not restricted.
        if !state.player.isSpectator, let i = state.civIndex(state.playerId), !state.civs[i].exploredRegion.isZero {
            let region = state.civs[i].exploredRegion
            let margin = HexCoord.colStep * 3
            if !state.map.wrapX { cam.position.x = min(max(cam.position.x, Self.sceneX(longitude: region.topLeft.x, state.map) - margin), Self.sceneX(longitude: region.bottomRight.x, state.map) + margin) }
            cam.position.y = min(max(cam.position.y, Self.sceneY(latitude: region.bottomRight.y, state.map) - margin), Self.sceneY(latitude: region.topLeft.y, state.map) + margin)
        }
    }

    /// Our scene x of an Unciv longitude (UncivSave.Frame.forExport: column = -longitude, our col = column + width/2 + extra)
    static func sceneX(longitude: Float, _ map: GameMap) -> CGFloat {
        let extra = (map.width / 2) % 2 == 0 ? 0 : 1
        return (CGFloat(-longitude) + CGFloat(map.width / 2 + extra)) * HexCoord.colStep
    }
    /// Our scene y of an Unciv latitude (UncivSave.Frame.forExport: 2 * our row + odd column = 2 * maxRow + 2 - latitude)
    static func sceneY(latitude: Float, _ map: GameMap) -> CGFloat {
        let maxRow = -((map.height - 1) / 2) + map.height - 2
        return (CGFloat(latitude) - CGFloat(2 * maxRow + 2)) * HexCoord.rowStep / 2
    }
    /// The inverses: Unciv's (fractional) column and latitude of a scene point.
    static func uncivColumn(sceneX x: CGFloat, _ map: GameMap) -> CGFloat {
        let extra = (map.width / 2) % 2 == 0 ? 0 : 1
        return x / HexCoord.colStep - CGFloat(map.width / 2 + extra)
    }
    static func uncivLatitude(sceneY y: CGFloat, _ map: GameMap) -> CGFloat {
        let maxRow = -((map.height - 1) / 2) + map.height - 2
        return CGFloat(2 * maxRow + 2) + 2 * y / HexCoord.rowStep
    }

    /// Unciv WorldMapHolder.onViewportChanged's worldViewport: the part of the world the camera is looking at, in scene
    /// points, so the minimap can draw the camera frame over it (Minimap.updateScrollPosition).
    var viewportRect: CGRect {
        let halfW = size.width * cam.xScale / 2, halfH = size.height * cam.yScale / 2
        return CGRect(x: cam.position.x - halfW, y: cam.position.y - halfH, width: halfW * 2, height: halfH * 2)
    }

    /// Unciv ZoomableScrollPane.onViewportChanged, which every scroll, zoom and scrollTo step calls: once a frame, after
    /// the gestures, the zoom buttons, the panning keys and the scrollTo action have moved the camera, a changed viewport
    /// goes out - at most one publish a frame
    override func didFinishUpdate() {
        super.didFinishUpdate()
        viewport.update(viewportRect)
    }

    /// Unciv WorldMapHolder.setCenterPosition's scroll and blink: ZoomableScrollPane.scrollTo returns `false` - nothing
    /// moves and nothing blinks - when the camera is already there or already on its way there (scrollingDestination);
    /// otherwise the camera goes there, at once or with a ScrollToAction, and the tile blinks.
    @discardableResult
    func center(on hex: HexCoord, animated: Bool = true) -> Bool {
        var p = hex.pixelCenter
        if wraps {
            // Take the copy of the hex nearest to the current camera position.
            let w = mapWidthPx
            for k in [-1.0, 1.0] { let alt = p.x + k * w; if abs(alt - cam.position.x) < abs(p.x - cam.position.x) { p.x = alt } }
        }
        let destination = cam.action(forKey: "scrollTo") != nil ? (scrollingTo ?? cam.position) : cam.position
        if abs(destination.x - p.x) < 0.01 && abs(destination.y - p.y) < 0.01 { return false }
        // Unciv ZoomableScrollPane.scrollTo: a ScrollToAction of 0.4s with Interpolation.sine
        cam.removeAction(forKey: "scrollTo")
        if animated { scrollingTo = p; let a = SKAction.move(to: p, duration: 0.4); a.timingFunction = MapScene.sine; cam.run(a, withKey: "scrollTo") } else { cam.position = p }
        blinkTile(hex)
        return true
    }
    /// Unciv WorldScreen.switchToNextUnit with no unit left: `mapHolder.removeAction(mapHolder.blinkAction)`
    func stopBlink() { fxLayer.childNode(withName: "centerBlink")?.removeFromParent() }
    /// Unciv EditorMapHolder init (every new holder: the editor opening, a map loaded or generated, the ruleset applied,
    /// world wrap switched): `scrollPercentX = .5f; scrollPercentY = .5f` - the middle of the map, at once, no blink;
    /// the zoom stays (`mapHolder.zoom(savedScale)`)
    func scrollToMiddle() {
        guard let tiles = controller?.state.map.tiles, !tiles.isEmpty else { return }
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for t in tiles { let p = t.coord.pixelCenter; minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        cam.removeAction(forKey: "scrollTo")
        cam.position = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }
    /// Unciv WorldMapHolder.setCenterPosition: the tile's highlight blinks three times (0.3s off, 0.3s on) - also when a
    /// rebuilt world screen then restores its old scroll, so the camera ends up elsewhere
    func blinkTile(_ hex: HexCoord) {
        fxLayer.childNode(withName: "centerBlink")?.removeFromParent()
        let blink = hexOverlay(at: hex, color: .white, alpha: 0.3); blink.name = "centerBlink"
        blink.run(.sequence([.repeat(.sequence([.hide(), .wait(forDuration: 0.3), .unhide(), .wait(forDuration: 0.3)]), count: 3), .removeFromParent()]))
        fxLayer.addChild(blink)
    }

    /// Forget every rendered tile (used when the viewing player changes and fog differs).
    func resetTiles() {
        tileLayer.removeAllChildren(); tileNodes.removeAll(); tileKeys.removeAll(); tileCopies.removeAll()
    }
    /// Unciv MapPanning keys: shift the camera by a few tiles.
    func pan(dx: CGFloat, dy: CGFloat) {
        let speed = CGFloat(UserSettings.mapPanningSpeed) / 2   // Unciv "Map panning speed" 1…12, default 6 = three tiles per key press
        cam.position.x += dx * HexCoord.colStep * speed * cam.xScale
        cam.position.y += dy * HexCoord.rowStep * speed * cam.yScale
        clampCamera()
    }
    /// Unciv ZoomButtonPair: scale the camera by a factor within the pinch limits.
    func zoom(by factor: CGFloat) {
        let s = min(maxZoomOutScale, max(0.18, cam.xScale * factor))
        cam.setScale(s); lastCameraScale = s
        clampCamera()
    }
    /// The yield and worked-tile overlays alone, for the viewing civ - what a city's worked tiles change on the map
    func refreshYieldOverlay() {
        guard let ctrl = controller else { return }
        let viewerId = ctrl.viewCivId
        refreshYieldOverlay(ctrl.state, explored: (ctrl.state.civ(viewerId) ?? ctrl.state.player).explored, viewerId: viewerId)
    }
    /// Unciv WorldMapHolder yield / worked-tile overlays, rebuilt on full refreshes only.
    private func refreshYieldOverlay(_ state: GameState, explored: Set<HexCoord>, viewerId: Int) {
        yieldLayer.removeAllChildren()
        let showYields = UserSettings.showTileYields, showWorked = UserSettings.showWorkedTiles
        let showCoords = UserSettings.debugShowTileCoords, showSettler = UserSettings.debugShowSettlerScores
        if showCoords || showSettler {
            // Unciv DebugTab overlays: hex coordinates and settler-site scores on every explored tile.
            for tile in state.map.tiles where explored.contains(tile.coord) {
                let node = SKNode(); node.position = tile.coord.pixelCenter; node.zPosition = MapScene.zFor(tile.coord) + 0.5
                if showCoords { let l = SKLabelNode(text: "\(tile.coord.q),\(tile.coord.r)"); l.fontSize = 4; l.fontName = "AvenirNext-Bold"; l.fontColor = .white; l.verticalAlignmentMode = .center; l.position = CGPoint(x: 0, y: -9); node.addChild(l) }
                if showSettler, tile.isLand, let score = state.settlerBaseTileMap[viewerId]?[tile.coord] { let l = SKLabelNode(text: String(format: "%.0f", score)); l.fontSize = 4; l.fontName = "AvenirNext-Bold"; l.fontColor = .yellow; l.verticalAlignmentMode = .center; l.position = CGPoint(x: 0, y: 9); node.addChild(l) }
                addWrapped(node, to: yieldLayer)
            }
        }
        guard showYields || showWorked else { return }
        let workedBy: [HexCoord: Int] = Dictionary(state.cities.filter { $0.civId == viewerId }.flatMap { c in c.workedTiles.map { ($0, c.id) } }, uniquingKeysWith: { a, _ in a })
        // Unciv TileLayerYield.updateYieldIcon: every explored tile, city centres included (only the setting gates it)
        for tile in state.map.tiles where explored.contains(tile.coord) {
            let node = SKNode(); node.position = tile.coord.pixelCenter; node.zPosition = MapScene.zFor(tile.coord)
            var added = false
            if showYields {
                let y = state.yields(of: tile, for: viewerId)
                // Unciv YieldGroup.setStats: `for ((stat, amount) in stats) if (amount > 0f) ... amount.toInt()`, in Stat
                // order - Production, Food, Gold, Science, Culture, Happiness, Faith
                var parts: [String] = []
                if y.production > 0 { parts.append("⚙️\(Int(y.production))") }
                if y.food > 0 { parts.append("🍎\(Int(y.food))") }
                if y.gold > 0 { parts.append("💰\(Int(y.gold))") }
                if y.science > 0 { parts.append("🔬\(Int(y.science))") }
                if y.culture > 0 { parts.append("🎵\(Int(y.culture))") }
                if y.happiness > 0 { parts.append("😊\(Int(y.happiness))") }
                if y.faith > 0 { parts.append("🕊\(Int(y.faith))") }
                if !parts.isEmpty {
                    let l = SKLabelNode(text: parts.joined(separator: " ")); l.fontSize = 5; l.fontName = "AvenirNext-Bold"; l.verticalAlignmentMode = .center; l.position = CGPoint(x: 0, y: -4)
                    node.addChild(l); added = true
                }
            }
            if showWorked, workedBy[tile.coord] != nil {
                let w = SKLabelNode(text: "👤"); w.fontSize = 7; w.verticalAlignmentMode = .center; w.position = CGPoint(x: 0, y: 5)
                node.addChild(w); added = true
            }
            if added { addWrapped(node, to: yieldLayer) }
        }
    }

    /// Adds a node and, on wrapping maps, shifted copies to the left and right.
    /// Unciv TileLayerFeatures.updateRoadImages: karonun kendisi de komsusu da gorunmuyorsa o yon yol cizilmez.
    private func roadMask(for tile: Tile, state: GameState, visible: Set<HexCoord>) -> Int {
        var mask = 0
        if tile.railroad { mask |= 1 << 7 }
        if tile.roads { mask |= 1 << 6 }
        let selfVisible = visible.contains(tile.coord)
        for (i, d) in HexCoord.directions.enumerated() {
            let n = state.map.normalize(HexCoord(tile.coord.q + d.q, tile.coord.r + d.r))
            guard selfVisible || visible.contains(n) else { continue }
            if let nt = state.map[n], nt.roads { mask |= 1 << i; if nt.railroad { mask |= 1 << (8 + i) } }
        }
        return mask
    }
    private func addWrapped(_ node: SKNode, to layer: SKNode) {
        layer.addChild(node)
        guard wraps else { return }
        for k in [-1.0, 1.0] { if let dup = node.copy() as? SKNode { dup.position.x += k * mapWidthPx; layer.addChild(dup) } }
    }

    // MARK: rendering
    func refreshAll() {
        let umT = UIMeasure.start(); defer { UIMeasure.stop("scene.refreshAll", umT) }
        longPressRecognizer?.minimumPressDuration = UserSettings.longPressSeconds
        guard let ctrl = controller else { return }
        let state = ctrl.state
        // Unciv WorldScreen.update: mapHolder.updateTiles(getGameViewConsideringForOfWar().civView) - a spectator sees the
        // selected civ's map (its fog), or its own with Fog of War off; everyone else always their own
        let playerId = ctrl.viewCivId
        let viewer = state.civ(playerId) ?? state.player
        let explored = viewer.explored
        let visible = state.visibleTiles(for: playerId)
        let cityEra: [Int: String] = Dictionary(uniqueKeysWithValues: state.civs.map { ($0.id, $0.eraName) })

        // Unciv draws a resource and an improvement twice over: "Show pixel improvements" puts the viewable resource and the
        // shown improvement into the terrain art (TileLayerTerrain.getTileBaseImageLocations), "Show resources and
        // improvements" adds their icons (TileLayerResource / TileLayerImprovement). Only with both off do they vanish.
        // The editor's tile groups are not WorldTileGroups: `if (tileGroup is WorldTileGroup) settings.showResourcesAndImprovements else true`.
        let pix = UserSettings.showPixelImprovements
        let icons = isMapEditor || UserSettings.showResourcesAndImprovements
        // Unciv TileView.isForceVisible: `DebugUtils.VISIBLE_MAP || getCivView()?.isMapRevealed() == true` - a defeated
        // single-player human watching the game out. TileLayerTerrain then asks getViewableResource(null) and
        // TileLayerMisc shows the resource icon whatever the viewer's techs.
        let forceVisible = UserSettings.debugVisibleMap || state.isMapRevealed(viewer)
        for var tile in state.map.tiles {
            let c = tile.coord
            guard explored.contains(c) else { continue }
            let isVisible = visible.contains(c)
            let era = tile.cityId.flatMap { state.city($0) }.flatMap { cityEra[$0.civId] }
            // Unciv TileLayerTerrain / TileLayerResource draw a resource only once the viewing civ has the
            // technology that reveals it - otherwise every iron and horse deposit is legible from turn one.
            if !forceVisible && !state.canSeeResource(tile.resource, civId: playerId) { tile.resource = nil }
            if !isVisible, !tile.isCityCenter { tile.improvement = viewer.lastSeenImprovement[c] }   // Unciv getShownImprovement: the fog shows what we last saw
            let shownImprovement: String? = tile.isCityCenter ? nil : tile.improvement
            // Unciv TileLayerOverlay: the red highlight follows getShownImprovement, whatever the two settings say
            let barbCamp = shownImprovement == Names.barbarianCamp
            // Unciv TileLayerResource: the icon (with its amount and the "provided" star) whenever the setting is on
            let resourceIcon: String? = icons ? tile.resource : nil
            // Unciv TileLayerResource.shouldResourceProvidedBeDisplayed: our own tile, and Tile.providesResources(viewingCiv) -
            // asked of the real tile, not of this copy whose improvement is the fog's or the settings'
            let provides = resourceIcon != nil && tile.ownerCivId == playerId && (state.map[c].map { state.tileProvidesResources($0, civ: viewer) } ?? false)
            // Unciv TileLayerTerrain: without pixel improvements neither the resource nor the improvement is in the art
            if !pix { tile.resource = nil }
            // Unciv TileLayerImprovement: pixel improvements off and icons on → the improvement is drawn as its icon.
            let iconImprovement: String? = (!pix && icons) ? shownImprovement : nil
            if !pix, !tile.isCityCenter { tile.improvement = nil }
            let layers = Art.shared.layers(for: tile, cityEra: era) + (iconImprovement.map { ["icon:" + $0] } ?? [])
                + ((!pix ? resourceIcon : nil).map { ["resicon:" + $0] } ?? [])
            let ownerColor = tile.ownerCivId.flatMap { state.civ($0)?.nationDef?.outerColor } ?? []
            let roadBits = roadMask(for: tile, state: state, visible: visible)
            let startsHere = editorStartingNations(at: c)
            let key = layers.joined(separator: ",") + "|\(isVisible)|\(ownerColor)|\(borderMask(for: tile, state: state))|\(tile.improvementInProgress ?? "")|\(tile.pillaged)|\(tile.roadPillaged)|\(roadBits)|\(resourceIcon == nil ? 0 : tile.resourceAmount)|\(provides)|\(barbCamp)|\(startsHere.joined(separator: ","))"
            if tileKeys[c] == key { continue }
            tileKeys[c] = key
            tileNodes[c]?.removeFromParent()
            tileCopies[c]?.forEach { $0.removeFromParent() }
            let node = buildTileNode(tile, layers: layers, visible: isVisible, state: state, roads: roadBits,
                                     resourceIcon: resourceIcon, provides: provides, barbCamp: barbCamp, startingNations: startsHere)
            tileNodes[c] = node
            tileLayer.addChild(node)
            if wraps {
                var copies: [SKNode] = []
                for k in [-1.0, 1.0] {
                    guard let dup = node.copy() as? SKNode else { continue }
                    dup.position.x += k * mapWidthPx
                    tileLayer.addChild(dup); copies.append(dup)
                }
                tileCopies[c] = copies
            }
        }
        refreshYieldOverlay(state, explored: explored, viewerId: playerId)
        refreshUnits()
    }

    private func borderMask(for tile: Tile, state: GameState) -> Int {
        guard let owner = tile.ownerCivId else { return 0 }
        var mask = 0
        for (i, d) in HexCoord.directions.enumerated() {
            let n = state.map.normalize(HexCoord(tile.coord.q + d.q, tile.coord.r + d.r))
            if state.map[n]?.ownerCivId != owner { mask |= 1 << i }
        }
        return mask
    }

    private static let corners: [CGPoint] = HexCoord.corners
    // direction index -> (cornerA, cornerB): edge d spans corners d-1 and d
    private static let edgeCorners: [(Int, Int)] = (0..<6).map { (($0 + 5) % 6, $0) }
    private static func zFor(_ c: HexCoord) -> CGFloat { -c.pixelCenter.y / HexCoord.rowStep }

    /// Unciv TileLayerTerrain: an unseen tile is tinted Color.WHITE.lerp(fogOfWarColor = CHARCOAL #111111, 0.6), i.e. its
    /// colours times 0.44; blending towards black by 0.56 gives the same product
    static let fogBlend: CGFloat = 1 - (1 - 0.6 * (1 - 17.0 / 255))
    private func buildTileNode(_ tile: Tile, layers: [String], visible: Bool, state: GameState, roads: Int,
                               resourceIcon: String?, provides: Bool, barbCamp: Bool, startingNations: [String]) -> SKNode {
        let node = SKNode()
        node.position = tile.coord.pixelCenter
        node.zPosition = MapScene.zFor(tile.coord)
        var z: CGFloat = 0
        var isBaseLayer = true   // Unciv TileLayerTerrain: taban zemin gorseli ustteki katmanlardan farkli renklenir
        for name in layers {
            if name.hasPrefix("icon:") {
                guard let tex = Art.shared.texture(String(name.dropFirst(5)), folder: "ImprovementIcons") else { continue }
                let icon = SKSpriteNode(texture: tex); icon.size = CGSize(width: 12, height: 12); icon.position = CGPoint(x: 0, y: -4); icon.zPosition = z; z += 0.01
                if !visible { icon.color = .black; icon.colorBlendFactor = MapScene.fogBlend }
                node.addChild(icon); continue
            }
            if name.hasPrefix("resicon:") { continue }   // the resource portrait, drawn over the roads below
            guard let tex = Art.shared.texture(name) else { continue }
            let s = SKSpriteNode(texture: tex)
            if name.hasPrefix("City center") { s.name = "cityicon" }   // Unciv layerImprovement.improvementIcon, used by battleAnimation
            s.anchorPoint = CGPoint(x: 0.5, y: 0)
            s.position = CGPoint(x: 0, y: -HexCoord.imageHeight / 2)
            s.size = MapScene.hexImageSize(tex)
            s.zPosition = z; z += 0.01
            if !visible { s.color = .black; s.colorBlendFactor = MapScene.fogBlend }
            else if tile.pillaged || tile.roadPillaged {   // Unciv Tile.isPillaged: improvement or road
                s.color = isBaseLayer ? UIColor(red: 0.5, green: 0.25, blue: 0.1, alpha: 1) : .red
                s.colorBlendFactor = isBaseLayer ? 0.6 : 0.5
            }
            isBaseLayer = false
            node.addChild(s)
        }
        for d in tile.riverEdges {
            let edge = d == HexCoord.dirS ? "Bottom" : d == HexCoord.dirSE ? "BottomRight" : "BottomLeft"
            let name = Art.shared.hd ? "hd:river:" + edge : "River-" + edge
            guard let tex = Art.shared.texture(name) else { continue }
            let s = SKSpriteNode(texture: tex)
            s.anchorPoint = CGPoint(x: 0.5, y: 0)
            s.position = CGPoint(x: 0, y: -HexCoord.imageHeight / 2)
            s.size = MapScene.hexImageSize(tex)
            s.zPosition = z; z += 0.01
            if !visible { s.color = .black; s.colorBlendFactor = MapScene.fogBlend }
            node.addChild(s)
        }
        // Unciv TileLayerFeatures.updateRoadImages: toward every neighbour where both tiles have a road, the tileset's Road
        // (Railroad when both are railroads) image, 10 x 6 world units, starting halfway to the neighbour (0.8 x 25 along
        // the neighbour's world vector) and pointing back at this tile's centre. The neighbour draws the other half.
        if tile.roads {
            for (i, d) in HexCoord.directions.enumerated() {
                guard roads & (1 << i) != 0 else { continue }   // no road where neither this tile nor the neighbour is visible
                let n = state.map.normalize(HexCoord(tile.coord.q + d.q, tile.coord.r + d.r))
                guard let nt = state.map[n], nt.roads else { continue }
                let rail = tile.railroad && nt.railroad
                guard let tex = Art.shared.texture(Art.shared.hd ? (rail ? "hd:railroad" : "hd:road") : (rail ? "Railroad" : "Road"), folder: "Roads") else { continue }
                let target = HexCoord(tile.coord.q + d.q, tile.coord.r + d.r).pixelCenter
                let mid = CGPoint(x: (target.x - tile.coord.pixelCenter.x) / 2, y: (target.y - tile.coord.pixelCenter.y) / 2)
                let s = SKSpriteNode(texture: tex)
                s.anchorPoint = CGPoint(x: 0, y: 0.5)
                s.size = CGSize(width: 10 * MapScene.uncivWorldUnit, height: 6 * MapScene.uncivWorldUnit)
                s.position = mid
                s.zRotation = atan2(-mid.y, -mid.x)
                s.zPosition = z + 0.05 + CGFloat(i) * 0.001
                if !visible { s.color = .black; s.colorBlendFactor = MapScene.fogBlend }
                node.addChild(s)
            }
        }
        // Unciv draws no marker for an improvement in progress, and a pillaged tile is only tinted (TileLayerTerrain.updateTileColor)
        // Unciv TileLayerResource: ImageGetter.getResourcePortrait, left of and above the centre, dimmed to 0.5 out of sight -
        // drawn as an icon only when the resource is not already in the art (pixel improvements off)
        if let r = resourceIcon, layers.contains("resicon:" + r), let tex = Art.shared.texture(r, folder: "ResourceIcons") {
            let icon = SKSpriteNode(texture: tex); icon.size = CGSize(width: 8, height: 8); icon.position = CGPoint(x: -4, y: 3.5); icon.zPosition = z + 0.09
            if !visible { icon.alpha = 0.5 }
            node.addChild(icon)
        }
        // Unciv PortraitResource: amount > 0 olan kaynak ikonu daire icinde miktar rozeti tasir (ikon katmaninin parcasi)
        if resourceIcon != nil, tile.resourceAmount > 0 {
            let badge = SKShapeNode(circleOfRadius: 3.4)
            badge.fillColor = UIColor(white: 0.1, alpha: 0.85); badge.strokeColor = UIColor(white: 0.85, alpha: 0.7); badge.lineWidth = 0.3
            badge.position = CGPoint(x: -8.5, y: 5.5); badge.zPosition = z + 0.1
            let amt = SKLabelNode(fontNamed: "AvenirNext-Bold")
            amt.text = "\(tile.resourceAmount)"; amt.fontSize = 4.5; amt.fontColor = .white; amt.verticalAlignmentMode = .center
            amt.position = badge.position; amt.zPosition = z + 0.11
            if !visible { badge.alpha = 0.55; amt.alpha = 0.55 }
            node.addChild(badge); node.addChild(amt)
        }
        // Unciv TileLayerResource: a resource of our own tile that the empire gets (Tile.providesResources) carries a
        // 12-unit black OtherIcons/Star under a 10-unit gold one, jutting out of the portrait's top right; not dimmed
        if resourceIcon != nil, provides, let star = Art.shared.texture("Star", folder: "OtherIcons") {
            let back = SKSpriteNode(texture: star); back.size = CGSize(width: 5, height: 5); back.color = .black; back.colorBlendFactor = 1
            back.position = CGPoint(x: -1, y: 8); back.zPosition = z + 0.115
            let gold = SKSpriteNode(texture: star); gold.size = CGSize(width: 4.2, height: 4.2); gold.color = UIColor(red: 1, green: 0.843, blue: 0, alpha: 1); gold.colorBlendFactor = 1   // Color.GOLD
            gold.position = back.position; gold.zPosition = z + 0.116
            node.addChild(back); node.addChild(gold)
        }
        // Unciv TileLayerOverlay: barbar kampi esdegeri bir gelistirme varsa karo kirmizi vurgulanir - getShownImprovement'a
        // bakar, ayarlar gelistirmeyi gizlese de.
        if barbCamp {
            let p = CGMutablePath(); p.addLines(between: MapScene.corners); p.closeSubpath()
            let highlight = SKShapeNode(path: p)
            highlight.fillColor = .red; highlight.strokeColor = .clear; highlight.alpha = 0.3; highlight.zPosition = z + 0.12
            node.addChild(highlight)
        }
        if let owner = tile.ownerCivId, let nation = state.civ(owner)?.nationDef {
            let color = UIColor(rgb: nation.outerColor)
            let mask = borderMask(for: tile, state: state)
            let path = CGMutablePath()
            for (i, edge) in MapScene.edgeCorners.enumerated() where mask & (1 << i) != 0 {
                path.move(to: MapScene.corners[edge.0]); path.addLine(to: MapScene.corners[edge.1])
            }
            if !path.isEmpty {
                // Unciv TileLayerBorders draws two images per edge, not one: an inner in the nation's outer
                // colour and an outer in its inner colour. The pair is what makes a border legible whatever the
                // terrain under it - a single line in one of the two disappears whenever the nation and the
                // ground share a hue, which is why China's border was invisible on grass.
                let backing = SKShapeNode(path: path)
                backing.strokeColor = UIColor(rgb: nation.innerColor ?? [255, 255, 255])
                backing.lineWidth = 3.4; backing.lineCap = .round; backing.zPosition = z + 0.19
                backing.alpha = visible ? 0.95 : 0.5
                node.addChild(backing)
                let shape = SKShapeNode(path: path)
                shape.strokeColor = color; shape.lineWidth = 1.8; shape.lineCap = .round; shape.zPosition = z + 0.2
                shape.alpha = visible ? 0.95 : 0.5
                node.addChild(shape)
            }
            let fill = SKShapeNode(path: { let p = CGMutablePath(); p.addLines(between: MapScene.corners); p.closeSubpath(); return p }())
            fill.fillColor = color; fill.strokeColor = .clear; fill.alpha = 0.10; fill.zPosition = z + 0.15
            node.addChild(fill)
        }
        // Unciv TileLayerMisc.updateStartingLocationIcon: up to three nation portraits, 20 units at alpha 0.6, the third
        // drawn first at ((n-1)*4, (n-1)*2) from the centre and each next one (-8, -4) further, so the first sits on top;
        // more than three add the count in FIREBRICK over a CHARCOAL (0.7) shadow
        if !startingNations.isEmpty {
            let u = MapScene.uncivWorldUnit
            let shown = min(startingNations.count, 3)
            var ox = CGFloat(shown - 1) * 4, oy = CGFloat(shown - 1) * 2
            var sz = z + 0.3
            for name in startingNations.prefix(3).reversed() {
                let portrait = MapScene.nationPortrait(name, size: 20 * u)
                portrait.position = CGPoint(x: ox * u, y: oy * u); portrait.alpha = 0.6; portrait.zPosition = sz; sz += 0.01
                node.addChild(portrait)
                ox -= 8; oy -= 4
            }
            if startingNations.count > 3 {
                for (color, dx, dy) in [(UIColor(white: 17.0 / 255, alpha: 0.7), 14.4, -9.0), (UIColor(red: 0.698, green: 0.133, blue: 0.133, alpha: 1), 14.0, -8.4)] {
                    let l = SKLabelNode(fontNamed: "AvenirNext-Bold"); l.text = "\(startingNations.count)"; l.fontSize = 14 * u; l.fontColor = color
                    l.verticalAlignmentMode = .center; l.position = CGPoint(x: CGFloat(dx) * u, y: CGFloat(dy) * u); l.zPosition = sz; sz += 0.01
                    node.addChild(l)
                }
            }
        }
        return node
    }

    /// Unciv TileMapView.getStartingLocationNationNames and updateStartingLocationIcon's list: the nations starting on the
    /// tile (the editor's "Any Civ" entry is Spectator), those the ruleset lacks dropped, sorted by (isCityState, name)
    private func editorStartingNations(at c: HexCoord) -> [String] {
        guard isMapEditor, !editorStartingLocations.isEmpty else { return [] }
        let rs = Ruleset.shared
        var names: [String] = []
        for sl in editorStartingLocations where sl.position == c {
            let name = sl.nation.isEmpty ? "Spectator" : sl.nation
            if !names.contains(name) { names.append(name) }
        }
        return names.compactMap { n in rs.nations[n].map { (name: n, isCityState: $0.isCityState) } }
            .sorted { a, b in a.isCityState != b.isCityState ? !a.isCityState : a.name < b.name }
            .map { $0.name }
    }

    /// Unciv PortraitNation: the nation's icon (NationIcons/CityState for a city-state without its own) on a disc of its
    /// outer colour ringed in its inner colour; a nation without any icon keeps the bare disc
    private static func nationPortrait(_ name: String, size: CGFloat) -> SKNode {
        let node = SKNode()
        let def = Ruleset.shared.nations[name]
        let ring = SKShapeNode(circleOfRadius: size / 2)
        ring.fillColor = def?.innerColor.map { UIColor(rgb: $0) } ?? .white; ring.strokeColor = .clear
        let disc = SKShapeNode(circleOfRadius: size / 2 * 0.9)
        disc.fillColor = def.map { UIColor(rgb: $0.outerColor) } ?? UIColor(white: 17.0 / 255, alpha: 1); disc.strokeColor = .clear
        node.addChild(ring); node.addChild(disc)
        let tex = Art.shared.texture(name, folder: "NationIcons")
            ?? ((def?.isCityState ?? false) ? Art.shared.texture("CityState", folder: "NationIcons") : nil)
        if let tex {
            let icon = SKSpriteNode(texture: tex); icon.size = CGSize(width: size * 0.7, height: size * 0.7)
            node.addChild(icon)
        }
        return node
    }

    // MARK: city buttons and unit art, drawn again piece by piece
    /// A layer drawn in pieces - a city's button, a unit's art - each kept with the model it was drawn from and with its
    /// world-wrap copies. refreshUnits hands over every piece's model in the order the layer is filled: a piece whose
    /// model is unchanged keeps its nodes, any other is drawn again in its place, so the layer holds the very nodes a
    /// drawing from nothing gives, in the same order. Unciv draws them anew on every update (CityButton.update clears its
    /// table, TileLayerUnitFlag.clearSlots makes a new UnitIconGroup), which costs libGDX next to nothing; a city button
    /// of SKShapeNodes and SKLabelNodes does not come that cheap, and redrawing every one on every tap held the main
    /// thread for a tenth of a second late in a game. What a piece looks like is its model and nothing else.
    private final class PieceLayer<Model: Equatable> {
        let layer: SKNode
        private var order: [Int] = []
        private var pieces: [Int: (model: Model, nodes: [SKNode])] = [:]
        /// drawn again at the next sync whatever their model says (a battle animation moved and tinted their nodes)
        var redraw: Set<Int> = []
        init(_ layer: SKNode) { self.layer = layer }
        func sync(_ wanted: [(id: Int, model: Model)], build: (Model) -> [SKNode]) {
            let redraw = self.redraw
            self.redraw = []
            let ids = Set(wanted.map(\.id))
            for id in order where !ids.contains(id) { pieces.removeValue(forKey: id)?.nodes.forEach { $0.removeFromParent() } }
            // the layer's children are the nodes of `old` from `j` on, after the `cursor` nodes of the pieces already placed
            var old = order.filter { ids.contains($0) }
            var j = 0, cursor = 0
            var newOrder: [Int] = []
            newOrder.reserveCapacity(wanted.count)
            for (id, model) in wanted {
                func place(_ nodes: [SKNode]) { for (k, n) in nodes.enumerated() { layer.insertChild(n, at: cursor + k) } }
                if let p = pieces[id] {
                    let inPlace = j < old.count && old[j] == id
                    if inPlace { j += 1 } else if let k = old[j...].firstIndex(of: id) { old.remove(at: k) }
                    if p.model == model && !redraw.contains(id) {
                        if !inPlace { p.nodes.forEach { $0.removeFromParent() }; place(p.nodes) }
                    } else {
                        p.nodes.forEach { $0.removeFromParent() }
                        let nodes = build(model)
                        place(nodes)
                        pieces[id] = (model, nodes)
                    }
                } else {
                    let nodes = build(model)
                    place(nodes)
                    pieces[id] = (model, nodes)
                }
                cursor += pieces[id]?.nodes.count ?? 0
                newOrder.append(id)
            }
            order = newOrder
        }
    }
    /// A texture compared by identity: Art hands out one SKTexture per image, and a new one once its cache is emptied
    private struct TextureRef: Equatable {
        let texture: SKTexture?
        static func == (a: Self, b: Self) -> Bool { a.texture === b.texture }
    }
    /// Everything a city button shows (Unciv CityButton: CityTable, DefenceTable, StatusTable, InfluenceTable, the health
    /// bar) and where it stands
    private struct CityButtonModel: Equatable {
        var id: Int
        var coord: HexCoord
        var wrap: CGFloat?          // the world's width on a world-wrap map: the button's two shifted copies
        var label: String
        var labelColor: [Int]
        var fill: [Int]
        var frame: Int              // CityTable's border: 1 the selected civ's city, 2 at war with it, 0 the dark one
        var civIcon: TextureRef     // CityTable.addCivIcon beside a city that is not the viewer's
        var civIconTint: [Int]?     // a city-state's icon, in its inner colour
        var strength: String
        var strengthFrame: Int      // DefenceTable.bgBorderColor: 1 the viewer's city, 2 at war with the viewer, 0 none
        var detail: String?         // CityTable isShowDetailedInfo: growth and production
        var status: String?
        var hurt: Bool
        var influence: CGFloat?     // InfluenceTable: the influence over 60, clamped
        var influenceLevel: Int     // its colour: 0 unforgivable, 1 enemy, 2 afraid, 3 neutral or friend, 4 ally, 5 other
        var health: CGFloat?        // the health bar of a hurt city we see
        var wasDown: Bool
        var isDown: Bool
        var fireworks: Bool
    }
    /// Everything a unit's art shows (Unciv TileLayerUnitSprite, and TileLayerUnitFlag's UnitIconGroup) and where it stands
    private struct UnitArtModel: Equatable {
        var id: Int
        var coord: HexCoord
        var wrap: CGFloat?
        var stack: Int              // its place among the units drawn on its tile
        var texture: TextureRef
        var outer: [Int]
        var inner: [Int]
        var flagAlpha: CGFloat
        var hd: Bool
        var health: Int
        var fortified: Bool
        var badgeIcon: TextureRef
        var badgeEmoji: String?
        var enemy: Bool
        var air: Int?
        var selected: Bool
        var glowing: Bool
        var walking: Bool
    }
    private lazy var cityButtons = PieceLayer<CityButtonModel>(labelLayer)
    private lazy var unitArt = PieceLayer<UnitArtModel>(unitLayer)

    /// A node and, on a world-wrap map, its copies shifted a world's width to the left and right (addWrapped)
    private static func wrapped(_ node: SKNode, _ wrap: CGFloat?) -> [SKNode] {
        guard let w = wrap else { return [node] }
        var out = [node]
        for k in [-1.0, 1.0] { if let dup = node.copy() as? SKNode { dup.position.x += k * w; out.append(dup) } }
        return out
    }

    private static func makeCityButton(_ m: CityButtonModel) -> [SKNode] {
        let banner = SKNode()
        banner.name = "citybanner\(m.id)"   // Unciv CityButton: its own touch target (handleTap)
        banner.position = m.coord.pixelCenter
        banner.zPosition = MapScene.zFor(m.coord)
        let label = SKLabelNode(fontNamed: "AvenirNext-Bold")
        label.text = m.label
        label.fontSize = 7; label.fontColor = UIColor(rgb: m.labelColor)
        label.verticalAlignmentMode = .center
        let bg = SKShapeNode(rectOf: CGSize(width: label.frame.width + 8, height: 10), cornerRadius: 2)
        // Unciv CityTable: kendi sehrimize #E9E9AC, bizimle savasta olan sehre #E63200, digerlerine koyu cerceve.
        bg.fillColor = UIColor(rgb: m.fill).withAlphaComponent(0.9)
        bg.strokeColor = m.frame == 1 ? UIColor(red: 0.914, green: 0.914, blue: 0.675, alpha: 1)
            : m.frame == 2 ? UIColor(red: 0.902, green: 0.196, blue: 0, alpha: 1) : UIColor(white: 0.13, alpha: 1)
        bg.lineWidth = m.frame != 0 ? 1 : 0.5
        bg.position = CGPoint(x: 0, y: 20); label.position = CGPoint(x: 0, y: 20)
        banner.addChild(bg); banner.addChild(label)
        // Unciv CityTable.addCivIcon: sehir bizim degilse adin sagina - buyuk uygarlikta ulus portresi, digerinde
        // CityStateIcons/<city.getCityStateTypeName()>, ic renkle boyanmis
        if let flag = m.civIcon.texture {
            let icon = SKSpriteNode(texture: flag); icon.size = CGSize(width: 9, height: 9)
            icon.position = CGPoint(x: bg.frame.width / 2 + 5.5, y: 20)
            if let tint = m.civIconTint { icon.color = UIColor(rgb: tint); icon.colorBlendFactor = 1 }
            banner.addChild(icon)
        }
        // Unciv CityButton: DefenceTable (strength) above, StatusTable icons, AirUnitTable and, for city-states, the InfluenceTable below.
        let strength = SKLabelNode(fontNamed: "AvenirNext-Bold")
        strength.text = m.strength; strength.fontSize = 5; strength.fontColor = .white; strength.verticalAlignmentMode = .center
        strength.position = CGPoint(x: 0, y: 27.5)
        let strengthBg = SKShapeNode(rectOf: CGSize(width: strength.frame.width + 4, height: 6), cornerRadius: 1.5); strengthBg.fillColor = UIColor(white: 0.13, alpha: 0.9); strengthBg.position = strength.position
        // Unciv DefenceTable.bgBorderColor: kendi sehir krem, bizimle savasta olan sehir kirmizi, digerleri cercevesiz.
        strengthBg.strokeColor = m.strengthFrame == 1 ? UIColor(red: 1, green: 0.929, blue: 0.784, alpha: 1) : m.strengthFrame == 2 ? .red : .clear
        strengthBg.lineWidth = 0.6
        banner.addChild(strengthBg); banner.addChild(strength)
        if let detail = m.detail {
            let prod = SKLabelNode(fontNamed: "AvenirNext-Bold")
            prod.text = detail; prod.fontSize = 4.5; prod.fontColor = .white; prod.verticalAlignmentMode = .center
            prod.position = CGPoint(x: 0, y: 14.5)
            let pbg = SKShapeNode(rectOf: CGSize(width: prod.frame.width + 4, height: 5.5), cornerRadius: 1.5)
            pbg.fillColor = UIColor(white: 0.13, alpha: 0.85); pbg.strokeColor = .clear; pbg.position = prod.position
            banner.addChild(pbg); banner.addChild(prod)
        }
        if let status = m.status {
            let st = SKLabelNode(fontNamed: "AvenirNext-Bold"); st.text = status; st.fontSize = 5; st.verticalAlignmentMode = .center
            st.position = CGPoint(x: 0, y: m.hurt ? 10 : 13)
            let stBg = SKShapeNode(rectOf: CGSize(width: st.frame.width + 4, height: 6), cornerRadius: 1.5); stBg.fillColor = UIColor(white: 0.13, alpha: 0.85); stBg.strokeColor = .clear; stBg.position = st.position
            banner.addChild(stBg); banner.addChild(st)
        }
        if let frac = m.influence {
            // Unciv InfluenceTable: renk sehir devletinin bize karsi RelationshipLevel'idir, cubuk ±60'ta kirpilir.
            let w: CGFloat = 26
            let back = SKShapeNode(rectOf: CGSize(width: w, height: 2)); back.fillColor = UIColor(white: 0.25, alpha: 1); back.strokeColor = .clear; back.position = CGPoint(x: 0, y: 6)
            let color: UIColor = {
                switch m.influenceLevel {
                case 0: return .red
                case 1: return .orange
                case 2: return .yellow
                case 3: return UIColor(red: 0.6, green: 1, blue: 0, alpha: 1)      // Color.LIME
                case 4: return UIColor(red: 0.5, green: 0.72, blue: 1, alpha: 1)   // Color.SKY
                default: return UIColor(white: 0.35, alpha: 1)                     // Color.DARK_GRAY
                }
            }()
            let fill = SKShapeNode(rectOf: CGSize(width: max(0.5, w / 2 * abs(frac)), height: 2)); fill.fillColor = color; fill.strokeColor = .clear
            fill.position = CGPoint(x: frac >= 0 ? w / 4 * frac : w / 4 * frac, y: 6)
            banner.addChild(back); banner.addChild(fill)
        }
        if let frac = m.health {   // Unciv CityButton: only for a city we can see, getHealthBar(getHealth(), getMaxHealth())
            let w: CGFloat = 26
            let back = SKShapeNode(rectOf: CGSize(width: w, height: 2)); back.fillColor = .darkGray; back.strokeColor = .clear; back.position = CGPoint(x: 0, y: 13)
            let fg = SKShapeNode(rectOf: CGSize(width: w * frac, height: 2)); fg.fillColor = frac > 2.0 / 3 ? .green : frac > 1.0 / 3 ? .orange : .red; fg.strokeColor = .clear; fg.position = CGPoint(x: -(w - w * frac) / 2, y: 13)
            banner.addChild(back); banner.addChild(fg)
        }
        // Unciv CityButton.moveButtonDown / moveButtonUp: a tapped (selected) city's button drops by its own
        // height over 0.4s with Interpolation.swingOut, and rises back over 0.4s (sine) once deselected. The model holds
        // where it was and where it goes: the refresh after the move draws it again where it came to rest. Unciv moves
        // each button to its own tile group's x (`Actions.moveTo(tileGroup.x, tileGroup.y - height)`); the world-wrap
        // copies here are node copies that run the same action, so it moves y alone and each copy keeps its own x,
        // a world's width from the button, where move(to:) with the button's own point would carry them onto it.
        let upPos = m.coord.pixelCenter
        let downPos = CGPoint(x: upPos.x, y: upPos.y - banner.calculateAccumulatedFrame().height)
        banner.position = m.wasDown ? downPos : upPos
        if m.isDown != m.wasDown {
            let a = SKAction.moveTo(y: (m.isDown ? downPos : upPos).y, duration: 0.4)
            a.timingFunction = m.isDown ? MapScene.swingOut : MapScene.sine
            banner.run(a)
        }
        var nodes = wrapped(banner, m.wrap)
        if m.fireworks {
            let fx = MapScene.fireworks(); fx.position = CGPoint(x: m.coord.pixelCenter.x, y: m.coord.pixelCenter.y + 18); fx.zPosition = 3000
            nodes += wrapped(fx, m.wrap)
        }
        return nodes
    }

    private static func makeUnitArt(_ m: UnitArtModel) -> [SKNode] { wrapped(makeUnitSprite(m), m.wrap) }
    private static func makeUnitSprite(_ m: UnitArtModel) -> SKSpriteNode {
        let tex = m.texture.texture
        let texSize = tex?.size() ?? .zero
        // Unciv ImagePacker: every atlas is filtered MipMapLinearLinear, so the art is drawn smoothed, not as square pixels.
        // A dark copy a pixel behind it lifts it off the terrain.
        let shadow = SKSpriteNode(texture: tex)
        shadow.size = CGSize(width: texSize.width * 0.8, height: texSize.height * 0.8)
        shadow.anchorPoint = CGPoint(x: 0.5, y: 0)
        shadow.color = .black; shadow.colorBlendFactor = 1; shadow.alpha = 0.45
        shadow.position = CGPoint(x: 0.7, y: -0.7)
        shadow.name = "shadow"   // part of the art: it walks and lunges with the unit, unlike the flag and badges
        let sprite = SKSpriteNode(texture: tex)
        sprite.name = "u\(m.id)"   // the battle animation finds the attacker by name, not by guessing at its position
        sprite.size = CGSize(width: texSize.width * 0.8, height: texSize.height * 0.8)
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        sprite.addChild(shadow); shadow.zPosition = -0.05
        let n = CGFloat(m.stack)
        sprite.position = CGPoint(x: m.coord.pixelCenter.x + n * 6, y: m.coord.pixelCenter.y - 9 + n * 3)
        sprite.zPosition = MapScene.zFor(m.coord) + n * 0.1
        // Civ colour flag
        let flag = SKShapeNode(circleOfRadius: 3.2)
        flag.fillColor = UIColor(rgb: m.outer); flag.strokeColor = UIColor(rgb: m.inner); flag.lineWidth = 0.6
        flag.alpha = m.flagAlpha   // Unciv "Unit icon opacity", half faded for a unit of ours out of movement (UnitIconGroup)
        flag.position = CGPoint(x: -11, y: 22); flag.zPosition = 0.5
        if m.hd {
            // the medallion is the flag: it takes the opacity and the out-of-movement fade, and the rings centre on it
            sprite.alpha = flag.alpha
            flag.isHidden = true
            flag.position = CGPoint(x: 0, y: 10.2)
        }
        sprite.addChild(flag)
        if m.health < 100 {
            let w: CGFloat = 18
            let back = SKShapeNode(rectOf: CGSize(width: w, height: 1.6)); back.fillColor = .darkGray; back.strokeColor = .clear; back.position = CGPoint(x: 0, y: -2)
            let frac = CGFloat(m.health) / 100
            let fg = SKShapeNode(rectOf: CGSize(width: w * frac, height: 1.6)); fg.fillColor = frac > 2.0 / 3 ? .green : frac > 1.0 / 3 ? .orange : .red; fg.strokeColor = .clear; fg.position = CGPoint(x: -(w - w * frac) / 2, y: -2)
            // Unciv UnitIconGroup: ImageGetter.getHealthBar, drawn as it stands (the animated bar is the BattleTable's)
            sprite.addChild(back); sprite.addChild(fg)
        }
        // Unciv UnitIconGroup.getBackgroundDrawableForUnit: a fortified or guarding unit's flag takes the UnitFlagFortify
        // shape, for every viewer - drawn here as a shield beside the flag, apart from the action image below.
        if m.fortified { let f = SKLabelNode(text: "🛡"); f.fontSize = 7; f.position = CGPoint(x: -11, y: 14); sprite.addChild(f) }
        if let tex = m.badgeIcon.texture {
            let disc = SKShapeNode(circleOfRadius: 4); disc.fillColor = UIColor(white: 0.13, alpha: 0.9); disc.strokeColor = .white; disc.lineWidth = 0.4
            disc.position = CGPoint(x: 11, y: 22.5); sprite.addChild(disc)
            let icon = SKSpriteNode(texture: tex); icon.size = CGSize(width: 6, height: 6); disc.addChild(icon)
        } else if let e = m.badgeEmoji {
            let f = SKLabelNode(text: e); f.fontSize = 6; f.position = CGPoint(x: 11, y: 20); sprite.addChild(f)
        }
        if m.enemy {
            let ring = SKShapeNode(circleOfRadius: m.hd ? 10.6 : 6.5)   // Unciv highlightRed: an enemy's unit is ringed
            ring.strokeColor = UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 0.95); ring.lineWidth = 1; ring.fillColor = .clear
            ring.position = flag.position; sprite.addChild(ring)
        }
        if let air = m.air {
            let a = SKLabelNode(text: "✈\(air)"); a.fontSize = 5; a.fontColor = .white; a.position = CGPoint(x: -11, y: 20); sprite.addChild(a)
        }
        if m.selected {
            // Unciv rings the selected unit itself, not only its tile: the tile highlight alone reads as one
            // more green circle among the ruins and wonders that use the same shape.
            let ring = SKShapeNode(circleOfRadius: m.hd ? 11 : 8)
            ring.strokeColor = .white; ring.lineWidth = 1.6; ring.fillColor = .clear
            ring.position = m.hd ? flag.position : CGPoint(x: 0, y: 8); ring.zPosition = -0.1
            let halo = SKShapeNode(circleOfRadius: m.hd ? 12.2 : 9.2)
            halo.strokeColor = UIColor(white: 0, alpha: 0.65); halo.lineWidth = 2.4; halo.fillColor = .clear
            halo.position = ring.position; halo.zPosition = -0.2
            sprite.addChild(halo); sprite.addChild(ring)
            // Unciv UnitIconGroup.selectUnit: the flag's selection glow (1, 1, 0.9) behind the flag - 0.8 alpha, or
            // with continuous rendering fading to 0 over 1s and back over 1s, forever. The unit itself stays still.
            let glow = SKShapeNode(circleOfRadius: m.hd ? 11.5 : 5)
            glow.fillColor = UIColor(red: 1, green: 1, blue: 0.9, alpha: 1); glow.strokeColor = .clear
            glow.position = flag.position; glow.zPosition = m.hd ? -0.3 : flag.zPosition - 0.01   // behind the medallion
            sprite.addChild(glow)
            if m.glowing {
                glow.alpha = 1
                glow.run(.repeatForever(.sequence([.fadeAlpha(to: 0, duration: 1), .fadeAlpha(to: 1, duration: 1)])))
            } else { glow.alpha = 0.8 }
        }
        // a unit whose art is still walking (Unciv animateMovement) is not drawn at its destination
        if m.walking {
            sprite.texture = nil; sprite.color = .clear; sprite.colorBlendFactor = 1
            sprite.childNode(withName: "shadow")?.isHidden = true
        }
        return sprite
    }

    func refreshUnits() {
        let umT = UIMeasure.start(); defer { UIMeasure.stop("scene.refreshUnits", umT) }
        guard let ctrl = controller else { return }
        let state = ctrl.state
        overlayLayer.removeAllChildren()
        // Unciv TileGroup.update(viewingCiv): the civ of getGameViewConsideringForOfWar() (the selected civ's, or with Fog of
        // War off the spectator's own); CityTable's own checks read GUI.getSelectedPlayer() - worldScreen.selectedCiv
        let viewerId = ctrl.viewCivId
        let viewer = state.civ(viewerId) ?? state.player
        let selectedId = ctrl.selectedCivId
        let visible = state.visibleTiles(for: viewerId)
        let explored = viewer.explored
        let wrap: CGFloat? = wraps ? mapWidthPx : nil
        let shown = state.visibleUnits(for: viewerId)
        // Unciv CityButton's AirUnitTable: the air units we see in a city we see
        var airInCity: [HexCoord: Int] = [:]
        for u in shown where u.def.isAir { airInCity[u.coord, default: 0] += 1 }

        // Cities: banner with name, population and health bar
        var newBannersDown: Set<Int> = []
        defer { bannersDown = newBannersDown }
        var buttons: [(id: Int, model: CityButtonModel)] = []
        for city in state.cities where explored.contains(city.coord) {
            guard let nation = state.civ(city.civId)?.nationDef else { continue }
            let atWarWithUs = city.civId != selectedId && state.areAtWar(selectedId, city.civId)
            var civIcon: SKTexture? = nil, civIconTint: [Int]? = nil
            if city.civId != viewerId, let owner = state.civ(city.civId) {
                let isMajor = !owner.isCityState
                civIcon = isMajor ? Art.shared.texture(nation.name, folder: "NationIcons")
                    : owner.cityStateType.flatMap { Art.shared.texture($0, folder: "CityStateIcons") }
                if civIcon != nil, !isMajor { civIconTint = nation.innerColor ?? [255, 255, 255] }
            }
            // Unciv CityTable: isShowDetailedInfo = DebugUtils.VISIBLE_MAP || city.belongsTo(selectedCiv) || viewingCiv.isSpectator().
            // Its growth and construction turns read the city's stored stats (City.foodForNextTurn is
            // `cityStats.currentCityStats.food`, CityConstructions.turnsToConstruction its production) - the ones the last
            // CityStats.update left; recomputing them here took 6 ms a city late in a game, and computeStats(for:) is that
            // update, which may stop a city working a blockaded tile (updateTileStats) - not something drawing the map does.
            var detail: String? = nil
            if city.civId == selectedId || viewer.isSpectator || UserSettings.debugVisibleMap {
                let cs = state.currentCityStats(city.id)
                var line: [String] = []
                // Unciv CityTable.addCityGrowthBar: isGrowing and isStarving read City.foodForNextTurn (the stored food,
                // rounded), and CityPopulationManager.getNumTurnsToNewPopulation counts it against the city's live
                // foodStored and getFoodToNextPopulation - food banked since the last CityStats.update (a spectated AI
                // city's endTurn, a pillage's or a removed terrain feature's Food) counts at once; 100 turns or more read ∞
                let food = cs.foodForNextTurn
                if food < 0 { line.append("🍎↓") }
                else if food > 0 {
                    let grow = max(1, Int(((state.growthCost(city) - city.foodStored) / food).rounded(.up)))
                    line.append(grow < 100 ? "🍎\(grow)" : "🍎∞")
                } else { line.append("🍎–") }
                if let p = city.currentProduction { line.append("🔨\(state.turnsToComplete(city).map(String.init) ?? "–") \(L(p.name).prefix(9))") }
                // Unciv CityTable.addCityConstruction: Idle turns "-", another perpetual "∞"; an empty queue has no portrait and "-"
                else if city.convertProductionTo == City.idleConstruction { line.append("🔨– \(L(city.convertProductionTo).prefix(9))") }
                else if !city.convertProductionTo.isEmpty { line.append("🔨∞ \(L(city.convertProductionTo).prefix(9))") }
                else { line.append("🔨–") }
                detail = line.joined(separator: "  ")
            }
            let maxHP = state.cityMaxHealth(city)   // Unciv CityButton: foreignCityView.getMaxHealth() = City.getMaxHealth(), walls and all
            var status: [String] = []
            if city.isCapital { status.append("★") }
            if city.isPuppet { status.append("🎭") }
            if city.resistanceTurns > 0 { status.append("✊") }
            if city.razing { status.append("🔥") }
            if city.civId == viewerId, city.isCelebrating { status.append("🎉") }   // Unciv StatusTable: WLTKD yalnizca kendi sehrimizde
            if city.civId == viewerId, state.isCityBlockaded(city) { status.append("⛔") }   // Unciv StatusTable: Blockade yalnizca kendi sehrimizde
            if city.civId == viewerId, !city.isCapital, state.isCapitalConnected(to: city, civId: city.civId) { status.append("🛤") }   // Unciv StatusTable: CityConnection
            if let r = state.majorityReligion(of: city) { status.append(r.prefix(1).uppercased()) }   // Unciv CityTable.addCityText: din ikonu her sehir bayraginda
            // Unciv CityButton: rozet yalnizca gordugumuz bir sehirde ve yalnizca gordugumuz hava birimleri icin
            let air = visible.contains(city.coord) ? airInCity[city.coord] ?? 0 : 0
            if air > 0 { status.append("✈\(air)") }
            var influence: CGFloat? = nil, influenceLevel = 5
            if let owner = state.civ(city.civId), owner.isCityState, city.civId != viewerId, viewer.metCivs.contains(city.civId) {
                influence = CGFloat(min(60, max(-60, state.influence(of: viewerId, with: city.civId)))) / 60
                switch state.relationshipLevel(city.civId, viewerId) {
                case .unforgivable: influenceLevel = 0
                case .enemy: influenceLevel = 1
                case .afraid: influenceLevel = 2
                case .neutral, .friend: influenceLevel = 3
                case .ally: influenceLevel = 4
                default: influenceLevel = 5
                }
            }
            // Unciv CityButton.moveButtonDown / moveButtonUp: it stays down while a unit on its tile is selected, and every
            // button drops while a spy is being moved.
            let wasDown = bannersDown.contains(city.id)
            let isDown = (ctrl.selectedCityId == city.id && ctrl.selectedUnitId == nil) || ctrl.foreignCityTapped == city.coord
                || ctrl.selectedSpyId != nil || (wasDown && ctrl.selectedUnit?.coord == city.coord)
            if isDown { newBannersDown.insert(city.id) }
            buttons.append((city.id, CityButtonModel(
                id: city.id, coord: city.coord, wrap: wrap,
                label: "\(city.population) \(L(city.name))",   // Unciv CityTable: city.name.toLabel() - translated
                labelColor: nation.innerColor ?? [255, 255, 255], fill: nation.outerColor,
                frame: city.civId == selectedId ? 1 : atWarWithUs ? 2 : 0,
                civIcon: TextureRef(texture: civIcon), civIconTint: civIconTint,
                strength: "⚔\(Int(state.cityStrength(city).rounded()))",
                strengthFrame: city.civId == viewerId ? 1 : state.areAtWar(viewerId, city.civId) ? 2 : 0,
                detail: detail, status: status.isEmpty ? nil : status.joined(separator: " "), hurt: city.health < maxHP,
                influence: influence, influenceLevel: influenceLevel,
                health: city.health < maxHP && visible.contains(city.coord) ? CGFloat(city.health) / CGFloat(maxHP) : nil,
                wasDown: wasDown, isDown: isDown,
                fireworks: UserSettings.continuousRendering && city.isCelebrating && city.civId == viewerId)))
        }
        cityButtons.sync(buttons, build: MapScene.makeCityButton)

        // Units
        var perTile: [HexCoord: Int] = [:]
        var arts: [(id: Int, model: UnitArtModel)] = []
        // Unciv UnitIconGroup.getActionImage starts with `unitView.tryGetMapUnitView() ?: return null`, and
        // ForeignMapUnitView.tryGetMapUnitView is null when `unit.civ != viewer && !viewer.isSpectator()`: a foreign
        // unit's flag shows only its shape (fortify/guard, embark, civilian), never an action image.
        let actionsOf = { (unit: Unit) in unit.civId == state.playerId || state.player.isSpectator }
        // Unciv TileLayerUnitSprite / TileLayerUnitFlag fill only the tile's civilianUnit and militaryUnit slots: the
        // tile's airUnits get no art and no flag - a city shows them as its AirUnitTable count, a carrier as its own.
        for unit in shown where visible.contains(unit.coord) && !unit.def.isAir {
            let embarked = state.isEmbarked(unit)
            let artName = embarked ? (unit.def.isSettler ? "EmbarkedUnit-Settler" : unit.isCivilian ? "EmbarkedUnit-Civilian" : "EmbarkedUnit-Military") : unit.name
            guard let nation = state.civ(unit.civId)?.nationDef else { continue }
            // HDTiles: a medallion in the nation's colours with the unit's icon, instead of the 32 px figure
            let hdKey = "hd:unit:\(unit.name)|\(nation.outerColor.map(String.init).joined(separator: ","))|\((nation.innerColor ?? [255, 255, 255]).map(String.init).joined(separator: ","))|\(embarked ? 1 : 0)"
            guard let tex = Art.shared.hd ? Art.shared.texture(hdKey, folder: "Units") : Art.shared.unitTexture(artName) else { continue }
            let n = perTile[unit.coord, default: 0]; perTile[unit.coord] = n + 1
            tex.filteringMode = .linear
            var flagAlpha = CGFloat(UserSettings.unitIconOpacity)   // Unciv "Unit icon opacity"
            if unit.civId == viewerId && unit.movementLeft <= 0 { flagAlpha *= 0.5 }   // Unciv UnitIconGroup: a unit out of movement is half faded
            let fortified: Bool
            switch unit.order {
            case .fortify, .fortifyUntilHealed, .guardPost: fortified = true
            default: fortified = false
            }
            // Unciv UnitIconGroup.getActionImage: one action image per flag, the first of isSleeping,
            // canBuildCurrentImprovement (MapUnitView: the tile's improvementInProgress, if the unit canBuildImprovement it -
            // drawn as ImprovementIcons/<improvementInProgress>), isEscorting, isMoving, isExploring, isAutomated (ConnectRoad
            // sets automated = true, so a road-connecting worker shows Automate) and isSetUpForSiege.
            var badgeTex: SKTexture? = nil, badgeEmoji: String? = nil
            if actionsOf(unit) {
                let here = state.map[unit.coord]
                if unit.order == .sleep || unit.order == .sleepUntilHealed { badgeEmoji = "💤" }                         // UnitActionIcons/Sleep
                else if let t = here, let imp = t.improvementInProgress, state.unitCanBuildImprovement(unit, imp, t) {
                    badgeTex = Art.shared.texture(imp, folder: "ImprovementIcons"); badgeEmoji = "🔨"                   // ImprovementIcons/<imp>
                }
                else if unit.escorting, state.isEscorting(unit) { badgeEmoji = "🔗" }                                   // UnitActionIcons/Escort
                else if case .moveTo = unit.order { badgeEmoji = "➡️" }                                                  // UnitActionIcons/MoveTo
                else if unit.order == .explore { badgeEmoji = "🔭" }                                                     // UnitActionIcons/Explore
                else if unit.isAutomated { badgeEmoji = "⚙️" }                                                    // UnitActionIcons/Automate
                else if case .connectRoad = unit.order { badgeEmoji = "⚙️" }                                             // automated -> Automate
                else if unit.isSetUp { badgeEmoji = "🎯" }                                                               // UnitActionIcons/SetUp
            }
            // Unciv TileLayerUnitFlag.newUnitIcon: `!tile.isCityCenter() && tile.airUnits.any { unit.isTransportTypeOf(it) }`
            // puts the getAirUnitTable on that unit's flag, counting `tile.airUnits.size` - every air unit on the tile
            let airHere = state.units(at: unit.coord).filter { $0.def.isAir }
            let carried = state.city(at: unit.coord) == nil && airHere.contains(where: { state.isTransportTypeOf(unit, $0) }) ? airHere.count : nil
            let selected = unit.id == ctrl.selectedUnitId
            var model = UnitArtModel(id: unit.id, coord: unit.coord, wrap: wrap, stack: n, texture: TextureRef(texture: tex),
                                     outer: nation.outerColor, inner: nation.innerColor ?? [255, 255, 255], flagAlpha: flagAlpha,
                                     hd: Art.shared.hd, health: unit.health, fortified: fortified,
                                     badgeIcon: TextureRef(texture: badgeTex), badgeEmoji: badgeEmoji,
                                     enemy: unit.civId != viewerId && state.areAtWar(viewerId, unit.civId), air: carried,
                                     selected: selected, glowing: selected && UserSettings.continuousRendering, walking: false)
            // Unciv animateMovement: the unit's art sprites (not its flag, which is another layer) are lifted into a
            // group of their own and moved tile by tile along the path, 0.5s / path length per step (linear); the art
            // standing at the destination is hidden until they arrive, so the unit is not drawn twice.
            if let k = moveAnimations.firstIndex(where: { $0.unitId == unit.id }) {
                let anim = moveAnimations.remove(at: k)
                if !anim.path.isEmpty {
                    let ghost = MapScene.makeUnitSprite(model)
                    let dy = ghost.position.y - unit.coord.pixelCenter.y
                    let dx = ghost.position.x - unit.coord.pixelCenter.x
                    ghost.removeAllActions()
                    for child in ghost.children where child.name != "shadow" { child.removeFromParent() }
                    ghost.position = CGPoint(x: anim.from.pixelCenter.x + dx, y: anim.from.pixelCenter.y + dy)
                    ghost.zPosition = 10   // fxLayer sits above the units
                    let step = 0.5 / Double(anim.path.count)
                    var steps: [SKAction] = anim.path.map { c in
                        SKAction.move(to: CGPoint(x: c.pixelCenter.x + dx, y: c.pixelCenter.y + dy), duration: step)
                    }
                    // The walking art lives on fxLayer, which a refresh does not clear - a second refresh right after the
                    // move (the next unit being selected) used to wipe it and the unit simply jumped
                    let id = unit.id
                    walkingUnits.insert(id)
                    steps.append(SKAction.run { [weak self] in self?.walkingUnits.remove(id); self?.refreshUnits() })
                    steps.append(SKAction.removeFromParent())
                    ghost.run(SKAction.sequence(steps))
                    fxLayer.addChild(ghost)
                }
            }
            model.walking = walkingUnits.contains(unit.id)
            arts.append((unit.id, model))
        }
        unitArt.sync(arts, build: MapScene.makeUnitArt)

        // Unciv BattleTableHelpers.battleAnimation: the attacker's art (a city's centre icon, an air unit nothing) is
        // pushed moveActorsDisplacement = 10 world units towards the defender over 0.3s (sine) and back; at the turn
        // a red "-N" appears at the right edge of each tile that lost health, and whoever took damage is tinted
        // red over 0.2s and back while the attacker returns.
        if let b = battleAnimation {
            battleAnimation = nil
            playBattleAnimation(b)
            // the next refresh draws the units it moved and tinted again, as the full redraw did: whatever it caught
            // still under way ends there, and nothing of the lunge or the red is left on them
            unitArt.redraw.insert(b.attackerId)
            if let d = b.defenderId { unitArt.redraw.insert(d) }
        }
        // Unciv BattleTable: ImageGetter.getCircle() (white), 10 world units wide with its origin at the centre, placed
        // at the target tile group's corner; fadeOut(0), then fadeIn 1s pow2In with scaleTo 200 1s linear, delay
        // 1s, fadeOut 1s pow2Out, removed.
        if let t = nukeAnimation {
            nukeAnimation = nil
            let r = 5 * MapScene.uncivWorldUnit
            let circle = SKShapeNode(circleOfRadius: r)
            circle.fillColor = .white; circle.strokeColor = .clear; circle.zPosition = 4000
            circle.position = CGPoint(x: t.pixelCenter.x + (-25 + 5) * MapScene.uncivWorldUnit, y: t.pixelCenter.y + (-25 + 5) * MapScene.uncivWorldUnit)
            circle.alpha = 0
            let fadeIn = SKAction.fadeAlpha(to: 1, duration: 1); fadeIn.timingFunction = { t in t * t }                       // pow2In
            let fadeOut = SKAction.fadeAlpha(to: 0, duration: 1); fadeOut.timingFunction = { t in 1 - (1 - t) * (1 - t) }   // pow2Out
            circle.run(.sequence([.group([fadeIn, .scale(to: 200, duration: 1)]), .wait(forDuration: 1), fadeOut, .removeFromParent()]))
            addWrapped(circle, to: fxLayer)
        }
        // Unciv addTileOverlays: the units offered as icons on the tapped tile, known before its button is placed
        overlayRow = ctrl.unitIconsTile.map { t in (t, ctrl.unitIconUnits(at: t)) }
        overlayButtonTiles = []
        // Unciv WorldMapHolder.selectedTile: tapping a tile selects it, and the selection is drawn - without it
        // a tap on empty ground only fills the panel on the right and the map says nothing about where you tapped.
        // updateTiles ends in `tileGroups[selectedTile]?.layerOverlay?.showHighlight(Color.WHITE)` whether or not the tile
        // is explored: showHighlight's determineVisibility makes the overlay layer visible again even where TileGroup.update
        // had hidden every layer (TileLayerOverlay.kt:41-46, :122-124; TileLayer.kt:28-33), so an unknown tile shows it too.
        if let t = ctrl.infoTile, ctrl.editorHighlight.isEmpty {
            addWrapped(hexOverlay(at: t, color: .white, alpha: 0.3), to: overlayLayer)
        }
        // Unciv MapEditorViewTab's continent link: TileLayerOverlay.showHighlight(Color.BROWN.darken(0.5f)), alpha 0.3
        // (libGDX BROWN 0x8b4513, darken multiplying the channels by 0.5)
        for c in ctrl.editorHighlight {
            addWrapped(hexOverlay(at: c, color: UIColor(red: CGFloat(0x8b) / 255 * 0.5, green: CGFloat(0x45) / 255 * 0.5, blue: CGFloat(0x13) / 255 * 0.5, alpha: 1), alpha: 0.3), to: overlayLayer)
        }
        // Unciv WorldMapTileUpdater.updateTilesForSelectedSpy: every city the spy canMoveTo is highlighted CYAN at 0.7
        if let spy = ctrl.selectedSpy {
            for c in state.cities where state.spyCanMoveTo(spy, c, civId: state.playerId) { addWrapped(hexOverlay(at: c.coord, color: .cyan, alpha: 0.7), to: overlayLayer) }
            // Unciv MoveSpyOverlayButtonData: a round button on the tapped tile - the movement icon over a city the spy may
            // move to, a red cross anywhere else - while the state may change
            if let t = ctrl.spyOverlayTile, ctrl.isMyTurn, !state.player.isSpectator {
                let button = SKNode(); button.position = t.pixelCenter; button.zPosition = 5
                let disc = SKShapeNode(circleOfRadius: 11); disc.fillColor = .white; disc.strokeColor = .clear
                button.addChild(disc)
                let canMove = ctrl.spyOverlayCity(t) != nil
                if let tex = canMove ? Art.shared.texture("Movement", folder: "StatIcons") : Art.shared.texture("Close", folder: "OtherIcons") {
                    let icon = SKSpriteNode(texture: tex); icon.size = CGSize(width: 11, height: 11)
                    icon.color = canMove ? UIColor(white: 0.13, alpha: 1) : .red; icon.colorBlendFactor = 1
                    button.addChild(icon)
                }
                addOverlayButton(button, over: t)
            }
        }
        // Selection + reachable/attackable overlays
        if let sel = ctrl.selectedUnitId, let unit = state.unit(sel) {
            if let hl = Art.shared.texture("Highlight") {
                let s = SKSpriteNode(texture: hl); s.size = MapScene.hexImageSize(hl); s.position = unit.coord.pixelCenter; s.alpha = 0.9
                s.anchorPoint = CGPoint(x: 0.5, y: 0); s.position.y -= HexCoord.imageHeight / 2
                addWrapped(s, to: overlayLayer)
            }
            // Unciv WorldMapTileUpdater Z-0: swapping mode highlights the swappable tiles in PURPLE, road connecting mode the
            // valid road tiles in RED at 0.3 and the chosen path in ORANGE at 0.8 - and neither shows the other overlays.
            if ctrl.swapMode {
                let purple = UIColor(red: 0.63, green: 0.13, blue: 0.94, alpha: 1)
                for c in state.distanceToTiles(unit).keys where state.canUnitSwapTo(unit, c) {   // Unciv getUnitSwappableTiles: reachable this turn
                    addWrapped(hexOverlay(at: c, color: purple, alpha: UserSettings.singleTapMove ? 0.7 : 0.3), to: overlayLayer)
                }
                if let t = ctrl.swapOverlayTile { addOverlayButton(overlayActionButton(at: t, icon: Art.shared.texture("Swap", folder: "OtherIcons"), unit: unit), over: t) }
            } else if ctrl.connectRoadMode {
                if state.rs.improvements["Road"] != nil {   // Unciv: rulesetHasRoadImprovement
                    for c in state.map.tiles.map(\.coord) where state.isValidRoadPathTile(c, civId: unit.civId) { addWrapped(hexOverlay(at: c, color: .red, alpha: 0.3), to: overlayLayer) }
                    if let ro = ctrl.roadOverlay {
                        for c in ro.path { addWrapped(hexOverlay(at: c, color: .orange, alpha: 0.8), to: overlayLayer) }
                        addOverlayButton(overlayActionButton(at: ro.tile, icon: Art.shared.texture("Road", folder: "ImprovementIcons"), unit: unit, tinted: false), over: ro.tile)
                    }
                }
            } else {
                // Unciv TileGroup.update hides every layer of an unexplored tile with no explored neighbour, but updateTiles
                // runs it before the unit's overlays (WorldMapTileUpdater.kt:21-22): showHighlight and overlayTerrain then add
                // their image and determineVisibility makes the layer visible again (TileLayerOverlay.kt:41-46, :122-124;
                // TileLayerMisc.kt:456-466, :493-499; TileLayer.kt:28-33). So the move highlight, the sky trail and the
                // destination mark are drawn deep in the dark too, like the Move here button.
                // Unciv WorldMapTileUpdater Z-1: moveTileOverlayColor is BLUE while the unit prepares a paradrop, WHITE otherwise.
                let moveColor: UIColor = ctrl.paradropMode ? .blue : .white
                if UserSettings.useCirclesToIndicateMovableTiles {
                    // Unciv "Use circles to indicate movable tiles": layerOverlay.showHighlight(moveTileOverlayColor, 0.7 with
                    // single-tap move, 0.3 otherwise) - the tile's Highlight image at hexagon size, the one the selected unit stands on
                    if let hl = Art.shared.texture("Highlight") {
                        for c in ctrl.reachable {
                            let n = SKSpriteNode(texture: hl); n.size = MapScene.hexImageSize(hl); n.anchorPoint = CGPoint(x: 0.5, y: 0)
                            n.position = CGPoint(x: c.pixelCenter.x, y: c.pixelCenter.y - HexCoord.imageHeight / 2)
                            n.color = moveColor; n.colorBlendFactor = 1; n.alpha = UserSettings.singleTapMove ? 0.7 : 0.3
                            addWrapped(n, to: overlayLayer)
                        }
                    }
                } else {
                    // Unciv layerMisc.overlayTerrain(moveTileOverlayColor, 0.4f)
                    for c in ctrl.reachable { addWrapped(hexOverlay(at: c, color: moveColor, alpha: 0.4), to: overlayLayer) }
                }
                // Unciv WorldMapTileUpdater Z-3: unitMovementPaths, the tiles of the planned route, in Color.SKY at 0.8.
                if let pm = ctrl.pendingMove {
                    let sky = UIColor(red: 135/255, green: 206/255, blue: 235/255, alpha: 1)
                    for c in pm.path { addWrapped(hexOverlay(at: c, color: sky, alpha: 0.8), to: overlayLayer) }
                }
                // Unciv WorldMapTileUpdater: suggested city locations for units that can found cities (best three explored sites).
                if UserSettings.showSettlersSuggestedCityLocations && unit.def.isSettler {
                    let best = state.bestTilesToFoundCity(unit, distanceToSearch: 5, minimumValue: 50).tileRankMap
                    for (c, _) in best.filter({ explored.contains($0.key) }).sorted(by: { $0.value > $1.value }).prefix(3) {
                        let ring = SKShapeNode(circleOfRadius: 9); ring.strokeColor = UIColor(red: 0.3, green: 0.9, blue: 0.3, alpha: 0.95); ring.lineWidth = 1.5; ring.fillColor = UIColor(red: 0.3, green: 0.9, blue: 0.3, alpha: 0.2); ring.position = c.pixelCenter; ring.zPosition = 4
                        let icon = SKLabelNode(text: "🏛"); icon.fontSize = 9; icon.verticalAlignmentMode = .center; ring.addChild(icon)
                        addWrapped(ring, to: overlayLayer)
                    }
                }
                // Unciv MoveHereOverlayButtonData: a round button with the movement icon and the turn count on the target tile.
                if let pm = ctrl.pendingMove { addMoveHereButton(pm, ctrl) }
                // Unciv MoveHereOverlayButtonData with isParadrop (the paratrooper's own button)
                if let po = ctrl.paradropOverlay { addParadropButton(po, ctrl) }
                // Unciv WorldMapTileUpdater Z-6: the target tint is rgb(237,41,57) at showHighlight's default alpha, and
                // every target carries a crosshair - half strength when the unit must move before it can shoot.
                let attackColor = UIColor(red: 237/255, green: 41/255, blue: 57/255, alpha: 1)
                for c in ctrl.attackCrosshairs {
                    addWrapped(hexOverlay(at: c, color: attackColor, alpha: 0.3), to: overlayLayer)
                    guard let tex = Art.shared.texture("Crosshair", folder: "Tiles") else { continue }
                    let x = SKSpriteNode(texture: tex); x.size = MapScene.hexImageSize(tex)
                    x.position = c.pixelCenter; x.zPosition = 2
                    x.alpha = (ctrl.attackOrigins[c] ?? unit.coord) != unit.coord ? 0.5 : 1   // Unciv: tileToAttackFrom != the unit's tile
                    addWrapped(x, to: overlayLayer)
                    // Unciv: `if (tileToAttack == selectedTile) tileGroups[tileToAttackFrom].showHighlight(Color.SKY, 0.7f)`
                    if c == ctrl.battleTarget, let from = ctrl.attackOrigins[c] {
                        addWrapped(hexOverlay(at: from, color: UIColor(red: 0x87/255, green: 0xce/255, blue: 0xeb/255, alpha: 1), alpha: 0.7), to: overlayLayer)
                    }
                }
                // Unciv WorldMapTileUpdater Z-4: a worker already building a road connection shows the tiles of the route it
                // has not reached yet, in orange - not a destination marker.
                if case .connectRoad = unit.order, let here = unit.roadConnectionPath.firstIndex(of: unit.coord) {
                    let orange = UIColor(red: 1, green: 0.65, blue: 0, alpha: 1)
                    for c in unit.roadConnectionPath[(here + 1)...] {
                        addWrapped(hexOverlay(at: c, color: orange, alpha: UserSettings.singleTapMove ? 0.7 : 0.3), to: overlayLayer)
                    }
                }
                // Unciv WorldMapTileUpdater Z-5: a unit under a multi-turn move order marks where it is headed, WHITE at 0.7.
                if case .moveTo(let t) = unit.order { addWrapped(hexOverlay(at: t, color: .white, alpha: 0.7), to: overlayLayer) }
            }
        }
        // Unciv WorldMapTileUpdater.updateBombardableTilesForSelectedCity: a selected city that can bombard marks each
        // bombardable tile with rgb(237,41,57) at showHighlight's 0.3 and a crosshair - nothing else of the city is drawn
        if ctrl.selectedUnitId == nil, let cityId = ctrl.selectedCityId, let city = state.city(cityId), city.civId == state.playerId || state.player.isSpectator, state.canBombard(city) {
            let attackColor = UIColor(red: 237/255, green: 41/255, blue: 57/255, alpha: 1)
            for c in state.bombardableTiles(city) {
                addWrapped(hexOverlay(at: c, color: attackColor, alpha: 0.3), to: overlayLayer)
                if let tex = Art.shared.texture("Crosshair", folder: "Tiles") {
                    let x = SKSpriteNode(texture: tex); x.size = MapScene.hexImageSize(tex); x.position = c.pixelCenter; x.zPosition = 2
                    addWrapped(x, to: overlayLayer)
                }
            }
        }
        // Unciv WorldMapTileUpdater.updateTiles: a selected city keeps the unit action overlays of the tap that selected it -
        // the Move here (or Paradrop) button of the unit selected before (updateTilesForSelectedUnit, and so its sky path,
        // is not run)
        if ctrl.selectedUnitId == nil, ctrl.selectedCityId != nil {
            if let pm = ctrl.pendingMove { addMoveHereButton(pm, ctrl) }
            if let po = ctrl.paradropOverlay { addParadropButton(po, ctrl) }
        }
        addUnitIcons(state)
        // Unciv WorldMapHolder.updateMovementOverlay: arrows along each visible unit's remembered path (only the selected unit's when one is selected).
        if UserSettings.showUnitMovements {
            let visibleNow = visible   // Unciv updateMovementOverlay(getGameViewConsideringForOfWar(), ...)
            for u in state.units where !u.movementMemories.isEmpty && (ctrl.selectedUnitId == nil || ctrl.selectedUnitId == u.id) {
                // Unciv MapVisualization.isMovementVisible: every remembered position AND the current tile must be
                // visible, and the unit itself must be visible to us - an OR leaked the path a unit took through fog,
                // and an undetected submarine drew its arrow.
                guard u.civId == viewerId || (visibleNow.contains(u.coord)
                    && u.movementMemories.allSatisfy { visibleNow.contains($0.coord) }
                    && !(u.def.isInvisible && !state.canSeeInvisibleUnit(u, from: viewerId))) else { continue }
                var previous = u.movementMemories[0]
                for next in u.movementMemories.dropFirst() { addArrow(from: previous.coord, to: next.coord, type: next.type); previous = next }
                addArrow(from: previous.coord, to: u.coord, type: u.mostRecentMoveType)
            }
            // Unciv GameView.getVisibleAttacks: every civ's living units' attacks since their turn start (from where the
            // unit stands now), then each civ's own records - city bombardments, units since gone - each kept only when
            // MapVisualization.isAttackVisible: our own attack, or its source or target tile in our viewableTiles.
            func isAttackVisible(_ attacker: Int, _ source: HexCoord, _ target: HexCoord) -> Bool {
                attacker == viewerId || visibleNow.contains(source) || visibleNow.contains(target)
            }
            var attacks: [(from: HexCoord, to: HexCoord)] = []
            for c in state.civs {
                for u in state.units(of: c.id) {
                    for t in u.attacksSinceTurnStart where isAttackVisible(c.id, u.coord, t) { attacks.append((u.coord, t)) }
                }
            }
            for c in state.civs {
                for m in c.attacksSinceTurnStart where isAttackVisible(c.id, m.source, m.target) { attacks.append((m.source, m.target)) }
            }
            // WorldMapHolder.updateMovementOverlay: with a unit selected, only the attacks from or onto ITS TILE
            let selectedAt = ctrl.selectedUnitId.flatMap { state.unit($0)?.coord }
            for (from, to) in attacks {
                if let s = selectedAt, s != from, s != to { continue }
                addArrow(from: from, to: to, type: "UnitHasAttacked")
            }
        }
    }

    /// Unciv MoveHereOverlayButtonData: a round button with the movement icon and the turn count on the target tile.
    private func addMoveHereButton(_ pm: (tile: HexCoord, turns: Int, unitId: Int, path: [HexCoord]), _ ctrl: GameController) {
        let button = SKNode(); button.position = pm.tile.pixelCenter; button.zPosition = 5
        // Unciv MoveHereOverlayButtonData: half transparent when no unit on it can move any further.
        if (ctrl.state.unit(pm.unitId)?.movementLeft ?? 0) <= 0 { button.alpha = 0.5 }
        let ring = SKShapeNode(circleOfRadius: 11); ring.fillColor = UIColor(white: 0.13, alpha: 1); ring.strokeColor = .clear
        let inner = SKShapeNode(circleOfRadius: 10); inner.fillColor = .white; inner.strokeColor = .clear
        button.addChild(ring); button.addChild(inner)
        if let tex = Art.shared.texture("Movement", folder: "StatIcons") { let icon = SKSpriteNode(texture: tex); icon.size = CGSize(width: 12, height: 12); icon.color = UIColor(white: 0.13, alpha: 1); icon.colorBlendFactor = 1; button.addChild(icon) }
        let badge = SKShapeNode(circleOfRadius: 5); badge.fillColor = UIColor(red: 0.2, green: 0.25, blue: 0.35, alpha: 1); badge.strokeColor = .white; badge.lineWidth = 0.6; badge.position = CGPoint(x: -6.4, y: -6.4)
        let n = SKLabelNode(fontNamed: "AvenirNext-Bold"); n.text = "\(pm.turns)"; n.fontSize = 6; n.fontColor = .white; n.verticalAlignmentMode = .center; badge.addChild(n)
        button.addChild(badge)
        // Unciv MoveHereOverlayButtonData: the icon of the unit the button would move, so a badge
        // belonging to a unit other than the selected one can still be told apart.
        if let mover = ctrl.state.unit(pm.unitId), let tex = Art.shared.texture(mover.name, folder: "UnitIcons") {
            let disc = SKShapeNode(circleOfRadius: 5.5)
            disc.fillColor = UIColor(white: 0.13, alpha: 1); disc.strokeColor = .white; disc.lineWidth = 0.6
            disc.position = CGPoint(x: -6.4, y: 6.4)
            let icon = SKSpriteNode(texture: tex); icon.size = CGSize(width: 8, height: 8)
            icon.color = .white; icon.colorBlendFactor = 1
            disc.addChild(icon); button.addChild(disc)
        }
        addOverlayButton(button, over: pm.tile)
    }

    /// Unciv MoveHereOverlayButtonData with isParadrop: the round button carries the Paradrop action portrait instead of
    /// the movement icon and no turn-count circle, the icon of the unit it drops on top; half transparent (and inert) when
    /// that unit has no movement left.
    private func addParadropButton(_ po: (tile: HexCoord, unitId: Int), _ ctrl: GameController) {
        guard let mover = ctrl.state.unit(po.unitId) else { return }
        let t = po.tile
        let button = SKNode(); button.position = t.pixelCenter; button.zPosition = 5
        if mover.movementLeft <= 0 { button.alpha = 0.5 }
        let ring = SKShapeNode(circleOfRadius: 11); ring.fillColor = UIColor(white: 0.13, alpha: 1); ring.strokeColor = .clear
        let inner = SKShapeNode(circleOfRadius: 10); inner.fillColor = .white; inner.strokeColor = .clear
        button.addChild(ring); button.addChild(inner)
        // the Paradrop action's own symbol (UnitActionsTable), as the portrait
        if let img = UIImage(systemName: "arrow.down.to.line", withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .bold))?
            .withTintColor(UIColor(white: 0.13, alpha: 1), renderingMode: .alwaysOriginal) {
            let icon = SKSpriteNode(texture: SKTexture(image: img))
            let k = 12 / max(img.size.width, img.size.height)
            icon.size = CGSize(width: img.size.width * k, height: img.size.height * k)
            button.addChild(icon)
        }
        if let tex = Art.shared.texture(mover.name, folder: "UnitIcons") {
            let disc = SKShapeNode(circleOfRadius: 5.5)
            disc.fillColor = UIColor(white: 0.13, alpha: 1); disc.strokeColor = .white; disc.lineWidth = 0.6
            disc.position = CGPoint(x: -6.4, y: 6.4)
            let icon = SKSpriteNode(texture: tex); icon.size = CGSize(width: 8, height: 8)
            icon.color = .white; icon.colorBlendFactor = 1
            disc.addChild(icon); button.addChild(disc)
        }
        addOverlayButton(button, over: t)
    }

    /// Unciv WorldMapHolder.addOverlayOnTileGroup: the button table is never packed, so its size is 0 - `center(group)`
    /// puts its origin on the tile's centre, `y += height` adds nothing, and the cells lay out centred on that origin; the
    /// button then rises 48 above the tile's centre - with "Animate Unit movement button" those 48 slide in while it
    /// fades in (0.15 s, smooth). Measured on the Unciv jar: button centre = tile centre + 48. It is its own touch target (handleTap), acting as a tap on its tile. When the
    /// tile also offers unit icons (addTileOverlays) the button is the first cell of that row, which stays centred.
    private func addOverlayButton(_ button: SKNode, over t: HexCoord) {
        overlayButtonTiles.insert(t)
        let icons = overlayRow.map { $0.tile == t ? $0.units.count : 0 } ?? 0
        placeOverlay(button, over: t, dx: -CGFloat(icons) * 44 * MapScene.uncivWorldUnit, name: "overlaybtn|\(t.q)|\(t.r)")
    }
    private func placeOverlay(_ button: SKNode, over t: HexCoord, dx: CGFloat, name: String) {
        button.name = name
        let u = MapScene.uncivWorldUnit
        let finalY = t.pixelCenter.y + 48 * u
        let targetAlpha = button.alpha
        var nodes = [button]
        if wraps { for k in [-1.0, 1.0] { if let dup = button.copy() as? SKNode { dup.position.x = t.pixelCenter.x + dx + k * mapWidthPx; nodes.append(dup) } } }
        for (i, node) in nodes.enumerated() {
            if i == 0 { node.position.x = t.pixelCenter.x + dx }
            if UserSettings.animateUnitMovementButton {
                node.position.y = finalY - 48 * u; node.alpha = 0
                let move = SKAction.moveTo(y: finalY, duration: 0.15); move.timingMode = .easeInEaseOut
                let fade = SKAction.fadeAlpha(to: targetAlpha, duration: 0.15); fade.timingMode = .easeInEaseOut
                node.run(.group([move, fade]))
            } else { node.position.y = finalY }
            overlayLayer.addChild(node)
        }
    }

    /// Unciv WorldMapHolder.addTileOverlays: every unit of ours seen on the tapped tile (a city centre, or a tile with our
    /// air units) gets a round icon in the row after the tile's action button - a UnitIconGroup of 48 in a grey circle of
    /// 68 at half alpha, the whole at 0.66 when the unit has no movement left. A tap selects the unit ("uniticon|<id>").
    private func addUnitIcons(_ state: GameState) {
        guard let row = overlayRow, !row.units.isEmpty else { return }
        let u = MapScene.uncivWorldUnit
        let n = CGFloat(row.units.count)
        let hasButton = overlayButtonTiles.contains(row.tile)
        for (i, unit) in row.units.enumerated() {
            // cells of 60 + 2 * 10 (the button) and 68 + 2 * 10 (each icon), the row centred on the tile
            let dx = ((hasButton ? 124 : 44) + 88 * CGFloat(i) - (hasButton ? 40 : 0) - 44 * n) * u
            let node = SKNode(); node.zPosition = 5
            let circle = SKShapeNode(circleOfRadius: 34 * u); circle.fillColor = UIColor.gray.withAlphaComponent(0.5); circle.strokeColor = .clear
            node.addChild(circle)
            let nation = state.civ(unit.civId)?.nationDef
            let disc = SKShapeNode(circleOfRadius: 24 * u); disc.strokeColor = .clear
            disc.fillColor = nation.map { UIColor(rgb: $0.outerColor) } ?? .darkGray
            node.addChild(disc)
            if let tex = Art.shared.texture(unit.name, folder: "UnitIcons") {
                let icon = SKSpriteNode(texture: tex); icon.size = CGSize(width: 34 * u, height: 34 * u)
                icon.color = UIColor(rgb: nation?.innerColor ?? [255, 255, 255]); icon.colorBlendFactor = 1
                node.addChild(icon)
            }
            if unit.movementLeft <= 0 { node.alpha = 0.66 }
            placeOverlay(node, over: row.tile, dx: dx, name: "uniticon|\(unit.id)")
        }
    }

    /// Unciv SwapWithOverlayButtonData / ConnectRoadOverlayButtonData: a white round button with the action's icon and the
    /// unit's icon on its upper left
    private func overlayActionButton(at t: HexCoord, icon tex: SKTexture?, unit: Unit, tinted: Bool = true) -> SKNode {
        let button = SKNode(); button.position = t.pixelCenter; button.zPosition = 5
        let disc = SKShapeNode(circleOfRadius: 11); disc.fillColor = .white; disc.strokeColor = .clear
        button.addChild(disc)
        if let tex { let icon = SKSpriteNode(texture: tex); icon.size = CGSize(width: tinted ? 11 : 16, height: tinted ? 11 : 16); if tinted { icon.color = UIColor(white: 0.13, alpha: 1); icon.colorBlendFactor = 1 }; button.addChild(icon) }
        if let utex = Art.shared.texture(unit.name, folder: "UnitIcons") {
            let small = SKShapeNode(circleOfRadius: 5.5); small.fillColor = UIColor(white: 0.13, alpha: 1); small.strokeColor = .white; small.lineWidth = 0.6
            small.position = CGPoint(x: -6.4, y: 6.4)
            let icon = SKSpriteNode(texture: utex); icon.size = CGSize(width: 8, height: 8); icon.color = .white; icon.colorBlendFactor = 1
            small.addChild(icon); button.addChild(small)
        }
        return button
    }

    /// Unciv world units per our map unit: adjacent tiles lie sqrt(3) * 0.8 * groupSize = 69.28 apart there and
    /// rowStep apart here.
    private static let uncivWorldUnit = HexCoord.rowStep / (1.7320508 * 0.8 * 50)
    /// Unciv stage units (the virtual canvas, 600 high on Small) per screen point.
    private static var uncivStageUnit: CGFloat {
        let size = Theme.ScreenSize(rawValue: UserSettings.screenSize) ?? .small
        return Theme.screenShortSide / (size.referenceHeight / 393 * 600)
    }

    private func playBattleAnimation(_ b: (attackerId: Int, attacker: HexCoord, defender: HexCoord, toAttacker: Int, toDefender: Int,
                                           defenderId: Int?, attackerIsAir: Bool, defenderIsAir: Bool, hideDefenderDamage: Bool)) {
        // getMapActorsForCombatant: a city's improvementIcon, a non-air unit's sprites
        func actors(unitId: Int?, at c: HexCoord, isAir: Bool) -> [SKSpriteNode] {
            if let id = unitId, id >= 0 {
                if isAir { return [] }
                return unitLayer.children.compactMap { $0.name == "u\(id)" ? $0 as? SKSpriteNode : nil }
            }
            return ([tileNodes[c]] + (tileCopies[c] ?? [])).compactMap { $0?.childNode(withName: "cityicon") as? SKSpriteNode }
        }
        let attackerActors = actors(unitId: b.attackerId, at: b.attacker, isAir: b.attackerIsAir)
        let defenderActors = actors(unitId: b.defenderId ?? -1, at: b.defender, isAir: b.defenderIsAir)
        var flashing: [SKSpriteNode] = []
        if b.toDefender != 0 { flashing += defenderActors }
        if b.toAttacker != 0 { flashing += attackerActors }

        var v = CGVector(dx: b.defender.pixelCenter.x - b.attacker.pixelCenter.x, dy: b.defender.pixelCenter.y - b.attacker.pixelCenter.y)
        if wraps, abs(v.dx) > mapWidthPx / 2 { v.dx -= (v.dx > 0 ? 1 : -1) * mapWidthPx }
        let len = max(0.0001, hypot(v.dx, v.dy)), disp = 10 * MapScene.uncivWorldUnit
        let out = CGVector(dx: v.dx / len * disp, dy: v.dy / len * disp), back = CGVector(dx: -out.dx, dy: -out.dy)
        func move(_ d: CGVector) -> SKAction { let a = SKAction.move(by: d, duration: 0.3); a.timingFunction = MapScene.sine; return a }
        // Only the unit art moves; the flag and the other badges drawn as children stay where they are
        func moveArt(_ node: SKSpriteNode, _ d: CGVector) {
            node.run(move(d))
            for child in node.children where child.name != "shadow" { child.run(move(CGVector(dx: -d.dx, dy: -d.dy))) }
        }
        let flashUp = SKAction.colorize(with: .red, colorBlendFactor: 1, duration: 0.2); flashUp.timingFunction = MapScene.sine
        let flashDown = SKAction.colorize(withColorBlendFactor: 0, duration: 0.2); flashDown.timingFunction = MapScene.sine

        run(.sequence([
            .run { attackerActors.forEach { moveArt($0, out) } },
            .wait(forDuration: 0.3),
            .run { [weak self] in
                guard let self else { return }
                self.damageLabel(b.toAttacker, at: b.attacker)
                if !b.hideDefenderDamage { self.damageLabel(b.toDefender, at: b.defender) }
                attackerActors.forEach { moveArt($0, back) }
                flashing.forEach { $0.color = .red; $0.run(.sequence([flashUp, flashDown])) }
            }
        ]))
    }

    /// Unciv createDamageLabel: a ShadowedLabel "-N", font 40 on the stage, centred on the right edge of the tile,
    /// rising 90 stage units over 1.2s while its alpha follows Interpolation.fade(1 - percent). It lives on the
    /// stage, so it keeps its size and place on screen whatever the map does.
    private func damageLabel(_ damage: Int, at c: HexCoord) {
        guard damage != 0 else { return }
        let unit = MapScene.uncivStageUnit
        let world = CGPoint(x: c.pixelCenter.x + 25 * MapScene.uncivWorldUnit, y: c.pixelCenter.y)
        let start = convert(world, to: cam)
        let group = SKNode(); group.zPosition = 5000
        func label(_ color: UIColor, _ offset: CGPoint) -> SKLabelNode {
            let l = SKLabelNode(text: "\(-damage)"); l.fontName = "Helvetica-Bold"; l.fontSize = 40 * unit
            l.fontColor = color; l.verticalAlignmentMode = .center; l.horizontalAlignmentMode = .center; l.position = offset
            return l
        }
        group.addChild(label(.black, CGPoint(x: 1, y: -1)))
        group.addChild(label(.red, .zero))
        group.position = start   // a child of the camera: its units are screen points whatever the zoom
        let rise = 90 * unit
        let anim = SKAction.customAction(withDuration: 1.2) { node, t in
            let p = CGFloat(t) / 1.2
            let x = 1 - p
            node.alpha = x * x * x * (x * (x * 6 - 15) + 10)   // Interpolation.fade
            node.position = CGPoint(x: start.x, y: start.y + p * rise)
        }
        group.run(.sequence([anim, .removeFromParent()]))
        cam.addChild(group)
    }

    /// Unciv TileLayerMisc.updateArrows: the tileset's Arrows/<type> image (Generic when missing), starting at the tile
    /// centre, stretched to the distance to the target (tileScale × distance) and 60 world units high around its axis.
    private func addArrow(from a: HexCoord, to b: HexCoord, type: String) {
        guard a != b, let tex = Art.shared.texture(type, folder: "Arrows") ?? Art.shared.texture("Generic", folder: "Arrows") else { return }
        tex.filteringMode = .linear
        let p0 = a.pixelCenter, p1 = b.pixelCenter
        let arrow = SKSpriteNode(texture: tex)
        arrow.anchorPoint = CGPoint(x: 0, y: 0.5)
        arrow.size = CGSize(width: hypot(p1.x - p0.x, p1.y - p0.y), height: 60 * MapScene.uncivWorldUnit)
        arrow.position = p0
        arrow.zRotation = atan2(p1.y - p0.y, p1.x - p0.x)
        arrow.zPosition = 2
        addWrapped(arrow, to: overlayLayer)
    }

    /// Unciv sizes every tile image to the hexagon width, keeping its aspect ratio.
    static func hexImageSize(_ tex: SKTexture) -> CGSize {
        let sz = tex.size()
        return CGSize(width: HexCoord.imageWidth, height: sz.height * HexCoord.imageWidth / sz.width)
    }

    /// Unciv ParticleEffectMapFireworks: a small emitter of coloured sparks bursting over a celebrating city.
    static func fireworks() -> SKEmitterNode {
        let e = SKEmitterNode()
        let size = CGSize(width: 3, height: 3)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        let img = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext()
        if let img { e.particleTexture = SKTexture(image: img) }
        e.particleBirthRate = 40; e.numParticlesToEmit = 0; e.particleLifetime = 1.2; e.particleLifetimeRange = 0.5
        e.particleSpeed = 25; e.particleSpeedRange = 15; e.emissionAngleRange = .pi * 2
        e.yAcceleration = -30; e.particleAlphaSpeed = -0.8; e.particleScale = 0.6; e.particleScaleRange = 0.3
        e.particleColorSequence = SKKeyframeSequence(keyframeValues: [UIColor.systemYellow, UIColor.systemRed, UIColor.systemBlue, UIColor.systemGreen], times: [0, 0.33, 0.66, 1])
        e.particleColorBlendFactor = 1
        return e
    }
    private func hexOverlay(at c: HexCoord, color: UIColor, alpha: CGFloat) -> SKNode {
        let p = CGMutablePath(); p.addLines(between: MapScene.corners); p.closeSubpath()
        let shape = SKShapeNode(path: p)
        // Unciv's hexagon overlay image has no outline
        shape.fillColor = color; shape.strokeColor = .clear; shape.lineWidth = 0; shape.alpha = alpha
        shape.position = c.pixelCenter
        return shape
    }
}

// MARK: - Unciv EditorMapHolder: the drag-paint listener exists only when the holder belongs to the map editor
extension MapScene: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === paintDragRecognizer { return controller?.editorPaint != nil }
        // Unciv WorldMapHolder longPress: consumed (true) only with Move units with a long tap, a selected unit and a
        // WorldTileGroup under the finger - the editor's listener has no longPress at all. Unconsumed, the tap still
        // fires when the finger lifts (GestureDetector: `if (longPressFired) return false`), so the press must not begin.
        if g === longPressRecognizer {
            guard !isMapEditor, UserSettings.longTapMove, let c = controller, c.selectedUnit != nil, let view else { InputTrace.log("long press not consumed (no unit selected / setting off) - lifting will tap"); return false }
            let p = convertPoint(fromView: g.location(in: view))
            guard mapHit(at: p) == nil else { return false }
            return c.state.map.contains(c.state.map.normalize(HexCoord.fromPixel(mapNode.convert(p, from: self))))
        }
        return true
    }
    /// The editor's hold is timed alongside the long-tap move; only the pan gives way to it. Unciv ZoomGestureListener:
    /// with two fingers the focus's movement pans while their spread zooms, so the pan and the pinch run together.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if g === traceRecognizer || other === traceRecognizer { return true }
        if (g === panRecognizer && other === pinchRecognizer) || (g === pinchRecognizer && other === panRecognizer) { return true }
        return (g === paintDragRecognizer && other !== panRecognizer) || (other === paintDragRecognizer && g !== panRecognizer)
    }
}

/// Unciv's GestureDetector tap: the finger may rest as long as it likes, and the tap fires on lifting it inside a square
/// of `halfSquare` points around where it came down (|dx| < half && |dy| < half); leaving the square, a second finger or
/// a cancelled touch ends it. UITapGestureRecognizer instead gives up after 1.5 s.
final class UncivTapRecognizer: UIGestureRecognizer {
    var halfSquare: CGFloat = 13
    private var start: CGPoint?
    private var lift: CGPoint?
    func liftLocation(in view: UIView?) -> CGPoint {
        guard let lift else { return location(in: view) }
        return view?.convert(lift, from: nil) ?? lift
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible else { return }
        guard start == nil, touches.count == 1, let t = touches.first else { state = .failed; return }
        start = t.location(in: nil)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard state == .possible, let start, let t = touches.first else { return }
        let p = t.location(in: nil)
        if abs(p.x - start.x) >= halfSquare || abs(p.y - start.y) >= halfSquare { InputTrace.log("tap given up: finger moved out of the \(Int(halfSquare))pt square (a drag)"); state = .failed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard state == .possible else { return }
        guard start != nil, let t = touches.first else { state = .failed; return }
        lift = t.location(in: nil)
        state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        if state == .possible { state = .failed }
    }
    override func reset() {
        super.reset()
        start = nil; lift = nil
    }
}
