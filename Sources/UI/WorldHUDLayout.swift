// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The world screen under the top bar, placed the way Unciv's stage places its actors - each on its own, so one that grows
/// never moves the others: the tutorial task hangs from the top centre (`tutorialTaskTable.centerX(stage)`, "behind
/// topBar!"), the status buttons from the top right (WorldScreen.updateGameplayButtons), the unit table stands in the bottom
/// left corner, the battle table at the bottom centre (BattleTable `y = 5`) and the minimap with its buttons in the bottom
/// right corner.
///
/// The tile info is where ours departs from Unciv, in its place only (what it shows and does is TileInfoTable's). Unciv
/// stands the TileInfoTable on the minimap (`bottomTileInfoTable.y = minimapWrapper.height + 5`, right-aligned), in the
/// column the notification list runs down; on a landscape phone a long one - a capital's eight lines - took that column's
/// whole band between the status buttons and the minimap, so the notifications could only be read through it, and reached
/// under the next-turn button. Ours stands on the bottom edge left of the minimap and its buttons (at the bottom right
/// corner with neither), as wide and high as its lines (TileInfoTable.pack) up to `tileInfoMaxWidth` and
/// `tileInfoMaxHeightShare` of the stage's height, scrolling beyond, and below the status buttons and the tutorial task
/// where they hang over it. Where the unit table or the battle table leaves it less than its lines' width there (and less
/// than `tileInfoMinBesideWidth`), it takes whichever place shows the most of its lines without covering another view:
/// Unciv's own above the minimap, below the status buttons and the tutorial task (right of the battle table where that
/// reaches under it), or beside the minimap narrowed down to `tileInfoMinNarrowWidth`, its lines cut short. Only where
/// neither has room for two lines - a battle preview on Micro or Tiny (whose battle table already lies over the unit
/// table), a unit selected on a 4:3 iPad on Tiny, Micro on an iPad or with the zoom buttons shown - does it keep below the
/// status buttons two lines high and lie over the top of the minimap and its buttons (`TileInfoPlacement.clear` false).
struct WorldHUDLayout: Layout {
    enum Slot { case tutorialTask, statusButtons, unitTable, battle, cluster, tileInfo }
    struct SlotKey: LayoutValueKey { static let defaultValue: Slot? = nil }

    /// Unciv's stage height (the world screen's, the top bar included): the tile info's height cap is a share of it
    var stageHeight: CGFloat

    /// The inset of the corners: the status buttons 10 from the right edge, the unit table and the minimap 10 from the bottom
    static let pad: CGFloat = 10
    /// Unciv `bottomTileInfoTable.y = minimapWrapper.height + 5f`: the gap between the tile info and its neighbours
    static let gap: CGFloat = 5
    /// The status buttons hang 6 under the top bar, and nothing stands closer than 6 under them or the tutorial task
    static let statusButtonsGap: CGFloat = 6
    /// The unit table's HStack gap to what stood right of it
    static let unitTableGap: CGFloat = 8
    /// The widest the tile info gets: 200 for its lines, 8 of padding on each side (lines longer than that are cut short)
    static let tileInfoMaxWidth: CGFloat = 216
    /// Narrower than this beside the minimap (and narrower than its lines want), the tile info takes whichever place shows
    /// more of its lines
    static let tileInfoMinBesideWidth: CGFloat = 150
    /// The narrowest the tile info is made beside the minimap when that shows more of its lines than the place above it:
    /// 74 for its lines, cut short, and its padding
    static let tileInfoMinNarrowWidth: CGFloat = 90
    /// The narrowest the tile info above the minimap is made to keep right of a battle table reaching under it
    static let tileInfoMinBattleClearWidth: CGFloat = 60
    /// The tile info beside the minimap is at most this share of the stage's height, scrolling beyond it
    static let tileInfoMaxHeightShare: CGFloat = 0.45
    /// The least height the tile info is ever given, however little room is left: two lines and its padding
    static let tileInfoMinHeight: CGFloat = 40

    /// Where the tile info goes: its bottom right corner and the most room it may take there
    struct TileInfoPlacement: Equatable {
        var right: CGFloat
        var bottom: CGFloat
        var maxWidth: CGFloat
        var maxHeight: CGFloat
        /// Beside the minimap (or in the bottom right corner), not above it
        var beside: Bool
        /// It covers no other view; false only where no place had room for two lines and it reaches over the minimap
        var clear: Bool = true
    }

    /// What the world screen's layout last did with the tile info: its place, and the frame of the minimap with its buttons
    /// it was placed against, in the layout's coordinates (read by --notif-selftest; written on the main thread)
    struct TileInfoRecord { var placement: TileInfoPlacement; var cluster: CGRect? }
    nonisolated(unsafe) static var lastTileInfo: TileInfoRecord? = nil

    /// The tile info's place, from the frames of the others (nil or empty when not shown) and the size of its lines
    /// (`natural`, measured at `tileInfoMaxWidth`), in the layout's coordinates
    static func placeTileInfo(bounds: CGRect, natural: CGSize, stageHeight: CGFloat, statusButtons: CGRect?, tutorialTask: CGRect? = nil,
                              unitTable: CGRect?, battle: CGRect?, cluster: CGRect?) -> TileInfoPlacement {
        func shown(_ r: CGRect?) -> CGRect? { r.flatMap { $0.width >= 1 && $0.height >= 1 ? $0 : nil } }
        let status = shown(statusButtons), tutorial = shown(tutorialTask), unit = shown(unitTable), battle = shown(battle), cluster = shown(cluster)
        let bottom = bounds.maxY - pad
        // the highest a column from minX to maxX may reach: 6 below the status buttons and the tutorial task where they hang
        // over it, 6 below the top bar elsewhere
        func top(_ minX: CGFloat, _ maxX: CGFloat) -> CGFloat {
            [status, tutorial].compactMap { $0 }.filter { $0.minX < maxX && $0.maxX > minX }.map { $0.maxY + statusButtonsGap }
                .reduce(bounds.minY + statusButtonsGap, max)
        }
        // how much of its lines a place shows while covering no other view: nothing where it has less than two lines' room
        func shows(_ p: TileInfoPlacement) -> CGFloat { p.maxHeight >= tileInfoMinHeight ? min(natural.height, p.maxHeight) : 0 }

        // beside the minimap and its buttons, standing on the bottom edge; right of the unit table and the battle table
        let right = cluster.map { $0.minX - gap } ?? bounds.maxX - pad
        let left = [unit, battle].compactMap { $0 }.filter { $0.minX < right }.map { $0.maxX + gap }.reduce(bounds.minX + pad, max)
        let room = right - left
        let besideWidth = min(tileInfoMaxWidth, room)
        let beside = TileInfoPlacement(right: right, bottom: bottom, maxWidth: besideWidth,
                                       maxHeight: min(stageHeight * tileInfoMaxHeightShare, bottom - top(right - min(natural.width, besideWidth), right)),
                                       beside: true)
        if room >= min(natural.width, tileInfoMinBesideWidth) && shows(beside) > 0 { return beside }

        // Unciv's place: above the minimap at the right edge, below the status buttons and the tutorial task - and above
        // the battle table too, should that reach under it, unless it is narrowed to the room right of the battle table
        let aboveRight = bounds.maxX - pad
        func above(_ width: CGFloat) -> TileInfoPlacement {
            let minX = aboveRight - min(natural.width, width)
            let under = [cluster, battle].compactMap { $0 }.filter { $0.minX < aboveRight && $0.maxX > minX }
            let floor = under.map { $0.minY - gap }.reduce(bottom, min)
            return TileInfoPlacement(right: aboveRight, bottom: floor, maxWidth: width, maxHeight: floor - top(minX, aboveRight), beside: false)
        }
        let full = above(min(tileInfoMaxWidth, bounds.width - 2 * pad))
        let rightOfBattle = battle.map { aboveRight - ($0.maxX + gap) }
            .flatMap { $0 >= tileInfoMinBattleClearWidth && $0 < min(natural.width, full.maxWidth) ? above($0) : nil }
        // the place that shows the most of its lines, the first of equals: above the minimap as wide as its lines, above it
        // right of the battle table, beside the minimap narrowed
        var best = full
        for p in [rightOfBattle, room >= tileInfoMinNarrowWidth ? beside : nil].compactMap({ $0 }) where shows(p) > shows(best) { best = p }
        if shows(best) > 0 { return best }

        // no place has room for two lines: below the status buttons and the tutorial task, two lines high, reaching down over
        // the minimap's top edge - right of the battle table where that leaves it the room
        let last = rightOfBattle ?? full
        let lastTop = last.bottom - last.maxHeight
        return TileInfoPlacement(right: aboveRight, bottom: lastTop + tileInfoMinHeight, maxWidth: last.maxWidth, maxHeight: tileInfoMinHeight,
                                 beside: false, clear: false)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        func slot(_ s: Slot) -> LayoutSubview? { subviews.first { $0[SlotKey.self] == s } }
        let w = bounds.width, h = bounds.height
        var tutorial: CGRect? = nil, status: CGRect? = nil, unit: CGRect? = nil, battle: CGRect? = nil, cluster: CGRect? = nil
        // Unciv WorldScreen.displayTutorialTaskOnUpdate: `tutorialTaskTable.centerX(stage)` hanging from the top bar
        // (`y = topBar.getYForTutorialTask() - height`); its view holds the 6 points above it
        if let v = slot(.tutorialTask) {
            let p = ProposedViewSize(width: w, height: h)
            let s = v.sizeThatFits(p)
            tutorial = CGRect(x: bounds.midX - s.width / 2, y: bounds.minY, width: s.width, height: s.height)
            v.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: p)
        }
        // Unciv WorldScreen.updateGameplayButtons: `statusButtons.setPosition(stage.width - statusButtons.width - 10,
        // topBar.y - statusButtons.height - 10)` - ours hang 6 under the top bar
        if let v = slot(.statusButtons) {
            let p = ProposedViewSize(width: w - Self.pad, height: h - Self.statusButtonsGap)
            let s = v.sizeThatFits(p)
            status = CGRect(x: bounds.maxX - Self.pad - s.width, y: bounds.minY + Self.statusButtonsGap, width: s.width, height: s.height)
            v.place(at: CGPoint(x: bounds.maxX - Self.pad, y: bounds.minY + Self.statusButtonsGap), anchor: .topTrailing, proposal: p)
        }
        // Unciv's minimapWrapper: `x = stage.width - width`, y = 0 - the zoom buttons, the overlay toggles and the minimap
        if let v = slot(.cluster) {
            let p = ProposedViewSize(width: w - 2 * Self.pad, height: h - Self.pad)
            let s = v.sizeThatFits(p)
            cluster = CGRect(x: bounds.maxX - Self.pad - s.width, y: bounds.maxY - Self.pad - s.height, width: s.width, height: s.height)
            v.place(at: CGPoint(x: bounds.maxX - Self.pad, y: bounds.maxY - Self.pad), anchor: .bottomTrailing, proposal: p)
        }
        // Unciv bottomUnitTable (x = 0, y = 0) with the unitActionsTable standing on it: offered the half of the room left of
        // the minimap that the HStack it stood in shared with the Spacer pushing the minimap right
        if let v = slot(.unitTable) {
            let room = w - 2 * Self.pad - Self.unitTableGap - (cluster?.width ?? 0)
            let p = ProposedViewSize(width: max(0, room / 2), height: h - Self.pad)
            let s = v.sizeThatFits(p)
            unit = CGRect(x: bounds.minX + Self.pad, y: bounds.maxY - Self.pad - s.height, width: s.width, height: s.height)
            v.place(at: CGPoint(x: bounds.minX + Self.pad, y: bounds.maxY - Self.pad), anchor: .bottomLeading, proposal: p)
        }
        // Unciv BattleTable: `setPosition(stage.width / 2 - width / 2, 5f)`
        if let v = slot(.battle) {
            let p = ProposedViewSize(width: w, height: h - 5)
            let s = v.sizeThatFits(p)
            battle = CGRect(x: bounds.midX - s.width / 2, y: bounds.maxY - 5 - s.height, width: s.width, height: s.height)
            v.place(at: CGPoint(x: bounds.midX, y: bounds.maxY - 5), anchor: .bottom, proposal: p)
        }
        if let v = slot(.tileInfo) {
            let natural = v.sizeThatFits(ProposedViewSize(width: Self.tileInfoMaxWidth, height: nil))
            let at = Self.placeTileInfo(bounds: bounds, natural: natural, stageHeight: max(stageHeight, h), statusButtons: status,
                                        tutorialTask: tutorial, unitTable: unit, battle: battle, cluster: cluster)
            Self.lastTileInfo = TileInfoRecord(placement: at, cluster: cluster)
            // as wide as its lines in the room there, as high as they are up to the cap (TileInfoTableView scrolls beyond it)
            let width = v.sizeThatFits(ProposedViewSize(width: at.maxWidth, height: nil)).width
            v.place(at: CGPoint(x: at.right, y: at.bottom), anchor: .bottomTrailing, proposal: ProposedViewSize(width: width, height: at.maxHeight))
        } else { Self.lastTileInfo = nil }
    }
}
