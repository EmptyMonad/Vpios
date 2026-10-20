// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Unciv MultiplayerHelpers (and the pieces of Multiplayer the multiplayer screens call for loading a game).
@MainActor
enum MultiplayerHelpers {
    /// Unciv Duration.formatShort: only the largest unit that is not zero - "[n] Days", Hours, Minutes, else Seconds.
    static func formatShort(seconds total: Int) -> String {
        let days = total / 86400, hours = (total / 3600) % 24, minutes = (total / 60) % 60, seconds = total % 60
        for (part, unit) in [(days, "Days"), (hours, "Hours"), (minutes, "Minutes"), (seconds, "Seconds")] where part > 0 { return L("[\(part)] \(unit)") }
        return L("[\(seconds)] Seconds")
    }
    private static func secondsSince(_ date: Date) -> Int { Int(Date().timeIntervalSince(date).rounded(.down)) }

    /// Unciv LoadGameScreen.getLoadExceptionMessage: the primary line, then what went wrong.
    static func loadExceptionMessage(_ error: Error, primary: String = "Could not load game!") -> String {
        L(primary) + "\n" + error.localizedDescription
    }

    /// Unciv MultiplayerHelpers.buildDescriptionText: the refresh error, "Last refresh", then - with a preview - whose
    /// turn it is and for how long (with the average once they have played a turn), the time they have left before
    /// they may be forced to resign, our civ with the difficulty and the zero-based turn, the base ruleset and the mods.
    static func descriptionText(_ gameId: String, status: MultiplayerStatus = .shared) -> String {
        var lines: [String] = []
        if let e = status.refreshErrors[gameId] { lines.append(L("Error while refreshing:") + "\n" + e) }
        if let last = status.lastUpdate(gameId) { lines.append(L("Last refresh: [\(formatShort(seconds: secondsSince(last)))] ago")) }
        if let preview = status.previews[gameId], let current = preview.currentHuman {
            // "You", name of friend, or null
            let descriptor: String? = current.playerUserId == Multiplayer.userId ? "You"
                : UserSettings.friends.first { $0.id == current.playerUserId }?.name
            var playerText = "{\(preview.currentPlayer)}"
            if let d = descriptor { playerText += "{ }({\(d)})" }
            let currentTurnTime = preview.currentTurnStartTime > 0 ? Int(((Date().timeIntervalSince1970 * 1000 - preview.currentTurnStartTime) / 1000).rounded(.down)) : 0
            var line = "Current Turn: [\(playerText)] since [\(formatShort(seconds: currentTurnTime))] ago"
            if current.turnsPlayedAsHuman > 0 {
                // "+1 to include current turn and avoid div by 0" (Duration.dividedBy: whole seconds, truncated)
                let average = (current.totalTurnTimeSeconds + currentTurnTime) / (current.turnsPlayedAsHuman + 1)
                line += " (average: [\(formatShort(seconds: average))])"
            }
            lines.append(L(line))
            lines.append(L("Time to play the turn: [\(formatShort(seconds: current.playerMinutesBeforeForceResign * 60))]"))
            let playerCivName = preview.civs.first { $0.playerUserId == Multiplayer.userId }?.nation ?? "Unknown"
            lines.append(L("{\(playerCivName)}, \(L(preview.settings.difficulty)), ⏳\(preview.uncivTurns)"))
            lines.append("\(L("Base ruleset:")) \(L(preview.settings.baseRuleset))")
            if !preview.settings.mods.isEmpty { lines.append(L("{Mods:} ") + Ruleset.shownModList(preview.settings.mods)) }
        }
        return lines.joined(separator: "\n")
    }

    /// Unciv Multiplayer.downloadGame(gameId), what MultiplayerHelpers.loadMultiplayerGame runs behind "Loading latest
    /// game state...": the latest game from the server; the list's preview is updated when the download is newer
    /// (hasNewerGameState: more turns); and UncivGame.loadGame's "You are not allowed to spectate!" check.
    static func downloadGame(_ gameId: String, status: MultiplayerStatus = .shared) async throws -> GameState {
        let state = try await Multiplayer.download(gameId)
        let preview = GamePreview(state)
        if let stored = status.previews[gameId], preview.uncivTurns > stored.uncivTurns { status.updatePreview(gameId, preview) }
        try Multiplayer.checkSpectate(state)
        return state
    }
}

/// Unciv AuthPopup: "Please enter your server password", a password field, a Close button (negative: the request
/// fails) and "Authenticate" (MultiplayerServer.authenticate; a refused password reads "Authentication failed" and
/// the popup stays).
struct AuthPopupView: View {
    let onResult: (Bool) -> Void
    @State private var password = ""
    @State private var header = "Please enter your server password"
    @State private var busy = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().bleedIntoCutout()
            Panel(highlighted: true) {
                VStack(spacing: 12) {
                    Text(L(header)).font(Theme.heading(15)).foregroundStyle(Theme.cream).multilineTextAlignment(.center)
                    SecureField(L("Password"), text: $password).textFieldStyle(.roundedBorder).font(Theme.body)
                    HStack(spacing: 16) {
                        Button(L("Close")) { onResult(false) }.buttonStyle(ThemedButtonStyle(destructive: true, compact: true))
                        Button(L("Authenticate")) {
                            busy = true
                            let pw = password
                            Task {
                                let ok = (try? await Multiplayer.authenticate(password: pw)) ?? false
                                busy = false
                                if ok { onResult(true) } else { header = "Authentication failed"; password = "" }
                            }
                        }.buttonStyle(ThemedButtonStyle(filled: true, compact: true)).disabled(busy)
                    }
                }
            }
            .frame(maxWidth: 420).padding(20)
        }
    }
}

/// Unciv WorldScreen's online popups: AuthPopup on a MultiplayerAuthException, the failed upload of nextTurn, and
/// loadLatestMultiplayerState's "Loading latest game state..." / "Couldn't download the latest game state!" (Retry,
/// Main menu); and startNewScreenJob's way back to the main menu when UncivGame.loadGame refuses the game.
struct OnlineWorldPopups: ViewModifier {
    @ObservedObject var controller: GameController
    let onQuit: () -> Void
    func body(content: Content) -> some View {
        content
            .overlay { if controller.authRequest != nil { AuthPopupView { controller.answerAuthentication($0) }.zIndex(13) } }
            .overlay { if let m = controller.uploadErrorPopup { MultiplayerMessagePopup(text: m, copyText: m, onClose: { controller.uploadErrorPopup = nil }).zIndex(13) } }
            .overlay { if controller.loadingLatestState { loadingPopup.zIndex(13) } }
            .overlay { if let e = controller.latestStateError { latestStateErrorPopup(e).zIndex(13) } }
            // Unciv loadMultiplayerGame: `loadingGamePopup.reuseWith(message, true)` - the failure, and a close button
            .overlay { if let m = controller.loadGameError { MultiplayerMessagePopup(text: m, onClose: { controller.loadGameError = nil }).zIndex(13) } }
            .onChange(of: controller.mainMenuMessage) { _, m in if m != nil { onQuit() } }
    }
    private var loadingPopup: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().bleedIntoCutout()
            Panel(padding: 16) { HStack(spacing: 10) { ProgressView().tint(Theme.gold); Text(L("Loading latest game state...")).font(Theme.heading(14)) } }
        }
    }
    private func latestStateErrorPopup(_ e: String) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().bleedIntoCutout()
            Panel(highlighted: true) {
                VStack(spacing: 12) {
                    Text(e).font(Theme.body).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Button(L("Main menu")) { controller.latestStateError = nil; onQuit() }.buttonStyle(ThemedButtonStyle(compact: true))
                        Button(L("Retry")) {
                            controller.latestStateError = nil
                            if let g = controller.state.settings.gameId { Task { await controller.loadLatestMultiplayerState(g) } }
                        }.buttonStyle(ThemedButtonStyle(filled: true, compact: true))
                    }
                }
            }.frame(maxWidth: 460).padding(20)
        }
    }
}

/// Unciv Popup with a good-sized label and a Close button (and, for an upload that failed, "Copy to clipboard").
struct MultiplayerMessagePopup: View {
    let text: String
    var copyText: String? = nil
    let onClose: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().bleedIntoCutout().onTapGesture { if !UserSettings.neverCloseByTapOutside { onClose() } }
            Panel(highlighted: true) {
                VStack(spacing: 12) {
                    Text(text).font(Theme.body).foregroundStyle(Theme.cream).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        if let c = copyText { Button(L("Copy to clipboard")) { UIPasteboard.general.string = c }.buttonStyle(ThemedButtonStyle(compact: true)) }
                        Button(L("Close")) { onClose() }.buttonStyle(ThemedButtonStyle(compact: true))
                    }
                }
            }
            .frame(maxWidth: 460).padding(20)
        }
    }
}
