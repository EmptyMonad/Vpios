// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UniformTypeIdentifiers

/// Unciv MultiplayerScreen: the list of online games, "Add multiplayer game", "Copy user ID", "Refresh list", per-game "Copy game ID" / "Delete", and "Join game".
struct MultiplayerView: View {
    @Binding var settings: GameSettings
    let onOpen: (GameState) -> Void
    let onClose: () -> Void
    @State private var games = Multiplayer.knownGames
    /// Unciv MultiplayerFiles' game previews, shared with the in-game status popup
    @ObservedObject private var mp = MultiplayerStatus.shared
    /// Unciv MultiplayerScreen: a MultiplayerAuthException opens AuthPopup, and the action runs again once it succeeds
    @State private var authRetry: (() -> Void)? = nil
    @State private var selected: String? = nil
    @State private var status: String? = nil
    @State private var busy = false
    @State private var showAdd = false
    @State private var addId = ""
    @State private var addName = ""
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmResign = false
    @State private var confirmSkip = false
    @State private var confirmForce = false
    @State private var showHelp = false
    @State private var confirmDelete = false
    @State private var showFriends = false

    var body: some View {
        ThemedSheet(L("Multiplayer"), subtitle: Multiplayer.serverURL.isEmpty ? L("No server address set.") : Multiplayer.serverURL, onClose: { if !busy { onClose() } }) {
            if Multiplayer.serverURL.isEmpty { Text(L("Set the server address in Options > Multiplayer first.")).font(Theme.caption).foregroundStyle(Theme.danger) }
            HStack(spacing: 6) {
                Button(L("Copy user ID")) { UIPasteboard.general.string = Multiplayer.userId; status = L("UserID copied to clipboard") }.buttonStyle(ThemedButtonStyle(compact: true))
                Button(L("Add multiplayer game")) { showAdd = true }.buttonStyle(ThemedButtonStyle(compact: true))
                Button(L("Refresh list")) { refresh() }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(busy || mp.loading)
                Button(L("Help")) { showHelp = true }.buttonStyle(ThemedButtonStyle(compact: true))   // Unciv MultiplayerScreen.setupHelpButton
                Button(L("Friends list")) { showFriends = true }.buttonStyle(ThemedButtonStyle(compact: true))   // Unciv MultiplayerScreen friends list button
            }
            if showAdd {
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Add multiplayer game")).font(Theme.heading(14)).foregroundStyle(Theme.gold)
                        TextField(L("GameID"), text: $addId).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Text(L("Game name")).font(Theme.small).foregroundStyle(Theme.creamDim)   // Unciv AddMultiplayerGameScreen
                        TextField(L("Game name"), text: $addName).textFieldStyle(.roundedBorder)
                        HStack {
                            Button(L("Paste gameID from clipboard")) { addId = UIPasteboard.general.string ?? "" }.buttonStyle(ThemedButtonStyle(compact: true))
                            Button(L("Save game")) { join(addId) }.buttonStyle(ThemedButtonStyle(filled: true, compact: true)).disabled(addId.isEmpty || busy)
                        }
                    }
                }
            }
            if let sel = selected {
                HStack(spacing: 6) {
                    Button(L("Copy game ID")) { UIPasteboard.general.string = sel; status = L("Game ID copied to clipboard!") }.buttonStyle(ThemedButtonStyle(compact: true))
                    Button(L("Rename")) { renameText = Multiplayer.gameNames[sel] ?? ""; renaming = true }.buttonStyle(ThemedButtonStyle(compact: true))
                    Button(L("Delete save")) { confirmDelete = true }.buttonStyle(ThemedButtonStyle(destructive: true, compact: true))
                }
                if let p = mp.previews[sel] {
                    let mine = Multiplayer.isMyTurn(p)
                    // Unciv selectGame: `weAreAPlayer = userId in preview.civilizations.map { it.playerId }`
                    let iPlay = p.civs.contains { $0.playerUserId == Multiplayer.userId }
                    let idle = Multiplayer.minutesInactive(p)
                    HStack(spacing: 6) {
                        if mine {
                            Button(L("Resign")) { confirmResign = true }.buttonStyle(ThemedButtonStyle(destructive: true, compact: true)).disabled(busy)
                        }
                        if !mine && iPlay && idle > Double(p.settings.minutesUntilSkipTurn) {
                            Button(L("Skip turn of current player")) { confirmSkip = true }.buttonStyle(ThemedButtonStyle(destructive: true, compact: true)).disabled(busy)
                        }
                        // Unciv MultiplayerScreen: `durationInactive > Duration.ofMinutes(currentPlayerCiv.playerMinutesBeforeForceResign)` -
                        // the current player's own pool, not the game's full allowance
                        if !mine && iPlay && idle > Double(p.currentHuman?.playerMinutesBeforeForceResign ?? 0) {
                            Button(L("Force current player to resign")) { confirmForce = true }.buttonStyle(ThemedButtonStyle(destructive: true, compact: true)).disabled(busy)
                        }
                    }
                }
                Button { open(sel) } label: { Label(L("Join game"), systemImage: "play.fill") }.buttonStyle(ThemedButtonStyle(filled: true)).disabled(busy)
                // Unciv MultiplayerScreen.selectGame: descriptionLabel = MultiplayerHelpers.buildDescriptionText
                Text(MultiplayerHelpers.descriptionText(sel)).font(Theme.caption).foregroundStyle(Theme.creamDim).fixedSize(horizontal: false, vertical: true)
            }
            if busy || mp.loading { ProgressView().tint(Theme.gold) }
            if let s = status { Text(s).font(Theme.caption).foregroundStyle(Theme.gold) }
            SectionTitle(L("Games"))
            if games.isEmpty { Text(L("No games yet. Start one from New Game with 'Online Multiplayer' or add one by its ID.")).font(Theme.caption).foregroundStyle(Theme.creamDim) }
            Panel(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Multiplayer.sortedGames(games, previews: mp.previews), id: \.self) { g in
                        let p = mp.previews[g]
                        let mine = p.map { Multiplayer.isMyTurn($0) } ?? false
                        // the turn is Unciv's zero-based GameInfoPreview.turns
                        ThemedRow(title: Multiplayer.name(of: g), detail: p.map { "\($0.currentPlayer) · \(L("Turn")) \($0.uncivTurns)" + (mine ? " · \(L("Your turn"))" : " · \(L("Waiting for [\($0.currentPlayer)]"))") } ?? L("Not refreshed yet"), selected: selected == g, action: { selected = g }, leading: {
                            // Unciv GameDisplay: the turn indicator, and the error indicator for a game whose refresh failed
                            ZStack(alignment: .bottomTrailing) {
                                Image(systemName: mine ? "flag.fill" : "hourglass").foregroundStyle(mine ? Theme.good : Theme.creamDim)
                                if mp.refreshErrors[g] != nil { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.danger) }
                            }
                        }, trailing: { EmptyView() })
                    }
                }
            }
        }
        .onAppear { refresh() }
        // Unciv's "Working..." and "Loading latest game state..." are popups over the screen (MultiplayerScreen.resignPlayer,
        // skipCurrentPlayerTurn, MultiplayerHelpers.loadMultiplayerGame): nothing else is reached until they close, so no
        // other game is loaded - and the shared ruleset rebuilt - while a resigned or skipped turn is played on its thread
        .interactiveDismissDisabled(busy)
        // Unciv MultiplayerScreen help popup: the five lines it shows, in its order.
        .sheet(isPresented: $showHelp) {
            ThemedSheet(L("Help"), subtitle: nil, onClose: { showHelp = false }) {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("To create a multiplayer game, check the 'multiplayer' toggle in the New Game screen, and for each human player insert that player's user ID.")).font(Theme.body)
                        Text(L("You can assign your own user ID there easily, and other players can copy their user IDs here and send them to you for you to include them in the game.")).font(Theme.body)
                        Text(L("Once you've created your game, the Game ID gets automatically copied to your clipboard so you can send it to the other players.")).font(Theme.body)
                        Text(L("Players can enter your game by copying the game ID to the clipboard, and clicking on the 'Add multiplayer game' button")).font(Theme.body)
                        Text(L("The symbol of your nation will appear next to the game when it's your turn")).font(Theme.body)
                    }
                }
            }
            .immersiveSystemUI()
        }
        // Unciv MultiplayerScreen.rename: a name field with the current name, saved with the Save button.
        .sheet(isPresented: $renaming) {
            ThemedSheet(L("Rename"), subtitle: selected, onClose: { renaming = false }) {
                Panel {
                    VStack(spacing: 8) {
                        TextField(L("Game name"), text: $renameText).textFieldStyle(.roundedBorder).font(Theme.body)
                        Button(L("Save")) {
                            if let sel = selected { Multiplayer.rename(sel, to: renameText) }
                            renaming = false
                        }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                    }
                }
            }
            .immersiveSystemUI()
        }
        // Unciv MultiplayerScreen: each button names the preview's current player (`preview.currentPlayer`) - Resign as
        // both the civ and who is responsible, Skip and Force resign with getOurCivNameOrPlayerId as the responsible one
        .confirmationDialog(L("Are you sure you ([\(mp.previews[selected ?? ""]?.currentPlayer ?? "?")]) want to resign?"), isPresented: $confirmResign, titleVisibility: .visible) {
            Button(L("Resign"), role: .destructive) { if let sel = selected, let p = mp.previews[sel] { resignPlayer(sel, preview: p, playerCiv: p.currentPlayer, responsible: p.currentPlayer) } }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("Are you sure you want to skip the turn of [\(mp.previews[selected ?? ""]?.currentPlayer ?? "?")]?"), isPresented: $confirmSkip, titleVisibility: .visible) {
            Button(L("Yes"), role: .destructive) { if let sel = selected, let p = mp.previews[sel] { skipCurrentPlayerTurn(sel, preview: p, playerToSkip: p.currentPlayer, responsible: Multiplayer.ourCivNameOrPlayerId(p)) } }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("Are you sure you want to force the current player ([\(mp.previews[selected ?? ""]?.currentPlayer ?? "?")]) to resign?"), isPresented: $confirmForce, titleVisibility: .visible) {
            Button(L("Yes"), role: .destructive) { if let sel = selected, let p = mp.previews[sel] { resignPlayer(sel, preview: p, playerCiv: p.currentPlayer, responsible: Multiplayer.ourCivNameOrPlayerId(p)) } }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("Are you sure you want to delete this save?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Delete save"), role: .destructive) { if let s = selected { Multiplayer.forget(s); SaveManager.delete(name: "online-\(s)"); games = Multiplayer.knownGames; selected = nil } }
            Button(L("Cancel"), role: .cancel) {}
        }
        .overlay { if showFriends { FriendListPanel(onClose: { showFriends = false }) } }
        .overlay { if authRetry != nil { AuthPopupView { ok in let retry = authRetry; authRetry = nil; if ok { retry?() } } } }
    }

    /// Unciv MultiplayerScreen "Refresh list": Multiplayer.requestUpdate() - every game's preview.
    private func refresh() {
        games = Multiplayer.knownGames
        guard !Multiplayer.serverURL.isEmpty, !games.isEmpty else { return }
        mp.refresh(currentGameId: nil)
    }

    /// Unciv MultiplayerScreen.resignPlayer: "Working...", then the message Multiplayer.resignPlayer returns (none when
    /// it went through) or LoadGameScreen.getLoadExceptionMessage; a MultiplayerAuthException opens AuthPopup instead,
    /// and a successful authentication runs the resignation again.
    private func resignPlayer(_ gameId: String, preview: GamePreview, playerCiv: String, responsible: String) {
        busy = true; status = L("Working...")
        Task {
            do {
                let r = try await Multiplayer.resignPlayer(gameId: gameId, previewCurrentPlayer: preview.currentPlayer, playerCivName: playerCiv, responsibleCivNameOrPlayerId: responsible)
                mp.updatePreview(gameId, GamePreview(r.state))   // Unciv game.updatePreview, in sync or not
                status = r.message.isEmpty ? nil : L(r.message)
            } catch Multiplayer.MPError.auth {
                status = nil
                authRetry = { resignPlayer(gameId, preview: preview, playerCiv: playerCiv, responsible: responsible) }
            } catch { status = MultiplayerHelpers.loadExceptionMessage(error) }
            busy = false
        }
    }
    /// Unciv MultiplayerScreen.skipCurrentPlayerTurn: as resignPlayer, with Multiplayer.skipCurrentPlayerTurn's message.
    private func skipCurrentPlayerTurn(_ gameId: String, preview: GamePreview, playerToSkip: String, responsible: String) {
        busy = true; status = L("Working...")
        Task {
            do {
                let r = try await Multiplayer.skipCurrentPlayerTurn(gameId: gameId, previewCurrentPlayer: preview.currentPlayer, playerCivName: playerToSkip, responsibleCivNameOrPlayerId: responsible)
                if let st = r.state { mp.updatePreview(gameId, GamePreview(st)) }
                status = r.message.map { L($0) }
            } catch Multiplayer.MPError.auth {
                status = nil
                authRetry = { skipCurrentPlayerTurn(gameId, preview: preview, playerToSkip: playerToSkip, responsible: responsible) }
            } catch { status = MultiplayerHelpers.loadExceptionMessage(error) }
            busy = false
        }
    }

    /// Unciv AddMultiplayerGameScreen: IdChecker.checkAndReturnUuiId must give a UUID ("Invalid game ID!"), then
    /// "Working..." and Multiplayer.addGame; a failure shows LoadGameScreen.getLoadExceptionMessage.
    private func join(_ text: String) {
        guard let id = IdChecker.checkAndReturnUuiId(text), IdChecker.isUUID(id) else { status = L("Invalid game ID!"); return }
        let name = addName
        busy = true; status = L("Working...")
        Task {
            do {
                let st = try await Multiplayer.join(gameId: id)
                Multiplayer.rename(id, to: name); addName = ""   // Unciv addGame(gameId, gameName): saved under the name given, else the id
                try? SaveManager.save(st, name: "online-\(id)")
                games = Multiplayer.knownGames; mp.previews[id] = GamePreview(st)
                showAdd = false; addId = ""; status = nil
            }
            catch { status = MultiplayerHelpers.loadExceptionMessage(error) }
            busy = false
        }
    }
    /// Unciv MultiplayerHelpers.loadMultiplayerGame: "Loading latest game state...", Multiplayer.downloadGame (the
    /// newer preview, the spectate check), else the load exception.
    private func open(_ id: String) {
        busy = true; status = L("Loading latest game state...")
        Task {
            do { let st = try await MultiplayerHelpers.downloadGame(id); busy = false; status = nil; onOpen(st) }
            catch { status = MultiplayerHelpers.loadExceptionMessage(error); busy = false }
        }
    }
}


/// Unciv FriendListPopup / AddFriendScreen / EditFriendScreen: the friends with Edit and delete, and the fields to add one
struct FriendListPanel: View {
    let onClose: () -> Void
    @State private var friendName = ""
    @State private var friendId = ""
    @State private var friends = UserSettings.friends
    @State private var editingFriend: Int? = nil
    @State private var deletingFriend: Int? = nil
    @State private var friendMessage: String? = nil
    /// Unciv EditFriendScreen's Delete closes the edit screen (`friendlist.delete(selectedFriend); goBack()`) and its Save
    /// edits by the Friend itself (FriendList.edit), never by a position: deleting the friend being edited ends the edit,
    /// deleting one above it moves its position with it. Ours kept the position, and Save wrote past the end of the list.
    nonisolated static func editingAfterDelete(_ editing: Int?, deleted i: Int) -> Int? {
        guard let e = editing else { return nil }
        return e == i ? nil : e > i ? e - 1 : e
    }
    /// Unciv AddFriendScreen / EditFriendScreen: the same checks and the same messages
    private func saveFriend() {
        let n = friendName.trimmingCharacters(in: .whitespaces)
        let id = friendId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { friendMessage = "You have to write a name for your friend!"; return }
        guard !id.isEmpty else { friendMessage = "You have to write an ID for your friend!"; return }
        guard UUID(uuidString: id) != nil else { friendMessage = "Player ID is incorrect"; return }
        guard id != Multiplayer.userId else { friendMessage = "You cannot add your own player ID in your friend list!"; return }
        let others = friends.enumerated().filter { $0.offset != editingFriend }.map { $0.element }
        guard !others.contains(where: { $0.name == n }) else { friendMessage = "Friend name is already in your friends list!"; return }
        guard !others.contains(where: { $0.id == id }) else { friendMessage = "Player ID is already in your friends list!"; return }
        // (Unciv FriendList.edit: `remove(friend)` of a friend no longer listed does nothing, the `add` still happens)
        if let i = editingFriend, friends.indices.contains(i) { friends[i] = (name: n, id: id) } else { friends.append((name: n, id: id)) }
        UserSettings.friends = friends
        editingFriend = nil; friendName = ""; friendId = ""; friendMessage = nil
    }
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().bleedIntoCutout().onTapGesture { if !UserSettings.neverCloseByTapOutside { onClose() } }   // Unciv forbidPopupClickBehindToClose
            Panel(highlighted: true) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(L("Friends list")).font(Theme.heading(16)).foregroundStyle(Theme.gold); Spacer(); Button { onClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gold) }.buttonStyle(.plain) }
                        ForEach(Array(friends.enumerated()), id: \.offset) { i, f in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) { Text(f.name).font(Theme.body); Text(f.id).font(Theme.small).foregroundStyle(Theme.creamDim).lineLimit(1).truncationMode(.middle) }
                                Spacer()
                                Button(L("Edit friend")) { editingFriend = i; friendName = f.name; friendId = f.id }.buttonStyle(ThemedButtonStyle(compact: true))
                                Button { deletingFriend = i } label: { Image(systemName: "trash") }.buttonStyle(ThemedButtonStyle(destructive: true, compact: true))
                            }
                        }
                        HStack(spacing: 6) {
                            TextField(L("Friend name"), text: $friendName).textFieldStyle(.roundedBorder).font(Theme.caption)
                            TextField(L("Player ID"), text: $friendId).textFieldStyle(.roundedBorder).font(Theme.caption).autocorrectionDisabled().textInputAutocapitalization(.never)
                        }
                        HStack(spacing: 6) {
                            Button(L("Paste player ID from clipboard")) { friendId = UIPasteboard.general.string ?? "" }.buttonStyle(ThemedButtonStyle(compact: true))
                            Button(L(editingFriend == nil ? "Add friend" : "Save")) { saveFriend() }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                            if editingFriend != nil { Button(L("Cancel")) { editingFriend = nil; friendName = ""; friendId = "" }.buttonStyle(ThemedButtonStyle(compact: true)) }
                        }
                        if let m = friendMessage { Text(L(m)).font(Theme.small).foregroundStyle(Theme.danger) }
                    }
                }
            }
            .frame(maxWidth: 520, maxHeight: 360).padding(20)
            .confirmationDialog(L("Are you sure you want to delete this friend?"), isPresented: Binding(get: { deletingFriend != nil }, set: { if !$0 { deletingFriend = nil } }), titleVisibility: .visible) {
                Button(L("Delete"), role: .destructive) {
                    if let i = deletingFriend, friends.indices.contains(i) {
                        friends.remove(at: i); UserSettings.friends = friends
                        if editingFriend == i { friendName = ""; friendId = ""; friendMessage = nil }   // Unciv goBack: the edit screen goes
                        editingFriend = FriendListPanel.editingAfterDelete(editingFriend, deleted: i)
                    }
                    deletingFriend = nil
                }
                Button(L("Cancel"), role: .cancel) { deletingFriend = nil }
            }
        }
    }
}
