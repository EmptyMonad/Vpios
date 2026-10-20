// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Asynchronous online play: the whole game state lives as a file on a simple server
/// (compatible with UncivServer's GET/PUT /files/{name} API). Players take turns by uploading the state.
enum Multiplayer {
    static var serverURL: String {
        get { UserDefaults.standard.string(forKey: "epochs.mpServer") ?? "https://uncivserver.xyz" }   // Unciv Constants.uncivXyzServer
        set { UserDefaults.standard.set(newValue, forKey: "epochs.mpServer") }
    }
    /// Unciv AdvancedTab "Take user ID from clipboard".
    static func setUserId(_ id: String) { UserDefaults.standard.set(id, forKey: "epochs.userId") }
    static var userId: String {
        if let id = UserDefaults.standard.string(forKey: "epochs.userId") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "epochs.userId")
        return id
    }
    static var userName: String {
        get { UserDefaults.standard.string(forKey: "epochs.userName") ?? "Player" }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.userName") }
    }
    static var knownGames: [String] {
        get { UserDefaults.standard.stringArray(forKey: "epochs.mpGames") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.mpGames") }
    }
    /// Unciv MultiplayerGame.name: the name the player gave the game, so the list is not a column of raw ids.
    static var gameNames: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "epochs.mpNames") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.mpNames") }
    }
    static func name(of gameId: String) -> String {
        let n = gameNames[gameId] ?? ""
        return n.isEmpty ? gameId : n
    }
    static func rename(_ gameId: String, to name: String) {
        var all = gameNames
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "")
        if trimmed.isEmpty { all[gameId] = nil } else { all[gameId] = trimmed }
        gameNames = all
    }
    /// Unciv GameList / GameDisplay.compareTo: the games where it is our turn first, then by name (Kotlin
    /// String.compareTo - by character, capitals before small letters).
    static func sortedGames(_ games: [String], previews: [String: GamePreview]) -> [String] {
        games.sorted { a, b in
            let ma = previews[a].map { isMyTurn($0) } ?? false
            let mb = previews[b].map { isMyTurn($0) } ?? false
            if ma != mb { return ma }
            return name(of: a) < name(of: b)
        }
    }

    /// Unciv GameSettingsMultiplayer.passwords[server]: Basic auth for UncivServer (`/auth`) and the chat socket.
    static var password: String {
        get { UserDefaults.standard.string(forKey: "epochs.mpPassword." + serverURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.mpPassword." + serverURL) }
    }
    static var authHeader: String { authHeader(password: password) }
    private static func authHeader(password: String) -> String { "Basic " + Data("\(userId):\(password)".utf8).base64EncodedString() }
    /// Unciv GameSettingsMultiplayer.currentGameTurnNotificationSound / otherGameTurnNotificationSound: both are
    /// `UncivSound.Silent` until the player picks a sound ("" here, which Audio.play does not sound).
    static var currentGameTurnNotificationSound: String {
        get { UserDefaults.standard.string(forKey: "epochs.mpSoundCurrent") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.mpSoundCurrent") }
    }
    static var otherGameTurnNotificationSound: String {
        get { UserDefaults.standard.string(forKey: "epochs.mpSoundOther") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.mpSoundOther") }
    }
    /// Unciv GameSettingsMultiplayer.currentGameRefreshDelay: `Duration.ofSeconds(10)` - how often the game on screen is
    /// fetched from the server (GameController.startPolling) - whoever's turn it is, since only UncivServer-style servers
    /// are used (Multiplayer.usesCustomServer()).
    static var currentGameRefreshSeconds: Int {
        get { UserDefaults.standard.object(forKey: "epochs.mpCurRefresh") as? Int ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.mpCurRefresh") }
    }
    /// Unciv GameSettingsMultiplayer.allGameRefreshDelay: `Duration.ofMinutes(5)` - how often the other games are fetched
    /// (MultiplayerStatus). Kept in seconds, as Unciv's list starts at 15 s; the older whole-minute setting
    /// ("epochs.mpCheckerDelay") is read as its value in seconds until a new one is picked.
    static var allGameRefreshSeconds: Int {
        get {
            if let s = UserDefaults.standard.object(forKey: "epochs.mpAllRefresh") as? Int { return s }
            if let m = UserDefaults.standard.object(forKey: "epochs.mpCheckerDelay") as? Int { return m * 60 }
            return 300
        }
        set { UserDefaults.standard.set(newValue, forKey: "epochs.mpAllRefresh") }
    }
    enum AuthStatus { case verified, unregistered, unauthorized, unknown }
    private static func authURL() -> URL? { URL(string: serverURL.hasSuffix("/") ? serverURL + "auth" : serverURL + "/auth") }
    /// Unciv UncivServerFileStorage.checkAuthStatus: GET /auth → 200 verified, 204 unregistered, 401 unauthorized.
    static func checkAuthStatus() async -> AuthStatus {
        guard let url = authURL() else { return .unknown }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return .unknown }
        switch http.statusCode { case 200: return .verified; case 204: return .unregistered; case 401: return .unauthorized; default: return .unknown }
    }
    /// Unciv MultiplayerServer.setPassword: false on a server without authentication (featureSet.authVersion == 0);
    /// otherwise UncivServerFileStorage.setPassword - PUT /auth with the new password as body, authenticated with the
    /// old one, a 401 being MultiplayerAuthException - and the new password is stored for the server.
    @discardableResult
    static func setPassword(_ newPassword: String) async throws -> Bool {
        guard await ServerFeatures.shared.featureSet.authVersion > 0 else { return false }
        guard let url = authURL() else { throw MPError.noServer }
        var req = URLRequest(url: url); req.httpMethod = "PUT"; req.timeoutInterval = 10
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.httpBody = Data(newPassword.utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw code == 401 ? MPError.auth : MPError.http(code) }
        password = newPassword
        return true
    }
    /// Unciv MultiplayerServer.authenticate (AuthPopup's Authenticate button): a server without authentication
    /// (featureSet.authVersion == 0) lets anyone in; otherwise GET /auth with the given password - 401 is
    /// MultiplayerAuthException ("Authentication failed") - and a password that works is stored for the server.
    static func authenticate(password newPassword: String) async throws -> Bool {
        if await ServerFeatures.shared.featureSet.authVersion == 0 { return true }
        guard let url = authURL() else { throw MPError.noServer }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        req.setValue(authHeader(password: newPassword), forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw code == 401 ? MPError.auth : MPError.http(code) }
        password = newPassword
        return true
    }
    static func remember(_ gameId: String) { var g = knownGames; if !g.contains(gameId) { g.append(gameId); knownGames = g } }
    static func forget(_ gameId: String) { knownGames = knownGames.filter { $0 != gameId } }

    enum MPError: LocalizedError {
        /// `auth`: Unciv MultiplayerAuthException, what UncivServer's 401 on a save becomes
        case noServer, http(Int), badData, auth
        var errorDescription: String? {
            switch self {
            case .noServer: return "No server address set."
            case .http(let c): return "Server returned \(c)."
            case .badData: return "Unreadable game data."
            case .auth: return L("Authentication failed")
            }
        }
    }
    /// Unciv UncivGame.loadGame's UncivShowableException for a player who holds no seat in a game that allows no spectators.
    struct NotAllowedToSpectate: LocalizedError { var errorDescription: String? { L("You are not allowed to spectate!") } }
    /// Unciv UncivGame.loadGame: `isOnlineMultiplayer && anyoneCanSpectate == false && civilizations.none { it.playerId == userId }`
    /// throws "You are not allowed to spectate!" - checked on every load of an online game.
    static func checkSpectate(_ state: GameState) throws {
        if state.settings.isOnline && !state.settings.anyoneCanSpectate && !state.civs.contains(where: { $0.playerUserId == userId }) { throw NotAllowedToSpectate() }
    }

    private static func fileURL(_ gameId: String) throws -> URL {
        let base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let url = URL(string: base.hasSuffix("/") ? base + "files/\(gameId)" : base + "/files/\(gameId)") else { throw MPError.noServer }
        return url
    }

    /// Unciv NewGameScreen.checkConnectionToMultiplayerServer: does the server answer at all.
    static func isAlive() async -> Bool {
        guard let base = URL(string: serverURL.hasSuffix("/") ? serverURL + "isalive" : serverURL + "/isalive") else { return false }
        var req = URLRequest(url: base); req.timeoutInterval = 8
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
    /// Unciv MultiplayerServer.checkServerStatus (at launch, UncivGame.kt, and from Options' "Check connection"):
    /// GET /isalive, and a 2xx answer's body is the server's feature set - one that is not a feature set reads as
    /// ServerFeatureSet() ("The server does not support server feature set - not an error!").
    @discardableResult
    static func checkServerStatus() async -> Bool {
        guard let base = URL(string: serverURL.hasSuffix("/") ? serverURL + "isalive" : serverURL + "/isalive") else { return false }
        var req = URLRequest(url: base); req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return false }
        let features = (try? JSONDecoder().decode(ServerFeatureSet.self, from: data)) ?? ServerFeatureSet()
        await ServerFeatures.shared.set(features)
        return true
    }

    static func upload(_ state: GameState) async throws {
        guard let gameId = state.settings.gameId else { throw MPError.badData }
        var req = URLRequest(url: try fileURL(gameId))
        req.httpMethod = "PUT"
        req.httpBody = try JSONEncoder().encode(state)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let (_, resp) = try await URLSession.shared.data(for: req)
        // Unciv UncivServerFileStorage.saveFileData: 401 throws MultiplayerAuthException
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw code == 401 ? MPError.auth : MPError.http(code) }
    }

    private static func fetch(_ gameId: String) async throws -> Data {
        var req = URLRequest(url: try fileURL(gameId)); req.timeoutInterval = 30
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw MPError.http((resp as? HTTPURLResponse)?.statusCode ?? 0) }
        return data
    }

    /// Unciv MultiplayerServer.tryDownloadGame: `UncivFiles.gameInfoFromString`, which ends in `gameInfo.setTransients()` -
    /// a downloaded game is rebuilt exactly as a local load is (SaveManager.load: the missing-mods check and the save's
    /// own ruleset, the HashSet orders, the IncompatibleSave check, updateCivilizationState). Ours only decoded it, so
    /// a joined, synced, skipped or resigned game ran on whatever stats, resources and orders the file happened to hold.
    /// Only the fetch leaves the main thread: the load activates the shared ruleset and sets the map globals, which the
    /// world screen reads as it draws (Unciv's load builds the game's own ruleset, on its download thread).
    @MainActor
    static func download(_ gameId: String) async throws -> GameState {
        let data = try await fetch(gameId)
        do { return try SaveManager.load(data: data) }
        catch let e as SaveManager.MissingMods { throw e }
        catch let e as SaveManager.IncompatibleSave { throw e }
        catch { throw MPError.badData }
    }
    /// Unciv MultiplayerServer.tryDownloadGamePreview: only the preview - no ruleset is activated and no game is built,
    /// so refreshing the list never touches the game being played.
    static func downloadPreview(_ gameId: String) async throws -> GamePreview {
        let data = try await fetch(gameId)
        guard let preview = try? JSONDecoder().decode(GamePreview.self, from: data) else { throw MPError.badData }
        return preview
    }

    /// Unciv Multiplayer.createGame: the new game is uploaded and added to the list - nothing else. Every human seat
    /// already carries the player ID the player picker gave it (GameStarter copies it into playerUserId); ours gave
    /// the first human seat the creator's ID over whatever the picker had put there.
    static func create(settings: GameSettings) async throws -> GameState {
        let (state, gameId) = try await newOnlineGame(settings)
        try await upload(state)
        remember(gameId)
        return state
    }
    /// The game itself is started on the main thread, as our offline Start game starts it (NewGameScreen.startNewGame):
    /// GameStarter activates the shared ruleset and sets the map globals, which the new game screen reads as it draws.
    /// (Unciv starts both on `runOnNonDaemonThreadPool("NewGame")`, its ruleset the new game's own; ours ran the online
    /// one on a thread of Swift's concurrency pool, writing those globals under the screen.) Only the upload leaves it.
    /// The start of a new online game threw before anything was uploaded
    struct GameStartFailure: Error, CustomStringConvertible { let description: String }
    @MainActor
    private static func newOnlineGame(_ settings: GameSettings) throws -> (GameState, String) {
        var s = settings
        s.isOnline = true
        // Unciv GameInfo.gameId = randomGameId(): `pseudoRandomUuid(SecureRandom()).toString()`, a whole lowercase UUID -
        // AddMultiplayerGameScreen refuses anything else, so ours (8 characters) could never be added on another device
        let gameId = UUID().uuidString.lowercased()
        s.gameId = gameId
        // Unciv NewGameScreen.startNewGame: GameStarter.startNewGame has its own try/catch before the upload's, so any
        // exception of it (StartingTilesError, the map generation's MapGenerationError) shows the map failure, never
        // "Could not upload game!"
        let state: GameState
        do { state = try GameState.newGame(settings: s) } catch { throw GameStartFailure(description: String(describing: error)) }
        // Epochs' display-only name, on the seat the creator actually holds (the waiting text shows it)
        if let i = state.civs.firstIndex(where: { $0.isPlayer && $0.playerUserId == userId }) { state.civs[i].playerName = userName }
        return (state, gameId)
    }

    /// Unciv Multiplayer.addGame: the game's preview is downloaded and the game added to the list under its name -
    /// nothing is uploaded and no seat is touched. A player who holds no seat has added a game to watch (Unciv checks
    /// spectating only when the game is loaded). Ours took the first human seat without a player ID and uploaded
    /// the game, and refused ("Unreadable game data.") anyone who found every seat taken.
    static func join(gameId: String) async throws -> GameState {
        let state = try await download(gameId)
        remember(gameId)
        return state
    }

    /// Unciv MultiplayerGame.durationInactive: how long the current player has been sitting on their turn.
    static func minutesInactive(_ state: GameState) -> Double { minutesInactive(since: state.currentTurnStartTime) }
    static func minutesInactive(_ preview: GamePreview) -> Double { minutesInactive(since: preview.currentTurnStartTime) }
    private static func minutesInactive(since start: Double) -> Double {
        guard start > 0 else { return 0 }
        return (Date().timeIntervalSince1970 * 1000 - start) / 60000
    }

    /// Unciv Multiplayer.hasLatestGameState: the same current player and the same turn.
    static func hasLatestGameState(_ state: GameState, _ preview: GamePreview) -> Bool {
        state.currentHuman.nation == preview.currentPlayer && state.uncivTurns == preview.uncivTurns
    }

    /// Unciv MultiplayerScreen.getOurCivNameOrPlayerId: our civ's name when we hold a seat that is not a spectator's,
    /// otherwise our player ID - who is named as having resigned or skipped someone.
    static func ourCivNameOrPlayerId(_ preview: GamePreview) -> String {
        if let ours = preview.civs.first(where: { $0.playerUserId == userId }), !ours.isSpectator { return ours.nation }
        return userId
    }

    /// Unciv Multiplayer.resignPlayer: the LATEST game is downloaded, and if its current player is no longer the one
    /// the list showed, nothing happens ("Game was out of sync with server - updated"). Otherwise the civ becomes an
    /// AI for good (playerType AI, playerId ""), a current player's turn is played on by GameInfo.nextTurn - which,
    /// the player now being an AI, skips the human end of turn and plays the civ itself as an AI this very turn before
    /// walking on to the next living human - every civ is told, and the game is uploaded.
    /// Ours only flipped the civ and uploaded: the resigning civ's turn was never played, and its leaving `humans`
    /// moved currentHumanIndex onto another human, who then played the same turn a second time.
    /// Returns the message to show ("" when it went through) and the game as it now stands (the caller's updatePreview).
    /// The server as ScenarioSelfTests.onlineThread stands in for it: resignPlayer and skipCurrentPlayerTurn take its game
    /// instead of downloading one (the download is the main thread's, which the self-test holds) and keep the game they
    /// would upload, and the game's part notes the thread it is played on and that thread's real stack size. Set only by
    /// the self-test, on the main thread, around its two calls.
    final class SelfTestServer: @unchecked Sendable {
        let game: GameState
        var uploaded: GameState? = nil
        var playedOnMain: Bool? = nil, playedStack = 0
        init(game: GameState) { self.game = game }
        func notePlay() { playedOnMain = Thread.isMainThread; playedStack = pthread_get_stacksize_np(pthread_self()) }
    }
    nonisolated(unsafe) static var selfTestServer: SelfTestServer? = nil

    static func resignPlayer(gameId: String, previewCurrentPlayer: String, playerCivName: String, responsibleCivNameOrPlayerId responsible: String) async throws -> (message: String, state: GameState) {
        // download to work with the latest game state
        let state: GameState
        if let server = selfTestServer { state = server.game } else { state = try await download(gameId) }
        if state.currentHuman.nation != previewCurrentPlayer {
            return ("Game was out of sync with server - updated", state)
        }
        guard state.civs.contains(where: { $0.nation == playerCivName }) else { throw MPError.badData }
        // Unciv runOnNonDaemonThreadPool("Resign"): the turn is played on a thread of its own (TurnThread)
        await TurnThread.run("Resign") { resignDownloaded(state, playerCivName: playerCivName, responsible: responsible) }
        if let server = selfTestServer { server.uploaded = state } else { try await upload(state) }
        return ("", state)
    }

    /// The game's part of resignPlayer, on the downloaded game: the civ becomes an AI, its turn is played on if it was
    /// the current player's, and every civ is told.
    static func resignDownloaded(_ state: GameState, playerCivName: String, responsible: String) {
        selfTestServer?.notePlay()
        guard let i = state.civs.firstIndex(where: { $0.nation == playerCivName }) else { return }
        let civId = state.civs[i].id
        let currentId = state.currentHumanId
        // Set civ info to AI
        state.civs[i].isPlayer = false
        state.civs[i].playerUserId = nil
        // call next turn so turn gets simulated by AI
        if currentId == civId { state.nextTurnAfterResign(civId) }
        // (the current human stays current: our index into `humans` follows it past the civ that left the list)
        else { state.currentHumanIndex = state.humans.firstIndex { $0.id == currentId } ?? 0 }
        // Add notification so everyone knows what happened - for every civ, as AI players are skipped anyway
        let text = responsible == playerCivName || responsible.isEmpty
            ? "[\(playerCivName)] resigned and is now controlled by AI"
            : "[\(playerCivName)] was forcibly resigned by [\(responsible)] and is now controlled by AI"
        for c in state.civs { state.notify(c.id, text, category: .General, icons: [playerCivName]) }
    }

    /// Unciv Multiplayer.skipCurrentPlayerTurn: the latest game is downloaded (a failure is the message shown); if its
    /// current player differs from the list's the list is updated ("The game was out of sync with the server"), and
    /// if it is not the civ the button named nothing is skipped - "we always pass in the player name to ensure if the
    /// button was clicked twice we don't skip 2 turns". Then `NextTurnAutomation.automateCivMoves(playerCiv, false)` -
    /// no war, offers, policies, gold, spies or settlers for the absent player - and `gameInfo.nextTurn()`, which ends
    /// that civ's turn the way a human's ends (TurnManager.endTurn, then the walk to the next human); every civ is
    /// told, and the game is uploaded.
    /// Ours ran the civ's automation with trading and state changes on, checked nothing and told no one.
    /// Returns the message to show (nil when it went through) and the game as it now stands for the list, if any.
    static func skipCurrentPlayerTurn(gameId: String, previewCurrentPlayer: String, playerCivName: String, responsibleCivNameOrPlayerId responsible: String) async throws -> (message: String?, state: GameState?) {
        // download to work with the latest game state
        let state: GameState
        if let server = selfTestServer { state = server.game }
        else { do { state = try await download(gameId) } catch { return (error.localizedDescription, nil) } }
        if state.currentHuman.nation != previewCurrentPlayer {
            return ("The game was out of sync with the server", state)
        }
        if state.currentHuman.nation != playerCivName {
            return ("Could not skip turn - current player is [\(state.currentHuman.nation)], not [\(playerCivName)]", nil)
        }
        // Unciv runOnNonDaemonThreadPool("Skip turn"): the turn is played on a thread of its own (TurnThread)
        await TurnThread.run("Skip turn") { skipDownloaded(state, playerCivName: playerCivName, responsible: responsible) }
        if let server = selfTestServer { server.uploaded = state } else { try await upload(state) }
        return (nil, state)
    }

    /// The game's part of skipCurrentPlayerTurn, on the downloaded game whose current player is the one skipped.
    static func skipDownloaded(_ state: GameState, playerCivName: String, responsible: String) {
        selfTestServer?.notePlay()
        let civId = state.currentHumanId
        state.automateCivMoves(civId, tradeAndChangeState: false)
        state.endTurn()
        let text = responsible == playerCivName || responsible.isEmpty
            ? "[\(playerCivName)] skipped their own turn"
            : "[\(playerCivName)]'s turn was skipped by [\(responsible)]"
        for c in state.civs { state.notify(c.id, text, category: .General, icons: [playerCivName]) }
    }

    static func isMyTurn(_ state: GameState) -> Bool {
        guard state.settings.isOnline else { return true }
        return state.currentHuman.playerUserId == userId
    }
    /// Unciv GameInfoPreview.isUsersTurn: `getCivilization(currentPlayer).playerId == userId`.
    static func isMyTurn(_ preview: GamePreview) -> Bool { preview.currentHuman?.playerUserId == userId }
}

/// Unciv ServerFeatureSet: what the server's `/isalive` body says it supports - all zeros for a server that says nothing.
struct ServerFeatureSet: Codable, Equatable {
    var authVersion = 0
    var chatVersion = 0
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authVersion = try c.decodeIfPresent(Int.self, forKey: .authVersion) ?? 0
        chatVersion = try c.decodeIfPresent(Int.self, forKey: .chatVersion) ?? 0
    }
}

/// Unciv MultiplayerServer.featureSet, observable: MultiplayerServer.setFeatureSet refreshes the chat button's visibility
/// (ChatButton.refreshVisibility) whenever the set changes.
@MainActor
final class ServerFeatures: ObservableObject {
    static let shared = ServerFeatures()
    @Published private(set) var featureSet = ServerFeatureSet()
    func set(_ value: ServerFeatureSet) { if featureSet != value { featureSet = value } }
}

/// Unciv GameInfoPreview (with CivilizationInfoPreview): the few fields the multiplayer screens read, decoded from the
/// game file alone (Unciv tryDownloadGamePreview) or taken from a game in hand (Unciv `gameInfo.asPreview()`).
struct GamePreview: Decodable {
    struct Civ: Decodable {
        var id: Int
        var nation: String
        var isPlayer: Bool
        var playerUserId: String? = nil
        var playerMinutesBeforeForceResign = 3 * 24 * 60   // Kotlin field default
        var totalTurnTimeSeconds = 0
        var turnsPlayedAsHuman = 0
        var isSpectator: Bool { nation == "Spectator" }
        private enum CodingKeys: String, CodingKey { case id, nation, isPlayer, playerUserId, playerMinutesBeforeForceResignField, totalTurnTimeSeconds, turnsPlayedAsHuman }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            nation = try c.decode(String.self, forKey: .nation)
            isPlayer = try c.decode(Bool.self, forKey: .isPlayer)
            playerUserId = try? c.decodeIfPresent(String.self, forKey: .playerUserId)
            playerMinutesBeforeForceResign = (try? c.decodeIfPresent(Int.self, forKey: .playerMinutesBeforeForceResignField)) ?? 3 * 24 * 60
            totalTurnTimeSeconds = (try? c.decodeIfPresent(Int.self, forKey: .totalTurnTimeSeconds)) ?? 0
            turnsPlayedAsHuman = (try? c.decodeIfPresent(Int.self, forKey: .turnsPlayedAsHuman)) ?? 0
        }
        init(_ civ: Civilization) {
            id = civ.id; nation = civ.nation; isPlayer = civ.isPlayer; playerUserId = civ.playerUserId
            playerMinutesBeforeForceResign = civ.playerMinutesBeforeForceResign
            totalTurnTimeSeconds = civ.totalTurnTimeSeconds; turnsPlayedAsHuman = civ.turnsPlayedAsHuman
        }
    }
    var settings: GameSettings
    var civs: [Civ]
    var turn: Int
    var currentHumanIndex = 0
    var currentTurnStartTime: Double = 0
    private enum CodingKeys: String, CodingKey { case settings, civs, turn, currentHumanIndex, currentTurnStartTime }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decode(GameSettings.self, forKey: .settings)
        civs = try c.decode([Civ].self, forKey: .civs)
        turn = try c.decode(Int.self, forKey: .turn)
        currentHumanIndex = try c.decodeIfPresent(Int.self, forKey: .currentHumanIndex) ?? 0
        currentTurnStartTime = try c.decodeIfPresent(Double.self, forKey: .currentTurnStartTime) ?? 0
    }
    /// Unciv GameInfo.asPreview()
    init(_ state: GameState) {
        settings = state.settings; civs = state.civs.map(Civ.init); turn = state.turn
        currentHumanIndex = state.currentHumanIndex; currentTurnStartTime = state.currentTurnStartTime
    }
    var gameId: String { settings.gameId ?? "" }
    var humans: [Civ] { civs.filter { $0.isPlayer } }
    /// GameState.currentHuman, read from the same saved fields
    var currentHuman: Civ? {
        let h = humans
        guard !h.isEmpty else { return civs.first }
        return h[min(currentHumanIndex, h.count - 1)]
    }
    /// Unciv GameInfoPreview.currentPlayer
    var currentPlayer: String { currentHuman?.nation ?? "" }
    /// Unciv GameInfoPreview.turns: zero-based (a saved game is never in its barbarian phase - GameState.uncivTurns)
    var uncivTurns: Int { turn - 1 }
}
