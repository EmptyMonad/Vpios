// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv ChatPopup: header, message list coloured by sender nation, text field + send; global (System) messages are polled in.
struct ChatPopup: View {
    @ObservedObject var controller: GameController
    @ObservedObject var store = ChatStore.shared
    @ObservedObject var chat: ChatStore.Chat
    let onClose: () -> Void
    @State private var text = ""

    init(controller: GameController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
        let id = controller.state.settings.gameId ?? ""
        self.chat = ChatStore.shared.chat(for: id)
    }

    var body: some View {
        let s = controller.state
        ThemedSheet(L("Chat"), subtitle: s.settings.gameId, onClose: onClose) {
            Panel(padding: 8) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(chat.messages) { m in
                                HStack(alignment: .top, spacing: 4) {
                                    Text(m.civName + ":").font(Theme.caption.bold()).foregroundStyle(color(for: m.civName, s))
                                    Text(m.message).font(Theme.caption).foregroundStyle(Theme.cream).fixedSize(horizontal: false, vertical: true)
                                }.id(m.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 160, maxHeight: 260)
                    .onChange(of: chat.messages.count) { _, _ in if let last = chat.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
                    .onAppear { if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack(spacing: 6) {
                TextField(L("Type something..."), text: $text).textFieldStyle(.roundedBorder).font(Theme.body).onSubmit { send() }
                Button { send() } label: { Image(systemName: "paperplane.fill") }.buttonStyle(ThemedButtonStyle(filled: true, compact: true)).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            store.openChatGameId = chat.gameId
            chat.unreadCount = 0
            store.start()
            store.join(gameId: chat.gameId)
            store.pollGlobalMessages { chat.messages.append($0) }
        }
        .onDisappear { store.openChatGameId = nil }
        .onChange(of: store.hasGlobalMessage) { _, has in if has { store.pollGlobalMessages { chat.messages.append($0) } } }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.requestMessageSend(gameId: chat.gameId, civName: controller.state.player.nation, message: t)
        text = ""
    }
    /// Unciv pickNationNameColor: the nation's outer colour unless it is too close to white, else a hash colour.
    private func color(for civName: String, _ s: GameState) -> Color {
        if civName == "System" || civName == "Server" { return Theme.gold }
        if let n = s.rs.nations[civName] {
            let c = n.outerColor
            if c.count >= 3, !(c[0] > 220 && c[1] > 220 && c[2] > 220) { return Color(red: Double(c[0]) / 255, green: Double(c[1]) / 255, blue: Double(c[2]) / 255) }
            if let inner = n.innerColor, inner.count >= 3 { return Color(red: Double(inner[0]) / 255, green: Double(inner[1]) / 255, blue: Double(inner[2]) / 255) }
        }
        let h = Double(abs(civName.hashValue % 360)) / 360
        return Color(hue: h, saturation: 0.6, brightness: 0.9)
    }
}

/// Unciv ChatButton: only for online games on a server with chat (ChatButton.refreshVisibility: `isOnlineMultiplayer &&
/// featureSet.chatVersion > 0`); a badge shows unread messages and the button flashes when one arrives.
struct ChatButton: View {
    @ObservedObject var controller: GameController
    @ObservedObject var store = ChatStore.shared
    @ObservedObject var features = ServerFeatures.shared
    @State private var flash = false
    var body: some View {
        if controller.state.settings.isOnline && features.featureSet.chatVersion > 0 {
            let unread = controller.state.settings.gameId.map { store.chat(for: $0).unreadCount } ?? 0
            Button { controller.showChat = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(flash ? Theme.panelDark : Theme.gold)
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(flash ? AnyShapeStyle(Theme.gold) : AnyShapeStyle(Theme.panelDark)))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1))
                    // Unciv ChatButton.updateBadge: shown with unread messages or a global message, unreadCount.toString()
                    // with a "+" after it for the global message
                    if unread > 0 || store.hasGlobalMessage {
                        Text("\(unread)" + (store.hasGlobalMessage ? "+" : "")).font(.system(size: 8, weight: .black)).foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.danger)).offset(x: 5, y: -5)
                    }
                }
            }
            .onAppear { store.onIndication = { withAnimation(.easeInOut(duration: 0.3).repeatCount(5, autoreverses: true)) { flash = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { flash = false } } }
        }
    }
}

/// Unciv's multiplayer game list (MultiplayerFiles.savedGames of MultiplayerGamePreview): each known game's preview,
/// when it was last refreshed and why the last refresh failed - what MultiplayerScreen, MultiplayerStatusButton and
/// MultiplayerStatusPopup show. The world screen refreshes its own game (GameController.startPolling); this polls the
/// others every allGameRefreshDelay (Unciv Multiplayer.requestUpdate with doNotUpdate = the current game).
@MainActor
final class MultiplayerStatus: ObservableObject {
    static let shared = MultiplayerStatus()
    /// Unciv MultiplayerGamePreview.preview, per game id
    @Published var previews: [String: GamePreview] = [:]
    /// Unciv MultiplayerGamePreview.lastOnlineUpdate: the last update that went through (a failed one leaves it be)
    @Published private(set) var lastRefresh: [String: Date] = [:]
    /// Unciv MultiplayerGamePreview.error: why the last update failed, until one goes through
    @Published private(set) var refreshErrors: [String: String] = [:]
    @Published var loading = false
    /// Unciv UncivGame.isCurrentGame: the game the world screen holds (it stays so from the main menu)
    var currentGameId: String? = nil
    private var timer: Timer?

    /// The known games whose preview says it is our turn (Unciv GameInfoPreview.isUsersTurn)
    var gamesWithCurrentTurn: [String] { Multiplayer.knownGames.filter { previews[$0].map { Multiplayer.isMyTurn($0) } ?? false } }

    /// Unciv MultiplayerGamePreview.getLastUpdate: the later of the game file's time and lastOnlineUpdate.
    func lastUpdate(_ gameId: String) -> Date? {
        let file = (try? FileManager.default.attributesOfItem(atPath: SaveManager.url(for: "online-\(gameId)").path))?[.modificationDate] as? Date
        switch (file, lastRefresh[gameId]) {
        case let (f?, l?): return max(f, l)
        case let (f?, nil): return f
        case let (nil, l): return l
        }
    }

    func startPolling(currentGameId: String?) {
        self.currentGameId = currentGameId
        timer?.invalidate()
        refresh(currentGameId: currentGameId)
        // Unciv Multiplayer.multiplayerGameUpdater: `throttle(lastAllGamesRefresh, multiplayerSettings.allGameRefreshDelay, ...)`
        let seconds = max(1, Multiplayer.allGameRefreshSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh(currentGameId: currentGameId) } }
    }
    func stopPolling() { timer?.invalidate(); timer = nil }
    /// Unciv Multiplayer.requestUpdate(doNotUpdate): every known game but the one given. The periodic refresh plays
    /// no sound - Unciv's MultiplayerGamePreview.update() only stores the preview; the sound is updatePreview's.
    /// (Ours downloaded every whole game, the open one included, and played the other-game sound for each game that
    /// had newly become ours.)
    func refresh(currentGameId: String?) {
        guard !Multiplayer.serverURL.isEmpty else { return }
        loading = true
        Task {
            for g in Multiplayer.knownGames where g != currentGameId { await requestUpdate(g) }
            loading = false
        }
    }
    /// Unciv MultiplayerGamePreview.requestUpdate → update(): the preview is downloaded; one whose turn or current
    /// player moved replaces the stored one (setNewPreview). Either way the error is cleared and lastOnlineUpdate is
    /// now; a failure is kept as the game's error.
    @discardableResult
    func requestUpdate(_ gameId: String) async -> GamePreview? {
        do {
            let p = try await Multiplayer.downloadPreview(gameId)
            lastRefresh[gameId] = Date()
            refreshErrors[gameId] = nil
            if let old = previews[gameId], old.uncivTurns == p.uncivTurns && old.currentPlayer == p.currentPlayer { return p }
            previews[gameId] = p
            return p
        } catch {
            refreshErrors[gameId] = error.localizedDescription
            return nil
        }
    }
    /// Unciv MultiplayerGamePreview.updatePreview (after our upload, a resign, a skip, or a download newer than the
    /// list's): lastOnlineUpdate now, the preview stored and its error cleared, then playMultiplayerTurnNotification -
    /// only when it is our turn, the open game's sound or the other games' one. (Unciv also returns while a
    /// deep-linked game is loading; Epochs opens no game from a turn-notification link.)
    func updatePreview(_ gameId: String, _ preview: GamePreview) {
        lastRefresh[gameId] = Date()
        previews[gameId] = preview
        refreshErrors[gameId] = nil
        guard Multiplayer.isMyTurn(preview) else { return }
        Audio.shared.play(gameId == currentGameId ? Multiplayer.currentGameTurnNotificationSound : Multiplayer.otherGameTurnNotificationSound)
    }
}

struct MultiplayerStatusButton: View {
    @ObservedObject var controller: GameController
    @ObservedObject var status = MultiplayerStatus.shared
    var body: some View {
        let others = status.gamesWithCurrentTurn.filter { $0 != controller.state.settings.gameId }
        Button { controller.showMultiplayerStatus = true } label: {
            HStack(spacing: 3) {
                // Unciv TurnIndicator: only while other games wait for this player, the exclamation mark with their
                // count through tr() in front of it from two games on; then the LoadingImage (multiplayer icon when idle)
                if !others.isEmpty {
                    if others.count >= 2 { Text(Translations.shared.numberTr(others.count)).font(.system(size: 11, weight: .black)) }
                    Image(systemName: "exclamationmark").font(.system(size: 12, weight: .black))
                }
                if status.loading { ProgressView().tint(Theme.gold).scaleEffect(0.6) } else { Image(systemName: "network").font(.system(size: 12, weight: .bold)) }
            }
            .foregroundStyle(others.isEmpty ? Theme.gold : Theme.panelDark)
            .frame(height: 26).padding(.horizontal, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(others.isEmpty ? AnyShapeStyle(Theme.panelDark) : AnyShapeStyle(Theme.gold)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1))
        }
    }
}

/// Unciv MultiplayerStatusPopup: Unciv's GameList (our turn first, then by name) in a PickerPane - a game is selected,
/// its description shown, and "Load [name]" runs MultiplayerHelpers.loadMultiplayerGame: "Loading latest game
/// state..." and the game as it is on the server NOW (Multiplayer.downloadGame), never the list's cached copy - the
/// game in hand included, which is simply downloaded again. Ours listed raw ids in the order they were added and
/// opened the copy the last refresh had kept, up to allGameRefreshDelay old.
struct MultiplayerStatusPopup: View {
    @ObservedObject var controller: GameController
    @ObservedObject var status = MultiplayerStatus.shared
    let onOpen: (GameState) -> Void
    let onClose: () -> Void
    @State private var selected: String? = nil
    var body: some View {
        ThemedSheet(L("Multiplayer"), subtitle: Multiplayer.serverURL, onClose: onClose) {
            Panel(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Multiplayer.sortedGames(Multiplayer.knownGames, previews: status.previews), id: \.self) { g in
                        let p = status.previews[g]
                        let mine = p.map { Multiplayer.isMyTurn($0) } ?? false
                        let current = g == controller.state.settings.gameId
                        ThemedRow(title: Multiplayer.name(of: g) + (current ? " · \(L("Current game"))" : ""), detail: p.map { "\($0.currentPlayer) · \(L("Turn")) \($0.uncivTurns)" + (mine ? " · \(L("Your turn"))" : "") } ?? L("Loading..."), selected: selected == g, action: {
                            selected = g
                        }, leading: {
                            // Unciv GameDisplay: the turn indicator, and the error indicator for a game whose refresh failed
                            ZStack(alignment: .bottomTrailing) {
                                Image(systemName: mine ? "flag.fill" : "hourglass").foregroundStyle(mine ? Theme.good : Theme.creamDim)
                                if status.refreshErrors[g] != nil { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.danger) }
                            }
                        }, trailing: { EmptyView() })
                    }
                }
            }
            if let sel = selected {
                Text(MultiplayerHelpers.descriptionText(sel)).font(Theme.caption).foregroundStyle(Theme.creamDim).fixedSize(horizontal: false, vertical: true)
                // (not while our next turn runs on its clone: the load rebuilds the ruleset the turn's thread reads)
                Button(L("Load [\(Multiplayer.name(of: sel))]")) { load(sel) }.buttonStyle(ThemedButtonStyle(filled: true, compact: true)).disabled(controller.isProcessing || controller.loadingLatestState)
            }
            Button(L("Refresh list")) { status.refresh(currentGameId: controller.state.settings.gameId) }.buttonStyle(ThemedButtonStyle(compact: true)).disabled(status.loading)
        }
    }
    /// Unciv MultiplayerStatusPopup rightSideButton: `close()`, then MultiplayerHelpers.loadMultiplayerGame - its modal
    /// "Loading latest game state..." over the world screen until the game is downloaded and opened, or the failure's
    /// message (GameController.loadMultiplayerGame). Ours kept the popup open over the download, which could be closed
    /// and a Next Turn started meanwhile - the download then rebuilt the ruleset and the map globals the turn's thread read.
    private func load(_ gameId: String) {
        guard !controller.isProcessing, !controller.loadingLatestState else { return }
        onClose()
        controller.loadMultiplayerGame(gameId, onOpen: onOpen)
    }
}
