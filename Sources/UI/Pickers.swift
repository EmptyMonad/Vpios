// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// MARK: - Tech tree (Unciv TechPickerScreen: columns per era, rows from the ruleset, lines to prerequisites)

struct TechTreeView: View {
    @ObservedObject var controller: GameController
    var selectedTech: String? = nil
    var tempTechsToResearch: [String] = []
    var onSelect: (String) -> Void = { _ in }
    var onQueue: (String) -> Void = { _ in }
    var onConfirm: () -> Void = {}
    @State private var centerTarget: String? = nil
    /// the tree's box at most this high (it scrolls inside); it takes the room it is given up to the tree's own height
    var maxHeight: CGFloat = .infinity
    static let cellW: CGFloat = 140, cellH: CGFloat = 44, gapX: CGFloat = 26, gapY: CGFloat = 6

    private func center(_ t: TechDef, _ colIndex: [Int: Int]) -> CGPoint {
        let x = CGFloat(colIndex[t.column] ?? 0) * (TechTreeView.cellW + TechTreeView.gapX) + TechTreeView.cellW / 2
        let y = CGFloat(t.row - 1) * (TechTreeView.cellH + TechTreeView.gapY) + TechTreeView.cellH / 2 + 24
        return CGPoint(x: x, y: y)
    }
    var body: some View {
        let _ = UIMeasure.count("TechTreeView.body")
        let s = controller.state
        let civ = controller.selectedCiv   // the TechPickerScreen's civInfo
        let science = s.scienceForNextTurn(civ.id)   // Unciv TechManager.turnsToTech: civInfo.stats.statsForNextTurn.science
        let columns = s.rs.techColumns.sorted { $0.columnNumber < $1.columnNumber }
        let colIndex: [Int: Int] = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($0.element.columnNumber, $0.offset) })
        let maxRow = max(1, s.rs.techs.values.map { $0.row }.max() ?? 1)
        let researchable = Set(s.researchableTechs(for: civ).map { $0.name })
        let width = CGFloat(columns.count) * (TechTreeView.cellW + TechTreeView.gapX)
        let height = CGFloat(maxRow) * (TechTreeView.cellH + TechTreeView.gapY) + 24
        return ScrollViewReader { proxy in
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for t in s.rs.techs.values {
                        let to = center(t, colIndex)
                        for p in t.prerequisites {
                            guard let pt = s.rs.techs[p] else { continue }
                            let from = center(pt, colIndex)
                            var path = Path()
                            path.move(to: CGPoint(x: from.x + TechTreeView.cellW / 2, y: from.y))
                            path.addCurve(to: CGPoint(x: to.x - TechTreeView.cellW / 2, y: to.y), control1: CGPoint(x: from.x + TechTreeView.cellW / 2 + 14, y: from.y), control2: CGPoint(x: to.x - TechTreeView.cellW / 2 - 14, y: to.y))
                            let known = civ.techs.contains(t.name)
                            ctx.stroke(path, with: .color(known ? Theme.gold.opacity(0.6) : Theme.creamDim.opacity(0.5)), lineWidth: known ? 1.5 : 1)
                        }
                    }
                }
                .frame(width: width, height: height)
                // era headers
                ForEach(Array(columns.enumerated()), id: \.offset) { i, col in
                    if i == 0 || columns[i - 1].era != col.era {
                        Text(L(col.era)).font(Theme.small.bold()).foregroundStyle(Theme.gold)
                            .offset(x: CGFloat(i) * (TechTreeView.cellW + TechTreeView.gapX), y: 2)
                    }
                }
                ForEach(s.rs.techs.values.sorted { ($0.column, $0.row) < ($1.column, $1.row) }) { t in
                    let c = center(t, colIndex)
                    let known = civ.techs.contains(t.name)
                    let continual = t.uniques.contains("Can be continually researched")
                    let current = civ.currentTech == t.name
                    let queued = tempTechsToResearch.contains(t.name)
                    let avail = researchable.contains(t.name)
                    let selected = selectedTech == t.name
                    // Unciv TechButton: turns to research (not for researched techs - `if (!isResearched || techName == Constants.futureTech)`
                    // sets the turns label, which is otherwise left empty), order indicator when more than one tech is lined up
                    let order = tempTechsToResearch.count > 1 ? tempTechsToResearch.firstIndex(of: t.name).map { " #\($0 + 1)" } ?? "" : ""
                    HStack(spacing: 4) {
                        ArtIcon(name: t.name, folder: "TechIcons", fallback: "book", size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L(t.name)).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)   // Unciv TechButton: one line, 140 wide at size 14, ellipsis
                            Text((known && !continual ? "" : "\(s.turnsToTech(civ, t.name, science: science))⏳") + order).font(.system(size: 8)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 5)
                    .frame(width: TechTreeView.cellW, height: TechTreeView.cellH)
                    .foregroundStyle(current || known ? Theme.panelDark : Theme.cream)
                    .background(RoundedRectangle(cornerRadius: 6).fill(known ? Theme.gold : current ? Theme.accent : queued ? Theme.goldDim : avail ? Theme.panelLight : Theme.panelDark.opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.cream : current ? Theme.cream : Theme.goldDim, lineWidth: selected ? 2.5 : current ? 1.5 : 1))
                    .contentShape(Rectangle())
                    // Unciv TechPickerScreen: click selects, right click (long press here) queues the path, double click confirms
                    .uncivTaps(onTap: { onSelect(t.name) }, onDoubleTap: { onSelect(t.name); onConfirm() })
                    .onLongPressGesture { onQueue(t.name) }
                    .id(t.name)
                    // placed, not offset: an offset leaves the button's frame at the tree's origin, where scrollTo looked for it,
                    // so the tree never centred on the technology (Unciv centerOnTechnology)
                    .position(x: c.x, y: c.y)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
        }
        // Unciv TechPickerScreen.init -> centerOnTechnology: scrollPane.scrollTo(button.x, y, width, height, centerH, centerV)
        // once the screen is laid out. The target is fixed when the picker opens; the offset is worked out from the
        // button's own rectangle and the box's size, and set again while the box settles into the room the screen gives
        // it. (proxy.scrollTo on the placed button left it half a button right and well below the middle, at the box's
        // lower edge, whatever the timing.)
        .modifier(TechTreeCentering(target: centerTarget, rect: { name in
            guard let t = s.rs.techs[name] else { return nil }
            let c = center(t, colIndex)
            return CGRect(x: c.x - TechTreeView.cellW / 2, y: c.y - TechTreeView.cellH / 2, width: TechTreeView.cellW, height: TechTreeView.cellH)
        }, content: CGSize(width: width, height: height), proxy: proxy))
        .onAppear {
            if centerTarget == nil { centerTarget = selectedTech ?? civ.currentTech ?? s.researchableTechs(for: civ).first?.name }
        }
        }
        .frame(maxHeight: min(height + 12, maxHeight))   // the room the screen leaves it, never more than the tree
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelDark.opacity(0.6)))
    }
}

/// Centres the tech tree's scroll view on a button's rectangle, as libGDX ScrollPane.scrollTo(x, y, w, h, true, true):
/// the scroll offset that puts the rectangle's middle in the middle of the box, kept inside the content
private struct TechTreeCentering: ViewModifier {
    let target: String?
    let rect: (String) -> CGRect?
    let content: CGSize
    let proxy: ScrollViewProxy
    func body(content view: Content) -> some View {
        if #available(iOS 18.0, *) {
            view.modifier(TechTreeCenteringByPoint(target: target, rect: rect, content: content))
        } else {
            view
                .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in if let t = target { DispatchQueue.main.async { proxy.scrollTo(t, anchor: .center) } } }
                .onChange(of: target) { _, t in if let t { DispatchQueue.main.async { proxy.scrollTo(t, anchor: .center) } } }
        }
    }
}
@available(iOS 18.0, *)
private struct TechTreeCenteringByPoint: ViewModifier {
    let target: String?
    let rect: (String) -> CGRect?
    let content: CGSize
    @State private var box: CGSize = .zero
    @State private var position = ScrollPosition(edge: .top)
    func body(content view: Content) -> some View {
        view
            .scrollPosition($position)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { box = $0; apply() }
            .onChange(of: target) { _, _ in apply() }
    }
    private func apply() {
        guard let t = target, let r = rect(t), box.width > 0, box.height > 0 else { return }
        let x = min(max(0, r.midX - box.width / 2), max(0, content.width - box.width))
        let y = min(max(0, r.midY - box.height / 2), max(0, content.height - box.height))
        DispatchQueue.main.async { position.scrollTo(point: CGPoint(x: x, y: y)) }
    }
}

// MARK: - Policy tree (Unciv PolicyPickerScreen: each branch lays its policies out by row/column with prerequisite lines)

struct PolicyTreeView: View {
    @ObservedObject var controller: GameController
    let branch: PolicyBranch
    var selectedPolicy: String? = nil
    var onSelect: (String) -> Void = { _ in }
    var onConfirm: (String) -> Void = { _ in }
    static let cellW: CGFloat = 96, cellH: CGFloat = 40, gapX: CGFloat = 10, gapY: CGFloat = 14
    private func center(_ p: PolicyDef) -> CGPoint {
        CGPoint(x: CGFloat(p.column - 1) * (PolicyTreeView.cellW + PolicyTreeView.gapX) + PolicyTreeView.cellW / 2, y: CGFloat(p.row - 1) * (PolicyTreeView.cellH + PolicyTreeView.gapY) + PolicyTreeView.cellH / 2)
    }

    var body: some View {
        let s = controller.state
        let civ = controller.selectedCiv   // the PolicyPickerScreen's viewingCiv
        let canChangeState = controller.isMyTurn && !controller.player.isSpectator
        let policies = branch.regularPolicies
        let maxCol = max(1, policies.map { $0.column }.max() ?? 1), maxRow = max(1, policies.map { $0.row }.max() ?? 1)
        let width = CGFloat(maxCol) * (PolicyTreeView.cellW + PolicyTreeView.gapX), height = CGFloat(maxRow) * (PolicyTreeView.cellH + PolicyTreeView.gapY)
        return ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for p in policies {
                        let to = center(p)
                        for r in p.requires {
                            guard let rp = policies.first(where: { $0.name == r }) else { continue }
                            let from = center(rp)
                            var path = Path(); path.move(to: CGPoint(x: from.x, y: from.y + PolicyTreeView.cellH / 2)); path.addLine(to: CGPoint(x: to.x, y: to.y - PolicyTreeView.cellH / 2))
                            ctx.stroke(path, with: .color(civ.policies.contains(p.name) ? Theme.gold : Theme.creamDim.opacity(0.6)), lineWidth: 1.2)
                        }
                    }
                }.frame(width: width, height: height)
                ForEach(policies) { p in
                    let c = center(p)
                    let have = civ.policies.contains(p.name)
                    let can = canChangeState && !have && s.canAdopt(civ, policy: p) && s.canAffordPolicy(civ)
                    let selected = selectedPolicy == p.name
                    VStack(spacing: 1) {
                        ArtIcon(name: p.name, folder: "PolicyIcons", fallback: "scroll", size: 18)
                        Text(L(p.name)).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(width: PolicyTreeView.cellW, height: PolicyTreeView.cellH)
                    .foregroundStyle(have ? Theme.panelDark : Theme.cream)
                    .background(RoundedRectangle(cornerRadius: 6).fill(have ? Theme.gold : can ? Theme.panelLight : Theme.panelDark.opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.cream : can ? Theme.gold : Theme.goldDim, lineWidth: selected ? 2.5 : 1))
                    .contentShape(Rectangle())
                    // Unciv getPolicyButton: click selects, double click adopts a pickable policy
                    .uncivTaps(onTap: { onSelect(p.name) }, onDoubleTap: { if can { onConfirm(p.name) } else { onSelect(p.name) } })
                    .offset(x: c.x - PolicyTreeView.cellW / 2, y: c.y - PolicyTreeView.cellH / 2)
                }
            }.frame(width: width, height: height, alignment: .topLeading)
        }
    }
}

// MARK: - Promotion tree (Unciv PromotionPickerScreen / PromotionTree: columns by prerequisite depth)

struct PromotionTreeView: View {
    @ObservedObject var controller: GameController
    let unit: Unit
    var saveUnitPromotion: Bool = false
    @State private var selected: String? = nil   // Unciv PromotionPickerScreen.selectedPromotion
    /// Unciv Promotion.getBaseNameAndLevel: the name without brackets and without its roman numeral.
    static func baseName(_ name: String) -> String {
        let plain = name.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        for (suffix, level) in [(" III", 3), (" II", 2), (" I", 1)] where plain.hasSuffix(suffix) {
            return String(plain.dropLast(level + 1))
        }
        return plain
    }
    static let cellW: CGFloat = 110, cellH: CGFloat = 36, gapX: CGFloat = 30, gapY: CGFloat = 8

    private func depth(_ p: PromotionDef, _ all: [String: PromotionDef], _ memo: inout [String: Int]) -> Int {
        if let d = memo[p.name] { return d }
        let d = p.prerequisites.compactMap { all[$0] }.map { depth($0, all, &memo) + 1 }.max() ?? 0
        memo[p.name] = d
        return d
    }

    /// Unciv Promotion.getBaseNameAndLevel: "Drill II" -> ("Drill", 2).
    static func baseNameAndLevel(_ name: String) -> (base: String, level: Int) {
        let n = name.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        let level = n.hasSuffix(" I") ? 1 : n.hasSuffix(" II") ? 2 : n.hasSuffix(" III") ? 3 : 0
        return (String(n.dropLast(level == 0 ? 0 : level + 1)), level)
    }

    /// Unciv PromotionTree.update (json row/column order, parent/child links, level groups) and PromotionPickerScreen.fillTable
    /// (each root tree starts on a fresh row; children go one column right, down a row when the cells are taken).
    static func layout(_ list: [PromotionDef]) -> [String: (row: Int, col: Int)] {
        func key(_ p: PromotionDef) -> Int { p.row < 0 ? Int.max : p.row == 0 ? Int.min / 2 + p.column : p.column }
        let sorted = list.sorted { a, b in
            if key(a) != key(b) { return key(a) < key(b) }
            if a.row != b.row { return a.row < b.row }
            return LocaleCode.compare(L(a.name), L(b.name)) == .orderedAscending
        }
        struct Node { var parents: [String] = []; var children: [String] = []; var levels = 1; let base: String; let level: Int }
        var nodes: [String: Node] = [:]
        for p in sorted { let b = baseNameAndLevel(p.name); nodes[p.name] = Node(base: b.base, level: b.level) }
        for p in sorted {
            for pre in p.prerequisites where nodes[pre] != nil && pre != p.name {
                nodes[p.name]!.parents.append(pre)
                if !nodes[pre]!.children.contains(p.name) { nodes[pre]!.children.append(p.name) }
                if nodes[p.name]!.level > 0 && nodes[p.name]!.base == nodes[pre]!.base { nodes[pre]!.levels += 1 }
            }
        }
        var occupied: [Int: Set<Int>] = [:]
        var placed: Set<String> = []
        var cells: [String: (row: Int, col: Int)] = [:]
        func isTherePlace(_ row: Int, _ col: Int, _ levels: Int) -> Bool { (0..<levels).allSatisfy { !(occupied[row]?.contains(col + $0) ?? false) } }
        func place(_ col: Int, _ row: Int, _ name: String) -> Int {
            guard let node = nodes[name], row <= nodes.count * 2 else { return row }
            if !placed.contains(name) {
                if isTherePlace(row, col, node.levels) { occupied[row, default: []].insert(col); placed.insert(name); cells[name] = (row, col) }
                else { return place(col, row + 1, name) }
            }
            let open = node.children.filter { !placed.contains($0) }
            let kids = open.filter { nodes[$0]?.base == node.base } + open.filter { nodes[$0]?.base != node.base }   // stable sortedBy { baseName != node.baseName }
            var maxRow: Int? = nil
            for k in kids { let r = place(col + 1, row, k); maxRow = max(maxRow ?? r, r) }
            return maxRow ?? row
        }
        var row = 0
        for p in sorted where nodes[p.name]!.parents.isEmpty { row = place(0, row, p.name); row += 1 }
        return cells
    }

    var body: some View {
        let s = controller.state
        // Unciv PromotionTree: promotions for the unit type plus any already adopted ones (e.g. kept across an upgrade).
        let typed = s.rs.promotions(forUnitType: unit.def.unitType)
        let typedNames = Set(typed.map { $0.name })
        let list = typed + unit.promotions.filter { !typedNames.contains($0) }.sorted().compactMap { s.rs.promotions[$0] }
        // Unciv PromotionTree ordering + PromotionPickerScreen.fillTable placement.
        let cells = PromotionTreeView.layout(list)
        var pos: [String: CGPoint] = [:]
        for (name, c) in cells { pos[name] = CGPoint(x: CGFloat(c.col) * (PromotionTreeView.cellW + PromotionTreeView.gapX) + PromotionTreeView.cellW / 2, y: CGFloat(c.row) * (PromotionTreeView.cellH + PromotionTreeView.gapY) + PromotionTreeView.cellH / 2) }
        let positions = pos
        let maxCol = cells.values.map { $0.col }.max() ?? 0, maxRow = cells.values.map { $0.row }.max() ?? 0
        let width = CGFloat(maxCol + 1) * (PromotionTreeView.cellW + PromotionTreeView.gapX), height = CGFloat(maxRow + 1) * (PromotionTreeView.cellH + PromotionTreeView.gapY)
        let available = Set(s.availablePromotions(for: unit).map { $0.name })
        // Unciv PromotionPickerScreen.canPromoteNow: state may change, canBePromoted, movement left, no attack this turn
        let canPromoteNow = controller.isMyTurn && !s.player.isSpectator && !available.isEmpty && unit.hasMovement && unit.attacksThisTurn == 0
        return VStack(alignment: .leading, spacing: 4) {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for p in list {
                        guard let to = positions[p.name] else { continue }
                        for r in p.prerequisites { guard let from = positions[r] else { continue }
                            let path0 = selected.flatMap { s.promotionPath(to: $0, for: unit)?.path } ?? []
                            let nodeInPath = path0.contains(p.name)
                            let selectionPath = nodeInPath && (unit.promotions.contains(r) || path0.contains(r))
                            let sameFamily = PromotionTreeView.baseName(p.name) == PromotionTreeView.baseName(r)
                            guard selectionPath || nodeInPath || sameFamily else { continue }   // Unciv otherLines is CLEAR
                            var path = Path(); path.move(to: CGPoint(x: from.x + PromotionTreeView.cellW / 2, y: from.y)); path.addLine(to: CGPoint(x: to.x - PromotionTreeView.cellW / 2, y: to.y))
                            let color: Color = selectionPath ? Theme.gold : nodeInPath ? Theme.cream : Theme.creamDim.opacity(0.5)
                            ctx.stroke(path, with: .color(color), lineWidth: selectionPath ? 3 : nodeInPath ? 2 : 1)
                        }
                    }
                }.frame(width: width, height: height)
                ForEach(list) { p in
                    let c = positions[p.name] ?? .zero
                    let have = unit.promotions.contains(p.name)
                    let can = available.contains(p.name)
                    Group {
                        HStack(spacing: 4) {
                            ArtIcon(name: p.name, folder: "PromotionIcons", fallback: "star", size: 18)
                            Text(L(p.name)).font(.system(size: 9, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.7)
                        }
                        .padding(.horizontal, 4).frame(width: PromotionTreeView.cellW, height: PromotionTreeView.cellH)
                        .foregroundStyle(have ? Theme.panelDark : Theme.cream)
                        .background(RoundedRectangle(cornerRadius: 6).fill(have ? Theme.gold : can ? Theme.panelLight : Theme.panelDark.opacity(0.8)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(can ? Theme.gold : Theme.goldDim, lineWidth: 1))
                    }
                    .contentShape(Rectangle())
                    // Unciv getButton: click selects (adopted ones too), double click accepts a pickable promotion
                    .uncivTaps(onTap: { selected = p.name }, onDoubleTap: { if canPromoteNow, let i = s.promotionPath(to: p.name, for: unit), s.canPickPromotionPath(i, for: unit) { controller.promotePath(p.name, saveDefault: saveUnitPromotion); selected = nil } else { selected = p.name } })
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected == p.name ? Color.white : Color.clear, lineWidth: 2).frame(width: PromotionTreeView.cellW, height: PromotionTreeView.cellH).offset(x: c.x - PromotionTreeView.cellW / 2, y: c.y - PromotionTreeView.cellH / 2), alignment: .topLeading)
                    .offset(x: c.x - PromotionTreeView.cellW / 2, y: c.y - PromotionTreeView.cellH / 2)
                }
            }.frame(width: width, height: height, alignment: .topLeading)
        }
        .frame(height: min(height + 10, 260))
        // Unciv PromotionPickerScreen.updateDescriptionLabel: the unit's display name until a promotion is selected
        let displayName = unit.customName.map { "\($0) (\(L(unit.name)))" } ?? L(unit.name)
        if let sel = selected {
            let info = s.promotionPath(to: sel, for: unit)
            let pickable = canPromoteNow && (info.map { s.canPickPromotionPath($0, for: unit) } ?? false)
            let listNames = Set(list.map(\.name))
            Button { controller.civilopediaEntry = "Promotion/\(sel)"; controller.showCivilopedia = true } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName + {
                        guard let i = info, !unit.promotions.contains(sel) else { return "" }
                        if i.ambiguous && i.distance > 1 && s.canBuyPromotionPath(i, for: unit) { return " - " + L("Path to [\(sel)] is ambiguous") }
                        return pickable ? ": " + i.path.map { L($0) }.joined(separator: " → ") : ""
                    }()).font(Theme.small.bold()).foregroundStyle(Theme.cream)
                    // Unciv Promotion.getDescription: the uniques, then "Requires: A OR B" over the unit type's promotions
                    if let promo = s.rs.promotions[sel] { Text(ObjectDescriptions.promotionDescription(promo, promotionsForUnitType: listNames)).font(Theme.small).foregroundStyle(Theme.creamDim).fixedSize(horizontal: false, vertical: true) }
                }.multilineTextAlignment(.leading)
            }.buttonStyle(.plain)
        } else {
            Text(displayName).font(Theme.small.bold())
        }
        // Unciv rightSideButton: "Pick promotion", disabled, while the unit may be promoted now; the selected promotion's name once one is tapped
        if canPromoteNow {
            let pickable = selected.flatMap { s.promotionPath(to: $0, for: unit) }.map { s.canPickPromotionPath($0, for: unit) } ?? false
            Button(selected.map { L($0) } ?? L("Pick promotion")) { if let sel = selected { controller.promotePath(sel, saveDefault: saveUnitPromotion); selected = nil } }.buttonStyle(ThemedButtonStyle(filled: true, compact: true)).disabled(!pickable)
        }
        }
    }
}

// MARK: - Improvement picker (Unciv ImprovementPickerScreen: improvements for the tile with yields and turns)

struct ImprovementPickerSheet: View {
    /// Unciv PickerScreen: the row you tapped, described below and committed with the bottom button.
    @State private var pickerSelection: String? = nil
    @ObservedObject var controller: GameController
    /// Unciv ImprovementPickerScreen.getProblemReport: "Research [tech] first", "Remove [feature] first",
    /// "Have this tile close to your borders", "Have this tile inside your empire", "Acquire more [resource]".
    /// Road, Railroad and the "Remove X" actions are reported like any other improvement (Unciv: "Research [The Wheel]
    /// first" on every first worker), and the player's own nation's unique improvement too - Unciv's WrongCiv is raised
    /// only for another civ's (ImprovementFunctions: `!civInfo.matchesFilter(uniqueTo)`).
    static func problemReports(_ tile: Tile, buildable: [ImprovementDef], civ: Civilization, unit: Unit, s: GameState, adjacentToBorders: Bool) -> [(String, [String])] {
        var out: [(String, [String])] = []
        let shown = Set(buildable.map { $0.name })
        let eraNow = s.rs.eraIndex(civ.eraName)
        let freshWater = s.hasFreshWater(tile)
        guard tile.isLand, !tile.isCityCenter, !tile.isMountain, tile.naturalWonder == nil else { return out }
        for imp in s.rs.improvements.values.sorted(by: { $0.name < $1.name }) where imp.isWorkerBuildable && !imp.isGreatImprovement && !shown.contains(imp.name) && imp.name != "Repair" {
            if imp.name == tile.improvement && !tile.pillaged { continue }
            // Unciv ImprovementPickerScreen.init: `if (!unit.canBuildImprovement(improvement)) continue`
            if !s.unitCanBuildImprovement(unit, imp.name, tile) { continue }
            // Unciv ProblemReport.proposedSolutions is a mutableSetOf: lines stay in the order they are proposed and a
            // repeated one is dropped (a Mine on a forested hill needs Mining once, not twice).
            var solutions: [String] = []
            func propose(_ line: String) { if !solutions.contains(line) { solutions.append(line) } }
            // Unciv ImprovementPickerScreen: maxImprovementTechErasForward < 0 → no limit, otherwise techs beyond the current era are not proposed.
            let maxEra = s.rs.constants.maxImprovementTechErasForward < 0 ? Int.max : eraNow
            var techsKnown = civ.techs
            let missingTech = imp.techRequired.flatMap { civ.techs.contains($0) ? nil : $0 }
            if let tech = missingTech { techsKnown.insert(tech) }
            // Would it be buildable with the tech, or after clearing the feature?
            var probe = tile
            var removedFeature: String? = nil
            let buildableWithTech = probe.buildableImprovements(knownTechs: techsKnown, nation: civ.nation, freshWater: freshWater).contains { $0.name == imp.name }
            if !buildableWithTech {
                guard let feature = tile.features.last(where: { s.rs.improvements["Remove \($0)"] != nil }) else { continue }
                probe.features.removeAll { $0 == feature }
                guard probe.buildableImprovements(knownTechs: techsKnown, nation: civ.nation, freshWater: freshWater).contains(where: { $0.name == imp.name }) else { continue }
                removedFeature = feature
            }
            // Unciv getProblemReport, in its order: with suggestRemoval, the removal's own report first (its tech when not
            // researched and not too many eras ahead, its borders) and then "Remove [F] first"; then MissingTech, whose tech
            // too many eras ahead drops the whole row; then the borders; then the resources to acquire.
            if let feature = removedFeature, let removal = s.rs.improvements["Remove \(feature)"] {
                // `getProblemReport(tile, null, removalImprovement)`: null - nothing of it added - when its tech is too many eras ahead
                var removalReport: [String]? = []
                if let removeTech = removal.techRequired, !civ.techs.contains(removeTech), let era = s.rs.techs[removeTech]?.era {
                    if s.rs.eraIndex(era) <= maxEra { removalReport?.append("Research [\(removeTech)] first") } else { removalReport = nil }
                }
                if removalReport != nil && tile.ownerCivId != civ.id && !removal.uniques.contains("Can be built outside your borders") { removalReport?.append("Have this tile inside your empire") }
                for line in removalReport ?? [] { propose(line) }
                propose("Remove [\(feature)] first")
            }
            if let tech = missingTech {
                guard let era = s.rs.techs[tech]?.era, s.rs.eraIndex(era) <= maxEra else { continue }
                propose("Research [\(tech)] first")
            }
            if tile.ownerCivId != civ.id && !imp.uniques.contains("Can be built outside your borders") {
                if imp.uniques.contains("Can be built just outside your borders") && !adjacentToBorders { propose("Have this tile close to your borders") }
                else if !imp.uniques.contains("Can be built just outside your borders") { propose("Have this tile inside your empire") }
            }
            for u in imp.uniqueObjects where u.pattern == "Consumes [] []" && (s.resourceCounts(civ.id)[u.param(1)] ?? 0) < u.int(0) { propose("Acquire more [\(u.param(1))]") }
            if solutions.isEmpty { continue }
            out.append((imp.name, solutions))
        }
        return out
    }
    /// Unciv ImprovementPickerScreen.addImprovementRow: a shared shortcut key goes to the buildable improvement with the most advanced tech column
    /// (ties: alphabetically earlier name); the others lose it.
    static func shortcutKey(for imp: ImprovementDef, among buildable: [ImprovementDef], rs: Ruleset) -> Character? {
        guard let key = imp.shortcutKey?.first else { return nil }
        func column(_ i: ImprovementDef) -> Int { i.techRequired.flatMap { rs.techs[$0]?.column } ?? -1 }
        let level = column(imp)
        let superseded = buildable.contains { other in
            other.name != imp.name && other.shortcutKey?.first == key && (column(other) > level || (column(other) == level && other.name < imp.name))
        }
        return superseded ? nil : key
    }
    /// Unciv ImprovementPickerScreen.addImprovementRow builds every row alike, a problem row too: the stat change
    /// (getStatDiffForImprovement, upkeep folded in as negative gold), " - N⏳" when N > 0 (the tile's own remaining turns
    /// while this improvement is in progress there - keyed on the TILE, not on the unit's order - else getTurnsToBuild),
    /// "Not in city work range", "Provides [R]" and "Replaces [I]".
    static func rowDetail(_ imp: ImprovementDef, tile: Tile, unit u: Unit, civ: Civilization, s: GameState, inWorkRange: Bool) -> String {
        // getStatDiffForImprovement: the stats of a clone after `setImprovement(name)` - so "Remove Forest" takes the
        // Lumber mill that needs the forest along, and "Remove Road" takes the road
        var change = s.statDiffForImprovement(tile, imp.name, civId: civ.id)
        change.gold -= s.improvementMaintenance(imp.name, on: tile, civId: civ.id)
        let turns = tile.improvementInProgress == imp.name ? tile.improvementTurnsLeft : s.improvementBuildTurns(imp.name, unit: u)
        var lines = [[change.delta, turns > 0 ? L("[\(turns)] turns") : ""].filter { !$0.isEmpty }.joined(separator: " · ")]
        // Unciv: warn when the tile is owned but no own city can ever work it - and only when the improvement
        // would raise some stat: `stats.max() > 0f` over the change (upkeep in), all seven stats, happiness too.
        let changeMax = max(change.production, change.food, change.gold, change.science, change.culture, change.happiness, change.faith)
        if tile.ownerCivId != nil && imp.name != "Road" && imp.name != "Railroad" && !imp.name.hasPrefix("Remove ") && !inWorkRange && changeMax > 0 { lines.append(L("Not in city work range")) }
        if let r = s.rs.resources.values.first(where: { r in tile.resource == r.name && (r.improvedBy.contains(imp.name) || r.improvement == imp.name) && s.canSeeResource(r.name, civId: civ.id) }) { lines.append(L("Provides [\(r.name)]")) }
        if let old = tile.improvement, imp.name != "Road" && imp.name != "Railroad" && !imp.name.hasPrefix("Remove ") && imp.name != "Cancel improvement order" { lines.append(L("Replaces [\(old)]")) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private func cancelOrder() { controller.cancelImprovementOrder(); controller.showImprovementPicker = false }
    /// Unciv addImprovementRow for an improvement the unit can build here: a tap selects it, a double tap builds it
    /// (`onDoubleClick { accept(improvement) }`), "Pick now!" builds it at once
    @ViewBuilder private func buildableRow(_ imp: ImprovementDef, tile: Tile, unit u: Unit, civ: Civilization, s: GameState, buildable: [ImprovementDef], inWorkRange: Bool, marked: Bool) -> some View {
        // Unciv getExplanationActor: "Current construction" whenever this improvement is in progress on the TILE, whatever
        // the selected unit's order.
        let building = tile.improvementInProgress == imp.name
        let pick = { controller.order(.build(imp.name)); controller.improvementPicked() }
        ThemedRow(title: L(imp.name), detail: ImprovementPickerSheet.rowDetail(imp, tile: tile, unit: u, civ: civ, s: s, inWorkRange: inWorkRange), selected: building || pickerSelection == imp.name,
                  onDoubleTap: { if !marked && controller.isMyTurn { pick() } }, action: { pickerSelection = imp.name }) {
            ArtIcon(name: imp.name, folder: "ImprovementIcons", fallback: "hammer.fill", size: 26)
        } trailing: { if building { Text(L("Current construction")).font(Theme.small).foregroundStyle(Theme.creamDim) } else { Button(L("Pick now!")) { pick() }.buttonStyle(ThemedButtonStyle(compact: true)).modifier(ImprovementShortcut(key: ImprovementPickerSheet.shortcutKey(for: imp, among: buildable, rs: s.rs))).disabled(marked) } }   // Unciv ImprovementPickerScreen
    }
    /// Unciv getProblemReport: an improvement that could be built once a problem is solved, with the proposed solutions.
    /// Each row carries what every row does (turns, stat change, Provides/Replaces, work range) and then its solutions; a
    /// tap shows the improvement's description (Unciv: the disabled button's own ClickListener → setDescription(improvement,
    /// LIGHT_GRAY)) - the "Pick improvement" button stays disabled for it.
    @ViewBuilder private func problemRow(_ name: String, solutions: [String], tile: Tile, unit u: Unit, civ: Civilization, s: GameState, inWorkRange: Bool) -> some View {
        let rowInfo = s.rs.improvements[name].map { ImprovementPickerSheet.rowDetail($0, tile: tile, unit: u, civ: civ, s: s, inWorkRange: inWorkRange) } ?? ""
        ThemedRow(title: L(name), detail: ([rowInfo] + solutions.map { L($0) }).filter { !$0.isEmpty }.joined(separator: "\n"), selected: pickerSelection == name, action: { pickerSelection = name }) {
            ArtIcon(name: name, folder: "ImprovementIcons", fallback: "hammer.fill", size: 26).opacity(0.5)
        } trailing: {
            // Unciv ProblemReport.isQueueable: the only problem is a removal → "Pick now!" removes first, then builds
            if solutions.count == 1, solutions[0].hasPrefix("Remove ["), solutions[0].hasSuffix("] first"), s.unitCanBuildImprovement(u, "Remove " + String(solutions[0].dropFirst(8).dropLast(7)), tile) {
                Button(L("Pick now!")) { controller.orderQueued("Remove " + String(solutions[0].dropFirst(8).dropLast(7)), then: name); controller.improvementPicked() }.buttonStyle(ThemedButtonStyle(compact: true))
            }
        }
    }
    var body: some View {
        let s = controller.state
        let civ = s.player
        ThemedSheet(L("Pick improvement"), subtitle: nil, onClose: { controller.showImprovementPicker = false }) {
            if let u = controller.selectedUnit, let tile = s.map[u.coord] {
                let current = s.yields(of: tile, for: civ.id)
                // Unciv ImprovementPickerScreen header: who owns the tile.
                Text(tile.ownerCivId == nil ? L("Unowned tile") : tile.ownerCivId == civ.id ? L("Tile owned by [\(civ.nation)] (You)") : L("Tile owned by [\(s.civ(tile.ownerCivId!)?.nation ?? "?")] - [\(s.cities.first { $0.tiles.contains(tile.coord) }?.name ?? "?")]")).font(Theme.caption.bold()).foregroundStyle(Theme.gold)
                Text("\(L(tile.baseTerrain))\(tile.features.isEmpty ? "" : ", " + tile.features.map { L($0) }.joined(separator: ", "))\(tile.resource.map { " · " + L($0) + (tile.resourceAmount > 0 ? " (\(tile.resourceAmount))" : "") } ?? "") · \(current.short)").font(Theme.caption).foregroundStyle(Theme.creamDim)
                let buildable = tile.buildableImprovements(knownTechs: civ.techs, nation: civ.nation, freshWater: s.hasFreshWater(tile))
                let adjacentToBorders = tile.ownerCivId == nil && s.map.neighbors(of: tile.coord).contains { s.map[$0]?.ownerCivId == civ.id }
                // Unciv ImprovementPickerScreen.tileMarkedForCreatesOneImprovement: a tile a construction has claimed takes no worker orders.
                let markedForCreatesOneImprovement = s.cities.contains { $0.civId == civ.id && $0.reservedImprovementTile == tile.coord }
                // Unciv ImprovementPickerScreen.tileMarkedForCreatesOneImprovement: a tile a construction has claimed takes no worker orders.
                let allowedHere = buildable.filter { s.unitCanBuildImprovement(u, $0.name, tile) }.filter { tile.ownerCivId == civ.id || $0.uniques.contains("Can be built outside your borders") || ($0.uniques.contains("Can be built just outside your borders") && adjacentToBorders) }
                let inWorkRange = s.map.tilesWithin(tile.coord, radius: s.rs.constants.cityWorkRange).contains { s.city(at: $0)?.civId == civ.id }
                let problems = ImprovementPickerSheet.problemReports(tile, buildable: allowedHere, civ: civ, unit: u, s: s, adjacentToBorders: adjacentToBorders)
                let showCancel = tile.improvementInProgress != nil && s.rs.improvements["Cancel improvement order"] != nil
                // Unciv ImprovementPickerScreen.init: one loop over ruleset.tileImprovements (TileImprovements.json order), each
                // improvement becoming a buildable row, a row with its problem report, or the Cancel row - mixed in that order
                let rowNames = s.rs.improvementOrder.filter { n in
                    allowedHere.contains { $0.name == n } || problems.contains { $0.0 == n } || (n == "Cancel improvement order" && showCancel)
                }
                Panel(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(rowNames, id: \.self) { name in
                            if let imp = allowedHere.first(where: { $0.name == name }) {
                                buildableRow(imp, tile: tile, unit: u, civ: civ, s: s, buildable: buildable, inWorkRange: inWorkRange, marked: markedForCreatesOneImprovement)
                            } else if name == "Cancel improvement order" {
                                // Unciv: the Cancel row's tap only selects it (the description and the right button say "Cancel
                                // improvement order"); "Pick now!", a double tap or the right button cancels
                                ThemedRow(title: L(name), detail: "", selected: pickerSelection == name, onDoubleTap: { cancelOrder() }, action: { pickerSelection = name }) {
                                    ArtIcon(name: name, folder: "ImprovementIcons", fallback: "xmark.circle", size: 26)
                                } trailing: { Button(L("Pick now!")) { cancelOrder() }.buttonStyle(ThemedButtonStyle(compact: true)) }
                            } else if let report = problems.first(where: { $0.0 == name }) {
                                problemRow(name, solutions: report.1, tile: tile, unit: u, civ: civ, s: s, inWorkRange: inWorkRange)
                            }
                        }
                        // Unciv PickerScreen.rightSideButton: the selected improvement is committed here.
                        if let sel = pickerSelection, let def = s.rs.improvements[sel] {
                            Divider2()
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L(sel)).font(Theme.heading(14)).foregroundStyle(Theme.gold)
                                // Unciv ImprovementPickerScreen.setDescription: improvement.getDescription(ruleset)
                                Text(ObjectDescriptions.improvementDescription(def, rs: s.rs)).font(Theme.small).foregroundStyle(Theme.creamDim).fixedSize(horizontal: false, vertical: true)
                                if sel == "Cancel improvement order" {
                                    Button(L("Cancel improvement order")) { cancelOrder() }.buttonStyle(ThemedButtonStyle(filled: true, compact: true)).disabled(!controller.isMyTurn)
                                } else {
                                    Button("\(L("Pick improvement")): \(L(sel))") {
                                        controller.order(.build(sel)); controller.improvementPicked()
                                    }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                                        .disabled(markedForCreatesOneImprovement || !controller.isMyTurn || !allowedHere.contains { $0.name == sel })
                                }
                            }
                        }
                    }
                }
            }   // PromotionPickerScreen is always opened for a unit
        }
    }
}

// MARK: - Rename popups (Unciv CityRenamePopup / UnitRenamePopup)

/// Unciv AskTextPopup: the prompt, a field of at most 32 characters without []{}"\\<>, Close and OK - OK checks
/// `validate` and shows "Invalid input! Please enter a different string." in red instead of closing when it fails
struct RenamePopup: View {
    let title: String
    let initial: String
    var allowEmpty: Bool = false
    var validate: ((String) -> Bool)? = nil
    let onDone: (String?) -> Void
    @State private var text = ""
    @State private var showError = false
    private static let illegalChars = Set("[]{}\"\\<>")
    var body: some View {
        ThemedDialog(title: title, onDismiss: { onDone(nil) }) {
            TextField("", text: $text)
                .textFieldStyle(.plain).font(Theme.body).foregroundStyle(Theme.cream)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Theme.R.control, style: .continuous).fill(Theme.fill))
                .overlay(RoundedRectangle(cornerRadius: Theme.R.control, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
                .onAppear { text = initial }
                .onChange(of: text) { _, t in
                    let clean = String(t.filter { !Self.illegalChars.contains($0) }.prefix(32))
                    if clean != t { text = clean }
                }
            if showError { Text(L("Invalid input! Please enter a different string.")).font(Theme.caption).foregroundStyle(Color.red) }
            HStack(spacing: 10) {
                Button(L("Cancel")) { onDone(nil) }.buttonStyle(ThemedButtonStyle())
                Button(L("OK")) {
                    if let validate, !validate(text) { showError = true; return }
                    onDone(validate == nil ? text.trimmingCharacters(in: .whitespaces) : text)
                }
                    .buttonStyle(ThemedButtonStyle(filled: true))
                    .disabled(validate == nil && !allowEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Detailed stats popup (Unciv DetailedStatsPopup: base values / bonuses / final per stat)

/// Unciv DetailedStatsPopup: a header of stat names (tap one to show only it, again for all) behind the "+"/"-" detail
/// toggle, then "Base values" (the base stat tree, happiness merged in), "Bonuses" (the percent bonus tree) and "Final"
/// (the final stat list with the happiness list merged in), each by source in sorted order with a Total row; with details
/// on, the trees' children follow indented with "- ". Tapping a source highlights its row.
struct DetailedStatsPopup: View {
    @ObservedObject var controller: GameController
    let cityId: Int
    @State private var onlyWithStat: String? = nil
    @State private var isDetailed = false
    @State private var sourceHighlighted: String? = nil
    private static let allStats = ["Production", "Food", "Gold", "Science", "Culture", "Happiness", "Faith"]   // Unciv Stat order
    private let colorTotal = Color(red: 0.5, green: 0.5, blue: 1)            // Color.BLUE.brighten(0.5f)
    private let colorSelector = Color(red: 0, green: 0.5, blue: 0)           // Color.GREEN.darken(0.5f)

    var body: some View {
        let s = controller.state
        let stats = onlyWithStat.map { [$0] } ?? Self.allStats.filter { $0 != "Faith" || s.religionEnabled }
        ThemedDialog(title: s.city(cityId)?.name ?? "", subtitle: nil, onDismiss: { controller.showDetailedStats = false }) {
            if let city = s.city(cityId), let m = CityStats(city: city, state: s) {
                let _ = m.update(currentConstruction: city.currentProduction)
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Button { isDetailed.toggle() } label: {
                            Text(isDetailed ? "-" : "+").font(Theme.heading(16)).frame(width: 25, height: 25).background(Circle().fill(Theme.panelLight)).overlay(Circle().stroke(Color.white, lineWidth: 1))
                        }.buttonStyle(.plain).frame(width: 130, alignment: .leading)
                        ForEach(stats, id: \.self) { st in
                            Button { onlyWithStat = onlyWithStat == nil ? st : nil } label: { cell(L(st), onlyWithStat == st ? colorSelector : nil) }.buttonStyle(.plain)
                        }
                    }
                    Divider()
                    ScrollView {
                        VStack(spacing: 3) {
                            section(L("Base values"))
                            treeRows(m.baseStatTree, stats: stats, happiness: m.happinessList, percentage: false)
                            section(L("Bonuses"))
                            treeRows(m.statPercentBonusTree, stats: stats, happiness: nil, percentage: true)
                            section(L("Final"))
                            finalRows(m, stats: stats)
                        }
                    }.frame(maxHeight: 300)
                    Button(L("Close")) { controller.showDetailedStats = false }.buttonStyle(ThemedButtonStyle(compact: true)).keyboardShortcut(.space, modifiers: [])
                }
            }
        }
    }

    private func section(_ title: String) -> some View {
        VStack(spacing: 2) { Divider(); Text(title).font(Theme.caption.bold()).frame(maxWidth: .infinity); Divider() }
    }
    private func cell(_ text: String, _ color: Color?, leading: Bool = false) -> some View {
        Text(text).font(Theme.small).lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: leading ? 130 : .infinity, alignment: leading ? .leading : .center)
            .frame(width: leading ? 130 : nil)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).stroke(color ?? .clear, lineWidth: 1.5))
    }
    /// Unciv decimalFormatter "0.#" and percentFormatter "+0.#%"
    private func number(_ v: Double, percentage: Bool) -> String {
        if v == 0 { return "-" }
        let f = NumberFormatter(); f.minimumFractionDigits = 0; f.maximumFractionDigits = 1; f.minimumIntegerDigits = 1; f.roundingMode = .halfEven
        let t = f.string(from: NSNumber(value: v)) ?? "\(v)"
        return percentage ? (v > 0 ? "+" : "") + t + "%" : t
    }
    private func row(_ label: String, _ values: [Double], percentage: Bool, color: Color?, onTap: (() -> Void)?) -> some View {
        HStack(spacing: 4) {
            if let onTap { Button(action: onTap) { cell(label, color, leading: true) }.buttonStyle(.plain) } else { cell(label, color, leading: true) }
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in cell(number(v, percentage: percentage), color) }
        }
    }
    /// Unciv traverseTree: the children in sorted order (happiness merged in at the top level of the base tree); a row
    /// with no stats, or none of the chosen stat, is skipped; the top level sums into Total
    private func treeRows(_ node: StatTreeNode, stats: [String], happiness: [(String, Double)]?, percentage: Bool) -> some View {
        var entries: [(String, Stats, StatTreeNode?)] = node.childOrder.map { ($0, node.children[$0]!.totalStats, node.children[$0]) }
        if let happiness {
            for (key, value) in happiness {
                if let i = entries.firstIndex(where: { $0.0 == key }) { if entries[i].1["Happiness"] == 0 { entries[i].1["Happiness"] = value } }
                else { var st = Stats(); st["Happiness"] = value; entries.append((key, st, nil)) }
            }
        }
        entries.sort { $0.0 < $1.0 }
        var flat: [(label: String, values: [Double])] = []
        func walk(_ list: [(String, Stats, StatTreeNode?)], depth: Int) {
            for (name, st, child) in list {
                if Self.allStats.allSatisfy({ st[$0] == 0 }) { continue }
                if let only = onlyWithStat, st[only] == 0 { continue }
                flat.append((String(repeating: "- ", count: depth) + L(name), stats.map { st[$0] }))
                if isDetailed, let c = child {
                    walk(c.childOrder.sorted().map { ($0, c.children[$0]!.totalStats, c.children[$0]) }, depth: depth + 1)
                }
            }
        }
        walk(entries, depth: 0)
        let totals = stats.map { st in entries.reduce(0.0) { $0 + $1.1[st] } }
        return VStack(spacing: 3) {
            ForEach(Array(flat.enumerated()), id: \.offset) { _, r in
                row(r.label, r.values, percentage: percentage, color: sourceHighlighted == r.label ? colorSelector : nil) { sourceHighlighted = sourceHighlighted == r.label ? nil : r.label }
            }
            row(L("Total"), totals, percentage: percentage, color: colorTotal, onTap: nil)
        }
    }
    /// Unciv "Final": the final stat list sorted by source, happiness merged, then Total
    private func finalRows(_ m: CityStats, stats: [String]) -> some View {
        var map: [String: Stats] = [:]
        for k in m.finalStatList.order { map[k] = m.finalStatList[k] }
        for (key, value) in m.happinessList {
            if var st = map[key] { if st["Happiness"] == 0 { st["Happiness"] = value; map[key] = st } }
            else { var st = Stats(); st["Happiness"] = value; map[key] = st }
        }
        let rows = map.keys.sorted().compactMap { k -> (String, Stats)? in
            let st = map[k]!
            if st.isEmpty { return nil }
            if let only = onlyWithStat, st[only] == 0 { return nil }
            return (k, st)
        }
        let totals = stats.map { st in rows.reduce(0.0) { $0 + $1.1[st] } }
        return VStack(spacing: 3) {
            ForEach(rows, id: \.0) { k, st in
                row(L(k), stats.map { st[$0] }, percentage: false, color: sourceHighlighted == k ? colorSelector : nil) { sourceHighlighted = sourceHighlighted == k ? nil : k }
            }
            row(L("Total"), totals, percentage: false, color: colorTotal, onTap: nil)
        }
    }
}

// MARK: - Great person points breakdown (Unciv GreatPersonPointsBreakdownPopup)

struct GreatPersonPointsBreakdownPopup: View {
    @ObservedObject var controller: GameController
    let cityId: Int
    var body: some View {
        let s = controller.state
        let person = controller.gppBreakdownPerson
        ThemedDialog(title: L(person ?? "Great person points") + " (\(L(s.city(cityId)?.name ?? "")))", subtitle: nil, onDismiss: { controller.showGPPBreakdown = false; controller.gppBreakdownPerson = nil }) {
            if let city = s.city(cityId) {
                let b = s.greatPersonPointsBreakdown(city)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array((b.base.map { ($0, false) } + b.percent.map { ($0, true) }).enumerated()), id: \.offset) { _, item in
                        if let line = Self.line(item.0, isPercentage: item.1, person: person) {
                            Text(line).font(Theme.body)
                        }
                    }
                }
            }
            // Unciv GreatPersonPointsBreakdownPopup: addCloseButton()
            Button(L("Close")) { controller.showGPPBreakdown = false; controller.gppBreakdownPerson = nil }.buttonStyle(ThemedButtonStyle(compact: true))
        }
    }
    /// Entry.toString: "{source}: +n" (one great person), "+n%" for an all-GP bonus, otherwise each great person listed
    static func line(_ e: GameState.GPPEntry, isPercentage: Bool, person: String?) -> String? {
        func signed(_ v: Int) -> String { v >= 0 ? "+\(v)" : "\(v)" }
        let pct = isPercentage ? "%" : ""
        if let p = person {
            guard let v = e.counter[p], v != 0 else { return nil }
            return L(e.source) + ": " + signed(v) + pct
        }
        if e.counter.isEmpty { return nil }
        if e.isAllGP { return L(e.source) + ": " + signed(e.counter.values.first ?? 0) + pct }
        return L(e.source) + ": " + e.counter.sorted { $0.key < $1.key }.map { signed($0.value) + pct + " " + L($0.key) }.joined(separator: ", ")
    }
}

/// Hardware-keyboard shortcut for an improvement row (Unciv keyShortcuts + tooltip).
struct ImprovementShortcut: ViewModifier {
    let key: Character?
    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(KeyEquivalent(Character(key.lowercased())), modifiers: []).help(String(key)) } else { content }
    }
}
