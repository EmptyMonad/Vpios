// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import SpriteKit

/// Unciv MapEditorScreen: the map on the left, a tabbed pane (View · Generate · Edit · Load · Save · Mods · Options) on the right.
/// Presented as a full-screen cover, so everything stays in-place (no sheets or menus – they hang SwiftUI here).
struct MapEditorView: View {
    @StateObject private var controller: GameController
    let onClose: () -> Void
    @State private var tab = "View"   // Unciv MapEditorMainTabs.selectPage(0)
    /// Unciv MapEditorEditTab.brushHandlerType: None (nil) until a brush is picked, so a tap paints nothing.
    @State private var brush: EditorBrush? = nil
    /// Unciv MapEditorEditTab.randomness: `MapGenerationRandomness()`, whose RNG starts as Random(42) - drawn by the
    /// strategic resource brush and the river target pick, reseeded with the map seed only when a river is painted.
    @State private var randomness = SeededRandom(seed: 42)
    /// Unciv MapEditorEditTab: 1-5 paint a hex radius of that size, 6 is flood fill.
    @State private var brushSize = 1
    /// Unciv MapEditorOptionsTab.TileMatchFuzziness, what flood fill treats as the same tile.
    @State private var matchFuzziness = "Complete match"
    @State private var mapName = "My Map"
    /// Unciv tileMap.mapParameters.name: empty on a new or generated map, the file's name once saved or loaded
    @State private var mapParametersName = ""
    /// Unciv MapEditorViewTab's map parameters ExpanderTab: startsOutOpened = false
    @State private var parametersOpen = false
    @State private var starts: [StartingLocation] = []
    /// Unciv MapEditorEditStartsTab: the "Use for new game \"Select players\" button" choice new locations get.
    @State private var startUsage: StartingLocation.Usage = .player
    /// Unciv MapEditorEditTab.riverStartTile / riverEndTile for the "Spawn river from/to" brush.
    @State private var riverFrom: HexCoord? = nil
    @State private var riverTo: HexCoord? = nil
    @State private var message: String? = nil
    @State private var pendingMapDeletion: String? = nil   // Unciv MapEditorLoadTab: deleting a map is confirmed
    @State private var confirmExit = false                 // Unciv MapEditorScreen: leaving with unsaved changes is confirmed
    /// Unciv MapEditorScreen.askIfDirtyForLoad: loading another map over unsaved changes is confirmed first
    @State private var pendingLoad: (() -> Void)? = nil
    @State private var edited = false                      // Unciv MapEditorScreen.isDirty: changed since the last load, save or autosave
    // Generate tab (Unciv MapEditorGenerateTab)
    @State private var genType = "Pangaea"
    @State private var genSize = "Medium"
    @State private var genShape = "Rectangular"
    @State private var genWrap = false
    @State private var genSeed = NewGameScreen.seedString(NewGameScreen.freshSeed())   // MapParameters.seed = System.currentTimeMillis()
    @State private var genRandomizeSeed = true   // Unciv MapParametersTable.randomizeSeed: on by default
    @State private var genRuins = true
    @State private var genWonders = true
    @State private var genMirroring = "None"   // Unciv MapParametersTable.addMirrorSelectBox
    /// Unciv MapParametersTable(forMapEditor = true): the resource setting and the "Advanced Settings" expander's values
    /// (newMapParameters - the generator reads them on every Generate and generator step)
    @State private var genAdv = GameSettings()
    @State private var genResourceRichness = 0.1   // MapParameters.resourceRichness, a slider only in the map editor
    @State private var genAdvOpen = false         // ExpanderTab("Advanced Settings", startsOutOpened = false)
    @State private var genStep: String? = nil   // Unciv MapEditorGenerateStepsTab: the chosen generator stage
    // Load/Save
    @State private var savedMaps = MapStore.list()
    @State private var selectedSaved: String? = nil
    // Mods (Unciv MapEditorModsTab): the selection on the page is newMapParameters' base ruleset and mods, the map's own
    // are tileMap.mapParameters' - a new map is Gods & Kings without mods (MapEditorScreen init)
    @State private var selectedBaseRuleset = Ruleset.baseRulesetName
    @State private var activeMods: [String] = []
    @State private var mapBaseRuleset = Ruleset.baseRulesetName
    @State private var mapMods: [String] = []
    /// The map's own MapParameters beyond seed and ruleset (CustomMap.parameters): a loaded map's, or the Generate tab's
    /// for a generated one (newMapParameters is the generator's latest, mapParameters the map's)
    @State private var mapParameters: GameSettings? = nil
    @State private var newMapParameters: GameSettings? = nil
    /// AskFitMapToRulesetPopup: the incompatibilities listed before "Change map to fit selected ruleset?"
    @State private var pendingFit: [String]? = nil
    /// The game's ruleset when the editor opened, put back when it closes (Unciv keeps the editor's ruleset to itself)
    @State private var rulesetBeforeEditor: (base: String, mods: [String])? = nil
    // Options
    /// Unciv MapEditorScreen.descriptionTextField / TileMap.description
    @State private var description = ""
    /// Unciv tileMap.mapParameters.seed: a new map's MapParameters default (System.currentTimeMillis()), a generated map's
    /// generation seed, a loaded map's saved one
    @State private var mapSeed = UInt64(Date().timeIntervalSince1970 * 1000)
    /// Unciv MapEditorViewTab.roundRobinIndex: "Click-locating items with several instances: round robin, for simplicity only a global one"
    @State private var roundRobinIndex = 0
    /// Unciv MapEditorScreen(map = null): the editor opened on its blank map
    private let startsBlank: Bool
    private let tabs = ["View", "Generate", "Edit", "Load", "Save", "Mods", "Options"]

    enum EditorBrush: Equatable {
        /// Unciv MapEditorEditTerrainTab / FeaturesTab ("Remove features") / WondersTab / ResourcesTab ("Remove resource") /
        /// ImprovementsTab ("Remove improvement"; Road and Railroad are its BrushHandlerType.Road brushes)
        case terrain(String), feature(String), clearFeatures, resource(String), clearResource, wonder(String), improvement(String), removeImprovement
        /// Unciv MapEditorEditStartsTab: one brush per nation ("" is the "Any Civ" entry) plus the eraser.
        case start(String), removeStarts
        /// Unciv MapEditorEditRiversTab: the three edges a tile owns, the eraser and the two-tile spawner.
        case riverEdge(Int), removeRivers, spawnRiver
        /// Unciv BrushHandlerType.Direct / River: the brush changes the tile as it is; the Tile and Road brushes go
        /// through MapEditorEditTab.paintTile (normalize, then keep or revert).
        var isDirect: Bool {
            switch self {
            case .start, .removeStarts, .riverEdge, .removeRivers: return true
            default: return false
            }
        }
    }

    /// Unciv MapEditorScreen.closeEditor after askIfDirty: the game's own ruleset comes back.
    private func closeEditor() {
        if let r = rulesetBeforeEditor { Ruleset.activate(mods: r.mods, baseRuleset: r.base) }
        onClose()
    }

    init(map: GameMap? = nil, starts: [StartingLocation] = [], name: String = "My Map", onClose: @escaping () -> Void) {
        // Unciv MapEditorScreen(map = null): `TileMap(MapSize.Tiny.radius, ruleset, false)` with mapSize Tiny - a hexagon
        // of the first land terrain that generates naturally (MapLandmassGenerator.getInitializationTerrain)
        let m = map ?? MapEditorView.blankTinyMap()
        startsBlank = map == nil
        _controller = StateObject(wrappedValue: GameController(state: GameState.editorState(map: m)))
        _starts = State(initialValue: starts)
        _mapName = State(initialValue: name)
        self.onClose = onClose
    }

    /// Unciv TileMap(radius = MapSize.Tiny.radius, ruleset, worldWrap = false), mapParameters.mapSize = MapSize.Tiny.
    static func blankTinyMap() -> GameMap {
        let rs = Ruleset.shared
        let land = rs.terrainOrder.compactMap { rs.terrains[$0] }.first { $0.type == .land && !$0.uniques.contains("Doesn't generate naturally") }?.name ?? "Grassland"
        let radius = MapSizePreset.Tiny.radius
        var m = GameMap(uncivPositions: HexMath.hexCoordsInDistance(origin: (0, 0), distance: radius, worldWrap: false), wrapX: false, baseTerrain: land)
        m.uncivSize = UncivMapSize(preset: .Tiny, shape: "Hexagonal")   // Unciv MapParameters.shape defaults to hexagonal
        m.hexRadius = radius
        return m
    }

    var body: some View {
        ZStack {
            SpriteView(scene: controller.scene, preferredFramesPerSecond: 60).ignoresSafeArea().bleedIntoCutout()
            HStack(spacing: 0) {
                Spacer()
                VStack(spacing: 6) {
                    HStack {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) { ForEach(tabs, id: \.self) { t in Button(L(t)) { tab = t }.buttonStyle(ThemedButtonStyle(filled: tab == t, compact: true)) } }
                        }
                        Button { if edited { confirmExit = true } else { closeEditor() } } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.gold).frame(width: 30, height: 30).background(Circle().fill(Theme.panelDark)) }
                    }
                    if let m = message { Text(m).font(Theme.caption).foregroundStyle(Theme.gold).lineLimit(12) }   // a load error lists what it removed
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            switch tab {
                            case "View": viewTab
                            case "Generate": generateTab
                            case "Edit": editTab
                            case "Load": loadTab
                            case "Save": saveTab
                            case "Mods": modsTab
                            default: optionsTab
                            }
                        }
                    }
                }
                .padding(8)
                .frame(width: 330)
                .background(Theme.panelDark.opacity(0.94))
            }
        }
        .foregroundStyle(Theme.cream)
        .onAppear {
            controller.scene.isMapEditor = true   // Unciv EditorMapHolder: plain TileGroups, not WorldTileGroups
            controller.scene.editorStartingLocations = starts   // drawn on the tiles (TileLayerMisc.updateStartingLocationIcon)
            controller.editorPaint = { hex in paint(hex) }
            controller.editorDragPaint = { hex in dragPaint(hex) }
            if rulesetBeforeEditor == nil {
                rulesetBeforeEditor = (Ruleset.currentBaseRuleset, Ruleset.shared.mods)
                // Unciv MapEditorScreen(map = null): `ruleset = RulesetCache[BaseRuleset.Civ_V_GnK.fullName]` - no mods, and
                // the blank map is laid out in it
                if startsBlank && (Ruleset.currentBaseRuleset != Ruleset.baseRulesetName || !Ruleset.shared.mods.isEmpty) {
                    Ruleset.activate(mods: [], baseRuleset: Ruleset.baseRulesetName)
                    controller.state.map = MapEditorView.blankTinyMap()
                    refreshEditorCiv()
                    controller.scene.resetTiles(); controller.scene.scrollToMiddle()   // the holder is built on this map
                }
                controller.state.map.assignContinents(.ensure)   // the View tab is the first one activated
            }
            controller.refresh()
        }
        // Unciv TileLayerMisc.updateStartingLocationIcon reads tileMap.startingLocationsByNation on every tile update: a
        // brush, a load or a generation that changes the starts redraws their icons
        .onChange(of: starts) { _, v in
            controller.scene.editorStartingLocations = v
            controller.refresh()
        }
        // Unciv MapEditorViewTab: deactivated hides the selection and the tile's info, activated runs update() -
        // `tileMap.assignContinents(Ensure)` first
        .onChange(of: tab) { _, newTab in
            controller.infoTile = nil; controller.editorHighlight = []
            if newTab == "View" { controller.state.map.assignContinents(.ensure) }
            controller.refresh(full: false)
        }
        .confirmationDialog(L("Are you sure you want to delete this map?"), isPresented: Binding(get: { pendingMapDeletion != nil }, set: { if !$0 { pendingMapDeletion = nil } }), titleVisibility: .visible) {
            Button(L("Delete map"), role: .destructive) {
                if let m = pendingMapDeletion { MapStore.delete(name: m); savedMaps = MapStore.list(); selectedSaved = nil }
                pendingMapDeletion = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingMapDeletion = nil }
        }
        .confirmationDialog(L("Do you want to leave without saving the recent changes?"), isPresented: $confirmExit, titleVisibility: .visible) {
            Button(L("Leave"), role: .destructive) { closeEditor() }
            Button(L("Cancel"), role: .cancel) { }
        }
        .confirmationDialog(L("Do you want to load another map without saving the recent changes?"), isPresented: Binding(get: { pendingLoad != nil }, set: { if !$0 { pendingLoad = nil } }), titleVisibility: .visible) {
            Button(L("Load map"), role: .destructive) { let action = pendingLoad; pendingLoad = nil; action?() }
            Button(L("Cancel"), role: .cancel) { pendingLoad = nil }
        }
        // Unciv MapEditorScreen.startMapAutosaveLoop: every 10 seconds a changed map is saved as "Autosave" (continents
        // reassigned on the copy) and the map counts as saved; the loop ends with the editor
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                guard edited else { continue }
                do {
                    try MapStore.save(currentCustomMap(), name: "Autosave")
                    savedMaps = MapStore.list()
                    edited = false
                } catch { /* Unciv: Log.error("Failed to autosave map") */ }
            }
        }
        .screenShown("map_editor")
    }

    /// Unciv MapEditorScreen.askIfDirty("Do you want to load another map without saving the recent changes?", "Load map")
    private func askIfDirtyForLoad(_ action: @escaping () -> Void) {
        if edited { pendingLoad = action } else { action() }
    }

    /// The map as MapEditorScreen.getMapCloneForSave hands it to MapSaver: the tiles, the starting locations, the
    /// description (MapEditorSaveTab: `tileMap.description = descriptionTextField.text`), the seed and the ruleset.
    private func currentCustomMap() -> CustomMap {
        CustomMap(map: controller.state.map, startingLocations: starts, description: description, seed: mapSeed,
                  baseRuleset: mapBaseRuleset, mods: mapMods, parameters: mapParameters)
    }

    /// Unciv MapEditorViewTab.updateMockCiv / EditorMapHolder's viewer: the editor's civ sees the whole map and knows
    /// every tech of the editor's ruleset.
    private func refreshEditorCiv() {
        guard let i = controller.state.civIndex(controller.state.playerId) else { return }
        controller.state.civs[i].explored = Set(controller.state.map.tiles.map { $0.coord })
        controller.state.civs[i].techs = Set(controller.state.rs.techs.keys)
    }

    // MARK: View tab (Unciv MapEditorViewTab: tile info + map statistics)
    private var viewTab: some View {
        let s = controller.state
        let map = s.map
        return VStack(alignment: .leading, spacing: 6) {
            // Unciv MapEditorViewTab.update: ExpanderTab(mapParameters.name.ifEmpty { "New map" }, startsOutOpened = false)
            // holding a WrappableLabel of mapParameters.toString() with its "\"name\" " taken out
            DisclosureGroup(isExpanded: $parametersOpen) {
                Text(L(MapEditorView.mapParametersText(map))).font(Theme.small).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(L(mapParametersName.isEmpty ? "New map" : mapParametersName)).font(Theme.heading(14)).foregroundStyle(Theme.gold)
            }
            // Unciv MapEditorViewTab: "Area: [area] tiles, [water]% water, [impassable]% impassable, [n] continents/islands" -
            // tileMap.values, isWater and isImpassible() (the last terrain), `(count * 100f / area).toInt()`
            let real = map.tilesInUncivOrder()
            let area = real.count
            Text(L("Area: [\(area)] tiles, [\(percent(real.filter { $0.isWater }.count, of: area))]% water, [\(percent(real.filter { s.lastTerrainOf($0)?.impassable == true }.count, of: area))]% impassable, [\(map.continentSizes.count)] continents/islands")).font(Theme.caption).foregroundStyle(Theme.creamDim)
            // Unciv MapEditorViewTab: `add(editorScreen.descriptionTextField).growX()` under the statistics, no title;
            // descriptionTextField.onChange { isDirty = true } - typing, not a map load, marks the map changed
            TextField(L("Enter a description for the users of this map"), text: Binding(get: { description }, set: { description = $0; edited = true }))
                .textFieldStyle(.roundedBorder).font(Theme.body)
            // Unciv: "{Natural Wonders} (n)" - the wonders on the map by translated name, "{name} (count)" when several;
            // a tap scrolls round-robin to the next tile with it
            let wonders = naturalWonderCounts(real)
            if !wonders.isEmpty {
                Text("\(L("Natural Wonders")) (\(wonders.count))").font(Theme.heading(13)).foregroundStyle(Theme.gold)
                ForEach(Array(wonders.enumerated()), id: \.offset) { _, w in
                    Button(w.count == 1 ? L(w.name) : "\(L(w.name)) (\(w.count))") { scrollToNextTile(of: real.filter { $0.naturalWonder == w.name }.map { $0.coord }) }
                        .font(Theme.small).buttonStyle(.plain)
                }
            }
            // Unciv: "{Starting locations} (nations)" - getStartingLocationSummary, city-states last, by translated name
            let byNation = startingLocationsByNation()
            if !byNation.isEmpty {
                Text("\(L("Starting locations")) (\(byNation.count))").font(Theme.heading(13)).foregroundStyle(Theme.gold)
                ForEach(Array(startingLocationSummary(byNation).enumerated()), id: \.offset) { _, entry in
                    Button(entry.count == 1 ? L(entry.name) : "\(L(entry.name)) (\(entry.count))") { scrollToNextTile(of: byNation.first { $0.nation == entry.key }?.tiles ?? []) }
                        .font(Theme.small).buttonStyle(.plain)
                }
            }
            Divider2()
            if let t = controller.infoTile {
                // Unciv MapEditorViewTab.tileClickHandler: position, TileDescription, the yields as the all-tech mock civ
                // sees them (no city), the starting locations, the continent
                let p = map.uncivPosition(t)
                Text(L("Position: [(\(p.x),\(p.y))]")).font(Theme.small)
                ForEach(controller.tileDescription(t), id: \.self) { Text($0).font(Theme.small) }
                if let tile = map[t] {
                    let stats = s.tileStats(tile, civId: s.playerId, city: nil)
                    if !stats.isEmpty { Text(stats.uncivText).font(Theme.small) }
                }
                let nations = tileStartingLocationSummary(t)
                if !nations.isEmpty { Text(L("Starting location(s): [\(nations)]")).font(Theme.small).foregroundStyle(Theme.gold) }
                if let tile = map[t], tile.continent >= 0 {
                    // Unciv: the line links to "continent" - editorScreen.hideSelection(), then every tile whose getContinent()
                    // matches is highlighted Color.BROWN.darken(0.5f)
                    Button(L("Continent: [\(tile.continent)] ([\(map.continentSizes[tile.continent] ?? 0)] tiles)")) {
                        controller.editorHighlight = controller.state.map.tiles.filter { $0.continent == tile.continent }.map(\.coord)
                        controller.refresh(full: false)
                    }.font(Theme.small).buttonStyle(.plain)
                }
                // Unciv: "Resource abundance" - an UncivSlider 0..42 step 1 snapping (threshold 5) to 0-10, 12, 15, 20, 30, 40 -
                // for a resource with an amount or a strategic one; it sets tile.resourceAmount, updates the tile, isDirty
                if let tile = map[t], let r = tile.resource,
                   tile.resourceAmount > 0 || Ruleset.shared.resources[r]?.resourceType == "Strategic" {
                    Divider2()
                    HStack {
                        Text(L("Resource abundance")).font(Theme.small)
                        Spacer()
                    }
                    EpochsSlider(value: Binding(get: { Double(controller.state.map[t]?.resourceAmount ?? 0) },
                                                set: { setResourceAmount(t, MapEditorView.snapResourceAbundance($0)) }),
                                 range: 0...42, step: 0)   // the step is applied after the snap, as libGDX's Slider does
                }
            }   // Unciv: tileDataCell stays empty until a tile is clicked
        }
    }

    /// Unciv MapEditorViewTab statistics: `(count * 100f / area).toInt()` - a Float share, truncated.
    private func percent(_ part: Int, of total: Int) -> Int { total <= 0 ? 0 : Int(Float(part) * 100 / Float(total)) }

    /// Unciv MapParameters.toString() as MapEditorViewTab shows it (the "\"name\" " part taken out): "(" the size's name
    /// unless Custom, "{World Wrap} " when wrapped, the shape and displayMapDimensions - "R"radius on a hexagonal or flat
    /// earth map, else "width"x"height", "w" when wrapped - then ")". The resource setting, strategic balance and legendary
    /// start are the editor's defaults here (none of them shown), and a named map's second line - its generation type, seed
    /// and generator parameters - is not shown, as a map saved by Epochs does not keep them (MIRROR.md known departures).
    static func mapParametersText(_ map: GameMap) -> String {
        let size = map.uncivSize ?? UncivMapSize(width: map.width, height: map.height, shape: "Rectangular")
        var out = "("
        if size.name != "Custom" { out += "{\(size.name)} " }
        if map.wrapX { out += "{World Wrap} " }
        out += "{\(size.shape)}"
        out += " " + (size.isHexagonal ? "R\(size.radius)" : "\(size.width)x\(size.height)") + (map.wrapX ? "w" : "") + ")"
        return out
    }

    /// libGDX Slider.calculatePositionAndValue under Unciv's "Resource abundance" slider: snap() - the closest of
    /// setSnapToValues(threshold = 5f, 0..10, 12, 15, 20, 30, 40) within the threshold, the first on a tie, else the value
    /// itself - then ProgressBar.setValue's `clamp(Math.round(value / stepSize) * stepSize)` with stepSize 1 over 0..42.
    static func snapResourceAbundance(_ raw: Double) -> Double {
        let snapValues: [Float] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 15, 20, 30, 40]
        let value = Float(raw)
        var bestDiff: Float = -1, bestValue: Float = 0
        for snapValue in snapValues {
            let diff = abs(value - snapValue)
            if diff <= 5 && (bestDiff == -1 || diff < bestDiff) { bestDiff = diff; bestValue = snapValue }
        }
        let snapped = bestDiff == -1 ? value : bestValue
        return Double(min(42, max(0, (snapped + 0.5).rounded(.down))))   // Math.round: half up
    }
    /// Unciv's slider onChange: `tile.resourceAmount = it.toInt()`, editorScreen.updateTile(tile), editorScreen.isDirty = true
    private func setResourceAmount(_ t: HexCoord, _ value: Double) {
        let amount = Int(value)
        guard let current = controller.state.map[t], current.resourceAmount != amount else { return }   // a ChangeListener: only on a change
        controller.state.map[t]?.resourceAmount = amount
        edited = true
        controller.refresh()
    }

    /// Unciv MapEditorViewTab.naturalWonders: `tileMap.values.mapNotNull { it.naturalWonder }` sorted by translated name
    /// into a Counter (insertion order).
    private struct NameCount { let key: String; let name: String; var count: Int; var isCityState = false }
    private struct NationTiles { let nation: String; var tiles: [HexCoord] }
    private func naturalWonderCounts(_ tiles: [Tile]) -> [NameCount] {
        var out: [NameCount] = []
        for w in tiles.compactMap({ $0.naturalWonder }).sorted(by: { LocaleCode.compare(L($0), L($1)) == .orderedAscending }) {
            if let i = out.firstIndex(where: { $0.name == w }) { out[i].count += 1 } else { out.append(NameCount(key: w, name: w, count: 1)) }
        }
        return out
    }
    /// Unciv TileMap.startingLocationsByNation: nation -> its tiles, in the order the locations were added
    /// ("" is the Spectator entry the editor shows as "Any Civ").
    private func startingLocationsByNation() -> [NationTiles] {
        var out: [NationTiles] = []
        for sl in starts {
            if let i = out.firstIndex(where: { $0.nation == sl.nation }) { if !out[i].tiles.contains(sl.position) { out[i].tiles.append(sl.position) } }
            else { out.append(NationTiles(nation: sl.nation, tiles: [sl.position])) }
        }
        return out
    }
    /// Unciv MapEditorViewTab.getStartingLocationSummary: only nations of the ruleset, city-states last, by translated name.
    private func startingLocationSummary(_ byNation: [NationTiles]) -> [NameCount] {
        let rs = Ruleset.shared
        return byNation.compactMap { e -> NameCount? in
            let name = e.nation.isEmpty ? "Spectator" : e.nation
            guard let def = rs.nations[name] else { return nil }
            return NameCount(key: e.nation, name: name, count: e.tiles.count, isCityState: def.isCityState)
        }.sorted { a, b in a.isCityState != b.isCityState ? !a.isCityState : LocaleCode.compare(L(a.name), L(b.name)) == .orderedAscending }
    }
    /// Unciv MapEditorViewTab.getTileStartingLocationSummary: "{nation} ({usage})" for the tile's locations.
    private func tileStartingLocationSummary(_ t: HexCoord) -> String {
        let rs = Ruleset.shared
        return starts.filter { $0.position == t }.compactMap { sl -> NameCount? in
            let name = sl.nation.isEmpty ? "Spectator" : sl.nation
            guard let def = rs.nations[name] else { return nil }
            return NameCount(key: sl.usage.label, name: name, count: 1, isCityState: def.isCityState)
        }.sorted { a, b in a.isCityState != b.isCityState ? !a.isCityState : LocaleCode.compare(L(a.name), L(b.name)) == .orderedAscending }
         .map { "\(L($0.name)) (\(L($0.key)))" }.joined(separator: ", ")
    }
    /// Unciv MapEditorViewTab.scrollToNextTileOf: one global round-robin index over whatever list is clicked;
    /// `setCenterPosition(tile.position, blink = true)` - EditorMapHolder's, which selects nothing and blinks only when the
    /// map moves - then tileClickHandler(tile): its info, hideSelection() and the tile's highlight.
    private func scrollToNextTile(of tiles: [HexCoord]) {
        if tiles.isEmpty { return }
        if roundRobinIndex >= tiles.count { roundRobinIndex = 0 }
        let t = tiles[roundRobinIndex]; roundRobinIndex += 1
        controller.scene.center(on: t)
        controller.infoTile = t; controller.editorHighlight = []
        controller.refresh(full: false)
    }

    // MARK: Generate tab (Unciv MapEditorGenerateTab)
    private var generateTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Map Type")).font(Theme.heading(13)).foregroundStyle(Theme.gold)
            // Unciv addMapTypeSelectBox: `if (forMapEditor ...) mapTypes = mapTypes + MapType.empty`
            FlowButtons(options: MapTypeInfo.generatedTypes + ["Empty"], selected: genType) { genType = $0 }
            Text(L("Map Shape")).font(Theme.heading(13)).foregroundStyle(Theme.gold)
            FlowButtons(options: ["Rectangular", "Hexagonal", "Flat Earth Hexagonal"], selected: genShape) { genShape = $0 }
            Text(L("World Size")).font(Theme.heading(13)).foregroundStyle(Theme.gold)
            FlowButtons(options: MapSizePreset.allCases.map { $0.rawValue }, selected: genSize) { genSize = $0 }
            // addWrappedCheckBoxes: Strategic Balance and Legendary Start only travel with the map's MapParameters here
            // (no regions on the editor's path); a game on the map file plays with them
            Toggle(L("Strategic Balance"), isOn: $genAdv.strategicBalance).tint(Theme.gold).font(Theme.body)
            Toggle(L("Legendary Start"), isOn: $genAdv.legendaryStart).tint(Theme.gold).font(Theme.body)
            Toggle(L("World Wrap"), isOn: $genWrap).tint(Theme.gold).font(Theme.body)
            // Unciv MapParametersTable: the ruins and natural wonders boxes are hidden for an Empty map
            if genType != "Empty" {
                // "No Ancient Ruins".toCheckBox(mapParameters.noRuins) / "No Natural Wonders".toCheckBox(mapParameters.noNaturalWonders)
                Toggle(L("No Ancient Ruins"), isOn: Binding(get: { !genRuins }, set: { genRuins = !$0 })).tint(Theme.gold).font(Theme.body)
                Toggle(L("No Natural Wonders"), isOn: Binding(get: { !genWonders }, set: { genWonders = !$0 })).tint(Theme.gold).font(Theme.body)
            }
            HStack {
                Text(L("Mirroring Type")).font(Theme.body)
                Spacer()
                // Unciv addMirrorSelectBox: "only support these, as the rest seem buggy" - None and Left-right
                Picker(L("Mirroring Type"), selection: $genMirroring) { ForEach(["None", "Left-right"], id: \.self) { Text(L($0)).tag($0) } }.pickerStyle(.menu).tint(Theme.gold)
            }
            // addResourceSelectBox: "This is used for painting resources, not in map generator steps:"
            Text(L("This is used for painting resources, not in map generator steps:")).font(Theme.caption).foregroundStyle(Theme.gold)
            HStack {
                Text(L("Resource Setting") + ":").font(Theme.body)
                Spacer()
                Picker(L("Resource Setting"), selection: $genAdv.resourceSetting) { ForEach(["Sparse", "Default", "Abundant"], id: \.self) { Text(L($0)).tag($0) } }.pickerStyle(.menu).tint(Theme.gold)
            }
            DisclosureGroup(isExpanded: $genAdvOpen) { generateAdvanced } label: { Text(L("Advanced Settings")).font(Theme.heading(13)).foregroundStyle(Theme.gold) }
            Button(L("Generate")) { generate() }.buttonStyle(ThemedButtonStyle(filled: true))
            Divider2()
            Text(L("Generator steps")).font(Theme.heading(13)).foregroundStyle(Theme.gold)
            FlowButtons(options: MapGenerator.steps, selected: genStep ?? "") { genStep = $0 }
            Button(L("Generate")) { if let step = genStep { runStep(step) } }
                .buttonStyle(ThemedButtonStyle(compact: true)).disabled(genStep == nil)
        }
    }

    /// Unciv MapParametersTable.addAdvancedControls(forMapEditor = true): seed, "Randomize seed", the sliders (Resource
    /// richness only here) and "Reset to defaults" (MapParameters.resetAdvancedSettings - a new seed and the defaults)
    private var generateAdvanced: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(L("RNG Seed")).font(Theme.body); TextField("0", text: $genSeed).textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation).frame(width: 140) }
            Toggle(L("Randomize seed"), isOn: $genRandomizeSeed).tint(Theme.gold).font(Theme.body)
            advSlider("Map Elevation", $genAdv.elevationExponent, 0.6...0.8, 0.01)
            advSlider("Temperature intensity", $genAdv.temperatureIntensity, 0.4...0.8, 0.02)
            advSlider("Temperature shift", $genAdv.temperatureShift, -0.4...0.4, 0.1)
            advSlider("Resource richness", $genResourceRichness, 0...0.5, 0.025)
            advSlider("Vegetation richness", $genAdv.vegetationRichness, 0...1, 0.05)
            advSlider("Rare features richness", $genAdv.rareFeaturesRichness, 0...0.5, 0.025)
            IntSliderRow(title: L("Max Coast extension"), value: genAdv.maxCoastExtension, range: Int(1)...Int(5)) { genAdv.maxCoastExtension = $0 }
            IntSliderRow(title: L("Biome size"), value: genAdv.tilesPerBiomeArea, range: Int(1)...Int(15)) { genAdv.tilesPerBiomeArea = $0 }
            advSlider("Water level", $genAdv.waterThreshold, -0.1...0.1, 0.01)
            Button(L("Reset to defaults")) {
                let d = GameSettings()
                genAdv.elevationExponent = d.elevationExponent; genAdv.temperatureIntensity = d.temperatureIntensity; genAdv.temperatureShift = d.temperatureShift
                genAdv.vegetationRichness = d.vegetationRichness; genAdv.rareFeaturesRichness = d.rareFeaturesRichness; genAdv.waterThreshold = d.waterThreshold
                genAdv.maxCoastExtension = d.maxCoastExtension; genAdv.tilesPerBiomeArea = d.tilesPerBiomeArea; genResourceRichness = 0.1
                genSeed = NewGameScreen.seedString(NewGameScreen.freshSeed())   // resetAdvancedSettings: reseed()
            }.buttonStyle(ThemedButtonStyle(compact: true))
        }
    }
    private func advSlider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(L(title)).font(Theme.caption).foregroundStyle(Theme.creamDim); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).font(Theme.caption.bold()).foregroundStyle(Theme.gold) }
            EpochsSlider(value: value, range: range, step: step)
        }
    }
    /// The Generate tab's map parameters on a generator's settings (newMapParameters' advanced values and resources)
    private func applyGenerateParameters(_ s: inout GameSettings) {
        s.elevationExponent = genAdv.elevationExponent; s.temperatureIntensity = genAdv.temperatureIntensity; s.temperatureShift = genAdv.temperatureShift
        s.vegetationRichness = genAdv.vegetationRichness; s.rareFeaturesRichness = genAdv.rareFeaturesRichness; s.waterThreshold = genAdv.waterThreshold
        s.maxCoastExtension = genAdv.maxCoastExtension; s.tilesPerBiomeArea = genAdv.tilesPerBiomeArea; s.resourceSetting = genAdv.resourceSetting
        s.strategicBalance = genAdv.strategicBalance; s.legendaryStart = genAdv.legendaryStart
    }
    /// MapEditorGenerateTab.generate(step): "reseed visibly if the 'Randomize seed' checkbox is checked", then the seed
    private func generateSeed() -> UInt64 {
        if genRandomizeSeed { genSeed = NewGameScreen.seedString(NewGameScreen.freshSeed()) }   // mapParameters.reseed()
        // MapGenerator.generateMap / generateSingleStep: `if (seed == 0L) seed = System.currentTimeMillis()`
        let seed = NewGameScreen.parseSeed(genSeed) ?? 0
        return seed == 0 ? NewGameScreen.freshSeed() : seed
    }

    /// Unciv MapEditorGenerateTab.generate(step) for a single step. Landmass builds a NEW map from the Generate tab's
    /// parameters (type Empty, then the step with the chosen type) - "This step _could_ run on an existing tileMap, but
    /// that opens a loophole where you get hills on water"; every other step runs over the map that is already there.
    private func runStep(_ step: String) {
        if step == "Generate landmass" && genType == "Empty" {
            message = L("Please don't use step 'Landmass' with map type 'Empty', create a new empty map instead.")
            return
        }
        let seed = generateSeed()
        if step == "Generate landmass" {
            // Unciv MapEditorGenerateTab.generate: an exception of the generator shows "It looks like we can't make a map
            // with the parameters you requested!" and leaves the map as it is - and the editor's ruleset, the new one
            // being used only by freshMapCompleted: the ruleset, map wrap and coastal lookup are put back
            do {
                let fresh: GameMap = try SaveManager.restoringGlobalsOnFailure {
                    var gen = newMapGenerator(seed: seed)
                    gen.mapType = "Empty"   // `mapParameters.type = MapType.empty; generator.generateMap(mapParameters)`
                    var fresh = try gen.generate(width: gen.mapSize?.width ?? 0, height: gen.mapSize?.height ?? 0)
                    gen.mapType = MapGenerator.canonicalType(genType)   // `mapParameters.type = editorScreen.newMapParameters.type`
                    HexCoord.wrapWidth = fresh.wrapX ? fresh.width : nil
                    try gen.runStep(step, &fresh)   // generator.generateSingleStep(generatedMap, step)
                    return fresh
                }
                freshMapCompleted(fresh, seed: seed)
            } catch { message = L("It looks like we can't make a map with the parameters you requested!") }
            return
        }
        var s = GameSettings()
        s.mapType = genType; s.mapShape = genShape; s.worldWrap = controller.state.map.wrapX; s.seed = seed
        applyGenerateParameters(&s)
        var gen = MapGenerator(seed: seed)
        gen.mapType = s.mapType; gen.wrapX = s.worldWrap; gen.configure(s); gen.resourceRichness = Float(genResourceRichness)
        // a single step runs on the map itself (Unciv generateSingleStep(editorScreen.tileMap, step)): what it did before
        // an exception stays, as in Unciv
        mapSeed = seed   // Unciv: `editorScreen.tileMap.mapParameters.seed = mapParameters.seed`, before the step
        do { try gen.runStep(step, &controller.state.map) }
        catch {
            // Unciv: the exception goes straight to the catch's popup - stepCompleted (isDirty, updateTileGroups) is not run
            message = L("It looks like we can't make a map with the parameters you requested!"); return
        }
        edited = true; genSeed = NewGameScreen.seedString(seed)   // Unciv stepCompleted: isDirty = true
        controller.scene.resetTiles(); controller.refresh()
    }
    /// The Generate tab's parameters (Unciv MapEditorScreen.newMapParameters) as a generator: a predefined size keeps
    /// Unciv's MapSize - fixUndesiredSizes leaves those alone, and a wrapped odd width is rounded down by the TileMap
    /// constructor (wrapAdjustedWidth), not up - and a hexagonal map takes the size's radius.
    private func newMapGenerator(seed: UInt64) -> MapGenerator {
        // `RulesetCache.getComplexRuleset(mapParameters)`: a new map is made in the ruleset chosen on the Mods page
        Ruleset.activate(mods: activeMods, baseRuleset: selectedBaseRuleset)
        var s = GameSettings()
        s.mapType = genType; s.mapShape = genShape; s.worldWrap = genWrap; s.ancientRuins = genRuins; s.naturalWonders = genWonders
        s.mapSizeName = genSize
        if let preset = MapSizePreset(rawValue: genSize) { s.mapWidth = preset.width; s.mapHeight = preset.height }
        s.seed = seed
        applyGenerateParameters(&s)
        newMapParameters = s   // the generated TileMap keeps them (`mapParameters.clone()`, loaded by freshMapCompleted)
        var gen = MapGenerator(seed: seed)
        gen.mapType = s.mapType; gen.wrapX = s.worldWrap; gen.configure(s); gen.resourceRichness = Float(genResourceRichness)
        if let preset = MapSizePreset(rawValue: genSize) { gen.mapSize = UncivMapSize(preset: preset, shape: genShape) }
        // Unciv MapEditorGenerateTab: generateMap always ends with spreadResources - MapParametersTable(forMapEditor) has no
        // switch for it, only the Resource Setting and richness above (ours offered a "Resources" toggle Unciv does not)
        gen.mirroring = genMirroring
        return gen
    }
    private func generate() {
        let seed = generateSeed()
        // a failed generation leaves the editor's ruleset, map wrap and coastal lookup as they were (Unciv's newRuleset is
        // used only by freshMapCompleted)
        guard let map = try? SaveManager.restoringGlobalsOnFailure({ () throws -> GameMap in
            var gen = newMapGenerator(seed: seed)
            return try gen.generate(width: gen.mapSize?.width ?? 0, height: gen.mapSize?.height ?? 0)
        }) else {
            message = L("It looks like we can't make a map with the parameters you requested!"); return
        }
        freshMapCompleted(map, seed: seed)
        tab = "View"   // freshMapCompleted(selectPage = 0); a Landmass step stays on the Generate tab (selectPage = 1)
        controller.state.map.assignContinents(.ensure)
    }
    /// Unciv MapEditorGenerateTab.freshMapCompleted: the new map is loaded (no starting locations) and counts as changed.
    private func freshMapCompleted(_ map: GameMap, seed: UInt64) {
        controller.state.map = map
        HexCoord.wrapWidth = controller.state.map.wrapX ? controller.state.map.width : nil
        if let i = controller.state.civIndex(controller.state.playerId) { controller.state.civs[i].explored = Set(controller.state.map.tiles.map { $0.coord }) }
        starts = []; genSeed = NewGameScreen.seedString(seed); mapParametersName = ""   // newMapParameters: no name
        // Unciv loadMap: the generated TileMap has the Generate tab's parameters (its seed, the chosen ruleset) and no
        // description yet
        mapSeed = seed; description = ""
        mapParameters = newMapParameters
        mapBaseRuleset = selectedBaseRuleset; mapMods = activeMods
        refreshEditorCiv()
        brush = nil   // Unciv newMapHolder sets editTabsNeedRefresh, and the Edit tab then resets its brush to None
        controller.scene.resetTiles(); controller.scene.scrollToMiddle(); controller.refresh()   // newMapHolder: the middle of the map
        edited = true   // Unciv freshMapCompleted: loadMap (isDirty = false), then isDirty = true
    }

    // MARK: Edit tab (Unciv MapEditorEditTab sub-tabs as chip rows)
    private var editTab: some View {
        let rs = Ruleset.shared
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Unciv MapEditorEditTab: "Brush ([size]):" with getBrushTip(abbreviate = true) - the size, or "Floodfill_Abbreviation"
                Text(L("Brush ([\(brushSize == 6 ? "Floodfill_Abbreviation" : String(brushSize))]):")).font(Theme.caption.bold()).foregroundStyle(Theme.gold)
                Text(brushName).font(Theme.caption).foregroundStyle(Theme.cream)
                Spacer()
                EpochsSlider(value: Binding(get: { Double(brushSize) }, set: { brushSize = Int($0) }), range: 1...6, step: 1).frame(width: 110, height: 24)
            }
            Divider2()
            Text(L("Terrain")).font(Theme.small).foregroundStyle(Theme.creamDim)
            FlowChips(items: rs.baseTerrains.filter { !$0.uniques.contains("Excluded from map editor") }.map { ($0.name, EditorBrush.terrain($0.name)) }, brush: $brush)
            // Unciv MapEditorEditFeaturesTab: the "Remove features" eraser, then every feature not excluded from the editor
            Text(L("Features")).font(Theme.small).foregroundStyle(Theme.creamDim)
            FlowChips(items: [(L("Remove features"), EditorBrush.clearFeatures)] + rs.terrainFeatures.filter { !$0.uniques.contains("Excluded from map editor") }.map { ($0.name, EditorBrush.feature($0.name)) }, brush: $brush)
            // Unciv MapEditorEditResourcesTab: the eraser, then the resources in ruleset order without the Mercantile
            // city-state ones (CityStateOnlyResource) and those excluded from the editor
            Text(L("Resources")).font(Theme.small).foregroundStyle(Theme.creamDim)
            FlowChips(items: [(L("Remove resource"), EditorBrush.clearResource)] + rs.resourcesInOrder.filter { r in
                !r.uniqueObjects.contains { $0.pattern == "Can only be created by Mercantile City-States" || $0.pattern == "Excluded from map editor" }
            }.map { ($0.name, EditorBrush.resource($0.name)) }, brush: $brush)
            // Unciv MapEditorEditImprovementsTab: the "Remove improvement" eraser, then every improvement in ruleset order
            // that is not excluded from the editor (Ancient ruins and City ruins included, the Barbarian encampment not)
            Text(L("Improvements")).font(Theme.small).foregroundStyle(Theme.creamDim)
            FlowChips(items: [(L("Remove improvement"), EditorBrush.removeImprovement)] + rs.improvementOrder.compactMap { rs.improvements[$0] }.filter { i in
                !i.uniqueObjects.contains { $0.pattern == "Excluded from map editor" }
            }.map { ($0.name, EditorBrush.improvement($0.name)) }, brush: $brush)
            Text(L("Natural Wonders")).font(Theme.small).foregroundStyle(Theme.creamDim)
            FlowChips(items: rs.naturalWonders.filter { !$0.uniques.contains("Excluded from map editor") }.map { ($0.name, EditorBrush.wonder($0.name)) }, brush: $brush)
            // Unciv MapEditorEditStartsTab: an eraser, "Any Civ" and one brush per nation, plus the Usage choice
            Text(L("Starting locations")).font(Theme.small).foregroundStyle(Theme.creamDim)
            Text(L("Use for new game \"Select players\" button:")).font(Theme.small).foregroundStyle(Theme.creamDim)
            FlowButtons(options: StartingLocation.Usage.allCases.map { $0.label }, selected: startUsage.label) { l in
                startUsage = StartingLocation.Usage.allCases.first { $0.label == l } ?? .player
            }
            FlowChips(items: [(L("Remove starting locations"), EditorBrush.removeStarts), (L("Any Civ"), EditorBrush.start(""))] + editorNations.map { ($0, EditorBrush.start($0)) }, brush: $brush)
            // Unciv MapEditorEditRiversTab
            Text(L("Rivers")).font(Theme.small).foregroundStyle(Theme.creamDim)
            FlowChips(items: [(L("Remove rivers"), EditorBrush.removeRivers), (L("Bottom left river"), EditorBrush.riverEdge(HexCoord.dirSW)), (L("Bottom river"), EditorBrush.riverEdge(HexCoord.dirS)), (L("Bottom right river"), EditorBrush.riverEdge(HexCoord.dirSE)), (L("Spawn river from/to"), EditorBrush.spawnRiver)], brush: $brush)
        }
    }

    // MARK: Load tab (Unciv MapEditorLoadTab: saved maps + "Load copied map")
    private var loadTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(L("Load copied data")) { loadFromClipboard() }.buttonStyle(ThemedButtonStyle(compact: true))
                // Unciv MapEditorWesnothImporter ("Import a Wesnoth map"): TerrainCodesWML text from the clipboard.
                // MapEditorWesnothImporter.onImportButtonClicked: `editorScreen.askIfDirtyForLoad(::openFileDialog)`
                Button(L("Import a Wesnoth map")) { askIfDirtyForLoad { importWesnoth() } }.buttonStyle(ThemedButtonStyle(compact: true))
            }
            // Unciv MapEditorLoadTab: the MapEditorFilesTable of the maps folder, untitled, empty when there are none
            ForEach(savedMaps, id: \.self) { m in
                Button { selectedSaved = m } label: { HStack { Text(m).font(Theme.body); Spacer(); if selectedSaved == m { Image(systemName: "checkmark").foregroundStyle(Theme.gold) } } }.buttonStyle(.plain)
            }
            if let sel = selectedSaved {
                HStack {
                    // Unciv MapEditorLoadTab.loadHandler: `editorScreen.askIfDirtyForLoad { ... loaderThread(mapFile) }`
                    Button(L("Load map")) { askIfDirtyForLoad { loadSavedMap(sel) } }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                    Button(L("Delete map")) { pendingMapDeletion = sel }.buttonStyle(ThemedButtonStyle(destructive: true, compact: true))
                }
            }
        }
    }
    /// Unciv MapEditorLoadTab.loaderThread: a base ruleset still listed among the mods moves to its own field; missing
    /// mods refuse the load ("Error loading map!" with "Missing mods: [...]"); otherwise the map's ruleset is taken and
    /// anything the ruleset does not know is removed, with a "This map has errors:" toast listing it.
    private func loadSavedMap(_ name: String) {
        guard var m = MapStore.load(name: name) else { message = L("Error loading map!"); return }
        if let modBase = m.mods.first(where: { Ruleset.baseRulesets.contains($0) }) {
            m.baseRuleset = modBase
            m.mods.removeAll { $0 == modBase }
        }
        let installed = Set(Ruleset.availableMods())
        let missingMods = ([m.baseRuleset] + m.mods).filter { !Ruleset.baseRulesets.contains($0) && !installed.contains($0) }
        if !missingMods.isEmpty {
            message = L("Error loading map!") + "\n" + L("Missing mods: [\(missingMods.joined(separator: ", "))]")
            return
        }
        // A map file's units never load in Unciv 4.22.1's editor: MapEditorScreen.loadMap's newMapHolder runs
        // tileMap.setTransients(ruleset, false), whose MapUnit.setTransients -> updateUniques reads the unit's lateinit
        // civ (UninitializedPropertyAccessException, measured with maps of in-ruleset and missing owners), caught by the
        // loader's GL-thread block as "Error loading map!" (ours keeps the map it had, see MIRROR.md)
        if !m.unitOwners.isEmpty { message = L("Error loading map!"); return }
        Ruleset.activate(mods: m.mods, baseRuleset: m.baseRuleset)   // RulesetCache.getComplexRuleset(map.mapParameters)
        let incompatibilities = NewGameScreen.rulesetIncompatibilities(m)
        apply(m.removingMissingTerrainModReferences(), name: name)
        if !incompatibilities.isEmpty {
            message = L("This map has errors:") + "\n\n" + incompatibilities.sorted().map { L($0) }.joined(separator: "\n") + "\n\n" + L("The incompatible elements have been removed.")
        }
    }
    /// Unciv MapEditorScreen.loadMap: the map, its description and its ruleset (the Mods tab then shows the map's own),
    /// a fresh map holder, and nothing unsaved.
    private func apply(_ m: CustomMap, name: String) {
        if Ruleset.currentBaseRuleset != m.baseRuleset || Ruleset.shared.mods != m.mods.filter({ Ruleset.availableMods().contains($0) }) {
            Ruleset.activate(mods: m.mods.filter { Ruleset.availableMods().contains($0) }, baseRuleset: m.baseRuleset)
        }
        mapBaseRuleset = m.baseRuleset; mapMods = m.mods
        selectedBaseRuleset = m.baseRuleset; activeMods = m.mods   // modsTabNeedsRefresh -> revertControls
        description = m.description; mapSeed = m.seed               // descriptionTextField.text = map.description
        controller.state.map = m.map
        refreshEditorCiv()
        HexCoord.wrapWidth = m.map.wrapX ? m.map.width : nil
        if let i = controller.state.civIndex(controller.state.playerId) { controller.state.civs[i].explored = Set(m.map.tiles.map { $0.coord }) }
        starts = m.startingLocations; mapName = name; mapParametersName = name
        mapParameters = m.parameters
        brush = nil   // Unciv newMapHolder sets editTabsNeedRefresh, and the Edit tab then resets its brush to None
        controller.scene.resetTiles(); controller.scene.scrollToMiddle(); controller.refresh()   // newMapHolder: the middle of the map
        edited = false   // Unciv MapEditorScreen.loadMap: isDirty = false
        tab = "View"     // loadMap(selectPage = 0): the View tab, whose activation ensures the continents
        controller.state.map.assignContinents(.ensure)
    }
    private func importWesnoth() {
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }   // Unciv: pasteMapButton.isEnabled = Gdx.app.clipboard.hasContents()
        // Unciv MapEditorWesnothImporter.startImport: an UncivShowableException's own message is toasted (translated),
        // anything else only "Could not load map!"
        do { let m = try WesnothImporter.parse(text, rs: controller.state.rs); apply(m, name: "") }   // Unciv loadMap: the imported map's new MapParameters, no name
        catch let e as WesnothImporter.ImportError { message = L(e.message) }
        catch { message = L("Could not load map!") }
    }
    private func loadFromClipboard() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }   // Unciv: pasteMapButton.isEnabled = Gdx.app.clipboard.hasContents()
        // Unciv MapEditorOptionsTab.pasteHandler: only MapSaver.mapFromSavedString - a Wesnoth map is not a saved map
        // Unciv loadMap keeps the pasted map's own mapParameters.name (an Epochs map carries none); a map with units throws
        // in MapEditorScreen.loadMap as a loaded one does (see loadSavedMap), caught as "Could not load map!"
        if let data = text.data(using: .utf8), let m = try? JSONDecoder().decode(CustomMap.self, from: data) {
            if m.unitOwners.isEmpty { apply(m, name: "") } else { message = L("Could not load map!") }
            return
        }
        let root = UncivSave.decodeToJSONData(text).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let pastedName = ((root?["mapParameters"] as? [String: Any])?["name"] as? String) ?? ""
        do {
            let m = try UncivSave.importMap(from: text)
            if m.unitOwners.isEmpty { apply(m, name: pastedName) } else { message = L("Could not load map!") }
        } catch { message = L("Could not load map!") }
    }

    // MARK: Save tab (Unciv MapEditorSaveTab: name, save, copy to clipboard, save to custom location)
    private var saveTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("Map Name"), text: $mapName).textFieldStyle(.roundedBorder).font(Theme.body)   // Unciv UncivTextField("Map Name")
            Button(L("Save map")) { save() }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
            Button(L("Copy to clipboard")) { UIPasteboard.general.string = UncivSave.exportMap(currentCustomMap(), name: mapName) }.buttonStyle(ThemedButtonStyle(compact: true))
            Button(L("Save to custom location")) {
                let text = UncivSave.exportMap(currentCustomMap(), name: mapName)
                SaveManager.shareFile(Data(text.utf8), fileName: "\(mapName).map")
            }.buttonStyle(ThemedButtonStyle(compact: true))
        }
    }
    private func save() {
        let name = mapName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            mapParametersName = name   // Unciv saveHandler: tileMap.mapParameters.name = mapNameTextField.text
            try MapStore.save(currentCustomMap(), name: name); savedMaps = MapStore.list(); message = L("Map saved successfully!")   // Unciv saverThread: ToastPopup("Map saved successfully!")
            edited = false   // Unciv MapEditorSaveTab.saverThread: isDirty = false after a successful save
        }
        catch { message = L("It looks like your map can't be saved!") }   // Unciv saverThread: a Popup with this line and Close
    }

    // MARK: Mods tab (Unciv MapEditorModsTab: choose the ruleset the map uses)
    private var modsTab: some View {
        let installed = Ruleset.availableMods()
        // enableApplyButton: both buttons only while the page differs from the map's own ruleset
        let differs = Set(activeMods) != Set(mapMods) || selectedBaseRuleset != mapBaseRuleset   // LinkedHashSet equality
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(L("Base Ruleset")):").font(Theme.heading(13)).foregroundStyle(Theme.gold)
            // baseRulesetSelectBox.onChange: the new base, every mod checkbox cleared (disableAllCheckboxes)
            FlowButtons(options: Ruleset.baseRulesets, selected: selectedBaseRuleset) { pick in
                if pick != selectedBaseRuleset { selectedBaseRuleset = pick; activeMods = [] }
            }
            HStack {
                Button(L("Change map ruleset")) { applyRulesetControls() }.buttonStyle(ThemedButtonStyle(filled: true, compact: true)).disabled(!differs)
                // revertControls: the page shows the map's ruleset again
                Button(L("Revert to map ruleset")) { selectedBaseRuleset = mapBaseRuleset; activeMods = mapMods }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(!differs)
            }
            // Unciv ModCheckboxTable.setBaseRuleset: no compatible mod leaves the table empty
            ForEach(installed.filter { Ruleset.modMeetsBaseRequirements($0) }, id: \.self) { m in
                let allowed = activeMods.contains(m) || Ruleset.modMeetsAllRequirements(m, selected: activeMods + [m])   // Unciv ModCompatibility
                Button {
                    if let i = activeMods.firstIndex(of: m) { activeMods.remove(at: i) } else { activeMods.append(m) }
                    activeMods = Ruleset.pruneModSelection(activeMods)
                } label: { HStack { Image(systemName: activeMods.contains(m) ? "checkmark.square.fill" : "square").foregroundStyle(Theme.gold); Text(m).font(Theme.body); Spacer() } }.buttonStyle(.plain)
                    .disabled(!allowed).opacity(allowed ? 1 : 0.45).comingSoon(mods: true, place: "map_editor")   // the store build's mods are not open yet
            }
            // Unciv AskFitMapToRulesetPopup: the incompatibilities, then "Change map to fit selected ruleset?" Yes / No
            if let incompatibilities = pendingFit {
                Divider2()
                ForEach(incompatibilities, id: \.self) { Text(L($0)).font(Theme.small).foregroundStyle(Theme.creamDim) }
                Text(L("Change map to fit selected ruleset?")).font(Theme.heading(13)).foregroundStyle(Theme.gold)
                HStack {
                    Button(L("Yes")) { pendingFit = nil; fitMapToRuleset(); applyRuleset() }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                    Button(L("No")) { pendingFit = nil }.buttonStyle(ThemedButtonStyle(compact: true))
                }
            }
        }
    }

    /// Unciv MapEditorModsTab.applyControls: the selected ruleset is applied at once when every tile fits it, otherwise
    /// the player is asked whether to fit the map to it.
    private func applyRulesetControls() {
        guard let newRuleset = try? Ruleset(named: selectedBaseRuleset, mods: activeMods) else { message = L("Could not load map!"); return }
        let incompatibilities = tileIncompatibilities(newRuleset)
        if incompatibilities.isEmpty { applyRuleset() } else { pendingFit = incompatibilities }
    }
    /// Unciv MapEditorModsTab.getIncompatibilities: Tile.getRulesetIncompatibility of every tile, "" removed, sorted.
    private func tileIncompatibilities(_ ruleset: Ruleset) -> [String] {
        var out = Set<String>()
        for t in controller.state.map.tilesInUncivOrder() {
            if ruleset.terrains[t.baseTerrain] == nil { out.insert("Base terrain [\(t.baseTerrain)] does not exist in ruleset!") }
            for f in t.features where ruleset.terrains[f] == nil { out.insert("Terrain feature [\(f)] does not exist in ruleset!") }
            if let r = t.resource, ruleset.resources[r] == nil { out.insert("Resource [\(r)] does not exist in ruleset!") }
            if let imp = t.improvement, ruleset.improvements[imp] == nil { out.insert("Improvement [\(imp)] does not exist in ruleset!") }
            if let w = t.naturalWonder, ruleset.terrains[w] == nil { out.insert("Natural Wonder [\(w)] does not exist in ruleset!") }
        }
        return out.sorted()
    }
    /// Unciv MapEditorModsTab.fitMapToRuleset: TileNormalizer.normalizeToRuleset on every tile, with the new ruleset.
    private func fitMapToRuleset() {
        Ruleset.activate(mods: activeMods, baseRuleset: selectedBaseRuleset)
        for t in controller.state.map.tilesInUncivOrder() { controller.state.normalizeTileToRuleset(t.coord) }
    }
    /// Unciv MapEditorScreen.applyRuleset: the map's parameters take the base ruleset and mods, the editor runs on that
    /// ruleset and the map holder is rebuilt (isDirty, the Edit tab's brush back to None).
    private func applyRuleset() {
        Ruleset.activate(mods: activeMods, baseRuleset: selectedBaseRuleset)
        mapBaseRuleset = selectedBaseRuleset; mapMods = activeMods
        refreshEditorCiv()
        brush = nil   // Unciv MapEditorEditTab.activated after editTabsNeedRefresh: BrushHandlerType.None
        edited = true   // newMapHolder: isDirty = true
        controller.scene.resetTiles(); controller.scene.scrollToMiddle(); controller.refresh()   // newMapHolder: the middle of the map
    }

    // MARK: Options tab (Unciv MapEditorOptionsTab)
    private var optionsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Unciv MapEditorOptionsTab has no resource / improvement switches: the editor's plain TileGroups always draw the
            // icons (`if (tileGroup is WorldTileGroup) settings.showResourcesAndImprovements else true`, MapScene.isMapEditor)
            // Unciv MapEditorOptionsTab: "Current map RNG seed: [x]" with a copy button.
            // (MapEditorOptionsTab.activated: `seedToCopy = editorScreen.tileMap.mapParameters.seed.toString()` - the map's own)
            Text(L("Current map RNG seed: [\(mapSeed)]")).font(Theme.caption).foregroundStyle(Theme.gold)
            Button(L("Copy to clipboard")) { UIPasteboard.general.string = "\(mapSeed)" }.buttonStyle(ThemedButtonStyle(compact: true))
            // Unciv MapEditorOptionsTab: "Current map: World Wrap", disabled when the geometry does not allow flipping it
            Toggle(L("Current map: World Wrap"), isOn: Binding(get: { controller.state.map.wrapX }, set: { setWorldWrap($0) }))
                .tint(Theme.gold).font(Theme.body).disabled(!canChangeWorldWrap)
            Text(L("Tile Matching Criteria")).font(Theme.heading(13)).foregroundStyle(Theme.gold)
            FlowButtons(options: MapEditorView.tileMatchFuzziness, selected: matchFuzziness) { matchFuzziness = $0 }
            Button(L("Copy to clipboard")) { UIPasteboard.general.string = UncivSave.exportMap(currentCustomMap(), name: mapName) }.buttonStyle(ThemedButtonStyle(compact: true))
            Button(L("Load copied data")) { loadFromClipboard() }.buttonStyle(ThemedButtonStyle(compact: true))
        }
    }

    /// Unciv MapEditorOptionsTab.canChangeWorldWrap: hexagonal maps can never flip it, a too small map neither,
    /// and turning it on needs an even width (our maps keep the width they were built with, so we only allow that).
    private var canChangeWorldWrap: Bool {
        let map = controller.state.map
        if map.hexRadius != nil { return false }
        if map.width < MapSizePreset.Tiny.width || map.height < MapSizePreset.Tiny.height { return false }
        // A grid laid out from Unciv positions whose column shift needed an extra, empty column 0 cannot close the seam
        if !map.wrapX && (0..<map.height).allSatisfy({ map.missing.contains($0 * map.width) }) { return false }
        return map.wrapX || map.width % 2 == 0
    }
    /// Unciv MapEditorScreen.setWorldWrap: the map holder is rebuilt around the new geometry.
    private func setWorldWrap(_ value: Bool) {
        guard canChangeWorldWrap, value != controller.state.map.wrapX else { return }
        controller.state.map.wrapX = value
        HexCoord.wrapWidth = value ? controller.state.map.width : nil
        edited = true
        brush = nil   // Unciv newMapHolder sets editTabsNeedRefresh, and the Edit tab then resets its brush to None
        controller.scene.resetTiles(); controller.scene.scrollToMiddle(); controller.refresh()   // newMapHolder: the middle of the map
    }

    /// Unciv MapEditorEditStartsTab.getNations: every nation the ruleset allows in the editor, city-states last.
    private var editorNations: [String] {
        let rs = Ruleset.shared
        func allowed(_ list: [NationDef]) -> [String] { list.filter { !$0.uniques.contains("Excluded from map editor") }.map { $0.name }.sorted() }
        return allowed(rs.majorNations) + allowed(rs.cityStateNations)
    }

    // MARK: painting
    private var brushName: String {
        guard let brush else { return "" }   // Unciv: the brush cell stays empty until a brush is picked
        switch brush {
        case .terrain(let n), .feature(let n), .resource(let n), .wonder(let n), .improvement(let n): return L(n)
        case .clearFeatures: return L("Remove features"); case .clearResource: return L("Remove resource")
        case .removeImprovement: return L("Remove improvement")
        case .start(let n): return n.isEmpty ? L("Any Civ") : L(n)
        case .removeStarts: return L("Remove starting locations")
        case .riverEdge(let d): return d == HexCoord.dirSW ? L("Bottom left river") : (d == HexCoord.dirS ? L("Bottom river") : L("Bottom right river"))
        case .removeRivers: return L("Remove rivers")
        case .spawnRiver: return L("Spawn river from/to")
        }
    }

    /// Unciv MapEditorScreen.tileClickHandler: only the View tab (tile info) and the Edit tab (the brush) install one;
    /// on every other tab a tap on the map does nothing.
    private func paint(_ hex: HexCoord) {
        guard tab == "Edit" || tab == "View" else { return }
        // MapEditorViewTab.tileClickHandler: ends in hideSelection() and the tapped tile's highlight
        if tab == "View" { controller.infoTile = hex; controller.editorHighlight = []; controller.refresh(full: false); return }
        // Unciv MapEditorEditTab.tileClickHandler: `brushHandlerType == BrushHandlerType.None -> return`
        guard let brush else { return }
        // Unciv MapEditorEditTab: BrushHandlerType.RiverFromTo takes two tiles and ignores the brush size
        if brush == .spawnRiver { selectRiverFromOrTo(hex); return }
        paintTilesWithBrush(hex, brush)
        controller.refresh()
    }

    /// Unciv EditorMapHolder's drag paint: `editorScreen.tabs.edit.paintTilesWithBrush(tile)` straight, whichever tab is
    /// showing - with no brush (None) or the river spawner (RiverFromTo) paintTilesWithBrush does nothing.
    private func dragPaint(_ hex: HexCoord) {
        guard let brush, brush != .spawnRiver else { return }
        paintTilesWithBrush(hex, brush)
        controller.refresh()
    }

    /// Unciv MapEditorEditTab.paintTilesWithBrush: the tiles within the brush radius, or everything a flood fill of
    /// similar-enough tiles reaches; Direct and River brushes paint as they are, Tile and Road brushes through paintTile.
    private func paintTilesWithBrush(_ hex: HexCoord, _ brush: EditorBrush) {
        let tiles = brushSize == 6 ? floodFill(from: hex) : controller.state.map.tilesWithin(hex, radius: brushSize - 1)
        for tileToPaint in tiles {
            if brush.isDirect { directPaintTile(tileToPaint, brush) } else { paintTile(tileToPaint, brush) }
        }
        for c in tiles { refreshRiverAdjacency(around: c) }   // adjacent tiles could have changed as well, due to rivers
    }

    /// Unciv `BFS(tile) { it.isSimilarEnough(tile) }.stepToEnd()`, then `getReachedTiles().toSet()`: breadth first over
    /// Tile.neighbors, the reached tiles walked as their HashMap keeps them (JavaHash1Set over the reaching order).
    private func floodFill(from hex: HexCoord) -> [HexCoord] {
        let map = controller.state.map
        guard let origin = map[hex] else { return [] }
        var reached: Set<HexCoord> = [hex]
        var reachedInOrder = [hex]
        var tilesToCheck = [hex], head = 0
        while head < tilesToCheck.count {
            let current = tilesToCheck[head]; head += 1
            for neighbor in map.neighbors(of: current) where !reached.contains(neighbor) {   // Tile.neighbors order
                guard let t = map[neighbor], similarEnough(t, origin) else { continue }
                reached.insert(neighbor); reachedInOrder.append(neighbor); tilesToCheck.append(neighbor)
            }
        }
        return JavaHash1Set.iterationOrder(reachedInOrder)
    }

    /// Unciv MapEditorEditTab.isSimilarEnough under the chosen TileMatchFuzziness. Kotlin binds `&&` before `||`, so a
    /// different road status tells two tiles apart at every level; a natural wonder always has to match.
    private func similarEnough(_ a: Tile, _ b: Tile) -> Bool {
        let level = MapEditorView.tileMatchFuzziness.firstIndex(of: matchFuzziness) ?? 0
        func roadStatus(_ t: Tile) -> Int { t.railroad ? 2 : t.roads ? 1 : 0 }
        if (level <= 0 && a.improvement != b.improvement) || roadStatus(a) != roadStatus(b) { return false }
        if level <= 1 && a.resource != b.resource { return false }
        if level <= 2 && Set(a.features) != Set(b.features) { return false }
        if level <= 3 && a.baseTerrain != b.baseTerrain { return false }
        if level <= 4 && a.isLand != b.isLand { return false }
        return a.naturalWonder == b.naturalWonder
    }
    /// Unciv MapEditorOptionsTab.TileMatchFuzziness labels, CompleteMatch first.
    static let tileMatchFuzziness = ["Complete match", "Except improvements", "Base and terrain features", "Base terrain only", "Land or water only"]

    /// Unciv MapEditorEditTab.directPaintTile: starting locations and rivers - no temporary tile, no validation.
    private func directPaintTile(_ hex: HexCoord, _ brush: EditorBrush) {
        guard var t = controller.state.map[hex] else { return }
        switch brush {
        case .start(let nation):
            // Unciv MapEditorEditStartsTab: the brush toggles this nation's location, so a tile can hold several
            // nations and a nation several tiles. Only major civs get the chosen Usage (Unciv: others are Normal).
            let usage: StartingLocation.Usage = (Ruleset.shared.nations[nation]?.isMajor ?? false) ? startUsage : .normal
            if let i = starts.firstIndex(where: { $0.position == hex && $0.nation == nation }) { starts.remove(at: i) }
            else { starts.append(StartingLocation(position: hex, nation: nation, usage: usage)) }
        case .removeStarts:
            starts.removeAll { $0.position == hex }   // Unciv TileMap.removeStartingLocations(position)
        case .riverEdge(let d):
            // Unciv MapEditorEditRiversTab: each brush toggles exactly the one edge the tile owns
            if t.riverEdges.contains(d) { t.riverEdges.remove(d) } else { t.riverEdges.insert(d) }
            controller.state.map[hex] = t
        case .removeRivers:
            // Unciv: the user expects all six edges around the tile to be cleared, three of which neighbours own
            t.riverEdges = []
            controller.state.map[hex] = t
            for d in [HexCoord.dirN, HexCoord.dirNE, HexCoord.dirNW] { controller.state.map.setRiver(hex, dir: d, false) }
        default: return
        }
        edited = true   // Unciv MapEditorScreen.isDirty
    }

    /// Unciv MapEditorEditTab.paintTile: "Try - matches - leave or revert". The brush runs on a copy and on the tile,
    /// the tile is normalized to the ruleset, and when that changed it away from the painted copy (under the chosen
    /// fuzziness) the tile gets its old fields back.
    @discardableResult
    private func paintTile(_ hex: HexCoord, _ brush: EditorBrush) -> Bool {
        guard let savedTile = controller.state.map[hex] else { return false }
        var paintedTile = savedTile
        applyBrush(brush, to: &paintedTile)
        setTerrainTransients(&paintedTile)

        var tile = savedTile
        applyBrush(brush, to: &tile)
        setTerrainTransients(&tile)
        controller.state.map[hex] = tile
        controller.state.normalizeTileToRuleset(hex)   // TileNormalizer.normalizeToRuleset(tile, ruleset)
        guard let normalized = controller.state.map[hex] else { return false }
        if !similarEnough(paintedTile, normalized) {
            // Unciv Tile.applyFrom(savedTile): terrain, features, resource (not its amount), improvement, wonder, road, rivers
            var reverted = normalized
            reverted.baseTerrain = savedTile.baseTerrain
            reverted.features = savedTile.features
            reverted.resource = savedTile.resource
            reverted.improvement = savedTile.improvement
            reverted.naturalWonder = savedTile.naturalWonder
            reverted.roads = savedTile.roads; reverted.railroad = savedTile.railroad
            reverted.riverEdges = savedTile.riverEdges
            setTerrainTransients(&reverted)
            controller.state.map[hex] = reverted
            return false
        }
        edited = true   // Unciv MapEditorScreen.isDirty
        return true
    }

    /// The brush actions of Unciv's MapEditorEdit*Tab, applied to one tile "without validation or transient updates".
    private func applyBrush(_ brush: EditorBrush, to t: inout Tile) {
        let rs = Ruleset.shared
        switch brush {
        case .terrain(let n):
            t.baseTerrain = n; t.naturalWonder = nil
        case .feature(let f):
            if !t.features.contains(f) { t.features.append(f) }   // tile.addTerrainFeature(it) only if missing
        case .clearFeatures:
            t.features = []   // tile.removeTerrainFeatures()
        case .wonder(let w):
            // "Normally the caller would ensure compliance, but here we make an exception - place it no matter what"
            if let into = rs.terrains[w]?.turnsInto { t.baseTerrain = into }
            t.features = []
            t.naturalWonder = w
        case .resource(let r):
            guard let resource = rs.resources[r] else { return }
            if t.resource == r && resource.resourceType == "Strategic" { t.resourceAmount = min(t.resourceAmount + 1, 42) }
            else { setTileResource(&t, resource) }
        case .clearResource:
            t.resource = nil; t.resourceAmount = 0
        case .improvement(let i) where i == "Road" || i == "Railroad":
            // BrushHandlerType.Road: `setRoadStatus(if (tile.roadStatus == road) RoadStatus.None else road, null)`
            let road = i == "Railroad" ? 2 : 1
            let current = t.railroad ? 2 : t.roads ? 1 : 0
            let newStatus = current == road ? 0 : road
            t.roads = newStatus >= 1; t.railroad = newStatus >= 2; t.roadPillaged = false
        case .improvement(let i):
            // tile.setImprovement(it) without a civ (TileImprovementFunctions.setImprovement's plain branch)
            guard let improvement = rs.improvements[i] else { t.pillaged = false; t.improvement = nil; return }
            t.pillaged = false; t.improvement = improvement.name
            // "relevant when the improvement was created instantly - such as Great Improvement"
            GameState.setImprovementQueue(&t, controller.state.improvementQueue(t).filter { !(rs.improvements[$0.improvement]?.isRoad ?? false) })
            if improvement.uniques.contains("Removes removable features when built") {
                // Remove terrainFeatures that a Worker can remove and that aren't explicitly allowed under the improvement
                t.features = t.features.filter { f in
                    guard let feature = rs.terrains[f] else { return true }
                    return !(rs.improvements["Remove " + f] != nil && !improvement.isAllowedOnFeature(feature))
                }
            }
        case .removeImprovement:
            t.pillaged = false; t.improvement = nil                         // tile.removeImprovement()
            t.roads = false; t.railroad = false; t.roadPillaged = false     // tile.removeRoad()
        case .start, .removeStarts, .riverEdge, .removeRivers, .spawnRiver:
            break   // Direct / River / RiverFromTo brushes never come here
        }
    }

    /// Unciv Tile.setTerrainTransients as the brush meets it: a strategic resource without an amount ("Resource amounts
    /// missing - Old save or bad mapgen?") is taken for a small deposit - setTileResource(majorDeposit = false).
    private func setTerrainTransients(_ t: inout Tile) {
        guard let r = t.resource.flatMap({ Ruleset.shared.resources[$0] }), r.resourceType == "Strategic", t.resourceAmount == 0 else { return }
        t.resourceAmount = Tile.depositAmount(r, on: t, major: false, setting: "Default")
    }

    /// Unciv Tile.setTileResource(newResource, rng = editTab.randomness.RNG): a strategic deposit takes the "Deposits in
    /// [] tiles always provide [] resources" amount, else one draw picks a major or minor deposit (MapParameters.mapResources
    /// is not kept with our maps, so the Default amounts); any other resource carries no amount.
    private func setTileResource(_ t: inout Tile, _ resource: ResourceDef) {
        t.resource = resource.name
        guard resource.resourceType == "Strategic" else { t.resourceAmount = 0; return }
        let tile = t
        if let u = resource.uniqueObjects.first(where: { $0.pattern == "Deposits in [] tiles always provide [] resources" && tile.matchesTerrainFilterForDeposits($0.param(0)) }) {
            t.resourceAmount = u.int(1)
            return
        }
        let major = randomness.nextDouble() < tile.approximateMajorDepositDistribution(Ruleset.shared)
        t.resourceAmount = Tile.depositAmount(resource, on: tile, major: major, setting: "Default")
    }

    /// A river lives on an edge two tiles share, so the precomputed flag is redone around every edit.
    private func refreshRiverAdjacency(around hex: HexCoord) { MapEditorView.refreshRiverAdjacency(controller.state, around: hex) }
    /// The same on any game (ScenarioSelfTests.riverAdjacency runs it on a copy).
    nonisolated static func refreshRiverAdjacency(_ state: GameState, around hex: HexCoord) {
        for c in [hex] + state.map.neighbors(of: hex) {
            // read before the write: `state.map[c]?.x = ...` holds state.map for its write while the right side runs, and
            // hasRiver reading state.map in there trips Swift's exclusivity check
            let adjacent = (0..<6).contains { d in state.map.hasRiver(between: c, c.neighbor(d)) }
            state.map[c]?.riverAdjacent = adjacent
        }
    }

    /// Unciv MapEditorEditTab.selectRiverFromOrTo: land means the river's start - painted at once when a target is
    /// already chosen, otherwise the closest water is proposed as the target; water means the target - painted at once
    /// when a start is chosen. (Unciv highlights the chosen tiles in blue.)
    private func selectRiverFromOrTo(_ hex: HexCoord) {
        guard let tile = controller.state.map[hex] else { return }
        if tile.isLand {
            riverFrom = hex
            if riverTo != nil { return paintRiverFromTo() }
            // RiverGenerator(editorScreen.tileMap, randomness, ruleset).getClosestWaterTile(tile) - the editor's own RNG
            var gen = MapGenerator(seed: 42)
            gen.rng = randomness
            riverTo = gen.closestWater(controller.state.map, from: hex)
            randomness = gen.rng
        } else {
            riverTo = hex
            if riverFrom != nil { return paintRiverFromTo() }
        }
    }
    /// Unciv MapEditorEditTab.paintRiverFromTo: the editor's RNG is reseeded with the map seed, the river is spawned,
    /// and the tiles it touched convert as "Becomes [] when adjacent to [River]" asks (MapGenerator.convertTerrains).
    private func paintRiverFromTo() {
        guard let from = riverFrom, let to = riverTo else { return }
        randomness = SeededRandom(kotlinSeedLong: Int64(bitPattern: NewGameScreen.parseSeed(genSeed) ?? 0))   // randomness.seedRNG(newMapParameters.seed)
        var gen = MapGenerator(seed: 42)
        gen.rng = randomness
        var resultingTiles: [HexCoord] = []
        gen.spawnRiver(&controller.state.map, from: from, to: to, resultingTiles: &resultingTiles)
        gen.convertTerrains(&controller.state.map, tiles: resultingTiles)
        randomness = gen.rng
        riverFrom = nil; riverTo = nil
        edited = true
        for i in controller.state.map.tiles.indices {
            let c = controller.state.map.tiles[i].coord
            controller.state.map.tiles[i].riverAdjacent = (0..<6).contains { d in controller.state.map.hasRiver(between: c, c.neighbor(d)) }
        }
        controller.scene.resetTiles(); controller.refresh()
    }
}

/// A row of selectable option buttons (used where Unciv would show a select box).
struct FlowButtons: View {
    let options: [String]
    let selected: String
    let onPick: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) { ForEach(options, id: \.self) { o in Button(L(o)) { onPick(o) }.buttonStyle(ThemedButtonStyle(filled: selected == o, compact: true)) } }
        }
    }
}

struct FlowChips: View {
    let items: [(String, MapEditorView.EditorBrush)]
    @Binding var brush: MapEditorView.EditorBrush?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button(L(item.0)) { brush = item.1 }.buttonStyle(ThemedButtonStyle(filled: brush == item.1, compact: true))
                }
            }
        }
    }
}
