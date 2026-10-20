// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv VictoryScreenReplay + ReplayMap: the explored world redrawn from the tiles' ownership history, turn by turn.
struct ReplayView: View {
    @ObservedObject var controller: GameController
    @State private var turn: Double = 0
    @State private var playing = false
    @State private var timer: Timer? = nil

    var body: some View {
        let s = controller.state
        let first = s.historyStartTurn, last = s.turn
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Unciv VictoryScreenReplay.updateReplayTable: "year / turn.tr()" with gameInfo.turns' zero-based count, the top
                // bar's number - the slider and the replayed map stay in our one-ahead turn
                Button { turn = Double(first); restart() } label: { Text("\(yearText(s, Int(turn))) / \(Translations.shared.numberTr(Int(turn) - (s.turn - s.uncivTurns)))⏳").font(Theme.caption.bold()).foregroundStyle(Theme.gold) }.buttonStyle(.plain)
                EpochsSlider(value: Binding(get: { turn }, set: { v in stop(); turn = v }), range: Double(first)...Double(max(first, last)), step: 1).frame(height: 24)
                Button { playing ? stop() : restart() } label: { Image(systemName: playing ? "pause.fill" : "forward.fill").font(.system(size: 16, weight: .bold)) }.buttonStyle(ThemedButtonStyle(compact: true))
            }
            ReplayMapView(controller: controller, turn: Int(turn))
        }
        .onAppear { turn = Double(first); restart() }
        .onDisappear { stop() }
    }

    private func yearText(_ s: GameState, _ t: Int) -> String {
        let y = s.speed.year(forTurn: t + s.startTurnOffset)
        return GameState.yearText(year: y, usesMayaCalendar: s.isLongCountDisplay(s.playerId))
    }
    /// Unciv restartTimer: a tick every 0.1 s until the final turn.
    private func restart() {
        stop()
        playing = true
        let last = controller.state.turn
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if Int(turn) >= last { stop(); return }
            turn += 1
        }
    }
    private func stop() { timer?.invalidate(); timer = nil; playing = false }
}

/// Unciv ReplayMap (IndependentMiniMap): hexes coloured by the historical owner, city circles for city centres, only the explored tiles.
struct ReplayMapView: View {
    @ObservedObject var controller: GameController
    let turn: Int

    var body: some View {
        let s = controller.state
        let me = s.player
        // Unciv ReplayMap.includeTileFilter = tile.isExplored(viewingCiv), true everywhere only for a spectator: a finished
        // game or a defeated viewer adds no unexplored tile (a defeated single-player human already has the whole map
        // explored by revealMapWhenDefeated). calcTileSize frames the viewer's explored region.
        let includeAll = me.isSpectator
        let bounds = includeAll ? nil : s.exploredBounds(for: me.id)
        let col0 = bounds?.minCol ?? 0, row0 = bounds?.minRow ?? 0
        let cols = CGFloat(bounds?.width ?? s.map.width), rows = CGFloat(bounds?.height ?? s.map.height)
        GeometryReader { geo in
            let cell = max(2, min(geo.size.width / (cols * 0.75 + 0.25), geo.size.height / ((rows + 0.5) * 0.866)))
            let explored = me.explored
            Canvas { ctx, _ in
                var cityCircles: [(CGRect, Color, Color)] = []
                for (i, tile) in s.map.tiles.enumerated() where !s.map.missing.contains(i) && (includeAll || explored.contains(tile.coord)) {   // tileMap.values: no missing corner tiles
                    let c = tile.coord
                    let x = CGFloat(c.offsetCol - col0) * cell * 0.75
                    let y = (CGFloat(c.offsetRow - row0) + (c.offsetCol & 1 == 1 ? 0.5 : 0)) * cell * 0.866
                    let state = s.tileHistoryState(tile, turn: turn)
                    let owner = state.owner.flatMap { s.civ($0) }
                    let isCenter = state.center != "N"
                    var color: Color
                    if isCenter && !tile.isWater, let n = owner?.nationDef, let inner = n.innerColor { color = Color(uiColor: UIColor(rgb: inner)) }
                    else if let n = owner?.nationDef, !tile.isWater { color = Color(uiColor: UIColor(rgb: n.outerColor)) }
                    else if let t = s.rs.terrains[tile.baseTerrain] { color = Color(red: (Double(t.rgb[0]) / 255 + 0.5) / 2, green: (Double(t.rgb[1]) / 255 + 0.5) / 2, blue: (Double(t.rgb[2]) / 255 + 0.5) / 2) }
                    else { color = .gray }
                    let rect = CGRect(x: x, y: y, width: cell * 0.95, height: cell * 0.85)
                    ctx.fill(Path(rect), with: .color(color))
                    if isCenter, let n = owner?.nationDef {
                        let big = (state.center == "C" && owner?.isMajor == true) ? 1.667 : 1.25
                        cityCircles.append((rect.insetBy(dx: -cell * (big - 1) / 2, dy: -cell * (big - 1) / 2), Color(uiColor: UIColor(rgb: n.outerColor)), Color(uiColor: UIColor(rgb: n.innerColor ?? n.outerColor))))
                    }
                }
                for (rect, outer, inner) in cityCircles {
                    ctx.fill(Path(ellipseIn: rect), with: .color(outer))
                    ctx.fill(Path(ellipseIn: rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)), with: .color(inner))
                }
            }
        }
        .frame(height: 260)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelDark.opacity(0.7)))
    }
}
