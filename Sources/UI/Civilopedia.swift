// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv FormattedLine: one line of civilopedia text, which may point at another entry - the line then
/// shows that entry's icon in front of it and opens its page when tapped.
struct PediaLine {
    /// The text as shown (already translated).
    let text: String
    /// Unciv FormattedLine.link: "Category/Name", a bare "Category", or an external URL. Nil for a plain line.
    let link: String?
    /// Unciv FormattedLine.extraImage: a picture line from the json (drawn by Unciv, not here).
    var extraImage: String? = nil
    init(_ text: String, link: String? = nil) { self.text = text; self.link = link }
}

/// Unciv CivilopediaScreen.CivilopediaEntry: one button of the entry list - its name, where its icon comes from,
/// ICivilopediaText.getSortGroup and ICivilopediaText.getSubCategory.
struct PediaEntry {
    let name: String
    let sortBy: Int
    let subCategory: String?
    /// Unciv CivilopediaCategories.getImage for this entry: (image name, art folder), nil for none.
    let icon: (name: String, folder: String)?
}

/// Unciv CivilopediaScreen.categoryToEntries: one category with the entries it displays.
struct PediaCategory {
    let name: String
    /// Unciv getCategoryIterator order, already filtered by shouldBeDisplayed - what the search walks.
    let entries: [PediaEntry]
    /// Unciv CivilopediaScreen.selectCategory: sortBy first, then the translated name with the locale's collator.
    let sorted: [PediaEntry]
}

/// Unciv CivilopediaScreen: category buttons on top, the selected category's entries on the left and the
/// selected entry's text on the right.
struct CivilopediaScreen: View {
    let rs: Ruleset
    let onClose: () -> Void
    private let openSearchOnAppear: Bool
    /// Unciv CivilopediaCategories.fromLink: a link names the category either by its enum name or by
    /// the label shown on the button.
    static func categoryForLink(_ name: String) -> String? {
        let byEnumName = ["Building": "Buildings", "Wonder": "Wonders", "Resource": "Resources",
                          "Terrain": "Terrains", "Improvement": "Tile Improvements", "Unit": "Units",
                          "UnitType": "Unit types", "Nation": "Nations", "Technology": "Technologies",
                          "Promotion": "Promotions", "Policy": "Policies", "Belief": "Religions and Beliefs",
                          "UnitNameGroup": "Unit Names", "Tutorial": "Tutorials", "Victory": "Victory Types",
                          "Difficulty": "Difficulty levels", "Era": "Eras", "Speed": "Speeds",
                          "Personality": "Personalities"]
        if let mapped = byEnumName[name] { return mapped }
        return allCategories.contains(name) ? name : nil
    }

    /// Unciv CivilopediaScreen(link): the entry to open on, written "Category/Name" (or a bare entry name,
    /// which is then looked up in the default category).
    private let openLink: String?
    /// The game in progress, if there is one (Unciv UncivGame.getGameInfoOrNull) - Unciv hides differently with and
    /// without a game, and the pages read it the same way.
    private let state: GameState?
    /// The settings of the game in progress, if there is one.
    private var settings: GameSettings? { state?.settings }
    /// Unciv showReligionInCivilopedia: in a game GameInfo.isReligionEnabled (the starting era's "Starting in this era
    /// disables religion", the ModOptions' "Disable religion" - a Vanilla game has none), outside one the ruleset's beliefs.
    var religionShown: Bool { state?.religionEnabled ?? !rs.beliefs.isEmpty }
    /// Unciv CivilopediaScreen: a category religion has switched off is never built, so it cannot be reached.
    private var shownCategories: [String] { Self.allCategories.filter { $0 != "Religions and Beliefs" || religionShown } }
    /// Unciv CivilopediaScreen: an object hidden by the ruleset, or by this game's own settings - IHasUniques
    /// isUnavailableBySettings, whose game-based conditionals include the speed and the difficulty.
    private func hidden(_ uniques: [String]) -> Bool {
        isHiddenFromCivilopedia(uniques) || (state?.isUnavailableBySettings(uniques.map(Unique.init)) ?? false)
    }
    init(controller: GameController) { self.state = controller.state; self.rs = controller.state.rs; self.onClose = { controller.showCivilopedia = false }; self.openLink = controller.civilopediaEntry; self.openSearchOnAppear = controller.civilopediaSearch; controller.civilopediaSearch = false }
    init(ruleset: Ruleset, onClose: @escaping () -> Void) { self.state = nil; self.rs = ruleset; self.onClose = onClose; self.openSearchOnAppear = false; self.openLink = nil }

    /// Unciv CivilopediaCategories, in its own order (which is the order of the buttons on top).
    static let allCategories = ["Buildings", "Wonders", "Resources", "Terrains", "Tile Improvements", "Units", "Unit types", "Nations", "Personalities", "Technologies", "Promotions", "Policies", "Religions and Beliefs", "Tutorials", "Victory Types", "Unit Names", "Difficulty levels", "Eras", "Speeds"]
    /// Unciv CivilopediaCategories.headerIcon: the icon on each category button.
    private static let headerIcons: [String: (name: String, folder: String)] = [
        "Buildings": ("Cities", "OtherIcons"), "Wonders": ("Wonders", "OtherIcons"), "Resources": ("Resources", "OtherIcons"),
        "Terrains": ("Terrains", "OtherIcons"), "Tile Improvements": ("Improvements", "OtherIcons"), "Units": ("Shield", "OtherIcons"),
        "Unit types": ("UnitTypes", "UnitTypeIcons"), "Nations": ("Nations", "OtherIcons"), "Personalities": ("Personality", "OtherIcons"),
        "Technologies": ("Philosophy", "TechIcons"), "Promotions": ("Mobility", "PromotionIcons"), "Policies": ("Constitution", "PolicyIcons"),
        "Religions and Beliefs": ("Religion", "ReligionIcons"), "Tutorials": ("ExclamationMark", "OtherIcons"), "Victory Types": ("Score", "OtherIcons"),
        "Unit Names": ("UnitNameGroups", "OtherIcons"), "Difficulty levels": ("Quickstart", "OtherIcons"), "Eras": ("Tyrannosaurus", "OtherIcons"),
        "Speeds": ("Timer", "OtherIcons"),
    ]
    /// Unciv UnitMovementType, in its declared order (UnitType.getCivilopediaIterator adds one "Domain: [X]" entry per value).
    private static let domains = ["Land", "Water", "Air"]

    /// Unciv CivilopediaScreen.lastCategory / lastEntryName (companion object): where the pedia was left, kept
    /// for as long as the app runs so a plain re-open resumes there.
    private nonisolated(unsafe) static var lastCategory: String? = nil
    private nonisolated(unsafe) static var lastEntryName: String? = nil

    /// Unciv CivilopediaScreen.categoryToEntries, built once when the screen opens.
    @State private var pedia: [PediaCategory] = []
    /// Unciv CivilopediaScreen.currentCategory / currentEntry / currentEntryPerCategory.
    @State private var currentCategory: String? = nil
    @State private var currentEntry = ""
    @State private var entryPerCategory: [String: String] = [:]
    /// Asks the entry list to bring an entry into view (Unciv selectEntry sets entrySelectScroll.scrollY).
    @State private var listScroll: ListScroll? = nil
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var searchResults: [SearchHit]? = nil
    @State private var resultsExpanded = true
    @State private var searchToast: String? = nil   // Unciv CivilopediaSearchPopup ToastPopup
    @FocusState private var searchFocused: Bool

    private struct ListScroll: Equatable { let name: String; let token: Int }
    /// Unciv CivilopediaSearchPopup.addResult: a found entry, opened through its link.
    private struct SearchHit: Identifiable { let category: String; let name: String; var id: String { category + "/" + name } }
    /// Unciv CivilopediaScreen.selectCategory: a SubCategoryTable header or an entry button.
    private enum ListRow: Identifiable {
        case header(String, Int)
        case entry(PediaEntry)
        var id: String { switch self { case .header(let s, let i): return "§\(i)§" + s; case .entry(let e): return e.name } }
    }

    /// Unciv CivilopediaScreen init: only categories with entries get a button.
    private var buttonCategories: [String] { pedia.filter { !$0.sorted.isEmpty }.map(\.name) }
    private var currentSorted: [PediaEntry] { pedia.first { $0.name == currentCategory }?.sorted ?? [] }

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(Theme.hairline).frame(height: 1)
                // Unciv CivilopediaScreen: entrySplitPane.splitAmount = 0.3 - the list takes 30% of the width.
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        entryList.frame(width: max(170, geo.size.width * 0.3))
                        Rectangle().fill(Theme.hairline).frame(width: 1)
                        detailPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background { shortcutButtons }
        .foregroundStyle(Theme.cream)
        .presentationBackground(Theme.bg)
        .presentationDragIndicator(.visible)
        .overlay { if showSearch { searchPopup } }
        .onAppear { setUp() }
        .screenShown("pedia")
        .onAppear { GameEvents.post(.pediaOpened) }
    }

    // MARK: Unciv CivilopediaScreen layout

    /// Unciv CivilopediaScreen topTable: the scrolling category buttons, the search button and the close button.
    private var topBar: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(buttonCategories, id: \.self) { c in
                            Button { selectCategory(c) } label: {
                                HStack(spacing: 5) {
                                    if let icon = Self.headerIcons[c] { art(icon.name, icon.folder, 16) }
                                    Text(L(c))
                                }
                            }
                            .buttonStyle(ThemedButtonStyle(filled: currentCategory == c, compact: true))
                            .id(c)
                        }
                    }.padding(.horizontal, 18)
                }
                // the row scrolls (Unciv buttonTableScroll); its ends fade so a button at the edge reads as scrolled off,
                // not as a label cut short
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.025),
                                             .init(color: .black, location: 0.975), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                // Unciv selectCategory: buttonTableScroll.scrollX centres the selected category's button.
                .onChange(of: currentCategory) { _, c in
                    guard let c else { return }
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo(c, anchor: .center) } }
                }
            }
            // Unciv CivilopediaScreen search button opens CivilopediaSearchPopup.
            Button { openSearch() } label: { Image(systemName: "magnifyingglass") }.buttonStyle(ThemedButtonStyle(compact: true))
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.cream)
                    .frame(width: 34, height: 34).background(Circle().fill(Theme.fill)).overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
            }
            .keyboardShortcut(showSearch ? nil : KeyboardShortcut(.escape, modifiers: []))   // Unciv getCloseButton: `keyShortcuts.add(KeyCharAndCode.BACK)` - the search popup's Close takes it while open
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
    }

    /// Unciv CivilopediaScreen.selectCategory: the entry buttons, with a SubCategoryTable header wherever
    /// getSubCategory changes to a non-null value.
    private var listRows: [ListRow] {
        var rows: [ListRow] = []
        var current: String? = nil
        for e in currentSorted {
            if current != e.subCategory {
                if let s = e.subCategory { rows.append(.header(s, rows.count)) }
                current = e.subCategory
            }
            rows.append(.entry(e))
        }
        return rows
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(listRows) { row in
                        switch row {
                        case .header(let s, _): subCategoryHeader(s)
                        case .entry(let e): entryButton(e)
                        }
                    }
                }.padding(8)
            }
            .id(currentCategory ?? "")
            // Unciv selectEntry: entrySelectScroll.scrollY centres the selected entry's button.
            .onChange(of: listScroll) { _, req in
                guard let req else { return }
                DispatchQueue.main.async { proxy.scrollTo(req.name, anchor: .center) }
            }
        }
    }

    /// Unciv SubCategoryTable: the sub-category's name flanked by two lines.
    private func subCategoryHeader(_ name: String) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(Theme.goldDim.opacity(0.7)).frame(minWidth: 6, maxWidth: .infinity).frame(height: 1)
            Text(L(name)).font(Theme.heading(13)).foregroundStyle(Theme.gold).fixedSize()
            Rectangle().fill(Theme.goldDim.opacity(0.7)).frame(minWidth: 6, maxWidth: .infinity).frame(height: 1)
        }.padding(.top, 8).padding(.bottom, 2)
    }

    /// Unciv CivilopediaScreen entryButton: the entry's icon and name; the selected one is tinted.
    private func entryButton(_ e: PediaEntry) -> some View {
        let selected = e.name == currentEntry
        return Button { selectEntry(e.name, scroll: false) } label: {
            HStack(spacing: 8) {
                entryIcon(e, size: 26)
                Text(L(e.name)).font(Theme.font(14)).foregroundStyle(selected ? Theme.gold : Theme.cream)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.R.row, style: .continuous).fill(selected ? Theme.gold.opacity(0.16) : Theme.fill))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.row, style: .continuous).stroke(selected ? Theme.gold.opacity(0.7) : Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(e.name)
    }

    /// Unciv CivilopediaScreen.selectEntry: the flavourTable shows the entry's assembled civilopedia text -
    /// the header (name with icon), a separator, then its lines.
    private var detailPane: some View {
        ScrollView {
            if let c = currentCategory, let e = currentSorted.first(where: { $0.name == currentEntry }) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        entryIcon(e, size: 36)
                        Text(L(e.name)).font(Theme.heading(20)).foregroundStyle(Theme.gold).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider2().padding(.vertical, 4)
                    // Unciv BaseUnitDescriptions: "Size of Unitset art in Civilopedia" puts the unit's art on top, centred.
                    if c == "Units", UserSettings.civilopediaUnitArtSize > 0 {
                        HStack { Spacer(); ArtIcon(name: e.name, folder: "Units", fallback: "person", size: CGFloat(UserSettings.civilopediaUnitArtSize)); Spacer() }
                    }
                    ForEach(Array(lines(c, e.name).enumerated()), id: \.offset) { _, l in lineView(l, own: e.name) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id((currentCategory ?? "") + "/" + currentEntry)
    }

    /// Unciv CivilopediaScreen: the category and entry keys, disabled while the search popup is open
    /// (a Popup vetoes the screen's shortcuts).
    private var shortcutButtons: some View {
        ZStack {
            ForEach(buttonCategories.filter { Self.hasBinding("Pedia: \($0)") }, id: \.self) { c in
                let spec = KeyBindings.spec("Pedia: \(c)")
                if let key = spec.equivalent { Button("") { selectCategory(c) }.keyboardShortcut(key, modifiers: spec.mods) }
            }
            let search = KeyBindings.spec("Open the Search Dialog")   // Unciv KeyboardBinding.PediaSearch
            if let key = search.equivalent { Button("") { openSearch() }.keyboardShortcut(key, modifiers: search.mods) }
            // Unciv CivilopediaScreen globalShortcuts: arrows, page up/down, home and end.
            Button("") { navigateCategories(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { navigateCategories(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { navigateEntries(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { navigateEntries(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { navigateEntries(-10) }.keyboardShortcut(.pageUp, modifiers: [])
            Button("") { navigateEntries(10) }.keyboardShortcut(.pageDown, modifiers: [])
            Button("") { navigateEntries(Int.min) }.keyboardShortcut(.home, modifiers: [])
            Button("") { navigateEntries(Int.max) }.keyboardShortcut(.end, modifiers: [])
        }
        .frame(width: 0, height: 0).opacity(0)
        .disabled(showSearch)
    }
    /// Only the categories Unciv gives a KeyboardBinding (Personalities has none; Tutorials is F1, not bound on this screen).
    private static func hasBinding(_ name: String) -> Bool { KeyBindings.groups.contains { $0.1.contains { $0.0 == name } } }

    /// An icon from the bundled art, or nothing when the art does not exist (Unciv shows no image then).
    @ViewBuilder private func art(_ name: String, _ folder: String, _ size: CGFloat) -> some View {
        if let img = Art.shared.image(name, folder: folder) {
            Image(uiImage: img).resizable().interpolation(.medium).frame(width: size, height: size)
        }
    }
    /// Unciv CivilopediaCategories.getImage: nations get their portrait, the rest their icon if the category has one.
    @ViewBuilder private func entryIcon(_ e: PediaEntry, size: CGFloat) -> some View {
        if currentCategory == "Nations", let n = rs.nations[e.name] { NationBadge(nation: n, size: size) }
        else if let icon = e.icon { art(icon.name, icon.folder, size) }
    }

    // MARK: Unciv CivilopediaScreen selection

    /// Unciv CivilopediaScreen init: build the entries, then open on the link, or resume where the pedia was left.
    private func setUp() {
        guard pedia.isEmpty else { return }
        pedia = buildPedia()
        let link = openLink ?? ""
        if link.isEmpty {
            // Generic open (e.g. keyboard shortcut, menu button) - resume where we left off
            let resumeCategory = Self.lastCategory ?? "Tutorials"
            let resumeEntry = Self.lastEntryName     // capture before selectCategory overwrites it
            selectCategory(resumeCategory)
            if let e = resumeEntry, currentSorted.contains(where: { $0.name == e }) { selectEntry(e) }
            else if resumeCategory == "Tutorials" { selectDefaultEntry() }
        } else if link.contains("/") {
            selectLink(link)
        } else {
            selectCategory("Tutorials")
            selectEntry(link)
        }
        // Unciv would stay blank if the remembered category has no button any more (religion switched off);
        // open the default category instead.
        if currentCategory == nil { selectCategory("Tutorials"); selectDefaultEntry() }
        if openSearchOnAppear { openSearch() }
    }

    /// Unciv CivilopediaScreen.selectLink: "Category/Entry" selects both, a bare "Category" only the category.
    private func selectLink(_ link: String) {
        let parts = link.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return }
        selectCategory(first)
        if parts.count >= 2 { selectEntry(parts[1]) }
    }

    /// Unciv CivilopediaScreen.selectCategory: unknown names are ignored; otherwise the category's last
    /// selected entry (this visit) is selected again, or its first entry.
    private func selectCategory(_ name: String) {
        guard let c = Self.categoryForLink(name), let cat = pedia.first(where: { $0.name == c }), !cat.sorted.isEmpty else { return }
        currentCategory = c
        GameEvents.post(.screen("pedia_" + c))
        Self.lastCategory = c
        currentEntry = ""
        if let e = entryPerCategory[c] { selectEntry(e) }
        else if let first = cat.sorted.first { selectEntry(first.name) }
    }

    /// Unciv CivilopediaScreen.selectEntry: an entry of the current category; unknown names are ignored.
    private func selectEntry(_ name: String, scroll: Bool = true) {
        guard let c = currentCategory, currentSorted.contains(where: { $0.name == name }) else { return }
        currentEntry = name
        Self.lastEntryName = name
        entryPerCategory[c] = name
        if scroll { listScroll = ListScroll(name: name, token: (listScroll?.token ?? 0) + 1) }
    }

    /// Unciv CivilopediaScreen.selectDefaultEntry: the base ruleset's own tutorial if it has one, else "Civilopedia".
    private func selectDefaultEntry() {
        let names = Set(currentSorted.map(\.name))
        guard let name = (rs.mods.filter { Ruleset.baseRulesets.contains($0) } + ["Civilopedia"]).first(where: { names.contains($0) }) else { return }
        selectEntry(name)
    }

    /// Unciv CivilopediaScreen.navigateCategories: left/right cycle through the category buttons.
    private func navigateCategories(_ direction: Int) {
        let keys = buttonCategories
        guard !keys.isEmpty else { return }
        let index = keys.firstIndex(of: currentCategory ?? "") ?? -1
        selectCategory(keys[((index + keys.count + direction) % keys.count + keys.count) % keys.count])
    }

    /// Unciv CivilopediaScreen.navigateEntries: up/down, page up/down, home/end move through the list, wrapping around.
    private func navigateEntries(_ direction: Int) {
        let names = currentSorted.map(\.name)
        guard !names.isEmpty else { return }
        guard let index = names.firstIndex(of: currentEntry) else { selectEntry(names[0]); return }
        let n = names.count
        let newIndex: Int
        switch direction {
        case Int.min: newIndex = 0
        case Int.max: newIndex = n - 1
        default: newIndex = ((index + direction) % n + n) % n
        }
        selectEntry(names[newIndex])
    }

    // MARK: Unciv CivilopediaCategories.getCategoryIterator + ICivilopediaText.getSortGroup / getSubCategory

    /// Unciv CivilopediaScreen init: every category's displayed entries (Religions and Beliefs only when
    /// religion is shown), each list sorted once.
    func buildPedia() -> [PediaCategory] {
        shownCategories.map { c in
            let entries = iterator(c)
            return PediaCategory(name: c, entries: entries, sorted: Self.sortEntries(entries))
        }
    }

    /// Unciv CivilopediaScreen.selectCategory: `compareBy { sortBy }.thenBy(collator) { name.tr() }` - a stable sort.
    static func sortEntries(_ entries: [PediaEntry]) -> [PediaEntry] {
        entries.enumerated().map { ($0.offset, $0.element, L($0.element.name)) }
            .sorted { a, b in
                if a.1.sortBy != b.1.sortBy { return a.1.sortBy < b.1.sortBy }
                let r = LocaleCode.compare(a.2, b.2)
                return r == .orderedSame ? a.0 < b.0 : r == .orderedAscending
            }
            .map { $0.1 }
    }

    /// Unciv CivilopediaScreen.shouldBeDisplayed = !IHasUniques.isHiddenFromCivilopedia(gameInfo, ruleset).
    private func displayed(_ uniques: [String]) -> Bool {
        !hidden(uniques) && !(settings == nil && hiddenWithoutGame(uniques))
    }
    /// Unciv IHasUniques.isHiddenFromCivilopedia with no game loaded (shouldBeHiddenIfNoGameLoaded): religion is
    /// assumed on when the ruleset has beliefs, espionage when a nation has spy names.
    private func hiddenWithoutGame(_ uniques: [String]) -> Bool {
        ObjectDescriptions.hiddenWithoutGame(uniques.map(Unique.init), rs: rs)
    }

    /// The ruleset's objects in its own (file) order, then any the order list does not know, by name.
    private func ordered<T>(_ order: [String], _ all: [String: T]) -> [T] {
        let known = Set(order)
        return order.compactMap { all[$0] } + all.keys.filter { !known.contains($0) }.sorted().compactMap { all[$0] }
    }
    /// Unciv Era.eraNumber of a tech's era, if both exist.
    private func eraNumber(ofTech tech: String?) -> Int? {
        guard let t = tech.flatMap({ rs.techs[$0] }) else { return nil }
        return rs.eras.firstIndex { $0.name == t.era }
    }
    /// Unciv Building/BaseUnit.getSortGroup: the era of the required tech, 100 without one.
    private func eraSort(_ tech: String?) -> Int { eraNumber(ofTech: tech) ?? 100 }
    /// Unciv Building/BaseUnit.getSubCategory: the era's name, "Other" without one.
    private func eraSub(_ tech: String?) -> String { eraNumber(ofTech: tech).map { rs.eras[$0].name } ?? "Other" }

    /// Unciv UnitNameGroup.getUnits: the units whose "[] gets a name from the [] group" names this group.
    private func unitNameGroupUnits(_ group: String) -> [String] {
        ordered(rs.unitOrder, rs.units).filter { u in
            u.uniques.contains { let q = Unique($0); return q.pattern == "[] gets a name from the [] group" && q.param(1) == group }
        }.map(\.name)
    }

    /// Unciv CivilopediaCategories.getCategoryIterator filtered by shouldBeDisplayed, with each entry's
    /// getSortGroup / getSubCategory and image.
    private func iterator(_ c: String) -> [PediaEntry] {
        switch c {
        case "Buildings", "Wonders":
            // Building.isUnavailableBySettings also hides the nuclear buildings with nukes off and the wonders the
            // starting era made obsolete
            return ordered(rs.buildingOrder, rs.buildings).filter { $0.isAnyWonder == (c == "Wonders") && displayed($0.uniques) && !(state?.isUnavailableBySettings(building: $0) ?? false) }
                .map { PediaEntry(name: $0.name, sortBy: eraSort($0.requiredTech), subCategory: eraSub($0.requiredTech), icon: ($0.name, "BuildingIcons")) }
        case "Resources":
            // Unciv TileResource.getSortGroup = resourceType.ordinal (Luxury, Strategic, Bonus)
            let types = ["Luxury": (0, "Luxury resource"), "Strategic": (1, "Strategic resource"), "Bonus": (2, "Bonus resource")]
            return ordered(rs.resourceOrder, rs.resources).filter { displayed($0.uniques) }
                .map { PediaEntry(name: $0.name, sortBy: types[$0.resourceType]?.0 ?? 0, subCategory: types[$0.resourceType]?.1, icon: ($0.name, "ResourceIcons")) }
        case "Terrains":
            // Unciv Terrain.getSortGroup = type.ordinal (Land, Water, TerrainFeature, NaturalWonder)
            return ordered(rs.terrainOrder, rs.terrains).filter { displayed($0.uniques) }.map { t in
                let (sort, sub): (Int, String) = {
                    switch t.type { case .land: return (0, "Land"); case .water: return (1, "Water"); case .terrainFeature: return (2, "Features"); case .naturalWonder: return (3, "Natural Wonders") }
                }()
                return PediaEntry(name: t.name, sortBy: sort, subCategory: sub, icon: (t.name, "Tiles"))
            }
        case "Tile Improvements":
            // Unciv TileImprovement.getSortGroup / getSubCategory
            return ordered(rs.improvementOrder, rs.improvements).filter { displayed($0.uniques) }.map { i in
                let (sort, sub): (Int, String) =
                    i.isGreatImprovement ? (1, "Great Improvement")
                    : (i.name.hasPrefix("Cancel ") || i.name.hasPrefix("Remove ") || i.name == "Repair") ? (2, "Action")
                    : (0, "Tile Improvements")
                return PediaEntry(name: i.name, sortBy: sort, subCategory: sub, icon: (i.name, "ImprovementIcons"))
            }
        case "Units":
            // BaseUnit.isUnavailableBySettings also hides the nuclear weapons with nukes off
            return ordered(rs.unitOrder, rs.units).filter { displayed($0.uniques) && !(state?.isUnavailableBySettings(unit: $0) ?? false) }
                .map { PediaEntry(name: $0.name, sortBy: eraSort($0.requiredTech), subCategory: eraSub($0.requiredTech), icon: ($0.name, "UnitIcons")) }
        case "Unit types":
            // Unciv UnitType.getCivilopediaIterator: a virtual "Domain: [X]" entry per movement type, then the used
            // unit types; getSortGroup = movementType.ordinal * 2 + (domain ? 0 : 1).
            let domainIndex = { (m: String) in Self.domains.firstIndex(of: m) ?? 100 }
            let domainEntries = Self.domains.map { d in PediaEntry(name: "Domain: [\(d)]", sortBy: domainIndex(d) * 2, subCategory: d, icon: nil) }
            let types = ordered(rs.unitTypeOrder, rs.unitTypes).filter { t in rs.units.values.contains { $0.unitType == t.name } && displayed(t.uniques) }
                .map { PediaEntry(name: $0.name, sortBy: domainIndex($0.movementType) * 2 + 1, subCategory: Self.domains.contains($0.movementType) ? $0.movementType : "Other", icon: ($0.name, "UnitIcons")) }
            return domainEntries + types
        case "Nations":
            // Unciv Nation.getSortGroup / getSubCategory: civilizations, city-states, then the barbarians.
            return rs.nations.values.filter { $0.name != "Spectator" && displayed($0.uniques) }.sorted { $0.name < $1.name }.map { n in
                let (sort, sub): (Int, String) = n.isCityState ? (1, "City-States") : n.isBarbarian ? (9, "Other") : (0, "Civilizations")
                return PediaEntry(name: n.name, sortBy: sort, subCategory: sub, icon: nil)
            }
        case "Personalities":
            // Unciv: "The Personalities file contains unused chaff" - only the ones a nation uses.
            return rs.personalities.values.filter { p in rs.nations.values.contains { $0.personality == p.name } && displayed(p.uniques) }
                .sorted { $0.name < $1.name }.map { PediaEntry(name: $0.name, sortBy: 0, subCategory: nil, icon: nil) }
        case "Technologies":
            // Unciv Technology.getSortGroup = the era's number; getSubCategory = the era's name.
            return rs.techs.values.filter { displayed($0.uniques) }.sorted { ($0.column, $0.row) < ($1.column, $1.row) }.map { t in
                let era = rs.eras.firstIndex { $0.name == t.era }
                return PediaEntry(name: t.name, sortBy: era ?? -1, subCategory: era.map { rs.eras[$0].name }, icon: (t.name, "TechIcons"))
            }
        case "Promotions":
            // Unciv Promotion.getSortGroup: the ruleset index of its first unit type, 1000 without one.
            return rs.promotionOrder.filter { displayed($0.uniques) }.map { p in
                let sort = p.unitTypes.first.flatMap { rs.unitTypeOrder.firstIndex(of: $0) } ?? 1000
                return PediaEntry(name: p.name, sortBy: sort, subCategory: p.unitTypes.first ?? "Other", icon: (p.name, "PromotionIcons"))
            }
        case "Policies":
            // Unciv Policy.getSortGroup = eraNumber * 10000 + branch index * 100 + policyBranchType.ordinal
            // (BranchStart, Member, BranchComplete); getSubCategory = the branch's name.
            var out: [PediaEntry] = []
            for (bi, b) in rs.policyBranches.enumerated() {
                let base = (rs.eras.firstIndex { $0.name == b.era } ?? 0) * 10000 + bi * 100
                if displayed(b.uniques) { out.append(PediaEntry(name: b.name, sortBy: base, subCategory: b.name, icon: (b.name, "PolicyIcons"))) }
                for p in b.policies where displayed(p.uniques) {
                    let complete = p.isBranchCompletion
                    out.append(PediaEntry(name: p.name, sortBy: base + (complete ? 2 : 1), subCategory: b.name, icon: (complete ? b.name : p.name, "PolicyIcons")))
                }
            }
            return out
        case "Religions and Beliefs":
            // Unciv Belief.getSortGroup = type.ordinal (None, Pantheon, Founder, Follower, Enhancer, Any); the
            // "Beliefs" and "Religions" overview entries are of type None, which has no sub-category.
            let order = ["None", "Pantheon", "Founder", "Follower", "Enhancer", "Any"]
            let beliefs = rs.beliefList.filter { displayed($0.uniques) }.map { b in
                let t = order.firstIndex(of: b.type) ?? 0
                return PediaEntry(name: b.name, sortBy: t, subCategory: (t == 0 || t == 5) ? nil : b.type, icon: (b.name, "ReligionIcons"))
            }
            return beliefs + [PediaEntry(name: "Beliefs", sortBy: 0, subCategory: nil, icon: nil),
                              PediaEntry(name: "Religions", sortBy: 0, subCategory: nil, icon: nil)]
        case "Tutorials":
            // Unciv Tutorial.getSortGroup: tutorials without a category first (-1), then by the first two letters
            // of the translated category; getSubCategory = the category, or "Tutorials".
            var out = Ruleset.civilopediaTutorials.filter { displayed($0.uniques) }.map { t -> PediaEntry in
                guard !t.category.isEmpty else { return PediaEntry(name: t.name, sortBy: -1, subCategory: "Tutorials", icon: nil) }
                let units = Array(L(t.category).utf16.prefix(2).map { $0 })
                let lower = Array(String(utf16CodeUnits: units, count: units.count).lowercased().utf16)
                let sort = lower.count < 2 ? Int(lower.first ?? 0) : (Int(lower[0]) << 16) + Int(lower[1])
                return PediaEntry(name: t.name, sortBy: sort, subCategory: t.category, icon: nil)
            }
            // Unciv CivilopediaCategories.getCivilopediaTutorials: the Global Uniques entry, when they have anything to show.
            if rs.globalUniques.contains(where: { isPlayerFacing($0.text) }) || !rs.globalUnitUniques.isEmpty {
                out.append(PediaEntry(name: "Global Uniques", sortBy: 0, subCategory: nil, icon: nil))
            }
            return out
        case "Victory Types":
            // Unciv: only the victory types active in the game in progress.
            return rs.victories.filter { v in settings.map { $0.victoryTypes.contains(v.name) } ?? true }
                .map { PediaEntry(name: $0.name, sortBy: 0, subCategory: nil, icon: nil) }
        case "Unit Names":
            // Unciv UnitNameGroup: only groups with names and units drawing on them; sorted like their first unit.
            return rs.unitNameGroups.keys.sorted().compactMap { g in
                guard !(rs.unitNameGroups[g] ?? []).isEmpty, let first = unitNameGroupUnits(g).first else { return nil }
                return PediaEntry(name: g, sortBy: eraSort(rs.units[first]?.requiredTech), subCategory: first, icon: (first, "UnitIcons"))
            }
        case "Difficulty levels":
            // Unciv Difficulty.getSortGroup: the ruleset's own order.
            return rs.difficulties.enumerated().map { PediaEntry(name: $0.element.name, sortBy: $0.offset, subCategory: nil, icon: nil) }
        case "Eras":
            return rs.eras.enumerated().filter { displayed($0.element.uniques) }.map { PediaEntry(name: $0.element.name, sortBy: $0.offset, subCategory: nil, icon: nil) }
        case "Speeds":
            // Unciv Speed.getSortGroup = (modifier * 1000).toInt()
            return rs.speeds.map { PediaEntry(name: $0.name, sortBy: Int($0.modifier * 1000), subCategory: nil, icon: nil) }
        default:
            return []
        }
    }

    // MARK: Unciv ICivilopediaText.assembleCivilopediaText - each entry's lines

    /// The text lines the right pane shows for an entry, from the same generators the pedia always used.
    func lines(_ c: String, _ name: String) -> [PediaLine] {
        switch c {
        case "Units":
            guard let u = rs.units[name] else { return [] }
            return assembled(u.civilopediaText, ObjectDescriptions.unit(u, rs: rs, s: state))
        case "Buildings", "Wonders":
            guard let b = rs.buildings[name] else { return [] }
            return assembled(b.civilopediaText, ObjectDescriptions.building(b, rs: rs, s: state))
        case "Technologies":
            guard let t = rs.techs[name] else { return [] }
            return assembled(t.civilopediaText, ObjectDescriptions.technology(t, rs: rs, s: state))
        case "Terrains":
            guard let t = rs.terrains[name] else { return [] }
            return assembled(t.civilopediaText, ObjectDescriptions.terrain(t, rs: rs, s: state))
        case "Resources":
            guard let r = rs.resources[name] else { return [] }
            return ObjectDescriptions.resource(r, rs: rs, s: state)   // (no civilopediaText in either base ruleset's TileResources.json)
        case "Tile Improvements":
            guard let i = rs.improvements[name] else { return [] }
            return assembled(i.civilopediaText, ObjectDescriptions.improvement(i, rs: rs, s: state))
        case "Promotions":
            guard let p = rs.promotions[name] else { return [] }
            return promotionLines(p)
        case "Unit types":
            if let d = Self.domains.first(where: { name == "Domain: [\($0)]" }) { return domainLines(d) }
            guard let t = rs.unitTypes[name] else { return [] }
            return assembled(t.civilopediaText, unitTypeLines(t, rs))
        case "Nations":
            guard let n = rs.nations[name] else { return [] }
            return ObjectDescriptions.nation(n, rs: rs, s: state)
        case "Personalities":
            guard let p = rs.personalities[name] else { return [] }
            // Unciv Personality.getCivilopediaTextHeader "[name]'s personality" (drawn as the page's header), then the
            // biography (civilopediaText) assembled with the generated lines
            return [PediaLine(L("[\(p.name)]'s personality"))] + assembled(p.civilopediaText, personalityLines(p, rs))
        case "Policies":
            for b in rs.policyBranches {
                if b.name == name { return branchLines(b) }
                if let p = b.policies.first(where: { $0.name == name }) { return policyLines(p, branch: b) }
            }
            return []
        case "Religions and Beliefs":
            // Unciv Belief.getCivilopediaBeliefsEntry / getCivilopediaReligionEntry
            if name == "Beliefs" {
                return [PediaLine(L("There are four types of beliefs: Pantheon, Founder, Follower and Enhancer beliefs.")),
                        PediaLine(L("Pantheon and Follower beliefs apply to each city following your religion, while Founder and Enhancer beliefs only apply to the founder of a religion."))]
            }
            if name == "Religions" {
                return rs.religionNames.map { L($0) }.sorted { LocaleCode.compare($0, $1) == .orderedAscending }.map { PediaLine($0) }
            }
            guard let b = rs.beliefs[name] else { return [] }
            // Unciv Belief.getCivilopediaTextLines: "{Type}: {type}", then the uniques.
            return (b.type == "None" ? [] : [PediaLine(L("{Type}: {\(b.type)}"))]) + ObjectDescriptions.uniqueFLines(b.uniques, rs: rs, s: state, leading: false)
        case "Tutorials":
            if name == "Global Uniques" { return assembled(rs.globalUniquesCivilopediaText, globalUniquesLines()) }
            guard let t = Ruleset.civilopediaTutorials.first(where: { $0.name == name }) else { return [] }
            // Unciv Tutorial.getCivilopediaTextLines = the steps (plain FormattedLines), assembled with the civilopediaText
            return assembled(t.civilopediaText, t.steps.map { PediaLine(L($0)) })
        case "Victory Types":
            guard let v = rs.victories.first(where: { $0.name == name }) else { return [] }
            // Unciv Victory.getCivilopediaTextLines: the victoryScreenHeader, (its illustration,) an empty line, the milestones
            return [PediaLine(L(v.victoryScreenHeader)), PediaLine("")] + milestoneLines(v)
        case "Unit Names":
            return unitNameGroupLines(name, rs)
        case "Difficulty levels":
            guard let d = rs.difficulties.first(where: { $0.name == name }) else { return [] }
            return difficultyLines(d).map { ObjectDescriptions.fl($0.0, link: $0.1) }
        case "Eras":
            guard let e = rs.eras.first(where: { $0.name == name }) else { return [] }
            return eraLines(e, rs)
        case "Speeds":
            guard let sp = rs.speeds.first(where: { $0.name == name }) else { return [] }
            return speedLines(sp).map { ObjectDescriptions.fl($0) }   // no links
        default:
            return []
        }
    }

    // MARK: Unciv CivilopediaSearchPopup

    /// Unciv searchPopup.open(force = true): the popup keeps its text and results between openings.
    private func openSearch() { showSearch = true }

    /// Unciv CivilopediaSearchPopup: "Search text:" field, the Results expander, Search! (Return) and Close.
    private var searchPopup: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().bleedIntoCutout().onTapGesture { guard !UserSettings.neverCloseByTapOutside else { return }; showSearch = false }
            Panel(highlighted: true) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(L("Search text:")).font(Theme.heading(14)).foregroundStyle(Theme.gold)
                        TextField("", text: $searchText).textFieldStyle(.plain).foregroundStyle(.black).padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white)).autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($searchFocused)
                            .onAppear { searchFocused = true }   // Unciv showListeners: keyboardFocus = searchText
                            .onSubmit { runSearch() }
                            // Unciv: searchText.maxLength = 100
                            .onChange(of: searchText) { _, t in if t.count > 100 { searchText = String(t.prefix(100)) } }
                    }
                    if let results = searchResults {
                        // Unciv ExpanderTab("Results")
                        Button { withAnimation { resultsExpanded.toggle() } } label: {
                            HStack { Text(L("Results")).font(Theme.heading(13)).foregroundStyle(Theme.gold); Spacer(); Image(systemName: resultsExpanded ? "chevron.up" : "chevron.down").foregroundStyle(Theme.creamDim) }
                        }.buttonStyle(.plain)
                        if resultsExpanded {
                            if results.isEmpty {
                                // Unciv finishSearch: FormattedLine("Nothing found!", color = "#f53", header = 3, centered = true)
                                Text(L("Nothing found!")).font(Theme.heading(16)).foregroundStyle(Color(red: 1, green: 0.2, blue: 0.2)).frame(maxWidth: .infinity)
                            } else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(results) { r in
                                            Button { open(r) } label: {
                                                Text(L(r.name)).font(Theme.body).foregroundStyle(Theme.cream).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }.frame(maxHeight: 220)
                            }
                        }
                    }
                    HStack {
                        Button(L("Search!")) { runSearch() }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                        Button(L("Close")) { showSearch = false }.buttonStyle(ThemedButtonStyle(compact: true)).keyboardShortcut(.cancelAction)
                    }
                    if let toast = searchToast {
                        Text(toast).font(Theme.caption).foregroundStyle(Theme.danger).frame(maxWidth: .infinity)
                    }
                }
            }.frame(maxWidth: 440)
        }
    }

    /// Unciv CivilopediaSearchPopup.startSearch / searchLoop / searchEntry: an empty text finds everything, text with
    /// ".*", "\" or "|" is a case-insensitive regular expression, otherwise every word must appear (ignoring case).
    /// Each category is walked in order, its entries in ruleset order; an entry is found when its header, or any of
    /// its civilopedia lines, matches.
    private func runSearch() {
        let text = searchText
        let check: (String) -> Bool
        if text.isEmpty {
            check = { _ in true }
        } else if text.contains(".*") || text.contains("\\") || text.contains("|") {
            guard let re = try? NSRegularExpression(pattern: text, options: .caseInsensitive) else {
                // Unciv: ToastPopup("Invalid regular expression", pediaScreen, 4000), the previous results stay.
                let message = L("Invalid regular expression")
                searchToast = message
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if searchToast == message { searchToast = nil } }
                return
            }
            check = { line in re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
        } else {
            let words = Set(text.split(separator: " ").map(String.init))
            check = { line in words.allSatisfy { line.range(of: $0, options: .caseInsensitive) != nil } }
        }
        searchToast = nil
        var hits: [SearchHit] = []
        for cat in pedia {
            for e in cat.entries where check(L(e.name)) || lines(cat.name, e.name).contains(where: { check($0.text) }) {
                hits.append(SearchHit(category: cat.name, name: e.name))
            }
        }
        searchResults = hits
        resultsExpanded = true
    }
    /// Unciv CivilopediaSearchPopup.addResult: a result opens its entry's link and closes the popup.
    private func open(_ r: SearchHit) {
        showSearch = false
        selectCategory(r.category)
        selectEntry(r.name)
    }

    // MARK: Line generators

    /// Unciv NationDescriptions: the personality's victory preference, its biases and its policy priorities.
    private func personalityLines(_ p: PersonalityDef, _ rs: Ruleset) -> [PediaLine] {
        // Unciv's own keys: "[name]'s personality", one "See also: [nation]" line per nation (ruleset order, each linked),
        // "Preferred victory type: [type]", "Biases:", "Policy priorities:" (biases and priorities indented, unlinked)
        typealias O = ObjectDescriptions
        var out: [PediaLine] = []
        if p.name == "Neutral" { out.append(O.fl(L("Neutral personality"))); return out }
        // (each group followed by Unciv's empty FormattedLine())
        let nations = rs.nationOrder.compactMap { rs.nations[$0] }.filter { $0.personality == p.name }.map { O.fl(L("See also: [\($0.name)]"), link: "Nation/\($0.name)") }
        if !nations.isEmpty { out += nations + [O.blank] }
        if !p.preferredVictoryType.isEmpty && p.preferredVictoryType != "Neutral" { out += [O.fl(L("Preferred victory type: [\(p.preferredVictoryType)]")), O.blank] }
        let biases: [(String, Double)] = [("Productive", p.production), ("Prolific", p.food), ("Greedy", p.gold), ("Scientific", p.science),
                                          ("Cultured", p.culture), ("Hedonistic", p.happiness), ("Religious", p.faith), ("Militaristic", p.military),
                                          ("Pushy", p.aggressive), ("Warmonger", p.declareWar), ("Trader", p.commerce),
                                          ("Negotiator", p.diplomacy), ("Stalwart", p.loyal), ("Expansionistic", p.expansion),
                                          ("Denouncer", p.denounceWillingness)]
        let shown = biases.filter { $0.1 != 5 }
        if !shown.isEmpty {
            out.append(O.fl(L("Biases:")))
            // Float.toPercent() = ((this - 5f) * 20f).toInt()
            for (name, v) in shown { out.append(O.fl("\(L(name)): \(Int((Float(v) - 5) * 20))%", indent: 1)) }
            out.append(O.blank)
        }
        if !p.priorities.isEmpty {
            out.append(O.fl(L("Policy priorities:")))
            for k in Self.priorityOrder(p) { out.append(O.fl(L("[\(k)]: [\(Int(p.priorities[k] ?? 0))]"), indent: 1)) }
        }
        return out
    }

    /// Unciv Personality.priorities is read from the json into a LinkedHashMap, so "Policy priorities:" lists them in the
    /// file's order; a Swift dictionary keeps none, so the order is read back from the personality's own object in the base
    /// ruleset's Personalities.json (keys it does not name - a mod's - follow by name).
    private static func priorityOrder(_ p: PersonalityDef) -> [String] {
        var order: [String] = []
        if let url = Bundle.main.url(forResource: "Personalities", withExtension: "json", subdirectory: "GameData/Rulesets/\(Ruleset.currentBaseRuleset)"),
           let text = try? String(contentsOf: url, encoding: .utf8),
           let nameRange = text.range(of: "\"name\":\"\(p.name)\"") {
            let rest = text[nameRange.upperBound...]
            let end = rest.range(of: "{\"name\":")?.lowerBound ?? rest.endIndex
            if let pr = rest[..<end].range(of: "\"priorities\":{"), let close = rest[pr.upperBound..<end].firstIndex(of: "}") {
                let body = rest[pr.upperBound..<close]
                for part in body.split(separator: ",") {
                    let key = part.split(separator: ":").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\t")) } ?? ""
                    if !key.isEmpty, p.priorities[key] != nil, !order.contains(key) { order.append(key) }
                }
            }
        }
        return order + p.priorities.keys.filter { !order.contains($0) }.sorted()
    }

    /// Unciv UnitNameGroup.getCivilopediaTextLines: the units that draw on the group (each linked), then the names in the
    /// locale's collation, each a link to a Wikipedia search in the game's language (`https://$language.wikipedia.org/w/
    /// index.php?search=${name.tr()}`)
    private func unitNameGroupLines(_ group: String, _ rs: Ruleset) -> [PediaLine] {
        var out: [PediaLine] = []
        let units = unitNameGroupUnits(group)
        if !units.isEmpty { out.append(PediaLine(L("Units"))); out += units.map { PediaLine(L($0), link: "Unit/\($0)") }; out.append(PediaLine("")) }
        // `unitNames.sortedWith(collator)` - the names as written, the game language's collation
        let names = (rs.unitNameGroups[group] ?? []).enumerated().sorted { a, b in
            let r = LocaleCode.compare(a.element, b.element); return r == .orderedSame ? a.offset < b.offset : r == .orderedAscending
        }.map(\.element)
        if !names.isEmpty {
            // settings.locale!!.language: the Java language code of the game language's locale ("en", "tr", "in" for
            // Indonesian); the query URLEncoder.encode(name.tr(), "UTF-8") - a space is "+"
            let language = Translations.shared.language
            let code = LocaleCode.find(language).map { String($0.languageTag.prefix { $0 != "-" }) } ?? (Locale.current.language.languageCode?.identifier ?? "en")
            out.append(PediaLine(L("Unit Names")))
            for n in names {
                out.append(PediaLine(L(n), link: "https://\(code).wikipedia.org/w/index.php?search=\(Self.javaURLEncode(L(n)))"))
            }
        }
        return out
    }

    /// java.net.URLEncoder.encode(s, "UTF-8"): letters, digits and ".-*_" as they are, a space as "+", every other byte
    /// of the UTF-8 form as %XX (upper-case hex).
    static func javaURLEncode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2E, 0x2D, 0x2A, 0x5F: out.append(Character(Unicode.Scalar(b)))
            case 0x20: out.append("+")
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }
    /// Unciv BaseUnitDescriptions.getUnitTypeCivilopediaTextLines, in its order: the domain and a separator, "Units:" and the type's units (ruleset.units order), "Promotions" and
    /// the promotions open to them (ruleset.unitPromotions order), then a separator before the uniques. (Ours sorted both
    /// lists by name.)
    /// Unciv UnitType.getUnitTypeCivilopediaTextLines (getUnitTypeLines): the domain linked to its own entry, a separator,
    /// "Units:" and the units of the type (ruleset order, each linked), "Promotions" and the promotions for it, then the
    /// type's uniques after a separator.
    private func unitTypeLines(_ t: UnitType, _ rs: Ruleset) -> [PediaLine] {
        var out: [PediaLine] = []
        if Self.domains.contains(t.movementType) { out += [ObjectDescriptions.fl(L("Domain: [\(t.movementType)]"), link: "UnitType/Domain: [\(t.movementType)]"), ObjectDescriptions.blank] }
        out.append(ObjectDescriptions.fl(L("Units:")))
        out += rs.unitOrder.compactMap { rs.units[$0] }.filter { $0.unitType == t.name }.map { ObjectDescriptions.fl(L($0.name), link: "Unit/\($0.name)") }
        let promos = rs.promotionOrder.filter { $0.unitTypes.contains(t.name) }.map { $0.name }
        if !promos.isEmpty { out.append(ObjectDescriptions.fl(L("Promotions"))); out += promos.map { ObjectDescriptions.fl(L($0), link: "Promotion/\($0)") } }
        out += ObjectDescriptions.uniqueFLines(t.uniques, rs: rs, s: state)
        return out
    }

    /// Unciv Difficulty.getCivilopediaTextLines (toPercent = (value × 100).toInt()).
    /// Each line with its link: a bonus starting unit is `FormattedLine(Unique("[unit]"))` (getUniqueLink), an AI free tech
    /// links to the tech; nothing else links.
    private func difficultyLines(_ d: DifficultyDef) -> [(String, String?)] {
        // Float.toPercent: (this * 100).toInt() in Float - the ruleset's 0.9 is the Float 0.9, whose ×100 is 90, not 89.99…
        func p(_ v: Double) -> Int { Int(Float(v) * 100) }
        func units(_ title: String, _ list: [String]) -> [(String, String?)] {
            guard !list.isEmpty else { return [] }
            var order: [String] = [], counts: [String: Int] = [:]
            for u in list { if counts[u] == nil { order.append(u) }; counts[u, default: 0] += 1 }
            return [("", nil), (" " + L("{\(title)}:"), nil)] + order.map { u in
                let unique = Unique(counts[u] == 1 ? "[\(u)]" : "\(counts[u] ?? 1) [\(u)]")
                return ("  " + (counts[u] == 1 ? L(u) : "\(counts[u] ?? 1) \(L(u))"), ObjectDescriptions.uniqueLink(unique, s: state))
            }
        }
        var out: [(String, String?)] = [L("Player settings"),
                   " " + L("{Base happiness}: \(d.baseHappiness) ⌣"),
                   " " + L("{Extra happiness per luxury}: \(Int(d.extraHappinessPerLuxury)) ⌣"),
                   " " + L("{Research cost modifier}: \(p(d.researchCostModifier))% ⍾"),
                   " " + L("{Unit cost modifier}: \(p(d.unitCostModifier))% ⚙"),
                   " " + L("{Building cost modifier}: \(p(d.buildingCostModifier))% ⚙"),
                   " " + L("{Policy cost modifier}: \(p(d.policyCostModifier))% ♪"),
                   " " + L("{Unhappiness modifier}: \(p(d.unhappinessModifier))%"),
                   " " + L("{Bonus vs. Barbarians}: \(p(d.barbarianBonus))% †"),
                   " " + L("{Barbarian spawning delay}: \(d.barbarianSpawnDelay)")].map { ($0, nil) }
        out += units("Bonus starting units", d.playerBonusStartingUnits)
        out += ["", L("AI settings"),
                " " + L("{AI difficulty level}: {\(d.aiDifficultyLevel ?? "")}"),
                " " + L("{AI city growth modifier}: \(p(d.aiCityGrowthModifier))% ⁂"),
                " " + L("{AI unit cost modifier}: \(p(d.aiUnitCostModifier))% ⚙"),
                " " + L("{AI building cost modifier}: \(p(d.aiBuildingCostModifier))% ⚙"),
                " " + L("{AI wonder cost modifier}: \(p(d.aiWonderCostModifier))% ⚙"),
                " " + L("{AI building maintenance modifier}: \(p(d.aiBuildingMaintenanceModifier))% ¤"),
                " " + L("{AI unit maintenance modifier}: \(p(d.aiUnitMaintenanceModifier))% ¤"),
                " " + L("{AI unhappiness modifier}: \(p(d.aiUnhappinessModifier))%")].map { ($0, nil) }
        if !d.aiFreeTechs.isEmpty { out += [("", nil), (" " + L("{AI free techs}:"), nil)] + d.aiFreeTechs.map { ("    " + L($0), "Technology/\($0)") } }
        out += units("Major AI civilization bonus starting units", d.aiMajorCivBonusStartingUnits)
        out += units("City state bonus starting units", d.aiCityStateBonusStartingUnits)
        out += ["", L("{Turns until barbarians enter player tiles}: \(d.turnBarbariansCanEnterPlayerTiles) ⏳"),
                L("{Gold reward for clearing barbarian camps}: \(d.clearBarbarianCampReward) ¤")].map { ($0, nil) }
        return out
    }
    /// Unciv Speed.getCivilopediaTextLines (Kotlin Float × 100 prints with one decimal, e.g. 100.0).
    private func speedLines(_ sp: SpeedDef) -> [String] {
        let year = Int(abs(sp.startYear))
        // Kotlin Float arithmetic and Float.toString: the Quick speed's 0.67 × 100 reads "67.0"
        func pct(_ v: Double) -> String { "\(Float(v) * 100)" }
        return [L("General speed modifier: [\(pct(sp.modifier))]%⏳"),
                L("Production cost modifier: [\(pct(sp.productionCostModifier))]%⚙"),
                L("Gold cost modifier: [\(pct(sp.goldCostModifier))]%¤"),
                L("Science cost modifier: [\(pct(sp.scienceCostModifier))]%⍾"),
                L("Culture cost modifier: [\(pct(sp.cultureCostModifier))]%♪"),
                L("Faith cost modifier: [\(pct(sp.faithCostModifier))]%☮"),
                L("Improvement build length modifier: [\(pct(sp.improvementBuildLengthModifier))]%⏳"),
                L("Diplomatic deal duration: [\(sp.dealDuration)] turns⏳"),
                L("Gold gift influence gain modifier: [\(pct(sp.goldGiftModifier))]%¤"),
                L("City-state tribute scaling interval: [\(sp.cityStateTributeScalingInterval)] turns⏳"),
                L("Barbarian spawn modifier: [\(pct(sp.barbarianModifier))]%†"),
                L("Golden age length modifier: [\(pct(sp.goldenAgeLengthModifier))]%⌣"),
                L("Adjacent city religious pressure: [\(Int(sp.religiousPressureAdjacentCity))]☮"),
                L("Peace deal duration: [\(sp.peaceDealDuration)] turns⏳"),
                L("Start year: [\(L("[\(year)] " + (sp.startYear < 0 ? "BC" : "AD")))]")]
    }
    /// Unciv Era.getCivilopediaTextLines: embark strength, buy/research-agreement costs, the era's techs, uniques, then "See also" policy branches.
    /// The techs in ruleset.technologies order, each linked; the uniques after an empty line; the era's policy branches.
    private func eraLines(_ e: EraDef, _ rs: Ruleset) -> [PediaLine] {
        var out = [L("Embarked strength: [\(e.embarkDefense)]†"), L("Base unit buy cost: [\(e.baseUnitBuyCost)]¤"), L("Research agreement cost: [\(e.researchAgreementCost)]¤"), ""].map { ObjectDescriptions.fl($0) }
        out += rs.techOrder.compactMap { rs.techs[$0] }.filter { $0.era == e.name }.map { ObjectDescriptions.fl(L($0.name), link: "Technology/\($0.name)") }
        out += ObjectDescriptions.uniqueFLines(e.uniques, rs: rs, s: state)
        let branches = rs.policyBranches.filter { $0.era == e.name }
        if !branches.isEmpty { out += [ObjectDescriptions.blank, ObjectDescriptions.fl(L("See also") + ":")] + branches.map { ObjectDescriptions.fl(L($0.name), link: "Policy/\($0.name)") } }
        return out
    }
    /// Unciv Promotion.getCivilopediaTextLines: its uniques, the promotions it needs, the units and unit types it is
    /// available for, the units that get it free, and the buildings and terrains that grant it
    private func promotionLines(_ p: PromotionDef) -> [PediaLine] {
        typealias O = ObjectDescriptions
        // uniquesToCivilopediaTextLines(leadingSeparator = null)
        var out = O.uniqueFLines(p.uniques, rs: rs, s: state, leading: false)
        // only prerequisites the ruleset has
        let pre = p.prerequisites.filter { rs.promotions[$0] != nil }
        if !pre.isEmpty {
            out.append(O.blank)
            if pre.count == 1 { out.append(O.fl(L("Requires [\(pre[0])]"), link: "Promotion/\(pre[0])")) }
            else { out.append(O.fl(L("Requires at least one of the following:"))); out += pre.map { O.fl(L($0), link: "Promotion/\($0)") } }
        }
        if !p.unitTypes.isEmpty {
            out.append(O.blank)
            // unitTypes.partition { it in ruleset.units }: a unit name links to the unit, anything else to a unit type
            func link(_ t: String) -> String { rs.units[t] != nil ? "Unit/\(t)" : "UnitType/\(t)" }
            if p.unitTypes.count == 1 { out.append(O.fl(L("Available for [\(p.unitTypes[0])]"), link: link(p.unitTypes[0]))) }
            else {
                out.append(O.fl(L("Available for:")))
                out += (p.unitTypes.filter { rs.units[$0] != nil } + p.unitTypes.filter { rs.units[$0] == nil }).map { O.fl(L($0), link: link($0), indent: 1) }
            }
        }
        // ruleset.units.filter { promotions.contains(name) }, in ruleset order
        let freeFor = rs.unitOrder.filter { rs.units[$0]?.promotions.contains(p.name) == true }
        if !freeFor.isEmpty {
            out.append(O.blank)
            if freeFor.count == 1 { out.append(O.fl(L("Free for [\(freeFor[0])]"), link: "Unit/\(freeFor[0])")) }
            else { out.append(O.fl(L("Free for:"))); out += freeFor.map { O.fl(L($0), link: "Unit/\($0)") } }
        }
        // the buildings whose UnitStartingPromotions grants it, then the terrains whose TerrainGrantsPromotion does
        let grantors = rs.buildingOrder.compactMap { rs.buildings[$0] }.filter { b in
            b.uniqueObjects.contains { $0.pattern == "All newly-trained [] units [] receive the [] promotion" && $0.param(2) == p.name }
        }.map { ($0.name, O.buildingLink($0)) } + rs.terrainOrder.compactMap { rs.terrains[$0] }.filter { t in
            t.uniqueObjects.contains { $0.pattern == "Grants [] ([]) to adjacent [] units for the rest of the game" && $0.param(0) == p.name }
        }.map { ($0.name, "Terrain/\($0.name)") }
        if !grantors.isEmpty {
            out.append(O.blank)
            if grantors.count == 1 { out.append(O.fl(L("Granted by [\(grantors[0].0)]"), link: grantors[0].1)) }
            else { out.append(O.fl(L("Granted by:"))); out += grantors.map { O.fl(L($0.0), link: $0.1, indent: 1) } }
        }
        return out
    }
    /// Unciv Policy.getCivilopediaTextLines for a member or completion policy: "Policy branch: [X]" (the era is only on the
    /// branch's own page), then - not for the branch completion - what it requires (Ruleset load: a policy with no
    /// `requires` requires its branch), then the policies it leads to (no completion among them), then its uniques
    private func policyLines(_ p: PolicyDef, branch: PolicyBranch) -> [PediaLine] {
        typealias O = ObjectDescriptions
        var out: [PediaLine] = [O.fl(L("Policy branch: [\(branch.name)]"), link: "Policy/\(branch.name)")]
        let requires = p.requires.isEmpty ? [branch.name] : p.requires
        if !p.isBranchCompletion {
            out.append(O.blank)
            if requires.count == 1 { out.append(O.fl(L("Requires [\(requires[0])]"), link: "Policy/\(requires[0])")) }
            else { out.append(O.fl(L("Requires all of the following:"))); out += requires.map { O.fl(L($0), link: "Policy/\($0)") } }
        }
        out += policyTail(p.name, uniques: p.uniques, leadsTo: rs.policyBranches.flatMap(\.policies).filter { !$0.isBranchCompletion && $0.requires.contains(p.name) }.map(\.name))
        return out
    }
    /// The rest of Policy.getCivilopediaTextLines, shared by branches and policies: "Leads to" (ruleset.policies in order,
    /// no branch completion), the buildings then units it enables ("Only available <after adopting [this]>" or
    /// "Unavailable <before adopting [this]>") and disables (the other way round), then its uniques.
    private func policyTail(_ name: String, uniques: [String], leadsTo: [String]) -> [PediaLine] {
        typealias O = ObjectDescriptions
        var out: [PediaLine] = []
        if !leadsTo.isEmpty {
            out.append(O.blank)
            if leadsTo.count == 1 { out.append(O.fl(L("Leads to [\(leadsTo[0])]"), link: "Policy/\(leadsTo[0])")) }
            else { out.append(O.fl(L("Leads to:"))); out += leadsTo.map { O.fl(L($0), link: "Policy/\($0)", indent: 1) } }
        }
        func has(_ us: [Unique], _ pattern: String, _ modifier: String) -> Bool {
            us.contains { $0.pattern == pattern && $0.conditionals.contains { $0.pattern == modifier && $0.param(0) == name } }
        }
        func enabled(_ us: [Unique]) -> Bool { has(us, "Only available", "after adopting []") || has(us, "Unavailable", "before adopting []") }
        func disabled(_ us: [Unique]) -> Bool { has(us, "Only available", "before adopting []") || has(us, "Unavailable", "after adopting []") }
        let buildings = rs.buildingOrder.compactMap { rs.buildings[$0] }, units = rs.unitOrder.compactMap { rs.units[$0] }
        let en = buildings.filter { enabled($0.uniqueObjects) }.map { O.fl(L($0.name), link: O.buildingLink($0), indent: 1) }
            + units.filter { enabled($0.uniqueObjects) }.map { O.fl(L($0.name), link: "Unit/\($0.name)", indent: 1) }
        if !en.isEmpty { out.append(O.fl(L("Enables:"))); out += en }
        let dis = buildings.filter { disabled($0.uniqueObjects) }.map { O.fl(L($0.name), link: O.buildingLink($0), indent: 1) }
            + units.filter { disabled($0.uniqueObjects) }.map { O.fl(L($0.name), link: "Unit/\($0.name)", indent: 1) }
        if !dis.isEmpty { out.append(O.fl(L("Disables:"))); out += dis }
        out += O.uniqueFLines(uniques, rs: rs, s: state)
        return out
    }

    /// Unciv BaseUnitDescriptions.getUnitTypeCivilopediaTextLines (getDomainLines): the used unit types of the domain.
    /// Unciv getUnitTypeCivilopediaTextLines (getDomainLines): "{Unit types}:" and the used unit types of the domain, linked.
    private func domainLines(_ domain: String) -> [PediaLine] {
        [ObjectDescriptions.fl(L("{Unit types}:"))] + ordered(rs.unitTypeOrder, rs.unitTypes)
            .filter { t in t.movementType == domain && rs.units.values.contains { $0.unitType == t.name } }
            .map { ObjectDescriptions.fl(L($0.name), link: "UnitType/\($0.name)") }
    }
    /// Unciv Policy.getCivilopediaTextLines for a PolicyBranch: the era it unlocks at, the policies it leads to, its uniques.
    private func branchLines(_ b: PolicyBranch) -> [PediaLine] {
        // "{Unlocked at} {era}" (header 4, the era's colour) linked to the era
        var out = [ObjectDescriptions.fl(L("{Unlocked at} {\(b.era)}"), link: rs.eras.contains { $0.name == b.era } ? "Era/\(b.era)" : nil)]
        // Unciv Ruleset load: a policy without "requires" requires its branch.
        let leadsTo = rs.policyBranches.flatMap(\.policies).filter { p in !p.isBranchCompletion && (p.requires.isEmpty ? b.policies.contains { $0.name == p.name } : p.requires.contains(b.name)) }.map(\.name)
        out += policyTail(b.name, uniques: b.uniques, leadsTo: leadsTo)
        return out
    }
    /// Unciv GlobalUniques.getCivilopediaTextLines: the global uniques under "Global Effect", then the unit uniques.
    private func globalUniquesLines() -> [PediaLine] {
        typealias O = ObjectDescriptions
        var out: [PediaLine] = []
        // uniquesToCivilopediaTextLines with an empty line and "Global Effect" (header 4) as the leading separator
        let global = O.uniqueFLines(rs.globalUniques.map(\.text), rs: rs, s: state, leading: false)
        if !global.isEmpty { out += [O.blank, O.fl(L("Global Effect"))] + global }
        let unit = O.uniqueFLines(rs.globalUnitUniques.map(\.text), rs: rs, s: state, leading: false)
        if !unit.isEmpty { out += [O.blank, O.fl(L("Units"))] + unit }
        return out
    }

    // MARK: Unciv FormattedLine rendering (link icon, object icon, jump to the linked entry)

    /// Unciv ICivilopediaText.civilopediaText: the ruleset's own lines, which carry their link in the json.
    private func authored(_ lines: [CivilopediaLine]) -> [PediaLine] {
        lines.map { l in
            let text = L(l.text)
            // FormattedLine from json: its own link only (getUniqueLink is for lines made from a Unique)
            var line = PediaLine(String(repeating: "  ", count: l.indent) + text, link: l.link)
            line.extraImage = l.extraImage
            return line
        }
    }
    /// Unciv ICivilopediaText.assembleCivilopediaText (the header is the page's own): the json's civilopediaText with the
    /// generated lines (getCivilopediaTextLines) put in front of its first non-empty linked line - after an empty line when
    /// json lines came before, followed by one - or after all of them (after an empty line) when none links.
    private func assembled(_ civilopediaText: [CivilopediaLine], _ generated: [PediaLine]) -> [PediaLine] {
        var out: [PediaLine] = []
        var middleDone = false, outerNotEmpty = false
        for next in civilopediaText {
            if !middleDone && !next.isEmpty && next.hasLink {
                middleDone = true
                if outerNotEmpty { out.append(PediaLine("")) }
                out += generated
                out.append(PediaLine(""))
            }
            outerNotEmpty = true
            out += authored([next])
        }
        if !middleDone {
            if outerNotEmpty { out.append(PediaLine("")) }
            out += generated
        }
        return out
    }
    /// Unciv Milestone.getFormattedLine: a milestone links to the thing it asks for.
    private func milestoneLines(_ v: VictoryDef) -> [PediaLine] {
        v.milestones.map { m in
            let u = Unique(m)
            switch u.pattern {
            // "TODO: Links should be `Building/params[0]`, but then the Wonder links don't resolve correctly" - Unciv writes Wonder/
            case "Build []", "Anyone should build []": return PediaLine(L(m), link: "Wonder/\(u.param(0))")
            case "Become the world religion": return PediaLine(L(m), link: "Tutorials/Religion")
            case "Complete [] Policy branches": return PediaLine(L(m), link: "Policies")
            default: return PediaLine(L(m))
            }
        }
    }

    /// Unciv CivilopediaCategories.getImage: which icon folder a category's entries are drawn from.
    static func iconFolder(_ category: String) -> String {
        switch category {
        case "Buildings", "Wonders": return "BuildingIcons"
        case "Units", "Unit types", "Unit Names": return "UnitIcons"
        case "Technologies": return "TechIcons"
        case "Terrains": return "Tiles"
        case "Resources": return "ResourceIcons"
        case "Tile Improvements": return "ImprovementIcons"
        case "Promotions": return "PromotionIcons"
        case "Policies": return "PolicyIcons"
        case "Religions and Beliefs": return "ReligionIcons"
        case "Nations": return "NationIcons"
        default: return "OtherIcons"
        }
    }
    /// Unciv FormattedLine.linkType: the entry an internal link points at, if this pedia can show it.
    private func destination(_ link: String) -> (category: String, name: String)? { Self.destination(link, shown: shownCategories) }
    /// The link is split as Unciv's CivilopediaScreen.selectLink splits it, `link.split('/', limit = 2)`, which keeps
    /// empty parts - "" is [""] and "/" is ["", ""] -, so a mod's civilopediaText line with `"link": ""` or `"/"`
    /// names no category and shows as plain text, where Swift's split dropped them and `parts[0]` stopped the app.
    static func destination(_ link: String, shown: [String]) -> (category: String, name: String)? {
        guard !link.hasPrefix("http") && !link.hasPrefix("mailto:") else { return nil }
        let parts = link.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let c = categoryForLink(parts[0]), shown.contains(c) else { return nil }
        return (c, parts.count == 2 ? parts[1] : "")
    }
    /// Unciv MarkupRenderer linkAction -> CivilopediaScreen.selectLink: select the linked category, then its entry.
    private func follow(_ dest: (category: String, name: String)) {
        selectCategory(dest.category)
        if !dest.name.isEmpty { selectEntry(dest.name) }
    }
    /// Unciv FormattedLine.render: a linked line gets the linked object's icon in front and opens it when tapped.
    @ViewBuilder private func lineView(_ line: PediaLine, own: String) -> some View {
        let color = line.text.hasPrefix(" ") ? Theme.creamDim : Theme.gold.opacity(0.85)
        if line.text.isEmpty && line.link == nil {
            Color.clear.frame(height: 6)   // Unciv FormattedLine(): an empty line is a spacer
        } else if let link = line.link, link.hasPrefix("http") {
            // Unciv LinkType.External: opens outside the game
            SwiftUI.Link(destination: URL(string: link) ?? URL(string: "https://unciv.app")!) {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "link").font(.system(size: 9)).foregroundStyle(Theme.gold).padding(.top, 2)
                    Text(line.text.isEmpty ? link : line.text).font(Theme.caption).foregroundStyle(Theme.gold).underline().fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let dest = line.link.flatMap({ destination($0) }), dest.name != own {
            Button { follow(dest) } label: {
                HStack(alignment: .top, spacing: 4) {
                    ArtIcon(name: dest.name, folder: Self.iconFolder(dest.category), fallback: "link", size: 15).padding(.top, 1)
                    Text(line.text).font(Theme.caption).foregroundStyle(color).underline().multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }.buttonStyle(.plain)
        } else {
            Text(line.text).font(Theme.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension CivilopediaScreen {
    /// A pedia over a game in progress without a controller (a save read on its own).
    init(state: GameState, ruleset: Ruleset) { self.state = state; self.rs = ruleset; self.onClose = {}; self.openSearchOnAppear = false; self.openLink = nil }
}
