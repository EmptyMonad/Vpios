// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UniformTypeIdentifiers

/// Unciv LoadGameScreen: the save list on the left, "Load [name]" plus the side buttons on the right.
struct LoadGameScreen: View {
    let onLoad: (GameState) -> Void
    let onClose: () -> Void
    @State private var saves: [SaveManager.SaveInfo] = []
    @State private var selected: SaveManager.SaveInfo? = nil
    @State private var showAutosaves = UserSettings.showAutosaves
    /// Unciv errorLabel (red, hidden when a save is selected) and descriptionLabel (the save's info, the delete
    /// result, the mod download progress)
    @State private var errorText: String? = nil
    @State private var descriptionText: String? = nil
    @State private var busy = false
    @State private var pasting = false
    @State private var loadingCustom = false
    @State private var showImporter = false
    @State private var confirmDelete = false
    @State private var cantLoadPopup = false
    @State private var toast: String? = nil

    var body: some View {
        ThemedSheet(L("Load game"), subtitle: nil, onClose: onClose) {
            if let sel = selected {
                Button { load(sel.name) } label: { Label(L("Load [\(sel.name)]"), systemImage: "play.fill") }.buttonStyle(ThemedButtonStyle(filled: true)).disabled(busy)
            }
            if let d = descriptionText {
                Panel(highlighted: selected != nil) { Text(d).font(Theme.caption).foregroundStyle(Theme.creamDim).frame(maxWidth: .infinity, alignment: .leading) }
            }
            HStack(spacing: 6) {
                Button(pasting ? L("Working...") : L("Load copied data")) { loadClipboard() }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(pasting)
                Button(loadingCustom ? L("Loading...") : L("Load from custom location")) { errorText = nil; loadingCustom = true; showImporter = true }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(loadingCustom)
            }
            if let e = errorText { Text(e).font(Theme.caption).foregroundStyle(Theme.danger).multilineTextAlignment(.center).frame(maxWidth: .infinity) }
            HStack(spacing: 6) {
                Button(L("Delete save")) { confirmDelete = true }.buttonStyle(ThemedButtonStyle(destructive: true, compact: true)).disabled(selected == nil)
                Button(L("Copy saved game to clipboard")) { copySelected() }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(selected == nil)
            }
            Button { showAutosaves.toggle(); UserSettings.showAutosaves = showAutosaves; reload() } label: {
                HStack(spacing: 6) { Image(systemName: showAutosaves ? "checkmark.square.fill" : "square").foregroundStyle(Theme.gold); Text(L("Show autosaves")).font(Theme.body) }
            }.buttonStyle(.plain)
            if busy { ProgressView().tint(Theme.gold) }
            // Unciv LoadGameScreen is LoadOrSaveScreen() - no fileListHeaderText (SaveGameScreen's "Current saves"), and an
            // empty list is just empty
            Panel(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(saves) { s in
                        ThemedRow(title: s.name, detail: "", selected: selected?.name == s.name, action: { select(s) }, leading: {
                            Image(systemName: SaveManager.isAutosave(s.name) ? "clock.arrow.circlepath" : "scroll.fill").foregroundStyle(Theme.gold)
                        }, trailing: { EmptyView() })
                        .simultaneousGesture(TapGesture(count: 2).onEnded { select(s); load(s.name) })   // Unciv doubleClickAction
                    }
                }
            }
        }
        .onAppear { reload() }
        .confirmationDialog(L("Are you sure you want to delete this save?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            // Unciv onDeleteClicked → resetWindowState: the list reloads, the result goes to the description
            Button(L("Delete save"), role: .destructive) { if let s = selected { let result = SaveManager.deleteWithResult(name: s.name); selected = nil; reload(); descriptionText = result } }
            Button(L("Cancel"), role: .cancel) {}
        }
        // Unciv handleLoadGameException: a problem the player cannot fix asks for the game data
        .alert(L("It looks like your saved game can't be loaded!"), isPresented: $cantLoadPopup) {
            Button(L("Close"), role: .cancel) {}
        } message: {
            Text([L("If you could copy your game data (\"Copy saved game to clipboard\" - "), L(SupportContact.pasteLine),
                  L("I could maybe help you figure out what went wrong, since this isn't supposed to happen!")].joined(separator: "\n"))
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .plainText, .data], allowsMultipleSelection: false) { result in
            defer { loadingCustom = false }
            switch result {
            case .failure(let error): handleLoadError(error, primary: "Could not load game from custom location!")
            case .success(let urls):
                guard let url = urls.first else { return }   // Unciv PlatformSaverLoader.Cancelled: nothing to say
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do { onLoad(try SaveManager.load(data: try Data(contentsOf: url))) }
                catch { handleLoadError(error, primary: "Could not load game from custom location!") }
            }
        }
        .onChange(of: showImporter) { _, open in if !open { DispatchQueue.main.async { loadingCustom = false } } }
        .overlay { LoadingOverlay(active: busy) }
        .overlay(alignment: .bottom) { ToastView(text: $toast) }
        .screenShown("load_game")
    }

    /// Unciv LoadOrSaveScreen.selectExistingSave: the error goes away, the save's info shows
    private func select(_ s: SaveManager.SaveInfo) {
        errorText = nil; selected = s
        descriptionText = saveDescription(s)
    }
    private func saveDescription(_ s: SaveManager.SaveInfo) -> String {
        // Unciv LoadOrSaveScreen.showSaveInfo: name, "Saved at", "civs, difficulty, ⏳turns", "Base ruleset:" (+ "Mods:")
        if s.civs.isEmpty && s.difficulty.isEmpty { return L("Could not load game!") }
        return [s.name, "\(L("Saved at")): \(UncivDateFormat.formatDate(s.date))", "\(s.civs.map { L($0) }.joined(separator: ", ")), \(L(s.difficulty)), ⏳\(s.turn)",
                "\(L("Base ruleset:")) \(L(s.baseRuleset))" + (s.mods.isEmpty ? "" : "\n\(L("Mods:")) \(Ruleset.shownModList(s.mods))")].joined(separator: "\n")
    }
    private func reload() { saves = SaveManager.list(includeAutosaves: showAutosaves) }
    private func load(_ name: String) {
        busy = true; errorText = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            do { let g = try SaveManager.load(name: name); GameEvents.post(.gameLoaded(g, source: "save")); onLoad(g) }
            catch { handleLoadError(error) }
            busy = false
        }
    }
    /// Unciv handleLoadGameException: the message under the buttons; the popup for what the player cannot fix;
    /// missing mods start downloading at once.
    private func handleLoadError(_ error: Error, primary: String = "Could not load game!") {
        let (text, fixable) = SaveManager.loadExceptionMessage(error, primary: primary)
        errorText = text
        if !fixable { cantLoadPopup = true }
        if let missing = error as? SaveManager.MissingMods { downloadMissingMods(missing.names) }
    }

    /// Unciv loadMissingModsAsync → Helpers.loadMissingMods: each name is found on GitHub and installed; the
    /// description counts them off, and at the end a toast says so and the error goes away (the game is not loaded).
    private func downloadMissingMods(_ names: [String]) {
        descriptionText = L("Loading...")
        Task {
            var failures: [String] = []
            for name in names {
                do {
                    let query = name.replacingOccurrences(of: " ", with: "-")
                    // Unciv getRepo: Github.tryGetGithubReposWithTopic(1, 10, repoName)
                    guard let repo = try await ModDownloader.fetchPage(1, amountPerPage: 10, search: query).items.first(where: { $0.folderName.lowercased() == name.lowercased() || $0.name.lowercased() == query.lowercased() }) else {
                        failures.append(L("Could not find a mod named \"[\(name)]\".")); continue
                    }
                    _ = try await ModDownloader.install(repo)
                    await MainActor.run { descriptionText = (descriptionText ?? "") + "\n" + L("[\(repo.name)] Downloaded!") }
                } catch { failures.append(error.localizedDescription) }
            }
            await MainActor.run {
                descriptionText = nil
                if failures.isEmpty {
                    // Unciv RulesetCache.loadRulesets: the mods are read again; the running game's ruleset is left alone
                    Ruleset.clearModOptionsCache()
                    errorText = nil
                    toast = L("Missing mods are downloaded successfully.")
                } else {
                    errorText = L("Could not load the missing mods!") + "\n" + failures.joined(separator: "\n")
                }
            }
        }
    }
    /// Unciv getLoadFromClipboardButton: nothing happens with an empty clipboard; "Working..." while it loads
    private func loadClipboard() {
        guard UIPasteboard.general.hasStrings else { return }
        pasting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            defer { pasting = false }
            do { let g = try SaveManager.loadFromClipboard(); GameEvents.post(.gameLoaded(g, source: "clipboard")); onLoad(g) } catch { handleLoadError(error, primary: "Could not load game from clipboard!") }
        }
    }
    /// Unciv copySavedGameToClipboard: the file itself, with the "'[name]' copied to clipboard!" toast
    private func copySelected() {
        guard let s = selected else { return }
        toast = SaveManager.copySaveFileToClipboard(name: s.name) ? L("'[\(s.name)]' copied to clipboard!") : L("Could not save game to clipboard!")
    }
}

/// Unciv SaveGameScreen: "Current saves" list, name field, Save game / Copy to clipboard / Save to custom location / Delete save.
struct SaveGameScreen: View {
    @ObservedObject var controller: GameController
    let onClose: () -> Void
    @State private var name: String = ""
    @State private var saves: [SaveManager.SaveInfo] = []
    @State private var selected: SaveManager.SaveInfo? = nil
    @State private var showAutosaves = UserSettings.showAutosaves
    @State private var description: String? = nil
    @State private var error: String? = nil
    @State private var toast: String? = nil
    @State private var saving = false
    @State private var confirmOverwrite = false
    @State private var confirmDelete = false

    /// Unciv UncivFiles.isValidFileName: not empty, no leading or trailing blank
    private var nameIsValid: Bool { !name.isEmpty && !name.hasPrefix(" ") && !name.hasSuffix(" ") }

    var body: some View {
        ThemedSheet(L("Save game"), subtitle: nil, onClose: onClose) {
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Saved game name")).font(Theme.caption).foregroundStyle(Theme.creamDim)
                    // Unciv fileNameTextFieldFilter: charsForbiddenInFileNames - both path separators and ':'
                    TextField(L("Saved game name"), text: $name).textFieldStyle(.roundedBorder).font(Theme.body)
                        .onChange(of: name) { _, n in let clean = n.filter { !"/\\:".contains($0) }; if clean != n { name = clean } }
                    Button { save() } label: { Label(saving ? L("Saving...") : L("Save game"), systemImage: "scroll.fill") }.buttonStyle(ThemedButtonStyle(filled: true)).disabled(!nameIsValid || saving)
                    HStack(spacing: 6) {
                        Button(L("Copy to clipboard")) { toast = SaveManager.copyToClipboard(controller.state) ? L("Current game copied to clipboard!") : L("Could not save game to clipboard!") }.buttonStyle(ThemedButtonStyle(compact: true))
                        Button(L("Save to custom location")) { SaveManager.exportUncivToCustomLocation(controller.state, name: name) }.buttonStyle(ThemedButtonStyle(compact: true))
                    }
                    if let e = error { Text(e).font(Theme.caption).foregroundStyle(Color.red) }
                    Button(L("Delete save")) { confirmDelete = true }.buttonStyle(ThemedButtonStyle(destructive: true, compact: true)).disabled(selected == nil)
                    Button { showAutosaves.toggle(); UserSettings.showAutosaves = showAutosaves; reload() } label: {
                        HStack(spacing: 6) { Image(systemName: showAutosaves ? "checkmark.square.fill" : "square").foregroundStyle(Theme.gold); Text(L("Show autosaves")).font(Theme.body) }
                    }.buttonStyle(.plain)
                    if let d = description { Text(d).font(Theme.caption).foregroundStyle(Theme.creamDim) }
                }
            }
            SectionTitle(L("Current saves"))
            Panel(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(saves) { s in
                        ThemedRow(title: s.name, detail: "", selected: selected?.name == s.name, action: { select(s) }, leading: {
                            Image(systemName: SaveManager.isAutosave(s.name) ? "clock.arrow.circlepath" : "scroll.fill").foregroundStyle(Theme.gold)
                        }, trailing: { EmptyView() })
                        .simultaneousGesture(TapGesture(count: 2).onEnded { select(s); confirmOverwrite = true })   // Unciv doubleClickAction
                    }
                }
            }
        }
        .onAppear { if name.isEmpty { name = SaveManager.defaultName(for: controller.state) }; reload() }
        .overlay(alignment: .bottom) { ToastView(text: $toast) }
        .confirmationDialog(L("Overwrite existing file?"), isPresented: $confirmOverwrite, titleVisibility: .visible) {
            Button(L("Overwrite"), role: .destructive) { write() }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("Are you sure you want to delete this save?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Delete save"), role: .destructive) {
                if let s = selected { description = SaveManager.deleteWithResult(name: s.name); selected = nil; reload() }
            }
            Button(L("Cancel"), role: .cancel) {}
        }
        .screenShown("save_game")
    }
    /// Unciv LoadOrSaveScreen.selectExistingSave: the delete button, the save's info, its name in the field
    private func select(_ s: SaveManager.SaveInfo) {
        selected = s; error = nil; name = s.name
        description = s.civs.isEmpty && s.difficulty.isEmpty ? L("Could not load game!") :
            "\(s.name)\n\(L("Saved at")): \(UncivDateFormat.formatDate(s.date))\n\(s.civs.map { L($0) }.joined(separator: ", ")), \(L(s.difficulty)), ⏳\(s.turn)\n\(L("Base ruleset:")) \(L(s.baseRuleset))" + (s.mods.isEmpty ? "" : "\n\(L("Mods:")) \(Ruleset.shownModList(s.mods))")
    }
    private func reload() { saves = SaveManager.list(includeAutosaves: showAutosaves) }
    /// Unciv rightSideButton: an existing file asks to overwrite, a new one is saved
    private func save() {
        if SaveManager.exists(name: name) { confirmOverwrite = true } else { write() }
    }
    /// Unciv saveGame: "Saving...", then back to the game, or the error under the buttons
    private func write() {
        saving = true; error = nil
        do { try SaveManager.save(controller.state, name: name); GameEvents.post(.gameSaved(turn: controller.state.turn)); onClose() }
        catch { self.error = "\(L("Could not save game!"))\n\(error.localizedDescription)"; saving = false }
    }
}

/// Unciv ToastPopup: a short message that shows for about two seconds and goes away by itself
struct ToastView: View {
    @Binding var text: String?
    var body: some View {
        if let t = text {
            Text(t).font(Theme.caption).foregroundStyle(Theme.cream).padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Theme.panelDark.opacity(0.95))).overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                .padding(.bottom, 24)
                .task(id: t) { try? await Task.sleep(nanoseconds: 2_000_000_000); if text == t { text = nil } }
        }
    }
}

/// Unciv UncivDateFormat.formatDate: `SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US)` - the same in every language, the
/// device's time zone (LoadOrSaveScreen.showSaveInfo's "Saved at")
enum UncivDateFormat {
    private static let standardFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
    static func formatDate(_ d: Date) -> String { standardFormat.string(from: d) }
    /// UncivDateFormat.parseDate: SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US) - the Z a literal and the zone the
    /// default one, as formatDate's is, so the date reads back with the API's own UTC digits
    private static let utcFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; return f
    }()
    static func parseDate(_ s: String) -> Date? { utcFormat.date(from: s) }
}
