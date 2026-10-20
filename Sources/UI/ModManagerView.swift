// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv ModManagementScreen: the installed and the downloadable mods under one ModManagementOptions - a filter text and a
/// category for both lists, a sort for each (SortType) - its texts Unciv's own.
struct ModManagerView: View {
    /// Unciv ModManagementOptions.SortType: the select box's label and the header's symbols (Fonts.sortUpArrow / sortDownArrow,
    /// Fonts.clock, Fonts.star, Fonts.status)
    enum SortType: CaseIterable {
        case name, nameDesc, date, dateDesc, stars, status
        var label: String {
            switch self { case .name: return "Name ↑"; case .nameDesc: return "Name ↓"; case .date: return "Date ↑"; case .dateDesc: return "Date ↓"
                          case .stars: return "Stars ↓"; case .status: return "Status ↓" }
        }
        var symbols: String {
            switch self { case .name: return "↑"; case .nameDesc: return "↓"; case .date: return "⌚↑"; case .dateDesc: return "⌚↓"
                          case .stars: return "✯↓"; case .status: return "◉↓" }
        }
        func next() -> SortType { let all = SortType.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count] }
    }
    /// Unciv ModManagementScreen.cleanModName
    static func cleanModName(_ name: String) -> String { name.replacingOccurrences(of: "   ", with: " - ") }
    let onClose: () -> Void
    @State private var filterText = ""   // Unciv ModManagementOptions.textField: one filter for both lists
    @State private var modURL = ""
    @State private var repos: [ModDownloader.Repo] = []
    @State private var status: String? = nil
    @State private var busy = false
    @State private var installed = Ruleset.availableMods()
    @State private var repoSizes: [String: Int] = [:]   // Unciv ModInfoAndActionPane: fetched lazily per mod

    /// Unciv ModManagementScreen.refreshInstalledModTable: the installed list under the chosen sort, through the same
    /// ModUIData.matchesFilter as the online list - the category (the mod's ModOptions topics) and the text in the
    /// name or the author. Ours matched the name only and ignored the category.
    private var sortedInstalled: [String] {
        let matching = installed.filter { ModDownloader.matchesFilter(name: $0, author: ModDownloader.installedAuthor($0), topics: ModDownloader.installedTopics($0), text: filterText, topic: category) }
        func hasUpdate(_ m: String) -> Bool { repos.contains { $0.folderName == m && ModDownloader.installedIsOutdated($0) } }
        // Unciv ModUIData.stateSortWeight: an update and visual 3, an update 2, visual 1
        func weight(_ m: String) -> Int { (hasUpdate(m) ? 2 : 0) + (UserSettings.visualMods.contains(m) ? 1 : 0) }
        func byName(_ a: String, _ b: String) -> ComparisonResult { a.compare(b, options: .caseInsensitive) }
        switch sortInstalled {
        case .nameDesc: return matching.sorted { byName($1, $0) == .orderedAscending }
        // Unciv sortByDate / sortByDateDesc: ModUIData.lastUpdated() - the ModOptions' lastUpdated, compared as a string
        case .date: return matching.sorted { ModDownloader.installedLastUpdated($0) < ModDownloader.installedLastUpdated($1) }
        case .dateDesc: return matching.sorted { ModDownloader.installedLastUpdated($0) > ModDownloader.installedLastUpdated($1) }
        case .status: return matching.sorted { a, b in weight(a) != weight(b) ? weight(a) > weight(b) : byName(a, b) == .orderedAscending }
        default: return matching.sorted { byName($0, $1) == .orderedAscending }
        }
    }
    @State private var category = "unciv-mod"
    @State private var incomplete = false   // Unciv markOnlineQueryIncomplete
    @State private var sortOnline = SortType.stars
    @State private var sortInstalled = SortType.name
    @State private var checking: String? = nil
    @State private var pendingRemoval: String? = nil   // Unciv ModManagementScreen: deleting a mod is confirmed first
    @State private var checkResults: [String: [RulesetError]] = [:]

    var body: some View {
        // Unciv's screen has no title; the sheet's is the main menu button that opens it ("Mods")
        ThemedSheet(L("Mods"), subtitle: nil, onClose: onClose) {
            // Unciv ModManagementOptions.expander: "Sort and Filter" - Filter:, Category:, Sort Current:, Sort Downloadable:
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Sort and Filter")).font(Theme.heading(14)).foregroundStyle(Theme.gold)
                    HStack { Text(L("Filter:")).font(Theme.small); TextField(L("Enter search text"), text: $filterText).textFieldStyle(.roundedBorder).font(Theme.small) }
                    HStack {
                        Text(L("Category:")).font(Theme.small); Spacer()
                        Menu(L(ModDownloader.categories.first { $0.topic == category }?.label ?? "")) {
                            ForEach(ModDownloader.categories, id: \.topic) { c in Button(L(c.label)) { category = c.topic } }
                        }.font(Theme.small).tint(Theme.gold)
                    }
                    HStack {
                        Text(L("Sort Current:")).font(Theme.small); Spacer()
                        Menu(L(sortInstalled.label)) { ForEach(SortType.allCases.filter { $0 != .stars }, id: \.self) { t in Button(L(t.label)) { sortInstalled = t } } }.font(Theme.small).tint(Theme.gold)
                    }
                    HStack {
                        Text(L("Sort Downloadable:")).font(Theme.small); Spacer()
                        Menu(L(sortOnline.label)) { ForEach(SortType.allCases, id: \.self) { t in Button(L(t.label)) { sortOnline = t } } }.font(Theme.small).tint(Theme.gold)
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    // Unciv getInstalledHeader: "Current mods" and the sort's symbols; a tap moves to the next sort but Stars
                    Button { repeat { sortInstalled = sortInstalled.next() } while sortInstalled == .stars } label: {
                        Text(L("Current mods") + " " + sortInstalled.symbols).font(Theme.heading(15)).foregroundStyle(Theme.gold)
                    }.buttonStyle(.plain)
                    ForEach(sortedInstalled, id: \.self) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                // Unciv ModUIData.buttonText: cleanModName, the categories its topics name under it (ModDecoratedButton)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Self.cleanModName(m)).font(Theme.body)
                                    let cats = Self.categoryText(ModDownloader.installedTopics(m))
                                    if !cats.isEmpty { Text(cats).font(Theme.small).foregroundStyle(Theme.creamDim) }
                                }
                                Spacer()
                                // Unciv refreshInstalledModActions: "Check [name]" (RulesetValidator on the mod merged with the
                                // base ruleset - Unciv opens the options' ModCheck page for it) and "Delete [name]"
                                Button(checking == m ? L("Checking mods for errors...") : L("Check [\(Self.cleanModName(m))]")) { check(m) }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(checking != nil)
                                Button(L("Delete [\(Self.cleanModName(m))]")) { pendingRemoval = m }.buttonStyle(ThemedButtonStyle(destructive: true, compact: true))
                            }
                            // Unciv ModManagementScreen.addVisualCheckBox
                            if Ruleset.isAudioVisualMod(m) {
                                Toggle(L("Permanent audiovisual mod"), isOn: Binding(get: { UserSettings.visualMods.contains(m) }, set: { on in
                                    var mods = UserSettings.visualMods.filter { $0 != m }
                                    if on { mods.append(m) }
                                    UserSettings.visualMods = mods
                                    installed = Ruleset.availableMods()
                                })).font(Theme.small).tint(Theme.gold)
                            }
                            // Unciv ModCheckTab.addModResult: every line in the order found, untranslated, in its severity's
                            // colour ("No problems found." when there is none), and "Copy to clipboard" unless OK
                            if let errors = checkResults[m] {
                                if errors.isEmpty { Text(L("No problems found.")).font(Theme.small).foregroundStyle(Theme.good) }
                                else {
                                    ForEach(errors) { e in
                                        Text(e.text).font(Theme.small).foregroundStyle(e.severity >= .ErrorOptionsOnly ? Theme.danger : Theme.gold).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Button(L("Copy to clipboard")) { UIPasteboard.general.string = errors.map { $0.text }.joined(separator: "\n") }.buttonStyle(ThemedButtonStyle(compact: true))
                                }
                            }
                        }
                        Divider2()
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    // Unciv getOnlineHeader: "Downloadable mods" and the sort's symbols; a tap moves to the next sort
                    Button { sortOnline = sortOnline.next() } label: {
                        Text(L("Downloadable mods") + " " + sortOnline.symbols).font(Theme.heading(15)).foregroundStyle(Theme.gold)
                    }.buttonStyle(.plain)
                    // Unciv "Download mod from URL": repository / branch / release / commit URL
                    HStack {
                        TextField(L("Please enter the mod repository -or- archive zip -or- branch -or- release -or- commit url:"), text: $modURL).textFieldStyle(.roundedBorder).font(Theme.caption)
                        Button(L("Paste from clipboard")) { modURL = UIPasteboard.general.string ?? "" }.buttonStyle(ThemedButtonStyle(compact: true))
                        Button(L("Download mod from URL")) { installFromURL() }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(busy || modURL.isEmpty)
                    }
                    if let s = status { Text(s).font(Theme.caption).foregroundStyle(Theme.creamDim) }
                    ForEach(sortedOnline) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            let outdated = installed.contains(r.folderName) && ModDownloader.installedIsOutdated(r)
                            // Unciv ModUIData.buttonText: cleanModName and " - {Updated}" for an installed mod pushed since, the
                            // categories its topics name under it (ModDecoratedButton); the star count is only a sort
                            Text(L(Self.cleanModName(r.folderName) + (outdated ? " - {Updated}" : ""))).font(Theme.heading(14))
                            let cats = Self.categoryText(r.topics ?? [])
                            if !cats.isEmpty { Text(cats).font(Theme.small).foregroundStyle(Theme.creamDim) }
                            if let d = r.description { Text(d).font(Theme.small).foregroundStyle(Theme.creamDim).lineLimit(3) }
                            // Unciv ModInfoAndActionPane: who wrote it, its size, a way to its page and "{Updated}: " with
                            // pushed_at through parseDate and formatDate ("yyyy-MM-dd HH:mm")
                            if let a = r.owner?.login { Text(L("Author: [\(a)]")).font(Theme.small).foregroundStyle(Theme.creamDim) }
                            if let kB = repoSizes[r.folderName] { Text(L(ModDownloader.sizeText(kB))).font(Theme.small).foregroundStyle(Theme.creamDim) }
                            else { Color.clear.frame(height: 0).task { if repoSizes[r.folderName] == nil, let kB = await ModDownloader.repoSize(r) { repoSizes[r.folderName] = kB } } }
                            if let link = URL(string: r.html_url) { Link(L("Open Github page"), destination: link).font(Theme.small).foregroundStyle(Theme.gold) }
                            if let u = r.pushed_at, !u.isEmpty, let d = UncivDateFormat.parseDate(u) { Text(L("Updated") + ": " + UncivDateFormat.formatDate(d)).font(Theme.small).foregroundStyle(Theme.creamDim) }
                            // Unciv onlineButtonAction: "Update [name]" for one pushed since, else "Download [name]"
                            Button(outdated ? L("Update [\(Self.cleanModName(r.folderName))]") : L("Download [\(Self.cleanModName(r.folderName))]")) { install(r) }
                                .buttonStyle(ThemedButtonStyle(filled: outdated, compact: true)).disabled(busy)
                        }
                        Divider2()
                    }
                    // Unciv markOnlineQueryIncomplete: a red label that queries the whole list again when tapped
                    if incomplete { Button { loadOnlineMods() } label: { Text(L("Online query result is incomplete")).font(Theme.caption).foregroundStyle(Theme.danger) }.buttonStyle(.plain) }
                }
            }
        }
        .onAppear { if repos.isEmpty { loadOnlineMods() } }
        // Unciv ConfirmPopup(question, confirmText = "Delete [name]", isConfirmPositive = false), then "[name] was deleted."
        .confirmationDialog(L("Are you SURE you want to delete this mod?"), isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button(L("Delete [\(Self.cleanModName(pendingRemoval ?? ""))]"), role: .destructive) {
                // Unciv ModManagementScreen.deleteMod: the folder goes and RulesetCache forgets the mod - the permanent
                // audiovisual choice stays, so a mod downloaded again is still one ("re-evaluate here or remove the
                // setting in the delete code" - Unciv keeps it). Ours dropped it from visualMods.
                if let m = pendingRemoval { ModDownloader.remove(m); Ruleset.clearModOptionsCache(); installed = Ruleset.availableMods(); checkResults[m] = nil; Translations.shared.reloadModTranslations(); status = L("[\(Self.cleanModName(m))] was deleted.") }
                pendingRemoval = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingRemoval = nil }
        }
    }

    private func check(_ mod: String) {
        checking = mod
        RulesetValidator.validateInBackground(mod: mod) { result in checkResults[mod] = result; checking = nil }
    }
    /// Unciv ModManagementScreen.refreshOnlineModTable: the whole online list, filtered by ModUIData.matchesFilter
    /// (the category through the repository's topics, the text in the name or the author) and sorted here - Stars
    /// (most first, then the name), Date (the latest push first) or Name. (Unciv also skips the authors of the
    /// player's own excludedModAuthors file, which Epochs does not have.)
    private var sortedOnline: [ModDownloader.Repo] {
        let matching = repos.filter { ModDownloader.matchesFilter(name: $0.folderName, author: $0.owner?.login ?? "", topics: $0.topics ?? [], text: filterText, topic: category) }
        func byName(_ a: ModDownloader.Repo, _ b: ModDownloader.Repo) -> ComparisonResult { a.folderName.compare(b.folderName, options: .caseInsensitive) }
        // an online entry's ModUIData: not visual, hasUpdate once an installed copy is older (stateSortWeight 2 or 0)
        func weight(_ r: ModDownloader.Repo) -> Int { installed.contains(r.folderName) && ModDownloader.installedIsOutdated(r) ? 2 : 0 }
        switch sortOnline {
        case .name: return matching.sorted { byName($0, $1) == .orderedAscending }
        case .nameDesc: return matching.sorted { byName($1, $0) == .orderedAscending }
        case .date: return matching.sorted { ($0.pushed_at ?? "") < ($1.pushed_at ?? "") }   // Unciv sortByDate: lastUpdated() = pushed_at
        case .dateDesc: return matching.sorted { ($0.pushed_at ?? "") > ($1.pushed_at ?? "") }
        case .status: return matching.sorted { a, b in weight(a) != weight(b) ? weight(a) > weight(b) : byName(a, b) == .orderedAscending }
        // Unciv sortByStars: `10 * (stars2 - stars1) + name1.compareTo(name2, true).sign`
        case .stars: return matching.sorted { a, b in a.stargazers_count != b.stargazers_count ? a.stargazers_count > b.stargazers_count : byName(a, b) == .orderedAscending }
        }
    }
    /// Unciv ModManagementScreen.reloadOnlineMods: every page of the unciv-mod repositories, once; filters and sorts then
    /// work on that list without asking GitHub again.
    private func loadOnlineMods() {
        // Unciv tryDownloadPage: nothing is shown while the pages come in, and a failing query is only logged
        busy = true; status = nil; repos = []; incomplete = false
        Task {
            do { incomplete = try await ModDownloader.fetchAllMods { page in repos += page } }
            catch { print("Could not download mod list: \(error)") }
            busy = false
        }
    }
    private func installFromURL() {
        // Unciv getDownloadFromUrlButton: "Downloading...", "«RED»{Invalid link!}«»" for a link Repo.parseUrl cannot read,
        // else downloadMod's messages ("Could not download [name]" with the repository's name)
        busy = true; status = L("Downloading...")
        let repoName = URL(string: modURL.trimmingCharacters(in: .whitespacesAndNewlines))?.pathComponents.filter { $0 != "/" }.dropFirst().first ?? modURL
        Task { @MainActor in
            do { let name = try await ModDownloader.installFromURL(modURL); await afterDownload(name); modURL = "" }
            catch let e as URLError where e.code == .badURL { status = L("Invalid link!") }
            catch let e as ModDownloader.ModError { status = e.errorDescription }
            catch { status = L("Could not download [\(repoName)]") }
            busy = false
        }
    }
    private func install(_ r: ModDownloader.Repo) {
        busy = true; status = L("Downloading...")
        Task {
            // Unciv ModManagementScreen.downloadMod: an UncivShowableException's own message, anything else
            // "Could not download [name]" (ours: "Install failed: " and the system's English error text)
            do { let name = try await ModDownloader.install(r); await afterDownload(name) }
            catch let e as ModDownloader.ModError { status = e.errorDescription }
            catch { status = L("Could not download [\(r.folderName)]") }
            busy = false
        }
    }
    /// Unciv ModManagementScreen.downloadMod once the files are in place: reloadCachesAfterModChange - the mod's
    /// ruleset loaded again (RulesetCache.reloadSingleRuleset); a mod that fails to load is reported "{[name] was
    /// downloaded, but is defective!}\n{For more information, see Options-Locate mod errors.}" - then a mod whose
    /// ModOptions has "Should only be used as permanent audiovisual mod" joins visualMods. Ours only unpacked the files:
    /// a music or sound mod of that kind stayed silent until the player found the toggle.
    private func afterDownload(_ name: String) async {
        Ruleset.clearModOptionsCache()
        let base = Ruleset.currentBaseRuleset
        let defective = await Task.detached { (try? Ruleset(named: base, mods: [name])) == nil }.value
        if Ruleset.modOptionUniques(of: name).contains(where: { $0.pattern == "Should only be used as permanent audiovisual mod" }), !UserSettings.visualMods.contains(name) {
            UserSettings.visualMods = UserSettings.visualMods + [name]
        }
        installed = Ruleset.availableMods()
        Translations.shared.reloadModTranslations()   // Unciv reloadCachesAfterModChange: tryReadTranslationForCurrentLanguage
        status = defective ? L("{[\(name)] was downloaded, but is defective!}") + "\n" + L("{For more information, see Options-Locate mod errors.}") : L("[\(name)] Downloaded!")
    }
    /// Unciv ModDecoratedButton: the categories but All mods whose topic the mod has, in ModCategories order, joined with ", "
    static func categoryText(_ topics: [String]) -> String {
        ModDownloader.categories.dropFirst().filter { topics.contains($0.topic) }.map { L($0.label) }.joined(separator: ", ")
    }
}
