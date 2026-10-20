// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// MARK: - City picker (Unciv CityScreenCityPickerTable: ◀ name (pop) ▶, tap the name to rename)

struct CityPickerRow: View {
    @ObservedObject var controller: GameController
    let city: City
    var body: some View {
        let s = controller.state
        // Unciv CityView.getViewableCities: casusluk yaparken kendi sehirlerimiz degil, casusu kurulu sehirler arasinda geziliyor
        let mine: [City] = city.civId == s.playerId ? s.cities(of: s.playerId)
            : s.cities.filter { c in c.civId != s.playerId && s.player.spies.contains { $0.cityId == c.id && $0.alive && GameState.spySetUpActions.contains($0.action) } }
        let nation = s.civ(city.civId)?.nationDef
        HStack(spacing: 8) {
            // Unciv CityScreenCityPickerTable: BackArrow in the civ's inner colour, turned round for the next city
            if mine.count > 1 { Button { controller.cycleCity(-1) } label: { tintedArt("BackArrow", folder: "OtherIcons", color: nation.flatMap { $0.innerColor }.map { Color(red: Double($0[0]) / 255, green: Double($0[1]) / 255, blue: Double($0[2]) / 255) } ?? Theme.cream, size: 25).padding(10).contentShape(Rectangle()) }.buttonStyle(.plain) }
            HStack(spacing: 6) {
                // Unciv CityScreenCityPickerTable: fire, puppet (light gray), resistance, capital star (light gray)
                if city.razing { ArtIcon(name: "Fire", folder: "OtherIcons", fallback: "flame.fill", size: 20) }
                if city.isPuppet { tintedArt("Puppet", folder: "OtherIcons", color: Color(white: 0.75), size: 20) }
                if city.resistanceTurns > 0 { ArtIcon(name: "Resistance", folder: "StatIcons", fallback: "hand.raised.fill", size: 20) }
                if city.isCapital { tintedArt("Star", folder: "OtherIcons", color: Color(white: 0.75), size: 20) }
                Button { if controller.isMyTurn && city.civId == s.playerId { controller.showRenameCity = true } } label: { Text(L(city.name) + L(" (\(city.population))")).font(Theme.title(20)).foregroundStyle(nation.flatMap { $0.innerColor }.map { Color(red: Double($0[0]) / 255, green: Double($0[1]) / 255, blue: Double($0[2]) / 255) } ?? Theme.cream) }.buttonStyle(.plain)
                if let garrison = s.units(at: city.coord).first(where: { $0.isMilitary && $0.civId == city.civId }) { ArtIcon(name: garrison.name, folder: "UnitIcons", fallback: "shield", size: 22) }
            }
            .padding(.horizontal, 6)
            if mine.count > 1 { Button { controller.cycleCity(1) } label: { tintedArt("BackArrow", folder: "OtherIcons", color: nation.flatMap { $0.innerColor }.map { Color(red: Double($0[0]) / 255, green: Double($0[1]) / 255, blue: Double($0[2]) / 255) } ?? Theme.cream, size: 25).rotationEffect(.degrees(180)).padding(10).contentShape(Rectangle()) }.buttonStyle(.plain) }
        }
        // Unciv CityScreenCityPickerTable: arrows and name inside one rounded panel in the civ's outer colour
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(nation.map { Color(red: Double($0.outerColor[0]) / 255, green: Double($0.outerColor[1]) / 255, blue: Double($0.outerColor[2]) / 255) } ?? Theme.panelDark))
    }
}

// MARK: - City map (Unciv CityMapHolder: the city's tiles, worked citizens, locks, purchasable tiles; tap a tile to inspect it)

struct CityMapView: View, Equatable {
    /// The tile art as UIImages, loaded once
    private static var imageCache: [String: UIImage] = [:]
    static func image(_ name: String) -> UIImage? {
        if let i = imageCache[name] { return i }
        guard let i = Art.shared.image(name, folder: "Tiles") else { return nil }
        imageCache[name] = i
        return i
    }
    /// the taps' target; the map is drawn from `model` and the tile states below, so a publish of the controller that
    /// changes none of them does not redraw the canvas (`==`, the screen's `.equatable()`)
    let controller: GameController
    /// the city's tiles as CityScreenModel works them out (CityTileGroup.update)
    let model: CityScreenModel
    var scale: CGFloat = 0.62
    /// Unciv CityScreen.selectedQueueEntryTargetTile: the tile the selected CreatesOneImprovement building has claimed
    var targetTile: HexCoord? = nil
    /// Unciv CityScreen.selectedTile (GameController.cityTile) and pickTileData (GameController.cityPickTile)
    var selectedTile: HexCoord? = nil
    var pickTile: GameController.PickTileForImprovement? = nil
    /// Unciv CityScreen.tileGroupOnClick with pickTileData set
    var onPickTile: ((HexCoord) -> Void)? = nil
    nonisolated static func == (a: CityMapView, b: CityMapView) -> Bool {
        a.model === b.model && a.scale == b.scale && a.targetTile == b.targetTile && a.selectedTile == b.selectedTile && a.pickTile == b.pickTile
    }

    var body: some View {
        let umT = UIMeasure.start()
        let v = map
        UIMeasure.stop("CityMapView.body", umT)
        return v
    }
    private var map: some View {
        let s = model.s
        let city = model.city
        let range = max(s.rs.constants.cityExpandRange, s.rs.constants.cityWorkRange)
        let tiles = model.mapTiles
        let center = city.coord.pixelCenter
        let nextToOwn = model.nextTileToOwn   // Unciv CityScreen.nextTileToOwn: sehrin sonraki alacagi karo
        let isSpying = model.isSpying
        let width = CGFloat(range * 2 + 1) * HexCoord.colStep * scale + 40, height = CGFloat(range * 2 + 2) * HexCoord.rowStep * scale + 20
        let point: (HexCoord) -> CGPoint = { c in
            let p = c.pixelCenter
            return CGPoint(x: width / 2 + (p.x - center.x) * scale, y: height / 2 - (p.y - center.y) * scale)
        }
        /// The tile whose hex a point falls on - the CityTileGroup a tap reaches
        let hitTile: (CGPoint) -> HexCoord? = { p in
            guard let hit = tiles.min(by: { hypot(point($0.coord).x - p.x, point($0.coord).y - p.y) < hypot(point($1.coord).x - p.x, point($1.coord).y - p.y) }),
                  hypot(point(hit.coord).x - p.x, point(hit.coord).y - p.y) < 16 * scale * 1.4 else { return nil }
            return hit.coord
        }
        let cityTile = selectedTile, pick = pickTile
        return Canvas { ctx, _ in
            let umT = UIMeasure.start(); defer { UIMeasure.stop("CityMapView.canvas", umT) }
            for t in tiles {
                let p = point(t.coord)
                var path = Path()
                for (i, corner) in HexCoord.corners.enumerated() {
                    let q = CGPoint(x: p.x + corner.x * scale, y: p.y - corner.y * scale)
                    if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                }
                path.closeSubpath()
                // Unciv CityTileGroup: the tile's own art layers (terrain, features, resource, improvement, city),
                // dimmed below as CityTileGroup.update says
                var drewArt = false
                for name in t.layers {
                    guard let img = CityMapView.image(name) else { continue }
                    let w = HexCoord.imageWidth * scale, h = img.size.height * HexCoord.imageWidth / max(1, img.size.width) * scale
                    ctx.draw(Image(uiImage: img).interpolation(.medium), in: CGRect(x: p.x - w / 2, y: p.y + HexCoord.imageHeight / 2 * scale - h, width: w, height: h))
                    drewArt = true
                }
                if !drewArt { ctx.fill(path, with: .color(t.fallbackColor)) }
                // CityTileGroup setDimmed: layerTerrain.dim(0.5 × 0.6) for a tile not of our civ, dim(0.5) for the others
                if !t.sameCiv { ctx.fill(path, with: .color(.black.opacity(0.3))) }
                else if t.dimmed { ctx.fill(path, with: .color(.black.opacity(0.5))) }
                // Unciv TileLayerMisc yields: every tile's getTileStats for this city - a tile not of our civ only with "Show
                // tile yields" (setYieldVisible) - at half alpha where CityTileGroup dims them
                if (t.sameCiv || UserSettings.showTileYields) && !t.yields.isEmpty {
                    ctx.draw(Text(t.yields.short).font(.system(size: 5 * scale, weight: .bold)).foregroundColor(.white.opacity(t.yieldsDimmed ? 0.5 : 1)), at: CGPoint(x: p.x, y: p.y + 8 * scale))
                }
                if t.worked { ctx.stroke(path, with: .color(Theme.gold), lineWidth: 2) }
                else if !t.dimmed { ctx.stroke(path, with: .color(Theme.cream.opacity(0.4)), lineWidth: 0.8) }
                else if t.purchaseCost != nil { ctx.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
                // Unciv CityScreen: nextTileToOwn mor (200,20,220) kontur alir - updateTileGroups' `if (isSpying) continue`
                // skips every outline below for a foreign city
                if !isSpying && t.coord == nextToOwn { ctx.stroke(path, with: .color(Color(red: 200 / 255, green: 20 / 255, blue: 220 / 255)), lineWidth: 2) }
                if t.coord == cityTile { ctx.stroke(path, with: .color(.white), lineWidth: 2.5) }
                // Unciv CityScreen.updateTileGroups: the claimed tile of the selected building, or while picking a tile for
                // one, every owned tile in range by getPickImprovementColor
                if !isSpying && t.coord == targetTile { ctx.stroke(path, with: .color(Color(red: 0.545, green: 0.271, blue: 0.075)), lineWidth: 2) }
                else if !isSpying, let pick, t.owned, t.coord.distance(to: city.coord) <= s.rs.constants.cityWorkRange, let tile = s.map[t.coord] {
                    let brown = Color(red: 0.545, green: 0.271, blue: 0.075)
                    let color: Color = {
                        if s.isMarkedForCreatesOneImprovement(t.coord) { return brown.opacity(0.7) }
                        if !s.canPlaceCreateOneImprovementOn(pick.improvement, t.coord, city: city) { return Color.red.opacity(0.4) }
                        // isExistingImprovementValuable: the existing improvement's stat difference ranks at or below zero
                        if let existing = tile.improvement, s.rankStatsValue(s.statDiffForImprovement(tile, existing, civId: city.civId), civId: city.civId) <= 0 { return Color.orange.opacity(0.5) }
                        if tile.improvement != nil || tile.improvementTurnsLeft > 0 { return Color.yellow.opacity(0.6) }
                        return Color.green.opacity(0.5)
                    }()
                    ctx.stroke(path, with: .color(color), lineWidth: 2)
                }
                switch t.mark {
                case .center: ctx.draw(Text("🏛").font(.system(size: 12)), at: p)   // TileIcons/CityCenter
                // Unciv CityTileGroup: abluka altindaki karo TileIcons/Blockaded ikonu alir ve calisilamaz.
                case .blockaded: ctx.draw(Text("⛔").font(.system(size: 9)), at: p)
                case .locked: ctx.draw(Text("🔒").font(.system(size: 9)), at: p)
                case .worked: ctx.draw(Text("👤").font(.system(size: 9)), at: p)
                // Unciv CityTileGroup NOT_WORKED: calisilabilir ama atanmamis karo da isaretlenir (kardes sehrin karosu da)
                case .notWorked: ctx.draw(Text("◦").font(.system(size: 11)).foregroundColor(Theme.cream.opacity(0.55)), at: p)
                case .none: break
                }
                // Unciv CityTileGroup: satin alinabilir karoda TileIcons/Buy ikonu ve fiyat etiketi; parasi yetmezse fiyat kirmizi
                if let cost = t.purchaseCost {
                    ctx.draw(Text(Translations.shared.numberTr(cost)).font(.system(size: 7, weight: .bold)).foregroundColor(t.ownerCanBuy ? .white : .red),
                             at: CGPoint(x: p.x, y: p.y - 9 * scale * 1.4))
                }
            }
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelDark.opacity(0.7)))
        .contentShape(Rectangle())
        // Unciv CityScreen: double tap works and locks a tile; tapping the selected tile works or unworks it (its citizen icon), other taps select.
        // Each tile is a CityTileGroup with its own onClick and onDoubleClick, so a double tap is two lifts on one tile, and the
        // first of them is already a tap (UncivTaps)
        .uncivTaps(sameTarget: { a, b in hitTile(a) != nil && hitTile(a) == hitTile(b) }, onTap: { p in
            guard !city.isPuppet, city.civId == s.playerId else { return }   // Unciv canCityBeChanged
            if controller.cityPickTile != nil, let onPickTile {
                if let hit = tiles.min(by: { hypot(point($0.coord).x - p.x, point($0.coord).y - p.y) < hypot(point($1.coord).x - p.x, point($1.coord).y - p.y) }) { onPickTile(hit.coord) } else { controller.cityPickTile = nil }
                return
            }
            guard let hit = hitTile(p) else { return }
            if controller.cityTile == hit { controller.toggleWorkedTile(hit) } else { controller.cityTile = hit }
        }, onDoubleTap: { p in
            guard !city.isPuppet, city.civId == s.playerId else { return }   // Unciv canCityBeChanged
            guard let hit = hitTile(p) else { return }
            controller.cityTile = hit
            controller.workAndLockTile(hit)
        })
    }
}

// MARK: - Tile table (Unciv CityScreenTileTable: terrain, yields, owner, lock/unlock, buy)

struct CityTileTable: View {
    @ObservedObject var controller: GameController
    /// the tile's texts and buttons as CityScreenModel works them out
    let model: CityScreenModel
    let coord: HexCoord
    @State private var confirmBuy = false   // Unciv CityScreen.askToBuyTile ConfirmPopup
    @State private var showRingMenu = false   // Unciv CityScreenTileTable.TileBuyMenu (the Buy button's context menu)
    var body: some View {
        let s = controller.state
        let city = model.city
        if let info = model.tileTable(coord) {
            Panel(padding: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.title).font(Theme.caption.bold())
                    Text(info.yields).font(Theme.caption).foregroundStyle(Theme.gold)
                    if let o = info.ownedBy { Text(o).font(Theme.small).foregroundStyle(Theme.creamDim) }
                    if let w = info.workedBy { Text(w).font(Theme.small).foregroundStyle(Theme.creamDim) }
                    HStack(spacing: 6) {
                        // Unciv CityScreenTileTable: Lock / Unlock only for tiles this city works
                        if let lock = info.lockTitle {
                            Button(lock) { controller.toggleLock(coord) }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(!controller.isMyTurn || city.isPuppet)
                        }
                        if let buy = info.buy {
                            let cost = buy.cost
                            let enabled = controller.isMyTurn && buy.enabled
                            // A tap asks to buy the tile; a long press opens the ring menu (addContextMenu { TileBuyMenu })
                            Text(L("Buy for [\(cost)] gold"))
                                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                .foregroundStyle(Theme.panelDark)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: Theme.R.control, style: .continuous).fill(Theme.gold))
                                .opacity(enabled ? 1 : 0.38)
                                .onTapGesture { if enabled { confirmBuy = true } }
                                .onLongPressGesture(minimumDuration: UserSettings.longPressSeconds) { if info.rings.count > 0 { showRingMenu = true } }
                                .confirmationDialog(L("Currently you have [\(Int(s.player.gold))] [Gold].") + "\n\n" + L("Would you like to purchase [Tile] for [\(cost)] [¤]?"), isPresented: $confirmBuy, titleVisibility: .visible) {
                                    Button(L("Purchase")) { controller.buyTile(coord) }
                                    Button(L("Cancel"), role: .cancel) {}
                                }
                                .themedMenu(isPresented: $showRingMenu) {
                                    Text(L("Currently you have [\(Int(s.player.gold))] [Gold].")).font(Theme.small).frame(maxWidth: .infinity)
                                    ForEach(info.rings, id: \.ring) { r in
                                        Button(L("Buy [\(r.count)] tiles in ring [\(r.ring)] for [\(r.cost)][¤]")) { showRingMenu = false; controller.buyTilesInRing(r.ring) }
                                            .buttonStyle(ThemedButtonStyle(compact: true)).disabled(Double(r.cost) > s.player.gold)
                                    }
                                }
                        }
                        if let other = info.moveToCity {
                            Button(L("Move to city")) { controller.selectedCityId = other; controller.cityTile = nil; controller.state.cityScreenOpened(other); controller.refresh(full: false) }.buttonStyle(ThemedButtonStyle(compact: true))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Specialist allocation (Unciv SpecialistAllocationTable: Manual/Auto toggle, −/+ per specialist, its stats)

struct SpecialistAllocationView: View {
    @ObservedObject var controller: GameController
    let city: City
    var body: some View {
        let s = controller.state
        let slots = s.maxSpecialists(city)
        // Unciv CityScreen.canCityBeChanged / canChangeState: our city, our turn, not a puppet
        let canChange = controller.isMyTurn && city.civId == s.playerId && !city.isPuppet
        if !slots.isEmpty {
            Panel(padding: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L("Specialists") + ":").font(Theme.heading(14)).foregroundStyle(Theme.gold)   // Unciv SpecialistAllocationTable.asExpander: "{Specialists}:"
                        Spacer()
                        if canChange { Button(city.manualSpecialists ? L("Manual Specialists") : L("Auto Specialists")) { controller.toggleManualSpecialists() }.buttonStyle(ThemedButtonStyle(filled: city.manualSpecialists, compact: true)) }
                    }
                    ForEach(slots.keys.sorted(), id: \.self) { name in
                        let assigned = city.specialists[name] ?? 0
                        let maxN = slots[name] ?? 0
                        let sp = s.rs.specialists[name]
                        HStack(spacing: 6) {
                            // getUnassignButton: hidden with nothing assigned or in a puppet, gone when the city cannot be changed
                            if canChange { Button { controller.unassignSpecialist(name) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Theme.danger) }.buttonStyle(.plain).opacity(assigned > 0 ? 1 : 0).disabled(assigned == 0) }
                            HStack(spacing: 2) { ForEach(0..<maxN, id: \.self) { i in Image(systemName: "person.fill").font(.system(size: 12)).foregroundStyle(i < assigned ? (sp?.color.flatMap { $0.count >= 3 ? Color(red: Double($0[0]) / 255, green: Double($0[1]) / 255, blue: Double($0[2]) / 255) : nil } ?? Theme.gold) : Theme.creamDim.opacity(0.4)) } }
                            // getAssignButton: absent when full or a puppet, empty with no free population or when the city cannot be changed
                            if canChange { Button { controller.assignSpecialist(name) } label: { Image(systemName: "plus.circle.fill").foregroundStyle(Theme.good) }.buttonStyle(.plain).opacity(assigned < maxN && s.freePopulation(city) > 0 ? 1 : 0).disabled(assigned >= maxN || s.freePopulation(city) <= 0) }
                            Divider().frame(height: 14)
                            Text(L(name)).font(Theme.small)
                            if let sp { Text(s.specialistStats(name, in: city).short).font(Theme.small).foregroundStyle(Theme.gold); ForEach(sp.greatPersonPoints.sorted { $0.key < $1.key }, id: \.key) { gp, pts in Text("+\(pts) \(L(gp))").font(Theme.small).foregroundStyle(Theme.creamDim) } }
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Religion info (Unciv CityReligionInfoTable: majority religion, holy city, followers and pressure per religion)

struct CityReligionInfoView: View {
    @ObservedObject var controller: GameController
    let city: City
    /// Unciv CityReligionInfoTable(cityView, showMajority): the foreign city popup puts the "Majority Religion" line on top of
    /// the table and always shows it; the city screen's CityStatsTable wraps the table in an expander titled with it
    var showMajority: Bool = false
    private struct FollowerRow: Identifiable { let religion: String; let count: Int; var id: String { religion } }
    /// Religion.getReligionDisplayName: the founder's chosen name, or the religion's own
    private func displayName(_ r: String, _ s: GameState) -> String { L(s.civs.first { $0.religionName == r }?.religionDisplayName ?? r) }
    /// linkedReligionIcon: a founded religion (named as its icon) opens the Religion overview on it; a pantheon - a religion
    /// without founder beliefs, named after its belief, whose icon is "Pantheon" - opens the belief's Civilopedia page
    private func openReligion(_ r: String) {
        if controller.state.civs.contains(where: { $0.religionName == r }) { controller.overviewPage = "Religion"; controller.overviewSelect = r; controller.showOverview = true }
        else { controller.civilopediaEntry = "Belief/\(r)"; controller.showCivilopedia = true }
    }
    private func religionLink(_ r: String) -> some View {
        Button { openReligion(r) } label: {
            Text(displayName(r, controller.state)).underline()
        }.buttonStyle(.plain)
    }
    /// "Majority Religion: [label]" - "None" without one (getIconAndLabel)
    private func majorityLabel(_ s: GameState) -> String {
        L("Majority Religion: [\(s.majorityReligion(of: city).map { displayName($0, s) } ?? L("None"))]")
    }
    /// Unciv CityReligionInfoTable.init after the majority line: the holy city line, then - only when the city has
    /// followers - the Followers / Pressure grid, `followers.asSequence().sortedByDescending { it.value }` (a stable sort
    /// over the Counter's insertion order)
    @ViewBuilder private func table(_ s: GameState, _ followers: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let h = city.holyCityOf {
                HStack(spacing: 4) { Text(L(city.isHolyCity ? "Holy City of: [\(displayName(h, s))]" : "Former Holy City of: [\(displayName(h, s))]")) }.font(Theme.small).foregroundStyle(Theme.gold)
            }
            if !followers.isEmpty {
                HStack { Text(L("Followers")).font(Theme.small.bold()).frame(width: 150, alignment: .leading); Text(L("Pressure")).font(Theme.small.bold()) }
                // the pressure column is what arrives next turn, written "+ [n] pressure"
                let future = s.pressuresFromSurroundingCities(city)
                let order = (s.religionFollowersOrderCache[city.id] ?? []).filter { followers[$0] != nil }
                let keys = order + followers.keys.filter { !order.contains($0) }.sorted()
                let rows = keys.enumerated().sorted { a, b in
                    let va = followers[a.element] ?? 0, vb = followers[b.element] ?? 0
                    return va != vb ? va > vb : a.offset < b.offset
                }.map { FollowerRow(religion: $0.element, count: followers[$0.element] ?? 0) }
                ForEach(rows) { row in
                    HStack {
                        HStack(spacing: 4) { religionLink(row.religion); Text(": \(row.count)") }.font(Theme.small).frame(width: 150, alignment: .leading)
                        if let p = future[row.religion] { Text(L("+ [\(p)] pressure")).font(Theme.small).foregroundStyle(Theme.creamDim) }
                    }
                }
            }
        }
    }
    var body: some View {
        let s = controller.state
        let followers = s.followers(of: city)
        if showMajority {
            // CityButton.foreignCityInfoPopup: `if (isReligionEnabled()) add(CityReligionInfoTable(foreignCityView, true))` -
            // the majority line (with its linked religion, "None" without one) whatever the followers
            if s.religionEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    if let r = s.majorityReligion(of: city) {
                        Button { openReligion(r) } label: { Text(majorityLabel(s)).underline() }.buttonStyle(.plain)
                            .font(Theme.caption.bold()).foregroundStyle(Theme.gold)
                    } else {
                        Text(majorityLabel(s)).font(Theme.caption.bold()).foregroundStyle(Theme.gold)
                    }
                    table(s, followers)
                }
            }
        } else if s.religionEnabled && !followers.isEmpty {
            // CityStatsTable: only when the city has followers and religion is on; an expander that starts closed
            DisclosureGroup {
                table(s, followers)
            } label: {
                Text(majorityLabel(s)).font(Theme.caption.bold()).foregroundStyle(Theme.gold)
            }
            .tint(Theme.gold)
        }
    }
}

/// A plain Int that a SwiftUI sheet can be driven by.
struct IdentifiedInt: Identifiable { let value: Int; var id: Int { value } }

/// Unciv CityButton.foreignCityInfoPopup: what a foreign city shows when you cannot enter it - the city
/// summary, its religion, and the way through to diplomacy with its owner. "View" appears only when a spy
/// of ours is set up there, which is what lets Unciv open the full city screen.
struct ForeignCityInfoView: View {
    @ObservedObject var controller: GameController
    let cityId: Int
    var body: some View {
        let s = controller.state
        ThemedSheet(L("City"), subtitle: s.city(cityId).map { L($0.name) }, onClose: { controller.foreignCityInfo = nil }) {
            if let city = s.city(cityId), let owner = s.civ(city.civId) {
                Panel() {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            // Unciv CityTable.addCivIcon: a major civ's nation icon, otherwise CityStateIcons/<type> in the inner colour
                            if owner.isCityState, let type = owner.cityStateType {
                                tintedArt(type, folder: "CityStateIcons", color: Color(uiColor: UIColor(rgb: owner.nationDef?.innerColor ?? [255, 255, 255])), size: 26)
                            } else {
                                ArtIcon(name: owner.nation, folder: "NationIcons", fallback: "flag.fill", size: 26)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L(city.name) + L(" (\(city.population))")).font(Theme.heading(16)).foregroundStyle(Theme.cream)
                                Text(L(owner.nation)).font(Theme.small).foregroundStyle(Theme.creamDim)
                            }
                            Spacer()
                            if city.isCapital { Text("★").font(Theme.body).foregroundStyle(Theme.gold) }
                        }
                        // Unciv CityTable: the growth bar and addCityConstruction only show when isShowDetailedInfo =
                        // DebugUtils.VISIBLE_MAP || city.belongsTo(selectedCiv) || viewingCiv.isSpectator(); tapCityButton sends
                        // our own cities and spectators to the city screen, so here it is mostly a foreign city keeping what it builds to itself
                        if city.civId == s.playerId || s.player.isSpectator || UserSettings.debugVisibleMap, let p = city.currentProduction {
                            Text("\(L("Currently building")): \(L(p.name))").font(Theme.small).foregroundStyle(Theme.creamDim)
                        }
                    }
                }
                // Unciv foreignCityInfoPopup: `if (isReligionEnabled()) add(CityReligionInfoTable(foreignCityView, true))` under the CityTable
                if s.religionEnabled {
                    Panel() { CityReligionInfoView(controller: controller, city: city, showMajority: true) }
                }
                // Unciv foreignCityInfoPopup: espionageVisible = isEspionageEnabled() && ForeignCityView.spyIsSetUpAtCity (Spy.isSetUp(),
                // sadece atanmis/hayatta olmasi yetmez)
                let spyHere = s.espionageEnabled && s.player.spies.contains { $0.cityId == city.id && $0.alive && GameState.spySetUpActions.contains($0.action) }
                if spyHere {
                    Button(L("View")) {
                        controller.foreignCityInfo = nil
                        controller.selectedCityId = city.id
                        controller.showCity = true
                    }.buttonStyle(ThemedButtonStyle(compact: true))
                }
                Button(L("Diplomacy")) {
                    controller.foreignCityInfo = nil
                    controller.diplomacyCiv = city.civId
                    controller.showDiplomacy = true
                }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
            }
        }
    }
}

/// An Unciv image drawn in a single colour (ImageGetter.getImage(...).apply { color = ... })
@ViewBuilder
func tintedArt(_ name: String, folder: String, color: Color, size: CGFloat) -> some View {
    if let img = Art.shared.image(name, folder: folder) {
        Image(uiImage: img).renderingMode(.template).resizable().interpolation(.medium).foregroundStyle(color).frame(width: size, height: size)
    } else {
        Image(systemName: "questionmark").foregroundStyle(color).frame(width: size, height: size)
    }
}
