// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Unciv multiplayer chat (core/logic/multiplayer/chat/ChatWebSocket.kt + ChatStore.kt): a WebSocket to `<server>/chat`
/// authenticated with the same Basic header as the file API; JSON messages tagged by `type`: chat / join / leave,
/// responses chat / joinSuccess / error. One chat per game id, unread counts, exponential reconnect.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    struct Message: Identifiable, Equatable { let id = UUID(); let civName: String; let message: String }
    final class Chat: ObservableObject, Identifiable {
        let gameId: String
        @Published var messages: [Message] = [Message(civName: "System", message: "Welcome to Chat!")]
        @Published var unreadCount = 0
        init(gameId: String) { self.gameId = gameId }
        var id: String { gameId }
    }

    @Published private(set) var chats: [String: Chat] = [:]
    @Published var globalMessages: [Message] = []
    @Published var hasGlobalMessage = false
    @Published private(set) var connected = false
    var openChatGameId: String? = nil           // the chat popup currently on screen
    var currentGameId: String? = nil            // the online game on the world screen
    var currentPlayerCiv: String? = nil
    var onIndication: (() -> Void)? = nil        // ChatButton.triggerChatIndication

    private var task: URLSessionWebSocketTask?
    private var session: URLSession { URLSession.shared }
    private var reconnectAttempts = 0
    private var reconnectDelay: TimeInterval = 1
    private var wantsRunning = false
    private var pingTimer: Timer?
    private static let maxReconnectAttempts = 100
    private static let maxReconnectDelay: TimeInterval = 64

    func chat(for gameId: String) -> Chat {
        if let c = chats[gameId] { return c }
        let c = Chat(gameId: gameId); chats[gameId] = c
        return c
    }
    var gameIds: [String] { Array(Set(Array(chats.keys) + Multiplayer.knownGames)) }

    // MARK: connection
    private func chatURL() -> URL? {
        var base = Multiplayer.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("https://") { base = "wss://" + base.dropFirst(8) } else if base.hasPrefix("http://") { base = "ws://" + base.dropFirst(7) }
        return URL(string: base + "/chat")
    }

    func start() {
        wantsRunning = true
        guard task == nil, let url = chatURL() else { return }
        var req = URLRequest(url: url)
        req.setValue(Multiplayer.authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("Epochs/Chat", forHTTPHeaderField: "User-Agent")
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        connected = true
        relayGlobal("Successfully connected to WebSocket server!")
        send(["type": "join", "gameIds": gameIds])
        receiveLoop(t)
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.task?.sendPing { err in if let err { Task { @MainActor in self?.handleError(err) } } }
        }
    }
    func stop() {
        wantsRunning = false
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .normalClosure, reason: nil); task = nil
        connected = false
        reconnectAttempts = 0; reconnectDelay = 1
    }
    func restart(dueToError: Bool = false) {
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        connected = false
        guard wantsRunning else { return }
        if dueToError {
            guard reconnectAttempts < ChatStore.maxReconnectAttempts else { return }
            reconnectAttempts += 1
            let delay = reconnectDelay
            reconnectDelay = min(ChatStore.maxReconnectDelay, reconnectDelay * 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
        } else { start() }
    }
    private func handleError(_ error: Error) {
        if reconnectAttempts == 0 {
            relayGlobal("WebSocket connection closed. Cause: [\(error.localizedDescription)]")
            if error.localizedDescription.contains("401") { relayGlobal("Authentication issue detected! You have to set a password to use Chat.") }
        }
        restart(dueToError: true)
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .failure(let e): self.handleError(e)
                case .success(let msg):
                    var data: Data? = nil
                    if case .string(let s) = msg { data = s.data(using: .utf8) } else if case .data(let d) = msg { data = d }
                    if let d = data, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { self.handle(obj) }
                    self.reconnectAttempts = 0; self.reconnectDelay = 1
                    self.receiveLoop(t)
                }
            }
        }
    }
    private func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "chat":
            let civ = obj["civName"] as? String ?? "?", text = obj["message"] as? String ?? ""
            if let g = obj["gameId"] as? String, !g.isEmpty { relayChat(gameId: g, civName: civ, message: text) } else { relayGlobal(text, from: civ) }
        case "error": relayGlobal("Error: [\(obj["message"] as? String ?? "")]", from: "Server")
        default: break
        }
    }
    private func send(_ obj: [String: Any]) {
        guard let t = task, let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        t.send(.string(s)) { [weak self] err in if let err { Task { @MainActor in self?.handleError(err) } } }
    }

    // MARK: messages
    func requestMessageSend(gameId: String, civName: String, message: String) {
        start()
        send(["type": "chat", "civName": civName, "message": message, "gameId": gameId])
    }
    func join(gameId: String) { _ = chat(for: gameId); if task != nil { send(["type": "join", "gameIds": [gameId]]) } }

    private func relayChat(gameId: String, civName: String, message: String) {
        let c = chat(for: gameId)
        c.messages.append(Message(civName: civName, message: message))
        if openChatGameId != gameId && civName != "System" {
            if gameId != currentGameId { c.unreadCount += 1 }
            else if currentPlayerCiv != civName { c.unreadCount += 1; onIndication?() }
        }
        objectWillChange.send()
    }
    private func relayGlobal(_ message: String, from civName: String = "System") {
        globalMessages.append(Message(civName: civName, message: message))
        hasGlobalMessage = true
    }
    /// Unciv pollGlobalMessages: hand the queued system messages to the open popup.
    func pollGlobalMessages(_ action: (Message) -> Void) {
        for m in globalMessages { action(m) }
        globalMessages.removeAll(); hasGlobalMessage = false
    }
    func clear() { chats = [:]; globalMessages = []; hasGlobalMessage = false }
}
