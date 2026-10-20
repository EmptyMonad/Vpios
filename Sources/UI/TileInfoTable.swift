// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv TileInfoTable: the tile's yields on top (tap → per-source breakdown popup), then the tile description lines,
/// rendered like MarkupRenderer with `worldScreen.openCivilopedia` as the link action: a line with a link opens its Civilopedia entry.
/// Unciv's stands on the minimap; ours stands beside it (WorldHUDLayout), which also caps its width and height, and GameView
/// gives each tile a table of its own (`.id`, Unciv's updateTileTable `clearChildren()`), so a scrolled one does not leave
/// the next scrolled.
struct TileInfoTableView: View {
    @ObservedObject var controller: GameController
    let coord: HexCoord
    @State private var showBreakdown = false

    var body: some View {
        let s = controller.state
        // Unciv WorldScreen.update: bottomTileInfoTable.civView = getGameViewConsideringForOfWar().civView
        let lines = controller.tileDescriptionLines(coord, viewer: controller.viewCivId)
        let stats = s.map[coord].map { s.yields(of: $0, for: controller.viewCivId) } ?? Stats()
        let table = VStack(alignment: .leading, spacing: 2) {
            if !stats.isEmpty {
                Button { showBreakdown = true } label: { Text(stats.short).font(Theme.small.bold()).foregroundStyle(Theme.gold) }.buttonStyle(.plain)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if let link = line.link {
                    Button { controller.civilopediaEntry = link; controller.showCivilopedia = true } label: { Text(line.text).font(Theme.small).foregroundStyle(Theme.cream).lineLimit(1) }.buttonStyle(.plain)
                } else { Text(line.text).font(Theme.small).foregroundStyle(Theme.cream).lineLimit(1) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // Unciv TileInfoTable.pack(): as wide as its longest line and as high as its lines - within the width WorldHUDLayout
        // offers (a phone's map must not be crossed by one long line, so a line longer than that is cut short) and up to
        // the height it offers, the lines scrolling inside beyond that
        ViewThatFits(in: .vertical) {
            table
            ScrollView(.vertical) { table }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicatorsFlash(onAppear: true)
        }
        // opaque, so what lies beneath - the map, an entry of the notification list scrolled under it - never shows through
        // its lines; Unciv's skin tints it `baseColor.darken(0.5f)` with the border addBorderAllowOpacity(1f, Color.WHITE)
        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelDark)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.8), lineWidth: 1))
        .overlay { if showBreakdown, let t = s.map[coord] { breakdownPopup(t) } }
    }

    /// Unciv getStatsTable onClick popup: `"${name.tr()}: {stats}"` for each row of TileView.getTileStatsBreakdown(civView) -
    /// TileStatFunctions.getTileStatsBreakdown with the tile's own city (tile.getCity()): terrain, the city's per-tile uniques
    /// ("{source} ({unique})"), river, resource, road, improvement, Minimum, Golden Age - unmultiplied, as Unciv lists them.
    private func breakdownPopup(_ t: Tile) -> some View {
        let s = controller.state
        let rows = s.tileStatsBreakdown(t, civId: controller.viewCivId, city: s.owningCity(t.coord))
        return Panel(highlighted: true) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in Text("\(L(r.0)): \(r.1.short)").font(Theme.small).foregroundStyle(Theme.cream) }
                Button(L("Close")) { showBreakdown = false }.buttonStyle(ThemedButtonStyle(compact: true))
            }
        }.fixedSize().offset(y: -60)
    }
}
