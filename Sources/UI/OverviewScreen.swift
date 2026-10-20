// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv Int.toLabel() = this.tr().toLabel(): a number in the game language's Number.tr
fileprivate func trNum(_ n: Int) -> String { Translations.shared.numberTr(n) }

/// Empire overview: the tabbed summary Unciv shows for cities, units, resources, wonders, deals, notifications and more.
struct OverviewScreen: View {
    @ObservedObject var controller: GameController
    @Environment(\.dismiss) private var dismiss
    /// Unciv TabbedPager.activePage: nil while no page is selected - the category asked for was disabled or hidden
    @State private var tab: String?
    @State private var didActivate = false
    @State private var highlightUnit: Int? = nil   // Unciv overviewScreen.select(EmpireOverviewCategories.Units, unitId)
    @State private var upgradeMenuUnit: Int? = nil   // Unciv UnitOverviewTabHelpers: the upgrade cell opens a UnitUpgradeMenu
    @State private var renameUnitId: Int? = nil      // Unciv UnitOverviewTabColumn.EditName: UnitRenamePopup over the overview
    // Unciv SortableGrid: tap a header to sort, again to flip; each grid has its own state (GameController keeps it)
    @State private var citySort: GameController.OverviewSort
    @State private var unitSort: GameController.OverviewSort
    @State private var selectedReligion: String?   // Unciv ReligionTabPersistableData.selectedReligion (GameController keeps it)
    @State private var religionCountOpen = false
    @State private var notifRevision = 0
    @State private var overviewRevision = 0         // Unciv: the "Religions to be founded" expander starts closed
    private let tabs = ["Cities", "Stats", "Trades", "Units", "Politics", "Resources", "Religion", "Wonders", "Notifications"]   // Unciv EmpireOverviewCategories (espionage has its own screen)
    /// Unciv EmpireOverviewCategories.shortcutKey: a fixed letter per page, not a KeyboardBinding the player may change
    private static let tabKeys: [String: Character] = [
        "Cities": "c", "Stats": "s", "Trades": "t", "Units": "u", "Politics": "p", "Resources": "r", "Religion": "f", "Wonders": "w", "Notifications": "n",
    ]
    /// Unciv EmpireOverviewScreen(viewingPlayer, defaultCategory, selection)
    init(controller: GameController, initialTab: String? = nil, initialSelect: String = "") {
        self.controller = controller
        // `defaultCategory ?: persistState.last`, selected only when its page is Normal: TabbedPager.selectPage refuses a
        // disabled page and a hidden one has none - either way no page is shown
        // ("Deals" / "Diplomacy" are this port's older names of Trades / Politics, as a stored last page may still hold.)
        var want = initialTab ?? UserSettings.overviewLastPage
        want = ["Deals": "Trades", "Diplomacy": "Politics"][want] ?? want
        _tab = State(initialValue: Self.tabState(want, controller.state, controller.selectedCiv) == 0 ? want : nil)
        _citySort = State(initialValue: controller.overviewCitySort)
        _unitSort = State(initialValue: controller.overviewUnitSort)
        // `select(pageObject, selection)` for the category it opens on: ReligionOverviewTab.select stores the religion
        // (the persisted one stays otherwise), UnitOverviewTab.select marks the unit's row
        let religion = want == "Religion" && !initialSelect.isEmpty ? initialSelect : controller.overviewReligionSelection
        _selectedReligion = State(initialValue: religion)
        _highlightUnit = State(initialValue: want == "Units" ? Int(initialSelect) : nil)
    }

    var body: some View {
        let _ = UIMeasure.count("OverviewScreen.body")
        let s = controller.state
        let me = controller.selectedCiv   // Unciv EmpireOverviewScreen(worldScreen.selectedGameView.civView, ...)
        let visibleTabs = tabs.filter { Self.tabState($0, s, me) != 2 }
        ThemedSheet(L("Overview"), subtitle: "\(L(me.nation)) · \(L("Turn")) \(s.uncivTurns)", onClose: { close() }) {
            Group {
                // Unciv TabbedPager.addPage(shortcutKey): only pages that exist, and a disabled page's button is inactive
                ForEach(visibleTabs, id: \.self) { t in
                    Button("") { select(t, s, me) }
                        .keyboardShortcut(KeyEquivalent(Self.tabKeys[t] ?? " "), modifiers: [])
                        .disabled(Self.tabState(t, s, me) != 0)
                        .frame(width: 0, height: 0).opacity(0)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { ForEach(visibleTabs, id: \.self) { t in Button(L(t)) { select(t, s, me) }.buttonStyle(ThemedButtonStyle(filled: tab == t, compact: true)).disabled(Self.tabState(t, s, me) == 1) } }
            }
            switch tab ?? "" {
            case "Cities": cities(s, me)
            case "Units": units(s, me)
            case "Resources": resources(s, me)
            case "Wonders": wonders(s, me)
            case "Deals", "Trades": deals(s, me)
            case "Diplomacy", "Politics": politics(s, me)
            case "Religion": religion(s, me)
            case "Stats": stats(s, me)
            case "Notifications": notifications(s, me)
            default: EmptyView()   // activePage == -1
            }
        }
        // The page opened on is activated once, as TabbedPager.selectPage does in EmpireOverviewScreen's init - which
        // saves it as persistState.last whether it came from the last one or from the caller (a stat tap, a notification,
        // the city screen). Coming back to the screen (EmpireOverviewScreen.resume) passes an empty caption and saves nothing.
        .onAppear {
            guard !didActivate else { return }
            didActivate = true
            controller.overviewReturn = nil   // whatever it had pushed has been popped, or the map was reset since
            controller.overviewReligionSelection = selectedReligion
            if let t = tab { activated(t, s, me) }
        }
        .onChange(of: selectedReligion) { _, v in controller.overviewReligionSelection = v }
        // Unciv UnitOverviewTabHelpers: clicking an upgrade icon opens the UnitUpgradeMenu over the overview and
        // refreshes the grid when it closes - the screen stays put and no gold moves until a button there is pressed.
        .overlay {
            if let id = upgradeMenuUnit, let u = s.unit(id) {
                UnitUpgradeMenuView(controller: controller, unit: u, onClose: { upgradeMenuUnit = nil })
            }
        }
        // Unciv UnitRenamePopup(overviewScreen, unit) { update(); overviewScreen.select(Units, key) }: OK renames that unit
        // (an empty name clears it) and selects its row
        .overlay {
            if let id = renameUnitId, let u = s.unit(id) {
                RenamePopup(title: L("Choose name for [\(u.name)]"), initial: u.customName ?? L(u.name), validate: { $0 != u.name },
                            onDone: { n in if let n { controller.renameUnit(n, unitId: id); highlightUnit = id }; renameUnitId = nil })
            }
        }
        // Unciv persistState: the grids' sort survives the screen
        .onChange(of: citySort) { _, v in controller.overviewCitySort = v }
        .onChange(of: unitSort) { _, v in controller.overviewUnitSort = v }
        .screenShown("overview")
        .onChange(of: tab) { _, t in GameEvents.post(.screen("overview_" + (t ?? ""))) }
    }
    /// Unciv TabbedPager.selectPage: nothing for the page already shown or a disabled one; otherwise the page's activated()
    private func select(_ t: String, _ s: GameState, _ me: Civilization) {
        guard Self.tabState(t, s, me) == 0, t != tab else { return }
        tab = t
        activated(t, s, me)
    }
    /// Unciv IPageExtensions.activated: StatsOverviewTab completes "See your stats breakdown", then EmpireOverviewTab
    /// remembers the page - as `EmpireOverviewCategories.entries[index]` with the PAGER's index, which skips a hidden
    /// Religion page: with religion off Wonders is remembered as Religion and Notifications as Wonders.
    private func activated(_ t: String, _ s: GameState, _ me: Civilization) {
        if t == "Stats" { controller.completeTask("stats") }
        if let i = tabs.filter({ Self.tabState($0, s, me) != 2 }).firstIndex(of: t) { UserSettings.overviewLastPage = tabs[i] }
    }

    /// Unciv EmpireOverviewTabState: 0 Normal, 1 Disabled, 2 Hidden
    private static func tabState(_ t: String, _ s: GameState, _ me: Civilization) -> Int {
        switch t {
        case "Cities": return s.cities(of: me.id).isEmpty ? 1 : 0
        case "Stats": return me.isSpectator ? 1 : 0
        // Unciv Trades.showDisabled: every diplomacy's `trades` empty and no trade request of ours waiting anywhere
        case "Trades": return s.currentTrades(me).values.allSatisfy { $0.isEmpty } && !s.pendingOffers.contains(where: { $0.from == me.id && !$0.isFriendshipRequest }) ? 1 : 0
        case "Units": return s.units(of: me.id).isEmpty ? 1 : 0
        case "Politics": return me.metCivs.isEmpty ? 1 : 0
        // Unciv Resources.showDisabled: `detailedCivResources.none { it.resource.resourceType != Bonus }` - the stored
        // per-origin list, where a resource produced and used up still has its rows (stockpiles do not count)
        case "Resources": return !s.detailedCivResources(me.id).contains(where: { $0.amount != 0 && s.rs.resources[$0.resource]?.resourceType != "Bonus" }) ? 1 : 0
        case "Religion": return !s.religionEnabled ? 2 : (s.civs.allSatisfy { $0.religionName == nil && $0.pantheonBelief == nil } ? 1 : 0)
        case "Wonders": return s.cities(of: me.id).isEmpty && !me.explored.contains(where: { s.map[$0]?.naturalWonder != nil }) ? 1 : 0
        case "Notifications": return me.notifications.isEmpty && me.notificationLog.isEmpty ? 1 : 0
        default: return 0
        }
    }

    private func sorted<T>(_ items: [T], _ sort: GameController.OverviewSort, _ key: (T) -> Double) -> [T] { items.sorted { sort.descending ? key($0) > key($1) : key($0) < key($1) } }
    /// A text column: a locale collator (Unciv ISortableGridContentProvider.collator), descending the comparator reversed.
    /// `emptyLast` is UnitOverviewTabColumn's non-numeric comparator, which counts an empty cell as "😀zzz" - after every
    /// name ascending, before them descending; the Cities columns compare the plain text, so "" comes first ascending.
    private func sortedByName<T>(_ items: [T], _ sort: GameController.OverviewSort, emptyLast: Bool = false, _ key: (T) -> String) -> [T] {
        items.sorted { a, b in
            let ka = key(a), kb = key(b)
            if emptyLast && ka.isEmpty != kb.isEmpty { return sort.descending ? ka.isEmpty : kb.isEmpty }
            let order = LocaleCode.compare(ka, kb)
            return sort.descending ? order == .orderedDescending : order == .orderedAscending
        }
    }

    /// Unciv ISortableGridContentProvider.defaultSort: the text columns open ascending, the numbers descending.
    private func defaultDescending(for column: String) -> Bool {
        // Cities: name, construction, celebration, garrison and defence open ascending; Units: everything
        // but strength, ranged strength, movement and promotions. The unit columns' titles are UnitOverviewTabColumn's
        // headerLabel ?: name - "Name", "Action", "Closest city", "Promotions", "Upgrade", "Health", "XP"; the strength,
        // ranged strength and movement columns' headers are their Fonts glyphs.
        let ascending = [L("City"), L("Construction"), "🎉", "🛡", "🏰",
                         L("Name"), L("Action"), L("Closest city"), L("Upgrade"), L("Health"), L("XP")]
        return !ascending.contains(column)
    }

    /// Unciv SortableGrid header with fixed column widths (the grid scrolls horizontally); toggleSort: the sorted column
    /// flips, another starts in its defaultSort (EditName's None makes it no button at all)
    private func gridHeader(_ cols: [(String, CGFloat)], _ sort: Binding<GameController.OverviewSort>) -> some View {
        HStack(spacing: 4) { ForEach(cols, id: \.0) { c in
            Button { guard c.0 != "✏️" else { return }; if sort.wrappedValue.column == c.0 { sort.wrappedValue.descending.toggle() } else { sort.wrappedValue = GameController.OverviewSort(column: c.0, descending: defaultDescending(for: c.0)) } } label: {
                HStack(spacing: 2) { Text(c.0).font(Theme.small.bold()).foregroundStyle(Theme.gold).lineLimit(1); if sort.wrappedValue.column == c.0 { Image(systemName: sort.wrappedValue.descending ? "chevron.down" : "chevron.up").font(.system(size: 8)).foregroundStyle(Theme.gold) } }
                    .frame(width: c.1, alignment: .leading)
            }.buttonStyle(.plain)
        } }
    }
    /// Unciv CityOverviewTabColumn: Name, Status, Construction, Population, Food, Gold, Science, Production, Culture, Faith, WLTK, Garrison, CityDefense, Religion
    /// - Population's header is its stat icon (ImageGetter.getStatIcon("Population")), here 👥 - no "Pop" text
    private func cityColumns(_ s: GameState) -> [(String, CGFloat)] {
        var cols: [(String, CGFloat)] = [(L("City"), 110), ("⚑", 24), ("🏗", 24), (L("Construction"), 140), ("👥", 34), ("🍞", 34), ("💰", 34), ("🔬", 34), ("⚙️", 34), ("🎭", 34)]
        cols.append(("😊", 34))   // Unciv CityOverviewTabColumn.Happiness
        if s.religionEnabled { cols.append(("🕊", 34)) }
        cols += [("🎉", 80), ("🛡", 90), ("🏰", 64)]
        if s.religionEnabled { cols.append((L("Religion"), 100)) }
        return cols
    }
    /// Unciv SortableGrid.getTotalsRow: the sums under the columns that have one.
    private func cityTotalCells(_ s: GameState, _ me: Civilization) -> [String] {
        let list = s.cities(of: me.id)
        let stats = list.map { s.computeStats(for: $0) }
        // Unciv getTotalsActor: the sum of the rounded cell values
        func sum(_ f: (Stats) -> Double) -> String { "\(stats.map { Self.roundToInt(f($0.total)) }.reduce(0, +))" }
        var cells: [String] = ["\(L("Total")) \(list.count)", "", "", "",
                               "\(list.map { $0.population }.reduce(0, +))",
                               "\(stats.map { Self.roundToInt($0.foodSurplus) }.reduce(0, +))",
                               sum { $0.gold }, sum { $0.science }, sum { $0.production }, sum { $0.culture },
                               "\(list.map { Self.roundToInt(s.happinessBreakdown($0.civId, onlyCity: $0.id).total) }.reduce(0, +))"]
        if s.religionEnabled { cells.append(sum { $0.faith }) }
        cells += ["\(list.filter { $0.wltkdTurns > 0 }.count)", "\(list.filter { garrison(s, $0) != nil }.count)", ""]
        // Unciv Religion.getTotalsActor: nothing without cities or without a religion of our own (a pantheon is one, named
        // after its belief); otherwise the cities whose majority religion is ours
        if s.religionEnabled {
            if !list.isEmpty, let ours = me.religionName ?? me.pantheonBelief { cells.append("\(list.filter { s.majorityReligion(of: $0) == ours }.count)") }
            else { cells.append("") }
        }
        return cells
    }

    @ViewBuilder
    private func cityTotals(_ s: GameState, _ me: Civilization, _ cols: [(String, CGFloat)]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(zip(cityTotalCells(s, me), cols).enumerated()), id: \.offset) { _, cell in
                Text(cell.0).font(Theme.small.bold()).foregroundStyle(Theme.gold).lineLimit(1).frame(width: cell.1.1, alignment: .leading)
            }
        }
    }

    /// Kotlin roundToInt (Math.round): floor(x + 0.5)
    static func roundToInt(_ d: Double) -> Int { Int((d + 0.5).rounded(.down)) }
    private func cityStatus(_ c: City) -> String { c.razing ? "🔥" : c.resistanceTurns > 0 ? "✊" : c.isPuppet ? "🎭" : "" }
    private func constructionText(_ s: GameState, _ c: City) -> String {
        // Unciv getCityProductionText: the name and getTurnsToConstructionString ("\n[progress/]cost⚙ turns⏳", then the
        // other currencies it can be bought with)
        if let p = c.currentProduction {
            return L(p.name) + s.turnsToConstructionString(p, in: c)
        }
        // a perpetual: its name and getProductionTooltip (production over the conversion rate per turn; nothing for Idle)
        let name = c.convertProductionTo
        if name.isEmpty || name == City.idleConstruction { return L(name) }
        let rate = max(1, Int((1 / max(0.0001, s.statConversionRate(c.civId, name))).rounded()))
        return L(name) + "\n\(Int((s.currentCityStats(c.id).total.production / Double(rate)).rounded()))/⏳"
    }
    private func garrison(_ s: GameState, _ c: City) -> Unit? { s.units(at: c.coord).first { $0.isMilitary && $0.def.isLand && $0.civId == c.civId } }
    private func cityCells(_ s: GameState, _ c: City) -> [String] {
        let st = s.computeStats(for: c)
        let buildingIcon: String = {
            // Unciv ConstructionIcon: no portrait for an empty queue, the perpetual's (Idle's too) otherwise
            guard let p = c.currentProduction else { return ["Gold": "💰", "Science": "🔬", "Culture": "🎵", "Faith": "🕊", "Food": "🍎", City.idleConstruction: "–"][c.convertProductionTo] ?? "" }
            if case .unit = p { return "⚔️" }
            if case .building(let n) = p { return s.rs.buildings[n]?.isAnyWonder == true ? "🏛" : "🏠" }
            return ""
        }()
        // Unciv CityOverviewTabColumn.getEntryValue: currentCityStats[stat].roundToInt(), shown unsigned
        var out = [L(c.name) + (c.isCapital ? " ★" : ""), cityStatus(c), buildingIcon, constructionText(s, c), "\(c.population)", "\(Self.roundToInt(st.foodSurplus))", "\(Self.roundToInt(st.total.gold))", "\(Self.roundToInt(st.total.science))", "\(Self.roundToInt(st.total.production))", "\(Self.roundToInt(st.total.culture))"]
        out.append("\(Self.roundToInt(s.happinessBreakdown(c.civId, onlyCity: c.id).total))")
        if s.religionEnabled { out.append("\(Self.roundToInt(st.total.faith))") }
        out.append(c.wltkdTurns > 0 ? "🎉 \(c.wltkdTurns)" : (c.demandedResource.isEmpty ? "" : L(c.demandedResource)))
        out.append(garrison(s, c).map { $0.customName ?? L($0.name) } ?? "")
        out.append("\(Int(s.cityStrength(c).rounded()))/\(s.cityMaxHealth(c))")
        if s.religionEnabled { out.append(s.majorityReligion(of: c) ?? "") }
        return out
    }
    private func cities(_ s: GameState, _ me: Civilization) -> some View {
        let cols = cityColumns(s)
        return Panel(padding: 8) {
            VStack(alignment: .leading, spacing: 4) {
                // Unciv CityOverviewTabColumn header tips
                Text("⚑: " + L("Status\n(puppet, resistance or being razed)").replacingOccurrences(of: "\n", with: " ") + " · 🎉: " + L("We Love The King Day") + " · 🛡: " + L("Garrisoned by unit") + " · 🏰: " + L("City defense")).font(Theme.small).foregroundStyle(Theme.creamDim)
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        gridHeader(cols, $citySort)
                        ForEach(sortedCities(s, me)) { c in
                            HStack(spacing: 4) {
                                ForEach(Array(zip(cityCells(s, c), cols).enumerated()), id: \.offset) { i, cell in
                                    let label = Text(cell.0).font(Theme.small).lineLimit(1).frame(width: cell.1.1, alignment: .leading)
                                    if i == 0 {
                                        // Unciv CityColumn: game.pushScreen { CityScreen(city) } - its exit comes back here
                                        Button { push("city"); controller.selectedCityId = c.id; close(); controller.afterSheetDismiss { controller.showCity = true } } label: { label }.buttonStyle(.plain)
                                    } else if cell.1.0 == "🛡", let g = garrison(s, c) {
                                        // Unciv Garrison: overviewScreen.select(Units, unit.id) - the Units grid keeps its own sort
                                        Button { highlightUnit = g.id; select("Units", s, me) } label: { label }.buttonStyle(.plain)
                                    } else if cell.1.0 == "🎉", c.wltkdTurns <= 0, !c.demandedResource.isEmpty {
                                        // Unciv WLTK: actionContext.showOneTimeNotification(getExploredResourcesNotification(civ, demandedResource))
                                        Button { if let n = s.exploredResourcesNotification(me.id, resource: c.demandedResource) { close(); controller.showOneTimeNotification(n, inList: false) } } label: { label }.buttonStyle(.plain)
                                    } else {
                                        label
                                    }
                                }
                            }
                        }
                        cityTotals(s, me, cols)
                    }
                }
            }
        }
    }

    /// The overview is presented either by GameController.showOverview or by the top bar's own tab binding; dismiss() covers both.
    private func close() { controller.showOverview = false; dismiss() }
    /// Unciv game.pushScreen over the overview: popping `screen` comes back to this page (GameController.overviewReturn),
    /// `select` naming the row to select then
    private func push(_ screen: String, select: @escaping () -> String = { "" }) {
        controller.overviewReturn = GameController.OverviewReturn(screen: screen, page: tab, select: select)
    }

    private func sortedCities(_ s: GameState, _ me: Civilization) -> [City] {
        let list = s.cities(of: me.id)
        let o = citySort
        switch o.column {
        case L("City"): return sortedByName(list, o) { L($0.name) }   // Unciv: compareBy(collator) { it.name.tr(hideIcons = true) }
        case "⚑": return sorted(list, o) { $0.razing ? 3 : $0.resistanceTurns > 0 ? 2 : $0.isPuppet ? 1 : 0 }
        case L("Construction"): return sortedByName(list, o) { $0.currentProduction?.name ?? "" }
        case "👥": return sorted(list, o) { Double($0.population) }
        case "🍞": return sorted(list, o) { s.computeStats(for: $0).foodSurplus }
        case "⚙️": return sorted(list, o) { s.computeStats(for: $0).total.production }
        case "💰": return sorted(list, o) { s.computeStats(for: $0).total.gold }
        case "🔬": return sorted(list, o) { s.computeStats(for: $0).total.science }
        case "🎭": return sorted(list, o) { s.computeStats(for: $0).total.culture }
        case "🕊": return sorted(list, o) { s.computeStats(for: $0).total.faith }
        case "🎉": return sorted(list, o) { $0.wltkdTurns > 0 ? 1 : 0 }
        case "🛡": return sortedByName(list, o) { garrison(s, $0)?.name ?? "" }
        case "🏰": return sorted(list, o) { s.cityStrength($0) }
        case "😊": return sorted(list, o) { s.happinessBreakdown($0.civId, onlyCity: $0.id).total }
        case "🏗": return sorted(list, o) { Double(s.turnsToComplete($0) ?? 999) }
        case L("Religion"): return sortedByName(list, o) { s.majorityReligion(of: $0) ?? "" }
        default: return list   // SortDirection.None: `data.asSequence()`, the civ's own city list
        }
    }
    /// Unciv MapUnit.getVisibleTilesInDistance(3).firstOrNull { it.isCityCenter() }: the Closest city cell and its sort key
    private func closestCity(_ s: GameState, _ u: Unit, _ visible: Set<HexCoord>) -> City? {
        s.map.tilesWithin(u.coord, radius: 3).first { visible.contains($0) && s.city(at: $0) != nil }.flatMap { s.city(at: $0) }
    }
    private func sortedUnits(_ s: GameState, _ me: Civilization) -> [Unit] {
        let list = s.units(of: me.id)
        let o = unitSort
        let visible = s.visibleTiles(for: me.id)
        switch o.column {
        // Unciv UnitOverviewTabColumn.Name: displayName(), translated
        case L("Name"): return sortedByName(list, o, emptyLast: true) { L(s.uncivDisplayName($0)) }
        case L("Action"): return sortedByName(list, o, emptyLast: true) { actionText(s, $0).map { L($0) } ?? "" }
        case "⚔": return sorted(list, o) { Double($0.def.strength) }
        case "🏹": return sorted(list, o) { Double($0.def.rangedStrength) }
        case "👟": return sorted(list, o) { s.maxMovement(of: $0) * 100 + $0.movementLeft }
        case L("Closest city"): return sortedByName(list, o, emptyLast: true) { closestCity(s, $0, visible)?.name ?? "" }
        // Unciv Promotions.getEntryValue: (canBePromoted() ? 10000 : 0) + promotions.size
        case L("Promotions"): return sorted(list, o) { Double((canBePromoted(s, $0) ? 10000 : 0) + $0.promotions.count) }
        case L("Upgrade"): return sortedByName(list, o, emptyLast: true) { UnitUpgradeMenuView.upgradeTargets(s, $0).first.map { L($0.name) } ?? "" }
        case L("Health"): return sorted(list, o) { Double($0.health) }
        case L("XP"): return sorted(list, o) { Double($0.xpForNextPromotion) * 1_000_000 + Double($0.currentXP) }
        // SortDirection.None: `data.asSequence()` over getCivUnits() - the civ's unit list, as "Next unit" rotates it
        default: return list
        }
    }
    /// Unciv UnitPromotions.canBePromoted: a promotion to take - one the XP pays for, or a free one
    private func canBePromoted(_ s: GameState, _ u: Unit) -> Bool { !s.availablePromotions(for: u).isEmpty }
    /// Unciv UnitOverviewTabColumn totals: how many units, how many can upgrade, how many are hurt, total XP.
    @ViewBuilder
    private func unitTotals(_ s: GameState, _ me: Civilization, _ cols: [(String, CGFloat)]) -> some View {
        let list = s.units(of: me.id)
        let cells = ["\(L("Total")) \(list.count)", "", "", "", "", "", "",
                     "",
                     "\(list.filter { !UnitUpgradeMenuView.upgradeTargets(s, $0).isEmpty }.count)",
                     "\(list.filter { $0.health < 100 }.count)",
                     "\(list.reduce(0) { $0 + $1.currentXP })"]
        HStack(spacing: 4) {
            ForEach(Array(zip(cells, cols).enumerated()), id: \.offset) { _, cell in
                Text(cell.0).font(Theme.small.bold()).foregroundStyle(Theme.gold).lineLimit(1).frame(width: cell.1.1, alignment: .leading)
            }
        }
    }

    private func units(_ s: GameState, _ me: Civilization) -> some View {
        Panel(padding: 8) {
            VStack(alignment: .leading, spacing: 4) {
                // Unciv UnitOverviewTabColumn: Name, Action, Strength, Ranged, Movement, Closest city, Promotions, Upgrade, Health, XP
                let cols: [(String, CGFloat)] = [(L("Name"), 110), ("✏️", 26), (L("Action"), 70), ("⚔", 34), ("🏹", 34), ("👟", 44), (L("Closest city"), 90), (L("Promotions"), 84), (L("Upgrade"), 90), (L("Health"), 50), (L("XP"), 56)]
                let w = cols.map { $0.1 }
                let visible = s.visibleTiles(for: me.id)
                // Unciv UnitOverviewTabHelpers: `viewingPlayer.isCurrentPlayer() && GUI.isAllowedChangeState()`
                let canEnable = controller.isMyTurn && !me.isSpectator
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        gridHeader(cols, $unitSort)
                        ForEach(sortedUnits(s, me)) { u in
                            let closest = closestCity(s, u, visible)
                            let promotable = canBePromoted(s, u)
                            HStack(spacing: 4) {
                                // Unciv UnitOverviewTabColumn.Name: the unit's displayName() - "name ([unit])", its religion too;
                                // showWorldScreenAt(unit): resetToWorldScreen, setCenterPosition(its tile, forceSelectUnit = unit)
                                Button { close(); controller.setCenterPosition(u.coord, forceSelectUnit: u.id); controller.refresh(full: false) } label: { Text(L(s.uncivDisplayName(u))).font(Theme.small).lineLimit(1).foregroundStyle(highlightUnit == u.id ? Theme.gold : Theme.cream).frame(width: w[0], alignment: .leading) }.buttonStyle(.plain)
                                // Unciv EditName: UnitRenamePopup over the overview for this row's unit; OK updates the
                                // grid and selects the row - the map's selection is not touched
                                Button { renameUnitId = u.id } label: {
                                    Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(Theme.gold).frame(width: w[1], alignment: .leading)
                                }.buttonStyle(.plain)
                                Text(actionText(s, u).map { L($0) } ?? "").font(Theme.small).lineLimit(1).frame(width: w[2], alignment: .leading)
                                Text(u.def.strength > 0 ? trNum(u.def.strength) : "").font(Theme.small).frame(width: w[3], alignment: .leading)
                                Text(u.def.rangedStrength > 0 ? trNum(u.def.rangedStrength) : "").font(Theme.small).frame(width: w[4], alignment: .leading)
                                Text(L(UnitPanel.movementString(s, u)))   // Movement column: getMovementString().toLabel()
                                    .font(Theme.small).frame(width: w[5], alignment: .leading)
                                // Unciv ClosestCity: showWorldScreenAt(closestCityTile) - setCenterPosition with selectUnit
                                Button { if let cc = closest { close(); controller.setCenterPosition(cc.coord); controller.refresh(full: false) } } label: { Text(closest?.name ?? "").font(Theme.small).lineLimit(1).foregroundStyle(closest?.coord == u.coord ? Theme.good : Theme.cream).frame(width: w[6], alignment: .leading) }.buttonStyle(.plain)
                                // Unciv getPromotionsTable: the star while canBePromoted(), dimmed unless the unit could take it now;
                                // a click opens the picker to promote (canEnable) or at least to look at the promotions it has
                                // game.pushScreen { PromotionPickerScreen(unit) { update(); select(Units, key) } }: the picker for
                                // this row's unit, back here when it closes - on the row when a promotion or a name was taken
                                Button { if (canEnable && promotable) || !u.promotions.isEmpty {
                                    let id = u.id, before = (u.promotions, u.customName)
                                    push("promotions") { controller.state.unit(id).map { $0.promotions != before.0 || $0.customName != before.1 } == true ? "\(id)" : "" }
                                    controller.promotionUnitId = id; close(); controller.afterSheetDismiss { controller.showPromotions = true }
                                } } label: {
                                    HStack(spacing: 0) {
                                        Text(u.promotions.isEmpty ? "" : "\(u.promotions.count)")
                                        if promotable { Text(" ★").opacity(canEnable && u.hasMovement && u.attacksThisTurn == 0 ? 1 : 0.75) }
                                    }.font(Theme.small).frame(width: w[7], alignment: .leading)
                                }.buttonStyle(.plain)
                                // Unciv UnitOverviewTabHelpers.getUpgradeTable: one icon per upgrade this unit could
                                // take (getUpgradeActionAnywhere, so units abroad show it too), green when it can be
                                // done right now and dimmed when not. Clicking opens the UnitUpgradeMenu - cost,
                                // what changes and a confirm button - it never spends gold by itself.
                                HStack(spacing: 3) {
                                    ForEach(UnitUpgradeMenuView.upgradeTargets(s, u)) { target in
                                        Button { upgradeMenuUnit = u.id } label: {
                                            HStack(spacing: 2) {
                                                ArtIcon(name: target.name, folder: "Units", fallback: "arrow.up.circle.fill", size: 16)
                                                Text(L(target.name)).font(Theme.small).lineLimit(1)
                                            }.foregroundStyle(UnitUpgradeMenuView.canPerform(s, u, to: target) ? Theme.good : Theme.good.opacity(0.5))
                                        }.buttonStyle(.plain)
                                    }
                                }.frame(width: w[8], alignment: .leading)
                                Text(u.health < 100 ? "\(u.health)" : "").font(Theme.small).frame(width: w[9], alignment: .leading)
                                Text(u.isMilitary ? "\(u.currentXP)/\(u.xpForNextPromotion)" : "").font(Theme.small).lineLimit(1).frame(width: w[10], alignment: .leading)
                            }
                        }
                        unitTotals(s, me, cols)
                    }
                }
                Divider2()
                // Unciv UnitSupplyTable
                let myCities = s.cities(of: me.id)
                let baseSupply = s.difficulty.unitSupplyBase + Int(s.civUniques(me.id).filter { $0.pattern == "[] Unit Supply" }.reduce(0.0) { $0 + $1.double(0) })
                let citySupply = s.difficulty.unitSupplyPerCity * myCities.count + Int(s.civUniques(me.id).filter { $0.pattern == "[] Unit Supply per city" }.reduce(0.0) { $0 + $1.double(0) } * Double(myCities.count))
                let popSupply = Int(Double(myCities.reduce(0) { $0 + $1.population }) * s.rs.constants.unitSupplyPerPopulation)
                let deficit = s.unitSupplyDeficit(me.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Unit Supply") + (deficit > 0 ? " ❗" : "")).font(Theme.heading(14)).foregroundStyle(deficit > 0 ? Theme.danger : Theme.gold)
                    supplyRow(L("Base Supply"), "\(baseSupply)"); supplyRow(L("Cities"), "\(citySupply)"); supplyRow(L("Population"), "\(popSupply)")
                    Divider2()
                    supplyRow(L("Total Supply"), "\(s.unitSupply(me.id))"); supplyRow(L("In Use"), "\(s.units(of: me.id).count)")
                    Divider2()
                    supplyRow(L("Supply Deficit"), "\(deficit)"); supplyRow(L("Production Penalty"), "\(Int(s.unitSupplyProductionPenalty(me.id)))%")
                    if deficit > 0 { Text(L("Increase your supply or reduce the amount of units to remove the production penalty")).font(Theme.small).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
    }
    private func supplyRow(_ label: String, _ value: String) -> some View { HStack { Text(label).font(Theme.small); Spacer(); Text(value).font(Theme.small.bold()) } }
    /// Unciv UnitOverviewTabHelpers.getActionText, untranslated: what the unit's `action` says, nil (an empty cell) when it
    /// has none and is not working an improvement. Our order stands for Unciv's action string (GameInfoSerialization.unitJSON):
    /// nothing, a build order and automation leave `action` null, Connect road is an automated "Connect road", and a
    /// set-up siege unit's action is "Set up" whatever it was before.
    private func actionText(_ s: GameState, _ u: Unit) -> String? {
        // getWorkerActionText: the improvement in progress on its tile, while it has movement and could build it
        let workerText: String? = {
            guard u.hasMovement, let t = s.map[u.coord], let imp = t.improvementInProgress, s.unitCanBuildImprovement(u, imp, t) else { return nil }
            return imp
        }()
        if u.isSetUp { return "Set up" }
        switch u.order {
        case .none, .build, .automate: return workerText                 // `action == null -> workerText`
        case .fortify, .fortifyUntilHealed: return "Fortify"             // isFortified(): action.startsWith("Fortify")
        case .guardPost: return "Guard"                                  // isGuarding()
        case .moveTo: return "Moving"                                    // isMoving(): action.startsWith("moveTo")
        case .connectRoad: return workerText.map { "[\($0)] ⛏" } ?? "Connect road"   // isAutomated() && workerText != null: "[$workerText] ${Fonts.automate}"
        case .sleep: return "Sleep"
        case .sleepUntilHealed: return "Sleep until healed"
        case .explore: return "Explore"
        }
    }

    /// Unciv ResourcesOverviewTab: the per-origin breakdown of where a resource's supply comes from.
    @ViewBuilder
    private func resourceOrigins(_ s: GameState, _ me: Civilization, _ resource: String) -> some View {
        let entries = s.detailedCivResources(me.id).filter { $0.resource == resource && $0.amount != 0 }
        let byOrigin = Dictionary(grouping: entries, by: { $0.origin }).mapValues { $0.reduce(0) { $0 + $1.amount } }
        ForEach(byOrigin.keys.sorted(), id: \.self) { origin in
            HStack {
                Text("  " + L(origin)).font(Theme.small).foregroundStyle(Theme.creamDim)
                Spacer()
                Text(L("\(byOrigin[origin] ?? 0)")).font(Theme.small).foregroundStyle((byOrigin[origin] ?? 0) < 0 ? .red : Theme.creamDim)
            }
        }
    }

    /// Unciv Tile.countAsUnimproved: a resource the civ can see, not a bonus one, that the tile does not provide
    private func countAsUnimproved(_ s: GameState, _ me: Civilization, _ t: Tile) -> Bool {
        guard let r = t.resource, let def = s.rs.resources[r], s.canSeeResource(r, civId: me.id), def.resourceType != "Bonus" else { return false }
        return !s.tileProvidesResources(t, civ: me)
    }

    /// Unciv ResourcesOverviewTab, laid out as its vertical variant: a row per civ-wide, non-bonus resource shown on the
    /// world screen (by type, then translated name) - its image (tap: where it lies), its name (tap: Civilopedia; red in
    /// deficit), the amount per origin, the total, then Unimproved (tap: those tiles), WLTK+, WLTK-, Trade offer and
    /// Stockpile when any resource has one.
    private func resources(_ s: GameState, _ me: Civilization) -> some View {
        let drill = s.detailedCivResources(me.id)
        var extra: [(resource: String, origin: String, amount: Int)] = []
        func add(_ r: String, _ o: String, _ n: Int) {
            if let i = extra.firstIndex(where: { $0.resource == r && $0.origin == o }) { extra[i].amount += n } else { extra.append((r, o, n)) }
        }
        func addUnimproved(_ c: City) { for t in c.tiles.compactMap({ s.map[$0] }) where countAsUnimproved(s, me, t) { add(t.resource!, "Unimproved", 1) } }
        for c in s.cities(of: me.id) {
            if !c.demandedResource.isEmpty { add(c.demandedResource, c.isCelebrating ? "CelebratingWLTK" : "DemandingWLTK", 1) }
            addUnimproved(c)
        }
        for o in s.civs where me.metCivs.contains(o.id) {
            // Unciv: the resources the requests we sent would bring us (the trade's theirOffers)
            for off in s.pendingOffers where off.from == me.id && off.to == o.id && !off.isFriendshipRequest { for r in off.want.resources where s.rs.resources[r] != nil { add(r, "TradeOffer", 1) } }
            if o.isCityState && s.ally(of: o.id) == me.id { for c in s.cities(of: o.id) { addUnimproved(c) } }
        }
        for r in s.rs.resources.values where r.resourceType == "Strategic" && s.canSeeResource(r.name, civId: me.id) { add(r.name, "No source", 0) }
        for name in me.resourceStockpiles.keys.sorted() {
            guard let r = s.rs.resources[name], !r.uniques.contains("Not shown on world screen") else { continue }
            add(name, "Stockpile", me.resourceStockpiles[name] ?? 0)
        }
        let typeOrder = ["Luxury", "Strategic", "Bonus"]
        var names: [String] = []
        for n in drill.map(\.resource) + extra.map(\.resource) where !names.contains(n) { names.append(n) }
        let resources = names.compactMap { s.rs.resources[$0] }
            .filter { $0.resourceType != "Bonus" && !$0.uniques.contains("Not shown on world screen") && !$0.isCityWide }
            .sorted { a, b in
                let ta = typeOrder.firstIndex(of: a.resourceType) ?? 3, tb = typeOrder.firstIndex(of: b.resourceType) ?? 3
                return ta != tb ? ta < tb : LocaleCode.compare(L(a.name), L(b.name)) == .orderedAscending
            }
        var origins: [String] = []
        for o in drill.map(\.origin) where !origins.contains(o) { origins.append(o) }
        var grouped: [(key: String, members: [String])] = []
        for o in origins {
            let k = o.hasSuffix("+") ? String(o.dropLast()) : o
            if let i = grouped.firstIndex(where: { $0.key == k }) { grouped[i].members.append(o) } else { grouped.append((k, [o])) }
        }
        let extraCaptions = ["Unimproved": "Unimproved", "CelebratingWLTK": "WLTK+", "DemandingWLTK": "WLTK-", "TradeOffer": "Trade offer", "Stockpile": "Stockpile"]
        let extraTips = ["Unimproved": "Number of tiles with this resource\nin your territory, without an\nappropriate improvement to use it",
                         "CelebratingWLTK": "Number of your cities celebrating\n'We Love The King Day' thanks\nto access to this resource",
                         "DemandingWLTK": "Number of your cities\ndemanding this resource for\n'We Love The King Day'",
                         "TradeOffer": "Resources we're offering in trades", "Stockpile": "The currently accumulated stockpile amount"]
        var extraOrigins: [String] = []
        for o in extra.map(\.origin) where extraCaptions[o] != nil && !extraOrigins.contains(o) { extraOrigins.append(o) }
        func amount(_ r: String, _ o: String) -> Int? { drill.contains { $0.resource == r && $0.origin == o } ? drill.filter { $0.resource == r && $0.origin == o }.reduce(0) { $0 + $1.amount } : nil }
        func extraAmount(_ r: String, _ o: String) -> Int? { extra.first { $0.resource == r && $0.origin == o }?.amount }
        func total(_ r: String) -> Int { drill.filter { $0.resource == r }.reduce(0) { $0 + $1.amount } }
        /// Unciv ResourcesOverviewTab.isDeficit
        func deficit(_ r: ResourceDef, _ o: String, _ n: Int) -> Bool {
            if r.isStockpiled && o != "Stockpile" { return n < -(extraAmount(r.name, "Stockpile") ?? 0) }
            if o != "Total" { return n < 0 && total(r.name) < 0 }
            if n != 0 { return n < 0 }
            return (extraAmount(r.name, "DemandingWLTK") ?? 0) > 0
        }
        func label(_ r: ResourceDef, _ o: String, _ n: Int) -> some View {
            Text((r.isStockpiled && n >= 0 && o != "Stockpile" ? "+" : "") + "\(n)").font(Theme.caption).foregroundStyle(deficit(r, o, n) ? Color.red : Theme.cream)
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .center, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1); Color.clear.frame(width: 1, height: 1)
                    ForEach(grouped, id: \.key) { g in Text(L(g.key)).font(Theme.caption.bold()) }
                    Text(L("Total")).font(Theme.caption.bold())
                    ForEach(extraOrigins, id: \.self) { o in
                        Text(L(extraCaptions[o]!)).font(Theme.caption.bold()).help(L(extraTips[o]!))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(resources, id: \.name) { r in
                    GridRow {
                        Button {
                            if let n = s.exploredResourcesNotification(me.id, resource: r.name) { close(); controller.showOneTimeNotification(n, inList: false) }
                        } label: { ArtIcon(name: r.name, folder: "ResourceIcons", fallback: "leaf.fill", size: 36) }.buttonStyle(.plain)
                        Button { push("civilopedia"); close(); controller.civilopediaEntry = "Resource/\(r.name)"; controller.showCivilopedia = true } label: {
                            Text(L(r.name)).font(Theme.caption).foregroundStyle(deficit(r, "Total", total(r.name)) ? Color.red : Theme.cream)
                        }.buttonStyle(.plain).gridColumnAlignment(.leading)
                        ForEach(grouped, id: \.key) { g in
                            HStack(spacing: 10) { ForEach(g.members, id: \.self) { o in if let n = amount(r.name, o) { label(r, o, n) } } }
                        }
                        label(r, "Total", total(r.name))
                        ForEach(extraOrigins, id: \.self) { o in
                            if let n = extraAmount(r.name, o) {
                                if o == "Unimproved" {
                                    Button {
                                        if let item = s.exploredResourcesNotification(me.id, resource: r.name, filter: { t in
                                            guard let owner = t.ownerCivId, owner == me.id || (s.civ(owner)?.isCityState == true && s.ally(of: owner) == me.id) else { return false }
                                            return countAsUnimproved(s, me, t)
                                        }) { close(); controller.showOneTimeNotification(item, inList: false) }
                                    } label: { label(r, o, n) }.buttonStyle(.plain)
                                } else { label(r, o, n) }
                            } else { Color.clear.frame(width: 1, height: 1) }
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    /// Unciv WonderOverviewTab / WonderInfo.collectInfo: the world wonders the player may see (shouldBeDisplayed: not hidden
    /// from this game's Civilopedia, era up to its own - none without an era hidden) and every wonder some city has built,
    /// by era then translated name under a line in the era's colour, then the map's natural wonders by translated name.
    /// Columns: image (Civilopedia), name, status (Owned, the owner's name when merely known, Not found, Not built,
    /// Unknown) and location (a tap centres the map).
    private func wonders(_ s: GameState, _ me: Civilization) -> some View {
        func eraOf(_ w: BuildingDef) -> Int? { w.requiredTech.flatMap { s.rs.techs[$0]?.era }.map { s.rs.eraIndex($0) } }
        let myEra = s.rs.eraIndex(me.eraName)
        // collectInfo: only the pre-populated entries are Hidden; the loop over the cities' built wonders overwrites a
        // Hidden entry with Owned / Known / NotFound, so a built wonder is listed whatever its era or the settings
        let builtNames = Set(s.cities.flatMap { $0.buildings })
        let all = s.rs.buildings.values.filter { w in
            w.isWonder && (builtNames.contains(w.name)
                || (!ObjectDescriptions.hiddenFromCivilopedia(building: w, s: s, rs: s.rs) && (eraOf(w).map { $0 <= myEra } ?? true)))
        }
            .sorted { a, b in
                let ea = eraOf(a) ?? 100, eb = eraOf(b) ?? 100
                return ea != eb ? ea < eb : LocaleCode.compare(L(a.name), L(b.name)) == .orderedAscending
            }
        let placed = Dictionary(s.map.tiles.compactMap { t in t.naturalWonder.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
        let naturalWonders = placed.keys.sorted { LocaleCode.compare(L($0), L($1)) == .orderedAscending }
        return Grid(alignment: .center, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow { Color.clear.frame(width: 1, height: 1); Text(L("Name")); Text(L("Status")); Text(L("Location")) }.font(Theme.caption.bold())
            ForEach(all) { w in
                let era = eraOf(w)
                let groupName = era.map { s.rs.eras[min($0, s.rs.eras.count - 1)].name } ?? "Other"
                if all.first(where: { eraOf($0) == era })?.name == w.name {
                    let color = era.map { eraColor(s, $0) } ?? Color.white
                    HStack(spacing: 4) { Rectangle().fill(color).frame(height: 2); Text(L(groupName)).font(Theme.caption).foregroundStyle(color) }.gridCellColumns(4)
                }
                // collectInfo walks gameInfo.getCities() (civ by civ) and the last city with the wonder writes the entry
                let owner = s.civs.flatMap { s.cities(of: $0.id) }.last { $0.buildings.contains(w.name) }
                let status: String = {
                    guard let o = owner else { return L("Not built") }
                    if o.civId == me.id { return L("Owned") }
                    if me.explored.contains(o.coord) { return L(s.civ(o.civId)?.nation ?? "") }
                    return L("Not found")
                }()
                GridRow {
                    Button { push("civilopedia"); close(); controller.civilopediaEntry = "Wonder/\(w.name)"; controller.showCivilopedia = true } label: {
                        ArtIcon(name: w.name, folder: "BuildingIcons", fallback: "building.columns.fill", size: 36)
                    }.buttonStyle(.plain)
                    Text(L(w.name)).font(Theme.caption)
                    Text(status).font(Theme.caption)
                    if let o = owner, o.civId == me.id || me.explored.contains(o.coord) {
                        // Unciv WonderOverviewTab: resetToWorldScreen, setCenterPosition(wonder.location.position)
                        Button { close(); controller.setCenterPosition(o.coord); controller.refresh(full: false) } label: { Text(L(o.name)).font(Theme.caption) }.buttonStyle(.plain)
                    } else { Color.clear.frame(width: 1, height: 1) }
                }
            }
            if !naturalWonders.isEmpty {
                let forest = Color(red: 0.13, green: 0.55, blue: 0.13)
                HStack(spacing: 4) { Rectangle().fill(forest).frame(height: 2); Text(L("Natural Wonders")).font(Theme.caption).foregroundStyle(forest) }.gridCellColumns(4)
                ForEach(naturalWonders, id: \.self) { name in
                    let t = placed[name]!
                    let owned = t.ownerCivId == me.id
                    let seen = me.seenNaturalWonders.contains(name)
                    // Unciv: a natural wonder not found stays "Unknown" unless a quest names it
                    let fromQuest = s.civs.contains { cs in cs.quests.contains { $0.name == "Find Natural Wonder" && $0.target == name && ($0.assigneeId == nil || $0.assigneeId == me.id) && $0.completedBy == nil } }
                    let unknown = !owned && !seen && !fromQuest
                    GridRow {
                        if unknown { Color.clear.frame(width: 1, height: 1) } else {
                            Button { push("civilopedia"); close(); controller.civilopediaEntry = "Terrain/\(name)"; controller.showCivilopedia = true } label: {
                                ArtIcon(name: name, folder: "Tiles", fallback: "mountain.2.fill", size: 40)
                            }.buttonStyle(.plain)
                        }
                        Text(unknown ? L("Unknown") : L(name)).font(Theme.caption)
                        Text(unknown ? L("Unknown") : owned ? L("Owned") : seen ? (t.ownerCivId.flatMap { s.civ($0)?.nation }.map { L($0) } ?? L("Known")) : L("Not found")).font(Theme.caption)
                        if owned || seen {
                            Button { close(); controller.setCenterPosition(t.coord); controller.refresh(full: false) } label: { Text(naturalWonderLocation(t, s, me)).font(Theme.caption) }.buttonStyle(.plain)
                        } else { Color.clear.frame(width: 1, height: 1) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Unciv Era.getColor: the era's iconRGB
    private func eraColor(_ s: GameState, _ era: Int) -> Color {
        guard s.rs.eras.indices.contains(era), let rgb = s.rs.eras[era].iconRGB, rgb.count >= 3 else { return .white }
        return Color(red: Double(rgb[0]) / 255, green: Double(rgb[1]) / 255, blue: Double(rgb[2]) / 255)
    }

    /// Unciv WonderInfo.getLocationColumn: the city on the tile, the city that owns it, otherwise the
    /// nearest city within five tiles that we know of and have seen - and failing all of that, far away.
    private func naturalWonderLocation(_ t: Tile, _ s: GameState, _ me: Civilization) -> String {
        if let c = s.city(at: t.coord) { return L(c.name) }   // getLocationColumn().toLabel()
        if let owner = s.cities.first(where: { $0.tiles.contains(t.coord) }) { return L("Near [\(owner.name)]") }
        let near = s.cities
            .filter { $0.coord.distance(to: t.coord) <= 5 && me.metCivs.contains($0.civId) && me.explored.contains($0.coord) }
            .min { $0.coord.distance(to: t.coord) < $1.coord.distance(to: t.coord) }
        return near.map { L("Somewhere around [\($0.name)]") } ?? L("Far away")
    }

    /// Unciv TradesOverviewTab: "Pending trades" - the requests we sent, our side first - then "Current trades", each
    /// trade as two columns of offers in the civs' colours. Both walk `viewingPlayer.diplomacy.values`, a HashMap by
    /// civ name (diplomacyOrder); the current ones are then stable-sorted by the longest duration among the ourOffers of
    /// each civ's first trade, so a tie keeps that HashMap order.
    private func deals(_ s: GameState, _ me: Civilization) -> some View {
        let diploOrder = s.diplomacyOrder(me.id)
        // `diplomacy.otherCiv.tradeRequests.filter { it.requestingCiv == civID }`, diplomacy by diplomacy
        let pendingAll = s.pendingOffers.filter { $0.from == me.id && !$0.isFriendshipRequest }   // tradeRequests only
        let pending = diploOrder.flatMap { cid in pendingAll.filter { $0.to == cid } }
        let trades = s.currentTrades(me)
        // `if (offers.isEmpty()) 0 else offers.maxByOrNull { it.duration }!!.duration`
        func key(_ id: Int) -> Int { trades[id]?.first?.ours.map { $0.duration }.max() ?? 0 }
        let civOrder: [Int] = diploOrder.filter { !(trades[$0] ?? []).isEmpty }
        let indexed: [(offset: Int, element: Int)] = Array(civOrder.enumerated()).map { ($0.offset, $0.element) }
        let sortedCivs: [Int] = indexed.sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map { $0.element }
        return VStack(spacing: 14) {
            if !pending.isEmpty {
                Text(L("Pending trades")).font(Theme.heading(18)).padding(.top, 6)
                ForEach(pending) { o in
                    // Unciv createOffersTable: one row per offer, its getOfferText (a turns line stays with its offer)
                    let give = s.offerTexts(o.give, tail: o.evTailGive)
                    let want = s.offerTexts(o.want, tail: o.evTailWant)
                    tradeTable(s, me, s.civ(o.to), ours: give, theirs: want)
                }
            }
            if !sortedCivs.isEmpty {
                Text(L("Current trades")).font(Theme.heading(18)).padding(.top, 6)
                ForEach(sortedCivs, id: \.self) { cid in
                    ForEach(Array((trades[cid] ?? []).enumerated()), id: \.offset) { _, t in
                        tradeTable(s, me, s.civ(cid), ours: t.ours.map(\.text), theirs: t.theirs.map(\.text))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Unciv createTradeTable: our offers beside theirs, each on the civ's outer colour with its portrait and name in the
    /// inner colour, the shorter side padded with empty lines
    private func tradeTable(_ s: GameState, _ me: Civilization, _ other: Civilization?, ours: [String], theirs: [String]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            offersColumn(me, ours, pad: max(0, theirs.count - ours.count))
            if let other { offersColumn(other, theirs, pad: max(0, ours.count - theirs.count)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 560)
    }

    private func offersColumn(_ civ: Civilization, _ offers: [String], pad: Int) -> some View {
        let outer = Color(uiColor: UIColor(rgb: civ.nationDef?.outerColor ?? [60, 60, 60]))
        let inner = Color(uiColor: UIColor(rgb: civ.nationDef?.innerColor ?? [230, 230, 230]))
        return VStack(spacing: 8) {
            HStack(spacing: 5) { NationBadge(nation: civ.nationDef, size: 30); Text(L(civ.nation)).font(Theme.caption.bold()).foregroundStyle(inner) }
            Rectangle().fill(inner.opacity(0.5)).frame(height: 1)
            ForEach(Array(offers.enumerated()), id: \.offset) { _, t in Text(t.contains("\n") ? t : t + "\n").font(Theme.caption).foregroundStyle(inner).multilineTextAlignment(.center) }
            ForEach(0..<pad, id: \.self) { _ in Text("\n").font(Theme.caption) }
        }
        .padding(10).frame(maxWidth: .infinity).background(outer)
    }


    /// Unciv GlobalPoliticsOverviewTable: the table (portrait, civ info, social policies, wonders, relations) or the diagram
    @ViewBuilder
    private func politics(_ s: GameState, _ me: Civilization) -> some View {
        if controller.overviewShowDiagram { politicsDiagram(s, me) } else { politicsTable(s, me) }
    }

    /// Unciv DiplomacyFunctions.getKnownCivsSorted: known, not barbarian or spectator, defeated ones only when asked;
    /// majors first, then by translated name
    private func knownCivsSorted(_ s: GameState, _ me: Civilization, cityStates: Bool, defeated: Bool = false) -> [Civilization] {
        s.civs.filter { $0.id != me.id && me.metCivs.contains($0.id) && !$0.isBarbarian && !$0.isSpectator && (defeated || $0.isAlive) && (cityStates || !$0.isCityState) }
            .sorted { a, b in a.isMajor != b.isMajor ? a.isMajor : LocaleCode.compare(L(a.nation), L(b.nation)) == .orderedAscending }
    }

    /// Unciv getCivName: the name of a civ we know, or "an unknown civilization"
    private func civName(_ s: GameState, _ me: Civilization, _ c: Civilization) -> String {
        c.id == me.id || me.metCivs.contains(c.id) ? L(c.nation) : L("an unknown civilization")
    }

    private func politicsTable(_ s: GameState, _ me: Civilization) -> some View {
        let civs = (me.isSpectator ? [] : [me]) + knownCivsSorted(s, me, cityStates: false)
        return Grid(alignment: .top, horizontalSpacing: 16, verticalSpacing: 14) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Text(L("Civilization Info")); Text(L("Social policies")); Text(L("Wonders"))
                VStack(spacing: 6) {
                    Text(L("Relations"))
                    Button(L("Show diagram")) { controller.overviewShowDiagram = true; overviewRevision += 1 }.buttonStyle(ThemedButtonStyle(compact: true))
                }
            }.font(Theme.caption.bold())
            ForEach(civs) { c in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    NationBadge(nation: c.nationDef, size: 64)
                    // Unciv getCivInfoTable: leader, civ, era
                    VStack(spacing: 3) {
                        Text(L(c.nationDef?.leaderName ?? "")).font(Theme.heading(18))
                        Text(L(c.nation)).font(Theme.caption)
                        Text(L(c.eraName)).font(Theme.caption)
                    }
                    // Unciv getPoliciesTable: "[branch]: adopted count" for each adopted branch
                    VStack(spacing: 3) {
                        ForEach(s.rs.policyBranches.filter { c.openBranches.contains($0.name) }, id: \.name) { br in
                            Text(L("[\(br.name)]: \(1 + br.policies.filter { c.policies.contains($0.name) && !$0.isBranchCompletion }.count)")).font(Theme.caption)
                        }
                    }
                    wondersOfCiv(s, me, c)
                    relationsOfCiv(s, me, c)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Unciv getWondersOfCivTable: the built wonders and owned natural wonders of the civ, each tappable while its tile is visible
    private func wondersOfCiv(_ s: GameState, _ me: Civilization, _ c: Civilization) -> some View {
        let visible = s.visibleTiles(for: me.id)
        let built: [(String, HexCoord)] = s.cities(of: c.id).flatMap { city in city.buildings.filter { s.rs.buildings[$0]?.isWonder == true }.map { ($0, city.coord) } }
            .sorted { LocaleCode.compare(L($0.0), L($1.0)) == .orderedAscending }
        let natural: [(String, HexCoord)] = s.map.tiles.filter { $0.naturalWonder != nil && $0.ownerCivId == c.id }.map { ($0.naturalWonder!, $0.coord) }
            .filter { n in c.id == me.id || me.seenNaturalWonders.contains(n.0) }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array((built + natural).enumerated()), id: \.offset) { _, w in
                if visible.contains(w.1) {
                    // resetToWorldScreen, setCenterPosition(wonder.location.position)
                    Button { close(); controller.setCenterPosition(w.1); controller.refresh(full: false) } label: { Text(L(w.0)).font(Theme.caption) }.buttonStyle(.plain)
                } else { Text(L(w.0)).font(Theme.caption) }
            }
        }
    }

    /// Unciv getPoliticsOfCivTable: nothing for a civ we do not know; "Defeated"; wars in red, defensive pacts in cyan or
    /// friendships in green with their turns, denunciations in red with their turns, allied city-states in cyan
    private func relationsOfCiv(_ s: GameState, _ me: Civilization, _ c: Civilization) -> some View {
        let known = c.id == me.id || me.metCivs.contains(c.id)
        // Unciv civ.getKnownCivs(): its diplomacy HashMap's order, the defeated and spectators left out
        let theirs = s.knownCivs(c.id).filter { $0.id != c.id && !$0.isSpectator }
        return VStack(alignment: .leading, spacing: 3) {
            if known {
                if !c.isAlive { Text(L("Defeated") + " ☠").font(Theme.caption) } else {
                    ForEach(theirs.filter { c.isAtWar(with: $0.id) }) { o in Text(L("At war with [\(civName(s, me, o))]")).font(Theme.caption).foregroundStyle(Color.red) }
                    ForEach(theirs) { o in
                        if c.defensivePacts.contains(o.id) {
                            Text(L("Defensive pact with [\(civName(s, me, o))]") + " (\(s.flag(c.id, o.id, "DefensivePact"))⏳)").font(Theme.caption).foregroundStyle(Color.cyan)
                        } else if s.hasFlag(c.id, o.id, "DeclarationOfFriendship") {
                            Text(L("Friends with [\(civName(s, me, o))]") + " (\(s.flag(c.id, o.id, "DeclarationOfFriendship"))⏳)").font(Theme.caption).foregroundStyle(Color.green)
                        }
                    }
                    ForEach(theirs.filter { s.hasFlag(c.id, $0.id, "Denunciation") }) { o in
                        Text(L("Denounced [\(civName(s, me, o))]") + " (\(s.flag(c.id, o.id, "Denunciation"))⏳)").font(Theme.caption).foregroundStyle(Color.red)
                    }
                    ForEach(s.civs.filter { $0.isCityState && $0.isAlive && s.ally(of: $0.id) == c.id }) { cs in
                        Text(L("Allied with [\(civName(s, me, cs))]")).font(Theme.caption).foregroundStyle(Color.cyan)
                    }
                }
            }
        }
    }

    /// Unciv GlobalPoliticsDiagramGroup: the undefeated civs on a circle and a line per pair that know each other, coloured
    /// by the relation (war red, defensive pact purple, else the relationship level); tapping a portrait toggles it, tapping
    /// the diagram opens the legend whose boxes toggle the relations. Beside it: the civ list with scores.
    private func politicsDiagram(_ s: GameState, _ me: Civilization) -> some View {
        let withCS = controller.overviewDiagramCityStates
        let undefeated = (me.isSpectator ? [] : [me]) + knownCivsSorted(s, me, cityStates: withCS)
        let defeated = knownCivsSorted(s, me, cityStates: withCS, defeated: true).filter { !$0.isAlive }
        // Unciv updateDiagram: `shouldHideCivCount() || includeCityStates && hideCityStateCount()`
        let hideCount = s.shouldHideCivCount(me) || (withCS && s.hideCityStateCount(me))
        let relevantCount = hideCount ? "?" : "\(s.civs.filter { !$0.isSpectator && !$0.isBarbarian && (withCS || !$0.isCityState) }.count)"
        return VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button(L("City-States")) { controller.overviewDiagramCityStates.toggle(); overviewRevision += 1 }
                    .buttonStyle(ThemedButtonStyle(filled: !withCS, destructive: withCS, compact: true))
                Button(L("Show global politics")) { controller.overviewShowDiagram = false; overviewRevision += 1 }.buttonStyle(ThemedButtonStyle(compact: true))
            }
            if undefeated.contains(where: { $0.id != me.id }) {
                PoliticsDiagram(state: s, civs: undefeated).frame(width: 300, height: 300)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("[\(relevantCount)] Civilizations in the game")).font(Theme.caption).frame(maxWidth: .infinity)
                if !me.isSpectator {
                    Text(L("Our Civilization:")).font(Theme.caption)
                    HStack { civMini(s, me, me); Spacer(); Text(me.isAlive ? trNum(s.score(me)) : "☠").font(Theme.caption) }
                }
                if let turns = s.turnsTillNextDiplomaticVote(me.id) { Text(L("Turns until the next\ndiplomacy victory vote: [\(turns)]")).font(Theme.caption) }
                ForEach([("alive", undefeated.filter { $0.id != me.id }), ("defeated", defeated)], id: \.0) { cat in
                    Divider()
                    Text(L("Known and \(cat.0) ([\(cat.1.count)])")).font(Theme.caption).frame(maxWidth: .infinity)
                    ForEach(cat.1) { c in
                        HStack { civMini(s, me, c); Spacer(); if c.isMajor { Text(trNum(s.score(c))).font(Theme.caption) } }
                    }
                }
            }
            .padding(10).frame(maxWidth: 360)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.2)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white, lineWidth: 2))
        }
        .frame(maxWidth: .infinity)
    }

    /// Unciv getCivMiniTable: portrait and name; a tap opens diplomacy with a living civ other than ours
    private func civMini(_ s: GameState, _ me: Civilization, _ c: Civilization) -> some View {
        Button {
            guard c.isAlive, !me.isSpectator, c.id != me.id else { return }
            push("diplomacy"); close(); controller.afterSheetDismiss { controller.diplomacyCiv = c.id; controller.showDiplomacy = true }
        } label: { HStack(spacing: 5) { NationBadge(nation: c.nationDef, size: 25); Text(L(c.nation)).font(Theme.caption) } }.buttonStyle(.plain)
    }

    private func legend(_ color: Color, _ text: String) -> some View { HStack(spacing: 3) { Rectangle().fill(color).frame(width: 14, height: 3); Text(text).font(Theme.small).foregroundStyle(Theme.creamDim) } }

    /// Unciv ReligionOverviewTab: the civ's religious numbers (religions still to be found behind a closed expander, the faith
    /// for the next prophet, the religious status), one button per existing religion or pantheon, and the selected one's
    /// name, founder, holy city, followers and beliefs.
    private func religion(_ s: GameState, _ me: Civilization) -> some View {
        // Unciv gameInfo.civilizations.mapNotNull { religionManager.religion }: a pantheon is its belief's religion
        let existing: [(key: String, civ: Civilization)] = s.civs.compactMap { c in (c.religionName ?? c.pantheonBelief).map { ($0, c) } }
        let selected = existing.first { $0.key == selectedReligion }
        return VStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Expander(s.shouldHideCivCount(me) ? L("Religions to be founded: [?]") : L("Religions to be founded: [\(s.remainingFoundableReligions())]"), open: $religionCountOpen, compact: true) {
                    ForEach(Array(s.remainingFoundableReligionsBreakdown().enumerated()), id: \.offset) { _, row in
                        HStack { Text(L(row.0)).font(Theme.caption); Spacer(); Text(trNum(row.1)).font(Theme.caption) }
                    }
                }
                if s.canGenerateProphetIgnoringFaith(me), let prophet = s.greatProphetEquivalent(me.id) {
                    HStack(alignment: .top) { Text(L("Minimal Faith required for\nthe next [\(prophet.name)]:")).font(Theme.caption); Spacer(); Text(trNum(Int(s.prophetCost(me)) + 1)).font(Theme.caption) }
                }
                HStack { Text(L("Religious status:")).font(Theme.caption); Spacer(); Text(L(s.religionStateText(me))).font(Theme.caption) }
            }
            .frame(maxWidth: 420)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(existing, id: \.key) { r in
                        let isSel = selectedReligion == r.key
                        Button { selectedReligion = r.key } label: {
                            Group {
                                if r.civ.religionName == nil {
                                    // Unciv: a pantheon shows its founder's nation, a random one while the founder is unknown
                                    let known = r.civ.id == me.id || me.metCivs.contains(r.civ.id)
                                    NationBadge(nation: known ? r.civ.nationDef : s.rs.nations.values.sorted { $0.name < $1.name }.randomElement(), size: 50)
                                } else {
                                    ReligionPortrait(name: r.key, size: 50)
                                }
                            }
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 10).fill(isSel ? Theme.gold.opacity(0.2) : Theme.fill))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSel ? Theme.gold : Theme.hairline, lineWidth: isSel ? 1.5 : 1))
                        }.buttonStyle(.plain).disabled(isSel)
                    }
                }.padding(.horizontal, 4)
            }
            if let r = selected {
                Text(L(r.civ.religionDisplayName ?? r.key)).font(Theme.heading(18)).foregroundStyle(Color(red: 1, green: 0.5, blue: 0.31))   // Color.CORAL
            } else {
                Text(L("Click an icon to see the stats of this religion")).font(Theme.caption)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let r = selected {
                let founderKnown = r.civ.id == me.id || me.metCivs.contains(r.civ.id)
                let isMajor = r.civ.religionName != nil
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(L(isMajor ? "Religion Name:" : "Pantheon Name:")); Spacer(); Text(L(r.civ.religionDisplayName ?? r.key)) }
                    HStack { Text(L("Founding Civ:")); Spacer(); Text(founderKnown ? L(r.civ.nation) : "???") }
                    if isMajor, let holy = s.cities.first(where: { $0.isHolyCity && $0.holyCityOf == r.key }) {
                        HStack { Text(L("Holy City:")); Spacer(); Text(me.explored.contains(holy.coord) ? holy.name : "???") }
                    }
                    // Unciv numberOfCitiesFollowingThisReligion / numberOfFollowersFollowingThisReligion("in all cities")
                    HStack { Text(L("Cities following this religion:")); Spacer(); Text(trNum(s.citiesFollowing(r.key).count)) }
                    HStack { Text(L("Followers of this religion:")); Spacer(); Text(trNum(s.cities.reduce(0) { $0 + (s.followers(of: $1)[r.key] ?? 0) })) }
                }
                .font(Theme.caption).frame(maxWidth: 420)
                // Unciv createBeliefDescription: each belief's Civilopedia text with its header
                VStack(spacing: 14) {
                    ForEach(religionBeliefsOrdered(s, r.civ), id: \.self) { b in
                        if let def = s.rs.beliefs[b] {
                            BeliefDescription(controller: controller, belief: def, onOpenCivilopedia: { push("civilopedia"); close() })
                                .frame(maxWidth: 420)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Unciv StatsOverviewTab: Happiness / Unhappiness / Gold / Science / Culture / Faith tables from the stat map, then Great people and Score.
    private func stats(_ s: GameState, _ me: Civilization) -> some View {
        let h = s.happinessBreakdown(me.id)
        let statMap = s.statMapForNextTurn(me.id)
        let gpPerTurn = s.greatPersonPointsPerTurn(me.id)
        // Unciv calculateScoreBreakdown: a hashMapOf, so the rows and `values.sum()` walk its bucket order
        let score = s.scoreBreakdown(me)
        let scoreRows: [(String, Double)] = javaHashMapOrder(score.map { $0.0 }).map { k in (k, score.first { $0.0 == k }?.1 ?? 0) }
        let scoreTotal = scoreRows.reduce(0.0) { $0 + $1.1 }
        func statTable(_ title: String, _ icon: String, _ value: @escaping (Stats) -> Double) -> some View {
            // Unciv updateStatTable: every source goes into the Float total; addLabeledValue only leaves out the rows
            // whose roundToInt() is 0, and addTotal shows total.roundToInt()
            let rows = statMap.filter { Self.roundToInt(value($0.1)) != 0 }
            let total = statMap.reduce(Float(0)) { $0 + Float(value($1.1)) }
            return Panel(padding: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(L(title)) \(icon)").font(Theme.heading(14)).foregroundStyle(Theme.gold)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in HStack { Text(L(r.0)).font(Theme.small); Spacer(); Text(trNum(Self.roundToInt(value(r.1)))).font(Theme.small) } }
                    Divider2()
                    HStack { Text(L("Total")).font(Theme.small.bold()); Spacer(); Text(trNum(Self.roundToInt(Double(total)))).font(Theme.small.bold()) }
                }
            }
        }
        /// Unciv addLabeledValue: `value.roundToInt()`, nothing when that is 0
        func labeled(_ label: String, _ v: Double) -> some View { Group { if Self.roundToInt(v) != 0 { HStack { Text(L(label)).font(Theme.small); Spacer(); Text(trNum(Self.roundToInt(v))).font(Theme.small) } } } }
        let columns = [GridItem(.adaptive(minimum: 220), alignment: .top)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            Panel(padding: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Happiness")).font(Theme.heading(14)).foregroundStyle(Theme.gold)
                    // Unciv getHappinessBreakdown is a HashMap<String, Float>: its rows come in bucket order, and the
                    // total is `values.sum()` over every key (HappinessBreakdown.total)
                    ForEach(javaHashMapOrder(h.keys), id: \.self) { k in labeled(k, h[k]) }
                    Divider2()
                    HStack { Text(L("Total")).font(Theme.small.bold()); Spacer(); Text(trNum(Self.roundToInt(h.total))).font(Theme.small.bold()) }
                }
            }
            let unhappinessRules = Array(Set(s.civUniques(me.id).filter { u in
                isPlayerFacing(u.text) && u.conditionals.contains { c in
                    (c.pattern.hasPrefix("when between [] and [] []") || c.pattern.hasPrefix("when below [] []") || c.pattern.hasPrefix("when above [] []"))
                        && c.params.last == "Happiness"
                }
            }.map { $0.text })).sorted()
            if !unhappinessRules.isEmpty {
            Panel(padding: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    // Unciv StatsOverviewTab.UnhappinessTable: the rules that change with the happiness level.
                    Text(L("Unhappiness")).font(Theme.heading(14)).foregroundStyle(Theme.gold)
                    ForEach(unhappinessRules, id: \.self) { t in Text(L(t)).font(Theme.small).foregroundStyle(Theme.creamDim) }
                }
            }
            }
            statTable("Gold", "💰") { $0.gold }
            // Unciv StatsOverviewTab.addGoldSlider (ModOptions "Can convert gold to science with sliders")
            if s.rs.modOptionUniques.contains(where: { $0.pattern == "Can convert gold to science with sliders" }) {
                Panel(padding: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Convert gold to science")).font(Theme.heading(14)).foregroundStyle(Theme.gold)
                        Slider(value: Binding(get: { controller.state.civ(me.id)?.goldPercentConvertedToScience ?? 0.6 },
                                              set: { v in if !controller.isProcessing, let i = controller.state.civIndex(me.id) { controller.state.civs[i].goldPercentConvertedToScience = v; controller.state.invalidateHappiness(me.id); controller.refresh() } }),
                               in: 0...1, step: 0.1).tint(Theme.gold).disabled(controller.isProcessing)
                        Text(trNum(Int((controller.state.civ(me.id)?.goldPercentConvertedToScience ?? 0.6) * 100 + 0.5)) + "%").font(Theme.small)
                    }
                }
            }
            statTable("Science", "🔬") { $0.science }
            statTable("Culture", "🎵") { $0.culture }
            if s.religionEnabled { statTable("Faith", "🕊") { $0.faith } }
            Panel(padding: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Great person points")).font(Theme.heading(14)).foregroundStyle(Theme.gold)
                    // Unciv updateGreatPeopleTable: a row per greatPersonPointsCounter entry (a Counter: points not zero) with
                    // "$points/$pointsToGreatPerson" through tr() and its points per turn (Int.toLabel), then a row per
                    // greatGeneralPointsCounter entry with "$points/$pointsToGreatGeneral" (200 until the first one is born: getNewGreatPerson writes Unciv's 200 each turn, this
                    // port reads it as the default).
                    // The rows come in the Counters' (LinkedHashMap) first-insertion order: greatPersonOrder / greatGeneralOrder,
                    // which GreatPersonManager keeps as the points are added (an entry going back to zero leaves it), any key
                    // missing from it last by name.
                    HStack { Text("").frame(width: 90, alignment: .leading); Text(L("Current points")).font(Theme.small.bold()).frame(maxWidth: .infinity); Text(L("Points per turn")).font(Theme.small.bold()).frame(maxWidth: .infinity) }
                    ForEach(Self.counterOrder(me.greatPersonOrder, me.greatPersonPoints.filter { Int($0.value) != 0 }.keys), id: \.self) { gp in
                        HStack {
                            Text(L(gp)).font(Theme.small).frame(width: 90, alignment: .leading).lineLimit(1)
                            Text(L("\(Int(me.greatPersonPoints[gp] ?? 0))/\(Int(s.greatPersonThreshold(me, for: gp)))")).font(Theme.small).frame(maxWidth: .infinity)
                            Text(trNum(Int((gpPerTurn[gp] ?? 0).rounded()))).font(Theme.small).frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(Self.counterOrder(me.greatGeneralOrder, me.greatGeneralPoints.filter { $0.value != 0 }.keys), id: \.self) { gg in
                        HStack {
                            Text(L(gg)).font(Theme.small).frame(width: 90, alignment: .leading).lineLimit(1)
                            Text(L("\(me.greatGeneralPoints[gg] ?? 0)/\(me.pointsForNextGreatGeneralCounter[gg] ?? 200)")).font(Theme.small).frame(maxWidth: .infinity)
                            Text("").frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            Panel(padding: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Score")).font(Theme.heading(14)).foregroundStyle(Theme.gold)
                    // Unciv updateScoreTable: addLabeledValue(label, value.toFloat()) per row, then
                    // addTotal(values.sum().toFloat()) - rounded here, where the politics table and rankings truncate
                    ForEach(Array(scoreRows.enumerated()), id: \.offset) { _, r in labeled(r.0, Stats.f32(r.1)) }
                    Divider2()
                    HStack { Text(L("Total")).font(Theme.small.bold()); Spacer(); Text(trNum(Self.roundToInt(Stats.f32(scoreTotal)))).font(Theme.small.bold()) }
                }
            }
        }
    }

    /// Unciv NotificationsOverviewTable: one expander per turn - this turn first, then the log newest first - with the
    /// entries grouped by category under a centred category line. This turn's entries that arrived after the turn began
    /// are tinted eggshell, those new since the tab was last seen bisque. A tap shows the entry once more on the map
    /// (showOneTimeNotification); the turn menu opens only the chosen turn.
    private func notifications(_ s: GameState, _ me: Civilization) -> some View {
        let current = me.notificationItems
        let h1 = me.notificationCountAtStartTurn ?? current.count
        let h2 = controller.overviewNotificationsLastCount.flatMap { $0.turn == s.turn ? $0.count : nil } ?? h1
        let turns: [(turn: Int, items: [NotificationItem], highlight: Bool)] =
            (current.isEmpty ? [] : [(s.turn, current, true)]) + me.notificationLog.reversed().map { ($0.turn, $0.items, false) }
        return ScrollViewReader { proxy in
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Menu {
                        ForEach(turns, id: \.turn) { t in
                            Button(t.turn == s.turn ? L("Current turn") : turnLabel(s, t.turn)) {
                                controller.overviewClosedTurns = Set(turns.map(\.turn)).subtracting([t.turn]); notifRevision += 1
                                withAnimation { proxy.scrollTo("turn\(t.turn)", anchor: .top) }
                            }
                        }
                    } label: { HStack(spacing: 4) { Text(L("Current turn")); Image(systemName: "chevron.down") }.font(Theme.caption) }
                }
                ForEach(turns, id: \.turn) { t in
                    let open = (t.highlight && h2 < current.count) || !controller.overviewClosedTurns.contains(t.turn)
                    VStack(spacing: 6) {
                        Button {
                            if open { controller.overviewClosedTurns.insert(t.turn) } else { controller.overviewClosedTurns.remove(t.turn) }
                            notifRevision += 1
                        } label: {
                            HStack { Spacer(); Text((t.turn == s.turn ? L("Current turn") + " | " : "") + turnLabel(s, t.turn)).font(Theme.heading(15)); Spacer(); Image(systemName: open ? "chevron.up" : "chevron.down") }
                                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill))
                        }.buttonStyle(.plain)
                        if open {
                            ForEach(NotificationCategory.allCases, id: \.self) { cat in
                                let items = t.items.filter { $0.meta.category == cat }
                                if !items.isEmpty {
                                    if cat != .General {
                                        HStack(spacing: 6) { Rectangle().fill(Theme.cream).frame(width: 90, height: 2); Text(L(cat.rawValue)).font(Theme.caption); Rectangle().fill(Theme.cream).frame(width: 90, height: 2) }
                                    }
                                    ForEach(items) { item in
                                        let tint: Color? = !t.highlight ? nil : item.index >= h2 ? Color(red: 0xf5 / 255, green: 0xc9 / 255, blue: 0x93 / 255) : item.index >= h1 ? Color(red: 0xf0 / 255, green: 0xea / 255, blue: 0xd6 / 255) : nil
                                        HStack(spacing: 4) {
                                            Text(L(item.text)).font(Theme.caption).foregroundStyle(Color(white: 0.2)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                            ForEach(Array(item.meta.icons.reversed().enumerated()), id: \.offset) { _, ic in
                                                let parts = notificationIconPath(ic, s.rs).split(separator: "/", maxSplits: 1).map(String.init)
                                                ArtIcon(name: parts.count == 2 ? parts[1] : ic, folder: parts.count == 2 ? parts[0] : "OtherIcons", fallback: "circle", size: 20)
                                            }
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: 420)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(tint ?? Color(white: 0.92)))
                                        .contentShape(Rectangle())
                                        .onTapGesture { if !item.meta.actions.isEmpty { close(); controller.showOneTimeNotification(item, inList: t.turn == s.turn) } }
                                    }
                                }
                            }
                        }
                    }
                    .id("turn\(t.turn)")
                }
            }
            .frame(maxWidth: .infinity)
            .id(notifRevision)
            .onDisappear { controller.overviewNotificationsLastCount = (s.turn, current.count) }
        }
    }

    /// A Counter's keys in its first-insertion order (`order`), keys the order lacks after them by name
    static func counterOrder(_ order: [String], _ keys: Dictionary<String, Int>.Keys) -> [String] { counterOrder(order, Array(keys)) }
    static func counterOrder(_ order: [String], _ keys: Dictionary<String, Double>.Keys) -> [String] { counterOrder(order, Array(keys)) }
    static func counterOrder(_ order: [String], _ keys: [String]) -> [String] {
        let present = Set(keys)
        var out: [String] = []
        for k in order where present.contains(k) && !out.contains(k) { out.append(k) }
        return out + keys.filter { !out.contains($0) }.sorted()
    }

    /// Unciv getTurnLabel: "⏳ turn | year", the turn as NotificationsLog stamps it - gameInfo.turns, zero-based. Our log
    /// and `s.turn` share one counter, so the entry's offset from this turn lands on uncivTurns (as the top bar shows it).
    private func turnLabel(_ s: GameState, _ turn: Int) -> String {
        let y = s.speed.year(forTurn: turn + s.startTurnOffset)
        let year = GameState.yearText(year: y, usesMayaCalendar: s.isLongCountDisplay(s.playerId))
        return "⏳ " + Translations.shared.numberTr(s.uncivTurns + (turn - s.turn)) + " | " + year
    }
}

/// Unciv GlobalPoliticsDiagramGroup
struct PoliticsDiagram: View {
    let state: GameState
    let civs: [Civilization]
    @State private var selectedCivs: Set<Int>? = nil
    @State private var selectedRelations: Set<String>? = nil
    @State private var showLegend = false
    /// Unciv Relation: War, the relationship levels, Defensive Pact - with their colours and z-order
    static let relations: [(key: String, label: String, color: Color, z: Int)] = [
        ("War", "War", .red, 100),
        ("unforgivable", "Unforgivable", DiplomacyScreen.levelColor(.unforgivable), 7), ("enemy", "Enemy", DiplomacyScreen.levelColor(.enemy), 5),
        ("afraid", "Afraid", DiplomacyScreen.levelColor(.afraid), 4), ("competitor", "Competitor", DiplomacyScreen.levelColor(.competitor), 2),
        ("neutral", "Neutral", DiplomacyScreen.levelColor(.neutral), 0), ("favorable", "Favorable", DiplomacyScreen.levelColor(.favorable), 1),
        ("friend", "Friend", DiplomacyScreen.levelColor(.friend), 3), ("ally", "Ally", DiplomacyScreen.levelColor(.ally), 6),
        ("DefensivePact", "Defensive Pact", .purple, 99)]
    /// Unciv DiplomacyManager.getRelation, from `a` towards `b`
    private func relation(_ a: Civilization, _ b: Civilization) -> String {
        let s = state
        if a.isAtWar(with: b.id) { return "War" }
        if a.defensivePacts.contains(b.id) && !a.isCityState && !b.isCityState { return "DefensivePact" }
        if a.isPlayer && b.isPlayer && s.hasFlag(a.id, b.id, "DeclarationOfFriendship") { return "friend" }
        if (a.isCityState && s.ally(of: a.id) == b.id) || (b.isCityState && s.ally(of: b.id) == a.id) { return "ally" }
        return String(describing: s.relationshipLevel(a.id, b.id))
    }
    /// One line per pair that knows each other, from the later civ towards the earlier, sorted by z-order
    private func diagramLines(_ pos: [Int: CGPoint]) -> [(from: CGPoint, to: CGPoint, rel: String, z: Int, a: Int, b: Int)] {
        var lines: [(from: CGPoint, to: CGPoint, rel: String, z: Int, a: Int, b: Int)] = []
        for (fi, c) in civs.enumerated() where c.isAlive {
            for ti in 0..<fi {
                let o = civs[ti]
                guard o.isAlive, c.metCivs.contains(o.id), let p1 = pos[c.id], let p2 = pos[o.id] else { continue }
                let r = relation(c, o)
                lines.append((p1, p2, r, Self.relations.first { $0.key == r }?.z ?? 0, c.id, o.id))
            }
        }
        return lines.sorted { $0.z < $1.z }
    }
    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: size / 2, y: size / 2)
            let pos: [Int: CGPoint] = Dictionary(uniqueKeysWithValues: civs.enumerated().map { i, c in
                let a = 2 * Double.pi * Double(i) / Double(civs.count)
                return (c.id, CGPoint(x: center.x + CGFloat(sin(a)) * size / 2.25 * 0.85, y: center.y - CGFloat(cos(a)) * size / 2.25 * 0.85))
            })
            let selCivs = selectedCivs ?? Set(civs.map(\.id)), selRel = selectedRelations ?? Set(Self.relations.map(\.key))
            let lines = diagramLines(pos)
            let hasLines = Set(lines.flatMap { [$0.a, $0.b] })
            ZStack {
                Circle().fill(Color.clear).contentShape(Circle()).onTapGesture { showLegend = true }
                Canvas { ctx, _ in
                    for l in lines where selRel.contains(l.rel) && selCivs.contains(l.a) && selCivs.contains(l.b) {
                        var p = Path(); p.move(to: l.from); p.addLine(to: l.to)
                        ctx.stroke(p, with: .color(Self.relations.first { $0.key == l.rel }?.color ?? .white), lineWidth: 2)
                    }
                }.allowsHitTesting(false)
                ForEach(civs) { c in
                    NationBadge(nation: c.nationDef, size: 30)
                        .padding(6).background(Circle().fill(Color.white.opacity(selCivs.contains(c.id) ? 0.5 : 0)))
                        .opacity(selCivs.contains(c.id) ? 1 : 0.5)
                        .position(pos[c.id] ?? center)
                        .onTapGesture {
                            guard hasLines.contains(c.id) else { return }   // dead or isolated civs do not react
                            var sel = selCivs
                            if sel.contains(c.id) { sel.remove(c.id) } else { sel.insert(c.id) }
                            if sel.count < 2 { sel = Set(civs.map(\.id)) }
                            selectedCivs = sel
                        }
                }
            }
            .frame(width: size, height: size)
            .overlay {
                if showLegend {
                    // Unciv DiagramLegendPopup: "Diagram line colors" with a checkbox per relation
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Diagram line colors")).font(Theme.heading(15)).frame(maxWidth: .infinity)
                        ForEach(Self.relations, id: \.key) { r in
                            Button {
                                var sel = selRel
                                if sel.contains(r.key) { sel.remove(r.key) } else { sel.insert(r.key) }
                                if sel.isEmpty { sel = Set(Self.relations.map(\.key)) }
                                selectedRelations = sel
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: selRel.contains(r.key) ? "checkmark.square.fill" : "square")
                                    Rectangle().fill(r.color).frame(width: 60, height: 3)
                                    Text(L(r.label)).font(Theme.caption)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelDark))
                    .overlay(alignment: .topTrailing) { Button { showLegend = false } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).padding(6) }
                }
            }
        }
    }
}
